import { analyzeEvents, compileTracks, midiNoteName, parseMidi } from "./midi.js";
import { encodePreviewFrames, serializeCsv, serializeJsonl } from "./protocol.js";
import { BleTransport } from "./ble-transport.js";
import { createNotePreview, transcribeAudioFile, scorePreviewEvents } from "./audio.js";
import { ScoreLibrary, LIBRARY_KEY, parseScore, serializeScore } from './score-library.js';
import { DeviceSession } from './device-session.js';
import { ScoreUploadSession } from './score-upload.js';
import { compileSelectedFpgaScore } from './fpga-score.js';
import { arrangeAudioMelody, audioSelectionEnd } from './audio-arrangement.js';
import { NativeBleTransport } from './native-ble-transport.js';
import { createPerformanceMonitor } from './performance-monitor.js';
import { createBoardMonitor } from './board-monitor.js';

const $ = (selector) => document.querySelector(selector);
const state = { project: null, events: [], selectedTracks: [], audioFile: null, transcription: null };
const library = new ScoreLibrary();
let libraryId = null;
let sourceFileName = '';
let removedScore = null;
const fileInput = $("#midi-file");
const audioInput = $("#audio-file");
const monitor = createPerformanceMonitor();
const preview = createNotePreview(value => monitor.setPlayback(value));
window.addEventListener('instrument-visibility', event => { if (!event.detail) preview.stop(); });
let audioUrl;
const trackList = $("#track-list");
const status = $("#status");
const diagnostics = $("#diagnostics");
const roll = $("#piano-roll");
const themeToggle = $('#theme-toggle');
function renderThemeToggle() {
  const dark = document.documentElement.dataset.theme === 'dark';
  themeToggle.setAttribute('aria-pressed', String(dark));
  themeToggle.lastElementChild.textContent = dark ? '夜间模式' : '白天模式';
  themeToggle.title = dark ? '切换到白天模式' : '切换到夜间模式';
}
renderThemeToggle();
themeToggle.onclick = () => {
  const theme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = theme;
  document.querySelector('meta[name="theme-color"]').content = theme === 'dark' ? '#211e1b' : '#f5f1e9';
  try { localStorage.setItem('instrument-theme', theme); } catch { /* Switching still works without persistence. */ }
  renderThemeToggle();
  drawRoll(state.events);
};
const activeTransport = window.top.mineradioNative ? new NativeBleTransport(window.top.mineradioNative) : new BleTransport();
const deviceSession = new DeviceSession(activeTransport);
const uploadSession = new ScoreUploadSession(deviceSession);
let compiledUpload = null;
const boardMonitor = createBoardMonitor(deviceSession, uploadSession);
const activeSession = () => deviceSession;
const activeUpload = () => uploadSession;
function renderDeviceState() {
  const s = activeSession().snapshot();
  const available = s.connected && !s.busy && !s.blocked;
  $('#board-message').textContent = s.message;
  $('#board-protocol').textContent = s.identity ? '短命令 v1 · 内置《小星星》《欢乐颂》' : '尚未识别';
  const report = s.report;
  const names = { SETTING: '设置中', MANUAL: '手动演奏模式', PLAYING: '内置曲目演奏中', STOPPED: '内置曲目已结束' };
  $('#board-state').textContent = report ? `${names[report.mode]}${report.total ? ` · 条目 ${report.position}/${report.total}` : ''}（最近查询）` : '未知，请查询状态';
  for (const button of document.querySelectorAll('[data-board-command]')) {
    button.disabled = !available || (!['HELLO', 'PING'].includes(button.dataset.boardCommand) && !s.identity);
  }
  $('#send').disabled = !s.connected || s.busy || s.blockedWrites;
  const upload = activeUpload().snapshot();
  $('#upload-probe').disabled = !available;
  $('#upload-start').disabled = !available || !upload.capability || !compiledUpload || Boolean(state.transcription) || (compiledUpload.length > upload.capability.words || compiledUpload.abi > upload.capability.abi);
  $('#upload-cancel').disabled = !upload.canCancel;
  $('#upload-message').textContent = upload.capability && compiledUpload &&
    (compiledUpload.length > upload.capability.words || compiledUpload.abi > upload.capability.abi)
    ? `当前设备不支持本曲的容量：${compiledUpload.length} 事件、${compiledUpload.melodyCount} 个旋律音符；请升级扩容固件或缩短选段。` : upload.message;
  $('#upload-progress').max = upload.totalWords || 1;
  $('#upload-progress').value = upload.confirmedWords;
  for (const button of document.querySelectorAll('[data-score-command]')) {
    button.disabled = !available || !upload.capability?.playback ||
      (button.dataset.scoreCommand === 'PLAY' && (!compiledUpload || Boolean(state.transcription) || (compiledUpload.length > upload.capability.words || compiledUpload.abi > upload.capability.abi)));
  }
  const playback = upload.playback;
  $('#upload-playback-state').textContent = playback ?
    `${['空闲', '准备播放', '播放中', '已结束', '调度故障'][playback.state]} · ${playback.length ? `曲谱校验码 ${playback.crc}，旋律序号 ${playback.noteIndex}` : '尚无播放记录'} · ${playback.storedValid ? `已存曲谱校验码 ${playback.storedCrc}` : '尚无已存曲谱'}（最近应答）` :
    upload.capability?.playback ? '支持上传曲谱控制，请查询设备状态。' : '设备尚未确认支持上传曲谱播放。';
}
deviceSession.onChange(renderDeviceState);
uploadSession.onChange(renderDeviceState);
function refreshUploadScore() {
  preview.stop();
  const select = $('#upload-melody');
  const previous = select.value;
  select.replaceChildren();
  for (const index of state.selectedTracks) {
    if (!state.project?.tracks[index].notes.length) continue;
    const option = document.createElement('option');
    option.value = String(index); option.textContent = `${index + 1} · ${state.project.tracks[index].title || '未命名轨道'}`;
    select.append(option);
  }
  if ([...select.options].some(o => o.value === previous)) select.value = previous;
  compiledUpload = null;
  try {
    if (state.project) compiledUpload = compileSelectedFpgaScore(state.project, state.selectedTracks, {
      melodyTrack: Number(select.value), speed: Number($('#speed').value) / 100, velocityScale: Number($('#velocity').value) / 100,
    });
    $('#upload-score').textContent = compiledUpload ? `${compiledUpload.length}/4096 个事件字 · 旋律 ${compiledUpload.melodyCount} 音 · 已应用当前速度与力度；结束于最后一个音符释放。` : '请先导入曲谱。';
  } catch (error) { $('#upload-score').textContent = error.message; }
  $('#preview-upload').disabled = !compiledUpload || Boolean(state.transcription);
  boardMonitor.setScore(compiledUpload);
  renderDeviceState();
}
$('#upload-melody').addEventListener('change', refreshUploadScore);
for (const [id, action] of [['#upload-probe', u => u.probe()], ['#upload-start', u => u.upload(compiledUpload)]]) {
  $(id).addEventListener('click', async () => {
    const uploader = activeUpload();
    try { await action(uploader); }
    catch (error) { if (uploader === activeUpload()) $('#upload-message').textContent = error.message; }
  });
}
$('#upload-cancel').addEventListener('click', () => activeUpload().cancel());
for (const button of document.querySelectorAll('[data-score-command]')) {
  button.addEventListener('click', async () => {
    const uploader = activeUpload();
    try { await uploader.control(button.dataset.scoreCommand, compiledUpload); }
    catch (error) { if (uploader === activeUpload()) $('#upload-message').textContent = error.message; }
  });
}
for (const button of document.querySelectorAll('[data-board-command]')) {
  button.addEventListener('click', async () => {
    const session = activeSession();
    try { logLink('命令', button.dataset.boardCommand); await session.request(button.dataset.boardCommand); }
    catch (error) { if (session === activeSession()) $('#board-message').textContent = error.message; }
  });
}
for (const button of document.querySelectorAll('[data-file]')) {
  button.addEventListener('click', () => document.getElementById(button.dataset.file).click());
}
function selectSource(kind) {
  for (const source of ['audio', 'midi']) {
    const selected = source === kind;
    $(`#tab-${source}`).setAttribute('aria-selected', String(selected));
    $(`#tab-${source}`).tabIndex = selected ? 0 : -1;
    $(`#${source}-pane`).hidden = !selected;
  }
}
for (const kind of ['audio', 'midi']) {
  $(`#tab-${kind}`).addEventListener('click', () => selectSource(kind));
  $(`#tab-${kind}`).addEventListener('keydown', event => {
    if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
      event.preventDefault();
      const next = event.key === 'Home' ? 'audio' : event.key === 'End' ? 'midi' : kind === 'audio' ? 'midi' : 'audio';
      if ($(`#tab-${next}`).disabled) return;
      selectSource(next); $(`#tab-${next}`).focus();
    }
  });
}
$('#connection-state').addEventListener('click', () => {
  $('#device-panel').open = true;
  $('#device-panel').scrollIntoView({ block: 'start' });
  $('#device-panel > summary').focus({ preventScroll: true });
});
$('#device-panel').addEventListener('toggle', () => $('#connection-state').setAttribute('aria-expanded', String($('#device-panel').open)));
const bleSupported = !!window.top.mineradioNative || (!!navigator.bluetooth && window.isSecureContext);
const logEntries = [];
function logLink(direction, text) {
  const value = text instanceof Uint8Array ? new TextDecoder().decode(text) : String(text);
  logEntries.push(`${new Date().toLocaleTimeString()} ${direction} ${value.slice(0, 1024)}`);
  if (logEntries.length > 100) logEntries.shift();
  $("#serial-log").textContent = logEntries.join('\n');
}
function updateConnectionUi({ state = activeTransport.state, connected = activeTransport.connected, message } = {}) {
  $("#connection-state").dataset.connected = String(connected);
  $("#connection-label").textContent = connected ? 'BLE 已连接' : state === 'connecting' ? '正在连接' : '未连接硬件';
  if (message) $("#link-status").textContent = message;
  $("#connect").disabled = !bleSupported || state !== 'disconnected';
  $("#disconnect").disabled = !connected;
  $("#send").disabled = !connected;
  $("#ble-service-uuid").disabled = state !== 'disconnected';
  $("#ble-write-uuid").disabled = state !== 'disconnected';
  $("#ble-notify-uuid").disabled = state !== 'disconnected';
  $("#ble-name-prefix").disabled = state !== 'disconnected';
  renderDeviceState();
}
function bindTransport(transport) {
  let decoder = new TextDecoder();
  transport.onStatus((event) => {
    if (transport !== activeTransport) return;
    if (event.state === 'connecting' || event.state === 'disconnected') decoder = new TextDecoder();
    updateConnectionUi(event);
    logLink('状态', event.message);
  });
  transport.onData((data) => {
    if (transport !== activeTransport) return;
    const text = data instanceof Uint8Array ? decoder.decode(data, { stream: true }) : data;
    if (text) logLink('收到', text);
  });
}
bindTransport(activeTransport);
if (!bleSupported) $("#serial-help").textContent = '当前浏览器不支持 BLE 连接。请用支持 Web Bluetooth 的 Chrome/Edge 打开 HTTPS 或 localhost 页面；曲谱转换仍可使用。';
updateConnectionUi();
$("#connect").addEventListener('click', async () => {
  try {
    await activeTransport.connect({
      serviceUuid: $("#ble-service-uuid").value,
      writeUuid: $("#ble-write-uuid").value,
      notifyUuid: $("#ble-notify-uuid").value,
      namePrefix: $("#ble-name-prefix").value,
    });
  }
  catch (error) { if (error.name !== 'NotFoundError') $("#link-status").textContent = error.message; }
});
$("#disconnect").addEventListener('click', async () => {
  try { await activeTransport.disconnect(); }
  catch (error) { $("#link-status").textContent = `断开失败：${error.message}`; }
});
$("#send-form").addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    const text = $("#send-text").value;
    const sender = activeTransport;
    const size = await activeSession().sendRaw(text, { newline: $("#send-newline").checked });
    if (sender !== activeTransport || !sender.connected) return;
    logLink('发送', text);
    $("#link-status").textContent = `已写入 BLE ${size} 字节；尚未确认板端执行。`;
  } catch (error) { $("#link-status").textContent = error.message; }
});
$("#clear-log").addEventListener('click', () => { logEntries.length = 0; $("#serial-log").textContent = '记录已清空。'; });

