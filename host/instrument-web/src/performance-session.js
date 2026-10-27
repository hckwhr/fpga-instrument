import { performanceRequest, parsePerformanceLine, decodeRecordingBlock, recordingWav, RECORDING } from './performance-protocol.js';

// One exclusive lease covers a command or a whole recording. No optimistic
// hardware state, automatic command replay, or conversion of missing PCM to silence.
export class PerformanceSession {
  constructor(device, { timeoutMs = 4000, leaseMs = 1000 } = {}) {
    this.device = device; this.transport = device.transport; this.timeoutMs = timeoutMs; this.leaseMs = leaseMs;
    this.listeners = new Set(); this.pending = null; this.take = null; this.release = null;
    this.capability = null; this.message = '连接后检查演奏扩展功能'; this.buffer = ''; this.saved = null; this.disposed = false;
    this.unsubs = [this.transport.onData(data => this.receive(data)), this.device.onChange(state => {
      if (!state.connected || state.blocked) { this.capability = null; this.abort(new Error('连接已断开或状态未知；录音未完成'), false); this.emit(); }
    })];
  }
  snapshot() { return { busy: Boolean(this.release), recording: Boolean(this.take), stopping: Boolean(this.take?.stopping),
    seconds: (this.take?.blocks.length || 0) / 50, capability: this.capability, message: this.message, saved: this.saved }; }
  onChange(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  emit() { for (const fn of this.listeners) fn(this.snapshot()); }
  unlock(uncertain = false) { const fn = this.release; this.release = null; fn?.({uncertain}); }
  abort(error, uncertain = true) {
    if (!this.release && !this.take && !this.pending) return;
    const p = this.pending; this.pending = null;
    clearTimeout(p?.timer); clearTimeout(this.take?.timer); clearInterval(this.take?.lease);
    this.take = null; this.buffer = ''; this.message = error.message;
    this.unlock(uncertain); p?.reject(error); this.emit();
  }
  async command(operation, notes) {
    if (this.disposed) throw new Error('演奏会话已关闭');
    if (this.release) throw new Error('演奏操作尚未结束');
    const id = crypto.getRandomValues(new Uint32Array(1))[0].toString(16).toUpperCase().padStart(8,'0');
    const line = performanceRequest(id, operation, notes);
    this.release = this.device.acquireExclusive(); this.buffer = '';
    this.message = '等待 FPGA 确认'; this.emit();
    return new Promise((resolve, reject) => {
      const pending = {id, operation, resolve, reject, written: false, reply: null, early: []}; this.pending = pending;
      pending.timer = setTimeout(() => this.abort(new Error('设备未确认演奏功能；请重连并检查配套固件')), this.timeoutMs);
      Promise.resolve().then(() => this.transport.sendText(line, {newline: false})).then(() => {
        if (this.pending === pending) { pending.written = true; this.finishCommand(); }
      }, () => { if (this.pending === pending) this.abort(new Error('命令发送失败；请重连')); });
    });
  }
  finishCommand() {
    const p = this.pending;
    if (!p?.written || !p.reply) return;
    clearTimeout(p.timer); this.pending = null;
    const r = p.reply;
    if (r.status >= 2) {
      this.message = r.status === 2 ? '设备忙：请松开所有实体键，并结束其他操作后再试' : '设备拒绝了演奏命令';
      this.unlock(); p.reject(new Error(this.message)); this.emit(); return;
    }
    if (p.operation <= 2) {
      this.capability = {custom: r.status === 1, notes: r.notes};
      this.message = p.operation === 0 ? '已读取 FPGA 实际键位设置' : p.operation === 2 ? '已恢复板端默认键阶' : '12 键映射已在 FPGA 生效';
      this.unlock();
    } else if (p.operation === 3) {
      // Keep previous saved recording until this take successfully completes.
      this.take = {id: p.id, blocks: [], predictor: 0, index: 0, stopping: false, writtenStop: false, ended: null};
      this.message = '正在接收 FPGA 演奏录音';
      this.armDataTimeout();
      this.take.lease = setInterval(() => {
        if (this.take && !this.take.stopping) void this.writeLive(5).catch(() => {});
      }, this.leaseMs);
    }
    p.resolve(r); this.emit();
    if (p.early.length) this.receive(p.early.join('\n') + '\n');
  }
  armDataTimeout() {
    if (!this.take) return;
    clearTimeout(this.take.timer);
    this.take.timer = setTimeout(() => this.abort(new Error('录音回传中断；本次未保存为完整录音，请重连')), this.timeoutMs);
  }
  async writeLive(operation) {
    const take = this.take;
    if (!take) return;
    try { await this.transport.sendText(performanceRequest(take.id, operation), {newline: false}); }
    catch { if (this.take === take) this.abort(new Error('录音控制发送失败；请重连')); throw new Error('发送失败'); }
  }
  async stop() {
    const take = this.take;
    if (!take || take.stopping) return;
    take.stopping = true; clearInterval(take.lease); this.message = '等待 FPGA 完成本段录音'; this.emit();
    await this.writeLive(4);
    if (this.take === take) { take.writtenStop = true; this.finishRecording(); }
  }
  finishRecording() {
    const take = this.take;
    if (!take?.ended || (take.stopping && !take.writtenStop)) return;
    const end = take.ended;
    if (end.count !== take.blocks.length || !end.count || ![0,3].includes(end.status)) {
      const errors = {1:'录音缓冲溢出',2:'录音连接续租超时',4:'板端采集时序错误'};
      this.abort(new Error(`${errors[end.status] || '录音段数不一致或没有音频'}；本次未保存为完整录音`)); return;
    }
    clearTimeout(take.timer); clearInterval(take.lease);
    this.saved = {bytes: recordingWav(take.blocks), seconds: end.count / 50, created: Date.now()};
    this.take = null; this.message = `已收回 ${this.saved.seconds.toFixed(2)} 秒真实演奏${end.status === 3 ? ' · 已达到 60 秒上限' : ''}`;
    this.unlock(); this.emit();
  }
  receive(data) {
    if (!this.release) return;
    const text = data instanceof Uint8Array ? new TextDecoder().decode(data) : String(data);
    for (const char of text) {
      if (!this.release) return;
      if (char !== '\n') {
        if (char < ' ' || char > '~' || this.buffer.length >= 254) { this.abort(new Error('演奏回传行损坏；请重连')); return; }
        this.buffer += char; continue;
      }
      const line = this.buffer; this.buffer = '';
      if (this.pending && ['ERR,COMMAND','ERR,LINE'].includes(line)) {
        this.capability = null; this.abort(new Error('当前 FPGA 固件尚不支持键位设置和录音，请更新配套位流'), false); return;
      }
      const id = this.take?.id || this.pending?.id;
      if (!id || !line.startsWith(`PERF1,${id},`)) continue;
      if (this.pending?.operation === 3 && this.pending.reply && !this.pending.written) {
        if (this.pending.early.length >= 8) { this.abort(new Error('开始命令尚未完成，录音数据已超出等待窗口')); return; }
        this.pending.early.push(line); continue;
      }
      try {
        const r = parsePerformanceLine(line);
        if (!r) continue;
        if (this.pending && r.type === 'ack' && r.operation === this.pending.operation) {
          this.pending.reply = r; this.finishCommand();
        } else if (this.take && r.type === 'data') {
          const take = this.take;
          if (r.sequence !== take.blocks.length || take.blocks.length >= RECORDING.maxBlocks || r.predictor !== take.predictor || r.index !== take.index) throw new Error('录音丢段、重复或预测状态不连续');
          const decoded = decodeRecordingBlock(r); take.blocks.push(decoded.pcm);
          take.predictor = decoded.predictor; take.index = decoded.index; this.armDataTimeout();
          if (take.blocks.length % 5 === 0) this.emit();
        } else if (this.take && r.type === 'end') { this.take.ended = r; this.finishRecording(); }
        else if (this.take && r.type === 'ack' && [4,5].includes(r.operation) && r.status >= 2) throw new Error('设备拒绝录音控制');
      } catch (error) { this.abort(new Error(`${error.message}；本次未保存为完整录音`)); return; }
    }
  }
  dispose() { this.disposed = true; this.abort(new Error('演奏页面已关闭')); this.unsubs.forEach(fn => fn()); this.listeners.clear(); }
}
