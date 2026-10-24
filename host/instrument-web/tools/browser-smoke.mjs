// No npm dependencies: drive an installed Chromium through its DevTools API.
// BLE is mocked explicitly; this checks UI lifecycle, not hardware.
import { createServer } from 'node:http';
import { readFile, mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';
import { resolve, dirname, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const prefix = '/fpga-instrument-web/';
const server = createServer(async (req, res) => {
  try {
    const pathname = new URL(req.url, 'http://localhost').pathname;
    if (!pathname.startsWith(prefix)) { res.writeHead(404).end(); return; }
    const relative = pathname.slice(prefix.length) || 'index.html';
    const target = resolve(root, 'dist', relative);
    if (!target.startsWith(resolve(root, 'dist') + sep)) { res.writeHead(403).end(); return; }
    const bytes = await readFile(target);
    res.writeHead(200, { 'Content-Type': ({ '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html; charset=utf-8', '.wasm': 'application/wasm', '.json': 'application/json' })[extname(target)] || 'application/octet-stream' });
    res.end(bytes);
  } catch { res.writeHead(404).end(); }
});
await new Promise((done) => server.listen(0, '127.0.0.1', done));
const profile = await mkdtemp(resolve(tmpdir(), 'instrument-browser-'));
const browser = spawn(process.env.CHROME_PATH || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { windowsHide: true });
let socket;
try {
  const endpoint = await new Promise((done, reject) => {
    let output = '';
    const finish = (error, endpoint) => { clearInterval(poll); clearTimeout(timer); error ? reject(error) : done(endpoint); };
    const poll = setInterval(async () => {
      try {
        const [port, path] = (await readFile(resolve(profile, 'DevToolsActivePort'), 'utf8')).trim().split(/\r?\n/);
        if (port && path) finish(null, `ws://127.0.0.1:${port}${path}`);
      } catch { /* Browser has not published the endpoint yet. */ }
    }, 200);
    const timer = setTimeout(() => finish(new Error(`Browser launch timed out: ${output.slice(-1500)}`)), 20000);
    browser.on('error', (error) => finish(error));
    browser.stderr.on('data', (part) => { output += part; const match = output.match(/DevTools listening on (ws:\/\/\S+)/); if (match) finish(null, match[1]); });
  });
  socket = new WebSocket(endpoint);
  await new Promise((done, reject) => { socket.onopen = done; socket.onerror = reject; });
  let id = 0; const requests = new Map(); const errors = [];
  socket.onmessage = ({ data }) => {
    const event = JSON.parse(data);
    if (event.id) { const pending = requests.get(event.id); requests.delete(event.id); clearTimeout(pending.timer); event.error ? pending.reject(new Error(event.error.message)) : pending.done(event.result); }
    if (event.method === 'Runtime.exceptionThrown') errors.push(event.params.exceptionDetails.text);
  };
  const command = (method, params = {}, sessionId) => new Promise((done, reject) => {
    const key = ++id; const timer = setTimeout(() => reject(new Error(`CDP timeout: ${method}`)), 10000);
    requests.set(key, { done, reject, timer }); socket.send(JSON.stringify({ id: key, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  const { targetId } = await command('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await command('Target.attachToTarget', { targetId, flatten: true });
  const page = (method, params) => command(method, params, sessionId);
  const evaluate = async (expression) => {
    const result = await page('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  await page('Runtime.enable'); await page('Page.enable');
  await page('Page.addScriptToEvaluateOnNewDocument', { source: `
    // BLE must work without Web Serial (including Android Chrome).
    Object.defineProperty(navigator, 'serial', {value: undefined, configurable: true});
    const notify = new EventTarget();
    notify.properties = { notify: true };
    notify.startNotifications = async () => notify;
    window.emitBle = bytes => {
      notify.value = new DataView(new Uint8Array(bytes).buffer);
      notify.dispatchEvent(new Event('characteristicvaluechanged'));
    };
    window.bleWritten = [];
    const write = { properties: { write: true }, writeValueWithResponse: async b => { window.bleWritten.push(...b); await window.onBleWrite?.(b); } };
    const device = new EventTarget(); device.name = '行者无疆';
    device.gatt = { connected: false,
      async connect() { this.connected = true; return { getPrimaryService: async () => ({ getCharacteristic: async uuid => uuid.includes('0002-') ? write : notify }) }; },
      disconnect() { this.connected = false; device.dispatchEvent(new Event('gattserverdisconnected')); }
    };
    Object.defineProperty(navigator, 'bluetooth', { value: { requestDevice: async options => { window.bleRequest = options; return device; } }, configurable: true });
  ` });
  await page('Emulation.setDeviceMetricsOverride', { width: 1280, height: 1050, deviceScaleFactor: 1, mobile: false });
  const siteUrl = process.argv.find(arg => arg.startsWith('--site='))?.slice(7);
  await page('Page.navigate', { url: siteUrl || `http://127.0.0.1:${server.address().port}${prefix}` });
  // Await the module's final status update, not a timing-dependent screenshot delay.
  await evaluate(`new Promise((resolve,reject)=>{ const timer=setTimeout(()=>reject(Error('UI load timeout')),5000); const poll=()=>{if(document.querySelector('#status')?.textContent.includes('不会自动发送')){clearTimeout(timer);resolve(true)}else setTimeout(poll,20)};poll()})`);
  assert.equal(await evaluate(`document.title`), 'FPGA 乐器 · 曲谱工作台');
  assert.equal(await evaluate(`getComputedStyle(document.head).display`), 'none', 'Browser default stylesheet must load');
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('main')).display`), 'block');
  assert.equal(await evaluate(`document.querySelector('main').getBoundingClientRect().width`), 1180, 'Desktop stylesheet and container width');
  assert.equal(await evaluate(`document.querySelector('#send').disabled`), true);
  assert.equal(await evaluate(`document.querySelector('#device-panel').open`), false, 'Device tools start collapsed');
  assert.equal(await evaluate(`document.querySelector('#connection-mode').value`), 'ble', 'BLE remains the default');
  assert.equal(await evaluate(`document.querySelector('#connection-mode option[value="usb"]').disabled`), true, 'USB fallback requires Serial API');
  assert.equal(await evaluate(`document.body.textContent.includes('HC-05')`), false);
  assert.equal(await evaluate(`document.querySelector('#connect').disabled`), false, 'BLE needs no Serial API');
  await evaluate(`document.querySelector('#tab-midi').click()`);
  assert.equal(await evaluate(`document.querySelector('#audio-pane').hidden && !document.querySelector('#midi-pane').hidden`), true);
  await evaluate(`document.querySelector('#tab-midi').focus()`);
  await page('Input.dispatchKeyEvent', { type: 'keyDown', key: 'ArrowLeft', code: 'ArrowLeft' });
  assert.equal(await evaluate(`document.activeElement.id`), 'tab-audio');
  assert.equal(await evaluate(`document.querySelector('#audio-pane').hidden`), false);
  await evaluate(`document.activeElement.blur()`);
  const emptyImage = await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  await mkdir(resolve(root, 'evidence'), { recursive: true });
  await writeFile(resolve(root, 'evidence/ui-empty-desktop.png'), Buffer.from(emptyImage.data, 'base64'));
  const canvasPixel = `Array.from(document.querySelector('#piano-roll').getContext('2d').getImageData(50,2,1,1).data)`;
  assert.equal(await evaluate(`document.documentElement.dataset.theme`), 'light');
  assert.deepEqual(await evaluate(canvasPixel), [250,247,240,255]);
  await evaluate(`document.querySelector('#theme-toggle').focus()`);
  assert.equal(await evaluate(`document.activeElement.id`), 'theme-toggle');
  await page('Page.bringToFront');
  await page('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r' });
  await page('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
  assert.equal(await evaluate(`document.documentElement.dataset.theme`), 'dark');
  assert.equal(await evaluate(`document.querySelector('#theme-toggle').getAttribute('aria-pressed')`), 'true');
  assert.deepEqual(await evaluate(canvasPixel), [36,33,30,255], 'Canvas must repaint immediately');
  // Leave the old document before revisiting so the ready check cannot match stale UI.
  await page('Page.navigate', { url: 'about:blank' });
  await evaluate(`document.readyState`);
  await page('Page.navigate', { url: siteUrl || `http://127.0.0.1:${server.address().port}${prefix}` });
  await evaluate(`new Promise((resolve,reject)=>{ const timer=setTimeout(()=>reject(Error('Theme reload timeout')),5000); const poll=()=>{if(document.querySelector('#status')?.textContent.includes('不会自动发送')){clearTimeout(timer);resolve(true)}else setTimeout(poll,20)};poll()})`);
  assert.equal(await evaluate(`document.documentElement.dataset.theme`), 'dark', 'Saved theme survives navigation');
  assert.equal(await evaluate(`getComputedStyle(document.documentElement).colorScheme`), 'dark');
  const darkDesktop = await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  await writeFile(resolve(root, 'evidence/theme-dark-desktop.png'), Buffer.from(darkDesktop.data, 'base64'));
  await evaluate(`document.querySelector('#theme-toggle').click()`);
  assert.equal(await evaluate(`localStorage.getItem('instrument-theme')`), 'light');
  assert.deepEqual(await evaluate(canvasPixel), [250,247,240,255]);
  // Persist an actual parsed MIDI, then reload and restore settings through UI.
  const { root: libraryDom } = await page('DOM.getDocument');
  const { nodeId: midiInputId } = await page('DOM.querySelector', { nodeId: libraryDom.nodeId, selector: '#midi-file' });
  await page('DOM.setFileInputFiles', { nodeId: midiInputId, files: [resolve(root, 'test/fixtures/fpga-scores/twinkle.mid')] });
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(!document.querySelector('#library-save').disabled)resolve();else if(n++>100)reject(Error('MIDI load'));else setTimeout(poll,20)};poll()})`);
  await evaluate(`document.querySelector('#speed').value='125'; document.querySelector('#speed').dispatchEvent(new Event('input')); document.querySelector('#velocity').value='75'; document.querySelector('#velocity').dispatchEvent(new Event('input')); document.querySelector('#library-title').value='星光练习'; document.querySelector('#library-save').click()`);
  assert.equal(await evaluate(`document.querySelector('#library-count').textContent`), '1 / 20');
  const savedDuration = await evaluate(`document.querySelector('#duration').textContent`);
  await page('Page.navigate', { url: 'about:blank' });
  await evaluate(`document.readyState`);
  await page('Page.navigate', { url: siteUrl || `http://127.0.0.1:${server.address().port}${prefix}` });
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(document.querySelector('#library-count')?.textContent==='1 / 20')resolve();else if(n++>100)reject(Error('Library reload'));else setTimeout(poll,20)};poll()})`);
  assert.equal(await evaluate(`document.querySelector('#send').disabled`), true);
  assert.equal(await evaluate(`document.querySelector('#preview-notes').disabled`), true, 'No automatic playback or project open');
  await evaluate(`document.querySelector('#library-list button').click()`);
  assert.equal(await evaluate(`document.querySelector('#speed').value`), '125');
  assert.equal(await evaluate(`document.querySelector('#velocity').value`), '75');
  assert.equal(await evaluate(`document.querySelector('#duration').textContent`), savedDuration);
  assert.equal(await evaluate(`document.querySelector('#source-audio').hasAttribute('src')`), false);
  await evaluate(`document.querySelector('#library-search').value='不存在'; document.querySelector('#library-search').dispatchEvent(new Event('input'))`);
  assert.match(await evaluate(`document.querySelector('#library-list').textContent`), /没有匹配/);
  await evaluate(`document.querySelector('#library-search').value=''; document.querySelector('#library-search').dispatchEvent(new Event('input')); document.querySelectorAll('#library-list button')[2].click()`);
  assert.equal(await evaluate(`document.querySelector('#library-count').textContent`), '0 / 20');
  await evaluate(`document.querySelector('#library-undo').click()`);
  assert.equal(await evaluate(`document.querySelector('#library-count').textContent`), '1 / 20');
  // Export the exact offered backup and reimport it through the file picker.
  const backup = await evaluate(`(async()=>{let href; const original=HTMLAnchorElement.prototype.click; HTMLAnchorElement.prototype.click=function(){href=this.href}; try{document.querySelector('#export-score').click(); return await(await fetch(href)).text()}finally{HTMLAnchorElement.prototype.click=original}})()`);
  const backupPath = resolve(root, 'evidence/library-roundtrip.json');
  await writeFile(backupPath, backup);
  const { root: importDom } = await page('DOM.getDocument');
  const { nodeId: importInput } = await page('DOM.querySelector', { nodeId: importDom.nodeId, selector: '#import-score' });
  await page('DOM.setFileInputFiles', { nodeId: importInput, files: [backupPath] });
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(document.querySelector('#library-count').textContent==='2 / 20')resolve();else if(n++>100)reject(Error('Backup import'));else setTimeout(poll,20)};poll()})`);
  assert.equal(await evaluate(`document.querySelector('#duration').textContent`), savedDuration);
  await evaluate(`document.querySelector('#speed').value='100'; document.querySelector('#velocity').value='100'; document.querySelector('#speed').dispatchEvent(new Event('input'))`);
  await evaluate(`document.querySelector('#connection-state').click()`);
  assert.equal(await evaluate(`document.querySelector('#device-panel').open`), true);
  await evaluate(`document.querySelector('#connect').click()`);
  assert.equal(await evaluate(`document.querySelector('#connection-label').textContent`), 'BLE 已连接');
  assert.deepEqual(await evaluate('window.bleRequest.filters'), [{services: ['6e400001-b5a3-f393-e0a9-e50e24dcca9e']}]);
  assert.match(await evaluate(`document.querySelector('#link-status').textContent`), /行者无疆/);
  await evaluate(`window.onBleWrite = b => window.emitBle(new TextEncoder().encode('ECHO '+new TextDecoder().decode(b)))`);
  await evaluate(`document.querySelector('#serial-test').open=true; document.querySelector('#send-form').requestSubmit()`);
  await evaluate(`new Promise(resolve=>setTimeout(resolve,50))`);
  assert.deepEqual(await evaluate('window.bleWritten'), [80,73,78,71,10]);
  assert.match(await evaluate(`document.querySelector('#serial-log').textContent`), /ECHO PING/);
  assert.match(await evaluate(`document.querySelector('#link-status').textContent`), /尚未确认板端执行/);
  await evaluate(`document.querySelector('#device-panel').open=false; document.activeElement.blur(); window.scrollTo(0,0)`);
  await mkdir(resolve(root, 'evidence'), { recursive: true });
  if (process.env.TEST_AUDIO === '1' || process.argv.includes('--audio')) {
    const { root: dom } = await page('DOM.getDocument');
    const { nodeId } = await page('DOM.querySelector', { nodeId: dom.nodeId, selector: '#audio-file' });
    await page('DOM.setFileInputFiles', { nodeId, files: [resolve(root, 'evidence/reference-notes.mp3')] });
    assert.equal(await evaluate(`document.querySelector('#audio-scope').value`), '0', 'Default conversion covers whole audio');
    await evaluate(`document.querySelector('#arrangement-end').value='30'`);
    await evaluate(`document.querySelector('#transcribe-audio').click()`);
    let finished = false;
    for (let attempt = 0; attempt < 180; attempt++) {
      const status = await evaluate(`({busy: document.querySelector('#transcribe-audio').disabled, message: document.querySelector('#audio-progress').textContent})`);
      if (!status.busy) { console.log('Audio result:', status.message); finished = true; break; }
      if (attempt % 10 === 0) console.log('Audio progress:', status.message);
      await new Promise(done => setTimeout(done, 1000));
    }
    assert.ok(finished, 'Real transcription must finish');
    assert.match(await evaluate(`document.querySelector('#audio-progress').textContent`), /识别完成/);
    const selectionEnd = await evaluate(`Number(document.querySelector('#arrangement-end').value)`);
    assert.ok(selectionEnd >= 5 && selectionEnd < 5.2, 'Selection follows decoded duration instead of stale 30 seconds');
    // Read exactly the JSONL offered by the UI, without writing a browser download.
    const notes = await evaluate(`(async()=>{
      const original = HTMLAnchorElement.prototype.click;
      let href; HTMLAnchorElement.prototype.click = function(){href=this.href};
      try { document.querySelector('#export-jsonl').click(); return (await (await fetch(href)).text()).trim().split('\\n').slice(1).map(JSON.parse); }
      finally { HTMLAnchorElement.prototype.click=original; }
    })()`);
    console.log('Recognized reference:', notes.map(n => [n.note, n.startMs, n.durationMs]));
    await writeFile(resolve(root, 'evidence/transcription-result.json'), JSON.stringify(notes, null, 2));
    for (const [note, start] of [[60, 200], [64, 1300], [67, 2400], [60, 3500], [64, 3500], [67, 3500]]) {
      assert.ok(notes.some(n => n.note === note && Math.abs(n.startMs - start) < 180 && n.durationMs > 400), `Expected MIDI ${note} near ${start} ms`);
    }
    assert.equal(notes.length, 6, 'Reference should contain exactly the six intended notes');
    await evaluate(`document.querySelector('#preview-notes').click()`);
    await evaluate(`new Promise(done=>setTimeout(done,100))`);
    assert.equal(await evaluate(`document.querySelector('#stop-preview').disabled`), false);
    const lightRoll = await evaluate(`document.querySelector('#piano-roll').toDataURL()`);
    await evaluate(`document.querySelector('#theme-toggle').click()`);
    assert.equal(await evaluate(`document.querySelector('#stop-preview').disabled`), false, 'Theme change must not stop audio');
    assert.equal(await evaluate(`document.querySelector('#note-count').textContent`), '6');
    assert.equal(await evaluate(`document.querySelector('#export-jsonl').disabled`), false);
    assert.notEqual(await evaluate(`document.querySelector('#piano-roll').toDataURL()`), lightRoll);
    const darkNotes = await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
    await writeFile(resolve(root, 'evidence/theme-dark-notes.png'), Buffer.from(darkNotes.data, 'base64'));
    await evaluate(`document.querySelector('#theme-toggle').click()`);
    assert.equal(await evaluate(`document.querySelector('#piano-roll').toDataURL()`), lightRoll, 'Theme round trip preserves notes');
    await evaluate(`document.querySelector('#stop-preview').click()`);
    assert.equal(await evaluate(`document.querySelector('#stop-preview').disabled`), true);
    const screenshot = await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
    await writeFile(resolve(root, 'evidence/audio-desktop.png'), Buffer.from(screenshot.data, 'base64'));
    assert.match(await evaluate(`document.querySelector('#upload-score').textContent`), /自动识别/);
    assert.equal(await evaluate(`document.querySelector('#arrangement-advanced').open`), false);
    assert.equal(await evaluate(`document.querySelector('#arrangement-onset-window').value`), '20');
    assert.equal(await evaluate(`document.querySelector('#arrangement-mode').value`), 'polyphonic');
    assert.equal(await evaluate(`document.querySelector('#arrangement-bass-balance').value`), '0.6');
    await evaluate(`document.querySelector('#arrangement-apply').click()`);
    assert.match(await evaluate(`document.querySelector('#upload-score').textContent`), /\/4096 个事件字/);
    assert.equal(await evaluate(`document.querySelector('#note-count').textContent`), '6', 'All reference chord notes survive arrangement');
    assert.equal(await evaluate(`document.querySelectorAll('#upload-melody option').length`), 2);
    assert.match(await evaluate(`document.querySelector('#arrangement-report').textContent`), /和弦延音/);
    await evaluate(`document.querySelector('#arrangement-mode').value='melody'; document.querySelector('#arrangement-apply').click()`);
    assert.equal(await evaluate(`document.querySelector('#note-count').textContent`), '4', 'Explicit legacy melody remains available');
    await evaluate(`document.querySelector('#arrangement-rhythm').value='sixteenth'; document.querySelector('#arrangement-reset').click()`);
    assert.equal(await evaluate(`document.querySelector('#arrangement-rhythm').value`), 'original');
    assert.equal(await evaluate(`document.querySelector('#arrangement-bpm').disabled`), true);
    await evaluate(`document.querySelector('#arrangement-min-pitch').value='60'; document.querySelector('#arrangement-max-pitch').value='84'`);
    await evaluate(`document.querySelector('#arrangement-apply').click()`);
    assert.equal(await evaluate(`document.querySelector('#arrangement-mode').value`), 'polyphonic');
    assert.match(await evaluate(`document.querySelector('#arrangement-report').textContent`), /复音重奏/);
    assert.match(await evaluate(`document.querySelector('#arrangement-report').textContent`), /音域排除/);
    assert.match(await evaluate(`document.querySelector('#upload-score').textContent`), /\/4096 个事件字/);
    assert.equal(await evaluate(`document.querySelector('#preview-upload').disabled`), false);
    await evaluate(`document.querySelector('#preview-upload').click()`);
    await evaluate(`new Promise(done=>setTimeout(done,200))`);
    assert.equal(await evaluate(`document.querySelector('#stop-preview').disabled`), false);
    assert.match(await evaluate(`document.querySelector('#preview-description').textContent`), /实际上传/);
    await evaluate(`document.querySelector('#speed').value='125'; document.querySelector('#speed').dispatchEvent(new Event('input'))`);
    assert.equal(await evaluate(`document.querySelector('#stop-preview').disabled`), true, 'Editing upload settings stops stale preview');
    assert.equal(await evaluate(`document.querySelector('#preview-upload').disabled`), false);
    console.log('Real MP3 recognition -> explicitly confirmed arrangement -> FPGA compiler: PASS');
    await evaluate(`document.querySelector('#transcribe-audio').click(); document.querySelector('#arrangement-apply').click(); window.staleArrangementStatus=document.querySelector('#status').textContent; document.querySelector('#cancel-transcription').click()`);
    assert.equal(await evaluate(`document.querySelector('#arrangement-panel').hidden`), true, 'A new transcription must hide stale recognition controls');
    assert.match(await evaluate(`window.staleArrangementStatus`), /等待当前转谱/);
    await evaluate(`new Promise(done=>setTimeout(done,500))`);
    assert.match(await evaluate(`document.querySelector('#audio-progress').textContent`), /取消/);
    assert.equal(await evaluate(`document.querySelector('#export-jsonl').disabled`), true, 'Cancelled run must not export stale results');
    // Decode errors must be visible, and active worker inference must be abortable.
    await evaluate(`import('./src/audio.js').then(module=>{window.audioModule=module; return true;})`);
    assert.match(await evaluate(`window.audioModule.transcribeAudioFile(new File(['invalid'], 'broken.mp3')).then(()=> 'unexpected success', e=> e.message)`), /无法解码/);
    await page('DOM.setFileInputFiles', { nodeId, files: [resolve(root, 'evidence/reference-long.mp3')] });
    await evaluate(`window.abortResult = null; const controller = new AbortController(); window.audioModule.transcribeAudioFile(document.querySelector('#audio-file').files[0], {signal: controller.signal, onProgress: p=>{if(p.stage==='model') controller.abort();}}).then(()=>window.abortResult='unexpected success', e=>window.abortResult=e.name)`);
    for (let i = 0; i < 60 && !await evaluate('window.abortResult'); i++) await new Promise(done=>setTimeout(done,500));
    assert.equal(await evaluate('window.abortResult'), 'AbortError');
    for (const limit of [30, 0]) {
      await evaluate(`window.longResult = null; window.audioModule.transcribeAudioFile(document.querySelector('#audio-file').files[0], {durationLimit:${limit}}).then(p=>window.longResult=p, e=>window.longResult={error:e.message})`);
      for (let i = 0; i < 180 && !await evaluate('!!window.longResult'); i++) {
        if (i % 20 === 0) console.log('Checking 40-second MP3, limit:', limit);
        await new Promise(done=>setTimeout(done,500));
      }
      const result = await evaluate('window.longResult');
      assert.ok(result && !result.error, JSON.stringify(result));
      assert.equal(result.partial, limit === 30);
      assert.equal(result.tracks[0].notes.length, limit ? 6 : 12, 'Whole-song mode must include notes after 30 seconds');
      if (!limit) for (const note of [60,64,67]) assert.ok(result.tracks[0].notes.some(n=>n.note===note && Math.abs(n.startMs-36500)<200), 'Late chord timing');
      console.log('Long MP3:', limit ? 'first 30 seconds' : 'whole file', result.tracks[0].notes.length, 'notes');
    }
  }
  const desktop = await page('Page.captureScreenshot', { format: 'png' });
  await writeFile(resolve(root, 'evidence/bluetooth-desktop.png'), Buffer.from(desktop.data, 'base64'));
  await evaluate(`document.querySelector('#disconnect').click()`);
  await evaluate(`new Promise(resolve=>setTimeout(resolve,50))`);
  assert.equal(await evaluate(`document.querySelector('#send').disabled`), true);
  await evaluate(`window.onBleWrite=null; window.bleWritten=[]; document.querySelector('#device-panel').open=true; document.querySelector('#ble-config').open=true; document.querySelector('#connect').click()`);
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(document.querySelector('#connection-label').textContent==='BLE 已连接')resolve();else if(n++>100)reject(Error('BLE connect'));else setTimeout(poll,20)};poll()})`);
  assert.equal(await evaluate(`document.querySelector('#ble-service-uuid').disabled`), true);
  await evaluate(`document.querySelector('#send-text').value='PING'; document.querySelector('#send-form').requestSubmit()`);
  await evaluate(`new Promise(resolve=>setTimeout(resolve,50))`);
  assert.deepEqual(await evaluate('window.bleWritten'), [80,73,78,71,10]);
  assert.match(await evaluate(`document.querySelector('#link-status').textContent`), /BLE.*尚未确认/);
  await evaluate(`window.emitBle([228,184]); window.emitBle([173,230,150,135]);`);
  assert.match(await evaluate(`document.querySelector('#serial-log').textContent`), /中文/);
  await evaluate(`document.querySelector('#disconnect').click()`);
  assert.equal(await evaluate(`document.querySelector('#send').disabled`), true);
  assert.equal(await evaluate(`document.querySelector('#ble-service-uuid').disabled`), false);
  assert.equal(await evaluate(`document.querySelector('#board-play').disabled`), true);
  await evaluate(`document.querySelector('#connect').click()`);
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(!document.querySelector('#board-hello').disabled)resolve();else if(n++>100)reject(Error('Board reconnect'));else setTimeout(poll,20)};poll()})`);
  await evaluate(`document.querySelector('#board-hello').click()`);
  assert.equal(await evaluate(`document.querySelector('#board-play').disabled`), true);
  assert.equal(await evaluate(`document.querySelector('#send').disabled`), true, 'No raw command can overlap protocol request');
  await evaluate(`window.emitBle(new TextEncoder().encode('OK,HC05,1,9600,8N1,DEMO='))`);
  assert.match(await evaluate(`document.querySelector('#board-protocol').textContent`), /尚未识别/);
  await evaluate(`window.emitBle(new TextEncoder().encode('TWINKLE+ODE\\n'))`);
  assert.equal(await evaluate(`document.querySelector('#board-play').disabled`), false);
  assert.match(await evaluate(`document.querySelector('#board-protocol').textContent`), /短命令 v1/);
  assert.equal(await evaluate(`document.querySelector('#upload-start').disabled`), true, 'Legacy HELLO never enables SONG2 upload');
  await evaluate(`document.querySelector('#board-play').click(); window.emitBle(new TextEncoder().encode('OK,STOP\\n'))`);
  assert.equal(await evaluate(`document.querySelector('#board-query').disabled`), true, 'Wrong ACK must leave request pending');
  await evaluate(`window.emitBle(new TextEncoder().encode('OK,PLAY\\n'))`);
  assert.match(await evaluate(`document.querySelector('#board-message').textContent`), /已确认 PLAY/);
  assert.match(await evaluate(`document.querySelector('#board-state').textContent`), /未知/);
  await evaluate(`document.querySelector('#board-query').click(); window.emitBle(new TextEncoder().encode('STATUS,PLAYING,003/084\\n'))`);
  assert.match(await evaluate(`document.querySelector('#board-state').textContent`), /条目 3\/84.*最近查询/);
  const boardScreenshot = await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  await writeFile(resolve(root, 'evidence/board-session-mock.png'), Buffer.from(boardScreenshot.data, 'base64'));
  await evaluate(`document.querySelector('#board-play').click(); window.emitBle(new TextEncoder().encode('ERR,LOCAL\\n'))`);
  assert.match(await evaluate(`document.querySelector('#board-message').textContent`), /阻止/);
  await evaluate(`document.querySelector('#board-stop').click(); window.emitBle(new TextEncoder().encode('OK,STOP\\n'))`);
  assert.match(await evaluate(`document.querySelector('#board-message').textContent`), /已确认 STOP/);
  await evaluate(`document.querySelector('#board-query').click()`);
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(document.querySelector('#board-message').textContent.includes('超时'))resolve();else if(n++>200)reject(Error('Missing timeout'));else setTimeout(poll,20)};poll()})`);
  await evaluate(`window.emitBle(new TextEncoder().encode('STATUS,PLAYING,004/084\\n'))`);
  assert.equal(await evaluate(`document.querySelector('#board-hello').disabled`), true);
  assert.match(await evaluate(`document.querySelector('#board-state').textContent`), /未知/);
  await evaluate(`document.querySelector('#disconnect').click()`);
  // Explicitly mocked SONG2 receiver. Actual BLE splitting still goes through
  // the browser adapter; no hardware support is inferred from this test.
  await evaluate(`(async()=>{
    const {decodeScoreFrame,encodeScoreFrame}=await import('./src/score-upload-protocol.js');
    const {crc16Ccitt}=await import('./src/protocol.js');
    let buffer='', bytes=[], meta, committed, playState=0, playLength=0, playCrc='0000';
    window.controlCaps=false;
    window.uploadHold='COMMIT'; window.uploadHeld=null; window.uploadCommands=[];
    window.onBleWrite=async chunk=>{
      buffer+=new TextDecoder().decode(chunk);
      while(buffer.includes('\\n')){
        const end=buffer.indexOf('\\n'),line=buffer.slice(0,end); buffer=buffer.slice(end+1);
        const f=decodeScoreFrame(line); if(!f)throw Error('Bad request CRC');
        const [,sid,seq,op,...v]=f; window.uploadCommands.push(op);
        let values=[];
        if(op==='CAPS')values=window.controlCaps?[12,512,8,1]:[12,512,8];
        if(op==='BEGIN'){meta=v;bytes=[];values=[0];}
        if(op==='DATA'){
          if(+v[0]!==bytes.length/8)throw Error('Bad upload offset');
          bytes.push(...v[2].match(/../g).map(b=>parseInt(b,16)));values=[bytes.length/8];
        }
        if(op==='COMMIT'){
          const crc=crc16Ccitt(bytes).toString(16).padStart(4,'0').toUpperCase();
          if(crc!==meta[4]||bytes.length!==+meta[1]*8)throw Error('Bad whole-score CRC');
          values=[bytes.length/8,crc];
          committed={length:bytes.length/8,crc};
        }
        if(op==='ABORT')bytes=[];
        if(['PLAY','STOP','STATUS'].includes(op)){
          if(op==='PLAY'){
            if(+v[0]!==committed.length||v[1]!==committed.crc||v[2]!=='1')throw Error('PLAY identity mismatch');
            playState=1;playLength=committed.length;playCrc=committed.crc;
          }
          if(op==='STOP')playState=0;
          const reported=op==='STATUS'?window.mockBoardPlayback:null;
          values=[reported?.state??playState,reported?.index??0,playLength,reported?.crc??playCrc,committed?1:0,committed?.crc||'0000'];
        }
        const reply=encodeScoreFrame(['ACK2',sid,seq,op,...values]);
        if(window.uploadHold===op)window.uploadHeld=reply;
        else window.emitBle(new TextEncoder().encode(reply));
      }
    };
    document.querySelector('#connect').click();
  })()`);
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(!document.querySelector('#upload-probe').disabled)resolve();else if(n++>100)reject(Error('Upload reconnect'));else setTimeout(poll,20)};poll()})`);
  const { root: scoreDom } = await page('DOM.getDocument');
  const { nodeId: scoreFile } = await page('DOM.querySelector', { nodeId: scoreDom.nodeId, selector: '#midi-file' });
  await page('DOM.setFileInputFiles', { nodeId: scoreFile, files: [resolve(root, 'test/fixtures/fpga-scores/ode.mid')] });
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(document.querySelector('#upload-score').textContent.includes('132/4096'))resolve();else if(n++>100)reject(Error(document.querySelector('#upload-score').textContent));else setTimeout(poll,20)};poll()})`);
  await evaluate(`document.querySelector('#upload-probe').click()`);
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(!document.querySelector('#upload-start').disabled)resolve();else if(n++>100)reject(Error('No capability'));else setTimeout(poll,20)};poll()})`);
  assert.equal(await evaluate(`document.querySelector('#upload-play').disabled && document.querySelector('#upload-stop').disabled && document.querySelector('#upload-status').disabled`), true, 'Upload-only CAPS must not enable playback');
  await evaluate(`window.controlCaps=true; document.querySelector('#upload-probe').click()`);
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(!document.querySelector('#upload-play').disabled)resolve();else if(n++>100)reject(Error('No playback capability'));else setTimeout(poll,20)};poll()})`);
  assert.equal(await evaluate(`document.querySelector('#upload-stop').textContent.trim()`), '停止播放', 'Board playback has a clearly named stop control');
  assert.equal(await evaluate(`document.querySelector('#upload-stop').getAttribute('aria-label')`), '停止 FPGA 曲谱播放');
  await evaluate(`document.querySelector('#upload-start').click()`);
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(window.uploadHeld)resolve();else if(n++>100)reject(Error('No COMMIT'));else setTimeout(poll,20)};poll()})`);
  assert.equal(await evaluate(`document.querySelector('#upload-progress').value`), 132);
  assert.match(await evaluate(`document.querySelector('#upload-message').textContent`), /等待设备.*提交/);
  assert.equal(await evaluate(`document.querySelector('#upload-start').disabled && document.querySelector('#send').disabled && document.querySelector('#board-hello').disabled && document.querySelector('#upload-cancel').disabled`), true);
  await evaluate(`window.emitBle(new TextEncoder().encode(window.uploadHeld)); window.uploadHeld=null`);
  assert.match(await evaluate(`document.querySelector('#upload-message').textContent`), /已确认整曲 CRC.*尚未请求播放/);
  assert.equal(await evaluate(`window.uploadCommands.includes('PLAY')`), false);
  await evaluate(`window.uploadHold='PLAY'; document.querySelector('#upload-play').click()`);
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(window.uploadHeld)resolve();else if(n++>100)reject(Error('No PLAY request'));else setTimeout(poll,20)};poll()})`);
  assert.equal(await evaluate(`document.querySelector('#upload-stop').disabled && document.querySelector('#upload-status').disabled && document.querySelector('#upload-start').disabled && document.querySelector('#send').disabled`), true, 'In-flight control owns transport');
  await evaluate(`window.emitBle(new TextEncoder().encode(window.uploadHeld)); window.uploadHeld=null`);
  assert.match(await evaluate(`document.querySelector('#upload-playback-state').textContent`), /准备播放.*最近应答/);
  assert.equal(await evaluate(`document.querySelector('#board-visuals').dataset.position`), '-1', 'Starting is not a confirmed melody onset');
  await evaluate(`window.uploadHold=null; document.querySelector('#upload-status').click()`);
  await evaluate(`new Promise(resolve=>{const poll=()=>document.querySelector('#upload-status').disabled?setTimeout(poll,10):resolve();poll()})`);
  await evaluate(`window.mockBoardPlayback={state:2,index:3}; document.querySelector('#board-monitor-refresh').click()`);
  await evaluate(`new Promise(resolve=>{const poll=()=>document.querySelector('#board-monitor-refresh').disabled?setTimeout(poll,10):resolve();poll()})`);
  assert.equal(await evaluate(`document.querySelector('#board-visuals').dataset.position`), '3');
  assert.equal(await evaluate(`document.querySelectorAll('#board-visuals .piano-key.active').length`), 1);
  assert.match(await evaluate(`document.querySelector('#board-monitor-note').textContent`), /4 \/ 30/);
  await evaluate(`window.mockBoardPlayback.crc='FFFF'; document.querySelector('#board-monitor-refresh').click()`);
  await evaluate(`new Promise(resolve=>{const poll=()=>document.querySelector('#board-monitor-refresh').disabled?setTimeout(poll,10):resolve();poll()})`);
  assert.equal(await evaluate(`document.querySelector('#board-visuals').dataset.position`), '-1', 'Different score CRC must not illuminate a local note');
  assert.equal(await evaluate(`document.querySelectorAll('#board-visuals .piano-key.active').length`), 0);
  await evaluate(`window.mockBoardPlayback={state:2,index:0}; document.querySelector('#board-monitor-auto').click()`);
  await evaluate(`new Promise(resolve=>{const poll=()=>document.querySelector('#board-visuals').dataset.position==='0'?resolve():setTimeout(poll,10);poll()})`);
  // Hidden player mode suspends automatic querying without destroying the session.
  const commandsBeforeHide = await evaluate(`window.uploadCommands.length`);
  await evaluate(`window.dispatchEvent(new CustomEvent('instrument-visibility',{detail:false}))`);
  await new Promise(resolve=>setTimeout(resolve,1800));
  assert.equal(await evaluate(`window.uploadCommands.length`), commandsBeforeHide);
  await evaluate(`window.uploadHold='STATUS'; window.dispatchEvent(new CustomEvent('instrument-visibility',{detail:true}))`);
  await evaluate(`new Promise(resolve=>{const poll=()=>window.uploadHeld?resolve():setTimeout(poll,10);poll()})`);
  assert.equal(await evaluate(`document.querySelector('#upload-start').disabled && document.querySelector('#board-monitor-refresh').disabled`), true, 'Polling must use the existing exclusive transport');
  await evaluate(`document.querySelector('#board-monitor-auto').click(); window.uploadHold=null; window.emitBle(new TextEncoder().encode(window.uploadHeld)); window.uploadHeld=null`);
  await evaluate(`new Promise(resolve=>{const poll=()=>document.querySelector('#board-monitor-refresh').disabled?setTimeout(poll,10):resolve();poll()})`);
  await new Promise(resolve=>setTimeout(resolve,6600));
  assert.equal(await evaluate(`document.querySelector('#board-visuals').dataset.position`), '-1', 'Unrefreshed board position expires rather than advancing by PC time');
  assert.equal(await evaluate(`document.querySelectorAll('#board-visuals .piano-key.active').length`), 0);
  await evaluate(`window.mockBoardPlayback=null; document.querySelector('#board-monitor-refresh').click()`);
  await evaluate(`new Promise(resolve=>{const poll=()=>document.querySelector('#board-monitor-refresh').disabled?setTimeout(poll,10):resolve();poll()})`);
  await evaluate(`document.querySelector('#upload-stop').click()`);
  await evaluate(`new Promise(resolve=>{const poll=()=>document.querySelector('#upload-stop').disabled?setTimeout(poll,10):resolve();poll()})`);
  assert.match(await evaluate(`document.querySelector('#upload-message').textContent`), /尾音可能尚未结束/);
  assert.match(await evaluate(`document.querySelector('#upload-playback-state').textContent`), /空闲/);
  const controlScreenshot=await page('Page.captureScreenshot', {format:'png',captureBeyondViewport:true});
  await writeFile(resolve(root,'evidence/score-control-mock.png'),Buffer.from(controlScreenshot.data,'base64'));
  // Cancel a DATA request while its reply is held, then acknowledge the write.
  await evaluate(`window.uploadHold='DATA'; document.querySelector('#upload-start').click()`);
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(window.uploadHeld)resolve();else if(n++>100)reject(Error('No DATA'));else setTimeout(poll,20)};poll()})`);
  await evaluate(`document.querySelector('#upload-cancel').click(); window.emitBle(new TextEncoder().encode(window.uploadHeld)); window.uploadHeld=null`);
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>{if(document.querySelector('#upload-message').textContent.includes('已确认丢弃'))resolve();else if(n++>100)reject(Error('No ABORT'));else setTimeout(poll,20)};poll()})`);
  const uploadScreenshot = await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  await writeFile(resolve(root, 'evidence/score-upload-mock.png'), Buffer.from(uploadScreenshot.data, 'base64'));
  // Explicit SCOPE1 simulator, not hardware evidence. Exercise the actual BLE
  // notification fragmentation, exclusive session, FFT and all three canvases.
  await evaluate(`window.scoreWriter=window.onBleWrite; window.scopeBuffer=''; window.onBleWrite=async bytes=>{
    window.scopeBuffer+=new TextDecoder().decode(bytes);
    if(!window.scopeBuffer.endsWith('\\n'))return;
    const request=window.scopeBuffer.trim();window.scopeBuffer='';
    if(!request.startsWith('SCOPE1,'))return;
    const id=request.split(',')[1];
    const crc=body=>{let c=65535;for(const ch of body){c^=ch.charCodeAt(0)<<8;for(let b=0;b<8;b++)c=((c<<1)^(c&32768?4129:0))&65535;}return c.toString(16).toUpperCase().padStart(4,'0');};
    const hx=v=>(v&255).toString(16).toUpperCase().padStart(2,'0');
    window.scopeResponse='';
    for(let block=0;block<32;block++){
      let payload='';for(let i=0;i<32;i++){const phase=2*Math.PI*16*(block*32+i)/1024;payload+=hx(Math.round(100*Math.sin(phase)))+hx(Math.round(90*Math.cos(phase)));}
      const body='SCOPE1,'+id+','+hx(block)+','+payload;window.scopeResponse+=body+','+crc(body)+'\\n';
    }
  };document.querySelector('#board-audio-capture').click()`);
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>window.scopeResponse?resolve():n++>100?reject(Error('No SCOPE1 request')):setTimeout(poll,20);poll()})`);
  assert.equal(await evaluate(`document.querySelector('#upload-start').disabled`), true, 'Scope owns the same UART as score upload');
  assert.equal(await evaluate(`document.querySelector('.board-audio').dataset.signal`), 'false', 'No fabricated samples while waiting');
  await evaluate(`(()=>{const b=new TextEncoder().encode(window.scopeResponse);for(let i=0;i<b.length;i+=19)window.emitBle(b.slice(i,i+19));})()`);
  await evaluate(`new Promise((resolve,reject)=>{let n=0;const poll=()=>document.querySelector('.board-audio').dataset.signal==='true'?resolve():n++>100?reject(Error('No board audio')):setTimeout(poll,20);poll()})`);
  assert.match(await evaluate(`document.querySelector('#board-audio-state').textContent`), /FPGA 实测快照.*非连续流/);
  const boardPlots = await evaluate(`['board-wave','board-spectrum','board-xy'].map(id=>{const c=document.getElementById(id),r=c.getBoundingClientRect(),p=c.getContext('2d').getImageData(0,0,c.width,c.height).data;let signalPixels=0;for(let i=0;i<p.length;i+=4)if(p[i]>80&&p[i]<180&&p[i+1]>200&&p[i+2]>180)signalPixels++;return {id,height:r.height,width:r.width,top:r.top,bottom:r.bottom,signalPixels};})`);
  assert.ok(boardPlots.every(p=>p.height>=300&&p.signalPixels>100), JSON.stringify(boardPlots));
  assert.ok(boardPlots.slice(1).every((p,i)=>p.top>boardPlots[i].bottom), 'Board plots must be three independent rows');
  const scopeScreenshot = await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  await writeFile(resolve(root, 'evidence/board-audio-mock.png'), Buffer.from(scopeScreenshot.data, 'base64'));
  await writeFile(resolve(root, 'evidence/board-audio-mock.json'), JSON.stringify({passed:true,hardwareTested:false,plots:boardPlots,samples:1024,sampleRate:48000},null,2));
  await evaluate(`document.querySelector('#disconnect').click(); window.onBleWrite=null`);
  assert.equal(await evaluate(`document.querySelector('.board-audio').dataset.signal`), 'false', 'Disconnect clears old captured audio');
  assert.equal(await evaluate(`document.querySelector('#board-visuals').dataset.position`), '-1');
  assert.equal(await evaluate(`document.querySelector('#board-monitor-auto').checked`), false);
  assert.equal(await evaluate(`document.querySelector('#upload-start').disabled`), true);
  assert.equal(await evaluate(`document.querySelector('#upload-play').disabled && document.querySelector('#upload-stop').disabled && document.querySelector('#upload-status').disabled`), true);
  await page('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await evaluate(`window.dispatchEvent(new Event('resize'))`);
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('.grid')).gridTemplateColumns.split(' ').length`), 1, 'Mobile cards must stack');
  assert.equal(await evaluate('document.documentElement.scrollWidth <= window.innerWidth'), true);
  const libraryMobile = await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  await writeFile(resolve(root, 'evidence/library-ble-mobile.png'), Buffer.from(libraryMobile.data, 'base64'));
  const mobile = await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  await writeFile(resolve(root, 'evidence/bluetooth-mobile.png'), Buffer.from(mobile.data, 'base64'));
  await evaluate(`document.querySelector('#theme-toggle').click()`);
  assert.equal(await evaluate('document.documentElement.scrollWidth <= window.innerWidth'), true);
  const darkMobile = await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  await writeFile(resolve(root, 'evidence/theme-dark-mobile.png'), Buffer.from(darkMobile.data, 'base64'));
  await evaluate(`document.querySelector('#audio-file-name').textContent='很长的音乐文件名'.repeat(12)+'.mp3'; document.querySelector('#file-name').textContent='long-filename-'.repeat(15)+'.mid';`);
  await page('Emulation.setDeviceMetricsOverride', { width: 320, height: 844, deviceScaleFactor: 1, mobile: true });
  await evaluate(`window.dispatchEvent(new Event('resize'))`);
  assert.equal(await evaluate('document.documentElement.scrollWidth <= window.innerWidth'), true, 'Long filenames on narrow screens');
  await page('Emulation.setDeviceMetricsOverride', { width: 640, height: 900, deviceScaleFactor: 1, mobile: false });
  await evaluate(`document.querySelectorAll('p,label,button,select,summary').forEach(e=>e.style.fontSize=(parseFloat(getComputedStyle(e).fontSize)*2)+'px'); window.dispatchEvent(new Event('resize'))`);
  assert.equal(await evaluate('document.documentElement.scrollWidth <= window.innerWidth'), true, 'Enlarged text must reflow');
  // Verify the unsupported-browser fallback independently of the mock.
  await evaluate(`Object.defineProperty(navigator,'bluetooth',{value:undefined, configurable:true});`);
  await evaluate(`import('./src/app.js?unsupported-test')`);
  assert.equal(await evaluate(`document.querySelector('#connect').disabled`), true);
  assert.match(await evaluate(`document.querySelector('#serial-help').textContent`), /不支持 BLE.*Web Bluetooth/);
  // A fresh page with an explicit Serial fixture exercises real stream locks,
  // envelope handshake and the manual selector without opening physical USB.
  await page('Page.addScriptToEvaluateOnNewDocument', { source: `
    const serial = new EventTarget();
    serial.requestPort = async options => {
      window.usbRequested = options;
      let rx;
      return {
        async open(options) {
          window.usbOpen = options;
          this.readable = new ReadableStream({start(c){rx=c;}});
          this.writable = new WritableStream({write(bytes){
            const [,token,op,seq] = new TextDecoder().decode(bytes).trim().split(',');
            const response = op==='OPEN'?'READY':op==='PING'?'PONG':op==='CLOSE'?'BYE':'OK,'+seq;
            rx.enqueue(new TextEncoder().encode('boot log\\n!USB1,'+token+','+response+'\\n'));
          }});
        },
        async close(){window.usbClosed=true;}
      };
    };
    Object.defineProperty(navigator,'serial',{value:serial,configurable:true});
  ` });
  await page('Page.reload');
  await evaluate(`new Promise((resolve,reject)=>{const t=setTimeout(()=>reject(Error('USB fixture load')),5000);const p=()=>{if(document.querySelector('#status')?.textContent.includes('不会自动发送')){clearTimeout(t);resolve()}else setTimeout(p,20)};p()})`);
  assert.equal(await evaluate(`document.querySelector('#connection-mode').value`), 'ble');
  assert.equal(await evaluate(`!!window.usbRequested`), false, 'startup cannot open USB');
  await evaluate(`const m=document.querySelector('#connection-mode');m.value='usb';m.dispatchEvent(new Event('change'));document.querySelector('#connect').click()`);
  await evaluate(`new Promise((resolve,reject)=>{const t=setTimeout(()=>reject(Error('USB handshake')),5000);const p=()=>{if(document.querySelector('#disconnect')?.disabled===false){clearTimeout(t);resolve()}else setTimeout(p,20)};p()})`);
  assert.equal(await evaluate(`window.usbRequested.filters[0].usbVendorId`), 0x303a);
  assert.equal(await evaluate(`document.querySelector('#connection-mode').disabled`), true);
  assert.equal(await evaluate(`document.querySelector('#upload-start').disabled`), true, 'USB handshake is not FPGA capability');
  await evaluate(`document.querySelector('#disconnect').click()`);
  await evaluate(`new Promise((resolve,reject)=>{const t=setTimeout(()=>reject(Error('USB close')),5000);const p=()=>{if(window.usbClosed&&!document.querySelector('#connection-mode').disabled){clearTimeout(t);resolve()}else setTimeout(p,20)};p()})`);
  await evaluate(`{const m=document.querySelector('#connection-mode');m.value='ble';m.dispatchEvent(new Event('change'))}`);
  assert.match(await evaluate(`document.querySelector('#connect').textContent`), /BLE/);
  assert.deepEqual(errors, []);
  console.log('PASS: Chromium UI, BLE primary without Serial, explicit USB backup handshake/stream cleanup/switch back, team device/service selection, library roundtrip, board HELLO/PLAY/STATUS/STOP, wrong ACK, ERR LOCAL, timeout/late response, SONG2 capability/CRC/commit/cancel/numbered playback/status/stop, legacy capability gate, split UTF-8, unsupported BLE fallback, mobile layout, zero runtime exceptions. Physical BLE/USB/FPGA not tested.');
  await command('Browser.close');
} finally {
  socket?.close(); browser.kill(); server.closeAllConnections();
  await new Promise((done) => server.close(done));
}
