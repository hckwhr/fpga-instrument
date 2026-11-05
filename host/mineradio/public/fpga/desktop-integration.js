// Integration point in the upstream player: current playback stays owned by
// Mineradio, conversion/upload stays owned by the shared instrument workbench.
const stylesheet = document.createElement('link');
stylesheet.rel = 'stylesheet';
stylesheet.href = 'fpga/desktop-integration.css';
document.head.append(stylesheet);

const shell = document.querySelector('#desktop-window-shell');
// Keep the original background renderers and window controls in both modes.
// Do not reparent the player's DOM: upstream layout and event bindings own it.
const sharedLayers = new Set(['desktop-titlebar', 'custom-bg', 'wallpaper-engine-layer',
  'wallpaper-engine-glass-sampler', 'album-bg', 'album-bg-next', 'canvas-container',
  'idle-guide-canvas', 'splash']);
const playerSurfaces = [...shell.children].filter(node =>
  !sharedLayers.has(node.id) && !['SCRIPT', 'STYLE', 'LINK', 'SVG'].includes(node.tagName));
for (const node of playerSurfaces) node.classList.add('fpga-player-surface');

const switcher = document.createElement('nav');
switcher.id = 'fpga-mode-switch';
switcher.setAttribute('aria-label', '播放模式');
switcher.innerHTML = '<button id="mode-player" type="button" aria-pressed="true" aria-controls="desktop-window-shell"><svg viewBox="0 0 20 20" aria-hidden="true"><path d="m7 4 9 6-9 6Z"/></svg>播放器</button><button id="mode-fpga" type="button" aria-pressed="false" aria-controls="fpga-playback"><svg viewBox="0 0 20 20" aria-hidden="true"><rect x="5" y="5" width="10" height="10" rx="2"/><path d="M8 1v4m4-4v4M8 15v4m4-4v4M1 8h4m-4 4h4m10-4h4m-4 4h4"/></svg>FPGA 播放</button>';
const panel = document.createElement('section');
const rhythmButton = document.createElement('button');
rhythmButton.id = 'mode-rhythm'; rhythmButton.type = 'button'; rhythmButton.textContent = '节奏大师';
rhythmButton.setAttribute('aria-pressed', 'false'); rhythmButton.setAttribute('aria-controls', 'fpga-playback');
switcher.append(rhythmButton);
panel.id = 'fpga-playback';
panel.hidden = true;
panel.setAttribute('aria-label', 'FPGA 播放模式');
panel.innerHTML = '<header class="fpga-playback-header"><div><p class="fpga-eyebrow">MUSIC TO INSTRUMENT</p><h1>FPGA 播放</h1><p class="fpga-description">把喜欢的音乐，交给你的乐器演奏。</p></div><div class="fpga-import"><button type="button" id="fpga-current">导入播放器当前歌曲 <span aria-hidden="true">↗</span></button><p role="status" id="fpga-source-status">也可以在下方选择本地音频或 MIDI</p></div></header><iframe title="曲谱转化与 BLE 乐器控制" allow="bluetooth; serial"></iframe>';
// Fixed controls must live outside the transformed/scrollable player shell.
// scrollIntoView in a child frame can otherwise scroll its clipped ancestors.
document.body.append(panel, switcher);
const titlebar = document.querySelector('#desktop-titlebar');
if (titlebar) document.body.append(titlebar);
const frame = panel.querySelector('iframe');
let ready = false;
let importRequest = null;
const previousInert = new Map();
let activeMode = 'player';
function notifyMode() {
  frame.contentWindow?.dispatchEvent(new CustomEvent('instrument-mode', { detail: activeMode }));
  frame.contentWindow?.dispatchEvent(new CustomEvent('instrument-visibility', { detail: activeMode !== 'player' }));
}
function setMode(mode) {
  activeMode = mode;
  const fpga = mode !== 'player';
  if (mode === 'rhythm') window.audio?.pause();
  if (fpga) window.desktopWindow?.ensureInstrumentWindow().catch(error => {
    panel.querySelector('#fpga-source-status').textContent = `窗口恢复失败：${error.message}`;
  });
  if (fpga && !frame.getAttribute('src')) frame.src = 'instrument/index.html';
  document.body.classList.toggle('fpga-playback-mode', fpga);
  document.body.classList.toggle('rhythm-playback-mode', mode === 'rhythm');
  panel.setAttribute('aria-label', mode === 'rhythm' ? '节奏大师模式' : 'FPGA 播放模式');
  panel.hidden = !fpga;
  shell.scrollTop = 0;
  document.scrollingElement.scrollTop = 0;
  if (ready) notifyMode();
  for (const node of playerSurfaces) {
    if (fpga) {
      if (!previousInert.has(node)) previousInert.set(node, node.inert);
      node.inert = true;
    } else if (previousInert.has(node)) {
      node.inert = previousInert.get(node);
      previousInert.delete(node);
    }
  }
  for (const name of ['player', 'fpga', 'rhythm']) switcher.querySelector(`#mode-${name}`).setAttribute('aria-pressed', String(name === mode));
  // Hide, never destroy, the frame so conversion and BLE sessions survive.
}
for (const name of ['player', 'fpga', 'rhythm']) switcher.querySelector(`#mode-${name}`).onclick = () => setMode(name);
// Player shortcuts must not intercept arrows/space on the mode buttons or the
// import toolbar. Keyboard events inside the iframe already stay in its document.
for (const type of ['keydown', 'keyup']) window.addEventListener(type, event => {
  if (!switcher.contains(event.target) && !panel.contains(event.target)) return;
  if (event.target instanceof HTMLButtonElement && ['Enter', ' '].includes(event.key)) {
    event.stopImmediatePropagation();
    if (type === 'keydown') { event.preventDefault(); if (!event.repeat) event.target.click(); }
  } else if (switcher.contains(event.target) && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
    event.stopImmediatePropagation();
    if (type === 'keydown') {
      event.preventDefault();
      const modes = ['player', 'fpga', 'rhythm'];
      const index = modes.indexOf(activeMode);
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? 2 : (index + (event.key === 'ArrowRight' ? 1 : 2)) % 3;
      setMode(modes[next]); switcher.querySelector(`#mode-${modes[next]}`).focus();
    }
  }
}, true);
frame.addEventListener('load', () => {
  // Desktop-only skin; shared web and Android themes stay independently usable.
  const doc = frame.contentDocument;
  if (!doc?.querySelector('#workspace')) {
    panel.querySelector('#fpga-source-status').textContent = '工作台加载失败，请重启应用后重试';
    return;
  }
  const skin = doc.createElement('link');
  skin.rel = 'stylesheet';
  skin.href = '../fpga/embedded-workbench.css';
  const reveal = () => {
    frame.dataset.themed = 'true';
    frame.contentWindow.dispatchEvent(new Event('resize'));
  };
  skin.onerror = reveal;
  skin.onload = reveal;
  doc.head.append(skin);
  if (window.androidAudioUrl) {
    doc.documentElement.classList.add('android-workbench');
    const mobileSkin = doc.createElement('link');
    mobileSkin.rel = 'stylesheet'; mobileSkin.href = '../fpga/android-workbench.css';
    doc.head.append(mobileSkin);
  }
  const integration = doc.createElement('script');
  integration.type = 'module';
  integration.src = '../fpga/desktop-workbench.js';
  doc.head.append(integration);
  doc.addEventListener('keydown', event => {
    if (event.key === 'Escape' && document.body.classList.contains('desktop-fullscreen')) {
      window.desktopWindow?.exitFullscreenWindowed();
    }
  });
  doc.querySelector('.brand')?.setAttribute('href', '#workspace');
});
window.addEventListener('message', event => {
  if (event.origin !== location.origin || event.source !== frame.contentWindow) return;
  if (event.data?.type === 'instrument-ready') { ready = true; notifyMode(); }
  if (event.data?.type === 'instrument-open-workbench') setMode('fpga');
  if (event.data?.type === 'instrument-open-rhythm') setMode('rhythm');
  if (event.data?.type === 'mineradio-audio-result' && event.data.requestId === importRequest?.id) {
    const request = importRequest;
    importRequest = null;
    clearTimeout(request.timer);
    if (event.data.ok) request.resolve(event.data.message);
    else request.reject(new Error(event.data.message || '工作台拒绝了导入'));
  }
});
function waitForWorkbench() {
  if (ready) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const cleanup = () => { clearTimeout(timer); window.removeEventListener('message', listener); };
    const listener = event => {
      if (event.origin === location.origin && event.source === frame.contentWindow && event.data?.type === 'instrument-ready') { cleanup(); resolve(); }
    };
    const timer = setTimeout(() => { cleanup(); reject(new Error('工作台加载超时，请重试')); }, 15000);
    window.addEventListener('message', listener);
  });
}
async function importCurrentSongToFpga() {
  const status = panel.querySelector('#fpga-source-status');
  const button = panel.querySelector('#fpga-current');
  if (button.disabled) return;
  button.disabled = true;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30000);
  try {
    const player = window.audio;
    const song = typeof window.currentCoverSong === 'function' ? window.currentCoverSong() : window.playQueue?.[window.currentIdx];
    if (!player?.currentSrc || !song) throw new Error('请先切到播放器，选择并播放一首歌曲');
    // Snapshot both before the asynchronous first frame load, so a track switch
    // cannot attach the next song's audio to the previous song's name.
    const source = player.currentSrc;
    const name = song.name || '当前歌曲';
    setMode('fpga');
    status.textContent = '正在打开 FPGA 工作台…';
    await waitForWorkbench();
    status.textContent = '正在读取当前歌曲音频…';
    const response = await fetch(source, { signal: controller.signal });
    if (!response.ok) throw new Error(`音频读取失败 ${response.status}`);
    if (Number(response.headers.get('content-length')) > 80 * 1024 * 1024) throw new Error('文件超过 80 MB');
    const blob = await response.blob();
    if (!blob.size || blob.size > 80 * 1024 * 1024) throw new Error('音频为空或超过 80 MB');
    const extension = /flac/.test(blob.type) ? 'flac' : /wav/.test(blob.type) ? 'wav' : 'mp3';
    status.textContent = await new Promise((resolve, reject) => {
      const id = crypto.randomUUID();
      const timer = setTimeout(() => { importRequest = null; reject(new Error('工作台未确认导入，请重试')); }, 5000);
      importRequest = { id, resolve, reject, timer };
      frame.contentWindow.postMessage({ type: 'mineradio-audio', requestId: id, file: new File([blob], `${name}.${extension}`, { type: blob.type || 'audio/mpeg' }) }, location.origin);
    });
  } catch (error) { status.textContent = error.name === 'AbortError' ? '读取音频超时，请重试或导入本地文件' : error.message; }
  finally { clearTimeout(timeout); button.disabled = false; }
}
panel.querySelector('#fpga-current').onclick = importCurrentSongToFpga;
window.importCurrentSongToFpga = importCurrentSongToFpga;
