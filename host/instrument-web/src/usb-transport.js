import { Transport } from './transport.js';

// A USB port opening is not a bridge handshake, and a bridge ACK is not a
// FPGA ACK. Session-tagged envelopes also exclude boot/debug console output.
export class UsbTransport {
  constructor(raw = new Transport(), { timeoutMs = 4000, heartbeatMs = 1000 } = {}) {
    this.raw = raw; this.timeoutMs = timeoutMs; this.heartbeatMs = heartbeatMs;
    this.state = 'disconnected'; this.connected = false;
    this.listeners = new Set(); this.dataListeners = new Set(); this.buffer = '';
    raw.onData(text => this.receive(text));
    raw.onStatus(event => {
      if (event.state === 'disconnected') {
        this.rejectPending(new Error(event.message || 'USB 已断开'));
        clearInterval(this.heartbeat); this.token = null;
        this.emit('disconnected', event.message);
      }
    });
  }
  onStatus(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  onData(fn) { this.dataListeners.add(fn); return () => this.dataListeners.delete(fn); }
  emit(state, message) { this.state = state; this.connected = state === 'connected'; for (const fn of this.listeners) fn({ state, connected: this.connected, message }); }
  rejectPending(error) { const p = this.pending; if (p) { clearTimeout(p.timer); this.pending = null; p.reject(error); } }
  receive(text) {
    for (const char of String(text)) {
      if (char !== '\n') {
        if (!this.discard) {
          if (this.buffer.length >= 600 || (char !== '\r' && (char < ' ' || char > '~'))) { this.discard = true; this.buffer = ''; }
          else this.buffer += char;
        }
        continue;
      }
      const fields = this.discard ? [] : this.buffer.trimEnd().split(','); this.buffer = ''; this.discard = false;
      if (!this.token || fields[0] !== '!USB1' || fields[1] !== this.token) continue;
      if (fields[2] === 'RX' && this.connected && fields.length === 4 && /^(?:[0-9A-F]{2}){1,256}$/.test(fields[3])) {
        const data = Uint8Array.from(fields[3].match(/../g), hex => parseInt(hex, 16));
        for (const fn of this.dataListeners) fn(data);
      } else if (fields[2] === 'ERR') {
        const error = new Error(`USB 桥接拒绝：${fields[3] || 'UNKNOWN'}；请断开其他连接，等待三秒后重连`);
        this.rejectPending(error);
        void this.disconnect(error.message).catch(() => {});
      } else if (this.pending && fields.slice(2).join(',') === this.pending.expected) {
        const p = this.pending; this.pending = null; clearTimeout(p.timer); p.resolve();
      }
    }
  }
  async exchange(command, expected) {
    if (this.pending) throw new Error('USB 请求尚未结束');
    let resolve, reject;
    const reply = new Promise((yes, no) => { resolve = yes; reject = no; });
    // Mark handled immediately, including an unplug while raw.write is pending.
    void reply.catch(() => {});
    const p = { expected, resolve, reject };
    let timer;
    const deadline = new Promise((_, fail) => {
      timer = setTimeout(() => {
        const error = new Error('USB 应答超时，结果未知；请重新连接');
        if (this.pending === p) this.rejectPending(error);
        fail(error);
      }, this.timeoutMs);
    });
    this.pending = p;
    try {
      await Promise.race([Promise.all([this.raw.sendBytes(new TextEncoder().encode(`!USB1,${this.token},${command}\n`)), reply]), deadline]);
    } catch (error) { if (this.pending === p) this.rejectPending(error); throw error; }
    finally { clearTimeout(timer); }
  }
  async connect() {
    if (this.state !== 'disconnected') throw new Error('USB 连接操作尚未结束');
    this.buffer = ''; this.discard = false; this.sequence = 0; this.tail = Promise.resolve(); this.queued = 0;
    this.token = Array.from(crypto.getRandomValues(new Uint8Array(8)), n => n.toString(16).padStart(2, '0')).join('').toUpperCase();
    this.emit('connecting', '请选择 ESP32-S3 USB 串口，正在确认桥接固件');
    try {
      await this.raw.connect({ baudRate: 115200 });
      await this.exchange('OPEN', 'READY');
      this.emit('connected', 'USB 桥接已连接；FPGA 尚未确认');
      this.heartbeat = setInterval(() => {
        if (!this.connected || this.queued || this.pending) return;
        void this.sendHeartbeat();
      }, this.heartbeatMs);
    } catch (error) { await this.disconnect(error.message); throw error; }
  }
  async sendHeartbeat() {
    const token = this.token;
    this.queued++;
    const task = this.tail.then(() => {
      if (!this.connected || this.token !== token) throw new Error('USB 会话已更换');
      return this.exchange('PING', 'PONG');
    });
    this.tail = task.catch(() => {});
    try { await task; } catch (error) { if (this.token === token) await this.disconnect(error.message); }
    finally { if (this.token === token) this.queued--; }
  }
  sendText(text, { newline = true } = {}) { return this.sendBytes(new TextEncoder().encode(text + (newline ? '\n' : ''))); }
  async sendBytes(input) {
    if (!this.connected) throw new Error('请先连接 USB');
    const bytes = new Uint8Array(input);
    if (!bytes.length || bytes.length > 256) throw new Error('USB 桥接每次发送 1..256 字节');
    if (this.queued >= 8) throw new Error('USB 发送队列已满');
    const token = this.token; this.queued++;
    const task = this.tail.then(async () => {
      if (!this.connected || this.token !== token) throw new Error('USB 会话已更换，未发送');
      const sequence = this.sequence++;
      const hex = Array.from(bytes, n => n.toString(16).padStart(2, '0')).join('').toUpperCase();
      await this.exchange(`DATA,${sequence},${hex}`, `OK,${sequence}`);
      if (this.token !== token) throw new Error('USB 会话已断开，发送结果未知');
      return bytes.length;
    });
    this.tail = task.catch(() => {});
    try { return await task; }
    catch (error) { if (this.token === token) void this.disconnect(error.message).catch(() => {}); throw error; }
    finally { if (this.token === token) this.queued--; }
  }
  disconnect(message = 'USB 已断开；不代表停止演奏') {
    if (this.closing) return this.closing;
    clearInterval(this.heartbeat);
    this.emit('disconnecting', '正在关闭 USB');
    this.rejectPending(new Error('USB 会话已关闭'));
    const token = this.token; this.token = null;
    this.closing = (async () => {
      // Best effort only: the ESP also expires ownership after 5 s without a
      // valid heartbeat. Never replay a command when reconnecting.
      if (this.raw.connected && token && !this.queued) {
        let timer;
        await Promise.race([
          this.raw.sendBytes(new TextEncoder().encode(`!USB1,${token},CLOSE\n`)).catch(() => {}),
          new Promise(resolve => { timer = setTimeout(resolve, 100); }),
        ]).finally(() => clearTimeout(timer));
      }
      await this.raw.disconnect();
      this.emit('disconnected', message);
    })().finally(() => { this.closing = null; });
    return this.closing;
  }
}

// Keep DeviceSession, uploader and visualizers attached to one event source.
// Selecting a different physical link is permitted only after cleanup ends.
export class LinkTransport {
  constructor(links, initial = 'ble') {
    this.links = links; this.kind = initial; this.listeners = new Set(); this.dataListeners = new Set();
    for (const [kind, link] of Object.entries(links)) {
      link.onStatus(event => { if (this.kind === kind) for (const fn of this.listeners) fn(event); });
      link.onData(data => { if (this.kind === kind) for (const fn of this.dataListeners) fn(data); });
    }
  }
  get current() { return this.links[this.kind]; }
  get state() { return this.current.state; }
  get connected() { return this.current.connected; }
  onStatus(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  onData(fn) { this.dataListeners.add(fn); return () => this.dataListeners.delete(fn); }
  select(kind) {
    if (!this.links[kind] || this.state !== 'disconnected') throw new Error('请先断开当前连接');
    this.kind = kind;
    for (const fn of this.listeners) fn({ state: 'disconnected', connected: false, message: '连接方式已切换，请连接并重新确认设备' });
  }
  connect(config) { return this.current.connect(config); }
  disconnect() { return this.current.disconnect(); }
  sendBytes(bytes) { return this.current.sendBytes(bytes); }
  sendText(text, options) { return this.current.sendText(text, options); }
}