function setStatus(message, kind = "info") {
  status.textContent = message;
  status.dataset.kind = kind;
}

function formatDuration(ms) {
  const seconds = Math.round(ms / 1000);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

function loadProject(project, fileName, message, recognitionSource = null) {
  preview.stop();
  $('#source-audio').pause();
  libraryId = null;
  sourceFileName = fileName;
  $('#library-title').value = project.title || fileName;
  state.project = project;
  state.recognitionSource = recognitionSource || (!project.arrangement && project.format === 'audio-transcription' ? project : null);
  $('#arrangement-panel').hidden = !state.recognitionSource;
  $('#arrangement-confirm').checked = false;
  if (state.recognitionSource && !recognitionSource) {
    $('#arrangement-start').value = '0';
    $('#arrangement-end').value = String(audioSelectionEnd(state.recognitionSource));
    $('#arrangement-report').textContent = '选段已覆盖本次识别全长；超过 2048 个旋律音符时请主动缩短选段，不会自动截断。';
  }
  state.selectedTracks = project.tracks.map((_, index) => index).filter((index) => project.tracks[index].notes.length);
  $("#song-title").textContent = project.arrangement ? project.title : project.format === 'audio-transcription' ? `${project.partial ? '前 30 秒' : '全段'}音频识别结果 · 请对比试听` : project.title;
  $("#file-name").textContent = fileName;
  renderTracks();
  compileAndRender();
  setStatus(message, "ok");
}

function currentScore() {
  return { version: 1, id: libraryId || 'export', savedAt: Date.now(),
    title: $('#library-title').value, fileName: sourceFileName, project: state.project,
    settings: { selectedTracks: state.selectedTracks, speed: Number($('#speed').value), velocity: Number($('#velocity').value) } };
}
function libraryMessage(message) { $('#library-status').textContent = message; }
function openScore(score) {
  if (state.transcription) return;
  // A restored score has no source audio blob. Never play a previously loaded
  // recording alongside an unrelated saved transcription.
  $('#source-audio').pause(); $('#source-audio').removeAttribute('src'); $('#source-audio').load();
  $('#source-audio').hidden = true;
  if (audioUrl) { URL.revokeObjectURL(audioUrl); audioUrl = null; }
  state.audioFile = null; audioInput.value = ''; fileInput.value = '';
  $('#transcribe-audio').disabled = true;
  $('#audio-file-name').textContent = '选择音频后可重新转谱';
  $('#audio-progress').textContent = '曲谱存档不包含原始音频；可以直接试听已保存的音符。';
  loadProject(score.project, score.fileName, `已打开「${score.title}」；未发送到设备。`);
  libraryId = score.id;
  $('#library-title').value = score.title;
  state.selectedTracks = [...score.settings.selectedTracks];
  $('#speed').value = String(score.settings.speed);
  $('#velocity').value = String(score.settings.velocity);
  renderTracks(); compileAndRender();
  libraryMessage(`已恢复「${score.title}」的音轨、速度和力度。`);
}
function renderLibrary() {
  const list = $('#library-list'); list.replaceChildren();
  try {
    const query = $('#library-search').value.trim().toLocaleLowerCase();
    const scores = library.list();
    $('#library-count').textContent = `${scores.length} / 20`;
    for (const score of scores.filter(s => (s.title + ' ' + s.fileName).toLocaleLowerCase().includes(query))) {
      const row = document.createElement('li'); row.className = 'library-row';
      const label = document.createElement('div');
      const title = document.createElement('strong'); title.textContent = score.title;
      const meta = document.createElement('small');
      const stats = analyzeEvents(compileTracks(score.project, score.settings.selectedTracks, { speed: score.settings.speed / 100, velocityScale: score.settings.velocity / 100 }));
      meta.textContent = `${score.project.format === 'audio-transcription' ? '音频转谱' : 'MIDI'} · ${stats.count} 音符 · ${formatDuration(stats.durationMs)} · ${score.settings.speed}% 速度`;
      label.append(title, meta); row.append(label);
      const actions = document.createElement('div'); actions.className = 'library-actions';
      for (const [caption, action] of [
        ['打开', () => openScore(score)],
        ['导出存档', () => download('instrument-score.json', serializeScore(score), 'application/json')],
        ['移除', () => {
          removedScore = library.remove(score.id);
          if (libraryId === score.id) libraryId = null;
          $('#library-undo').hidden = false;
          libraryMessage(`已移除「${score.title}」；本页可撤销，原音频/MIDI 文件未删除。`);
          renderLibrary();
        }],
      ]) {
        const button = document.createElement('button'); button.className = 'button small'; button.textContent = caption;
        button.disabled = Boolean(state.transcription);
        button.setAttribute('aria-label', `${caption}：${score.title}`);
        button.onclick = () => { try { action(); } catch (e) { libraryMessage(e.message); } };
        actions.append(button);
      }
      row.append(actions); list.append(row);
    }
    if (!list.children.length) {
      const empty = document.createElement('li'); empty.className = 'hint';
      empty.textContent = query ? '没有匹配的曲谱。' : '导入或转谱后，点击“保存到曲谱库”。'; list.append(empty);
    }
  } catch (error) { libraryMessage(error.message); }
}
$('#library-search').addEventListener('input', renderLibrary);
$('#library-save').onclick = () => {
  try {
    const score = library.save(currentScore(), libraryId); libraryId = score.id;
    renderLibrary(); libraryMessage(`已保存「${score.title}」；刷新后可重新打开。建议导出存档备份。`);
  } catch (error) { libraryMessage(error.message); }
};
$('#export-score').onclick = () => {
  try { download('instrument-score.json', serializeScore(currentScore()), 'application/json'); }
  catch (error) { libraryMessage(error.message); }
};
$('#library-undo').onclick = () => {
  try {
    library.restore(removedScore); removedScore = null; $('#library-undo').hidden = true;
    renderLibrary(); libraryMessage('已恢复移除的曲谱。');
  } catch (error) { libraryMessage(error.message); }
};
$('#import-score').addEventListener('change', async (event) => {
  const file = event.target.files?.[0];
  if (!file || state.transcription) return;
  try {
    if (file.size > 6 * 1024 * 1024) throw new Error('曲谱存档超过 6 MB，请选择本站导出的 JSON 存档');
    const source = parseScore(await file.text());
    if (state.transcription) throw new Error('正在转谱，请完成后再导入存档');
    const score = library.save(source); openScore(score); renderLibrary();
    libraryMessage(`已导入并保存「${score.title}」。`);
  } catch (error) { libraryMessage(`导入失败：${error.message}`); }
  finally { event.target.value = ''; }
});
window.addEventListener('storage', (event) => { if (event.key === LIBRARY_KEY || event.key === null) renderLibrary(); });

function download(name, content, type = "text/plain;charset=utf-8") {
  if (window.top.mineradioNative) {
    const bytes = new TextEncoder().encode(content);
    let binary = '';
    for (const byte of bytes) binary += String.fromCharCode(byte);
    window.top.mineradioNative.request('save-file', { name, mime: type.split(';')[0], data: btoa(binary) })
      .then(() => setStatus('已保存文件'))
      .catch(error => setStatus(error.message, 'error'));
    return;
  }
  const link = document.createElement("a");
  link.href = URL.createObjectURL(new Blob([content], { type }));
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 1000);
}

