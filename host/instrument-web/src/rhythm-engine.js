// Pure score/clock logic. Input is local keyboard/touch, never inferred FPGA telemetry.
export const HIT_WINDOWS = Object.freeze({ perfect: 70, good: 160 });
export const KEY_CODES = Object.freeze(['KeyA', 'KeyS', 'KeyD', 'KeyF', 'KeyG', 'KeyH', 'KeyJ', 'KeyK', 'KeyL', 'Semicolon', 'Quote', 'Enter']);

export function buildRhythmChart(events) {
  if (!Array.isArray(events) || !events.length || events.length > 50000) throw Error('请选择包含 1–50000 个音符的曲谱');
  const notes = events.map(e => {
    if (!Number.isInteger(e.note) || e.note < 0 || e.note > 127 || !Number.isFinite(e.startMs) || e.startMs < 0 ||
        !Number.isFinite(e.durationMs) || e.durationMs <= 0 || e.startMs + e.durationMs > 3600000 ||
        !Number.isFinite(e.velocity) || e.velocity < 1 || e.velocity > 127) throw Error('曲谱音符无效，或时长超过一小时');
    return { note: e.note, startMs: e.startMs, durationMs: e.durationMs, velocity: e.velocity };
  }).sort((a, b) => a.startMs - b.startMs || a.note - b.note);
  const pitches = [...new Set(notes.map(n => n.note))].sort((a, b) => a - b);
  if (pitches.length > 12) throw Error(`这份曲谱有 ${pitches.length} 个不同音高，超过 12 键。请在 FPGA 播放中选择旋律音轨或较短片段；未删减任何音符。`);
  // Two tracks striking the very same pitch at the same time need one physical
  // action. Preserve the longest sustain / strongest velocity and report the merge.
  const merged = [];
  for (const n of notes) {
    const last = merged.at(-1);
    if (last?.note === n.note && last.startMs === n.startMs) {
      last.durationMs = Math.max(last.durationMs, n.durationMs); last.velocity = Math.max(last.velocity, n.velocity);
    } else merged.push({ ...n, lane: pitches.indexOf(n.note), id: merged.length });
  }
  return { notes: merged, pitches, merged: notes.length - merged.length,
    durationMs: merged.reduce((end, n) => Math.max(end, n.startMs + n.durationMs), 0) };
}

export class RhythmGame {
  constructor(chart, { mode = 'practice', speed = 1 } = {}) {
    if (!['practice', 'challenge'].includes(mode) || !Number.isFinite(speed) || speed < .5 || speed > 1.5) throw Error('练习模式或速度无效');
    this.chart = chart; this.mode = mode; this.speed = speed;
    this.reset();
  }
  reset() {
    this.time = -2000 * this.speed; this.last = null; this.status = 'ready'; this.cursor = 0;
    this.results = Array(this.chart.notes.length).fill(null); this.held = new Set();
    this.counts = { perfect: 0, good: 0, hit: 0, miss: 0, wrong: 0 };
    this.combo = 0; this.bestCombo = 0; this.points = 0;
  }
  start(now) { if (['ready', 'paused'].includes(this.status)) { this.status = 'running'; this.last = now; } }
  pause(now) { this.advance(now); if (this.status === 'running') this.status = 'paused'; this.held.clear(); this.last = null; }
  release(lane) { this.held.delete(lane); }
  next() { while (this.cursor < this.results.length && this.results[this.cursor]) this.cursor++; return this.chart.notes[this.cursor]; }
  advance(now) {
    if (this.status !== 'running') return;
    if (!Number.isFinite(now) || now < this.last) throw Error('练习时钟必须单调递增');
    let target = this.time + (now - this.last) * this.speed;
    this.last = now;
    const next = this.next();
    if (this.mode === 'practice' && next) target = Math.min(target, next.startMs);
    this.time = target;
    if (this.mode === 'challenge') {
      let n;
      while ((n = this.next()) && (this.time - n.startMs) / this.speed > HIT_WINDOWS.good) {
        this.results[n.id] = 'miss'; this.counts.miss++; this.combo = 0;
      }
    }
    if (!this.next() && this.time >= this.chart.durationMs + HIT_WINDOWS.good * this.speed) {
      this.status = 'finished'; this.held.clear();
    }
  }
  press(lane, now) {
    this.advance(now);
    if (this.status !== 'running' || !Number.isInteger(lane) || lane < 0 || lane >= this.chart.pitches.length || this.held.has(lane)) return null;
    this.held.add(lane);
    const limit = this.mode === 'practice' ? this.time : this.time + HIT_WINDOWS.good * this.speed;
    let note;
    for (let i = this.cursor; i < this.chart.notes.length; i++) {
      const n = this.chart.notes[i];
      if (n.startMs > limit) break;
      if (!this.results[i] && n.lane === lane) { note = n; break; }
    }
    if (!note) { this.counts.wrong++; this.combo = 0; return { judgement: 'wrong' }; }
    const errorMs = (this.time - note.startMs) / this.speed;
    const judgement = this.mode === 'practice' ? 'hit' : Math.abs(errorMs) <= HIT_WINDOWS.perfect ? 'perfect' : 'good';
    this.results[note.id] = judgement; this.counts[judgement]++; this.combo++;
    this.bestCombo = Math.max(this.bestCombo, this.combo);
    this.points += judgement === 'good' ? 70 : 100;
    this.next();
    return { judgement, note, errorMs };
  }
  get accuracy() { return this.points / (this.chart.notes.length * 100) * 100; }
}

// Short, recognisable phrases; no reference recording plays behind the exercise.
export function demoRhythmEvents(name) {
  const melody = name === 'ode' ?
    [64,64,65,67,67,65,64,62,60,60,62,64,64,62,62] :
    [60,60,67,67,69,69,67,65,65,64,64,62,62,60];
  let at = 0;
  return melody.map((note, i) => {
    const beats = (name === 'ode' ? i === 14 : i === 6 || i === 13) ? 2 : 1;
    const e = { note, startMs: at, durationMs: beats * 500 - 60, velocity: 100 };
    at += beats * 500; return e;
  });
}
