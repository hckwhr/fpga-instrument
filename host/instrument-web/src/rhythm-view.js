import { buildRhythmChart, demoRhythmEvents, KEY_CODES, RHYTHM_KEYMAPS, RhythmGame } from './rhythm-engine.js';
import { createRhythmAudio } from './rhythm-audio.js';
import { RhythmSession } from './rhythm-session.js';
import { compileTracks, midiNoteName } from './midi.js';

export function createRhythmView({ currentScore, library, stopPreview, device }) {
  const css = document.createElement('link'); css.rel = 'stylesheet'; css.href = new URL('./rhythm.css', import.meta.url).href; document.head.append(css);
  const root = document.createElement('section'); root.id = 'rhythm-root'; root.hidden = true;
  root.setAttribute('aria-label', '节奏大师');
  root.innerHTML = `
    <header class="rhythm-heading"><div><p class="rhythm-eyebrow">MINERADIO / LIVE STAGE</p><h1>节奏大师<span>十二键，奏出你的节奏。</span></h1></div><span class="rhythm-local">● 本机练习 · 键盘 / 触屏</span></header>
    <div class="rhythm-layout">
      <main class="rhythm-stage">
        <div class="rhythm-scorebar"><div><span>得分</span><strong id="rhythm-points">00000</strong></div><div><span>连击</span><strong id="rhythm-combo">0</strong></div><div><span>完成分</span><strong id="rhythm-accuracy">0%</strong></div><div class="rhythm-timer"><span id="rhythm-song-name">小星星</span><strong id="rhythm-time">0:00 / 0:00</strong></div></div>
        <div class="rhythm-actions"><button type="button" id="rhythm-start" class="button primary">开始练习</button><button type="button" id="rhythm-pause" class="button" disabled>暂停</button><button type="button" id="rhythm-reset" class="button plain">重来</button><button type="button" id="rhythm-focus" class="button plain" aria-pressed="false">展开舞台</button></div>
        <p id="rhythm-stage-status" class="rhythm-stage-status" role="status" aria-live="polite"></p>
        <div class="rhythm-roll"><canvas id="rhythm-canvas" aria-label="下落音符：到达底部判定线时按下对应键"></canvas><div class="rhythm-callout"><strong id="rhythm-judgement">准备好了吗</strong><span id="rhythm-prompt">按开始，等待音符到达判定线</span></div><span class="rhythm-line-label">判定线</span></div>
        <div id="rhythm-keys" class="rhythm-keys" aria-label="演奏键盘"></div>
        <div class="rhythm-legend"><span><i class="upcoming"></i>即将到达</span><span><i class="due"></i>等待按下</span><span><i class="accepted"></i>命中</span><span><i class="missed"></i>漏音</span></div>
        <progress id="rhythm-progress" max="1" value="0" aria-label="练习进度"></progress>
        <div id="rhythm-result" class="rhythm-result" hidden role="status"></div>
      </main>
      <aside class="rhythm-settings" aria-label="练习设置">
        <p class="rhythm-eyebrow">YOUR SESSION</p><h2>今天，练哪一首？</h2>
        <label>演奏设备<select id="rhythm-device"><option value="local">本机键盘 / 触屏</option><option value="fpga">FPGA 实体 12 键 · RGB 跟练</option></select></label>
        <label>练习曲谱<select id="rhythm-source"><option value="twinkle">小星星 · 入门</option><option value="ode">欢乐颂 · 入门</option><option value="current">FPGA 工作台当前曲谱</option></select></label>
        <label>12 键配谱<select id="rhythm-keymap"><option value="auto">自动配键 · 保留原音高</option><option value="white">C 大调 · Do Re Mi</option><option value="chromatic">半音阶 · C4—B4</option><option value="fold">练习改编 · 八度折叠至 C4—B4</option></select></label>
        <p id="rhythm-chart-info" class="rhythm-note"></p>
        <button type="button" id="rhythm-adapt" class="button" hidden>生成 12 键练习谱（八度折叠）</button>
        <button type="button" id="rhythm-import" class="button plain">导入 / 整理自己的曲谱 ↗</button>
        <fieldset class="rhythm-choice"><legend>练习方式</legend><label><input type="radio" name="rhythm-mode" value="practice" checked><span>跟练<small>等你按对，再继续</small></span></label><label><input type="radio" name="rhythm-mode" value="challenge"><span>挑战<small>按节拍前进，记录漏音</small></span></label></fieldset>
        <label>速度 <output id="rhythm-speed-label">100%</output><input id="rhythm-speed" type="range" min="50" max="150" step="5" value="100"></label>
        <label>舞台效果<select id="rhythm-motion"><option value="live">流光舞台 · 动态光轨</option><option value="quiet">简洁舞台 · 减少动态</option></select></label>
        <p class="rhythm-note">轨道 01—12 按键盘从左到右排列。竖屏触键分两排，以编号对应轨道；横屏可展开完整舞台。</p>
        <p id="rhythm-status" class="rhythm-note" role="status">命中才发声，未按或按错保持静音。</p>
        <div class="rhythm-counts"><span>Perfect <b id="rhythm-perfect">0</b></span><span>Good <b id="rhythm-good">0</b></span><span>Miss <b id="rhythm-miss">0</b></span><span>错按 <b id="rhythm-wrong">0</b></span></div>
        <details class="rhythm-help"><summary>怎么玩 / 硬件联动</summary><p>本机模式：电脑用 A S D F G H J K L ; ' Enter，手机触摸琴键。同音重奏需要先松开。Perfect ±70 ms，Good ±160 ms。</p><p>实体模式：先在 FPGA 工作台连接 BLE 或 USB，再选 FPGA 实体 12 键。RGB 亮起的位置就是要按的压力键，按对才由板端发声，按齐后曲谱继续。实体模式只提供跟练，不把蓝牙延迟算作演奏误差。</p><p>练习当前音乐：在 FPGA 工作台将音乐转换为曲谱，再选“FPGA 工作台当前曲谱”。自动配键保留原音高，以屏幕标注为准；超出 12 键范围时可明确选择八度折叠，生成独立练习谱，原曲谱不变。实体跟练会临时配置键位，停止后请松开压力键以恢复原设置。</p></details>
      </aside>
    </div>`;
  document.body.append(root);
  const $ = selector => root.querySelector(selector);
  const sound = createRhythmAudio();
  const canvas = $('#rhythm-canvas'), context = canvas.getContext('2d');
  let game, visible = false, animation, lastFeedback = 0, loading = false, generation = 0;
  const activeInputs = new Map();
  let savedScores = [], title = '', stageError = '';
  const particles = [];
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const animated = () => !reducedMotion.matches && $('#rhythm-motion').value === 'live';
  const message = text => { $('#rhythm-status').textContent = text; $('#rhythm-stage-status').textContent = text; };
  const showError = error => { stageError = error.message || String(error); message(stageError); root.dataset.error = 'true'; render(); };
  const clearError = () => { stageError = ''; delete root.dataset.error; };
  function hitBurst(lane) {
    if (!animated()) return;
    particles.push({ lane, at: performance.now() });
    if (particles.length > 36) particles.shift();
  }
  const hardwareMode = () => $('#rhythm-device').value === 'fpga';
  let cueStart = null, cueBusy = false, hardwareStopping = null;
  const hardware = device ? new RhythmSession(device, {
    onStatus(status) {
      if (!hardwareMode() || game?.status !== 'running') return;
      for (let lane = 0; lane < 12; lane++) {
        if (status.newHits & (1 << lane)) {
          // Sticky FPGA hits prove a fresh accepted edge even if a complete
          // press/release occurred between two BLE polls.
          game.release(lane);
          const hit = game.press(lane, performance.now());
          if (hit?.note) {
            hitBurst(lane);
            $('#rhythm-judgement').textContent = '实体命中';
            $('#rhythm-prompt').textContent = midiNoteName(hit.note.note);
            lastFeedback = performance.now();
          }
        }
        if (!(status.keys & (1 << lane))) game.release(lane);
      }
      render();
    },
    onError(error) { game?.pause(performance.now()); releaseAll(); showError(error); }
  }) : null;
  function stopHardware() {
    cueStart = null;
    if (!hardware || hardwareStopping) return hardwareStopping;
    hardwareStopping = hardware.close().catch(showError).finally(() => {
      hardwareStopping = null; render();
    });
    return hardwareStopping;
  }
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
    void stopHardware();
    clearError(); particles.length = 0;
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
      $('#rhythm-song-name').textContent = title;
      const mapping = $('#rhythm-keymap').value;
      const chart = buildRhythmChart(events, RHYTHM_KEYMAPS[mapping] || mapping);
      game = new RhythmGame(chart, { mode: $('input[name="rhythm-mode"]:checked').value, speed: +$('#rhythm-speed').value / 100 });
      $('#rhythm-song-name').textContent = title;
      $('#rhythm-adapt').hidden = true;
      $('#rhythm-chart-info').textContent = `${chart.notes.length} 个起音 · 本曲使用 ${new Set(chart.notes.map(n => n.lane)).size} / 12 键${mapping === 'fold' ? ` · 练习改编：${chart.folded} 个音符调整八度，节奏保留` : ' · 原音高'}${chart.merged ? ` · ${chart.merged} 个同刻同音合并` : ''}`;
      const labels = ['A','S','D','F','G','H','J','K','L',';','\'','↵'];
      for (let lane = 0; lane < 12; lane++) {
        const key = document.createElement('button'); key.type = 'button'; key.dataset.lane = lane;
        key.disabled = lane >= chart.pitches.length;
        key.innerHTML = `<span class="rhythm-led"></span><small class="rhythm-key-number">${String(lane + 1).padStart(2, '0')}</small><strong>${midiNoteName(chart.pitches[lane])}</strong><kbd>${labels[lane]}</kbd>`;
        key.setAttribute('aria-label', key.disabled ? '未分配音高' : `${midiNoteName(chart.pitches[lane])}，快捷键 ${labels[lane]}`);
        $('#rhythm-keys').append(key);
      }
      $('#rhythm-start').disabled = false;
      $('#rhythm-judgement').textContent = '准备好了吗'; $('#rhythm-prompt').textContent = '按开始，等待音符到达判定线';
      message(hardwareMode() ? '先连接 FPGA，退出板端设置并松开压力键。按开始后，依照 RGB 提示弹奏。' : '命中才发声。此模式使用本机音频，不控制 FPGA 自动播放。');
    } catch (error) {
      $('#rhythm-adapt').hidden = !['current', ...savedScores.map(s => `saved:${s.id}`)].includes($('#rhythm-source').value);
      $('#rhythm-chart-info').textContent = '曲谱暂不可练习'; $('#rhythm-judgement').textContent = '换一份练习曲谱';
      $('#rhythm-prompt').textContent = '选择自动配键或生成 12 键练习谱'; showError(error);
    }
    render();
  }
  async function start() {
    if (!game || loading || game.status === 'running') return;
    if (game.status === 'finished') reset();
    const token = ++generation; loading = true; $('#rhythm-start').disabled = true;
    clearError();
    try {
      stopPreview();
      await hardwareStopping;
      if (token !== generation || !visible || document.hidden) return;
      if (hardwareMode()) {
        if (!hardware) throw Error('当前页面没有设备连接入口');
        message('正在停止板端自动播放、配置 12 键并等待 FPGA 确认…');
        await hardware.open(game.chart.pitches); hardware.schedule(); cueStart = null;
      } else await sound.unlock();
      if (token !== generation || !visible || document.hidden) return;
      game.start(performance.now()); message(hardwareMode() ? '实体跟练中：按下 RGB 提示的压力键，声音由 FPGA 发出。和弦需按齐，同音重奏先松开。' : game.mode === 'practice' ? '跟练中：黄色键等待你按下；和弦需逐个或同时按齐。' : '挑战中：音符到达判定线时按下对应键。');
      canvas.focus({ preventScroll: true });
    } catch (error) { showError(Error(`练习未启动：${error.message}`)); }
    finally { if (token === generation) { loading = false; render(); } }
  }
  function pause() {
    generation++; loading = false;
    game?.pause(performance.now()); releaseAll(); render();
    void stopHardware();
  }
  function press(lane, input) {
    if (hardwareMode() || activeInputs.has(input) || game?.status !== 'running') return;
    // Multiple pointers/keyboard inputs holding the same lane count as one press.
    const occupied = [...activeInputs.values()].includes(lane); activeInputs.set(input, lane);
    if (occupied) return;
    const hit = game.press(lane, performance.now());
    if (!hit) return;
    if (hit.note) sound.hit(hit.note, game.speed);
    if (hit.note) hitBurst(lane);
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
  $('#rhythm-adapt').onclick = () => { $('#rhythm-keymap').value = 'fold'; reset(); };
  $('#rhythm-focus').onclick = () => {
    const expanded = root.classList.toggle('stage-expanded');
    $('#rhythm-focus').setAttribute('aria-pressed', String(expanded));
    $('#rhythm-focus').textContent = expanded ? '显示设置' : '展开舞台'; render();
  };
  $('#rhythm-source').onchange = reset;
  $('#rhythm-device').onchange = () => {
    if (hardwareMode()) $('input[value="practice"]').checked = true;
    $('input[value="challenge"]').disabled = hardwareMode();
    $('.rhythm-counts').hidden = hardwareMode();
    $('.rhythm-local').textContent = hardwareMode() ? '● FPGA 实体跟练 · RGB / 压力键' : '● 本机练习 · 键盘 / 触屏';
    reset();
  };
  $('#rhythm-keymap').onchange = reset;
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
      $('#rhythm-start').disabled = loading || Boolean(hardwareStopping) || game.status === 'running'; $('#rhythm-pause').disabled = game.status !== 'running';
      $('#rhythm-start').textContent = game.status === 'paused' ? '继续练习' : game.status === 'finished' ? '再来一次' : '开始练习';
      const next = game.next();
      for (const key of $('#rhythm-keys').children) {
        const lane = +key.dataset.lane;
        key.classList.toggle('pressed', game.held.has(lane));
        key.classList.toggle('due', !!next && game.chart.notes.slice(game.cursor, game.cursor + 12).some(n => n.lane === lane && !game.results[n.id] && Math.abs(n.startMs - game.time) / game.speed <= 160));
        key.setAttribute('aria-pressed', String(game.held.has(lane)));
      }
      if (stageError) {
        $('#rhythm-judgement').textContent = '练习未就绪';
        $('#rhythm-prompt').textContent = '请查看开始按钮下方的提示';
      } else if (loading) {
        $('#rhythm-judgement').textContent = '正在准备';
        $('#rhythm-prompt').textContent = '等待板端确认，完成后自动开始';
      } else if (performance.now() - lastFeedback > 650) {
        $('#rhythm-judgement').textContent = game.status === 'running' ? game.time < 0 ? String(Math.ceil(-game.time / game.speed / 1000)) : game.mode === 'practice' && next?.startMs === game.time ? '轮到你了' : '跟上节拍' : game.status === 'paused' ? '已暂停' : game.status === 'finished' ? '练习完成' : '准备好了吗';
        $('#rhythm-prompt').textContent = game.status === 'paused' ? '点击继续，接着练' : game.status === 'ready' ? '按开始，等待音符到达判定线' : game.status === 'finished' ? '每一次练习，都更进一步' : '到线按键 · 命中发声';
      }
      if (game.status === 'finished') {
        $('#rhythm-result').hidden = false;
        $('#rhythm-result').textContent = `${hardwareMode() ? '实体跟练' : game.mode === 'practice' ? '跟练' : '挑战'}完成 · 命中 ${game.counts.hit + game.counts.perfect + game.counts.good}/${game.chart.notes.length} · 最高连击 ${game.bestCombo}${hardwareMode() ? '' : ` · 错按 ${game.counts.wrong}`} · ${Math.round(game.accuracy)} 分`;
      }
    }
    draw();
  }
  function draw() {
    const box = canvas.getBoundingClientRect(); if (!box.width || !box.height) return;
    const dpr = Math.min(2, devicePixelRatio || 1), w = box.width, h = box.height;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) { canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr); }
    context.setTransform(dpr, 0, 0, dpr, 0, 0); context.clearRect(0, 0, w, h);
    const horizon = h * .12, line = h - 32;
    const now = performance.now(), motion = animated();
    // Decorative motion never moves the twelve hit positions or changes time.
    // Keep hit targets fixed while light ribbons and dust move behind the notes.
    if (motion) {
      for (let i = 0; i < 3; i++) {
        const y = horizon + Math.sin(now / 2600 + i * 1.7) * h * .14;
        context.strokeStyle = ['#73e8ef20','#bca3ff20','#bed9ff12'][i];
        context.lineWidth = 18 + i * 10;
        context.beginPath(); context.moveTo(-30,y);
        context.bezierCurveTo(w*.25,y-h*.22,w*.65,y+h*.2,w+30,y-h*.12); context.stroke();
      }
    }
    // One projection for lanes, beats, notes and judgement: the same note never
    // crosses its lane as it approaches. Coordinates are CSS pixels at any DPR.
    const point = (lane, depth) => {
      const p = Math.max(0, Math.min(1.06, depth));
      const z = .22 * p / (1 - .78 * p);
      return [w / 2 + (lane / 12 - .5) * w * (.22 + .78 * z), horizon + (line - horizon) * z];
    };
    const quad = (left, right, far, near, fill, stroke) => {
      context.beginPath();
      [point(left, far), point(right, far), point(right, near), point(left, near)].forEach(([x,y], i) => i ? context.lineTo(x,y) : context.moveTo(x,y));
      context.closePath(); context.fillStyle = fill; context.fill();
      if (stroke) { context.strokeStyle = stroke; context.stroke(); }
    };
    const glow = context.createRadialGradient(w / 2, horizon, 0, w / 2, horizon, w * .7);
    glow.addColorStop(0, '#715bd040'); glow.addColorStop(.5, '#2d749018'); glow.addColorStop(1, '#14203700');
    context.fillStyle = glow; context.fillRect(0, 0, w, h);
    context.lineWidth = 1;
    for (let i = 0; i < 12; i++) {
      quad(i, i+1, 0, 1, i % 2 ? '#131e36e8' : '#1a2941e8', '#9dbde626');
      if (game?.held.has(i)) {
        const beam = context.createLinearGradient(0, horizon, 0, line);
        beam.addColorStop(0, '#60eddf00'); beam.addColorStop(1, '#60eddf55');
        quad(i+.04, i+.96, .15, 1, beam);
      }
    }
    context.lineWidth = 2;
    for (const edge of [0,12]) {
      const a = point(edge, 0), b = point(edge, 1);
      context.strokeStyle = edge ? '#ae94ff' : '#60e0ed'; context.shadowColor = context.strokeStyle; context.shadowBlur = 12;
      context.beginPath(); context.moveTo(...a); context.lineTo(...b); context.stroke();
    }
    context.shadowBlur = 0;
    if (motion) {
      context.fillStyle = '#b8edfa70';
      for (let i = 0; i < 28; i++) {
        const x = ((i * 97.13) % 997) / 997 * w;
        const y = h - ((now * (.008 + (i % 3) * .004) + i * 23) % h);
        context.fillRect(x, y, i % 3 ? 1 : 2, i % 3 ? 1 : 2);
      }
    }
    const rail = context.createLinearGradient(0, 0, w, 0);
    rail.addColorStop(0,'#64e5ec'); rail.addColorStop(.5,'#e0ffff'); rail.addColorStop(1,'#ad9aff');
    context.fillStyle = rail; context.fillRect(0,line-2,w,4);
    context.fillStyle = '#82dbe724'; context.fillRect(0,line+2,w,6);
    if (motion) for (const burst of particles) {
      const age = (now - burst.at) / 700;
      if (age < 0 || age >= 1) continue;
      const x = (burst.lane + .5) * w / 12;
      context.globalAlpha = 1-age;
      context.strokeStyle = '#d5fff3'; context.lineWidth = 2;
      context.beginPath(); context.ellipse(x,line,12+age*36,4+age*14,0,0,Math.PI*2); context.stroke();
      for (let k = 0; k < 8; k++) {
        const a = k * Math.PI / 4;
        context.fillStyle = k % 2 ? '#bcadff' : '#94fff0';
        context.fillRect(x+Math.cos(a)*age*50,line-Math.abs(Math.sin(a))*age*95,3,3);
      }
      context.globalAlpha = 1;
    }
    while (particles.length && now-particles[0].at>700) particles.shift();
    if (!game) return;
    context.fillStyle = '#b7cee6'; context.font = '10px ui-monospace,monospace'; context.textAlign = 'center';
    game.chart.pitches.forEach((pitch, lane) => context.fillText(String(lane+1).padStart(2,'0'), (lane + .5) * w / 12, h - 8));
    const ahead = 2400 * game.speed;
    for (let beat = Math.ceil(game.time / 500) * 500; beat < game.time + ahead; beat += 500) {
      const depth = 1 - (beat - game.time) / ahead;
      const a = point(0,depth), b = point(12,depth);
      context.strokeStyle = '#c7e8ff20'; context.lineWidth = 1;
      context.beginPath(); context.moveTo(...a); context.lineTo(...b); context.stroke();
    }
    // Binary search the visible onset window; never redraw a whole long score.
    const notes = game.chart.notes; let lo = 0, hi = notes.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (notes[mid].startMs < game.time - 400 * game.speed) lo = mid + 1; else hi = mid; }
    let end = lo;
    while (end < notes.length && notes[end].startMs < game.time + ahead) end++;
    // Paint distant notes first so close notes occlude them correctly.
    for (let i = end - 1; i >= lo; i--) {
      const n = notes[i], result = game.results[i], depth = 1 - (n.startMs - game.time) / ahead;
      if (depth > 1.04) continue;
      const color = result === 'miss' ? '#d78b9d' : result ? '#7ef1c7' : Math.abs(n.startMs - game.time) / game.speed <= 160 ? '#ffe1a0' : n.lane % 2 ? '#bba2ff' : '#72dcfa';
      if (n.durationMs > 220 && !result) quad(n.lane+.3,n.lane+.7,depth-Math.min(.35,n.durationMs/ahead),depth,color+'38');
      context.shadowColor = color; context.shadowBlur = depth > .8 ? 14 : 4;
      quad(n.lane+.09,n.lane+.91,depth-.025,depth,color,'#ffffff85');
      context.shadowBlur = 0;
    }
    if (lastFeedback && performance.now() - lastFeedback < 450 && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
      const fade = 1 - (performance.now() - lastFeedback) / 450;
      context.globalAlpha = fade;
      for (const lane of game.held) {
        const x = (lane+.5)*w/12;
        context.strokeStyle='#c1fff0'; context.lineWidth=2;
        context.beginPath(); context.ellipse(x,line,w/30*(1.5-fade),8*(1.5-fade),0,0,Math.PI*2);context.stroke();
      }
      context.globalAlpha = 1;
    }
  }
  // RAF's frame timestamp can predate an input handled within that same frame.
  // Sample the same monotonic clock as press/start instead of mixing timestamps.
  function tick() {
    if (!visible) return;
    game?.advance(performance.now());
    if (hardwareMode() && hardware?.running && !cueBusy) {
      const next = game?.next();
      if (game?.status === 'finished') void stopHardware();
      else if (game?.status === 'running' && next && game.time >= next.startMs && cueStart !== next.startMs && !hardware.pending) {
        const start = next.startMs;
        const mask = game.chart.notes.filter(n => n.startMs === start && !game.results[n.id]).reduce((m, n) => m | (1 << n.lane), 0);
        cueBusy = true;
        void hardware.setCue(mask).then(ok => { if (ok) cueStart = start; }).finally(() => { cueBusy = false; });
      }
    }
    render(); animation = requestAnimationFrame(tick);
  }
  function setVisible(value) {
    if (value === visible) return;
    pause(); visible = value; cancelAnimationFrame(animation);
    root.hidden = !value; document.body.classList.toggle('rhythm-mode', value);
    if (value) { stopPreview(); loadSources(); if (!game || game.status === 'ready') reset(); animation = requestAnimationFrame(tick); }
  }
  window.addEventListener('instrument-mode', event => setVisible(event.detail === 'rhythm'));
  window.addEventListener('instrument-visibility', event => { if (!event.detail) { pause(); visible = false; cancelAnimationFrame(animation); } });
  window.addEventListener('blur', pause);
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
  window.addEventListener('pagehide', () => { cancelAnimationFrame(animation); sound.close(); void stopHardware(); });
  return { scoreChanged() { if ($('#rhythm-source').value === 'current') reset(); } };
}
