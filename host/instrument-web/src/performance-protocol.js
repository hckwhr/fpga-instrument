import { crc16Ccitt } from './protocol.js';

export const RECORDING = Object.freeze({ sampleRate: 12000, blockSamples: 240, maxBlocks: 3000 });
export const IMA_STEPS = Object.freeze([7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]);
const INDEX = [-1,-1,-1,-1,2,4,6,8];
const BASE64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const hex = (v, n) => v.toString(16).toUpperCase().padStart(n, '0');
export const performanceCrc = body => hex(crc16Ccitt(new TextEncoder().encode(body)), 4);
export const performanceLine = body => `${body},${performanceCrc(body)}\n`;

export function packKeymap(notes) {
  if (!Array.isArray(notes) || notes.length !== 12 || notes.some(n => !Number.isInteger(n) || n < 48 || n > 83)) throw new Error('请选择 12 个 C3—B5 范围内的音');
  return hex(notes.reduce((bits, note, i) => bits | (BigInt((Math.floor((note - 48) / 12) << 4) | ((note - 48) % 12)) << BigInt(i * 6)), 0n), 18);
}
export function unpackKeymap(encoded) {
  if (!/^[0-9A-F]{18}$/.test(encoded)) throw new Error('键位应答格式错误');
  const bits = BigInt(`0x${encoded}`);
  return Array.from({length: 12}, (_, i) => {
    const v = Number((bits >> BigInt(i * 6)) & 63n);
    if ((v >> 4) > 2 || (v & 15) > 11) throw new Error('设备返回了无效音高');
    return 48 + (v >> 4) * 12 + (v & 15);
  });
}
export function performanceRequest(id, operation, notes) {
  if (!/^[0-9A-F]{8}$/.test(id) || !Number.isInteger(operation) || operation < 0 || operation > 5) throw new Error('演奏命令无效');
  return performanceLine(`PERF1,${id},${operation},${operation === 1 ? packKeymap(notes) : '0'.repeat(18)}`);
}
// PERF1 6/7 use a tagged status payload; they are not key-map responses.
export function rhythmRequest(id, { cue = 0, mask = 0, enabled = false, poll = false } = {}) {
  if (!/^[0-9A-F]{8}$/.test(id) || !Number.isInteger(cue) || cue < 0 || cue > 0xffffffff ||
      !Number.isInteger(mask) || mask < 0 || mask > 4095 || (!enabled && (cue || mask))) throw Error('跟练命令无效');
  const payload = poll ? 0n : (BigInt(enabled) << 44n) | (BigInt(cue) << 12n) | BigInt(mask);
  return performanceLine(`PERF1,${id},${poll ? 7 : 6},${hex(payload, 18)}`);
}
export function parsePerformanceLine(line) {
  if (line.length > 254 || !/^PERF1,[0-9A-F]{8},/.test(line)) return null;
  const split = line.lastIndexOf(',');
  if (performanceCrc(line.slice(0, split)) !== line.slice(split + 1)) throw new Error('演奏回传校验失败');
  const p = line.slice(0, split).split(',');
  if (p[2] === 'A' && p.length === 6 && /^[0-7]$/.test(p[3]) && /^[0-3]$/.test(p[4])) {
    const result = { type: 'ack', id: p[1], operation: +p[3], status: +p[4] };
    if (result.operation < 6) return {...result, notes: unpackKeymap(p[5])};
    if (!/^[0-9A-F]{18}$/.test(p[5])) throw Error('跟练应答格式错误');
    if (result.status >= 2) return result;
    const bits = BigInt(`0x${p[5]}`);
    if (bits >> 70n !== 2n) throw Error('设备不支持实体跟练状态，请更新配套 FPGA 固件');
    return {...result, guard: Boolean(bits & (1n << 69n)), active: Boolean(bits & (1n << 68n)),
      cue: Number((bits >> 36n) & 0xffffffffn), keys: Number((bits >> 24n) & 4095n),
      hits: Number((bits >> 12n) & 4095n), guide: Number(bits & 4095n)};
  }
  if (p[2] === 'E' && p.length === 5 && /^[0-9A-F]{4}$/.test(p[3]) && /^[0-4]$/.test(p[4])) return {type: 'end', id: p[1], count: parseInt(p[3], 16), status: +p[4]};
  if (p[2] === 'D' && p.length === 7 && /^[0-9A-F]{4}$/.test(p[3]) && /^[0-9A-F]{4}$/.test(p[4]) && /^[0-9A-F]{2}$/.test(p[5]) && /^[A-Za-z0-9+/]{160}$/.test(p[6])) {
    const predictor = parseInt(p[4], 16), index = parseInt(p[5], 16);
    if (index > 88) throw new Error('录音预测状态无效');
    return {type: 'data', id: p[1], sequence: parseInt(p[3], 16), predictor: predictor >= 32768 ? predictor - 65536 : predictor, index, payload: p[6]};
  }
  throw new Error('演奏回传格式错误');
}
export function decodeRecordingBlock(block) {
  let predictor = block.predictor, index = block.index;
  const pcm = new Int16Array(RECORDING.blockSamples);
  let at = 0;
  for (let i = 0; i < block.payload.length; i += 2) {
    const word = (BASE64.indexOf(block.payload[i]) << 6) | BASE64.indexOf(block.payload[i + 1]);
    for (const shift of [8,4,0]) {
      const code = (word >> shift) & 15, step = IMA_STEPS[index];
      const delta = (step >> 3) + ((code & 4) ? step : 0) + ((code & 2) ? step >> 1 : 0) + ((code & 1) ? step >> 2 : 0);
      predictor = Math.max(-32768, Math.min(32767, predictor + ((code & 8) ? -delta : delta)));
      index = Math.max(0, Math.min(88, index + INDEX[code & 7]));
      pcm[at++] = predictor;
    }
  }
  return {pcm, predictor, index};
}
export function recordingWav(blocks) {
  const count = blocks.reduce((n, block) => n + block.length, 0);
  if (!count || count > RECORDING.blockSamples * RECORDING.maxBlocks) throw new Error('录音为空或超过 60 秒');
  const bytes = new Uint8Array(44 + count * 2), view = new DataView(bytes.buffer);
  const text = (offset, value) => [...value].forEach((ch, i) => view.setUint8(offset + i, ch.charCodeAt(0)));
  text(0, 'RIFF'); view.setUint32(4, bytes.length - 8, true); text(8, 'WAVE'); text(12, 'fmt ');
  view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, RECORDING.sampleRate, true); view.setUint32(28, RECORDING.sampleRate * 2, true);
  view.setUint16(32, 2, true); view.setUint16(34, 16, true); text(36, 'data'); view.setUint32(40, count * 2, true);
  let offset = 44;
  for (const block of blocks) for (const value of block) { view.setInt16(offset, value, true); offset += 2; }
  return bytes;
}
