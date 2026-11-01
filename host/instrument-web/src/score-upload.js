import { encodeScoreRequest, parseScoreReply, prepareScoreUpload, supportsScoreAbi } from './score-upload-protocol.js';

// 上传会话独占传输通道：能力查询、分块上传、提交及取消共用事务编号。
// BLE/USB 写入完成只表示链路接收，必须匹配 FPGA 应答才能推进进度。
// 断线使会话失效，不推断板端已停止，也不自动重放播放命令。

function sessionId() {
  return Array.from(crypto.getRandomValues(new Uint8Array(8)), b => b.toString(16).padStart(2, '0')).join('').toUpperCase();
}

// One stop-and-wait transaction owns the transport, including CAPS and ABORT.
// All success states require both a completed write and the numbered FPGA ACK.
export class ScoreUploadSession {
  constructor(device, { timeoutMs = 3000, writeTimeoutMs = 5000, retries = 2 } = {}) {
    if (![timeoutMs, writeTimeoutMs].every(n => Number.isFinite(n) && n > 0) || !Number.isInteger(retries) || retries < 0 || retries > 5) throw new Error('上传超时或重试设置无效');
    this.device = device; this.transport = device.transport;
    this.timeoutMs = timeoutMs; this.writeTimeoutMs = writeTimeoutMs; this.retries = retries;
    this.listeners = new Set(); this.pending = null; this.busy = false; this.capability = null;
    this.phase = 'idle'; this.message = '尚未检查整曲上传能力'; this.confirmedWords = 0;
    this.totalWords = 0; this.buffer = ''; this.discard = false; this.epoch = 0;
    this.startedAt = 0; this.finishedAt = 0; this.retryCount = 0; this.ackCount = 0; this.ackMs = 0;
    this.sessionValid = false; this.playback = null; this.playbackUpdatedAt = 0; this.closed = false;
    this.unsubscribers = [this.transport.onData(data => this.receive(data)), device.onChange(s => {
      if (!s.connected || s.blocked) {
        this.capability = null;
        this.sessionValid = false; this.playback = null;
        if (!s.connected) { this.epoch++; this.buffer = ''; this.discard = false; }
        this.settle(new Error('连接不可用，上传结果未知；请重连'));
        if (!this.busy && this.phase !== 'unknown') { this.phase = 'idle'; this.message = '请连接设备并检查上传能力；断线不代表停止演奏'; }
        this.emit();
      }
    })];
  }
  snapshot() {
    const elapsedMs = this.startedAt ? Math.max(0, (this.finishedAt || performance.now()) - this.startedAt) : 0;
    return { busy: this.busy, phase: this.phase, capability: this.capability, playback: this.playback, playbackUpdatedAt: this.playback ? this.playbackUpdatedAt : 0,
      confirmedWords: this.confirmedWords, totalWords: this.totalWords, message: this.message,
      transfer: { elapsedMs, confirmedBytes: this.confirmedWords * 8, retries: this.retryCount,
        bytesPerSecond: elapsedMs > 0 ? this.confirmedWords * 8000 / elapsedMs : 0,
        averageAckMs: this.ackCount ? this.ackMs / this.ackCount : 0 },
      canCancel: this.busy && !this.cancelRequested && ['checking', 'begin', 'data'].includes(this.phase) };
  }
  onChange(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  emit() { for (const fn of this.listeners) fn(this.snapshot()); }
  receive(data) {
    if (!this.transport.connected) return;
    // Only ASCII is legal; decoding each byte preserves invalid-byte detection.
    const text = data instanceof Uint8Array ? Array.from(data, b => String.fromCharCode(b)).join('') : String(data);
    for (const char of text) {
      if (char === '\n') {
        const line = this.buffer.endsWith('\r') ? this.buffer.slice(0, -1) : this.buffer;
        const reply = this.discard ? null : parseScoreReply(line);
        this.buffer = ''; this.discard = false;
        const p = this.pending;
        if (p && reply && reply.session === p.session && reply.sequence === p.sequence && reply.operation === p.operation &&
            (reply.error || p.operation === 'CAPS' || (p.validate ? p.validate(reply) : JSON.stringify(reply.values) === JSON.stringify(p.expected)))) {
          if (!p.reply) p.reply = reply;
          this.complete();
        }
      } else if (!this.discard) {
        if (this.buffer.length >= 255 || (char !== '\r' && (char < ' ' || char > '~'))) { this.discard = true; this.buffer = ''; }
        else this.buffer += char;
      }
    }
  }
  complete() {
    const p = this.pending;
    if (!p?.written || !p.reply) return;
    if (this.startedAt && !this.finishedAt) { this.ackCount++; this.ackMs += performance.now() - p.sentAt; }
    this.settle(p.reply.error ? Object.assign(new Error(`设备拒绝 ${p.operation}：${p.reply.error}`), { deviceCode: p.reply.error }) : null, p.reply);
  }
  settle(error, reply) {
    const p = this.pending;
    if (!p) return;
    clearTimeout(p.timer); this.pending = null;
    error ? p.reject(error) : p.resolve(reply);
  }
  exchange(operation, fields = [], expected = [], validate = null) {
    if (!this.transport.connected || this.poisoned) return Promise.reject(new Error('上传链路不可用；请重连'));
    if (this.pending) return Promise.reject(new Error('上一上传请求尚未完成'));
    const sequence = this.sequence++;
    const frame = encodeScoreRequest(this.session, sequence, operation, fields);
    if (this.buffer.length) { this.buffer = ''; this.discard = true; }
    return new Promise((resolve, reject) => {
      const p = { session: this.session, sequence, operation, expected, validate, frame, resolve, reject, attempt: 0 };
      this.pending = p; this.write(p);
    });
  }
  write(p) {
    p.written = false;
    p.sentAt = performance.now();
    p.timer = setTimeout(() => {
      if (this.pending !== p) return;
      // A hung write cannot be cancelled by a JS timer. Do not enqueue a retry
      // or ABORT behind it; require an actual disconnect to drain the adapter.
      this.poisoned = true;
      this.settle(new Error('发送未完成，禁止重试；请断开重连，结果未知'));
    }, this.writeTimeoutMs);
    const failed = error => {
      if (this.pending !== p) return;
      this.poisoned = true;
      this.settle(new Error(`上传发送失败：${error.message}；结果未知`));
    };
    try {
      Promise.resolve(this.transport.sendText(p.frame, { newline: false })).then(() => {
        if (this.pending !== p) return;
        clearTimeout(p.timer); p.written = true;
        this.complete();
        if (this.pending !== p) return;
        p.timer = setTimeout(() => {
          if (this.pending !== p) return;
          if (p.attempt++ < this.retries && (!this.cancelRequested || p.operation === 'ABORT')) {
            if (this.startedAt && !this.finishedAt) this.retryCount++;
            this.message = `${p.operation} 等待应答，重试 ${p.attempt}/${this.retries}`;
            this.emit(); this.write(p);
          } else this.settle(Object.assign(new Error(`${p.operation} 应答超时，结果未知`), { uncertain: true }));
        }, this.timeoutMs);
      }, failed);
    } catch (error) { failed(error); }
  }
  cancel() {
    if (!this.snapshot().canCancel) return false;
    this.cancelRequested = true;
    this.message = '正在取消：等待当前写入结束，再请求设备丢弃暂存曲谱'; this.emit();
    return true;
  }
  async probe() { return this.run(null); }
  async upload(score) {
    // Validate before acquiring the link or sending anything. Words are copied
    // into immutable frame strings, so UI edits cannot change an active upload.
    const prepared = prepareScoreUpload(score, this.capability);
    return this.run(prepared);
  }
  async control(operation, score = null) {
    if (this.closed) throw new Error('上传会话已关闭');
    if (!['PLAY', 'STOP', 'STATUS'].includes(operation)) throw new Error('不支持的曲谱控制');
    if (this.busy) throw new Error('上一曲谱事务尚未结束');
    if (!this.capability?.playback || !this.sessionValid) throw new Error('设备尚未确认上传曲谱播放能力，请先检查能力');
    if (this.sequence > 65535) {
      this.sessionValid = false; this.capability = null; this.playback = null;
      this.phase = 'failed'; this.message = '请求编号已用尽，请重新检查能力'; this.emit();
      throw new Error(this.message);
    }
    const prepared = operation === 'PLAY' ? prepareScoreUpload(score, this.capability) : null;
    const fields = prepared ? [prepared.length, prepared.crc, 1] : [];
    const release = this.device.acquireExclusive();
    const epoch = this.epoch;
    this.busy = true; this.cancelRequested = false; this.poisoned = false;
    if (operation !== 'STATUS') this.playback = null;
    this.phase = 'control'; this.message = `等待设备确认上传曲谱 ${operation}`; this.emit();
    let uncertain = false;
    try {
      const reply = await this.exchange(operation, fields, [], r => Boolean(r.playback) &&
        (!prepared || (r.playback.length === prepared.length && r.playback.crc === prepared.crc && r.playback.storedValid && r.playback.storedCrc === prepared.crc)));
      this.checkConnection(epoch);
      this.playback = reply.playback;
      this.playbackUpdatedAt = Date.now();
      const label = ['空闲', '准备播放', '播放中', '已结束', '调度故障'][reply.playback.state];
      this.phase = 'controlled';
      this.message = operation === 'STOP' ? '设备已停止曲谱事件并释放声部；尾音可能尚未结束' :
        `设备已确认：${label}；这是最近一次应答状态${operation === 'PLAY' ? '，尚未验证实际声音' : ''}`;
      return reply.playback;
    } catch (error) {
      this.playback = null;
      uncertain = this.poisoned || epoch !== this.epoch || !error.deviceCode || error.deviceCode === 'STATE';
      if (!uncertain) {
        // FPGA errors do not consume the next sequence; a corrected request
        // must use it again. Successful retries consume exactly one number.
        this.sequence--;
        if (['SESSION', 'SEQUENCE', 'CONFLICT', 'FORMAT'].includes(error.deviceCode)) {
          this.sessionValid = false; this.capability = null;
        }
      } else { this.sessionValid = false; this.capability = null; }
      this.phase = uncertain ? 'unknown' : 'failed';
      this.message = `${error.message}${uncertain ? '；执行结果未知，请断开重连；断线不代表停止演奏' : ''}`;
      throw new Error(this.message);
    } finally { this.busy = false; release({ uncertain }); this.emit(); }
  }
  checkConnection(epoch) {
    if (epoch !== this.epoch || !this.transport.connected || this.device.snapshot().blocked) throw new Error('连接已改变，上传结果未知；请重连');
  }
  async run(prepared) {
    if (this.closed) throw new Error('上传会话已关闭');
    if (this.busy) throw new Error('上传事务尚未结束');
    const session = sessionId();
    const release = this.device.acquireExclusive();
    const epoch = this.epoch;
    this.busy = true; this.cancelRequested = false; this.poisoned = false;
    this.confirmedWords = 0; this.totalWords = prepared?.length || 0;
    this.startedAt = prepared ? performance.now() : 0; this.finishedAt = 0;
    this.retryCount = 0; this.ackCount = 0; this.ackMs = 0;
    this.session = session; this.sequence = 0;
    this.sessionValid = false; this.playback = null;
    let began = false, committing = false, uncertain = false;
    try {
      this.phase = 'checking'; this.message = '等待设备确认 SONG2 上传能力'; this.emit();
      const reply = await this.exchange('CAPS');
      this.checkConnection(epoch);
      if (!supportsScoreAbi(reply.capability.abi)) throw new Error('设备曲谱 ABI 不兼容');
      const previous = this.capability;
      this.capability = reply.capability;
      this.sessionValid = true;
      if (!prepared) {
        this.phase = this.cancelRequested ? 'cancelled' : 'available';
        this.message = this.cancelRequested ? '已取消，未开始传输曲谱' : `设备已应答上传能力：最多 ${this.capability.words} 个事件字`;
        return this.capability;
      }
      if (prepared.length > this.capability.words || previous.abi > this.capability.abi || previous.chunkWords > this.capability.chunkWords) throw new Error('设备容量已改变，请重新检查曲谱');
      for (const request of prepared.requests) {
        if (this.cancelRequested) break;
        this.phase = request.operation.toLowerCase();
        if (request.operation === 'BEGIN') began = true;
        if (request.operation === 'COMMIT') committing = true;
        this.message = request.operation === 'COMMIT' ? '等待设备完成整曲 CRC 校验与提交' : `上传中：${this.confirmedWords}/${prepared.length} 个事件字已确认`;
        this.emit();
        await this.exchange(request.operation, request.fields, request.expected);
        this.checkConnection(epoch);
        if (request.operation === 'DATA') { this.confirmedWords = Number(request.expected[0]); this.emit(); }
      }
      if (this.cancelRequested) {
        if (began) {
          this.phase = 'aborting'; this.emit();
          await this.exchange('ABORT');
          this.checkConnection(epoch);
        }
        this.phase = 'cancelled'; this.message = began ? '设备已确认丢弃本次暂存曲谱' : '已取消，未开始传输曲谱';
        return { cancelled: true };
      }
      this.phase = 'ready'; this.message = '设备已确认整曲 CRC 与提交；尚未请求播放';
      return { length: prepared.length, crc: prepared.crc };
    } catch (error) {
      uncertain = this.poisoned || committing || epoch !== this.epoch || this.phase === 'aborting' || (!began && Boolean(error.uncertain));
      if (began && !uncertain && this.transport.connected) {
        this.phase = 'aborting'; this.message = '上传中断，等待设备确认清理暂存曲谱'; this.emit();
        try {
          await this.exchange('ABORT');
          this.checkConnection(epoch);
          if (this.cancelRequested) {
            this.phase = 'cancelled'; this.message = '设备已确认丢弃本次暂存曲谱';
            return { cancelled: true };
          }
        } catch { uncertain = true; }
      }
      this.capability = null;
      this.sessionValid = false;
      this.phase = uncertain ? 'unknown' : 'failed';
      this.message = `${error.message}${uncertain ? '；设备结果未知，请重连核对' : began ? '；暂存已清理' : '；未确认上传能力'}`;
      throw new Error(this.message);
    } finally {
      if (this.startedAt) this.finishedAt = performance.now();
      this.busy = false;
      release({ uncertain }); this.emit();
    }
  }
  dispose() {
    this.closed = true; this.epoch++; this.poisoned = true;
    this.sessionValid = false; this.capability = null; this.playback = null;
    this.settle(new Error('上传会话已关闭，结果未知'));
    this.unsubscribers.forEach(fn => fn()); this.listeners.clear();
  }
}
