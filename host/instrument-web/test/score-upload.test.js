import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { crc16Ccitt, wordBytes } from '../src/protocol.js';
import { encodeScoreFrame, decodeScoreFrame, encodeScoreRequest, parseScoreReply, prepareScoreUpload } from '../src/score-upload-protocol.js';
import { ScoreUploadSession } from '../src/score-upload.js';
import { DeviceSession } from '../src/device-session.js';
import { ScoreReceiverModel } from '../tools/score-receiver-model.mjs';
import { compileFpgaScore, compileSelectedFpgaScore } from '../src/fpga-score.js';
import { parseMidi, compileTracks } from '../src/midi.js';

const sid = '0123456789ABCDEF';
const capability = { abi: 12, words: 512, chunkWords: 8 };
const score = { words: Array.from({ length: 18 }, (_, i) => BigInt(i) << 40n), length: 18, endTick: 32, melodyCount: 9 };
const tick = () => new Promise(resolve => setImmediate(resolve));
test('expanded session uploads all 4096 words with a lost late DATA ACK and full progress', async () => {
  const f = fixture({ model: { abi: 13, words: 4096, playback: true } });
  const notes = Array.from({ length: 2048 }, (_, i) => ({ note: 60, velocity: 40, channel: 0,
    startMs: i * 250, endMs: i * 250 + 125, track: 0, order: i }));
  const longScore = compileFpgaScore({ title: 'Full', tracks: [{ warnings: [], notes }] });
  await f.uploader.probe();
  let dropped = false;
  f.hook = ({ fields, reply, emit }) => {
    if (!dropped && fields[3] === 'DATA' && fields[4] === '4088') { dropped = true; return; }
    emit(reply);
  };
  await f.uploader.upload(longScore);
  assert.equal(f.model.writes, 512); assert.equal(f.model.commits, 1);
  assert.equal(f.model.committed.bytes.length, 32768);
  assert.equal(f.uploader.confirmedWords, 4096);
  await f.uploader.control('PLAY', longScore);
  f.model.playState = 3; f.model.noteIndex = 2047;
  assert.equal((await f.uploader.control('STATUS')).noteIndex, 2047);
  f.uploader.dispose();
});
function fixture(options = {}) {
  const status = new Set(), data = new Set(), sent = [];
  const model = new ScoreReceiverModel(options.model);
  const f = { model, sent, hook: null };
  const transport = {
    connected: true,
    onStatus(fn) { status.add(fn); return () => status.delete(fn); },
    onData(fn) { data.add(fn); return () => data.delete(fn); },
    async sendText(text, opts) {
      sent.push(text); assert.equal(opts.newline, false);
      const reply = model.receive(text);
      if (f.hook) return f.hook({ text, reply, fields: decodeScoreFrame(text.trim()), emit: f.emit });
      if (reply) f.emit(reply);
    },
  };
  f.emit = text => { for (const fn of data) fn(text); };
  f.connect = connected => { transport.connected = connected; for (const fn of status) fn({ state: connected ? 'connected' : 'disconnected' }); };
  f.device = new DeviceSession(transport);
  f.uploader = new ScoreUploadSession(f.device, { timeoutMs: 15, writeTimeoutMs: 60, retries: 1, ...options });
  f.transport = transport;
  return f;
}

