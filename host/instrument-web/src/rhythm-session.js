import { performanceRequest, rhythmRequest, parsePerformanceLine } from './performance-protocol.js';

// Owns the link for a complete hardware practice session. Attacks happen on
// the FPGA; these reports advance the score, never measure BLE timing as skill.
export class RhythmSession {
  constructor(device, { timeoutMs = 2000, pollMs = 100, onStatus = () => {}, onError = () => {} } = {}) {
    this.device = device; this.transport = device.transport;
    this.timeoutMs = timeoutMs; this.pollMs = pollMs; this.onStatus = onStatus; this.onError = onError;
    this.release = null; this.pending = null; this.buffer = ''; this.running = false;
    this.cue = 0; this.mask = 0; this.seen = 0; this.previousMap = null;
    this.unsubs = [this.transport.onData(data => this.receive(data)), device.onChange(s => {
      if (this.release && (!s.connected || s.blocked)) this.fail(Error('跟练连接已断开；请重连后重新开始'), false);
    })];
  }
  fail(error, uncertain = true) {
    clearTimeout(this.timer); this.running = false;
    const p = this.pending; this.pending = null; clearTimeout(p?.timer); p?.reject(error);
    const release = this.release; this.release = null; release?.({uncertain});
    this.onError(error);
  }
  request(operation, value) {
    if (!this.release || this.pending) return Promise.reject(Error('实体跟练会话未就绪或有命令未完成'));
    const id = crypto.getRandomValues(new Uint32Array(1))[0].toString(16).toUpperCase().padStart(8, '0');
    const line = operation < 6 ? performanceRequest(id, operation, value) : rhythmRequest(id, operation === 7 ? {poll: true} : value);
    const promise = new Promise((resolve, reject) => {
      const p = {id, operation, resolve, reject, written: false, reply: null}; this.pending = p;
      p.timer = setTimeout(() => this.fail(Error('FPGA 未确认实体跟练；请检查配套固件并重新连接')), this.timeoutMs);
      Promise.resolve().then(() => this.transport.sendText(line, {newline: false})).then(() => {
        if (this.pending === p) { p.written = true; this.finish(); }
      }, () => { if (this.pending === p) this.fail(Error('跟练发送失败；请重新连接')); });
    });
    this.inflight = promise;
    return promise;
  }
  finish() {
    const p = this.pending;
    if (!p?.written || !p.reply) return;
    clearTimeout(p.timer); this.pending = null;
    if (p.reply.status >= 2) p.reject(Error(p.reply.status === 2 ? '设备忙：请退出设置、松开全部压力键后再试' : '设备拒绝跟练命令，请检查配套固件'));
    else p.resolve(p.reply);
  }
  receive(data) {
    if (!this.release) return;
    const text = data instanceof Uint8Array ? new TextDecoder().decode(data) : String(data);
    for (const ch of text) {
      if (!this.release) return;
      if (ch !== '\n') {
        if (ch === '\r') continue;
        if (ch < ' ' || ch > '~' || this.buffer.length >= 254) { this.fail(Error('跟练回传行损坏，请重连')); return; }
        this.buffer += ch; continue;
      }
      const line = this.buffer; this.buffer = '';
      if (!this.pending) continue;
      if (['ERR,COMMAND', 'ERR,LINE'].includes(line)) { this.fail(Error('此 FPGA 固件不支持实体跟练，请更新配套位流'), false); return; }
      if (!line.startsWith(`PERF1,${this.pending.id},`)) continue;
      try {
        const reply = parsePerformanceLine(line);
        if (reply?.type === 'ack' && reply.operation === this.pending.operation) { this.pending.reply = reply; this.finish(); }
      } catch (error) { this.fail(error); }
    }
  }
  async open(pitches) {
    if (this.opening || this.release || this.closing) throw Error('上一轮跟练尚未结束');
    this.opening = this.prepare(pitches);
    try { await this.opening; } finally { this.opening = null; }
  }
  async prepare(pitches) {
    try {
      if (!this.device.snapshot().identity) await this.device.request('HELLO');
      await this.device.request('STOP'); // stop auto-play before taking exclusive ownership
      this.release = this.device.acquireExclusive(); this.buffer = '';
      await this.request(7); // Capability probe; no fallback to fake local success.
      await this.request(6, {});
      this.previousMap = await this.request(0);
      await this.request(1, pitches);
      this.cue = (this.cue + 1) >>> 0; this.mask = 0; this.seen = 0;
      const reply = await this.request(6, {enabled: true, cue: this.cue, mask: 0});
      if (!reply.active || !reply.guard || reply.cue !== this.cue) throw Error('FPGA 未进入实体跟练');
      this.running = true;
    } catch (error) {
      // A known rejection can still be cleaned up. Unknown transport outcomes
      // have already released/blocked the device and must never auto-replay.
      if (this.release) await this.cleanup().catch(() => {});
      throw error;
    }
  }
  async setCue(mask) {
    if (!this.running || this.pending || this.closing) return false;
    clearTimeout(this.timer);
    this.cue = (this.cue + 1) >>> 0; this.mask = mask; this.seen = 0;
    try {
      const reply = await this.request(6, {enabled: true, cue: this.cue, mask});
      if (this.running) { this.accept(reply); this.schedule(); }
      return true;
    } catch (error) { if (this.release) this.fail(error); return false; }
  }
  accept(reply) {
    if (!reply.guard || !reply.active) throw Error('FPGA 已停止跟练（菜单、曲目切换或通信超时），请重新开始');
    if (reply.cue !== this.cue || (reply.hits & ~this.mask) || (reply.guide & ~this.mask)) throw Error('跟练提示与板端状态不一致');
    const newHits = reply.hits & ~this.seen; this.seen |= reply.hits;
    this.onStatus({...reply, newHits});
  }
  schedule() {
    clearTimeout(this.timer);
    if (!this.running || this.closing) return;
    this.timer = setTimeout(async () => {
      try { const r = await this.request(7); if (this.running) this.accept(r); }
      catch (error) { if (this.release) this.fail(error); }
      this.schedule();
    }, this.pollMs);
  }
  async cleanup() {
    if (!this.release) return;
    try {
      await this.request(6, {});
      // Stop inhibits already-held keys. Wait for release before restoring the
      // user's previous mapping, otherwise a sounding key would change pitch.
      const deadline = Date.now() + 4000;
      while ((await this.request(7)).keys) {
        if (Date.now() >= deadline) throw Error('跟练已停止；请松开压力键并在演奏设置恢复键位');
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      if (this.previousMap) await this.request(this.previousMap.status === 1 ? 1 : 2, this.previousMap.notes);
      this.previousMap = null;
      const release = this.release; this.release = null; release?.();
    } catch (error) { if (this.release) this.fail(error); throw error; }
  }
  close() {
    if (this.closing) return this.closing;
    this.running = false; clearTimeout(this.timer);
    this.closing = (async () => {
      if (this.opening) await this.opening.catch(() => {});
      this.running = false;
      if (this.pending) await this.inflight.catch(() => {});
      await this.cleanup();
    })().finally(() => { this.closing = null; });
    return this.closing;
  }
  dispose() { void this.close().finally(() => this.unsubs.forEach(fn => fn())).catch(() => {}); }
}
