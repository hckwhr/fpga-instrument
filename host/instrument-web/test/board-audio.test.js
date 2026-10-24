import test from 'node:test';
import assert from 'node:assert/strict';
import { DeviceSession } from '../src/device-session.js';
import { BOARD_AUDIO, BoardAudioSession, parseScopeBlock, scopeRequest, boardSpectrum } from '../src/board-audio.js';

// Independent bitwise CCITT reference; same public wire contract as the RTL.
function line(body) {
  let crc = 65535;
  for (const ch of body) {
    crc ^= ch.charCodeAt(0) << 8;
    for (let i = 0; i < 8; i++) crc = ((crc << 1) ^ (crc & 32768 ? 4129 : 0)) & 65535;
  }
  return `${body},${crc.toString(16).toUpperCase().padStart(4, '0')}\n`;
}
function block(id, index) {
  const payload = Array.from({ length: 32 }, (_, i) => {
    const v = (index * 32 + i) & 255;
    return [v, 255 - v].map(x => x.toString(16).toUpperCase().padStart(2, '0')).join('');
  }).join('');
  return line(`SCOPE1,${id},${index.toString(16).toUpperCase().padStart(2, '0')},${payload}`);
}
function fixture(timeoutMs = 500) {
  const data = new Set(), status = new Set(), sent = [];
  const transport = { connected: true,
    onData(fn) { data.add(fn); return () => data.delete(fn); },
    onStatus(fn) { status.add(fn); return () => status.delete(fn); },
    sendText(text) { sent.push(text); return Promise.resolve(); } };
  const device = new DeviceSession(transport), session = new BoardAudioSession(device, { timeoutMs });
  const emit = value => { for (const fn of data) fn(value); };
  const connect = connected => { transport.connected = connected; for (const fn of status) fn({ state: connected ? 'connected' : 'disconnected' }); };
  const id = () => sent.at(-1).split(',')[1];
  const frame = () => { for (let i = 0; i < 32; i++) emit(block(id(), i)); };
  return { device, session, transport, sent, emit, connect, id, frame, dispose() { session.dispose(); device.dispose(); } };
}
test('SCOPE1 request, CRC, bounds and signed wire payload', () => {
  assert.equal(scopeRequest('0123ABCD'), line('SCOPE1,0123ABCD'));
  assert.throws(() => scopeRequest('bad'));
  const good = block('0123ABCD', 31).trim();
  assert.equal(good.length, 152);
  assert.equal(parseScopeBlock(good).bytes.length, 64);
  for (const bad of [good.replace('SCOPE1', 'SCOPE2'), good.slice(0, -1) + 'X', good.replace(',1F,', ',20,'), good.toLowerCase()]) assert.equal(parseScopeBlock(bad), null);
});
test('fragments and coalesced notifications yield exactly 1024 real dry/wet samples; exclusive ownership blocks other writes', async () => {
  const f = fixture(), task = f.session.capture();
  await assert.rejects(f.device.request('PING'), /上一条/);
  await assert.rejects(f.session.capture(), /尚未完成/);
  f.emit(block('FFFFFFFF' === f.id() ? '00000000' : 'FFFFFFFF', 0));
  const text = Array.from({ length: 32 }, (_, i) => block(f.id(), i)).join('');
  const bytes = new TextEncoder().encode(text);
  for (let i = 0; i < bytes.length; i += 17) f.emit(bytes.slice(i, i + 17));
  const frame = await task;
  assert.equal(frame.sampleRate, 48000);
  for (let i = 0; i < BOARD_AUDIO.samples; i++) {
    const value = i & 255, signed = v => (v >= 128 ? v - 256 : v) / 128;
    assert.equal(frame.dry[i], signed(value)); assert.equal(frame.wet[i], signed(255 - value));
  }
  assert.equal(f.device.snapshot().busy, false); assert.equal(f.device.snapshot().blocked, false);
  f.connect(false); assert.equal(f.session.frame, null); f.dispose();
});
test('a full reply cannot complete before write success, nor hide write failure', async () => {
  for (const fail of [false, true]) {
    const f = fixture(); let done, reject;
    f.transport.sendText = text => { f.sent.push(text); return new Promise((a, b) => { done = a; reject = b; }); };
    const task = f.session.capture(); f.frame();
    assert.equal(f.session.snapshot().busy, true); assert.equal(f.session.frame, null);
    if (fail) { reject(Error('failed')); await assert.rejects(task, /发送失败/); assert.equal(f.device.snapshot().blocked, true); }
    else { done(); await task; assert.ok(f.session.frame); }
    f.dispose();
  }
});
test('bad CRC, missing/out of order and duplicate blocks discard whole capture and block unsafe retries', async () => {
  for (const broken of ['crc', 'missing', 'duplicate', 'nonascii']) {
    const f = fixture(), task = f.session.capture();
    if (broken === 'nonascii') f.emit('\0');
    else if (broken === 'crc') f.emit(block(f.id(), 0).replace(',00,', ',01,'));
    else if (broken === 'missing') f.emit(block(f.id(), 1));
    else { f.emit(block(f.id(), 0)); f.emit(block(f.id(), 0)); }
    await assert.rejects(task, /校验失败|格式错误/);
    assert.equal(f.session.frame, null); assert.equal(f.device.snapshot().blocked, true);
    await assert.rejects(f.session.capture(), /重.*连接/); f.dispose();
  }
});
test('timeout and disconnect reject incomplete capture; stale write rejection cannot kill a new connection', async () => {
  const timed = fixture(10), timeout = timed.session.capture();
  timed.emit(block(timed.id(), 0)); await assert.rejects(timeout, /超时/);
  assert.equal(timed.session.frame, null); assert.equal(timed.device.snapshot().blocked, true); timed.dispose();
  const f = fixture(); let rejectOld;
  f.transport.sendText = text => { f.sent.push(text); return new Promise((a, b) => { rejectOld = b; }); };
  const old = f.session.capture(); f.connect(false); await assert.rejects(old, /不可用/);
  f.connect(true); f.transport.sendText = text => { f.sent.push(text); return Promise.resolve(); };
  const current = f.session.capture(); rejectOld(Error('old write'));
  await Promise.resolve(); await Promise.resolve(); assert.equal(f.session.snapshot().busy, true);
  f.frame(); await current; assert.equal(f.device.snapshot().blocked, false); f.dispose();
});
test('legacy firmware rejection leaves song commands usable and suppresses unsupported auto requests', async () => {
  const f = fixture(), task = f.session.capture(); f.emit('ERR,LINE\n');
  await assert.rejects(task, /不支持音频回传/);
  assert.equal(f.session.snapshot().unsupported, true); assert.equal(f.device.snapshot().blocked, false);
  const ping = f.device.request('PING'); f.emit('PONG\n'); await ping;
  await assert.rejects(f.session.capture(), /更新/); f.dispose();
});
test('FFT measures known actual PCM bins and amplitudes, not score-derived harmonics', () => {
  const n = 1024, values = Float32Array.from({ length: n }, (_, i) => .5 * Math.sin(2 * Math.PI * 16 * i / n) + .25 * Math.sin(2 * Math.PI * 40 * i / n));
  const spectrum = boardSpectrum(values);
  assert.ok(Math.abs(spectrum[16] + 6.0206) < .01); assert.ok(Math.abs(spectrum[40] + 12.0412) < .01);
  assert.ok(spectrum[100] < -80); assert.equal(spectrum.length, 513);
  assert.ok(boardSpectrum(new Float32Array(1024)).every(v => v === -96));
  assert.throws(() => boardSpectrum(new Float32Array(32)), /完整/);
});
