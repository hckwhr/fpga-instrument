import { prepareScoreUpload } from './score-upload-protocol.js';
import { midiNoteName } from './midi.js';
import { createBoardAudioView } from './board-audio-view.js';

// SONG2 reports a zero-based last melody onset, not an audio sample clock or
// held-key mask. Never interpolate position or infer that a note is still audible.
export function boardPlaybackView(playback, identity, receivedAt, now = Date.now()) {
  const fresh = Boolean(receivedAt && now - receivedAt >= 0 && now - receivedAt < 5000);
  const matched = Boolean(playback && identity && playback.length === identity.length && playback.crc === identity.crc);
  const position = matched && fresh && playback.state === 2 && Number.isInteger(playback.noteIndex) &&
    playback.noteIndex >= 0 && playback.noteIndex < identity.notes.length ? playback.noteIndex : -1;
  return { fresh, matched, position };
}

export function createBoardMonitor(device, upload) {
  const section = document.createElement('section');
  section.id = 'board-visuals'; section.className = 'performance-visuals board-visuals';
  section.setAttribute('aria-labelledby', 'board-visuals-heading');
  section.innerHTML = `<div class="section-heading"><h2 id="board-visuals-heading">FPGA 联动可视化</h2><span class="monitor-origin">真实音频采样 / 板端状态</span></div>
    <p class="hint">显示上传曲谱在 FPGA 上的最近旋律起音位置。进度与键盘只随设备应答更新，不按电脑时间推演；不代表音符仍在发声。</p>
    <div class="connection-controls"><button type="button" id="board-monitor-refresh" class="button">刷新板端状态</button><label class="checkbox"><input type="checkbox" id="board-monitor-auto">自动跟随 · 每 1.5 秒查询</label></div>
    <p id="board-monitor-state" class="hint" role="status">未连接 · 等待板端应答</p>
    <dl class="board-info"><dt>最近应答</dt><dd id="board-monitor-time">尚无</dd><dt>曲谱核对</dt><dd id="board-monitor-identity">请先导入曲谱并检查上传能力</dd></dl>
    <div class="preview-keyboard"><div class="keyboard-caption"><span>板端最近旋律位置 · C3—B5</span><span id="board-monitor-note">—</span></div><div class="keyboard-keys" aria-label="FPGA 最近应答的旋律位置键盘"></div></div>
    <div id="board-score-map" class="board-score-map" aria-label="曲谱旋律位置图"></div>
    <p class="hint board-telemetry-note">当前固件未回传音频采样、FFT 或实体按键状态；板端实测波形、李萨如与频谱需要新增采集协议。上方「电脑可视化」来自本机试听音频。</p>`;
  document.querySelector('footer').before(section);
  createBoardAudioView(section, device, upload);
  const $ = selector => section.querySelector(selector);
  const keys = new Map(); let white = 0;
  for (let note = 48; note <= 83; note++) {
    const black = [1, 3, 6, 8, 10].includes(note % 12);
    const key = document.createElement('span'); key.className = `piano-key ${black ? 'black' : 'white'}`;
    key.style.setProperty('--key-position', black ? white - .32 : white++);
    key.textContent = note % 12 === 0 ? midiNoteName(note) : '';
    $('.keyboard-keys').append(key); keys.set(note, key);
  }
  $('.keyboard-keys').style.setProperty('--white-keys', white);
  let identity = null, visible = true, polling = false, disposed = false;
  const available = () => {
    const d = device.snapshot(), u = upload.snapshot();
    return d.connected && !d.busy && !d.blocked && !u.busy && Boolean(u.capability?.playback);
  };
  function render() {
    const d = device.snapshot(), u = upload.snapshot(), p = u.playback;
    const view = boardPlaybackView(d.connected && !d.blocked ? p : null, identity, u.playbackUpdatedAt);
    $('#board-monitor-refresh').disabled = !available();
    $('#board-monitor-auto').disabled = !d.connected || d.blocked || !u.capability?.playback;
    if (!d.connected || d.blocked) $('#board-monitor-auto').checked = false;
    $('#board-monitor-state').textContent = !d.connected ? '连接已断开 · 板端可能仍在演奏，当前位置未知' :
      d.blocked ? '通信状态未知 · 请断开重连后确认' : !p ? u.message :
        `${['空闲', '准备播放', '播放中', '已结束', '调度故障'][p.state]} · ${view.fresh ? '最近板端应答' : '应答已过期，请刷新'}`;
    $('#board-monitor-time').textContent = p && u.playbackUpdatedAt ? new Date(u.playbackUpdatedAt).toLocaleTimeString() : '尚无有效状态应答';
    $('#board-monitor-identity').textContent = !p ? '等待设备报告曲谱校验码' : view.matched ?
      `与当前曲谱一致 · CRC ${p.crc} · ${p.length} 事件字` : `与当前页面不匹配或尚未播放 · 板端 CRC ${p.crc}；不标记音符`;
    const note = view.position >= 0 ? identity.notes[view.position] : null;
    for (const [pitch, key] of keys) key.classList.toggle('active', note?.note === pitch);
    $('#board-monitor-note').textContent = note ? `${view.position + 1} / ${identity.notes.length} · ${midiNoteName(note.note)}` : '—';
    for (const [i, marker] of [...$('#board-score-map').children].entries()) marker.classList.toggle('current', i === view.position);
    section.dataset.position = String(view.position);
    section.dataset.matched = String(view.matched);
    section.dataset.fresh = String(view.fresh);
  }
  async function refresh() {
    if (polling || !available()) return;
    polling = true;
    try { await upload.control('STATUS'); }
    catch { /* Session owns the error and invalidates uncertain state. */ }
    finally { polling = false; render(); }
  }
  $('#board-monitor-refresh').onclick = refresh;
  $('#board-monitor-auto').onchange = () => { if ($('#board-monitor-auto').checked) void refresh(); };
  const tick = setInterval(() => {
    if (!visible || document.hidden) return;
    render();
    if ($('#board-monitor-auto').checked) void refresh();
  }, 1500);
  const unsubs = [device.onChange(render), upload.onChange(render)];
  window.addEventListener('instrument-visibility', event => { visible = Boolean(event.detail); if (visible) render(); });
  window.addEventListener('pagehide', () => { disposed = true; clearInterval(tick); unsubs.forEach(fn => fn()); }, { once: true });
  render();
  return { setScore(score) {
    if (disposed) return;
    identity = score ? { ...prepareScoreUpload(score, { abi: 13, words: 4096, chunkWords: 8 }),
      notes: score.events.filter(e => e.on && e.melody) } : null;
    $('#board-score-map').replaceChildren();
    for (const [i, note] of (identity?.notes || []).entries()) {
      const marker = document.createElement('span');
      marker.style.setProperty('--pitch-height', `${20 + (note.note - 48) * 2}px`);
      marker.title = `${i + 1} · ${midiNoteName(note.note)} · ${(note.tick * .00625).toFixed(2)} s`;
      $('#board-score-map').append(marker);
    }
    render();
  } };
}
