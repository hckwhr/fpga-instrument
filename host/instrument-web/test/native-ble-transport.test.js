import test from 'node:test';
import assert from 'node:assert/strict';
import { NativeBleTransport } from '../src/native-ble-transport.js';
function fixture() {
  let listener;
  const calls = [];
  const bridge = { subscribe(fn) { listener = fn; return () => {}; }, async request(op, value) { calls.push({ op, value }); return { name: '行者无疆' }; } };
  return { bridge, calls, emit: msg => listener(msg), transport: new NativeBleTransport(bridge) };
}
test('native transport needs no Web Bluetooth, serializes snapshots and forwards only current notifications', async () => {
  const f = fixture(), received = [];
  f.transport.onData(bytes => received.push([...bytes]));
  await f.transport.connect();
  const sessionId = f.calls[0].value.sessionId;
  const bytes = Uint8Array.of(1, 2);
  const a = f.transport.sendBytes(bytes); bytes[0] = 9;
  await Promise.all([a, f.transport.sendText('PING')]);
  assert.equal(f.calls[1].value.data, 'AQI=');
  assert.equal(atob(f.calls[2].value.data), 'PING\n');
  f.emit({ type: 'ble-data', sessionId: 'old', data: 'Aw==' });
  f.emit({ type: 'ble-data', sessionId, data: 'BA==' });
  assert.deepEqual(received, [[4]]);
  await f.transport.disconnect(); assert.equal(f.transport.connected, false);
});
test('partial native write failure cancels the following command and requires reconnect', async () => {
  const f = fixture(); await f.transport.connect();
  const request = f.bridge.request.bind(f.bridge);
  f.bridge.request = (op, value) => op === 'ble-write' ? Promise.reject(Error('radio failed')) : request(op, value);
  const results = await Promise.allSettled([f.transport.sendText('A'), f.transport.sendText('B')]);
  assert.deepEqual(results.map(r => r.status), ['rejected', 'rejected']);
  assert.equal(f.transport.connected, false);
});
test('late native completion and disconnect from an old connection cannot affect a new session', async () => {
  const f = fixture(); await f.transport.connect();
  const oldId = f.calls[0].value.sessionId;
  const request = f.bridge.request.bind(f.bridge); let finish;
  f.bridge.request = (op, value) => op === 'ble-write' ? new Promise(resolve => { finish = resolve; }) : request(op, value);
  const writing = f.transport.sendText('A');
  const rejected = assert.rejects(writing, /更换/);
  await Promise.resolve();
  f.emit({ type: 'ble-disconnected', sessionId: oldId });
  await f.transport.connect(); finish({}); await rejected;
  f.emit({ type: 'ble-disconnected', sessionId: oldId });
  assert.equal(f.transport.connected, true);
});
test('cancelling native device chooser cannot resurrect a late connection', async () => {
  const f = fixture(), request = f.bridge.request.bind(f.bridge); let finish;
  f.bridge.request = (op, value) => op === 'ble-connect' ? new Promise(resolve => { finish = resolve; }) : request(op, value);
  const connecting = f.transport.connect(); const rejected = assert.rejects(connecting, /更换/);
  await assert.rejects(f.transport.connect(), /尚未结束/);
  await f.transport.disconnect(); finish({ name: 'late' }); await rejected;
  assert.equal(f.transport.connected, false);
});
