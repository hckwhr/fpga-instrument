import test from 'node:test';
import assert from 'node:assert/strict';
import { BleTransport, NUS_UUIDS, normalizeUuid } from '../src/ble-transport.js';

function fakeBle({ write = true, writeWithoutResponse = false } = {}) {
  const calls = [];
  const listeners = new Map();
  const characteristic = (properties, method) => ({
    properties,
    addEventListener(type, fn) { listeners.set(type, fn); },
    removeEventListener(type, fn) { if (listeners.get(type) === fn) listeners.delete(type); },
    async startNotifications() { calls.push('notify-start'); return this; },
    async stopNotifications() { calls.push('notify-stop'); },
    [method]: async (bytes) => { calls.push([method, [...bytes]]); },
    emit(bytes) { listeners.get('characteristicvaluechanged')?.({ target: { value: new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength) } }); },
  });
  const tx = characteristic({ write, writeWithoutResponse }, write ? 'writeValueWithResponse' : 'writeValueWithoutResponse');
  const service = { async getCharacteristic(uuid) { return uuid === NUS_UUIDS.write ? tx : rx; } };
  const rx = characteristic({ notify: true }, 'unused');
  const deviceListeners = new Map();
  const device = {
    name: 'FPGA-V3', gatt: { connected: true, async connect() { this.connected = true; return server; }, disconnect() { this.connected = false; calls.push('gatt-disconnect'); } },
    addEventListener(type, fn) { deviceListeners.set(type, fn); },
    removeEventListener(type, fn) { if (deviceListeners.get(type) === fn) deviceListeners.delete(type); },
    emitDisconnect() { deviceListeners.get('gattserverdisconnected')?.(); },
  };
  const server = { async getPrimaryService() { return service; } };
  const bluetooth = { async requestDevice(options) { calls.push(['request', options]); return device; } };
  return { bluetooth, device, tx, rx, calls };
}

test('UUID validation accepts configured values and rejects unsafe input', () => {
  assert.equal(normalizeUuid(NUS_UUIDS.service), NUS_UUIDS.service);
  assert.equal(normalizeUuid('180D'), '0000180d-0000-1000-8000-00805f9b34fb');
  assert.equal(normalizeUuid('12345678'), '12345678-0000-1000-8000-00805f9b34fb');
  assert.throws(() => normalizeUuid('javascript:alert(1)'), /格式无效/);
});

test('BLE discovers characteristics, subscribes notifications, and forwards bytes', async () => {
  const fake = fakeBle();
  const transport = new BleTransport(fake.bluetooth);
  const received = [];
  transport.onData(bytes => received.push([...bytes]));
  await transport.connect();
  assert.equal(transport.connected, true);
  assert.equal(fake.calls[0][0], 'request');
  assert.deepEqual(fake.calls[0][1].optionalServices, [NUS_UUIDS.service]);
  fake.rx.emit(new Uint8Array([0xE5, 0x8F, 0x8C]));
  assert.deepEqual(received, [[0xE5, 0x8F, 0x8C]]);
  await transport.disconnect();
  assert.equal(transport.connected, false);
  assert.ok(fake.calls.includes('gatt-disconnect'));
  fake.rx.emit(new Uint8Array([1]));
  assert.equal(received.length, 1, 'notification listener removed');
});

test('BLE writes are serialized and split into browser-sized chunks', async () => {
  const fake = fakeBle();
  const transport = new BleTransport(fake.bluetooth, { chunkSize: 4 });
  await transport.connect();
  const first = transport.sendBytes(new Uint8Array([1, 2, 3, 4, 5]));
  const second = transport.sendText('OK', { newline: false });
  assert.equal(await first, 5);
  assert.equal(await second, 2);
  assert.deepEqual(fake.calls.filter(item => Array.isArray(item) && item[0] === 'writeValueWithResponse').map(item => item[1]), [[1,2,3,4],[5],[79,75]]);
});

test('BLE falls back to Write Without Response and cleans up on device disconnect', async () => {
  const fake = fakeBle({ write: false, writeWithoutResponse: true });
  const transport = new BleTransport(fake.bluetooth, { chunkSize: 20 });
  await transport.connect();
  await transport.sendBytes(new Uint8Array([7]));
  assert.deepEqual(fake.calls.find(item => Array.isArray(item) && item[0] === 'writeValueWithoutResponse'), ['writeValueWithoutResponse', [7]]);
  fake.device.emitDisconnect();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(transport.connected, false);
});

test('BLE connection failure leaves no stale device state', async () => {
  const fake = fakeBle();
  fake.device.gatt.connect = async () => { throw new Error('radio unavailable'); };
  const transport = new BleTransport(fake.bluetooth);
  await assert.rejects(transport.connect(), /radio unavailable/);
  assert.equal(transport.device, null);
  assert.equal(transport.state, 'disconnected');
});

test('a disconnected notification subscription cannot later report connected', async () => {
  const fake = fakeBle(); const transport = new BleTransport(fake.bluetooth);
  const states = []; transport.onStatus(s => states.push(s.state));
  fake.rx.startNotifications = async () => { fake.device.emitDisconnect(); };
  await assert.rejects(transport.connect(), /取消或断开/);
  assert.equal(transport.state, 'disconnected');
  assert.ok(!states.includes('connected'));
});
test('queued writes snapshot bytes and a partial failure cancels the following command', async () => {
  const fake = fakeBle(); const transport = new BleTransport(fake.bluetooth, { chunkSize: 2 });
  await transport.connect();
  const data = new Uint8Array([1,2,3]);
  const first = transport.sendBytes(data); data.fill(9);
  await first;
  assert.deepEqual(fake.calls.filter(x => x[0] === 'writeValueWithResponse').map(x => x[1]), [[1,2],[3]]);
  let writes = 0;
  fake.tx.writeValueWithResponse = async () => { if (++writes === 2) throw new Error('lost write'); };
  const results = await Promise.allSettled([transport.sendText('ABCD'), transport.sendText('PLAY')]);
  assert.deepEqual(results.map(r => r.status), ['rejected', 'rejected']);
  assert.equal(writes, 2);
  assert.equal(transport.connected, false);
  await transport.connect();
  await transport.sendText('PING');
  assert.equal(transport.connected, true);
});
test('drop during last write is rejected and a fresh session is independent', async () => {
  const fake = fakeBle(); const transport = new BleTransport(fake.bluetooth);
  await transport.connect();
  let release;
  fake.tx.writeValueWithResponse = () => new Promise(resolve => { release = resolve; });
  const sending = transport.sendText('X');
  await new Promise(resolve => setImmediate(resolve));
  await transport.disconnect();
  await transport.connect();
  release();
  await assert.rejects(sending, /断开/);
  assert.equal(transport.connected, true);
});
test('device chooser cannot be bypassed by a second connect or disconnect', async () => {
  const fake = fakeBle(); let select;
  fake.bluetooth.requestDevice = () => new Promise(resolve => { select = resolve; });
  const transport = new BleTransport(fake.bluetooth);
  const connecting = transport.connect();
  await assert.rejects(transport.connect(), /尚未结束/);
  await assert.rejects(transport.disconnect(), /选择窗口/);
  select(fake.device); await connecting;
  assert.equal(transport.connected, true);
});