function renderTracks() {
  trackList.replaceChildren();
  state.project.tracks.forEach((track, index) => {
    const label = document.createElement("label");
    label.className = "track-row";
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.checked = state.selectedTracks.includes(index);
    checkbox.addEventListener("change", () => {
      state.selectedTracks = [...trackList.querySelectorAll("input:checked")].map((input) => Number(input.value));
      compileAndRender();
    });
    checkbox.value = String(index);
    const notes = track.notes.length ? `${track.notes.length} 音符 · ${formatDuration(track.notes.reduce((max, note) => Math.max(max, note.endMs), 0))}` : "无音符";
    label.append(checkbox, document.createTextNode(`轨道 ${index + 1}${track.title ? ` · ${track.title}` : ""}`));
    const meta = document.createElement("small");
    meta.textContent = notes;
    label.append(meta);
    trackList.append(label);
  });
}

function renderDiagnostics(events) {
  const info = analyzeEvents(events);
  $("#note-count").textContent = info.count.toLocaleString();
  $("#duration").textContent = formatDuration(info.durationMs);
  $("#polyphony").textContent = `${info.maxPolyphony} / 32`;
  diagnostics.replaceChildren();
  if (info.over32) {
    const warning = document.createElement("p");
    warning.className = "warning";
    warning.textContent = `峰值同时发声 ${info.maxPolyphony}，超过当前 FPGA 的 32 声部预算；导出仍保留全部音符，上传前必须选择简化策略。`;
    diagnostics.append(warning);
  }
  const warnings = state.project?.tracks.flatMap((track) => track.warnings || []) || [];
  if (warnings.length) {
    const warning = document.createElement("p");
    warning.className = "warning";
    warning.textContent = `曲谱有 ${warnings.length} 条提示：${warnings.slice(0, 2).join("；")}`;
    diagnostics.append(warning);
  }
}

