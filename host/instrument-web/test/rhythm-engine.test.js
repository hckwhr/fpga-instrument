import test from 'node:test';
import assert from 'node:assert/strict';
import { buildRhythmChart, demoRhythmEvents, RhythmGame } from '../src/rhythm-engine.js';

const note = (pitch = 60, startMs = 0, durationMs = 300) => ({ note: pitch, startMs, durationMs, velocity: 100 });
const make = (notes, options) => new RhythmGame(buildRhythmChart(notes), options);

test('chart preserves pitch, velocity and rhythm without mutating source', () => {
  const events = [note(67, 500), note(60, 0)], saved = structuredClone(events);
  const chart = buildRhythmChart(events);
  assert.deepEqual(chart.pitches, [60, 67]); assert.equal(chart.notes[1].startMs, 500);
  assert.deepEqual(events, saved);
});
test('more than twelve distinct pitches fails explicitly, not silent octave folding', () => {
  assert.throws(() => buildRhythmChart(Array.from({ length: 13 }, (_, i) => note(60 + i, i * 500))), /超过 12 键/);
});
test('invalid scores and settings are rejected', () => {
  for (const events of [[], [note(NaN)], [note(128)], [note(60, -1)], [note(60, 0, 0)], [{ ...note(), velocity: Infinity }]]) assert.throws(() => buildRhythmChart(events));
  assert.throws(() => make([note()], { speed: 0 })); assert.throws(() => make([note()], { mode: 'auto' }));
});
test('unison across tracks merges once with an explicit count and longest duration', () => {
  const chart = buildRhythmChart([note(), { ...note(60, 0, 500), velocity: 80 }]);
  assert.equal(chart.merged, 1); assert.equal(chart.notes.length, 1);
  assert.equal(chart.notes[0].durationMs, 500); assert.equal(chart.notes[0].velocity, 100);
});
test('practice freezes indefinitely at the next note, with no automatic hits', () => {
  const g = make([note(), note(64, 500)]); g.start(0); g.advance(60000);
  assert.equal(g.time, 0); assert.equal(g.points, 0); assert.deepEqual(g.results, [null, null]);
  assert.equal(g.press(0, 60000).judgement, 'hit'); g.advance(90000);
  assert.equal(g.time, 500); assert.equal(g.results[1], null);
});
test('practice chords wait for every chord member and cannot hit a future note', () => {
  const g = make([note(), note(64), note(67, 500)]); g.start(0); g.advance(2000);
  assert.equal(g.press(0, 2000).judgement, 'hit'); g.advance(3000); assert.equal(g.time, 0);
  assert.equal(g.press(2, 3000).judgement, 'wrong');
  assert.equal(g.press(1, 3000).judgement, 'hit'); g.advance(3500); assert.equal(g.time, 500);
});
test('holding a key never retriggers repeated pitches; release is required', () => {
  const g = make([note(), note(60, 500)]); g.start(0); g.advance(2000); g.press(0, 2000);
  g.advance(2500); assert.equal(g.press(0, 2500), null); assert.equal(g.points, 100);
  g.release(0); assert.equal(g.press(0, 2500).judgement, 'hit'); assert.equal(g.points, 200);
});
test('early held key must be released and pressed again at the cue', () => {
  const g = make([note()]); g.start(0);
  assert.equal(g.press(0, 1000).judgement, 'wrong'); g.advance(2000);
  assert.equal(g.press(0, 2000), null); g.release(0); assert.equal(g.press(0, 2000).judgement, 'hit');
});
test('challenge timing windows use real milliseconds at all speed settings', () => {
  for (const speed of [.5, 1, 1.5]) for (const [offset, verdict] of [[-160,'good'],[-70,'perfect'],[0,'perfect'],[70,'perfect'],[160,'good']]) {
    const g = make([note()], { mode: 'challenge', speed }); g.start(0);
    assert.equal(g.press(0, 2000 + offset).judgement, verdict, `${speed}/${offset}`);
  }
});
test('missed notes remain silent and break combo, including a long clock gap', () => {
  const g = make([note(), note(62, 500), note(64, 1000)], { mode: 'challenge' });
  g.start(0); g.press(0, 2000); g.advance(20000);
  assert.deepEqual(g.results, ['perfect', 'miss', 'miss']); assert.equal(g.points, 100); assert.equal(g.combo, 0); assert.equal(g.status, 'finished');
});
test('wrong pitch is not accepted, and the right note remains pending', () => {
  const g = make([note(), note(64, 500)], { mode: 'challenge' }); g.start(0);
  assert.equal(g.press(1, 2000).judgement, 'wrong'); assert.equal(g.results[0], null);
  assert.equal(g.press(0, 2000).judgement, 'perfect');
});
test('challenge chord accepts every simultaneous note exactly once', () => {
  const g = make([note(), note(64), note(67)], { mode: 'challenge' }); g.start(0);
  for (const lane of [2, 0, 1]) assert.equal(g.press(lane, 2000).judgement, 'perfect');
  assert.equal(g.points, 300); assert.equal(g.bestCombo, 3); assert.equal(g.accuracy, 100);
});
test('pause/resume excludes background time and clears held inputs', () => {
  const g = make([note(), note(62, 1000)], { mode: 'challenge' }); g.start(0); g.press(0, 2000); g.pause(2100);
  assert.equal(g.status, 'paused'); assert.equal(g.held.size, 0); g.advance(100000); assert.equal(g.time, 100);
  g.start(100000); g.advance(100900); assert.equal(g.time, 1000); assert.equal(g.press(1, 100900).judgement, 'perfect');
});
test('reset clears score, misses and held keys and restores the countdown', () => {
  const g = make([note()], { mode: 'challenge' }); g.start(0); g.press(0, 2000); g.reset();
  assert.equal(g.status, 'ready'); assert.equal(g.time, -2000); assert.equal(g.points, 0); assert.equal(g.held.size, 0); assert.deepEqual(g.results, [null]);
});
test('a whole practice phrase can finish, but never by waiting without input', () => {
  const g = make(demoRhythmEvents('twinkle')); g.start(0); let now = 2000;
  for (const n of g.chart.notes) { now += 1000; g.advance(now); assert.equal(g.press(n.lane, now).judgement, 'hit'); g.release(n.lane); }
  g.advance(now + 2000); assert.equal(g.status, 'finished'); assert.equal(g.accuracy, 100);
});
test('input is ignored before start, while paused, after finish, and for unused lanes', () => {
  const g = make([note()], { mode: 'challenge' }); assert.equal(g.press(0, 0), null);
  g.start(0); assert.equal(g.press(11, 100), null); g.pause(100); assert.equal(g.press(0, 2000), null);
  g.start(3000); g.advance(10000); assert.equal(g.press(0, 10000), null);
});
test('clock regressions are rejected rather than changing rhythm backwards', () => {
  const g = make([note()]); g.start(100); assert.throws(() => g.advance(99), /单调/);
});
