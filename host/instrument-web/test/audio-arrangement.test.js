import test from 'node:test';
import assert from 'node:assert/strict';
import { notesToProject } from '../src/audio.js';
import { arrangeAudioMelody, audioSelectionEnd } from '../src/audio-arrangement.js';
import { compileFpgaScore } from '../src/fpga-score.js';
import { serializeScore, parseScore } from '../src/score-library.js';
const project = count => notesToProject(Array.from({ length: count }, (_, i) => ({ startTimeSeconds: i * .3, durationSeconds: .2, pitchMidi: i % 2 ? 40 : 90, amplitude: .7 })));
test('recognition remains blocked until explicit confirmed derivative', () => {
  const original = project(12), snapshot = structuredClone(original);
  assert.throws(() => compileFpgaScore(original));
  assert.throws(() => arrangeAudioMelody(original), /确认/);
  const { project: arranged, report } = arrangeAudioMelody(original, { confirmed: true });
  assert.equal(compileFpgaScore(arranged).length, 24);
  assert.equal(report.folded, 12); assert.deepEqual(original, snapshot);
  const saved = parseScore(serializeScore({ version: 1, id: 'arranged', savedAt: 1, title: '选段', fileName: 'a.mp3', project: arranged, settings: { selectedTracks: [0], speed: 100, velocity: 100 } }));
  assert.deepEqual(saved.project.arrangement, report);
  assert.deepEqual(compileFpgaScore(saved.project).words, compileFpgaScore(arranged).words);
});
test('capacity is rejected without silent truncation; explicit excerpt works', () => {
  const source = project(2400);
  // Fit 2400 notes into the supported 600 s audio window without overlap.
  for (const n of source.tracks[0].notes) { n.startMs *= .8; n.endMs *= .8; }
  assert.throws(() => arrangeAudioMelody(source, { confirmed: true, endSeconds: 600 }), /缩短/);
  const shortSource = project(300);
  assert.equal(arrangeAudioMelody(shortSource, { confirmed: true, startSeconds: 30, endSeconds: 40 }).report.melodyNotes, 34);
  assert.equal(arrangeAudioMelody(shortSource, { confirmed: true }).report.melodyNotes, 300);
});
test('simultaneous notes choose strongest, overlapping durations are clipped', () => {
  const source = notesToProject([
    { startTimeSeconds: 0, durationSeconds: 1, pitchMidi: 60, amplitude: .3 },
    { startTimeSeconds: 0, durationSeconds: 1, pitchMidi: 64, amplitude: .8 },
    { startTimeSeconds: .5, durationSeconds: 1, pitchMidi: 67, amplitude: .8 },
  ]);
  const { project: arranged, report } = arrangeAudioMelody(source, { confirmed: true });
  assert.equal(report.removedSimultaneous, 1); assert.equal(report.shortened, 1);
  assert.equal(arranged.tracks[0].notes[0].note, 64); assert.equal(compileFpgaScore(arranged).length, 4);
});

const recognize = rows => notesToProject(rows.map(([start, end, pitch, amplitude = .8]) =>
  ({ startTimeSeconds: start / 1000, durationSeconds: (end - start) / 1000, pitchMidi: pitch, amplitude })));
const arrange = (rows, options = {}) => arrangeAudioMelody(recognize(rows), { confirmed: true, ...options });
const pitches = result => result.project.tracks[0].notes.map(n => n.note);

