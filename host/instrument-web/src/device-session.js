// Matches stage42 rtl/hc05_link.v exactly. HC05 is the legacy wire-protocol
// name, not a claim about which radio carried the reply (V3 uses S3 BLE).
export function parseDeviceReply(line) {
  if (line === 'PONG') return { type: 'PING' };
  if (line === 'OK,HC05,1,9600,8N1,DEMO=TWINKLE+ODE') {
    return { type: 'HELLO', protocol: 'HC05', version: 1, baudRate: 9600,
      songs: ['TWINKLE', 'ODE'], upload: false };
  }
  const ack = /^OK,(PLAY|STOP)$/.exec(line);
  if (ack) return { type: ack[1] };
  const error = /^ERR,(BUSY|FRAME|LINE|LOCAL|TIMEOUT|COMMAND)$/.exec(line);
  if (error) return { type: 'error', code: error[1] };
  const mode = /^STATUS,(SETTING|MANUAL)$/.exec(line);
  if (mode) return { type: 'STATUS', mode: mode[1] };
  const progress = /^STATUS,(PLAYING|STOPPED),(\d{3,4})\/(\d{3,4})$/.exec(line);
  if (progress && +progress[2] <= 2048 && +progress[3] > 0 && +progress[3] <= 2048 && +progress[2] <= +progress[3]) {
    return { type: 'STATUS', mode: progress[1], position: +progress[2], total: +progress[3] };
  }
  return null;
}

const ERRORS = {
  BUSY: '设备忙，请等待后重新查询', FRAME: '设备报告 UART 帧错误',
  LINE: '设备报告命令格式错误', LOCAL: '板载设置或停止键阻止了播放',
  TIMEOUT: '设备报告接收超时', COMMAND: '设备不支持此命令',
};

