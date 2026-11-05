// Real Chromium + bundled model/worker/WASM. Native RPC/GATT and FPGA replies
// are explicitly mocked: this is not a claim of Android hardware validation.
import { createServer } from 'node:http';
import { readFile, mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { resolve, dirname, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const assets = resolve(root, 'android/app/src/main/assets');
const fullPlayer = process.argv.includes('--player');
const evidence = resolve(root, fullPlayer ? '../../artifacts/fpgavedio_android_20261027' : '../../artifacts/mineradio_app_20261021');
// Match Android's token-prefixed loopback origin, not just root hosting.
const basePath = '/android-test-token';
await mkdir(evidence, { recursive: true });
const server = createServer(async (req, res) => {
  try {
    const requestPath = new URL(req.url, 'http://localhost').pathname;
    if (!requestPath.startsWith(basePath + '/')) return res.writeHead(404).end();
    const path = requestPath.slice(basePath.length);
    const target = path === '/fixture.mp3' ? resolve(root, '../instrument-web/evidence/reference-notes.mp3') : resolve(assets, '.' + path);
    if (path !== '/fixture.mp3' && !target.startsWith(assets + sep)) return res.writeHead(403).end();
    const body = await readFile(target);
    res.writeHead(200, { 'Content-Type': ({ '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html; charset=utf-8', '.wasm': 'application/wasm', '.json': 'application/json', '.mp3': 'audio/mpeg' })[extname(target)] || 'application/octet-stream' });
    res.end(body);
  } catch { res.writeHead(404).end(); }
});
await new Promise(done => server.listen(0, '127.0.0.1', done));
const profile = await mkdtemp(resolve(root, '../../work/mineradio-browser-'));
const browser = spawn(process.env.CHROME_PATH || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { windowsHide: true });
// Drain both pipes so verbose Chromium startup diagnostics cannot block it.
let browserOutput = '';
for (const stream of [browser.stdout, browser.stderr]) stream.on('data', data => {
  browserOutput = (browserOutput + data).slice(-16000);
});
let socket;
try {
  const endpoint = await new Promise((done, reject) => {
    const poll = setInterval(async () => {
      try { const [port, path] = (await readFile(resolve(profile, 'DevToolsActivePort'), 'utf8')).trim().split(/\r?\n/); if (port && path) { clearInterval(poll); clearTimeout(timer); done(`ws://127.0.0.1:${port}${path}`); } } catch {}
    }, 200);
    const timer = setTimeout(() => { clearInterval(poll); reject(Error('Browser startup timeout')); }, 20000);
    browser.on('error', e => { clearInterval(poll); clearTimeout(timer); reject(e); });
  });
  socket = new WebSocket(endpoint);
  await new Promise((done, reject) => { socket.onopen = done; socket.onerror = reject; });
  let sequence = 0; const pending = new Map(), errors = [];
  socket.onmessage = ({ data }) => {
    const event = JSON.parse(data);
    if (event.id) { const p = pending.get(event.id); if (!p) return; pending.delete(event.id); clearTimeout(p.timer); event.error ? p.reject(Error(event.error.message)) : p.done(event.result); }
    if (event.method === 'Runtime.exceptionThrown') errors.push(event.params.exceptionDetails);
  };
  const command = (method, params = {}, sessionId) => new Promise((done, reject) => {
    const id = ++sequence, timer = setTimeout(() => { pending.delete(id); reject(Error(`CDP timeout ${method}`)); }, 15000);
    pending.set(id, { done, reject, timer }); socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  const { targetId } = await command('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await command('Target.attachToTarget', { targetId, flatten: true });
  const page = (method, params) => command(method, params, sessionId);
  const evaluate = async expression => {
    const r = await page('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true });
    if (r.exceptionDetails) throw Error(JSON.stringify(r.exceptionDetails)); return r.result.value;
  };
  const waitFor = async (expression, seconds = 10) => {
    const limit = Date.now() + seconds * 1000;
    while (Date.now() < limit) { if (await evaluate(`Boolean(${expression})`)) return; await new Promise(done => setTimeout(done, 100)); }
    throw Error(`UI timeout: ${expression}`);
  };
  await page('Runtime.enable'); await page('Page.enable');
  await page('Page.addScriptToEvaluateOnNewDocument', { source: `
    Object.defineProperty(navigator,'bluetooth',{value:undefined,configurable:true});
    if(window.top===window){
      window.nativeCalls=[]; window.nativeSession=null; window.receivedWords=0;
      let buffer='',bytes=[],meta,stored,playing=0;
      let performanceMap=null,performanceCustom=false,recordingId=null;
      window.NativeApp={request(id,op,payload){(async()=>{
        const value=JSON.parse(payload); window.nativeCalls.push({op,value});
        let result={};
        if(op==='music-search') result={songs:[{id:1451396976,name:'联调参考音符',artist:'本地合成测试'}]};
        else if(op==='music-status') result={loggedIn:!!window.testLoggedIn,nickname:'测试账号'};
        else if(op==='music-login-key') result={key:'mock-key',url:'https://music.163.com/login?codekey=mock-key'};
        else if(op==='music-login-check') { const code=window.testLoginCode||801; if(code===803)window.testLoggedIn=true; result={code,loggedIn:code===803,nickname:'测试账号'}; }
        else if(op==='music-logout') { window.testLoggedIn=false;result={loggedIn:false}; }
        else if(op==='save-login-qr') result={saved:true};
        else if(op==='music-download') result={url:'${basePath}/fixture.mp3',name:'reference-notes.mp3',mime:'audio/mpeg'};
        else if(op==='ble-connect'){window.nativeSession=value.sessionId;result={name:'行者无疆'};}
        else if(op==='ble-write'){
          const {decodeScoreFrame,encodeScoreFrame}=await import('${basePath}/instrument/src/score-upload-protocol.js');
          const {crc16Ccitt}=await import('${basePath}/instrument/src/protocol.js');
          buffer+=atob(value.data);
          while(buffer.includes('\\n')){
            const end=buffer.indexOf('\\n'),line=buffer.slice(0,end);buffer=buffer.slice(end+1);
            if(line.startsWith('PERF1,')){
              const {performanceLine,performanceCrc,packKeymap}=await import('${basePath}/instrument/src/performance-protocol.js');
              const fields=line.split(',');if(performanceCrc(line.slice(0,-5))!==fields.at(-1))throw Error('Performance request CRC');
              const identity=fields[1],operation=+fields[2];
              performanceMap??=packKeymap(Array.from({length:12},(_,i)=>60+i));
              if(operation===1){performanceMap=fields[3];performanceCustom=true;}
              if(operation===2)performanceCustom=false;
              if(operation===3)recordingId=identity;
              const emit=body=>{const text=performanceLine(body);for(let i=0;i<text.length;i+=17)window.mineradioNative.deliver({type:'ble-data',sessionId:window.nativeSession,data:btoa(text.slice(i,i+17))});};
              emit('PERF1,'+identity+',A,'+operation+','+(operation<=2&&performanceCustom?1:0)+','+performanceMap);
              if(operation===3)setTimeout(()=>{if(recordingId===identity)emit('PERF1,'+identity+',D,0000,0000,00,'+'A'.repeat(160));},20);
              if(operation===4){emit('PERF1,'+identity+',E,0001,0');recordingId=null;}
              continue;
            }
            const frame=decodeScoreFrame(line);if(!frame)throw Error('Request CRC');
            const [,sid,seq,operation,...v]=frame;let reply=[];
            if(operation==='CAPS')reply=[12,512,8,1];
            if(operation==='BEGIN'){meta=v;bytes=[];reply=[0];}
            if(operation==='DATA'){
              if(+v[0]!==bytes.length/8)throw Error('Offset');
              bytes.push(...v[2].match(/../g).map(x=>parseInt(x,16)));reply=[bytes.length/8];
            }
            if(operation==='COMMIT'){
              const crc=crc16Ccitt(bytes).toString(16).padStart(4,'0').toUpperCase();
              if(crc!==meta[4]||bytes.length!==+meta[1]*8)throw Error('Whole score CRC');
              stored={length:bytes.length/8,crc};window.receivedWords=stored.length;reply=[stored.length,crc];
            }
            if(['PLAY','STOP','STATUS'].includes(operation)){
              if(operation==='STATUS'&&window.holdStatusReply)await new Promise(resolve=>{window.releaseStatusReply=()=>{window.holdStatusReply=false;window.releaseStatusReply=null;resolve();};});
              if(operation==='PLAY'){if(+v[0]!==stored.length||v[1]!==stored.crc)throw Error('PLAY identity');playing=1;}
              if(operation==='STOP')playing=0;
              reply=[playing,0,stored.length,stored.crc,1,stored.crc];
            }
            const ack=encodeScoreFrame(['ACK2',sid,seq,operation,...reply]);
            // Notifications are split, and arrive before write completion.
            for(let i=0;i<ack.length;i+=7) window.mineradioNative.deliver({type:'ble-data',sessionId:window.nativeSession,data:btoa(ack.slice(i,i+7))});
          }
        } else if(op==='save-file') window.savedFile=value;
        window.mineradioNative.deliver({id,result});
      })().catch(error=>window.mineradioNative.deliver({id,error:error.message}));}};
    }
  ` });
  await page('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  if (fullPlayer) {
    await page('Page.navigate', { url: `http://127.0.0.1:${server.address().port}${basePath}/android.html` });
    await waitFor(`typeof window.handleFiles==='function' && !!document.querySelector('#mode-fpga')`, 30);
    await waitFor(`window.splashReadyToEnter`, 15);
    await evaluate(`document.querySelector('#splash').click()`);
    await waitFor(`!document.body.classList.contains('splash-active')`, 15);
    await evaluate(`document.querySelector('#android-menu').click()`);
    assert.equal(await evaluate(`document.querySelector('#android-account').getBoundingClientRect().width>0`), true, 'Login entry is visible inside drawer');
    await evaluate(`document.querySelector('#android-account').click()`);
    await waitFor(`document.querySelector('#android-login').open && !document.querySelector('#android-login-qr').hidden`);
    await evaluate(`document.querySelector('#android-login-save').click()`);
    await waitFor(`window.nativeCalls.some(c=>c.op==='save-login-qr' && c.value.data.length>100)`);
    await evaluate(`window.testLoginCode=800`);
    await waitFor(`document.querySelector('#android-login-status').textContent.includes('过期')`);
    assert.equal(await evaluate(`window.testLoggedIn===true`), false, 'Expired QR must not log in');
    await evaluate(`window.testLoginCode=803;document.querySelector('#android-login-refresh').click()`);
    await waitFor(`document.querySelector('#android-account').textContent==='测试账号'`);
    await evaluate(`document.querySelector('#android-login-logout').click()`);
    await waitFor(`document.querySelector('#android-account').textContent==='网易云登录'`);
    await evaluate(`document.querySelector('#android-login').close()`);
    await evaluate(`document.querySelector('#android-menu').click();document.querySelector('#android-drawer [data-page="queue"]').click()`);
    assert.equal(await evaluate(`(()=>{const p=document.querySelector('#playlist-panel').getBoundingClientRect(),s=document.querySelector('#search-box').getBoundingClientRect();return p.top>=s.bottom && document.elementFromPoint(s.left+s.width/2,s.top+s.height/2).id==='search-input';})()`), true, 'Queue must never cover search');
    await writeFile(resolve(evidence, 'phone-queue.png'), Buffer.from((await page('Page.captureScreenshot', { format: 'png' })).data, 'base64'));
    await evaluate(`document.querySelector('#android-menu').click();document.querySelector('#android-drawer [data-page="home"]').click();setPeek(document.querySelector('#playlist-panel'),true,'pl')`);
    assert.equal(await evaluate(`getComputedStyle(document.querySelector('#playlist-panel')).display`), 'none', 'Desktop hover must not open phone library');
    await writeFile(resolve(evidence, 'phone-home.png'), Buffer.from((await page('Page.captureScreenshot', { format: 'png' })).data, 'base64'));
    await evaluate(`document.querySelector('#android-menu').click()`);
    await writeFile(resolve(evidence, 'phone-drawer.png'), Buffer.from((await page('Page.captureScreenshot', { format: 'png' })).data, 'base64'));
    await evaluate(`document.querySelector('#android-menu-close').click()`);
    assert.equal(await evaluate(`document.querySelector('#mode-player').getAttribute('aria-pressed')`), 'true');
    assert.equal(await evaluate(`document.querySelector('#android-send-current').disabled`), true, 'No audio means no misleading transfer action');
    await evaluate(`document.querySelector('#search-input').value='小星星';document.querySelector('#search-input').dispatchEvent(new Event('input',{bubbles:true}))`);
    await waitFor(`document.querySelector('#search-results .search-result')`, 20);
    await evaluate(`playSearchResult(0)`);
    await waitFor(`window.audio?.currentSrc && window.audio.readyState >= 2 && !window.audio.paused && window.audio.currentTime > 0.2`, 30);
    await waitFor(`!document.querySelector('#android-send-current').disabled`);
    assert.match(await evaluate(`document.querySelector('#android-now-title').textContent`), /联调参考音符/);
    await evaluate(`document.querySelector('#search-input').blur();document.querySelector('#search-results').classList.remove('show')`);
    assert.equal(await evaluate(`document.querySelector('#search-area').getBoundingClientRect().top >= document.querySelector('#fpga-mode-switch').getBoundingClientRect().bottom`), true, 'Phone search must not overlap the mode switch');
    await writeFile(resolve(evidence, 'full-player.png'), Buffer.from((await page('Page.captureScreenshot', { format: 'png' })).data, 'base64'));
    // Cold workbench: one button must load the iframe, then import and confirm.
    assert.equal(await evaluate(`document.querySelector('#fpga-playback iframe').hasAttribute('src')`), false);
    await evaluate(`document.querySelector('#android-send-current').click()`);
    await waitFor(`document.querySelector('#fpga-playback iframe')?.contentDocument?.querySelector('.function-rail')`, 30);
    await evaluate(`document.querySelector('#fpga-playback iframe').id='instrument'`);
    await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#audio-file-name').textContent.includes('联调参考音符')`);
  } else {
  await page('Page.navigate', { url: `http://127.0.0.1:${server.address().port}${basePath}/mobile.html` });
  await waitFor(`document.querySelector('#instrument')?.contentDocument?.querySelector('#status')?.textContent.includes('不会自动发送')`);
  assert.equal(await evaluate(`document.documentElement.scrollWidth<=innerWidth`), true);
  await evaluate(`document.querySelector('#keywords').value='小星星';document.querySelector('#search-form').requestSubmit()`);
  await waitFor(`document.querySelector('#search-results button')`);
  await evaluate(`document.querySelector('#search-results button').click()`);
  await waitFor(`!document.querySelector('#convert-current').disabled`);
  await writeFile(resolve(evidence, 'music-mobile.png'), Buffer.from((await page('Page.captureScreenshot', { format: 'png' })).data, 'base64'));
  await evaluate(`document.querySelector('#convert-current').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#audio-file-name').textContent.includes('reference-notes')`);
  }
  const inside = expression => evaluate(`(()=>{const document=window.document.querySelector('#instrument').contentDocument;return (${expression})})()`);
  assert.equal(await inside(`document.querySelector('#connect').disabled`), false, 'Native BLE must work with navigator.bluetooth absent');
  await inside(`document.querySelector('#transcribe-audio').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#audio-progress').textContent.includes('识别完成')`, 120);
  assert.equal(await inside(`document.querySelector('#note-count').textContent`), '6');
  assert.match(await inside(`document.querySelector('#upload-score').textContent`), /自动识别/);
  assert.equal(await inside(`document.querySelector('#arrangement-advanced').open`), false);
  await inside(`document.querySelector('#arrangement-apply').click()`);
  assert.match(await inside(`document.querySelector('#upload-score').textContent`), /12\/4096/);
  assert.match(await inside(`document.querySelector('#arrangement-report').textContent`), /6 → 6/);
  assert.match(await inside(`document.querySelector('#arrangement-report').textContent`), /和弦延音/);
  await inside(`document.querySelector('#connect').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#connection-label').textContent==='BLE 已连接'`);
  await inside(`document.querySelector('#upload-probe').click()`);
  await waitFor(`!document.querySelector('#instrument').contentDocument.querySelector('#upload-start').disabled`);
  await inside(`document.querySelector('#upload-start').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#upload-message').textContent.includes('已确认整曲 CRC')`);
  assert.equal(await evaluate('window.receivedWords'), 12);
  assert.equal(await evaluate(`window.nativeCalls.some(c=>c.op==='ble-write'&&atob(c.value.data).includes(',PLAY,'))`), false);
  await inside(`document.querySelector('#upload-play').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#upload-playback-state').textContent.includes('准备播放')`);
  assert.equal(await inside(`document.querySelector('#upload-stop').textContent.trim()`), '停止播放');
  await inside(`document.querySelector('#upload-stop').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#upload-playback-state').textContent.includes('空闲')`);
  await inside(`document.querySelector('#export-score').click()`);
  await waitFor('!!window.savedFile');
  const backup = await evaluate(`JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(window.savedFile.data),x=>x.charCodeAt(0))))`);
  assert.equal(backup.project.arrangement.melodyNotes, 6);
  assert.equal(backup.project.arrangement.mode, 'polyphonic');
  assert.equal(backup.project.tracks.length, 2);
  // A fresh connection may start recording directly: the view probes first.
  assert.equal(await inside(`document.querySelector('#record-start').disabled`),false);
  await inside(`document.querySelector('#record-start').click()`);
  await waitFor(`!document.querySelector('#instrument').contentDocument.querySelector('#record-stop').disabled`);
  await new Promise(resolve=>setTimeout(resolve,100));
  await inside(`document.querySelector('#record-stop').click()`);
  await waitFor(`!document.querySelector('#instrument').contentDocument.querySelector('#record-result').hidden`);
  await waitFor(`!document.querySelector('#instrument').contentDocument.querySelector('#keymap-apply').disabled`);
  assert.equal(await inside(`document.querySelectorAll('#keymap-grid select').length`),12);
  await inside(`(()=>{document.querySelector('#keymap-grid select').value='83';document.querySelector('#keymap-grid select').dispatchEvent(new Event('change'));document.querySelector('#keymap-apply').click();})()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#performance-message').textContent.includes('已在 FPGA 生效')`);
  // Reproduce the real UI problem: a delayed background STATUS owns the link.
  // No transient busy event may disable Start, and one click must run once
  // after that reply without overlapping or starving the manual command.
  await evaluate(`window.holdStatusReply=true`);
  await inside(`(()=>{document.querySelector('#board-monitor-auto').checked=true;document.querySelector('#board-monitor-auto').dispatchEvent(new Event('change'));})()`);
  await waitFor(`typeof window.releaseStatusReply==='function'`);
  assert.equal(await inside(`document.querySelector('#record-start').disabled`),false,'STATUS must not blink/disable recording button');
  await inside(`(()=>{document.querySelector('#record-start').click();document.querySelector('#record-start').click();})()`);
  assert.match(await inside(`document.querySelector('#record-state').textContent`),/等待当前通信/);
  assert.equal(await inside(`document.querySelector('#record-stop').disabled`),true,'no optimistic recording before ACK');
  await evaluate(`window.releaseStatusReply()`);
  await waitFor(`!document.querySelector('#instrument').contentDocument.querySelector('#record-stop').disabled`);
  await new Promise(resolve=>setTimeout(resolve,100));
  await inside(`document.querySelector('#record-stop').click()`);
  await waitFor(`!document.querySelector('#instrument').contentDocument.querySelector('#record-result').hidden`);
  await waitFor(`!document.querySelector('#instrument').contentDocument.querySelector('#record-start').disabled`);
  await inside(`document.querySelector('#record-save').click()`);
  await waitFor(`window.savedFile?.mime==='audio/wav'`);
  const recorded=Buffer.from(await evaluate('window.savedFile.data'),'base64');
  assert.equal(recorded.toString('ascii',0,4),'RIFF');assert.equal(recorded.readUInt32LE(24),12000);assert.equal(recorded.readUInt32LE(40),480);
  const recordingStarts=await evaluate(`window.nativeCalls.filter(c=>c.op==='ble-write').map(c=>atob(c.value.data)).filter(s=>/^PERF1,[0-9A-F]{8},3,/.test(s)).length`);
  assert.equal(recordingStarts,2,'direct start and busy-link start each send exactly one START');
  await inside(`document.querySelector('#board-monitor-auto').checked=false`);
  if(fullPlayer)await inside(`document.querySelector('.function-rail a[href="#live-performance"]').click()`);
  if(fullPlayer)await waitFor(`(()=>{const d=document.querySelector('#instrument').contentDocument,r=d.querySelector('#live-performance').getBoundingClientRect();return r.top>=0 && r.top<140;})()`);
  await writeFile(resolve(evidence,'performance-mobile.png'),Buffer.from((await page('Page.captureScreenshot',{format:'png'})).data,'base64'));
  assert.equal(await inside(`document.documentElement.scrollWidth<=document.documentElement.clientWidth`),true,'Performance editor must fit phone');
  if(fullPlayer){
    await page('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
    await inside(`document.querySelector('#live-performance').scrollIntoView()`);
    await new Promise(resolve=>setTimeout(resolve,300));
    await writeFile(resolve(evidence,'performance-wide.png'),Buffer.from((await page('Page.captureScreenshot',{format:'png'})).data,'base64'));
    await page('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
  }
  await writeFile(resolve(evidence, 'arranged-score.json'), JSON.stringify(backup, null, 2));
  assert.equal(await inside(`document.documentElement.scrollWidth<=document.documentElement.clientWidth`), true);
  await writeFile(resolve(evidence, 'workbench-mobile.png'), Buffer.from((await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true })).data, 'base64'));
  await inside(`document.querySelector('#library-save').click()`);
  await inside(`document.querySelector('#disconnect').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#connection-label').textContent==='未连接硬件'`);
  assert.equal(await inside(`document.querySelector('#upload-play').disabled`), true);
  if (fullPlayer) {
    await evaluate(`document.querySelector('#android-menu').click();document.querySelector('#android-drawer [data-page="rhythm"]').click()`);
    await waitFor(`document.querySelector('#instrument').contentDocument.body.classList.contains('rhythm-mode')`);
    assert.equal(await evaluate('window.audio.paused'), true);
    assert.equal(await inside(`document.documentElement.scrollWidth<=document.documentElement.clientWidth`), true);
    await inside(`document.querySelector('#rhythm-start').click()`);
    try { await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#rhythm-judgement').textContent==='轮到你了'`); }
    catch (error) { console.log(await inside(`document.querySelector('#rhythm-root').innerText`)); throw error; }
    const point = await evaluate(`(()=>{const f=document.querySelector('#instrument'),d=f.contentDocument;d.scrollingElement.scrollTop=0;const r=d.querySelector('#rhythm-keys button').getBoundingClientRect(),p=f.getBoundingClientRect();return {x:p.x+r.x+r.width/2,y:p.y+r.y+r.height/2};})()`);
    assert.ok(point.y < 844 && point.y > 0, 'Phone key must be reachable without horizontal scrolling');
    await page('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ ...point, id: 1 }] });
    await page('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#rhythm-points').textContent==='00100'`);
    await writeFile(resolve(evidence, 'phone-rhythm.png'), Buffer.from((await page('Page.captureScreenshot', { format: 'png' })).data, 'base64'));
    await evaluate(`document.querySelector('#android-menu').click();document.querySelector('#android-drawer [data-page="home"]').click()`);
    assert.equal(await inside(`document.querySelector('#rhythm-start').textContent`), '继续练习');
  }
  assert.deepEqual(errors, []);
  const result = { passed: true, recognizedNotes: 6, arrangedNotes: 6, uploadedEventWords: 12, browser: 'installed Microsoft Edge', realModel: true, nativeBleAndFpga: 'MOCKED, not physical hardware', checks: ['music source RPC -> decoded MP3 -> iframe import', 'no Web Bluetooth API required', 'model/worker/WASM transcription', 'polyphonic arrangement and unchanged hardware compiler', 'CAPS/DATA/COMMIT CRC and PLAY/STOP ACK', 'Android save-file RPC includes two-track arrangement', 'mobile layout and zero runtime exceptions'] };
  if (fullPlayer) result.checks.push('visible account entry; QR render/save, expiry, authorization and logout (mocked provider)', 'actual player media time advances', 'drawer navigation keeps search reachable', 'current song button loads cold workbench and imports matching audio');
  result.checks.push('12-key map read/apply ACK and recording START/DATA/STOP/END to native WAV save (mock FPGA)');
  result.checks.push('recording button stays clickable during delayed STATUS; automatic capability probe; duplicate clicks send one START after pending reply');
  if (fullPlayer) result.checks.push('third rhythm mode from drawer, real touch hit, pause on leaving, mobile layout');
  await writeFile(resolve(evidence, 'app-smoke.json'), JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result, null, 2));
  await command('Browser.close');
} finally {
  await writeFile(resolve(evidence, 'browser.log'), browserOutput);
  socket?.close(); browser.kill(); server.closeAllConnections(); await new Promise(done => server.close(done));
}