test('phrase gain preserves strong-note accents instead of flattening them at 80', () => {
  const source = recognize([[0, 200, 60], [300, 500, 62], [600, 800, 64]]);
  source.tracks[0].notes.forEach((n, i) => { n.velocity = [60, 90, 120][i]; });
  const original = structuredClone(source);
  const result = arrangeAudioMelody(source, { confirmed: true });
  assert.deepEqual(result.project.tracks[0].notes.map(n => n.velocity), [40, 60, 80]);
  assert.equal(result.report.velocityScale, 2 / 3);
  assert.deepEqual(source, original);
  assert.deepEqual(result.project.tracks[0].notes.map(n => [n.startMs,n.endMs]), [[0,200],[300,500],[600,800]]);
  source.tracks[0].notes.forEach((n, i) => { n.velocity = [1, 40, 80][i]; });
  assert.deepEqual(arrangeAudioMelody(source, { confirmed: true }).project.tracks[0].notes.map(n => n.velocity), [1,40,80]);
});
test('near onsets select a coherent melody instead of following a louder changing bass', () => {
  const rows = [[0, 400, 72, .8], [20, 420, 48, .9], [500, 900, 74, .8], [520, 920, 55, .9], [1000, 1400, 76, .8], [1020, 1420, 50, .9]];
  assert.deepEqual(pitches(arrange(rows)), [72, 74, 76]);
  assert.deepEqual(pitches(arrange(rows, { strategy: 'strongest' })), [48, 55, 50]);
  assert.deepEqual(pitches(arrange(rows, { strategy: 'highest' })), [72, 74, 76]);
});
test('weak brief insertions do not cut a sustained melody; filtering is optional', () => {
  const rows = [[0, 900, 72, .9], [300, 420, 50, .3]];
  const result = arrange(rows);
  assert.deepEqual(pitches(result), [72]); assert.equal(result.report.suppressed, 1);
  assert.equal(result.project.tracks[0].notes[0].endMs, 900);
  assert.equal(arrange(rows, { minDurationMs: 150 }).report.filtered, 1);
  const fast = arrange([[0, 20, 60], [30, 50, 62], [60, 80, 64]], { minDurationMs: 0, onsetWindowMs: 0 });
  assert.deepEqual(pitches(fast), [60, 62, 64]);
});
test('overlapping same pitch merges, distinct repeated attacks remain distinct', () => {
  const merged = arrange([[0, 300, 60], [200, 450, 60], [500, 700, 60]], { repeatMode: 'merge' });
  assert.equal(merged.report.merged, 1); assert.deepEqual(pitches(merged), [60, 60]);
  assert.equal(merged.project.tracks[0].notes[0].endMs, 450);
  const adjacent = arrange([[0, 300, 60], [300, 600, 60]]);
  assert.equal(adjacent.report.merged, 0); assert.equal(adjacent.report.melodyNotes, 2);
});
test('onset window is anchored, not transitively chained through a phrase', () => {
  assert.equal(arrange([[0, 100, 60], [30, 130, 62], [60, 160, 64]], { strategy: 'highest' }).report.melodyNotes, 2);
});
test('excerpt includes crossing sustained notes and clips ends to its boundary', () => {
  const notes = arrange([[100, 1300, 60], [1400, 2000, 62]], { startSeconds: 1, endSeconds: 1.8 }).project.tracks[0].notes;
  assert.deepEqual(notes.map(n => [n.startMs, n.endMs]), [[0, 300], [400, 800]]);
});
test('original timing changes only by hardware tick; optional BPM snapping resolves collisions explicitly', () => {
  const notes = arrange([[53, 283, 60], [508, 746, 62]], { onsetWindowMs: 0 }).project.tracks[0].notes;
  for (const [i, [start, end]] of [[53, 283], [508, 746]].entries()) {
    assert.ok(Math.abs(notes[i].startMs - start) <= 3.125);
    assert.ok(Math.abs(notes[i].endMs - end) <= 3.125);
  }
  const snapped = arrange([[10, 100, 60, .5], [50, 140, 62, .8], [510, 740, 64]],
    { rhythm: 'sixteenth', bpm: 120, onsetWindowMs: 0, strategy: 'highest' });
  assert.equal(snapped.report.gridCollisions, 1);
  assert.deepEqual(pitches(snapped), [62, 64]);
  assert.deepEqual(snapped.project.tracks[0].notes.map(n => n.startMs), [0, 500]);
});
test('invalid arrangement parameters are rejected before generation', () => {
  for (const options of [{ bpm: 0 }, { strategy: 'guess' }, { onsetWindowMs: 101 }, { minDurationMs: -1 }, { rhythm: 'auto' }, { startSeconds: 2, endSeconds: 1 }, { repeatMode: 'auto' }, { pitchMode: 'guess' }, { beatOffsetMs: -1 }])
    assert.throws(() => arrange([[0, 200, 60]], options));
});

test('repeated attacks with reverb overlap remain separate by default', () => {
  const result = arrange([[0, 550, 60], [500, 1050, 60], [1000, 1400, 60]]);
  assert.equal(result.report.merged, 0);
  assert.deepEqual(result.project.tracks[0].notes.map(n => [n.startMs, n.endMs]), [[0, 500], [500, 1000], [1000, 1400]]);
  assert.equal(compileFpgaScore(result.project).length, 6);
});

test('melody keeps its onset when accompaniment starts earlier in its cluster', () => {
  const result = arrange([[0, 300, 48, .5], [30, 330, 72, .9]], { strategy: 'highest' });
  assert.equal(result.project.tracks[0].notes[0].startMs, 31.25);
});

