// These displays measure the local Web Audio preview, never unacknowledged
// FPGA playback. The XY trace uses a documented delay of the same mono signal.
export function createPerformanceMonitor() {
  const section = document.createElement('section');
  section.id = 'performance-visuals';
  section.className = 'performance-visuals';
  section.setAttribute('aria-labelledby', 'visuals-heading');
  section.innerHTML = `<div class="section-heading"><h2 id="visuals-heading">电脑可视化</h2><span class="monitor-origin">电脑试听 · 非板端回传</span></div>
    <p id="monitor-state" class="hint" role="status">等待试听 · 导入曲谱后点击「试听音符」</p>
    <div class="monitor-grid">
      <figure><figcaption>波形 <small>AMPLITUDE / TIME</small></figcaption><canvas id="monitor-wave" aria-label="电脑试听音频的时域波形"></canvas></figure>
      <figure><figcaption>李萨如 <small>X(t) / X(t − 1ms)</small></figcaption><canvas id="monitor-xy" aria-label="同一试听信号与其一毫秒延迟的 XY 轨迹"></canvas></figure>
      <figure><figcaption>频谱 <small>20 Hz — 20 kHz</small></figcaption><canvas id="monitor-spectrum" aria-label="电脑试听音频的频谱"></canvas></figure>
    </div>`;
  document.querySelector('.result-panel').after(section);
  const keyboard = document.createElement('section');
  keyboard.className = 'preview-keyboard';
  keyboard.setAttribute('aria-label', '试听键盘，C3 至 C6；亮键表示当前曲谱音符');
  keyboard.innerHTML = '<div class="keyboard-caption"><span>演奏键盘</span><span id="monitor-notes">等待试听 · C3—C6</span></div><div class="keyboard-keys"></div>';
  document.querySelector('.roll-frame').after(keyboard);
  const keys = new Map();
  let white = 0;
  for (let note = 48; note <= 84; note++) {
    const black = [1, 3, 6, 8, 10].includes(note % 12);
    const key = document.createElement('span');
    key.className = black ? 'piano-key black' : 'piano-key white';
    key.dataset.note = note;
    key.style.setProperty('--key-position', black ? white - 0.32 : white++);
    key.textContent = note % 12 === 0 ? `C${Math.floor(note / 12) - 1}` : '';
    keyboard.lastElementChild.append(key); keys.set(note, key);
  }
  keyboard.lastElementChild.style.setProperty('--white-keys', white);
  const canvases = [...section.querySelectorAll('canvas')];
  const state = section.querySelector('#monitor-state');
  const notes = keyboard.querySelector('#monitor-notes');
  const samples = new Float32Array(4096), spectrum = new Uint8Array(2048);
  let playback = null, raf = 0, visible = true, last = 0, cursor = 0, activeEvents = [], previousElapsed = -1;
  const grid = canvas => {
    const width = Math.max(1, canvas.clientWidth), height = Math.max(1, canvas.clientHeight);
    const ratio = Math.min(devicePixelRatio || 1, 2);
    if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) {
      canvas.width = Math.round(width * ratio); canvas.height = Math.round(height * ratio);
    }
    const ctx = canvas.getContext('2d');
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.clearRect(0, 0, width, height);
    ctx.strokeStyle = 'rgba(160,195,210,.12)'; ctx.lineWidth = 1;
    ctx.beginPath();
    for (let n = 1; n < 4; n++) {
      ctx.moveTo(width * n / 4, 0); ctx.lineTo(width * n / 4, height);
      ctx.moveTo(0, height * n / 4); ctx.lineTo(width, height * n / 4);
    }
    ctx.stroke(); ctx.strokeStyle = '#8fe9df'; ctx.lineWidth = 1.5;
    return { ctx, width, height };
  };
  const draw = () => {
    const playing = playback && playback.context.state === 'running';
    samples.fill(0); spectrum.fill(0);
    if (playing) {
      playback.analyser.getFloatTimeDomainData(samples);
      playback.analyser.getByteFrequencyData(spectrum);
    }
    const elapsed = playing ? (playback.context.currentTime - playback.start) * 1000 : -1;
    // Events arrive sorted from compileTracks. Advance once per note instead of
    // scanning up to 50,000 notes on every animation frame.
    if (elapsed < previousElapsed) { cursor = 0; activeEvents = []; }
    previousElapsed = elapsed;
    if (playing) {
      while (cursor < playback.events.length && playback.events[cursor].startMs <= elapsed) activeEvents.push(playback.events[cursor++]);
      activeEvents = activeEvents.filter(e => e.startMs + e.durationMs > elapsed);
    } else activeEvents = [];
    const pitches = new Set(activeEvents.map(e => e.note));
    for (const [note, key] of keys) key.classList.toggle('active', pitches.has(note));
    notes.textContent = playing ? `${pitches.size} 个音高 · ${(Math.max(0, elapsed) / 1000).toFixed(1)} s` : '等待试听 · C3—C6';
    let { ctx, width, height } = grid(canvases[0]);
    ctx.beginPath();
    // Align to a rising zero crossing so musical waveforms remain readable.
    let offset = 0;
    for (let i = 1; i < 1024; i++) if (samples[i - 1] <= 0 && samples[i] > 0) { offset = i; break; }
    for (let i = 0; i < 1024; i++) {
      const x = i / 1023 * width, y = height / 2 - samples[offset + i] * height * 2;
      i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
    }
    ctx.stroke();
    ({ ctx, width, height } = grid(canvases[1]));
    const delay = playing ? Math.round(playback.context.sampleRate / 1000) : 48;
    ctx.beginPath();
    for (let i = delay; i < 2048; i++) {
      const x = width / 2 + samples[i] * width * 2, y = height / 2 - samples[i - delay] * height * 2;
      i === delay ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
    }
    ctx.stroke();
    ({ ctx, width, height } = grid(canvases[2]));
    ctx.fillStyle = '#8fe9df';
    for (let i = 0; i < 48; i++) {
      const frequency = 20 * 1000 ** (i / 47);
      const bin = playing ? Math.round(frequency * 4096 / playback.context.sampleRate) : 0;
      const amplitude = playing ? spectrum[Math.min(2047, bin)] / 255 : 0;
      ctx.fillRect(i * width / 48, height * (1 - amplitude), Math.max(1, width / 48 - 3), height * amplitude);
    }
    section.dataset.playing = String(!!playing);
    section.dataset.signal = String(samples.some(value => Math.abs(value) > 0.0001));
    state.textContent = playing ? '正在显示电脑试听音频 · 键盘跟随曲谱音符' : '等待试听 · 导入曲谱后点击「试听音符」';
  };
  const animate = now => {
    raf = 0;
    if (!visible || document.hidden || !playback) return;
    if (now - last >= 33) { draw(); last = now; }
    raf = requestAnimationFrame(animate);
  };
  const resume = () => { if (!raf && visible && !document.hidden && playback) raf = requestAnimationFrame(animate); };
  document.addEventListener('visibilitychange', resume);
  window.addEventListener('instrument-visibility', event => {
    visible = event.detail;
    if (!visible) { cancelAnimationFrame(raf); raf = 0; } else { draw(); resume(); }
  });
  new ResizeObserver(draw).observe(section);
  return { setPlayback(value) {
    cancelAnimationFrame(raf); raf = 0; playback = value; cursor = 0; activeEvents = []; previousElapsed = -1; draw(); resume();
  } };
}
