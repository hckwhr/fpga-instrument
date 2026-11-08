import { BoardAudioSession, boardSpectrum } from './board-audio.js';

export function createBoardAudioView(section, device, upload) {
  const container = document.createElement('div'); container.className = 'board-audio';
  container.innerHTML = `<div class="connection-controls"><button type="button" id="board-audio-capture" class="button primary">抓取 FPGA 音频</button><label class="checkbox"><input type="checkbox" id="board-audio-auto">连续快照 · 约每 7 秒</label></div>
    <p id="board-audio-state" class="hint" role="status">等待 FPGA 音频回传 · 需要支持 SCOPE1 的板端固件</p>
    <div class="monitor-grid board-audio-grid">
      <figure><figcaption>FPGA 波形 <small>输出 PCM / 21.33 ms</small></figcaption><canvas id="board-wave" aria-label="FPGA 实测输出波形"></canvas></figure>
      <figure><figcaption>FPGA 频谱 <small>48 kHz · 1024 点 FFT · dBFS</small></figcaption><canvas id="board-spectrum" aria-label="FPGA 实测输出频谱"></canvas></figure>
      <figure><figcaption>FPGA 李萨如 <small>X：效果前 / Y：输出</small></figcaption><canvas id="board-xy" aria-label="FPGA 效果前后信号的李萨如图形"></canvas></figure>
    </div>
    <p class="hint">三图来自同一段 FPGA 实测音频，与电脑试听独立。9600 波特率下每帧约需 5 秒；显示分段快照，不是连续实时流。关闭效果时 X/Y 接近直线属于正常现象。8 位采集仅用于显示，DAC 仍为 16 位。</p>`;
  section.querySelector('.board-telemetry-note').replaceWith(container);
  const $ = selector => container.querySelector(selector);
  const session = new BoardAudioSession(device);
  let frame = null, spectrum = null, visible = true, disposed = false, lastRequest = 0, manualOperation = false;
  window.addEventListener('instrument-performance-operation', event => { manualOperation = Boolean(event.detail); });
  function grid(canvas) {
    const width = Math.max(1, canvas.clientWidth), height = Math.max(1, canvas.clientHeight), ratio = Math.min(devicePixelRatio || 1, 2);
    canvas.width = Math.round(width * ratio); canvas.height = Math.round(height * ratio);
    const ctx = canvas.getContext('2d'); ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.strokeStyle = 'rgba(160,195,210,.14)'; ctx.lineWidth = 1; ctx.beginPath();
    for (let i = 1; i < 4; i++) {
      ctx.moveTo(width * i / 4, 0); ctx.lineTo(width * i / 4, height);
      ctx.moveTo(0, height * i / 4); ctx.lineTo(width, height * i / 4);
    }
    ctx.stroke(); ctx.strokeStyle = '#8fe9df'; ctx.fillStyle = '#8fe9df'; ctx.lineWidth = 1.5;
    if (!frame) { ctx.font = '14px sans-serif'; ctx.fillText('等待 FPGA 实测采样', 20, 30); }
    return { ctx, width, height };
  }
  function draw() {
    let { ctx, width, height } = grid($('#board-wave'));
    if (frame) {
      ctx.beginPath();
      frame.wet.forEach((v, i) => { const x = i / 1023 * width, y = height / 2 - v * height * .46; i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); });
      ctx.stroke();
    }
    ({ ctx, width, height } = grid($('#board-spectrum')));
    if (spectrum) {
      ctx.beginPath();
      for (let i = 1; i < spectrum.length; i++) {
        const x = Math.log(i) / Math.log(512) * width, y = height * (1 - Math.max(0, Math.min(1, (spectrum[i] + 72) / 72)));
        i === 1 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      }
      ctx.stroke(); ctx.font = '12px sans-serif';
      ctx.fillText('46.9 Hz', 8, height - 8); ctx.fillText('24 kHz', width - 55, height - 8);
      ctx.fillText('0 dBFS', 8, 16); ctx.fillText('−72 dBFS', 8, height - 26);
    }
    ({ ctx, width, height } = grid($('#board-xy')));
    if (frame) {
      ctx.beginPath();
      frame.dry.forEach((v, i) => { const x = width / 2 + v * width * .46, y = height / 2 - frame.wet[i] * height * .46; i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); });
      ctx.stroke();
    }
    container.dataset.signal = String(Boolean(frame?.wet.some(v => v !== 0)));
    container.dataset.frame = frame?.id || '';
  }
  function available() {
    const d = device.snapshot();
    return !document.body.classList.contains('rhythm-mode') && !disposed && !manualOperation && d.connected && !d.blocked && !d.busy && !upload.snapshot().busy && !session.snapshot().unsupported;
  }
  function render() {
    const d = device.snapshot(), s = session.snapshot();
    if (frame !== s.frame) { frame = s.frame; spectrum = frame ? boardSpectrum(frame.wet) : null; draw(); }
    $('#board-audio-capture').disabled = !available();
    $('#board-audio-auto').disabled = !d.connected || d.blocked || s.unsupported;
    if (!d.connected || d.blocked || s.unsupported) $('#board-audio-auto').checked = false;
    $('#board-audio-state').textContent = !d.connected ? '未连接 · 等待 FPGA 音频回传' : d.blocked ? '通信状态未知，请断开重连' : frame ?
      `FPGA 实测快照 · 接收于 ${new Date(frame.receivedAt).toLocaleTimeString()} · ${Math.floor((Date.now() - frame.receivedAt) / 1000)} 秒前 · 非连续流` : s.message;
  }
  async function capture() {
    if (!available()) return;
    lastRequest = Date.now();
    try { await session.capture(); } catch { /* Session reports error; uncertain transfers require reconnect. */ }
  }
  $('#board-audio-capture').onclick = capture;
  $('#board-audio-auto').onchange = () => { if ($('#board-audio-auto').checked) void capture(); };
  const timer = setInterval(() => {
    if (!visible || document.hidden) return;
    render();
    if ($('#board-audio-auto').checked && Date.now() - lastRequest >= 7000) void capture();
  }, 1000);
  const unsubscribe = [session.onChange(render), device.onChange(render), upload.onChange(render)];
  const observer = new ResizeObserver(draw); observer.observe(container);
  window.addEventListener('instrument-visibility', event => { visible = Boolean(event.detail); if (visible) { draw(); render(); } });
  window.addEventListener('pagehide', () => { disposed = true; clearInterval(timer); observer.disconnect(); unsubscribe.forEach(fn => fn()); session.dispose(); }, { once: true });
  draw(); render();
}
