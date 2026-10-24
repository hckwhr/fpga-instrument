import { crc16Ccitt, wordBytes } from './protocol.js';

export const SCORE_ABI = 13;
export const supportsScoreAbi = abi => abi === 12 || abi === 13;
const encoder = new TextEncoder();
const hex = n => n.toString(16).padStart(4, '0').toUpperCase();
const integer = (value, low, high) => Number.isInteger(value) && value >= low && value <= high;
const decimal = (text, low, high) => /^(0|[1-9]\d*)$/.test(text) && integer(Number(text), low, high);

// CRC covers the complete ASCII header/payload, excluding the final comma,
// CRC itself and LF. This also protects the session, sequence and metadata.
export function encodeScoreFrame(fields) {
  if (!Array.isArray(fields) || fields.some(f => !/^[A-Z0-9]+$/.test(String(f)))) throw new Error('上传帧字段无效');
  const body = fields.join(',');
  const frame = `${body},${hex(crc16Ccitt(encoder.encode(body)))}\n`;
  if (frame.length > 256) throw new Error('上传帧超过 256 字节');
  return frame;
}

export function decodeScoreFrame(line) {
  if (typeof line !== 'string' || line.length > 255 || !/^[A-Z0-9]+(?:,[A-Z0-9]+)+,[0-9A-F]{4}$/.test(line)) return null;
  const end = line.lastIndexOf(',');
  if (hex(crc16Ccitt(encoder.encode(line.slice(0, end)))) !== line.slice(end + 1)) return null;
  return line.slice(0, end).split(',');
}

export function encodeScoreRequest(session, sequence, operation, fields = []) {
  if (!/^[0-9A-F]{16}$/.test(session) || !integer(sequence, 0, 65535) ||
      !['CAPS', 'BEGIN', 'DATA', 'COMMIT', 'ABORT', 'PLAY', 'STOP', 'STATUS'].includes(operation)) throw new Error('上传请求编号或操作无效');
  return encodeScoreFrame(['SONG2', session, sequence, operation, ...fields]);
}

export function parseScoreReply(line) {
  const f = decodeScoreFrame(line);
  if (!f || !['ACK2', 'ERR2'].includes(f[0]) || !/^[0-9A-F]{16}$/.test(f[1]) ||
      !decimal(f[2], 0, 65535) || !['CAPS', 'BEGIN', 'DATA', 'COMMIT', 'ABORT', 'PLAY', 'STOP', 'STATUS'].includes(f[3])) return null;
  const reply = { session: f[1], sequence: Number(f[2]), operation: f[3], values: f.slice(4) };
  if (f[0] === 'ERR2') {
    if (f.length !== 5 || !['BUSY', 'CRC', 'ABI', 'CAPACITY', 'SESSION', 'SEQUENCE', 'CONFLICT', 'OFFSET', 'FORMAT', 'STATE', 'CONTENT', 'NOSCORE'].includes(f[4])) return null;
    return { ...reply, error: f[4] };
  }
  const v = reply.values;
  if (f[3] === 'CAPS' && (v.length === 3 || (v.length === 4 && v[3] === '1')) && decimal(v[0], 1, 65535) && decimal(v[1], 1, +v[0] === 13 ? 4096 : 512) && decimal(v[2], 1, 8)) {
    return { ...reply, capability: { abi: +v[0], words: +v[1], chunkWords: +v[2], ...(v.length === 4 ? { playback: true } : {}) } };
  }
  if (f[3] === 'BEGIN' && v.length === 1 && v[0] === '0') return reply;
  if (f[3] === 'DATA' && v.length === 1 && decimal(v[0], 1, 4096)) return reply;
  if (f[3] === 'COMMIT' && v.length === 2 && decimal(v[0], 1, 4096) && /^[0-9A-F]{4}$/.test(v[1])) return reply;
  if (f[3] === 'ABORT' && v.length === 0) return reply;
  if (['PLAY', 'STOP', 'STATUS'].includes(f[3]) && v.length === 6 &&
      decimal(v[0], 0, 4) && decimal(v[1], 0, 2047) && decimal(v[2], 0, 4096) &&
      /^[0-9A-F]{4}$/.test(v[3]) && ['0', '1'].includes(v[4]) && /^[0-9A-F]{4}$/.test(v[5])) {
    if ((Number(v[2]) % 2 !== 0) || (Number(v[2]) > 0 && Number(v[1]) >= Number(v[2]) / 2) ||
        (v[2] === '0' && (v[0] !== '0' || v[1] !== '0' || v[3] !== '0000')) ||
        (v[4] === '0' && v[5] !== '0000') || (f[3] === 'STOP' && v[0] !== '0') ||
        (f[3] === 'PLAY' && !['1', '2', '3'].includes(v[0]))) return null;
    return { ...reply, playback: { state: +v[0], noteIndex: +v[1], length: +v[2], crc: v[3],
      storedValid: v[4] === '1', storedCrc: v[5] } };
  }
  return null;
}

export function prepareScoreUpload(score, capability) {
  if (!supportsScoreAbi(capability?.abi) || !integer(capability.words, 1, capability.abi === 13 ? 4096 : 512) || !integer(capability.chunkWords, 1, 8)) throw new Error('设备未确认支持 SONG2 / ABI 12 或 13');
  const abi = score?.abi ?? 12;
  if (!supportsScoreAbi(abi) || abi > capability.abi) throw new Error('这首曲谱需要扩容固件（4096 事件）；当前设备仍为旧版，请升级 FPGA 或缩短选段');
  if (!score || !Array.isArray(score.words) || !integer(score.words.length, 1, capability.words) ||
      score.length !== score.words.length || !integer(score.endTick, 1, 0xffffff) || !integer(score.melodyCount, 1, abi === 13 ? 2048 : 255) || score.words.length > (abi === 13 ? 4096 : 512)) throw new Error('曲谱容量或元数据不符合设备要求');
  const bytes = new Uint8Array(score.words.length * 8);
  score.words.forEach((word, i) => bytes.set(wordBytes(word), i * 8));
  const crc = hex(crc16Ccitt(bytes));
  const requests = [{ operation: 'BEGIN', fields: [abi, score.length, score.endTick, score.melodyCount, crc], expected: ['0'] }];
  for (let offset = 0; offset < score.length; offset += capability.chunkWords) {
    const count = Math.min(capability.chunkWords, score.length - offset);
    const payload = Array.from(bytes.slice(offset * 8, (offset + count) * 8), b => b.toString(16).padStart(2, '0')).join('').toUpperCase();
    requests.push({ operation: 'DATA', fields: [offset, count, payload], expected: [String(offset + count)] });
  }
  requests.push({ operation: 'COMMIT', fields: [score.length, crc], expected: [String(score.length), crc] });
  return { requests, crc, length: score.length };
}
