// Start the actual packaged Windows app. No BLE device is impersonated here.
import { spawn } from 'node:child_process';
import { readFile, mkdir, writeFile, mkdtemp } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { tmpdir } from 'node:os';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const evidence = resolve(root, '../../artifacts/fpgavedio_desktop_20261021');
await mkdir(evidence, { recursive: true });
const profile = await mkdtemp(resolve(tmpdir(), 'fpgavedio-desktop-smoke-'));
const env = { ...process.env, MINERADIO_STARTUP_QA_HIDDEN: '1', MINERADIO_STARTUP_QA_USER_DATA: profile };
delete env.ELECTRON_RUN_AS_NODE;
const child = spawn(resolve(root, 'dist-fpga/win-unpacked/FPGAvedio.exe'), ['--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1'], { env, windowsHide: true });
let output = '', socket;
child.stdout.on('data', data => output += data);
child.stderr.on('data', data => output += data);
const pause = ms => new Promise(done => setTimeout(done, ms));
const errors = [];
const closeMode = process.argv.find(arg => arg.startsWith('--close-only='))?.split('=')[1];
try {
  let endpoint;
  for (let i = 0; i < 150; i++) {
    endpoint = /DevTools listening on (ws:\/\/[^\s]+)/.exec(output)?.[1];
    if (endpoint) break;
    if (child.exitCode !== null) throw Error(`App exited ${child.exitCode}: ${output}`);
    await pause(200);
  }
  assert.ok(endpoint, `No debugger endpoint: ${output}`);
  socket = new WebSocket(endpoint);
  await new Promise((done, reject) => { socket.onopen = done; socket.onerror = reject; });
  let id = 0; const pending = new Map();
  socket.onmessage = ({ data }) => {
    const event = JSON.parse(data);
    if (event.id) {
      const request = pending.get(event.id);
      if (!request) return;
      pending.delete(event.id); clearTimeout(request.timer);
      event.error ? request.reject(Error(event.error.message)) : request.done(event.result);
    }
    if (event.method === 'Runtime.exceptionThrown') errors.push(event.params.exceptionDetails);
  };
  const command = (method, params = {}, sessionId) => new Promise((done, reject) => {
    const requestId = ++id;
    const timer = setTimeout(() => { pending.delete(requestId); reject(Error(`CDP timeout ${method}`)); }, 60000);
    pending.set(requestId, { done, reject, timer });
    socket.send(JSON.stringify({ id: requestId, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  let target;
  for (let i = 0; i < 150; i++) {
    target = (await command('Target.getTargets')).targetInfos.find(t => t.type === 'page' && /^http:\/\/127\.0\.0\.1:\d+\//.test(t.url));
    if (target) break;
    await pause(200);
  }
  assert.ok(target, `Main window never loaded: ${output}`);
  const { sessionId } = await command('Target.attachToTarget', { targetId: target.targetId, flatten: true });
  const page = (method, params) => command(method, params, sessionId);
  const evaluate = async expression => {
    const response = await page('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true });
    if (response.exceptionDetails) throw Error(JSON.stringify(response.exceptionDetails));
    return response.result.value;
  };
  const waitFor = async (expression, seconds = 20) => {
    for (let i = 0; i < seconds * 5; i++) { if (await evaluate(expression)) return; await pause(200); }
    throw Error(`UI timeout: ${expression}`);
  };
  const mouseClick = async selector => {
    const point = await evaluate(`(()=>{const b=document.querySelector(${JSON.stringify(selector)}),r=b.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;return {x,y,reachable:x>0&&y>0&&x<innerWidth&&y<innerHeight&&b.contains(document.elementFromPoint(x,y))};})()`);
    assert.equal(point.reachable, true, `Mouse cannot reach ${selector}: ${JSON.stringify(point)}`);
    await page('Input.dispatchMouseEvent', { type: 'mousePressed', x: point.x, y: point.y, button: 'left', clickCount: 1 });
    await page('Input.dispatchMouseEvent', { type: 'mouseReleased', x: point.x, y: point.y, button: 'left', clickCount: 1 });
  };
  await page('Runtime.enable'); await page('Page.enable');
  await waitFor(`document.querySelector('#mode-fpga') && typeof audio!=='undefined'`);
  assert.equal(await evaluate('document.title'), 'FPGAvedio');
  const version = await evaluate(`fetch('/api/app/version').then(r=>r.json())`);
  assert.equal(version.productName, 'FPGAvedio');
  assert.equal(version.update.configured, false);
  await waitFor(`!document.body.classList.contains('splash-active') || document.querySelector('#splash').classList.contains('ready')`);
  if (closeMode !== 'splash') {
    await evaluate(`document.querySelector('#splash').click()`);
    await waitFor(`!document.body.classList.contains('splash-active')`);
  }
  if (closeMode) {
    if (closeMode === 'fpga') await evaluate(`document.querySelector('#mode-fpga').click()`);
    if (closeMode === 'modal') await evaluate(`openGsapModal(document.querySelector('#login-modal'))`);
    if (['fullscreen', 'fpga-fullscreen'].includes(closeMode)) await evaluate(`toggleFullscreen()`);
    if (closeMode === 'fpga-fullscreen') {
      await evaluate(`document.querySelector('#mode-fpga').click()`);
      await waitFor(`document.querySelector('#fpga-playback iframe').contentDocument?.querySelector('.ble-sidebar')`);
    }
    if (closeMode === 'snapshot-error') await evaluate(`saveLastPlaybackSnapshot=()=>{throw Error('Injected snapshot failure')}`);
    if (closeMode === 'immersive') await evaluate(`document.body.classList.add('immersive-mode')`);
    await pause(1000);
    const controls = await evaluate(`(()=>{const b=document.querySelector('[data-window-action="close"]'),r=b.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2,hit:document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)?.outerHTML,preference:closeBehaviorPreference,api:typeof window.desktopWindow?.close,body:document.body.className};})()`);
    console.log(JSON.stringify({ closeMode, controls }));
    await page('Input.dispatchMouseEvent', { type: 'mousePressed', x: controls.x, y: controls.y, button: 'left', clickCount: 1 });
    await page('Input.dispatchMouseEvent', { type: 'mouseReleased', x: controls.x, y: controls.y, button: 'left', clickCount: 1 });
    for (let i=0; i<100 && child.exitCode === null; i++) await pause(200);
    assert.notEqual(child.exitCode, null, `Close button did not exit: ${JSON.stringify(errors)}\n${output.slice(-4000)}`);
    assert.equal(child.exitCode, 0);
    assert.deepEqual(errors, [], 'Closing must not leave uncaught renderer errors');
    console.log(JSON.stringify({ passed: true, closeMode, gracefulExit: true, errors }));
    await writeFile(resolve(evidence, `close-${closeMode}.json`), JSON.stringify({ passed: true, closeMode, gracefulExit: true, controls, errors }, null, 2));
    process.exitCode = 0;
  } else {
  assert.equal(await evaluate(`(()=>{const a=document.querySelector('#top-right').getBoundingClientRect(),b=document.querySelector('#fpga-mode-switch').getBoundingClientRect();return a.right<=b.left;})()`), true);
  assert.equal(await evaluate(`document.querySelector('#fpga-playback').hidden`), true);
  await mouseClick('#mode-fpga');
  const f = `document.querySelector('iframe[title="曲谱转化与 BLE 乐器控制"]')`;
  await waitFor(`${f}?.contentDocument?.querySelector('#choose-audio')`);
  await waitFor(`${f}.dataset.themed === 'true'`);
  await waitFor(`${f}.contentDocument.querySelector('.ble-sidebar')`);
  await waitFor(`!document.body.classList.contains('desktop-wallpaper-mode')`);
  assert.equal(await evaluate(`window.desktopWindow.getState().then(s=>s.isDesktopEmbedded)`), false);
  assert.equal(await evaluate(`${f}.contentDocument.querySelector('#performance-visuals').dataset.signal`), 'false');
  // Reproduce the connection-summary jump that used to scroll host controls
  // out of the clipped player shell, then use real pointer switching.
  await evaluate(`${f}.contentDocument.querySelector('#connection-state').click()`);
  await pause(500);
  await mouseClick('#mode-player');
  assert.equal(await evaluate(`document.querySelector('#fpga-playback').hidden`), true);
  await mouseClick('#mode-fpga');
  await evaluate(`${f}.contentDocument.querySelector('.function-rail a').click()`);
  await pause(400);
  // All three native controls must be visible and hit-testable in FPGA mode.
  assert.equal(await evaluate(`['minimize','maximize','close'].every(a=>{const b=document.querySelector('[data-window-action="'+a+'"]'),r=b.getBoundingClientRect();return r.width>0&&r.height>0&&r.y>=0&&b.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2));})`), true);
  await mouseClick('[data-window-action="minimize"]');
  await waitFor(`window.desktopWindow.getState().then(s=>s.isMinimized)`);
  await evaluate(`window.desktopWindow.restore()`);
  await waitFor(`window.desktopWindow.getState().then(s=>!s.isMinimized&&s.isVisible)`);
  await waitFor(`getComputedStyle(${f}.contentDocument.documentElement).backgroundColor === 'rgba(0, 0, 0, 0)'`);
  assert.equal(await evaluate(`document.querySelector('dialog') !== null`), false);
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#search-area')).display`), 'none');
  assert.equal(await evaluate(`document.querySelector('#search-area').inert`), true);
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#canvas-container')).display`), 'block');
  const bluetooth = await evaluate(`({secure:${f}.contentWindow.isSecureContext,requestDevice:typeof ${f}.contentWindow.navigator.bluetooth?.requestDevice})`);
  assert.equal(bluetooth.secure, true);
  assert.equal(bluetooth.requestDevice, 'function');
  // Exercise the actual OS chooser lifecycle without selecting or connecting
  // a user's instrument. Discovering hardware is not a requirement to cancel.
  if (process.argv.includes('--ble-scan')) {
    await evaluate(`${f}.contentDocument.querySelector('#ble-service-uuid').value='invalid';${f}.contentDocument.querySelector('#connect').click()`);
    await waitFor(`${f}.contentDocument.querySelector('#link-status').textContent.includes('格式无效')`);
    await waitFor(`${f}.contentDocument.querySelector('#ble-scan-message').textContent.includes('已停止')`);
    assert.equal(await evaluate(`${f}.contentDocument.querySelector('#ble-scan-stop').hidden`), true);
    await evaluate(`${f}.contentDocument.querySelector('#ble-service-uuid').value='6e400001-b5a3-f393-e0a9-e50e24dcca9e'`);
    await evaluate(`${f}.contentDocument.querySelector('#connect').click()`);
    await waitFor(`!${f}.contentDocument.querySelector('#ble-scan-stop').hidden`);
    await pause(2000);
    await evaluate(`${f}.contentDocument.querySelector('#ble-scan-stop').click()`);
    await waitFor(`!${f}.contentDocument.querySelector('#connect').disabled`);
    assert.equal(await evaluate(`${f}.contentDocument.querySelector('#connection-label').textContent`), '未连接硬件');
    await writeFile(resolve(evidence, 'ble-chooser-scan.json'), JSON.stringify({ passed: true, connectedToHardware: false, invalidUuidRecovered: true, cancelled: true }, null, 2));
  }
  // Use known MP3 bytes as current playback; exercise the real import button,
  // parent/iframe origin check, File transfer, decoder, model and WASM worker.
  const fixture = await readFile(resolve(root, '../instrument-web/evidence/reference-notes.mp3'));
  await evaluate(`(async()=>{window.playQueue=[{name:'桌面转谱验证'}];window.currentIdx=0;if(!window.audio)window.audio=new Audio();window.audio.src='data:audio/mpeg;base64,${fixture.toString('base64')}';window.audio.load();})()`);
  await waitFor('window.audio.currentSrc.startsWith("data:audio/mpeg")');
  await evaluate(`document.querySelector('#fpga-current').click()`);
  await waitFor(`${f}.contentDocument.querySelector('#audio-file-name').textContent.includes('桌面转谱验证')`);
  await waitFor(`document.querySelector('#fpga-source-status').textContent.startsWith('已导入')`);
  // Local playback need not have a queue entry.
  await evaluate(`window.currentLocalSong={name:'本地播放验证'};window.currentIdx=-1;window.playQueue=[];document.querySelector('#fpga-current').click()`);
  await waitFor(`${f}.contentDocument.querySelector('#audio-file-name').textContent.includes('本地播放验证')`);
  await evaluate(`window.__workbenchIdentity=${f}.contentWindow;document.querySelector('#mode-player').click()`);
  assert.equal(await evaluate(`document.querySelector('#fpga-playback').hidden`), true);
  assert.notEqual(await evaluate(`getComputedStyle(document.querySelector('#search-area')).display`), 'none');
  assert.equal(await evaluate(`document.querySelector('#search-area').inert`), false);
  await evaluate(`document.querySelector('#mode-player').focus()`);
  await page('Input.dispatchKeyEvent', { type: 'keyDown', key: 'ArrowRight', code: 'ArrowRight' });
  await page('Input.dispatchKeyEvent', { type: 'keyUp', key: 'ArrowRight', code: 'ArrowRight' });
  assert.equal(await evaluate(`document.querySelector('#mode-fpga').getAttribute('aria-pressed')`), 'true');
  assert.equal(await evaluate(`${f}.contentWindow===window.__workbenchIdentity`), true);
  assert.match(await evaluate(`${f}.contentDocument.querySelector('#audio-file-name').textContent`), /本地播放验证/);
  await evaluate(`${f}.contentDocument.querySelector('#transcribe-audio').click()`);
  await evaluate(`document.querySelector('#fpga-current').click()`);
  await waitFor(`document.querySelector('#fpga-source-status').textContent.includes('请先取消或等待')`);
  await waitFor(`${f}.contentDocument.querySelector('#audio-progress').textContent.includes('识别完成')`, 120);
  const transcription = await evaluate(`${f}.contentDocument.querySelector('#audio-progress').textContent`);
  assert.match(transcription, /[1-9]\d* 个音符/);
  await evaluate(`${f}.contentDocument.querySelector('.function-rail a').click();${f}.contentDocument.querySelector('#preview-notes').click()`);
  await waitFor(`${f}.contentDocument.querySelector('#performance-visuals').dataset.signal==='true'`);
  await waitFor(`${f}.contentDocument.querySelector('#performance-home .piano-key.active')`);
  const monitor = await evaluate(`({signal:${f}.contentDocument.querySelector('#performance-visuals').dataset.signal,keys:${f}.contentDocument.querySelectorAll('#performance-home .piano-key').length,source:${f}.contentDocument.querySelector('#performance-visuals .monitor-origin').textContent})`);
  assert.equal(monitor.keys, 37);
  await evaluate(`${f}.contentDocument.querySelector('.function-rail a[href="#performance-visuals"]').click()`);
  await waitFor(`(()=>{const d=${f}.contentDocument;return Math.abs(d.querySelector('#performance-visuals').getBoundingClientRect().top-d.querySelector('.desktop-main').getBoundingClientRect().top-d.querySelector('.workflow-steps').offsetHeight-16)<12})()`);
  const plots = await evaluate(`[...${f}.contentDocument.querySelectorAll('.monitor-grid canvas')].map(c=>({width:c.clientWidth,height:c.clientHeight,top:c.getBoundingClientRect().top,bottom:c.getBoundingClientRect().bottom}))`);
  assert.ok(plots.every(plot => plot.height >= 300), JSON.stringify(plots));
  assert.ok(plots.every(plot => plot.width === plots[0].width), 'Each plot must span its own full row');
  assert.ok(plots.slice(1).every((plot, i) => plot.top > plots[i].bottom), 'Plots must stack in three separate rows');
  const visualScreenshot = await page('Page.captureScreenshot', { format: 'png' });
  await writeFile(resolve(evidence, 'desktop-visuals-large.png'), Buffer.from(visualScreenshot.data, 'base64'));
  await evaluate(`${f}.contentDocument.querySelector('#stop-preview').click()`);
  await waitFor(`${f}.contentDocument.querySelector('#performance-visuals').dataset.signal==='false' && !${f}.contentDocument.querySelector('#performance-home .piano-key.active')`);
  await evaluate(`${f}.contentDocument.querySelector('#arrangement-confirm').checked=true;${f}.contentDocument.querySelector('#arrangement-apply').click()`);
  assert.equal(await evaluate(`${f}.contentDocument.querySelector('#preview-upload').disabled`), false);
  await evaluate(`${f}.contentDocument.querySelector('#preview-upload').click()`);
  await waitFor(`${f}.contentDocument.querySelector('#performance-visuals').dataset.signal==='true'`);
  assert.match(await evaluate(`${f}.contentDocument.querySelector('#preview-description').textContent`), /实际上传/);
  await evaluate(`${f}.contentDocument.querySelector('#stop-preview').click()`);
  const workflow = await evaluate(`(()=>{const d=${f}.contentDocument;return {order:[...d.querySelector('.desktop-main').children].filter(e=>e.id).map(e=>e.id),steps:[...d.querySelectorAll('.workflow-steps a')].map(e=>e.hash),boardKeys:d.querySelectorAll('#board-visuals .piano-key').length,position:d.querySelector('#board-visuals').dataset.position};})()`);
  assert.deepEqual(workflow.order, ['source-section', 'performance-home', 'device-panel', 'library-section', 'performance-visuals', 'board-visuals']);
  assert.deepEqual(workflow.steps, ['#source-section', '#performance-home', '#device-panel']);
  assert.equal(workflow.boardKeys, 36); assert.equal(workflow.position, '-1');
  const boardAudioLayout = await evaluate(`(()=>{const d=${f}.contentDocument;return [...d.querySelectorAll('.board-audio-grid canvas')].map(c=>{const r=c.getBoundingClientRect();return {id:c.id,width:r.width,height:r.height,top:r.top,bottom:r.bottom};});})()`);
  assert.deepEqual(boardAudioLayout.map(p=>p.id), ['board-wave','board-spectrum','board-xy']);
  assert.ok(boardAudioLayout.every(p=>p.height>=300), JSON.stringify(boardAudioLayout));
  assert.ok(boardAudioLayout.slice(1).every((p,i)=>p.top>boardAudioLayout[i].bottom));
  assert.equal(await evaluate(`${f}.contentDocument.querySelector('#board-audio-capture').disabled`), true, 'Disconnected desktop must not invent FPGA data');
  for (const target of ['source-section', 'library-section', 'device-panel', 'performance-home', 'board-visuals']) {
    await evaluate(`${f}.contentDocument.querySelector('.function-rail a[href="#${target}"]').click()`);
    await waitFor(`(()=>{const d=${f}.contentDocument,r=d.querySelector('#${target}').getBoundingClientRect(),c=d.querySelector('.desktop-main').getBoundingClientRect();return r.top>=c.top-10&&r.top<c.bottom})()`);
  }
  await waitFor(`${f}.contentDocument.querySelector('.function-rail a[aria-current]').hash === '#board-visuals'`);
  const layout = await evaluate(`(()=>{const r=document.querySelector('#fpga-playback').getBoundingClientRect();return {width:r.width,height:r.height,viewportWidth:innerWidth,viewportHeight:innerHeight};})()`);
  assert.ok(layout.height > 300);
  assert.equal(layout.width, layout.viewportWidth);
  const sidebar = await evaluate(`(()=>{const d=${f}.contentDocument,a=d.querySelector('.desktop-main').getBoundingClientRect(),b=d.querySelector('.ble-sidebar').getBoundingClientRect();return {right:b.left>=a.right,visible:b.top>=0&&b.bottom<=${f}.clientHeight};})()`);
  assert.deepEqual(sidebar, { right: true, visible: true });
  await mouseClick('[data-window-action="maximize"]');
  await waitFor(`document.body.classList.contains('desktop-fullscreen')`);
  await evaluate(`${f}.contentDocument.querySelector('#connect').focus()`);
  await page('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape' });
  await page('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape' });
  await waitFor(`!document.body.classList.contains('desktop-fullscreen')`);
  const screenshot = await page('Page.captureScreenshot', { format: 'png' });
  await writeFile(resolve(evidence, 'desktop-workbench.png'), Buffer.from(screenshot.data, 'base64'));
  assert.deepEqual(errors, [], JSON.stringify(errors));
  await page('Emulation.setDeviceMetricsOverride', { width: 760, height: 720, deviceScaleFactor: 1, mobile: false });
  await pause(500);
  assert.equal(await evaluate(`${f}.contentDocument.documentElement.scrollWidth <= ${f}.clientWidth`), true);
  const narrow = await page('Page.captureScreenshot', { format: 'png' });
  await writeFile(resolve(evidence, 'desktop-workbench-narrow.png'), Buffer.from(narrow.data, 'base64'));
  await page('Emulation.clearDeviceMetricsOverride');
  await evaluate(`document.querySelector('#mode-player').click()`);
  await pause(400);
  const playerScreenshot = await page('Page.captureScreenshot', { format: 'png' });
  await writeFile(resolve(evidence, 'desktop-player.png'), Buffer.from(playerScreenshot.data, 'base64'));
  await writeFile(resolve(evidence, 'desktop-smoke.json'), JSON.stringify({ packagedApp: true, dualMode: true, mouseSwitch: true, nativeWindowControls: true, navigation: true, workflow, monitor, modeStatePreserved: true, transparentBackground: true, keyboardSwitch: true, narrowLayout: true, layout, version, bluetooth, transcription, errors, hardwareBleTested: false }, null, 2));
  console.log(JSON.stringify({ passed: true, version, bluetooth, transcription }));
  await evaluate(`document.querySelector('[data-window-action="close"]').click()`);
  for (let i=0; i<100 && child.exitCode === null; i++) await pause(200);
  assert.equal(child.exitCode, 0, 'Packaged app must exit naturally after Close');
  }
} finally {
  if (socket) socket.close();
  if (child.exitCode === null) child.kill();
  await writeFile(resolve(evidence, 'desktop-smoke.log'), output);
}