export class DeviceSession {
  constructor(transport, { timeoutMs = 3000 } = {}) {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error('应答超时设置无效');
    this.transport = transport;
    this.timeoutMs = timeoutMs;
    this.listeners = new Set();
    this.pending = null;
    this.identity = null;
    this.report = null;
    this.rawUsed = false;
    this.rawBusy = false;
    this.exclusive = null;
    this.blocked = false;
    this.epoch = 0;
    this.resetReceiver();
    this.message = '尚未识别板端协议';
    this.unsubscribers = [transport.onData(data => this.receive(data)), transport.onStatus(s => {
      if (s.state === 'connected') {
        this.blocked = false; this.rawUsed = false;
        this.message = '链路已连接，请点击“识别设备”';
      } else {
        this.epoch++; this.exclusive = null;
        this.resetReceiver(); this.identity = null; this.report = null; this.rawBusy = false;
        this.finish(new Error('连接已断开，执行结果未知'));
        this.message = '板端状态未知；断开通信不代表停止演奏';
      }
      this.emit();
    })];
  }
  resetReceiver() { this.buffer = ''; this.discard = false; this.decoder = new TextDecoder(); }
  onChange(listener) { this.listeners.add(listener); return () => this.listeners.delete(listener); }
  snapshot() {
    return { connected: this.transport.connected, busy: Boolean(this.pending) || this.rawBusy || Boolean(this.exclusive),
      blocked: this.blocked || this.rawUsed, blockedWrites: this.blocked, identity: this.identity, report: this.report, message: this.message };
  }
  emit() { for (const listener of this.listeners) listener(this.snapshot()); }
  acquireExclusive() {
    if (!this.transport.connected) throw new Error('请先连接设备');
    if (this.blocked || this.rawUsed) throw new Error('请断开并重新连接后识别设备');
    if (this.pending || this.rawBusy || this.exclusive) throw new Error('正在等待上一条应答或上传完成');
    const token = {};
    this.exclusive = token;
    this.emit();
    return ({ uncertain = false } = {}) => {
      if (this.exclusive !== token) return;
      this.exclusive = null;
      if (uncertain) {
        this.blocked = true; this.identity = null; this.report = null;
        this.message = '上传通信结果未知；请断开重连后重新确认设备';
      }
      // Discard a partial legacy response received during exclusive upload.
      if (this.buffer.length) { this.buffer = ''; this.discard = true; }
      this.emit();
    };
  }
  receive(data) {
    if (!this.transport.connected || this.blocked || this.rawUsed) return;
    const text = data instanceof Uint8Array ? this.decoder.decode(data, { stream: true }) : String(data);
    for (const char of text) {
      if (char === '\n') {
        const line = this.buffer.endsWith('\r') ? this.buffer.slice(0, -1) : this.buffer;
        const reply = this.discard ? null : parseDeviceReply(line);
        this.buffer = ''; this.discard = false;
        // No unsolicited or mismatched response can satisfy another command.
        if (reply && this.pending && !this.pending.reply && (reply.type === this.pending.command || reply.type === 'error')) {
          this.pending.reply = reply;
          this.completeIfReady();
        }
      } else if (!this.discard) {
        if (this.buffer.length >= 128 || (char !== '\r' && (char < ' ' || char > '~'))) {
          this.buffer = ''; this.discard = true;
        } else this.buffer += char;
      }
    }
  }
  completeIfReady() {
    const p = this.pending;
    if (!p?.written || !p.reply) return;
    if (p.reply.type === 'error') {
      this.report = null;
      this.finish(new Error(ERRORS[p.reply.code]));
      return;
    }
    if (p.command === 'HELLO') {
      this.identity = p.reply;
      this.message = '已识别内置曲目控制协议；整曲上传能力请另点“检查上传能力”确认';
    } else if (p.command === 'STATUS') {
      this.report = p.reply;
      this.message = '已收到设备状态；显示的是最近一次查询结果';
    } else if (p.command === 'PING') this.message = '已收到 PONG；这不是歌曲上传确认';
    else {
      // ACK means the request was accepted, not proof of analog audio output
      // or an exact playback position. Only STATUS carries those mode fields.
      this.report = null;
      this.message = `设备已确认 ${p.command} 请求；可查询板端当前状态`;
    }
    this.finish(null, p.reply);
  }
  finish(error, reply) {
    const p = this.pending;
    if (!p) return;
    clearTimeout(p.timer); this.pending = null;
    if (error) { this.message = error.message; p.reject(error); }
    else p.resolve(reply);
    this.emit();
  }
  request(command) {
    if (!['HELLO', 'PING', 'STATUS', 'PLAY', 'STOP'].includes(command)) return Promise.reject(new Error('不支持的短命令'));
    if (!this.transport.connected) return Promise.reject(new Error('请先连接设备'));
    if (this.blocked || this.rawUsed) return Promise.reject(new Error('请断开并重新连接后识别设备'));
    if (this.pending || this.rawBusy || this.exclusive) return Promise.reject(new Error('正在等待上一条应答或上传完成'));
    if (['PLAY', 'STOP', 'STATUS'].includes(command) && !this.identity) return Promise.reject(new Error('请先识别设备协议'));
    // Discard the remainder of any old partial line at the next LF.
    if (this.buffer.length) { this.buffer = ''; this.discard = true; }
    return new Promise((resolve, reject) => {
      const p = { command, resolve, reject, written: false, reply: null };
      this.pending = p;
      this.message = `等待设备应答：${command}`;
      p.timer = setTimeout(() => {
        if (this.pending !== p) return;
        // Protocol v1 has no sequence ID. Never retry PLAY or accept a late
        // response as the ACK to a new command after a timeout.
        this.blocked = true; this.identity = null; this.report = null;
        this.finish(new Error(`${command} 应答超时，执行结果未知；请重连后重新识别`));
      }, this.timeoutMs);
      this.emit();
      try {
        Promise.resolve(this.transport.sendText(command)).then(() => {
          if (this.pending !== p) return;
          p.written = true; this.completeIfReady();
        }, error => this.writeFailed(p, error));
      } catch (error) { this.writeFailed(p, error); }
    });
  }
  writeFailed(p, error) {
    if (this.pending !== p) return;
    this.blocked = true; this.identity = null; this.report = null;
    this.finish(new Error(`命令发送失败：${error.message}；请重连，执行结果未知`));
  }
  async sendRaw(text, options) {
    if (!this.transport.connected) throw new Error('请先连接设备');
    if (this.blocked) throw new Error('通信结果未知，请断开重连后再发送');
    if (this.pending || this.rawBusy || this.exclusive) throw new Error('正在等待上一条应答或发送完成');
    this.rawUsed = true; this.identity = null; this.report = null; this.rawBusy = true;
    this.message = '调试收发模式；使用板端控制前请断开重连，避免旧应答混入';
    const epoch = this.epoch;
    this.emit();
    try { return await this.transport.sendText(text, options); }
    finally { if (this.epoch === epoch) { this.rawBusy = false; this.emit(); } }
  }
  dispose() {
    this.blocked = true;
    this.finish(new Error('板端会话已关闭'));
    this.unsubscribers.forEach(unsubscribe => unsubscribe()); this.listeners.clear();
  }
}
