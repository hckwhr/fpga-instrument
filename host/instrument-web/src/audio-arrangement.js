import { compileFpgaScore } from './fpga-score.js';

// Confirmed derivative only: these heuristics do not separate vocals and backing.
// Recognition and its warnings remain untouched for comparison and re-arranging.
export function audioSelectionEnd(source) {
  const noteEnd = source?.tracks?.reduce((end, track) => track.notes.reduce((last, n) => Math.max(last, n.endMs / 1000), end), 0) || 0;
  return Math.min(600, Math.max(.01, Math.ceil((source?.audioDurationSeconds || noteEnd) * 1000) / 1000));
}

export function arrangeAudioMelody(source, { startSeconds = 0, endSeconds = audioSelectionEnd(source), confirmed = false,
  strategy = 'balanced', onsetWindowMs = 40, minDurationMs = 80, rhythm = 'original', bpm = 120,
  repeatMode = 'preserve', pitchMode = 'phrase', beatOffsetMs = 0,
  minPitch = 0, maxPitch = 127, protectSustain = true } = {}) {
  if (!confirmed) throw new Error('请先试听并确认接受旋律整理');
  if (source?.format !== 'audio-transcription') throw new Error('请选择音频识别结果');
  if (![startSeconds, endSeconds].every(Number.isFinite) || startSeconds < 0 || endSeconds <= startSeconds || endSeconds > 600)
    throw new Error('选段须在 0..600 秒内，结束时间须大于开始时间');
  if (!['balanced', 'highest', 'strongest'].includes(strategy) ||
      !Number.isFinite(onsetWindowMs) || onsetWindowMs < 0 || onsetWindowMs > 100 ||
      !Number.isFinite(minDurationMs) || minDurationMs < 0 || minDurationMs > 250 ||
      !['original', 'sixteenth'].includes(rhythm) || !Number.isFinite(bpm) || bpm < 40 || bpm > 240 ||
      !['preserve', 'merge'].includes(repeatMode) || !['phrase', 'fold'].includes(pitchMode) ||
      !Number.isFinite(beatOffsetMs) || beatOffsetMs < 0 || beatOffsetMs > 2000 ||
      !Number.isInteger(minPitch) || !Number.isInteger(maxPitch) || minPitch < 0 || maxPitch > 127 || minPitch > maxPitch ||
      typeof protectSustain !== 'boolean')
    throw new Error('旋律整理参数无效；节拍速度须为 40–240 BPM');
  const begin = startSeconds * 1000, finish = endSeconds * 1000;
  const all = source.tracks.flatMap(t => t.notes);
  const selected = all.filter(n => n.startMs < finish && n.endMs > begin);
  // Filter before voice selection/transposition: folding bass into the melody
  // octave first would make accompaniment indistinguishable by register.
  const inRange = selected.filter(n => n.note >= minPitch && n.note <= maxPitch);
  const candidates = inRange.filter(n => n.endMs - n.startMs >= minDurationMs)
    .map(n => ({ ...n, startMs: Math.max(begin, n.startMs), endMs: Math.min(finish, n.endMs) }))
    .sort((a, b) => a.startMs - b.startMs || b.velocity - a.velocity || b.note - a.note);
  // Anchor each cluster to its FIRST onset. Pairwise clustering could chain a
  // rolled chord into the next phrase. Keep only the strongest of each pitch.
  const groups = [];
  for (const note of candidates) {
    let group = groups.at(-1);
    if (!group || note.startMs - group.start > onsetWindowMs) {
      group = { start: note.startMs, pitches: new Map() }; groups.push(group);
    }
    const old = group.pitches.get(note.note);
    if (!old || note.velocity > old.velocity) group.pitches.set(note.note, note);
  }
  if (!groups.length) throw new Error('该选段没有可用音符；请调整选段、旋律音域或碎音过滤');
  // Score the whole phrase with a soft continuity cost rather than selecting the
  // loudest accompaniment at every onset. Genuine leaps remain possible.
  const layers = groups.map(group => {
    const notes = [...group.pitches.values()];
    const top = Math.max(...notes.map(n => n.note));
    return notes.map(note => ({ note, previous: -1, score: 0,
      weight: strategy === 'highest' ? note.note : strategy === 'strongest' ? note.velocity :
        note.velocity / 127 + Math.min(600, note.endMs - note.startMs) / 3000 - Math.min(24, top - note.note) * .025 }));
  });
  for (let i = 0; i < layers.length; i++) for (const choice of layers[i]) {
    choice.score = choice.weight;
    if (!i) continue;
    let best = -Infinity;
    layers[i - 1].forEach((previous, index) => {
      const distance = Math.abs(choice.note.note - previous.note.note);
      const score = previous.score + choice.weight - (strategy === 'balanced' ? Math.min(24, distance) * .04 : 0);
      if (score > best) { best = score; choice.previous = index; }
    });
    choice.score = best;
  }
  let index = layers.at(-1).reduce((best, choice, i, last) => choice.score > last[best].score ? i : best, 0);
  const phrase = new Array(groups.length);
  for (let i = layers.length - 1; i >= 0; i--) {
    // A chord grouping chooses a voice, not its timing: an earlier bass onset
    // must not pull the selected melody forward.
    const choice = layers[i][index]; phrase[i] = { ...choice.note }; index = choice.previous;
  }
  let suppressed = 0, sustainedBass = 0, merged = 0;
  const melody = [];
  for (const note of phrase) {
    const previous = melody.at(-1);
    // Recognition can overlap genuine repeated attacks (especially with reverb).
    // Preserve them by default; merging remains an explicit repair option.
    if (repeatMode === 'merge' && previous && previous.note === note.note && note.startMs < previous.endMs) {
      previous.endMs = Math.max(previous.endMs, note.endMs); merged++; continue;
    }
    if (strategy === 'balanced' && previous && previous.endMs > note.startMs + 50 &&
        note.velocity < previous.velocity * .65 && note.endMs - note.startMs < 200) { suppressed++; continue; }
    // Optional heuristic: a softer bass attack contained inside a sustained
    // upper voice need not replace it. Keep repeated notes, strong attacks and
    // notes continuing beyond the held voice; this is not source separation.
    if (protectSustain && strategy === 'balanced' && previous &&
        previous.endMs > note.startMs + 50 && note.endMs <= previous.endMs &&
        previous.note - note.note >= 12 && note.velocity < previous.velocity * .85) {
      sustainedBass++; continue;
    }
    melody.push(note);
  }
  const gridMs = rhythm === 'sixteenth' ? 60000 / bpm / 4 : 6.25;
  const offset = rhythm === 'sixteenth' ? beatOffsetMs : 0;
  const toTick = ms => Math.round((Math.round((ms - begin - offset) / gridMs) * gridMs + offset) / 6.25);
  const limitTick = Math.round((finish - begin) / 6.25);
  // Snapping may join two onsets. Resolve that before producing a mono score.
  const quantized = new Map();
  for (const note of melody) {
    const tick = Math.max(0, toTick(note.startMs));
    if (tick >= limitTick) continue;
    const old = quantized.get(tick);
    if (!old || note.velocity > old.velocity) quantized.set(tick, note);
  }
  const ordered = [...quantized];
  if (!ordered.length) throw new Error('选段量化后没有可用音符，请延长选段');
  if (ordered.length > 2048) throw new Error(`选段含 ${ordered.length} 个旋律音符，扩容版上限 2048；请缩短选段后重试，不会自动截断`);
  // Prefer a single octave transposition for the phrase. Per-note folding at
  // B5/C6 otherwise turns an ascending semitone into a descending major seventh.
  // If the range exceeds the board's 36 notes, minimize remaining folds, and
  // report those explicitly. No pitch-class correction is guessed here.
  let octaveShift = 0;
  if (pitchMode === 'phrase') {
    let bestOutside = Infinity;
    for (let shift = -72; shift <= 72; shift += 12) {
      const outside = ordered.filter(([, n]) => n.note + shift < 48 || n.note + shift > 83).length;
      if (outside < bestOutside || outside === bestOutside && Math.abs(shift) < Math.abs(octaveShift)) {
        bestOutside = outside; octaveShift = shift;
      }
    }
  }
  // Scale the entire phrase rather than clipping every strong note to 80.
  // Preserve accents/dynamics while retaining the existing headroom ceiling.
  const velocityScale = Math.min(1, 80 / Math.max(...ordered.map(([, n]) => n.velocity)));
  let residualFolds = 0;
  let folded = 0, shortened = 0;
  const notes = ordered.map(([tick, n], order) => {
    let pitch = n.note + octaveShift;
    while (pitch < 48) pitch += 12;
    while (pitch > 83) pitch -= 12;
    if (pitch !== n.note + octaveShift) residualFolds++;
    if (pitch !== n.note) folded++;
    const naturalEnd = Math.min(limitTick, Math.max(tick + 1, toTick(n.endMs)));
    const end = Math.min(naturalEnd, ordered[order + 1]?.[0] ?? naturalEnd);
    if (end < naturalEnd) shortened++;
    return { note: pitch, velocity: Math.max(1, Math.round(n.velocity * velocityScale)), startMs: tick * 6.25, endMs: end * 6.25,
      durationMs: (end - tick) * 6.25, channel: 0, track: 0, order };
  });
  const report = { startSeconds, endSeconds, sourceNotes: all.length, selectedNotes: selected.length,
    melodyNotes: notes.length, removedSimultaneous: candidates.length - groups.length,
    filtered: inRange.length - candidates.length, outsideRange: selected.length - inRange.length,
    suppressed, sustainedBass, merged, folded, shortened, velocityScale,
    strategy, onsetWindowMs, minDurationMs, rhythm, bpm, gridMs, gridCollisions: melody.length - ordered.length,
    repeatMode, pitchMode, beatOffsetMs, octaveShift, residualFolds, minPitch, maxPitch, protectSustain };
  const project = { format: 'audio-transcription', title: `${source.title} · 已确认旋律选段`, partial: true,
    tracks: [{ title: '已确认单声部旋律', notes, warnings: [] }], arrangement: report };
  // Use the unchanged hardware compiler as admission control, including tail
  // occupancy. Very fast/dense recognition must still fail rather than overflow.
  compileFpgaScore(project);
  return { project, report };
}
