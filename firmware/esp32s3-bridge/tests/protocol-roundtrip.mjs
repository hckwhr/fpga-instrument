import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { encodeScoreRequest, prepareScoreUpload, parseScoreReply } from '../../../host/instrument-web/src/score-upload-protocol.js';
import { ScoreReceiverModel } from '../../../host/instrument-web/tools/score-receiver-model.mjs';

const executable = process.argv[2];
assert(executable, 'Pass the compiled bridge_tests executable');
const hex = text => Buffer.from(text).toString('hex');
let total = 0;
for (const chunk of [1, 7, 20, 64, 244]) {
  for (const mtu of [23, 64, 247]) {
    const model = new ScoreReceiverModel({ playback: true });
    const sid = '1020304050607080';
    // Capacity boundary transport test; this model does not verify audio ABI.
    const score = { words: Array.from({ length: 512 }, (_, i) => BigInt(i)), length: 512, endTick: 48000, melodyCount: 12 };
    const plan = prepareScoreUpload(score, { abi: 12, words: 512, chunkWords: 8 });
    const requests = [encodeScoreRequest(sid, 0, 'CAPS')];
    let seq = 0;
    for (const r of plan.requests) requests.push(encodeScoreRequest(sid, ++seq, r.operation, r.fields));
    requests.push(encodeScoreRequest(sid, ++seq, 'PLAY', [512, plan.crc, 1]));
    requests.push(requests.at(-1)); // lost ACK => exact PLAY retry, only one execution
    requests.push(encodeScoreRequest(sid, ++seq, 'STATUS'));
    requests.push(encodeScoreRequest(sid, ++seq, 'STOP'));
    const commands = [], expected = [];
    for (const frame of requests) {
      for (let i = 0; i < frame.length; i += chunk) {
        commands.push(`B ${hex(frame.slice(i, i + chunk))}`); expected.push('R 0');
      }
      commands.push('W'); expected.push(`W ${hex(frame)}`);
      const reply = model.receive(frame);
      assert(reply && parseScoreReply(reply.trimEnd()));
      for (let i = 0; i < reply.length; i += 3) {
        commands.push(`U ${hex(reply.slice(i, i + 3))}`); expected.push('R 0');
      }
      for (let i = 0; i < reply.length; i += mtu - 3) {
        commands.push(`N ${mtu}`); expected.push(`N ${hex(reply.slice(i, i + mtu - 3))}`);
      }
      commands.push('N 23'); expected.push('N ');
    }
    const result = spawnSync(executable, ['--pipe'], { input: commands.join('\n') + '\n', encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.stdout.replace(/\r/g, '').trimEnd().split('\n').map(s => s.trimEnd()), expected.map(s => s.trimEnd()));
    assert.equal(model.plays, 1); assert.equal(model.stops, 1); assert.equal(model.commits, 1);
    total += requests.length;
  }
}
console.log(`PASS 15 fragmentation/MTU combinations, ${total} SONG2 request/reply roundtrips through production C core; test-only FPGA model`);

// Replay the exact request/expected-response bytes used by the previously
// accepted RTL integration bench. This is transport checking, not a new RTL run.
const fixtures = ['control_vectors/pcm_upload.vh', 'production_vectors/commands.vh'];
let goldenCount = 0;
for (const fixture of fixtures) {
  const source = readFileSync(new URL(`../../../tests/fixtures/rtl-stage47/${fixture}`, import.meta.url), 'utf8');
  const pairs = [...source.matchAll(/exchange\("([^"\r\n]+)","([^"\r\n]+)"\)/g)];
  assert(pairs.length);
  for (const [, a, z] of pairs) {
    const frame = a.replaceAll('\\n', '\n'), reply = z.replaceAll('\\n', '\n');
    const commands = [], expected = [];
    for (let i = 0; i < frame.length; i += 20) {
      commands.push(`B ${hex(frame.slice(i, i + 20))}`); expected.push('R 0');
    }
    commands.push('W'); expected.push(`W ${hex(frame)}`);
    for (const byte of reply) { commands.push(`U ${hex(byte)}`); expected.push('R 0'); }
    for (let i = 0; i < reply.length; i += 20) {
      commands.push('N 23'); expected.push(`N ${hex(reply.slice(i, i + 20))}`);
    }
    const r = spawnSync(executable, ['--pipe'], { input: commands.join('\n') + '\n', encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(r.stdout.replace(/\r/g, '').trimEnd().split('\n'), expected);
    goldenCount++;
  }
}
console.log(`PASS ${goldenCount} stage47 RTL golden exchanges preserved byte-for-byte (including BUSY)`);