function drawRoll(events) {
  const context = roll.getContext("2d");
  const palette = getComputedStyle(document.documentElement);
  const color = name => palette.getPropertyValue(`--${name}`).trim();
  roll.width = roll.clientWidth * devicePixelRatio;
  roll.height = roll.clientHeight * devicePixelRatio;
  context.scale(devicePixelRatio, devicePixelRatio);
  const viewWidth = roll.clientWidth;
  const viewHeight = roll.clientHeight;
  $('#roll-empty').hidden = events.length > 0;
  context.fillStyle = color('roll-bg');
  context.fillRect(0, 0, viewWidth, viewHeight);
  const minNote = events.length ? Math.max(0, events.reduce((min, event) => Math.min(min, event.note), 127) - 2) : 60;
  const maxNote = events.length ? Math.min(127, events.reduce((max, event) => Math.max(max, event.note), 0) + 2) : 72;
  const duration = Math.max(1000, analyzeEvents(events).durationMs);
  const gutter = 38, top = 24, plotWidth = viewWidth - gutter;
  const rowHeight = (viewHeight - top) / (maxNote - minNote + 1);
  context.font = '10px Consolas, monospace';
  for (let note = minNote; note <= maxNote; note += 1) {
    const y = top + (maxNote - note) * rowHeight;
    const black = [1, 3, 6, 8, 10].includes(note % 12);
    context.fillStyle = color(black ? 'roll-row' : 'roll-bg');
    context.fillRect(gutter, y, plotWidth, rowHeight);
    context.fillStyle = color(black ? 'roll-key' : 'paper');
    context.fillRect(0, y, gutter - 1, rowHeight - 0.5);
    if (rowHeight >= 13 || note % 12 === 0) {
      context.fillStyle = color('text'); context.fillText(midiNoteName(note), 5, y + rowHeight / 2 + 3);
    }
  }
  for (let i = 0; i <= 4; i++) {
    const x = gutter + plotWidth * i / 4;
    context.fillStyle = color('line'); context.fillRect(Math.floor(x), top, 0.7, viewHeight - top);
    if (i < 4 && events.length) { context.fillStyle = color('muted'); context.fillText(`${(duration * i / 4000).toFixed(1)}s`, x + 5, 15); }
  }
  for (const event of events) {
    const x = gutter + (event.startMs / duration) * plotWidth;
    const widthPx = Math.max(2, (event.durationMs / duration) * plotWidth);
    const y = top + (maxNote - event.note) * rowHeight;
    context.fillStyle = color('roll-note');
    context.fillRect(x, y + 1, widthPx, Math.max(1, rowHeight - 2));
  }
}

