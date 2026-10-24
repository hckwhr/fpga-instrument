import test from 'node:test';
import assert from 'node:assert/strict';
import { notesToProject } from '../src/audio.js';
import { arrangeInstrumentalScore, arrangeAudioMelody } from '../src/audio-arrangement.js';
import { compileFpgaScore, compileSelectedFpgaScore } from '../src/fpga-score.js';
import { serializeScore, parseScore } from '../src/score-library.js';

const source = rows => notesToProject(rows.map(([start, end, pitch, amplitude = .8]) =>
  ({ startTimeSeconds: start / 1000, durationSeconds: (end - start) / 1000, pitchMidi: pitch, amplitude })));
const arrange = (rows, options = {}) => arrangeInstrumentalScore(source(rows), { confirmed: true, ...options });
const allNotes = result => result.project.tracks.flatMap(t => t.notes).sort((a, b) => a.startMs - b.startMs || a.note - b.note);

test('default keeps chords, full sustains and native pitches without display duplication', () => {
  const input = source([[0, 2000, 60], [0, 1500, 64], [0, 1000, 67], [500, 800, 69]]);
  const snapshot = structuredClone(input);
  const result = arrangeInstrumentalScore(input, { confirmed: true });
  assert.deepEqual(input, snapshot);
  assert.equal(result.report.mode, 'polyphonic');
  assert.equal(result.report.melodyNotes, 4);
  assert.equal(result.report.shortened, 0);
  assert.equal(result.report.folded, 0);
  assert.deepEqual(allNotes(result).map(n => [n.note, n.startMs, n.endMs]),
    [[60, 0, 2000], [64, 0, 1500], [67, 0, 1000], [69, 500, 800]]);
  const score = compileFpgaScore(result.project);
  assert.equal(score.maxVoices, 4);
  assert.equal(score.length, 8);
  assert.equal(score.melodyCount, result.report.guideNotes);
  for (const [i, track] of result.project.tracks.entries())
    track.notes.forEach((n, order) => { assert.equal(n.track, i); assert.equal(n.order, order); });
});

test('out-of-range registers cannot transpose native melody or reverse its contour', () => {
  const result = arrange([[0, 500, 31], [0, 500, 43], [1000, 1500, 77], [2000, 2500, 69], [3000, 3500, 84]]);
  assert.deepEqual(allNotes(result).map(n => n.note), [55, 67, 77, 69, 72]);
  assert.equal(result.report.lowOctaveShift, 24);
  assert.equal(result.report.highOctaveShift, -12);
  assert.equal(result.report.folded, 3);
  const wide = arrange([[0, 500, 0], [1000, 1500, 12], [2000, 2500, 47], [3000, 3500, 60]]);
  assert.ok(wide.report.pitchOmitted > 0, 'Too-wide bass is reported, not individually wrapped');
});

test('same pitch repeated attacks retain separate IDs and independent OFFs by default', () => {
  const rows = [[0, 1000, 60], [250, 750, 60]];
  const score = compileFpgaScore(arrange(rows).project);
  assert.equal(score.length, 4);
  assert.equal(score.maxVoices, 2);
  assert.deepEqual(score.events.filter(e => !e.on).map(e => [e.id, e.tick]), [[1, 120], [0, 160]]);
  const merged = arrange(rows, { repeatMode: 'merge' });
  assert.equal(merged.report.merged, 1);
  assert.equal(merged.report.melodyNotes, 1);
  assert.equal(allNotes(merged)[0].endMs, 1000);
});

test('same-pitch onset dedup prefers unchanged native note and discloses removal', () => {
  const result = arrange([[0, 500, 36, .9], [0, 1000, 48, .7]]);
  assert.equal(result.report.removedSimultaneous, 1);
  assert.equal(result.report.folded, 0);
  assert.equal(allNotes(result)[0].endMs, 1000);
});

test('quantization, clipping and explicit excerpt retain positive full note durations', () => {
  const result = arrange([[0, 2000, 60], [1000, 1500, 64], [1500, 2500, 67]], { startSeconds: .5, endSeconds: 1.6 });
  assert.deepEqual(allNotes(result).map(n => [n.startMs, n.endMs]), [[0, 1100], [500, 1000], [1000, 1100]]);
  compileFpgaScore(result.project);
});