test('SONG2 known CRC, complete-header integrity, strict reply parsing and 64-bit bounds', () => {
  assert.equal(crc16Ccitt(new TextEncoder().encode('123456789')), 0x29b1);
  const frame = encodeScoreRequest(sid, 0, 'CAPS');
  assert.deepEqual(decodeScoreFrame(frame.trim()), ['SONG2', sid, '0', 'CAPS']);
  for (const changed of [frame.replace('CAPS', 'DATA'), frame.replace(sid, '1123456789ABCDEF'), frame.replace(',0,', ',1,')]) assert.equal(decodeScoreFrame(changed.trim()), null);
  assert.equal(parseScoreReply(encodeScoreFrame(['ACK2', sid, 0, 'CAPS', 12, 512, 8]).trim()).capability.abi, 12);
  for (const fields of [ ['ACK2', sid, 0, 'CAPS', 12, 513, 8], ['ACK2', sid, 0, 'DATA', '01'], ['ACK2', sid, 0, 'ABORT', 0], ['ERR2', sid, 0, 'BEGIN', 'BOGUS'] ]) assert.equal(parseScoreReply(encodeScoreFrame(fields).trim()), null);
  for (const word of [-1n, 1n << 64n, Number.MAX_SAFE_INTEGER]) assert.throws(() => wordBytes(word));
  assert.deepEqual([...wordBytes(0x0123456789abcdefn)], [1,35,69,103,137,171,205,239]);
  assert.throws(() => prepareScoreUpload({ ...score, melodyCount: 0 }, capability));
  assert.throws(() => prepareScoreUpload(score, { ...capability, words: 16 }));
  const maximum = prepareScoreUpload({ ...score, length: 512, words: Array(512).fill(0xffffffffffffffffn), endTick: 0xffffff }, capability);
  for (const [i, r] of maximum.requests.entries()) assert.ok(encodeScoreRequest(sid, i + 1, r.operation, r.fields).length <= 256);
});

test('receiver model deduplicates exact retries, rejects conflicts/offsets, and commits atomically', () => {
  const model = new ScoreReceiverModel();
  model.receive(encodeScoreRequest(sid, 0, 'CAPS'));
  const { requests } = prepareScoreUpload(score, capability);
  const send = (i, r) => model.receive(encodeScoreRequest(sid, i, r.operation, r.fields));
  const first = send(1, requests[0]); assert.equal(send(1, requests[0]), first); assert.equal(model.begins, 1);
  assert.match(send(1, { ...requests[0], fields: [12, 18, 33, 9, requests[0].fields.at(-1)] }), /CONFLICT/);
  assert.match(send(2, { operation: 'DATA', fields: [1, 1, '0000000000000000'] }), /OFFSET/);
  requests.slice(1, -1).forEach((r, i) => { const reply = send(i + 2, r); assert.equal(send(i + 2, r), reply); });
  assert.equal(model.committed, null);
  const last = send(requests.length, requests.at(-1));
  assert.equal(send(requests.length, requests.at(-1)), last);
  assert.equal(model.commits, 1); assert.equal(model.writes, 3); assert.equal(model.committed.bytes.length, 144);
  model.receive(encodeScoreRequest(sid, requests.length + 1, 'ABORT'));
  assert.equal(model.commits, 1, 'ABORT does not undo an already committed score');
});

test('capability gate, full real MIDI upload, lost BEGIN/DATA/COMMIT ACKs retry byte-identically', async () => {
  const f = fixture();
  await assert.rejects(f.uploader.upload(score), /未确认/); assert.equal(f.sent.length, 0);
  await f.uploader.probe();
  const lost = new Set();
  f.hook = ({ text, reply, fields, emit }) => {
    if (['BEGIN', 'DATA', 'COMMIT'].includes(fields[3]) && !lost.has(fields[3])) { lost.add(fields[3]); return; }
    emit(new TextEncoder().encode(reply.slice(0, 7))); emit(reply.slice(7));
  };
  const midi = parseMidi(await readFile(new URL('./fixtures/fpga-scores/ode.mid', import.meta.url)));
  const compiled = compileFpgaScore(midi);
  await f.uploader.upload(compiled);
  assert.equal(f.uploader.phase, 'ready'); assert.equal(f.uploader.confirmedWords, compiled.length);
  assert.equal(f.model.commits, 1); assert.equal(f.model.begins, 1); assert.equal(f.model.writes, Math.ceil(compiled.length / 8));
  for (const op of lost) { const frames = f.sent.filter(frame => frame.includes(`,${op},`)); assert.equal(frames[0], frames[1]); }
  assert.deepEqual(f.model.committed.bytes, Uint8Array.from(compiled.words.flatMap(w => [...wordBytes(w)])));
  assert.equal(f.device.snapshot().busy, false);
});