function compileAndRender() {
  preview.stop();
  const speed = Number($("#speed").value) / 100;
  const velocityScale = Number($("#velocity").value) / 100;
  state.events = state.project ? compileTracks(state.project, state.selectedTracks, { speed, velocityScale }) : [];
  $("#speed-value").textContent = `${Math.round(speed * 100)}%`;
  $("#velocity-value").textContent = `${Math.round(velocityScale * 100)}%`;
  renderDiagnostics(state.events);
  drawRoll(state.events);
  for (const id of ['#preview-notes', '#export-csv', '#export-jsonl', '#export-protocol']) $(id).disabled = !state.events.length;
  for (const id of ['#library-save', '#export-score']) $(id).disabled = !state.project || !state.events.length || Boolean(state.transcription);
  for (const id of ['#import-score', '#choose-score', '#library-undo', '#library-title']) $(id).disabled = Boolean(state.transcription);
  renderLibrary();
  refreshUploadScore();
}

fileInput.addEventListener("change", async () => {
  const file = fileInput.files?.[0];
  if (!file) return;
  try {
    loadProject(parseMidi(await file.arrayBuffer()), file.name, `已解析 ${file.name}，请选择要演奏的音轨。`);
  } catch (error) {
    state.project = null; state.events = [];
    trackList.replaceChildren(); compileAndRender(); setStatus(error.message, "error");
  }
});