test('capacity keeps the ending and onset coverage rather than truncating the song', () => {
  const rows = Array.from({ length: 1100 }, (_, i) => [[i * 300, i * 300 + 100, 60], [i * 300, i * 300 + 100, 67]]).flat();
  const result = arrange(rows);
  assert.equal(result.report.melodyNotes, 2048);
  assert.equal(result.report.capacityOmitted, 152);
  assert.equal(new Set(allNotes(result).map(n => n.startMs)).size, 1100);
  assert.equal(Math.max(...allNotes(result).map(n => n.endMs)), 329800);
  assert.equal(compileFpgaScore(result.project).length, 4096);
  assert.throws(() => arrange(Array.from({ length: 2049 }, (_, i) => [i * 200, i * 200 + 100, 60])), /缩短选段/);
});

test('dense chords obey event groups and tail occupancy, reporting all omissions', () => {
  const chord = Array.from({ length: 20 }, (_, i) => [0, 1000, 48 + i]);
  const result = arrange(chord);
  assert.equal(result.report.densityOmitted, 4);
  assert.equal(compileFpgaScore(result.project).maxGroup, 16);
  const tails = arrange([...Array.from({ length: 16 }, (_, i) => [0, 100, 48 + i]), [106.25, 200, 72]]);
  assert.ok(tails.report.densityOmitted > 0);
  assert.ok(compileFpgaScore(tails.project).maxVoices <= 16);
  const released = arrange([...Array.from({ length: 16 }, (_, i) => [0, 100, 48 + i]), [137.5, 200, 72]]);
  assert.equal(released.report.densityOmitted, 0);
});

test('polyphonic amplitude leaves room for UI 125% velocity without admission failure', () => {
  const result = arrange(Array.from({ length: 16 }, (_, i) => [0, 1000, 48 + i, 1]));
  const score = compileSelectedFpgaScore(result.project, [0, 1], { melodyTrack: 0, velocityScale: 1.25 });
  assert.ok(score.maxVelocity <= 768);
  assert.equal(score.maxVoices, 16);
});

test('polyphonic archive round trip retains both tracks, report and identical event words', () => {
  const result = arrange([[0, 1000, 60], [0, 2000, 64], [500, 1500, 67]]);
  const snapshot = { version: 1, id: 'poly', savedAt: 1, title: '复音', fileName: 'a.mp3', project: result.project,
    settings: { selectedTracks: [0, 1], speed: 100, velocity: 100 } };
  const restored = parseScore(serializeScore(snapshot));
  assert.deepEqual(restored.project.arrangement, result.report);
  assert.deepEqual(compileFpgaScore(restored.project).words, compileFpgaScore(result.project).words);
  snapshot.project.arrangement.guideNotes++;
  assert.throws(() => serializeScore(snapshot), /统计/);
});

test('explicit melody compatibility is byte-identical to the existing arranger', () => {
  const input = source([[0, 1000, 60], [0, 1000, 64], [500, 1500, 67]]);
  const options = { confirmed: true, onsetWindowMs: 20, minDurationMs: 60 };
  assert.deepEqual(compileFpgaScore(arrangeInstrumentalScore(input, { ...options, mode: 'melody' }).project).words,
    compileFpgaScore(arrangeAudioMelody(input, options).project).words);
});

test('polyphonic admission requires confirmation and validated settings', () => {
  const input = source([[0, 500, 60]]);
  assert.throws(() => arrangeInstrumentalScore(input), /确认/);
  for (const options of [{ mode: 'unknown' }, { minPitch: 84, maxPitch: 48 }, { startSeconds: 2, endSeconds: 1 },
    { rhythm: 'unknown' }, { bpm: NaN }, { pitchMode: 'unknown' }, { repeatMode: 'unknown' }, { onsetWindowMs: -1 }])
    assert.throws(() => arrangeInstrumentalScore(input, { confirmed: true, ...options }), /参数/);
  assert.throws(() => arrange([[0, 500, 60]], { minPitch: 80 }), /没有可用/);
});
