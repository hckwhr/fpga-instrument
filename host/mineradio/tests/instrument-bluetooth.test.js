const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { attachInstrumentBluetooth } = require('../desktop/instrument-bluetooth');

function setup(local = true) {
  const wc = new EventEmitter();
  const states = [];
  wc.mainFrame = {};
  wc.send = (channel, state) => { assert.equal(channel, 'instrument-bluetooth-state'); states.push(state); };
  wc.getURL = () => local ? 'http://127.0.0.1:3000/' : 'https://example.com/';
  const win = { webContents: wc, isDestroyed: () => false };
  attachInstrumentBluetooth(win, {}, url => url.startsWith('http://127.0.0.1:3000/'));
  const action = (payload, senderFrame = wc.mainFrame) => wc.emit('ipc-message', { senderFrame }, 'instrument-bluetooth-action', payload);
  return { wc, states, action };
}
const emit = (wc, callback) => wc.emit('select-bluetooth-device', { preventDefault() {} }, [{ deviceId: 's3', deviceName: '行者无疆' }], callback);

test('remote pages cannot select Bluetooth devices', () => {
  const { wc, states, action } = setup(false);
  action({ type: 'scan' });
  let selected;
  emit(wc, id => selected = id);
  assert.equal(selected, '');
  assert.deepEqual(states, []);
});

test('live discovery requires explicit selection and completes callback once', () => {
  const { wc, action, states } = setup();
  const replies = [];
  action({ type: 'scan' });
  const requestId = states[0].requestId;
  emit(wc, id => replies.push(id));
  emit(wc, () => assert.fail('duplicate callback'));
  assert.deepEqual(replies, []);
  assert.equal(states.at(-1).devices[0].deviceName, '行者无疆');
  action({ type: 'select', requestId, deviceId: 's3' });
  action({ type: 'select', requestId, deviceId: 's3' });
  assert.deepEqual(replies, ['s3']);
  assert.equal(states.at(-1).scanning, false);
});

test('cancel before discovery rejects late callbacks and permits fresh scan', () => {
  const { wc, action, states } = setup();
  action({ type: 'scan' });
  action({ type: 'cancel', requestId: states[0].requestId });
  let reply;
  emit(wc, id => reply = id);
  assert.equal(reply, '');
  action({ type: 'scan' });
  emit(wc, id => reply = id);
  action({ type: 'select', requestId: states.at(-1).requestId, deviceId: 's3' });
  assert.equal(reply, 's3');
});

test('navigation cancels and ignores stale selection', () => {
  const { wc, action, states } = setup();
  action({ type: 'scan' });
  const requestId = states[0].requestId;
  const replies = [];
  emit(wc, id => replies.push(id));
  wc.emit('did-start-navigation', {}, 'https://example.com', false, true);
  action({ type: 'select', requestId, deviceId: 's3' });
  assert.deepEqual(replies, ['']);
});

test('unknown IDs, stale requests and subframe IPC cannot select devices', () => {
  const { wc, action, states } = setup();
  action({ type: 'scan' }, {});
  assert.equal(states.length, 0);
  action({ type: 'scan' });
  const requestId = states[0].requestId;
  const replies = [];
  emit(wc, id => replies.push(id));
  action({ type: 'select', requestId, deviceId: 's3' }, {});
  action({ type: 'select', requestId: requestId + 1, deviceId: 's3' });
  action({ type: 'select', requestId, deviceId: 'injected' });
  assert.deepEqual(replies, []);
  action({ type: 'cancel', requestId });
  assert.deepEqual(replies, ['']);
});

test('timeout and destroyed windows release pending requests', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const { wc, action, states } = setup();
  action({ type: 'scan' });
  const replies = [];
  emit(wc, id => replies.push(id));
  t.mock.timers.tick(30001);
  assert.deepEqual(replies, ['']);
  assert.equal(states.at(-1).reason, 'timeout');
  action({ type: 'scan' });
  emit(wc, id => replies.push(id));
  wc.emit('destroyed');
  t.mock.timers.tick(30001);
  assert.deepEqual(replies, ['', '']);
});
