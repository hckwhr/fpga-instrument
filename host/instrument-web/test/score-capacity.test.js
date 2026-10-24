import test from 'node:test';
import assert from 'node:assert/strict';
import { compileFpgaScore } from '../src/fpga-score.js';
import { prepareScoreUpload, parseScoreReply, encodeScoreFrame } from '../src/score-upload-protocol.js';

const project = count => ({ title: '长曲', tracks: [{ warnings: [], notes: Array.from({ length: count }, (_, i) =>
  ({ note: 60 + i % 12, velocity: 40, startMs: i * 250, endMs: i * 250 + 125, channel: 0, track: 0, order: i })) }] });
const old = { abi: 12, words: 512, chunkWords: 8 };
const extended = { abi: 13, words: 4096, chunkWords: 8 };
test('4096 events retain all 2048 notes, IDs, full progress and last release', () => {
  const score = compileFpgaScore(project(2048));
  assert.equal(score.abi, 13); assert.equal(score.length, 4096); assert.equal(score.melodyCount, 2048);
  for (const n of [0, 254, 255, 256, 511, 512, 1023, 2047]) {
    const word = score.words[n * 2];
    assert.equal(Number(word >> 23n & 65535n), n);
    assert.equal(Number(word & 255n), n & 255);
    assert.equal(score.events[n * 2].progress, n);
  }
  assert.equal(score.events.at(-1).on, false);
  assert.equal(score.events.at(-1).tick, score.endTick);
  const upload = prepareScoreUpload(score, extended);
  assert.equal(upload.requests[0].fields[0], 13);
  const blocks = upload.requests.filter(r => r.operation === 'DATA');
  assert.equal(blocks.length, 512); assert.deepEqual(blocks.at(-1).expected, ['4096']);
  assert.equal(blocks.at(-1).fields[0], 4088);
  assert.throws(() => prepareScoreUpload(score, old), /扩容固件/);
  assert.throws(() => compileFpgaScore(project(2049)), /4096/);
});
test('short scores stay byte-identical across old and expanded upload targets', () => {
  const score = compileFpgaScore(project(255));
  assert.equal(score.abi, 12);
  assert.deepEqual(prepareScoreUpload(score, old), prepareScoreUpload(score, extended));
  const next = compileFpgaScore(project(256));
  assert.equal(next.abi, 13);
  assert.throws(() => prepareScoreUpload(next, old), /扩容固件/);
  assert.equal(prepareScoreUpload(next, extended).length, 512);
});
test('capabilities and full progress parse strictly at new and legacy boundaries', () => {
  const reply = (op, values) => parseScoreReply(encodeScoreFrame(['ACK2', '0123456789ABCDEF', 1, op, ...values]).trim());
  assert.deepEqual(reply('CAPS', [13, 4096, 8, 1]).capability, { ...extended, playback: true });
  assert.equal(reply('CAPS', [12, 4096, 8, 1]), null);
  assert.equal(reply('CAPS', [13, 4097, 8, 1]), null);
  assert.equal(reply('STATUS', [3, 2047, 4096, 'ABCD', 1, 'ABCD']).playback.noteIndex, 2047);
  assert.equal(reply('STATUS', [3, 2048, 4096, 'ABCD', 1, 'ABCD']), null);
  assert.equal(reply('STATUS', [3, 1024, 2, 'ABCD', 1, 'ABCD']), null);
});
