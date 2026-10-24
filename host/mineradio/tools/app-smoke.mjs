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
const evidence = resolve(root, '../../artifacts/mineradio_app_20261021');
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
    while (Date.now() < limit) { if (await evaluate(expression)) return; await new Promise(done => setTimeout(done, 100)); }
    throw Error(`UI timeout: ${expression}`);
  };
  await page('Runtime.enable'); await page('Page.enable');
  await page('Page.addScriptToEvaluateOnNewDocument', { source: `
    Object.defineProperty(navigator,'bluetooth',{value:undefined,configurable:true});
    if(window.top===window){
      window.nativeCalls=[]; window.nativeSession=null; window.receivedWords=0;
      let buffer='',bytes=[],meta,stored,playing=0;
      window.NativeApp={request(id,op,payload){(async()=>{
        const value=JSON.parse(payload); window.nativeCalls.push({op,value});
        let result={};
        if(op==='music-search') result={songs:[{id:1451396976,name:'联调参考音符',artist:'本地合成测试'}]};
        else if(op==='music-download') result={url:'${basePath}/fixture.mp3',name:'reference-notes.mp3',mime:'audio/mpeg'};
        else if(op==='ble-connect'){window.nativeSession=value.sessionId;result={name:'行者无疆'};}
        else if(op==='ble-write'){
          const {decodeScoreFrame,encodeScoreFrame}=await import('${basePath}/instrument/src/score-upload-protocol.js');
          const {crc16Ccitt}=await import('${basePath}/instrument/src/protocol.js');
          buffer+=atob(value.data);
          while(buffer.includes('\\n')){
            const end=buffer.indexOf('\\n'),line=buffer.slice(0,end);buffer=buffer.slice(end+1);
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
  const inside = expression => evaluate(`(()=>{const document=window.document.querySelector('#instrument').contentDocument;return (${expression})})()`);
  assert.equal(await inside(`document.querySelector('#connect').disabled`), false, 'Native BLE must work with navigator.bluetooth absent');
  await inside(`document.querySelector('#transcribe-audio').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#audio-progress').textContent.includes('识别完成')`, 120);
  assert.equal(await inside(`document.querySelector('#note-count').textContent`), '6');
  assert.match(await inside(`document.querySelector('#upload-score').textContent`), /自动识别/);
  assert.equal(await inside(`document.querySelector('#arrangement-advanced').open`), false);
  await inside(`document.querySelector('#arrangement-apply').click()`);
  assert.match(await inside(`document.querySelector('#upload-score').textContent`), /8\/4096/);
  assert.match(await inside(`document.querySelector('#arrangement-report').textContent`), /6 → 4/);
  await inside(`document.querySelector('#connect').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#connection-label').textContent==='BLE 已连接'`);
  await inside(`document.querySelector('#upload-probe').click()`);
  await waitFor(`!document.querySelector('#instrument').contentDocument.querySelector('#upload-start').disabled`);
  await inside(`document.querySelector('#upload-start').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#upload-message').textContent.includes('已确认整曲 CRC')`);
  assert.equal(await evaluate('window.receivedWords'), 8);
  assert.equal(await evaluate(`window.nativeCalls.some(c=>c.op==='ble-write'&&atob(c.value.data).includes(',PLAY,'))`), false);
  await inside(`document.querySelector('#upload-play').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#upload-playback-state').textContent.includes('准备播放')`);
  assert.equal(await inside(`document.querySelector('#upload-stop').textContent.trim()`), '停止播放');
  await inside(`document.querySelector('#upload-stop').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#upload-playback-state').textContent.includes('空闲')`);
  await inside(`document.querySelector('#export-score').click()`);
  await waitFor('!!window.savedFile');
  const backup = await evaluate(`JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(window.savedFile.data),x=>x.charCodeAt(0))))`);
  assert.equal(backup.project.arrangement.melodyNotes, 4);
  await writeFile(resolve(evidence, 'arranged-score.json'), JSON.stringify(backup, null, 2));
  assert.equal(await inside(`document.documentElement.scrollWidth<=document.documentElement.clientWidth`), true);
  await writeFile(resolve(evidence, 'workbench-mobile.png'), Buffer.from((await page('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true })).data, 'base64'));
  await inside(`document.querySelector('#library-save').click()`);
  await inside(`document.querySelector('#disconnect').click()`);
  await waitFor(`document.querySelector('#instrument').contentDocument.querySelector('#connection-label').textContent==='未连接硬件'`);
  assert.equal(await inside(`document.querySelector('#upload-play').disabled`), true);
  assert.deepEqual(errors, []);
  const result = { passed: true, recognizedNotes: 6, arrangedNotes: 4, uploadedEventWords: 8, browser: 'installed Microsoft Edge', realModel: true, nativeBleAndFpga: 'MOCKED, not physical hardware', checks: ['music source RPC -> decoded MP3 -> iframe import', 'no Web Bluetooth API required', 'model/worker/WASM transcription', 'explicit arrangement and unchanged hardware compiler', 'CAPS/DATA/COMMIT CRC and PLAY/STOP ACK', 'Android save-file RPC includes arrangement', 'mobile layout and zero runtime exceptions'] };
  await writeFile(resolve(evidence, 'app-smoke.json'), JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result, null, 2));
  await command('Browser.close');
} finally {
  await writeFile(resolve(evidence, 'browser.log'), browserOutput);
  socket?.close(); browser.kill(); server.closeAllConnections(); await new Promise(done => server.close(done));
}
