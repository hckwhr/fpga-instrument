'use strict';

// Discovery stays in Chromium and GATT in BleTransport. The bridge only owns
// the explicit chooser; renderer input cannot select undiscovered device IDs.
function attachInstrumentBluetooth(win, _dialog, isLocalAppUrl) {
  const wc = win.webContents;
  let pending = null;
  let sequence = 0;
  const trusted = () => !win.isDestroyed() && isLocalAppUrl(wc.getURL());
  const publish = payload => { if (trusted()) wc.send('instrument-bluetooth-state', payload); };
  const finish = (reason, deviceId = '') => {
    const request = pending;
    if (!request) return;
    pending = null;
    clearTimeout(request.timer);
    publish({ requestId: request.id, scanning: false, reason, deviceId, devices: request.devices });
    request.callback?.(deviceId);
  };
  wc.on('ipc-message', (event, channel, action) => {
    if (channel !== 'instrument-bluetooth-action' || !trusted() || event.senderFrame !== wc.mainFrame) return;
    if (action?.type === 'scan') {
      if (pending) return;
      const request = { id: ++sequence, devices: [], callback: null };
      pending = request;
      request.timer = setTimeout(() => finish('timeout'), 30000);
      publish({ requestId: request.id, scanning: true, devices: [] });
    } else if (pending && action?.requestId === pending.id) {
      if (action.type === 'cancel') finish('cancelled');
      else if (action.type === 'select' && pending.callback && pending.devices.some(d => d.deviceId === action.deviceId)) finish('selected', action.deviceId);
    }
  });
  wc.on('select-bluetooth-device', (event, devices, callback) => {
    event.preventDefault();
    if (!trusted() || !pending) { callback(''); return; }
    pending.callback ??= callback;
    pending.devices = devices.filter(d => typeof d.deviceId === 'string' && d.deviceId).map(d => ({ deviceId: d.deviceId, deviceName: String(d.deviceName || '未命名 BLE 设备') }));
    publish({ requestId: pending.id, scanning: true, devices: pending.devices });
  });
  wc.on('did-start-navigation', (_event, _url, inPlace) => { if (!inPlace) finish('navigation'); });
  wc.once('destroyed', () => {
    if (pending) { clearTimeout(pending.timer); const callback = pending.callback; pending = null; callback?.(''); }
  });
}

module.exports = { attachInstrumentBluetooth };