test('wrong session/sequence/operation/offset/CRC and oversized lines cannot satisfy DATA', async () => {
  const f = fixture({ timeoutMs: 100 }); await f.uploader.probe();
  let actual;
  f.hook = ({ fields, reply, emit }) => {
    if (fields[3] !== 'DATA') { emit(reply); return; }
    actual = reply;
    emit('X'.repeat(300) + '\n' + '\u0080junk\n');
    for (const [session, seq, op, value] of [[sid, +fields[2], 'DATA', 8], [fields[1], +fields[2] + 1, 'DATA', 8], [fields[1], +fields[2], 'BEGIN', 0], [fields[1], +fields[2], 'DATA', 1]]) emit(encodeScoreFrame(['ACK2', session, seq, op, value]));
    emit(reply.replace('ACK2', 'ACK3'));
  };
  const task = f.uploader.upload({ ...score, words: score.words.slice(0, 8), length: 8 });
  await tick(); assert.equal(f.uploader.confirmedWords, 0); assert.equal(f.uploader.busy, true);
  await assert.rejects(f.device.request('PING'), /上一条/);
  await assert.rejects(f.device.sendRaw('PING'), /上一条/);
  await assert.rejects(f.uploader.probe(), /尚未结束/);
  f.emit(actual); await task; assert.equal(f.uploader.phase, 'ready');
});

test('cancel waits for current write, confirms ABORT and retains prior committed score', async () => {
  const f = fixture(); await f.uploader.probe(); await f.uploader.upload(score);
  const previous = f.model.committed;
  let resume;
  f.hook = ({ fields, reply, emit }) => {
    if (fields[3] === 'DATA') return new Promise(resolve => { resume = () => { emit(reply); resolve(); }; });
    emit(reply);
  };
  const task = f.uploader.upload(score); await tick();
  assert.equal(f.uploader.cancel(), true); await tick();
  assert.ok(!f.sent.at(-1).includes(',ABORT,'));
  resume(); assert.deepEqual(await task, { cancelled: true });
  assert.equal(f.uploader.phase, 'cancelled'); assert.equal(f.model.staging, null); assert.equal(f.model.committed, previous);
});

test('hung write, even with early ACK, never retries or queues ABORT', async () => {
  const f = fixture({ writeTimeoutMs: 20 }); await f.uploader.probe();
  f.hook = ({ fields, reply, emit }) => { emit(reply); if (fields[3] === 'DATA') return new Promise(() => {}); };
  await assert.rejects(f.uploader.upload(score), /发送未完成/);
  assert.equal(f.uploader.phase, 'unknown'); assert.equal(f.device.snapshot().blocked, true);
  assert.equal(f.sent.filter(s => s.includes(',DATA,')).length, 1);
  assert.equal(f.sent.filter(s => s.includes(',ABORT,')).length, 0);
  await assert.rejects(f.device.sendRaw('PING'), /断开重连/);
});

test('early valid ACK followed by write rejection cannot report success', async () => {
  const f = fixture(); await f.uploader.probe();
  f.hook = ({ fields, reply, emit }) => { emit(reply); if (fields[3] === 'COMMIT') throw new Error('write rejected'); };
  await assert.rejects(f.uploader.upload(score), /发送失败/);
  assert.equal(f.model.commits, 1); assert.equal(f.uploader.phase, 'unknown');
});

test('lost final COMMIT ACK leaves unknown result, never assumes cancellation', async () => {
  const f = fixture(); await f.uploader.probe();
  f.hook = ({ fields, reply, emit }) => { if (fields[3] !== 'COMMIT') emit(reply); };
  await assert.rejects(f.uploader.upload(score), /COMMIT 应答超时/);
  assert.equal(f.uploader.phase, 'unknown'); assert.equal(f.model.commits, 1);
  assert.equal(f.sent.filter(s => s.includes(',ABORT,')).length, 0);
  assert.equal(f.uploader.cancel(), false);
});

