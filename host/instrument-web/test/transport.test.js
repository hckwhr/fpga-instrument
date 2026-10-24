import test from 'node:test';
import assert from 'node:assert/strict';
import { Transport } from '../src/transport.js';

function fixture({ denied = false, openFails = false, writeFails = false } = {}) {
  let rx;
  const writes = [];
  const port = {
    readable: new ReadableStream({ start(controller) { rx = controller; } }),
    writable: new WritableStream({ write(bytes) { if (writeFails) throw new Error('write lost'); writes.push([...bytes]); } }),
    async open(options) { if (openFails) throw new Error('busy'); this.options = options; },
    async close() { assert.equal(this.readable.locked, false); assert.equal(this.writable.locked, false); this.closed = true; },
  };
  const serial = new EventTarget();
  serial.requestPort = async () => { if (denied) throw new DOMException('cancelled', 'NotFoundError'); return port; };
  return { port, serial, writes, get rx() { return rx; }, transport: new Transport(serial) };
}

test('opens configured port, preserves split UTF-8 and orders sends, releases locks', async () => {
  const f = fixture(); const received = []; const states = [];
  f.transport.onData((text) => received.push(text));
  f.transport.onStatus((status) => states.push(status.state));
  await f.transport.connect({ baudRate: 38400 });
  assert.equal(f.port.options.baudRate, 38400);
  const bytes = new TextEncoder().encode('中文\n');
  f.rx.enqueue(bytes.slice(0, 2)); f.rx.enqueue(bytes.slice(2));
  await Promise.all([f.transport.sendText('A'), f.transport.sendText('B', { newline: false })]);
  assert.deepEqual(f.writes, [[65, 10], [66]]);
  assert.equal(received.join(''), '中文\n');
  await f.transport.disconnect();
  assert.equal(f.port.closed, true);
  assert.deepEqual(states, ['connecting', 'connected', 'disconnecting', 'disconnected']);
  await assert.rejects(f.transport.sendText('x'), /先连接/);
});
test('cancel, open failure and unavailable API never report a connected device', async () => {
  for (const options of [{ denied: true }, { openFails: true }]) {
    const f = fixture(options); await assert.rejects(f.transport.connect());
    assert.equal(f.transport.state, 'disconnected');
    assert.equal(f.transport.connected, false);
  }
  await assert.rejects(new Transport(null).connect(), /Web Serial/);
});
test('rejects oversized UTF-8 and invalid baud rates', async () => {
  const f = fixture();
  await assert.rejects(f.transport.connect({ baudRate: 1 }), /波特率/);
  await f.transport.connect();
  await assert.rejects(f.transport.sendText('中'.repeat(86)), /256/);
  await assert.rejects(f.transport.sendText(' '), /不能为空/);
  assert.equal(f.writes.length, 0); await f.transport.disconnect();
});
test('physical disconnect clears state and closes locks, read errors also clean up', async () => {
  for (const mode of ['disconnect', 'readError']) {
    const f = fixture(); await f.transport.connect();
    const closed = new Promise((resolve) => f.transport.onStatus((s) => { if (s.state === 'disconnected') resolve(); }));
    if (mode === 'readError') f.rx.error(new Error('lost link'));
    else { const event = new Event('disconnect'); event.port = f.port; f.serial.dispatchEvent(event); }
    await closed; assert.equal(f.port.closed, true); assert.equal(f.transport.connected, false);
  }
});
test('write errors reject instead of reporting upload success', async () => {
  const f = fixture({ writeFails: true }); await f.transport.connect();
  await assert.rejects(f.transport.sendText('PING'), /write lost/);
  await f.transport.disconnect(); assert.equal(f.transport.connected, false);
});
