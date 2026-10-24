import test from 'node:test';
import assert from 'node:assert/strict';
import { UsbTransport, LinkTransport } from '../src/usb-transport.js';
import { DeviceSession } from '../src/device-session.js';
import { ScoreUploadSession } from '../src/score-upload.js';
import { ScoreReceiverModel } from '../tools/score-receiver-model.mjs';

function fixture() {
  const listeners = new Set(), data = new Set(), writes = [];
  const model = new ScoreReceiverModel({ abi: 13, words: 4096, playback: true });
  const emit = text => { for (const fn of data) fn(text); };
  const f = { writes, model, drop: false, failOpen: false };
  const raw = {
    connected: false, state: 'disconnected',
    onData(fn) { data.add(fn); }, onStatus(fn) { listeners.add(fn); },
    async connect() { this.connected = true; this.state = 'connected'; },
    async disconnect() { this.connected = false; this.state = 'disconnected'; for (const fn of listeners) fn({ state: this.state }); },
    async sendBytes(bytes) {
      const text = new TextDecoder().decode(bytes); writes.push(text);
      const [,token,op,seq,hex] = text.trim().split(',');
      f.token = token;
      if (f.drop) return;
      const reply = payload => emit(`boot log\n!USB1,0000000000000000,PONG\n!USB1,${token},${payload}\n`);
      if (op === 'OPEN') reply(f.failOpen ? 'ERR,BUSY' : 'READY');
      if (op === 'PING') reply('PONG');
      if (op === 'DATA') {
        reply(`OK,${seq}`);
        const response = model.receive(Buffer.from(hex, 'hex').toString());
        if (response) {
          const envelope = `!USB1,${token},RX,${Buffer.from(response).toString('hex').toUpperCase()}\n`;
          for (let i = 0; i < envelope.length; i += 7) emit(envelope.slice(i, i + 7));
        }
      }
    },
  };
  f.raw = raw; f.emit = emit;
  f.usb = new UsbTransport(raw, { timeoutMs: 25, heartbeatMs: 10000 });
  return f;
}

test('BLE is default, USB is explicit; inactive data cannot reach shared sessions', async () => {
  const ble = fixture().usb, usb = fixture().usb;
  const link = new LinkTransport({ ble, usb });
  assert.equal(link.kind, 'ble');
  let received = 0; link.onData(() => received++);
  link.select('usb'); await link.connect();
  assert.throws(() => link.select('ble'), /断开/);
  for (const fn of ble.dataListeners) fn('stale');
  assert.equal(received, 0);
  await link.disconnect(); link.select('ble');
  assert.equal(link.kind, 'ble');
});

test('USB carries a complete CRC-verified 4096-word upload and PLAY/STOP; bridge ACK alone is never device success', async () => {
  const f = fixture(); const device = new DeviceSession(f.usb);
  const uploader = new ScoreUploadSession(device);
  try {
    await f.usb.connect();
    assert.equal(device.snapshot().identity, null);
    await uploader.probe();
    const score = { abi: 13, words: Array(4096).fill(0n), length: 4096, endTick: 2048, melodyCount: 2048 };
    await uploader.upload(score);
    assert.equal(uploader.snapshot().confirmedWords, 4096);
    assert.equal(f.model.commits, 1);
    await uploader.control('PLAY', score); await uploader.control('STOP');
    assert.equal(uploader.snapshot().playback.state, 0);
    assert(f.writes.every(line => line.startsWith('!USB1,')));
  } finally { uploader.dispose(); await f.usb.disconnect(); }
});

test('USB refuses busy firmware and ignores debug logs, wrong tokens and stale replies after reconnect', async () => {
  const f = fixture(); f.failOpen = true;
  await assert.rejects(f.usb.connect(), /BUSY/);
  assert.equal(f.usb.connected, false);
  f.failOpen = false; await f.usb.connect(); const old = f.token;
  await f.usb.disconnect(); await f.usb.connect();
  let received = 0; f.usb.onData(() => received++);
  f.emit(`debug\n!USB1,${old},RX,50494E470A\n`);
  assert.equal(received, 0);
  await f.usb.disconnect();
});

test('USB ACK timeout invalidates session, never retries DATA, and reconnect starts a fresh queue', async () => {
  const f = fixture(); await f.usb.connect(); f.drop = true;
  await assert.rejects(f.usb.sendText('PING'), /超时/);
  await f.usb.disconnect();
  assert.equal(f.writes.filter(x => x.includes(',DATA,')).length, 1);
  f.drop = false; await f.usb.connect(); await f.usb.sendHeartbeat();
  assert.equal(f.usb.queued, 0); await f.usb.disconnect();
});

test('an early bridge ACK cannot hide a hung USB write; overlong log suffix is discarded', async () => {
  const f = fixture(); await f.usb.connect();
  let received = 0; f.usb.onData(() => received++);
  f.emit('x'.repeat(700) + `!USB1,${f.token},RX,50494E470A\n`);
  assert.equal(received, 0);
  const original = f.raw.sendBytes.bind(f.raw);
  let release;
  f.raw.sendBytes = async bytes => { await original(bytes); await new Promise(resolve => { release = resolve; }); };
  await assert.rejects(f.usb.sendText('PING'), /超时/);
  release(); await f.usb.disconnect();
  assert.equal(f.usb.connected, false);
});
