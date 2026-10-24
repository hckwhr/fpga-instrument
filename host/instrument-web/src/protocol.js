export function crc16Ccitt(bytes) {
  let crc = 0xffff;
  for (const byte of bytes) {
    crc ^= byte << 8;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
  }
  return crc;
}

export function wordBytes(word) {
  const bytes = new Uint8Array(8);
  if (typeof word !== 'bigint' && typeof word !== 'string') throw new Error('事件字必须是 BigInt 或整数字符串');
  let value = BigInt(word);
  if (value < 0n || value > 0xffffffffffffffffn) throw new Error('事件字超出 64 位范围');
  for (let i = 7; i >= 0; i -= 1) {
    bytes[i] = Number(value & 0xffn);
    value >>= 8n;
  }
  return bytes;
}

function hexBytes(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("").toUpperCase();
}

/**
 * Encode a compiled FPGA score for the future BEGIN/DATA/COMMIT protocol.
 * This is deliberately separate from encodePreviewFrames: the current RTL
 * accepts only bring-up commands and cannot consume these frames yet.
 */
export function encodeUploadFrames(score, { chunkWords = 8 } = {}) {
  if (!score || !Array.isArray(score.words) || score.words.length === 0) throw new Error("缺少已编译曲谱");
  if (!Number.isInteger(chunkWords) || chunkWords < 1 || chunkWords > 8) throw new Error("每帧最多 8 个事件字");
  const bytes = new Uint8Array(score.words.length * 8);
  score.words.forEach((word, index) => bytes.set(wordBytes(word), index * 8));
  const songCrc = crc16Ccitt(bytes).toString(16).padStart(4, "0").toUpperCase();
  const frames = [`SONG1,BEGIN,${score.words.length},${score.endTick},${songCrc}\n`];
  for (let offset = 0; offset < score.words.length; offset += chunkWords) {
    const chunk = bytes.slice(offset * 8, Math.min(score.words.length, offset + chunkWords) * 8);
    const crc = crc16Ccitt(chunk).toString(16).padStart(4, "0").toUpperCase();
    frames.push(`SONG1,DATA,${offset},${chunk.length / 8},${hexBytes(chunk)},${crc}\n`);
  }
  frames.push(`SONG1,COMMIT,${score.words.length},${songCrc}\n`);
  return frames;
}

export function encodePreviewFrames(events, chunkSize = 16) {
  const frames = [`SONG,BEGIN,1,${events.length}`];
  for (let offset = 0; offset < events.length; offset += chunkSize) {
    const chunk = events.slice(offset, offset + chunkSize);
    const payload = chunk.map((event, index) => [offset + index, event.startMs, event.note, event.velocity, event.durationMs].join(",")).join(";");
    const crc = crc16Ccitt(new TextEncoder().encode(payload)).toString(16).padStart(4, "0").toUpperCase();
    frames.push(`SONG,DATA,${offset},${chunk.length},${payload},${crc}`);
  }
  frames.push(`SONG,END,${events.length}`);
  return frames.map((line) => `${line}\n`);
}

export function serializeCsv(events) {
  const lines = ["delta_ms,note,velocity,duration_ms,channel,track"];
  for (const event of events) lines.push([event.deltaMs, event.noteName, event.velocity, event.durationMs, event.channel, event.track].join(","));
  return `${lines.join("\n")}\n`;
}

export function serializeJsonl(events, metadata = {}) {
  return `${JSON.stringify({ type: "header", version: 1, ...metadata })}\n${events.map((event) => JSON.stringify({ type: "note", ...event })).join("\n")}\n`;
}
