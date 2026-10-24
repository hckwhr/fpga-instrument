// Test-only transaction/RAM model. This is NOT ESP32 firmware or FPGA RTL,
// and does not validate ABI event scheduling or prove hardware timing.
import { decodeScoreFrame, encodeScoreFrame } from '../src/score-upload-protocol.js';
import { crc16Ccitt } from '../src/protocol.js';

export class ScoreReceiverModel {
  constructor({ words = 512, chunkWords = 8, playback = false, abi = 12 } = {}) {
    this.abi = abi; this.words = words; this.chunkWords = chunkWords;
    this.sessions = new Map(); this.staging = null; this.committed = null;
    this.writes = 0; this.commits = 0; this.begins = 0;
    this.playback = playback; this.playState = 0; this.noteIndex = 0;
    this.playLength = 0; this.playCrc = '0000'; this.plays = 0; this.stops = 0;
  }
  receive(frame) {
    const f = decodeScoreFrame(frame.replace(/\r?\n$/, ''));
    if (!f || f[0] !== 'SONG2' || !/^[0-9A-F]{16}$/.test(f[1]) || !/^(0|[1-9]\d*)$/.test(f[2]) || +f[2] > 65535) return null;
    const [, sid, seq, op, ...v] = f;
    const error = code => encodeScoreFrame(['ERR2', sid, seq, op, code]);
    const previous = this.sessions.get(sid);
    if (previous && +seq === previous.sequence) return previous.frame === frame ? previous.reply : error('CONFLICT');
    if (previous && (+seq < previous.sequence || (+seq !== previous.sequence + 1 && op !== 'ABORT'))) return error('SEQUENCE');
    if (!previous && (op !== 'CAPS' || seq !== '0') && op !== 'ABORT') return error('SESSION');
    const ack = values => {
      const reply = encodeScoreFrame(['ACK2', sid, seq, op, ...values]);
      this.sessions.set(sid, { sequence: +seq, frame, reply });
      return reply;
    };
    const num = (s, min, max) => /^(0|[1-9]\d*)$/.test(s) && +s >= min && +s <= max;
    if (op === 'CAPS' && v.length === 0) return ack([this.abi, this.words, this.chunkWords, ...(this.playback ? [1] : [])]);
    if (['PLAY', 'STOP', 'STATUS'].includes(op)) {
      if (!this.playback) return error('FORMAT');
      if (op === 'PLAY') {
        if (v.length !== 3 || !num(v[0], 1, this.words) || !/^[0-9A-F]{4}$/.test(v[1]) || !num(v[2], 0, 3)) return error('FORMAT');
        if (!this.committed) return error('NOSCORE');
        if (+v[0] !== this.committed.length || v[1] !== this.committed.crc) return error('CONTENT');
        if ([1, 2].includes(this.playState)) return error('BUSY');
        this.playLength = this.committed.length; this.playCrc = this.committed.crc;
        this.playState = 1; this.noteIndex = 0; this.plays++;
      } else {
        if (v.length) return error('FORMAT');
        if (op === 'STOP') { this.playState = 0; this.stops++; }
      }
      return ack([this.playState, this.noteIndex, this.playLength, this.playCrc, this.committed ? 1 : 0, this.committed?.crc || '0000']);
    }
    if (op === 'ABORT' && v.length === 0) {
      if (this.staging && this.staging.sid !== sid) return error('SESSION');
      this.staging = null;
      return ack([]);
    }
    if (op === 'BEGIN') {
      if (v.length !== 5 || !num(v[1], 1, v[0] === '13' ? 4096 : 512) || !num(v[2], 1, 0xffffff) || !num(v[3], 1, v[0] === '13' ? 2048 : 255) || !/^[0-9A-F]{4}$/.test(v[4])) return error('FORMAT');
      if (v[0] !== '12' && !(v[0] === '13' && this.abi === 13)) return error('ABI');
      if (+v[1] > this.words) return error('CAPACITY');
      if (this.staging) return error('BUSY');
      this.staging = { sid, length: +v[1], endTick: +v[2], melodyCount: +v[3], crc: v[4], bytes: [] };
      this.begins++;
      return ack([0]);
    }
    const s = this.staging;
    if (!s || s.sid !== sid) return error('STATE');
    if (op === 'DATA') {
      if (v.length !== 3 || !num(v[0], 0, this.words - 1) || !num(v[1], 1, this.chunkWords) || !/^[0-9A-F]+$/.test(v[2]) || v[2].length !== +v[1] * 16) return error('FORMAT');
      if (+v[0] !== s.bytes.length / 8 || +v[0] + +v[1] > s.length) return error('OFFSET');
      s.bytes.push(...v[2].match(/../g).map(b => parseInt(b, 16)));
      this.writes++;
      return ack([s.bytes.length / 8]);
    }
    if (op === 'COMMIT') {
      if ([1, 2].includes(this.playState)) return error('BUSY');
      if (v.length !== 2 || v[0] !== String(s.length) || v[1] !== s.crc || s.bytes.length !== s.length * 8) return error('CONTENT');
      if (crc16Ccitt(s.bytes).toString(16).padStart(4, '0').toUpperCase() !== s.crc) return error('CRC');
      this.committed = { ...s, bytes: Uint8Array.from(s.bytes) };
      this.staging = null; this.commits++;
      return ack([s.length, s.crc]);
    }
    return error('FORMAT');
  }
}
