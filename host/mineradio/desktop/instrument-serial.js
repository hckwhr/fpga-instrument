'use strict';

// Chromium owns the serial stream. Only an explicit, trusted local chooser
// grants access; opening the app never selects or opens a physical port.
function attachInstrumentSerial(ses, dialog, isLocalAppUrl) {
  const grants = new Map();
  const trusted = wc => wc && !wc.isDestroyed() && isLocalAppUrl(wc.getURL());
  const espPort = port => ['303a', '0x303a', '12346'].includes(String(port.vendorId).toLowerCase());
  ses.setDevicePermissionHandler(details => {
    if (details.deviceType !== 'serial' || !isLocalAppUrl(details.origin)) return false;
    const device = details.device;
    // Electron exposes origin/device here, not a frame. Grant only a port
    // explicitly selected in a still-live local app window of that origin.
    return Boolean(device && espPort(device) && [...grants.values()].some(grant =>
      trusted(grant.wc) && new URL(grant.wc.getURL()).origin === details.origin && grant.portId === device.portId));
  });
  ses.on('select-serial-port', (event, ports, wc, callback) => {
    event.preventDefault();
    if (!trusted(wc) || wc._instrumentSerialChooser) { callback(''); return; }
    const candidates = ports.filter(espPort);
    if (!candidates.length) { callback(''); return; }
    let ended = false;
    const finish = portId => {
      if (ended) return;
      ended = true; clearTimeout(timer);
      wc._instrumentSerialChooser = false;
      wc.removeListener('destroyed', cancelled);
      wc.removeListener('did-start-navigation', navigated);
      if (portId && trusted(wc)) {
        if (!grants.has(wc.id)) wc.once('destroyed', () => grants.delete(wc.id));
        grants.set(wc.id, { wc, portId });
      }
      callback(portId && trusted(wc) ? portId : '');
    };
    const cancelled = () => { grants.delete(wc.id); finish(''); };
    const navigated = (_e, _url, inPlace, isMainFrame) => { if (!inPlace && isMainFrame) cancelled(); };
    const timer = setTimeout(() => finish(''), 30000);
    wc._instrumentSerialChooser = true;
    wc.once('destroyed', cancelled);
    wc.on('did-start-navigation', navigated);
    dialog.showMessageBox({ type: 'question', title: 'USB 有线备用',
      message: '请选择 ESP32-S3 原生 USB 串口',
      detail: '请先断开 BLE，并关闭串口监视器。确认后仅打开所选串口，不会烧录或复位设备。',
      buttons: [...candidates.map(p => `${p.displayName || 'ESP32-S3'} · ${p.portName}`), '取消'],
      defaultId: candidates.length, cancelId: candidates.length, noLink: true,
    }).then(result => finish(candidates[result.response]?.portId || ''), () => finish(''));
  });
}

module.exports = { attachInstrumentSerial };