test('phrase octave shift preserves ascending intervals across board range boundary', () => {
  const rows = [[0, 200, 81], [300, 500, 83], [600, 800, 84], [900, 1100, 86]];
  const result = arrange(rows);
  assert.deepEqual(pitches(result), [69, 71, 72, 74]);
  assert.equal(result.report.octaveShift, -12);
  assert.equal(result.report.residualFolds, 0);
  assert.deepEqual(pitches(arrange(rows, { pitchMode: 'fold' })), [81, 83, 72, 74]);
  assert.deepEqual(pitches(arrange([[0, 200, 60], [300, 500, 64]])), [60, 64]);
});

test('manual beat phase preserves pickup offset instead of snapping to excerpt start', () => {
  const result = arrange([[80, 300, 60], [580, 800, 62]], { rhythm: 'sixteenth', bpm: 120, beatOffsetMs: 75 });
  assert.deepEqual(result.project.tracks[0].notes.map(n => n.startMs), [75, 575]);
});

test('whole recognition determines default selection; sparse songs can upload beyond 30 seconds', () => {
  const source = recognize([[0, 500, 60], [35000, 35500, 64], [119000, 119500, 67]]);
  source.audioDurationSeconds = 120;
  const result = arrangeAudioMelody(source, { confirmed: true });
  assert.equal(audioSelectionEnd(source), 120);
  assert.equal(result.report.endSeconds, 120);
  assert.deepEqual(pitches(result), [60, 64, 67]);
  assert.equal(compileFpgaScore(result.project).endTick, 19120);
  delete source.audioDurationSeconds;
  assert.equal(audioSelectionEnd(source), 119.5);
});

test('range selection removes bass and high overtones before melody choice without mutating recognition', () => {
  const source = recognize([[0, 400, 48, .95], [0, 400, 72, .8], [0, 400, 96, .9],
    [500, 900, 50, .95], [500, 900, 74, .8], [500, 900, 98, .9]]);
  const snapshot = structuredClone(source);
  const result = arrangeAudioMelody(source, { confirmed: true, minPitch: 60, maxPitch: 84 });
  assert.deepEqual(pitches(result), [72, 74]);
  assert.equal(result.report.outsideRange, 4);
  assert.equal(result.report.folded, 0);
  assert.deepEqual(source, snapshot);
  assert.throws(() => arrangeAudioMelody(source, { confirmed: true, minPitch: 100 }), /没有可用音符/);
});

test('contained weaker bass no longer chops a long melody into accompaniment notes', () => {
  const rows = [[0, 1800, 72, .9], [300, 650, 48, .7], [800, 1200, 52, .7], [1900, 2400, 74, .9]];
  const result = arrange(rows);
  assert.deepEqual(pitches(result), [72, 74]);
  assert.equal(result.project.tracks[0].notes[0].endMs, 1800);
  assert.equal(result.report.sustainedBass, 2);
  assert.deepEqual(pitches(arrange(rows, { protectSustain: false })), [72, 48, 52, 74]);
});

test('sustain guard retains stronger bass attacks, true phrase transitions and repeated notes', () => {
  assert.deepEqual(pitches(arrange([[0, 900, 72, .8], [300, 700, 48, .9]])), [72, 48]);
  assert.deepEqual(pitches(arrange([[0, 900, 72, .9], [700, 1400, 48, .7]])), [72, 48]);
  assert.deepEqual(pitches(arrange([[0, 900, 72, .9], [300, 700, 72, .7]])), [72, 72]);
  assert.deepEqual(pitches(arrange([[0, 900, 72, .9], [300, 700, 48, .7]], { strategy: 'strongest' })), [72, 48]);
});

test('new selection options reject invalid values and survive score archive', () => {
  for (const options of [{ minPitch: -1 }, { maxPitch: 128 }, { minPitch: 72, maxPitch: 60 }, { minPitch: 60.5 }, { protectSustain: 'true' }])
    assert.throws(() => arrange([[0, 200, 60]], options));
  const { project: arranged, report } = arrange([[0, 500, 72], [1000, 1500, 74]], { minPitch: 60, maxPitch: 84, protectSustain: false });
  const saved = parseScore(serializeScore({ version: 1, id: 'range', savedAt: 1, title: 'range', fileName: 'range.mp3', project: arranged,
    settings: { selectedTracks: [0], speed: 100, velocity: 100 } }));
  assert.deepEqual(saved.project.arrangement, report);
});