test('cancel without DATA ACK still ABORTs; lost ABORT ACK remains unknown', async () => {
  for (const dropAbort of [false, true]) {
    const f = fixture(); await f.uploader.probe();
    f.hook = ({ fields, reply, emit }) => { if (fields[3] === 'DATA') f.uploader.cancel(); else if (!(dropAbort && fields[3] === 'ABORT')) emit(reply); };
    const task = f.uploader.upload(score);
    if (dropAbort) { await assert.rejects(task, /未知/); assert.equal(f.uploader.phase, 'unknown'); }
    else { assert.deepEqual(await task, { cancelled: true }); assert.equal(f.uploader.phase, 'cancelled'); }
    assert.equal(f.model.staging, null);
  }
});

test('legacy reply never enables upload; raw mode and reconnection invalidate capability', async () => {
  const f = fixture();
  f.hook = ({ emit }) => emit('OK,HC05,1,9600,8N1,DEMO=TWINKLE+ODE\nERR,LINE\n');
  await assert.rejects(f.uploader.probe(), /超时/); assert.equal(f.uploader.capability, null);
  f.connect(false); f.connect(true); f.hook = null; await f.uploader.probe();
  f.transport.sendText = async () => {};
  await f.device.sendRaw('PING'); assert.equal(f.uploader.capability, null);
});

test('disconnect rejects active request and ignores its late write completion after reconnect', async () => {
  const f = fixture(); await f.uploader.probe();
  let rejectOld;
  f.hook = () => new Promise((resolve, reject) => { rejectOld = reject; });
  const task = f.uploader.upload(score);
  const failure = assert.rejects(task, /未知/);
  f.connect(false); await failure;
  f.connect(true); f.hook = null; await f.uploader.probe();
  rejectOld(new Error('late failure')); await tick();
  assert.equal(f.uploader.phase, 'available'); assert.equal(f.uploader.capability.abi, 12);
});

test('corrupted staged bytes fail whole-score CRC without replacing committed song', async () => {
  const f = fixture(); await f.uploader.probe();
  f.hook = ({ fields, reply, emit }) => { if (fields[3] === 'DATA') f.model.staging.bytes[0] ^= 1; emit(reply); };
  await assert.rejects(f.uploader.upload(score), /CRC/);
  assert.equal(f.model.committed, null); assert.notEqual(f.uploader.phase, 'ready');
});

test('disconnect immediately after ACK cannot resurrect capability or ready state', async () => {
  for (const op of ['CAPS', 'COMMIT']) {
    const f = fixture();
    if (op === 'COMMIT') await f.uploader.probe();
    f.hook = ({ fields, reply, emit }) => { emit(reply); if (fields[3] === op) queueMicrotask(() => f.connect(false)); };
    await assert.rejects(op === 'CAPS' ? f.uploader.probe() : f.uploader.upload(score), /未知/);
    assert.equal(f.uploader.capability, null); assert.equal(f.uploader.phase, 'unknown');
  }
});

test('selected compiler matches preview, survives library data, preserves source and rejects warnings', async () => {
  const project = parseMidi(await readFile(new URL('./fixtures/fpga-scores/ode.mid', import.meta.url)));
  const restored = JSON.parse(JSON.stringify(project));
  const options = { melodyTrack: 0, speed: 1.25, velocityScale: 0.75 };
  const a = compileSelectedFpgaScore(project, [0, 1], options);
  const b = compileSelectedFpgaScore(restored, [0, 1], options);
  assert.deepEqual(a.words, b.words);
  const preview = compileTracks(project, [0, 1], options);
  for (const event of a.events.filter(e => e.on)) assert.ok(preview.some(n => n.track === event.track && n.note === event.note && n.velocity === event.velocity && Math.round(n.startMs / 6.25) === event.tick));
  assert.notDeepEqual(a.words, compileSelectedFpgaScore(project, [0, 1], { melodyTrack: 0 }).words);
  project.tracks[1].warnings.push('unsupported control');
  assert.doesNotThrow(() => compileSelectedFpgaScore(project, [0], { melodyTrack: 0 }));
  assert.throws(() => compileSelectedFpgaScore(project, [0, 1], options), /unsupported/);
  assert.throws(() => compileSelectedFpgaScore(project, [1], { melodyTrack: 0 }), /旋律轨/);
  assert.equal(project.tracks[0].notes[0].velocity, restored.tracks[0].notes[0].velocity);
});
