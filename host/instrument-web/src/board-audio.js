import { crc16Ccitt } from './protocol.js';

export const BOARD_AUDIO = Object.freeze({ sampleRate: 48000, samples: 1024, blocks: 32, pairsPerBlock: 32 });
const hex = (value, width) => value.toString(16).toUpperCase().padStart(width, '0');
const crc = body => hex(crc16Ccitt(new TextEncoder().encode(body)), 4);
export function scopeRequest(id) {
  if (!/^[0-9A-F]{8}$/.test(id)) throw new Error('采样请求编号无效');
  const body = `SCOPE1,${id}`;
  return `${body},${crc(body)}\n`;
}
export function parseScopeBlock(line) {
  const match = /^SCOPE1,([0-9A-F]{8}),([0-9A-F]{2}),([0-9A-F]{128}),([0-9A-F]{4})$/.exec(line);
  if (!match || +`0x${match[2]}` >= BOARD_AUDIO.blocks || crc(line.slice(0, -5)) !== match[4]) return null;
  const bytes = Uint8Array.from(match[3].match(/../g), value => parseInt(value, 16));
  return { id: match[1], index: parseInt(match[2], 16), bytes };
}

// One read-only snapshot owns the existing link. No background unsolicited
// stream: uploads and legacy requests must acquire the same exclusive token.
export class BoardAudioSession {
  constructor(device, { timeoutMs = 12000 } = {}) {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error('采样超时无效');
    this.device = device; this.transport = device.transport; this.timeoutMs = timeoutMs;
    this.listeners = new Set(); this.pending = null; this.frame = null; this.unsupported = false;
    this.message = '等待从 FPGA 抓取音频'; this.buffer = ''; this.closed = false;
    this.unsubscribers = [this.transport.onData(data => this.receive(data)), device.onChange(state => {
      if (!state.connected || state.blocked) {
        this.frame = null; this.buffer = '';
        if (!state.connected) this.unsupported = false;
        this.fail(new Error('连接不可用，采样已取消；请重连'), true);
        this.emit();
      }
    })];
  }
  snapshot() { return { busy: Boolean(this.pending), frame: this.frame, unsupported: this.unsupported, message: this.message, blocks: this.pending?.next || 0 }; }
  onChange(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  emit() { for (const fn of this.listeners) fn(this.snapshot()); }
  fail(error, uncertain = true) { if (this.pending) this.settle(error, null, uncertain); }
  settle(error, frame, uncertain = false) {
    const p = this.pending;
    if (!p) return;
    clearTimeout(p.timer); this.pending = null; this.buffer = '';
    this.frame = frame;
    this.message = error ? error.message : '已收到 FPGA 真实音频快照';
    p.release({ uncertain }); this.emit();
    error ? p.reject(error) : p.resolve(frame);
  }
  complete() {
    const p = this.pending;
    if (!p?.written || p.next !== BOARD_AUDIO.blocks) return;
    this.settle(null, { id: p.id, dry: p.dry, wet: p.wet, sampleRate: BOARD_AUDIO.sampleRate, receivedAt: Date.now() });
  }
  receive(data) {
    if (!this.pending) return;
    const text = data instanceof Uint8Array ? Array.from(data, b => String.fromCharCode(b)).join('') : String(data);
    for (const char of text) {
      const p = this.pending;
      if (!p) return;
      if (char !== '\n') {
        if (this.buffer.length >= 255 || char < ' ' || char > '~') { this.fail(new Error('采样行格式错误，请断开重连')); return; }
        this.buffer += char; continue;
      }
      const line = this.buffer; this.buffer = '';
      // Older FPGA images route this longer command to the legacy line checker.
      if (['ERR,COMMAND', 'ERR,LINE'].includes(line) && p.next === 0) {
        this.unsupported = true;
        this.fail(new Error('当前 FPGA 固件不支持音频回传，需要更新位流；歌曲功能仍可使用'), false); return;
      }
      if (!line.startsWith(`SCOPE1,${p.id},`)) continue; // An old ID can never complete this capture.
      const block = parseScopeBlock(line);
      if (!block || block.index !== p.next) { this.fail(new Error('采样校验失败或分段缺失，请断开重连')); return; }
      for (let i = 0; i < BOARD_AUDIO.pairsPerBlock; i++) {
        const signed = value => (value > 127 ? value - 256 : value) / 128;
        const offset = block.index * BOARD_AUDIO.pairsPerBlock + i;
        p.dry[offset] = signed(block.bytes[i * 2]); p.wet[offset] = signed(block.bytes[i * 2 + 1]);
      }
      p.next++; this.message = `接收 FPGA 音频 ${p.next} / ${BOARD_AUDIO.blocks} 段`; this.emit(); this.complete();
    }
  }
  capture() {
    if (this.closed) return Promise.reject(new Error('采样会话已关闭'));
    if (this.pending) return Promise.reject(new Error('上一采样尚未完成'));
    if (this.unsupported) return Promise.reject(new Error('请先更新支持 SCOPE1 的 FPGA 位流'));
    let release;
    try { release = this.device.acquireExclusive(); } catch (error) { return Promise.reject(error); }
    const id = hex(crypto.getRandomValues(new Uint32Array(1))[0], 8);
    this.frame = null; this.buffer = ''; this.message = '等待 FPGA 采集与完整回传';
    return new Promise((resolve, reject) => {
      const p = { id, release, resolve, reject, next: 0, written: false,
        dry: new Float32Array(BOARD_AUDIO.samples), wet: new Float32Array(BOARD_AUDIO.samples) };
      this.pending = p;
      p.timer = setTimeout(() => this.fail(new Error('采样应答超时，请断开重连')), this.timeoutMs);
      this.emit();
      try {
        Promise.resolve(this.transport.sendText(scopeRequest(id), { newline: false })).then(() => {
          if (this.pending === p) { p.written = true; this.complete(); }
        }, () => { if (this.pending === p) this.fail(new Error('采样请求发送失败，请断开重连')); });
      } catch { if (this.pending === p) this.fail(new Error('采样请求发送失败，请断开重连')); }
    });
  }
  dispose() {
    this.closed = true; this.fail(new Error('采样会话已关闭'));
    this.unsubscribers.forEach(fn => fn()); this.listeners.clear();
  }
}

// Radix-2 FFT of actual wet samples, with a Hann window and amplitude-corrected
// dBFS. 1024 samples at 48 kHz => 46.875 Hz bins, not inferred score harmonics.
export function boardSpectrum(samples) {
  const n = samples.length;
  if (n !== BOARD_AUDIO.samples) throw new Error('需要完整的 1024 点采样');
  const re = new Float64Array(n), im = new Float64Array(n);
  let windowSum = 0;
  for (let i = 0; i < n; i++) {
    const w = .5 - .5 * Math.cos(2 * Math.PI * i / (n - 1));
    re[i] = samples[i] * w; windowSum += w;
  }
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) [re[i], re[j]] = [re[j], re[i]];
  }
  for (let size = 2; size <= n; size *= 2) {
    for (let start = 0; start < n; start += size) {
      for (let k = 0; k < size / 2; k++) {
        const angle = -2 * Math.PI * k / size, c = Math.cos(angle), s = Math.sin(angle);
        const a = start + k, b = a + size / 2;
        const r = re[b] * c - im[b] * s, m = re[b] * s + im[b] * c;
        re[b] = re[a] - r; im[b] = im[a] - m; re[a] += r; im[a] += m;
      }
    }
  }
  return Float32Array.from({ length: n / 2 + 1 }, (_, i) =>
    Math.max(-96, 20 * Math.log10(Math.max(1e-9, Math.hypot(re[i], im[i]) * (i && i !== n / 2 ? 2 : 1) / windowSum))));
}