audioInput.addEventListener("change", () => {
  const file = audioInput.files?.[0];
  if (!file) return;
  preview.stop();
  state.audioFile = file;
  $("#audio-file-name").textContent = `${file.name} · ${(file.size / 1024 / 1024).toFixed(1)} MB`;
  $("#audio-progress").textContent = "可先播放原音频，再点击开始转谱。";
  $("#transcribe-audio").disabled = false;
  const source = $("#source-audio");
  source.pause();
  if (audioUrl) URL.revokeObjectURL(audioUrl);
  audioUrl = URL.createObjectURL(file);
  source.src = audioUrl;
  source.hidden = false;
});

// Mineradio supplies the exact local/current playback bytes. Same-origin and
// parent checks prevent another page from replacing the user's selected source.
window.addEventListener('message', async event => {
  if (event.origin !== location.origin || event.source !== window.parent || event.data?.type !== 'mineradio-audio') return;
  const reply = (ok, message) => event.source.postMessage({ type: 'mineradio-audio-result', requestId: event.data.requestId, ok, message }, event.origin);
  try {
    if (state.transcription) throw new Error('请先取消或等待当前转谱完成，再导入另一首歌');
    const file = event.data.file;
    if (!(file instanceof File) || !file.size || file.size > 80 * 1024 * 1024) throw new Error('音频文件无效或超过 80 MB');
    const transfer = new DataTransfer(); transfer.items.add(file); audioInput.files = transfer.files;
    audioInput.dispatchEvent(new Event('change'));
    $('#tab-audio').click();
    setStatus(`已接收 Mineradio 音频：${file.name}，点击开始转谱。`, 'ok');
    reply(true, '已导入。请转谱、试听确认，再上传 FPGA。');
  } catch (error) { setStatus(error.message, 'error'); reply(false, error.message); }
});
$('#arrangement-rhythm').onchange = () => {
  for (const id of ['#arrangement-bpm', '#arrangement-beat-offset']) $(id).disabled = $('#arrangement-rhythm').value === 'original';
};
$('#arrangement-apply').onclick = () => {
  try {
    if (state.transcription) throw new Error('请等待当前转谱完成后再整理旋律');
    const result = arrangeAudioMelody(state.recognitionSource, {
      startSeconds: Number($('#arrangement-start').value), endSeconds: Number($('#arrangement-end').value),
      confirmed: $('#arrangement-confirm').checked,
      strategy: $('#arrangement-strategy').value, minDurationMs: Number($('#arrangement-min-duration').value),
      onsetWindowMs: Number($('#arrangement-onset-window').value), rhythm: $('#arrangement-rhythm').value,
      bpm: Number($('#arrangement-bpm').value),
      beatOffsetMs: Number($('#arrangement-beat-offset').value),
      repeatMode: $('#arrangement-repeat').value, pitchMode: $('#arrangement-pitch').value,
      minPitch: Number($('#arrangement-min-pitch').value), maxPitch: Number($('#arrangement-max-pitch').value),
      protectSustain: $('#arrangement-protect-sustain').checked,
    });
    loadProject(result.project, sourceFileName, '已生成可上传旋律；请再次试听后上传。原识别结果仍可重新整理。', state.recognitionSource);
    const r = result.report;
    const pitchReport = `整段移调 ${r.octaveShift / 12} 个八度，仍需逐音折回 ${r.residualFolds} 音`;
    $('#arrangement-report').textContent = `${r.startSeconds}–${r.endSeconds} 秒：${r.selectedNotes} → ${r.melodyNotes}/2048 音符；近同时起音择一 ${r.removedSimultaneous}，音域排除 ${r.outsideRange}，过滤碎音 ${r.filtered}，抑制弱插音 ${r.suppressed}，长音保护排除低音 ${r.sustainedBass}，合并重叠同音 ${r.merged}，网格合并/边界去除 ${r.gridCollisions}，${pitchReport}，缩短重叠 ${r.shortened}。${r.rhythm === 'original' ? '保留原始节奏' : `按 ${r.bpm} BPM、拍点偏移 ${r.beatOffsetMs} ms 对齐十六分音符`}。这是旋律重奏，不是 MP3 原声播放。`;
  } catch (error) { setStatus(error.message, 'error'); }
};

