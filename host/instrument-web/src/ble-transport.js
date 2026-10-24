// Browser Web Bluetooth central for the V3 ESP32-S3 bridge.
// The FPGA is still behind the S3 UART; a BLE link only proves that the
// browser reached the bridge, not that the FPGA executed a command.
export const NUS_UUIDS = Object.freeze({
  service: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
  write: '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
  notify: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
});

const UUID_RE = /^(?:[0-9a-f]{4}|[0-9a-f]{8}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
const textEncoder = new TextEncoder();

export function normalizeUuid(value, label = 'UUID') {
  const uuid = String(value ?? '').trim();
  if (!UUID_RE.test(uuid)) throw new Error(`${label} 格式无效：请输入 16 位、32 位或标准 UUID`);
  return uuid.length <= 8 ? `${uuid.padStart(8, '0').toLowerCase()}-0000-1000-8000-00805f9b34fb` : uuid.toLowerCase();
}

function characteristicSupports(characteristic, property) {
  return Boolean(characteristic?.properties?.[property]);
}

export class BleTransport {
  constructor(bluetooth = globalThis.navigator?.bluetooth, { chunkSize = 20 } = {}) {
    this.bluetooth = bluetooth;
    this.chunkSize = chunkSize;
    this.connected = false;
    this.state = 'disconnected';
    this.listeners = new Set();
    this.dataListeners = new Set();
    this.device = null;
    this.server = null;
    this.writeCharacteristic = null;
    this.notifyCharacteristic = null;
    this.session = null;
    this.onDisconnected = () => {
      if (this.state !== 'disconnected') void this.close('BLE 设备已断开').catch(() => {});
    };
    this.onValueChanged = this.onValueChanged.bind(this);
    if (!Number.isInteger(chunkSize) || chunkSize < 1 || chunkSize > 512) throw new Error('BLE 分片大小无效');
  }

  onStatus(listener) { this.listeners.add(listener); return () => this.listeners.delete(listener); }
  onData(listener) { this.dataListeners.add(listener); return () => this.dataListeners.delete(listener); }
  emit(state, message) {
    this.state = state;
    this.connected = state === 'connected';
    for (const listener of this.listeners) listener({ state, connected: this.connected, message });
  }

  async connect({ serviceUuid = NUS_UUIDS.service, writeUuid = NUS_UUIDS.write, notifyUuid = NUS_UUIDS.notify, namePrefix = '' } = {}) {
    if (!this.bluetooth?.requestDevice) throw new Error('此浏览器不支持 Web Bluetooth；请使用 HTTPS 或 localhost 的 Chrome/Edge。');
    if (globalThis.isSecureContext === false) throw new Error('BLE 连接需要 HTTPS 或 localhost 页面。');
    if (this.state !== 'disconnected') throw new Error('当前 BLE 连接操作尚未结束');
    const service = normalizeUuid(serviceUuid, '服务 UUID');
    const write = normalizeUuid(writeUuid, '写入特征 UUID');
    const notify = normalizeUuid(notifyUuid, '通知特征 UUID');
    const session = { active: true, tail: Promise.resolve(), pending: 0 };
    this.session = session;
    const check = () => {
      if (!session.active || this.session !== session) throw new Error('BLE 连接已取消或断开');
    };
    this.emit('connecting', '请选择 V3 ESP32-S3 BLE 设备');
    let device;
    try {
      const filters = namePrefix.trim() ? [{ namePrefix: namePrefix.trim() }] : [{ services: [service] }];
      device = await this.bluetooth.requestDevice({ filters, optionalServices: [service] });
      check();
      if (!device?.gatt) throw new Error('所选 BLE 设备不支持 GATT');
      device.addEventListener?.('gattserverdisconnected', this.onDisconnected);
      this.device = device;
      const server = await device.gatt.connect();
      check(); this.server = server;
      const primary = await server.getPrimaryService(service);
      check();
      const writer = await primary.getCharacteristic(write);
      check(); this.writeCharacteristic = writer;
      const receiver = await primary.getCharacteristic(notify);
      check(); this.notifyCharacteristic = receiver;
      if (!characteristicSupports(this.writeCharacteristic, 'write') && !characteristicSupports(this.writeCharacteristic, 'writeWithoutResponse')) {
        throw new Error('写入特征不支持 Write 或 Write Without Response');
      }
      if (!characteristicSupports(this.notifyCharacteristic, 'notify') && !characteristicSupports(this.notifyCharacteristic, 'indicate')) {
        throw new Error('通知特征不支持 Notify 或 Indicate');
      }
      this.notifyCharacteristic.addEventListener('characteristicvaluechanged', this.onValueChanged);
      await this.notifyCharacteristic.startNotifications();
      check();
      this.emit('connected', `BLE 已连接：${device.name || '未命名设备'} · FPGA 状态尚未确认`);
    } catch (error) {
      // Only the failed session may clear its own state. In particular a late
      // promise from an old connection must never tear down a reconnected one.
      if (this.session === session) {
        this.cleanup();
        this.emit('disconnected', `BLE 连接未建立：${error.message}`);
      } else if (device && device !== this.device && device.gatt.connected) device.gatt.disconnect();
      throw error;
    }
  }

  onValueChanged(event) {
    const value = event.target?.value;
    if (!value || !this.session?.active) return;
    const bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    for (const listener of this.dataListeners) listener(bytes.slice());
  }

  async sendBytes(bytes) {
    if (!this.connected || !this.writeCharacteristic) throw new Error('请先连接 BLE');
    const data = new Uint8Array(bytes);
    if (!data.length) throw new Error('不能发送空数据');
    if (data.length > 4096) throw new Error('BLE 单次发送最多 4096 字节');
    const session = this.session;
    if (session.pending >= 8) throw new Error('BLE 发送队列已满，请稍后重试');
    const characteristic = this.writeCharacteristic;
    session.pending += 1;
    const check = () => {
      if (!session.active || this.session !== session || !this.connected) throw new Error('BLE 连接已断开，未完成发送');
    };
    const task = session.tail.then(async () => {
      try {
      for (let offset = 0; offset < data.length; offset += this.chunkSize) {
        check();
        const chunk = data.slice(offset, Math.min(data.length, offset + this.chunkSize));
        if (characteristicSupports(characteristic, 'write')) {
          if (typeof characteristic.writeValueWithResponse === 'function') await characteristic.writeValueWithResponse(chunk);
          else await characteristic.writeValue(chunk);
        } else if (characteristicSupports(characteristic, 'writeWithoutResponse')) {
          if (typeof characteristic.writeValueWithoutResponse === 'function') await characteristic.writeValueWithoutResponse(chunk);
          else await characteristic.writeValue(chunk);
        }
        else throw new Error('BLE 写入特征已失效');
        check();
      }
      return data.length;
      } catch (error) {
        if (this.session === session) this.close(`BLE 发送失败：${error.message}`);
        throw error;
      }
    });
    session.tail = task.catch(() => {});
    try { return await task; }
    finally { session.pending -= 1; }
  }

  async sendText(text, { newline = true } = {}) {
    const value = String(text ?? '');
    const bytes = textEncoder.encode(value + (newline ? '\n' : ''));
    if (!value.trim() || bytes.length > 4096) throw new Error('测试文本不能为空，含换行最多 4096 字节');
    return this.sendBytes(bytes);
  }

  cleanup() {
    if (this.session) this.session.active = false;
    this.session = null;
    this.notifyCharacteristic?.removeEventListener?.('characteristicvaluechanged', this.onValueChanged);
    const device = this.device;
    device?.removeEventListener?.('gattserverdisconnected', this.onDisconnected);
    this.device = null; this.server = null; this.writeCharacteristic = null; this.notifyCharacteristic = null;
    // GATT disconnect ends notifications too, without a stopNotifications
    // operation racing an outstanding write on the same GATT server.
    if (device?.gatt?.connected) device.gatt.disconnect();
  }

  close(message = '已断开 BLE') {
    if (!this.device && this.state === 'disconnected') return Promise.resolve();
    this.emit('disconnecting', '正在断开 BLE');
    this.cleanup();
    this.emit('disconnected', message);
    return Promise.resolve();
  }

  disconnect(message) {
    if (this.state === 'connecting') return Promise.reject(new Error('请先关闭设备选择窗口或等待连接结束'));
    return this.close(message);
  }
}
