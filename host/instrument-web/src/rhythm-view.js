import { buildRhythmChart, demoRhythmEvents, KEY_CODES, RhythmGame } from './rhythm-engine.js';
import { createRhythmAudio } from './rhythm-audio.js';
import { compileTracks, midiNoteName } from './midi.js';

export function createRhythmView({ currentScore, library, stopPreview }) {
  const css = document.createElement('link'); css.rel = 'stylesheet'; css.href = new URL('./rhythm.css', import.meta.url).href; document.head.append(css);
  const root = document.createElement('section'); root.id = 'rhythm-root'; root.hidden = true;
  root.setAttribute('aria-label', '节奏大师');
  root.innerHTML = `
    <header class="rhythm-heading"><div><p class="rhythm-eyebrow">PLAY THE MOMENT</p><h1>节奏大师<span>让每一个音，由你奏响。</span></h1></div><span class="rhythm-local">● 本机练习 · 键盘 / 触屏</span></header>
    <div class="rhythm-layout">
      <main class="rhythm-stage">
        <div class="rhythm-scorebar"><div><span>得分</span><strong id="rhythm-points">00000</strong></div><div><span>连击</span><strong id="rhythm-combo">0</strong></div><div><span>完成分</span><strong id="rhythm-accuracy">0%</strong></div><div class="rhythm-timer"><span id="rhythm-song-name">小星星</span><strong id="rhythm-time">0:00 / 0:00</strong></div></div>
        <div class="rhythm-actions"><button type="button" id="rhythm-start" class="button primary">开始练习</button><button type="button" id="rhythm-pause" class="button" disabled>暂停</button><button type="button" id="rhythm-reset" class="button plain">重来</button></div>
        <div class="rhythm-roll"><canvas id="rhythm-canvas" aria-label="下落音符：到达底部判定线时按下对应键"></canvas><div class="rhythm-callout"><strong id="rhythm-judgement">准备好了吗</strong><span id="rhythm-prompt">按开始，等待音符到达判定线</span></div><span class="rhythm-line-label">判定线</span></div>
        <div id="rhythm-keys" class="rhythm-keys" aria-label="演奏键盘"></div>
        <div class="rhythm-legend"><span><i class="upcoming"></i>即将到达</span><span><i class="due"></i>等待按下</span><span><i class="accepted"></i>命中</span><span><i class="missed"></i>漏音</span></div>
        <progress id="rhythm-progress" max="1" value="0" aria-label="练习进度"></progress>
        <div id="rhythm-result" class="rhythm-result" hidden role="status"></div>
      </main>
      <aside class="rhythm-settings" aria-label="练习设置">
        <p class="rhythm-eyebrow">YOUR SESSION</p><h2>今天，练哪一首？</h2>
        <label>练习曲谱<select id="rhythm-source"><option value="twinkle">小星星 · 入门</option><option value="ode">欢乐颂 · 入门</option><option value="current">FPGA 工作台当前曲谱</option></select></label>
        <p id="rhythm-chart-info" class="rhythm-note"></p>
        <button type="button" id="rhythm-import" class="button plain">导入 / 整理自己的曲谱 ↗</button>
        <fieldset class="rhythm-choice"><legend>练习方式</legend><label><input type="radio" name="rhythm-mode" value="practice" checked><span>跟练<small>等你按对，再继续</small></span></label><label><input type="radio" name="rhythm-mode" value="challenge"><span>挑战<small>按节拍前进，记录漏音</small></span></label></fieldset>
        <label>速度 <output id="rhythm-speed-label">100%</output><input id="rhythm-speed" type="range" min="50" max="150" step="5" value="100"></label>
        <p class="rhythm-note">更换曲谱、练习方式或速度会重新开始。竖屏琴键分两排，按音名与亮灯提示演奏。</p>
        <p id="rhythm-status" class="rhythm-note" role="status">命中才发声，未按或按错保持静音。</p>
        <div class="rhythm-counts"><span>Perfect <b id="rhythm-perfect">0</b></span><span>Good <b id="rhythm-good">0</b></span><span>Miss <b id="rhythm-miss">0</b></span><span>错按 <b id="rhythm-wrong">0</b></span></div>
        <details class="rhythm-help"><summary>怎么玩 / 硬件联动</summary><p>电脑用 A S D F G H J K L ; ' Enter，手机直接触摸下方琴键。可同时按下多个键；同音重奏需要先松开。当前按起音计分，长音提前松开会停止声音，但不扣保持分。</p><p>挑战判定：Perfect ±70 ms，Good ±160 ms。跟练仅记录命中，不评价快慢。完成分以整曲音符总数计算。</p><p>本轮是上位机练习版，声音来自电脑或手机。琴键颜色是屏幕提示，尚未控制实体 RGB，也不读取压力键。实物联动需要配套 FPGA/ESP 固件扩展。</p><p>键位按本曲音高由低到高分配，不会改写板端键位。先在 FPGA 播放中停止板端曲目，再开始练习；本模式不会发送播放指令。</p></details>
      </aside>
    </div>`;
  document.body.append(root);
  const $ = selector => root.querySelector(selector);
  const sound = createRhythmAudio();
  const canvas = $('#rhythm-canvas'), context = canvas.getContext('2d');
  let game, visible = false, animation, lastFeedback = 0, loading = false, generation = 0;
  const activeInputs = new Map();
  let savedScores = [], title = '';
  const message = text => { $('#rhythm-status').textContent = text; };
  function releaseAll() { activeInputs.clear(); game?.held.clear(); sound.silence(); }
  function loadSources() {
    const value = $('#rhythm-source').value;
    for (const option of $('#rhythm-source').querySelectorAll('[data-saved]')) option.remove();
    try {
      savedScores = library.list();
      for (const score of savedScores) {
        const option = document.createElement('option'); option.value = `saved:${score.id}`;
        option.dataset.saved = 'true'; option.textContent = `曲谱库 · ${score.title}`; $('#rhythm-source').append(option);
      }
      if ([...$('#rhythm-source').options].some(o => o.value === value)) $('#rhythm-source').value = value;
    } catch (error) { message(error.message); }
  }
  function reset() {
    generation++; loading = false; releaseAll(); game = null;
    $('#rhythm-result').hidden = true; $('#rhythm-start').disabled = true; $('#rhythm-pause').disabled = true;
    $('#rhythm-start').textContent = '开始练习'; $('#rhythm-keys').replaceChildren();
    for (const id of ['points', 'combo', 'perfect', 'good', 'miss', 'wrong']) $(`#rhythm-${id}`).textContent = '0';
    $('#rhythm-accuracy').textContent = '0%'; $('#rhythm-time').textContent = '0:00 / 0:00'; $('#rhythm-progress').value = 0;
    try {
      const source = $('#rhythm-source').value;
      let events;
      if (source === 'current') {
        const current = currentScore(); title = current.title || '当前曲谱'; events = current.events;
      } else if (source.startsWith('saved:')) {
        const score = savedScores.find(s => `saved:${s.id}` === source);
        if (!score) throw Error('该曲谱已被移除，请重新选择');
        title = score.title; events = compileTracks(score.project, score.settings.selectedTracks,
          { speed: score.settings.speed / 100, velocityScale: score.settings.velocity / 100 });
      } else { title = source === 'ode' ? '欢乐颂' : '小星星'; events = demoRhythmEvents(source); }
      const chart = buildRhythmChart(events);
      game = new RhythmGame(chart, { mode: $('input[name="rhythm-mode"]:checked').value, speed: +$('#rhythm-speed').value / 100 });
      $('#rhythm-song-name').textContent = title;
      $('#rhythm-chart-info').textContent = `${chart.notes.length} 个起音 · ${chart.pitches.length} 个音高 · 按音高升序分配${chart.merged ? ` · ${chart.merged} 个同刻同音合并` : ''}`;
      const labels = ['A','S','D','F','G','H','J','K','L',';','\'','↵'];
      for (let lane = 0; lane < 12; lane++) {
        const key = document.createElement('button'); key.type = 'button'; key.dataset.lane = lane;
        key.disabled = lane >= chart.pitches.length;
        key.innerHTML = `<span class="rhythm-led"></span><strong>${key.disabled ? '—' : midiNoteName(chart.pitches[lane])}</strong><kbd>${labels[lane]}</kbd>`;
        key.setAttribute('aria-label', key.disabled ? '未分配音高' : `${midiNoteName(chart.pitches[lane])}，快捷键 ${labels[lane]}`);
        $('#rhythm-keys').append(key);
      }
      $('#rhythm-start').disabled = false;
      $('#rhythm-judgement').textContent = '准备好了吗'; $('#rhythm-prompt').textContent = '按开始，等待音符到达判定线';
      message('命中才发声。此模式使用本机音频，不控制 FPGA 自动播放。');
    } catch (error) {
      $('#rhythm-chart-info').textContent = '曲谱暂不可练习'; $('#rhythm-judgement').textContent = '换一份练习曲谱';
      $('#rhythm-prompt').textContent = '可先选小星星，或选择单独旋律音轨'; message(error.message);
    }
    render();
  }
  async function start() {
    if (!game || loading || game.status === 'running') return;
    if (game.status === 'finished') reset();
    const token = ++generation; loading = true; $('#rhythm-start').disabled = true;
    try {
      stopPreview(); await sound.unlock();
      if (token !== generation || !visible || document.hidden) return;
      game.start(performance.now()); message(game.mode === 'practice' ? '跟练中：黄色键等待你按下；和弦需逐个或同时按齐。' : '挑战中：音符到达判定线时按下对应键。');
      canvas.focus({ preventScroll: true });
    } catch (error) { message(`音频未启动：${error.message}`); }
    finally { if (token === generation) { loading = false; render(); } }
  }
  function pause() {
    generation++; loading = false;
    game?.pause(performance.now()); releaseAll(); render();
  }
  function press(lane, input) {
    if (activeInputs.has(input) || game?.status !== 'running') return;
    // Multiple pointers/keyboard inputs holding the same lane count as one press.
    const occupied = [...activeInputs.values()].includes(lane); activeInputs.set(input, lane);
    if (occupied) return;
    const hit = game.press(lane, performance.now());
    if (!hit) return;
    if (hit.note) sound.hit(hit.note, game.speed);
    $('#rhythm-judgement').textContent = ({ wrong: '再找准一点', hit: '命中', perfect: 'Perfect', good: 'Good' })[hit.judgement];
    $('#rhythm-prompt').textContent = hit.note ? `${midiNoteName(hit.note.note)}${game.mode === 'challenge' ? ` · ${Math.round(hit.errorMs)} ms` : ''}` : '按下亮起的对应键，松开后再试';
    lastFeedback = performance.now(); render();
  }
  function release(input) {
    const lane = activeInputs.get(input); activeInputs.delete(input);
    if (lane !== undefined && ![...activeInputs.values()].includes(lane)) { game?.release(lane); sound.release(lane); }
  }
  canvas.tabIndex = 0;
  root.addEventListener('keydown', event => {
    if (event.target.closest('select,input,summary') || (event.target.closest('button') && !event.target.closest('#rhythm-keys'))) return;
    const lane = KEY_CODES.indexOf(event.code); if (lane < 0) return;
    event.preventDefault(); if (!event.repeat) press(lane, event.code);
  });
  window.addEventListener('keyup', event => { if (activeInputs.has(event.code)) { event.preventDefault(); release(event.code); } });
  $('#rhythm-keys').addEventListener('pointerdown', event => {
    const key = event.target.closest('button'); if (!key || key.disabled) return;
    event.preventDefault(); key.setPointerCapture(event.pointerId); canvas.focus({ preventScroll: true }); press(+key.dataset.lane, event.pointerId);
  });
  for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) $('#rhythm-keys').addEventListener(type, event => release(event.pointerId));
  // Assistive technology activates buttons without pointerdown/keydown.
  $('#rhythm-keys').addEventListener('click', event => {
    const key = event.target.closest('button'); if (!key || event.detail !== 0) return;
    const input = `assistive:${key.dataset.lane}`; press(+key.dataset.lane, input); release(input);
  });
  $('#rhythm-start').onclick = start; $('#rhythm-pause').onclick = pause; $('#rhythm-reset').onclick = reset;
  $('#rhythm-source').onchange = reset;
  for (const radio of root.querySelectorAll('[name="rhythm-mode"]')) radio.onchange = reset;
  $('#rhythm-speed').oninput = () => { $('#rhythm-speed-label').textContent = `${$('#rhythm-speed').value}%`; reset(); };
  $('#rhythm-import').onclick = () => {
    if (window.parent !== window) window.parent.postMessage({ type: 'instrument-open-workbench' }, location.origin);
    else setVisible(false);
  };
  const formatTime = ms => `${Math.floor(Math.max(0, ms) / 60000)}:${String(Math.floor(Math.max(0, ms) / 1000) % 60).padStart(2, '0')}`;
  function render() {
    if (game) {
      $('#rhythm-points').textContent = String(game.points).padStart(5, '0'); $('#rhythm-combo').textContent = game.combo;
      $('#rhythm-accuracy').textContent = `${Math.round(game.accuracy)}%`;
      $('#rhythm-time').textContent = `${formatTime(game.time / game.speed)} / ${formatTime(game.chart.durationMs / game.speed)}`;
      $('#rhythm-progress').value = Math.max(0, Math.min(1, game.time / game.chart.durationMs));
      for (const name of ['perfect', 'good', 'miss', 'wrong']) $(`#rhythm-${name}`).textContent = game.counts[name];
      $('#rhythm-start').disabled = loading || game.status === 'running'; $('#rhythm-pause').disabled = game.status !== 'running';
      $('#rhythm-start').textContent = game.status === 'paused' ? '继续练习' : game.status === 'finished' ? '再来一次' : '开始练习';
      const next = game.next();
      for (const key of $('#rhythm-keys').children) {
        const lane = +key.dataset.lane;
        key.classList.toggle('pressed', game.held.has(lane));
        key.classList.toggle('due', !!next && game.chart.notes.slice(game.cursor, game.cursor + 12).some(n => n.lane === lane && !game.results[n.id] && Math.abs(n.startMs - game.time) / game.speed <= 160));
        key.setAttribute('aria-pressed', String(game.held.has(lane)));
      }
      if (performance.now() - lastFeedback > 650) {
        $('#rhythm-judgement').textContent = game.status === 'running' ? game.time < 0 ? String(Math.ceil(-game.time / game.speed / 1000)) : game.mode === 'practice' && next?.startMs === game.time ? '轮到你了' : '跟上节拍' : game.status === 'paused' ? '已暂停' : game.status === 'finished' ? '练习完成' : '准备好了吗';
        $('#rhythm-prompt').textContent = game.status === 'paused' ? '点击继续，接着练' : game.status === 'ready' ? '按开始，等待音符到达判定线' : game.status === 'finished' ? '每一次练习，都更进一步' : '到线按键 · 命中发声';
      }
      if (game.status === 'finished') {
        $('#rhythm-result').hidden = false;
        $('#rhythm-result').textContent = `${game.mode === 'practice' ? '跟练' : '挑战'}完成 · 命中 ${game.counts.hit + game.counts.perfect + game.counts.good}/${game.chart.notes.length} · 最高连击 ${game.bestCombo} · 错按 ${game.counts.wrong} · ${Math.round(game.accuracy)} 分`;
      }
    }
    draw();
  }
  function draw() {
    const box = canvas.getBoundingClientRect(); if (!box.width || !box.height) return;
    const dpr = Math.min(2, devicePixelRatio || 1), w = box.width, h = box.height;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) { canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr); }
    context.setTransform(dpr, 0, 0, dpr, 0, 0); context.clearRect(0, 0, w, h);
    const laneWidth = w / 12, line = h - 30;
    for (let i = 0; i < 12; i++) {
      context.fillStyle = i % 2 ? '#ffffff03' : '#ffffff07'; context.fillRect(i * laneWidth, 0, laneWidth - 1, h);
    }
    context.strokeStyle = '#91e3d6'; context.lineWidth = 2; context.beginPath(); context.moveTo(0, line); context.lineTo(w, line); context.stroke();
    if (!game) return;
    context.fillStyle = '#adc6d4'; context.font = '9px system-ui'; context.textAlign = 'center';
    game.chart.pitches.forEach((pitch, lane) => context.fillText(midiNoteName(pitch), (lane + .5) * laneWidth, h - 8));
    const ahead = 2400 * game.speed, scale = line / ahead;
    for (let beat = Math.ceil(game.time / 500) * 500; beat < game.time + ahead; beat += 500) {
      const y = line - (beat - game.time) * scale; context.fillStyle = '#ffffff0b'; context.fillRect(0, y, w, 1);
    }
    // Binary search the visible onset window; never redraw a whole long score.
    const notes = game.chart.notes; let lo = 0, hi = notes.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (notes[mid].startMs < game.time - 400 * game.speed) lo = mid + 1; else hi = mid; }
    for (let i = lo; i < notes.length && notes[i].startMs < game.time + ahead; i++) {
      const n = notes[i], result = game.results[i], y = line - (n.startMs - game.time) * scale;
      const height = Math.max(12, Math.min(90, n.durationMs * scale));
      context.fillStyle = result === 'miss' ? '#c48288' : result ? '#91e3b5' : Math.abs(n.startMs - game.time) / game.speed <= 160 ? '#f0cc86' : '#8ebad4';
      context.beginPath(); context.roundRect(n.lane * laneWidth + 4, y - height, Math.max(3, laneWidth - 8), height, 5); context.fill();
    }
  }
  // RAF's frame timestamp can predate an input handled within that same frame.
  // Sample the same monotonic clock as press/start instead of mixing timestamps.
  function tick() { if (!visible) return; game?.advance(performance.now()); render(); animation = requestAnimationFrame(tick); }
  function setVisible(value) {
    pause(); visible = value; cancelAnimationFrame(animation);
    root.hidden = !value; document.body.classList.toggle('rhythm-mode', value);
    if (value) { stopPreview(); loadSources(); if (!game || game.status === 'ready') reset(); animation = requestAnimationFrame(tick); }
  }
  window.addEventListener('instrument-mode', event => setVisible(event.detail === 'rhythm'));
  window.addEventListener('instrument-visibility', event => { if (!event.detail) { pause(); visible = false; cancelAnimationFrame(animation); } });
  window.addEventListener('blur', pause);
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
  window.addEventListener('pagehide', () => { cancelAnimationFrame(animation); sound.close(); });
  return { scoreChanged() { if ($('#rhythm-source').value === 'current') reset(); } };
}