$("#transcribe-audio").addEventListener("click", async () => {
  if (!state.audioFile || state.transcription) return;
  state.transcription = new AbortController();
  const file = state.audioFile;
  preview.stop(); $("#source-audio").pause();
  state.project = null; state.recognitionSource = null; state.selectedTracks = [];
  $('#arrangement-panel').hidden = true;
  $('#arrangement-confirm').checked = false;
  trackList.replaceChildren(); compileAndRender();
  $("#file-name").textContent = '正在转谱'; $("#song-title").textContent = file.name;
  for (const id of ['#audio-file', '#midi-file', '#choose-audio', '#choose-midi', '#tab-audio', '#tab-midi', '#audio-scope', '#audio-threshold', '#audio-min-note']) $(id).disabled = true;
  $('#transcription-progress').hidden = false;
  $('#transcription-progress').value = 0;
  $("#transcribe-audio").disabled = true;
  $("#cancel-transcription").disabled = false;
  try {
    const project = await transcribeAudioFile(file, {
      signal: state.transcription.signal,
      durationLimit: Number($('#audio-scope').value),
      threshold: Number($('#audio-threshold').value),
      minNoteMs: Number($('#audio-min-note').value),
      onProgress: ({ stage, percent }) => { $("#audio-progress").textContent = `${{ decode: '解码音频', load: '加载本地转谱模型', model: '识别音符' }[stage]}：${Math.round(percent * 100)}%`; $('#transcription-progress').value = percent * 100; },
    });
    loadProject(project, file.name, project.tracks[0].notes.length ? '转谱完成，请对比原音频和音符试听；浏览器音色不代表 FPGA 实际音色。' : '未识别到音符，可降低识别门槛或更换旋律清晰的音频。');
    $("#audio-progress").textContent = `${project.partial ? '前 30 秒' : '全段'}识别完成：${project.tracks[0].notes.length} 个音符。`;
  } catch (error) {
    setStatus(error.name === "AbortError" ? "已取消音频转谱。" : `音频转谱失败：${error.message}`, error.name === "AbortError" ? "info" : "error");
    $("#audio-progress").textContent = error.name === "AbortError" ? "已取消。" : error.message;
    $('#file-name').textContent = '尚无转谱结果';
    $('#song-title').textContent = '调整设置后，可以重新开始。';
  } finally {
    state.transcription = null;
    compileAndRender();
    for (const id of ['#audio-file', '#midi-file', '#choose-audio', '#choose-midi', '#tab-audio', '#tab-midi', '#audio-scope', '#audio-threshold', '#audio-min-note']) $(id).disabled = false;
    $('#transcription-progress').hidden = true;
    $("#transcribe-audio").disabled = !state.audioFile;
    $("#cancel-transcription").disabled = true;
  }
});
$("#cancel-transcription").addEventListener("click", () => state.transcription?.abort());

