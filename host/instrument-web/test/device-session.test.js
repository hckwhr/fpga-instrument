import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { DeviceSession, parseDeviceReply } from '../src/device-session.js';

const HELLO = 'OK,HC05,1,9600,8N1,DEMO=TWINKLE+ODE';
function fixture(timeoutMs = 500) {
  const status = new Set(), data = new Set(), sent = [];
  const transport = {
    connected: true,
    onStatus(fn) { status.add(fn); return () => status.delete(fn); },
    onData(fn) { data.add(fn); return () => data.delete(fn); },
    async sendText(text) { sent.push(text); },
  };
  const emit = value => { for (const fn of data) fn(value); };
  const setConnected = connected => {
    transport.connected = connected;
    for (const fn of status) fn({ state: connected ? 'connected' : 'disconnected', connected });
  };
  const session = new DeviceSession(transport, { timeoutMs });
  async function identify() { const task = session.request('HELLO'); emit(HELLO + '\n'); return task; }
  return { transport, session, emit, setConnected, sent, identify };
}

test('reply vocabulary matches real stage42 RTL and never advertises upload', async () => {
  const rtl = await readFile(new URL('../../../tests/reference/stage42/hc05_link.v', import.meta.url), 'utf8');
  for (const token of [HELLO, 'PONG', 'OK,PLAY', 'OK,STOP', 'ERR,LOCAL', 'STATUS,PLAYING,']) assert.ok(rtl.includes(token));
  assert.equal(parseDeviceReply(HELLO).upload, false);
  for (const invalid of ['OK,HC05,2,9600,8N1,DEMO=TWINKLE+ODE', 'ECHO PONG', 'OK,PLAY junk', 'STATUS,PLAYING,999/001', 'STATUS,STOPPED,001/000', 'STATUS,PLAYING,002/001']) assert.equal(parseDeviceReply(invalid), null);
});
test('arbitrary notification splits and coalesced lines identify without starting playback', async () => {
  const f = fixture(); const task = f.session.request('HELLO');
  const bytes = new TextEncoder().encode('PONG\n' + HELLO + '\r\nSTATUS,MANUAL\n');
  for (let i = 0; i < bytes.length; i++) f.emit(bytes.slice(i, i + 1));
  const reply = await task;
  assert.equal(reply.type, 'HELLO');
  assert.match(f.session.snapshot().message, /检查上传能力/);
  assert.doesNotMatch(f.session.snapshot().message, /不支持整曲上传/);
  assert.deepEqual(f.sent, ['HELLO']);
  assert.equal(f.session.report, null, 'unsolicited status is not a query result');
  f.session.dispose();
});
test('writes alone, wrong ACK and echoes do not mean successful execution', async () => {
  const f = fixture(); await f.identify();
  const task = f.session.request('PLAY');
  f.emit('PLAY\nOK,STOP\nPONG\n');
  await Promise.resolve();
  assert.equal(f.session.snapshot().busy, true);
  assert.equal(f.session.report, null);
  await assert.rejects(f.session.request('STOP'), /上一条/);
  await assert.rejects(f.session.sendRaw('STATUS'), /上一条/);
  f.emit('OK,PLAY\n'); await task;
  assert.match(f.session.message, /已确认 PLAY/);
  assert.equal(f.session.report, null, 'ACK is not a fabricated playback position');
});
test('STATUS reports numeric item counters and local blocking errors remain errors', async () => {
  const f = fixture(); await f.identify();
  let task = f.session.request('STATUS'); f.emit('STATUS,PLAYING,003/084\n'); await task;
  assert.deepEqual(f.session.report, { type: 'STATUS', mode: 'PLAYING', position: 3, total: 84 });
  task = f.session.request('PLAY'); f.emit('ERR,LOCAL\n');
  await assert.rejects(task, /阻止/);
  assert.equal(f.session.report, null);
  task = f.session.request('STOP'); f.emit('OK,STOP\n'); await task;
});
test('unidentified sessions cannot control playback; raw debugging invalidates identity', async () => {
  const f = fixture();
  await assert.rejects(f.session.request('PLAY'), /识别/);
  await f.identify();
  await f.session.sendRaw('PING');
  assert.equal(f.session.identity, null);
  await assert.rejects(f.session.request('HELLO'), /重新连接/);
  f.setConnected(false); f.setConnected(true); await f.identify();
  assert.ok(f.session.identity);
});
test('timeout blocks late ACKs and never retries non-sequenced commands', async () => {
  const f = fixture(10); await f.identify();
  await assert.rejects(f.session.request('PLAY'), /超时.*结果未知/);
  f.emit('OK,PLAY\n');
  assert.equal(f.session.identity, null);
  await assert.rejects(f.session.request('PLAY'), /重新连接/);
  assert.deepEqual(f.sent, ['HELLO', 'PLAY']);
  f.setConnected(false); f.setConnected(true); await f.identify();
});
test('disconnect rejects pending requests, clears state, and requires a new HELLO', async () => {
  const f = fixture(); await f.identify();
  const task = f.session.request('STATUS'); f.setConnected(false);
  await assert.rejects(task, /断开/);
  assert.equal(f.session.identity, null); assert.equal(f.session.report, null);
  f.emit('STATUS,PLAYING,001/084\n'); assert.equal(f.session.report, null);
  f.setConnected(true); await assert.rejects(f.session.request('PLAY'), /识别/);
});
test('response arriving before write failure must not mark device identified', async () => {
  const f = fixture();
  f.transport.sendText = async () => { f.emit(HELLO + '\n'); throw new Error('lost link'); };
  await assert.rejects(f.session.request('HELLO'), /发送失败/);
  assert.equal(f.session.identity, null); assert.equal(f.session.snapshot().blocked, true);
});
test('overlong lines and stale partial responses are discarded until LF, then recover', async () => {
  const f = fixture(); f.emit('OK,');
  const task = f.session.request('HELLO');
  f.emit(HELLO.slice(3) + '\n');
  f.emit('x'.repeat(2000) + HELLO + '\n');
  assert.equal(f.session.identity, null); assert.equal(f.session.buffer.length, 0);
  f.emit(HELLO + '\n'); await task;
  const query = f.session.request('STATUS');
  f.emit('STATUS,MAN\rUAL\nSTATUS,MANUAL\n');
  await query; assert.equal(f.session.report.mode, 'MANUAL');
});
test('late completion from old transport write never changes a new session', async () => {
  const f = fixture(); let rejectOld;
  f.transport.sendText = () => new Promise((resolve, reject) => { rejectOld = reject; });
  const old = f.session.request('HELLO');
  f.setConnected(false); await assert.rejects(old, /断开/);
  f.transport.sendText = async () => {};
  f.setConnected(true); await f.identify();
  rejectOld(new Error('late write error')); await Promise.resolve(); await Promise.resolve();
  assert.ok(f.session.identity); assert.equal(f.session.snapshot().blocked, false);
});
