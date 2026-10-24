'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { attachInstrumentSerial } = require('../desktop/instrument-serial');

function fixture() {
  const ses = new EventEmitter();
  ses.setDevicePermissionHandler = handler => { ses.permission = handler; };
  const wc = new EventEmitter();
  wc.id = 1; wc.url = 'http://127.0.0.1:3210/'; wc.dead = false;
  wc.getURL = () => wc.url; wc.isDestroyed = () => wc.dead;
  const isLocal = url => /^http:\/\/127\.0\.0\.1:3210(?:\/|$)/.test(url);
  let answer, options;
  const dialog = { showMessageBox(config) { options = config; return new Promise(resolve => { answer = resolve; }); } };
  attachInstrumentSerial(ses, dialog, isLocal);
  const ports = [{ portId: 'esp', vendorId: '303a', portName: 'COM21' },
    { portId: 'other', vendorId: '1234', portName: 'COM1' }];
  let result;
  const choose = () => ses.emit('select-serial-port', { preventDefault() {} }, ports, wc, id => { result = id; });
  const allowed = () => ses.permission({ deviceType: 'serial', origin: 'http://127.0.0.1:3210', device: ports[0] });
  return { ses, wc, ports, choose, allowed, reply: n => answer({ response: n }),
    get result() { return result; }, get options() { return options; } };
}

test('USB needs explicit trusted selection, cancel default, and exact port grant', async () => {
  const f = fixture(); assert.equal(f.allowed(), false);
  f.choose();
  assert.equal(f.options.buttons.length, 2, 'non-Espressif ports excluded');
  assert.equal(f.options.defaultId, 1);
  f.reply(0); await new Promise(setImmediate);
  assert.equal(f.result, 'esp'); assert.equal(f.allowed(), true);
  assert.equal(f.ses.permission({ deviceType: 'serial', origin: 'https://evil.example', device: f.ports[0] }), false);
  assert.equal(f.ses.permission({ deviceType: 'serial', origin: 'http://127.0.0.1:3210', device: { ...f.ports[0], portId: 'other' } }), false);
  f.wc.dead = true; f.wc.emit('destroyed');
  assert.equal(f.allowed(), false);
});

test('navigation cancels USB chooser and late dialog response cannot grant a port', async () => {
  const f = fixture(); f.choose();
  f.wc.emit('did-start-navigation', {}, 'https://evil.example', false, true);
  assert.equal(f.result, ''); f.reply(0); await new Promise(setImmediate);
  assert.equal(f.result, ''); assert.equal(f.allowed(), false);
  f.wc.url = 'https://evil.example'; f.choose(); assert.equal(f.result, '');
});

test('cancel does not select a port or create a permission grant', async () => {
  const f = fixture(); f.choose(); f.reply(1); await new Promise(setImmediate);
  assert.equal(f.result, ''); assert.equal(f.allowed(), false);
});