async function playPreview(upload = false) {
  preview.stop();
  $('#source-audio').pause();
  if (upload && !compiledUpload) return;
  const events = upload ? scorePreviewEvents(compiledUpload) : state.events;
  if (analyzeEvents(events).over32) { setStatus('超过 32 声部，请简化曲谱后试听。', 'error'); return; }
  $('#preview-notes').disabled = true; $('#preview-upload').disabled = true; $('#stop-preview').disabled = false;
  const done = () => { $('#preview-notes').disabled = !state.events.length; $('#preview-upload').disabled = !compiledUpload || Boolean(state.transcription); $('#stop-preview').disabled = true; };
  $('#preview-description').textContent = upload ? '正在试听待上传曲谱：使用实际上传的音高、力度与量化节奏。板卡音色可能不同；板端速度请设为 100%。' : '正在试听当前音符，用于对比识别结果；不代表设备已接受曲谱。';
  try { await preview.play(events, done); }
  catch (error) { done(); setStatus(error.message, 'error'); }
}
$('#preview-notes').addEventListener('click', () => playPreview());
$('#preview-upload').addEventListener('click', () => playPreview(true));
$('#stop-preview').addEventListener('click', () => preview.stop());
$('#source-audio').addEventListener('play', () => preview.stop());

$("#select-all").addEventListener("click", () => { trackList.querySelectorAll("input").forEach((input) => { input.checked = true; }); state.selectedTracks = state.project?.tracks.map((_, index) => index) || []; compileAndRender(); });
$("#clear-all").addEventListener("click", () => { trackList.querySelectorAll("input").forEach((input) => { input.checked = false; }); state.selectedTracks = []; compileAndRender(); });
$("#speed").addEventListener("input", compileAndRender);
$("#velocity").addEventListener("input", compileAndRender);
$("#export-csv").addEventListener("click", () => state.events.length && download("fpga-song-events.csv", serializeCsv(state.events), "text/csv;charset=utf-8"));
$("#export-jsonl").addEventListener("click", () => state.events.length && download("fpga-song-events.jsonl", serializeJsonl(state.events, { title: state.project?.title || "song", count: state.events.length }), "application/x-ndjson;charset=utf-8"));
$("#export-protocol").addEventListener("click", () => state.events.length && download("fpga-song-upload-preview.txt", encodePreviewFrames(state.events).join("")));

compileAndRender();
setStatus("未加载曲谱。导出文件不会自动发送到设备。", "info");
window.addEventListener('resize', () => drawRoll(state.events));
window.parent.postMessage({ type: 'instrument-ready' }, location.origin);
