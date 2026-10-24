import { normalizeUuid, NUS_UUIDS } from './ble-transport.js';
// Same contract as BleTransport; Android uses its real GATT stack rather than
// Web Bluetooth (which Android WebView does not implement).
export class NativeBleTransport {
  constructor(bridge) {
    this.bridge = bridge; this.connected = false; this.state = 'disconnected';
    this.listeners = new Set(); this.dataListeners = new Set(); this.session = null; this.sequence = 0;
    this.unsubscribe = bridge.subscribe(message => {
      if (!this.session || message.sessionId !== this.session.id) return;
      if (message.type === 'ble-data' && this.connected) {
        const bytes = Uint8Array.from(atob(message.data), c => c.charCodeAt(0));
        for (const listener of this.dataListeners) listener(bytes);
      } else if (message.type === 'ble-disconnected') {
        this.session.active = false;
        this.emit('disconnected', message.message || 'BLE 已断开');
      }
    });
  }
  onStatus(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  onData(fn) { this.dataListeners.add(fn); return () => this.dataListeners.delete(fn); }
  emit(state, message) { this.state = state; this.connected = state === 'connected'; for (const fn of this.listeners) fn({ state, connected: this.connected, message }); }
  async connect(config = {}) {
    if (this.state !== 'disconnected') throw new Error('连接操作尚未结束');
    const uuids = { serviceUuid: normalizeUuid(config.serviceUuid ?? NUS_UUIDS.service), writeUuid: normalizeUuid(config.writeUuid ?? NUS_UUIDS.write), notifyUuid: normalizeUuid(config.notifyUuid ?? NUS_UUIDS.notify) };
    const session = { id: String(++this.sequence), active: true, tail: Promise.resolve(), pending: 0 };
    this.session = session;
    this.emit('connecting', '正在扫描行者无疆，请在 App 中选择设备');
    try {
      const result = await this.bridge.request('ble-connect', { ...config, ...uuids, sessionId: session.id });
      this.check(session);
      this.emit('connected', `BLE 已连接：${result.name}；尚未确认 FPGA`);
    } catch (error) {
      if (this.session === session && session.active) await this.disconnect().catch(() => {});
      throw error;
    }
  }
  check(session) { if (!session.active || this.session !== session) throw new Error('BLE 会话已断开或更换'); }
  sendBytes(input) {
    if (!this.connected) return Promise.reject(new Error('请先连接 BLE'));
    const bytes = new Uint8Array(input);
    if (!bytes.length || bytes.length > 4096) return Promise.reject(new Error('发送长度须为 1..4096 字节'));
    const session = this.session;
    if (session.pending >= 64) return Promise.reject(new Error('BLE 发送队列已满'));
    session.pending++;
    const task = session.tail.then(async () => {
      this.check(session);
      try {
        await this.bridge.request('ble-write', { data: btoa(String.fromCharCode(...bytes)), sessionId: session.id });
        this.check(session);
        return bytes.length;
      } catch (error) {
        if (this.session === session && session.active) await this.disconnect().catch(() => {});
        throw error;
      }
    }).finally(() => session.pending--);
    session.tail = task.catch(() => {}); return task;
  }
  sendText(text, { newline = true } = {}) { return this.sendBytes(new TextEncoder().encode(text + (newline ? '\n' : ''))); }
  async disconnect() {
    const session = this.session;
    if (this.state === 'disconnected') return;
    if (session) session.active = false;
    this.emit('disconnecting', '正在断开 BLE');
    try { await this.bridge.request('ble-disconnect'); }
    finally { if (this.session === session) this.emit('disconnected', '已断开 BLE；不代表停止演奏'); }
  }
}
