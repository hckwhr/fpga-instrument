import test from 'node:test';
import assert from 'node:assert/strict';
import { restoreNoteDynamics } from '../src/audio-dynamics.js';

const rate = 22050;
function fixture(levels = [.05, .2]) {
  const samples = new Float32Array(rate * 2);
  const notes = [60, 64].map((pitchMidi, i) => {
    const startTimeSeconds = i + .1, durationSeconds = .7;
    const frequency = 440 * 2 ** ((pitchMidi - 69) / 12);
    for (let j = Math.round(startTimeSeconds * rate); j < Math.floor((startTimeSeconds + durationSeconds) * rate); j++)
      samples[j] = levels[i] * Math.sin(2 * Math.PI * frequency * j / rate);
    return { pitchMidi, startTimeSeconds, durationSeconds, amplitude: .8 };
  });
  return { notes, samples };
}

test('relative audio dynamics replace equal model confidence while preserving attacks', () => {
  const { notes, samples } = fixture();
  const snapshot = structuredClone(notes), original = samples.slice();
  const output = restoreNoteDynamics(notes, samples, rate);
  assert.ok(output[1].amplitude / output[0].amplitude > 2.3);
  assert.ok(output[1].amplitude / output[0].amplitude < 2.7);
  output.forEach((n, i) => assert.deepEqual({ ...n, amplitude: .8 }, notes[i]));
  assert.deepEqual(notes, snapshot);
  assert.deepEqual(samples, original);
});

test('relative dynamics are invariant under whole-recording gain', () => {
  const { notes, samples } = fixture();
  const a = restoreNoteDynamics(notes, samples, rate);
  const b = restoreNoteDynamics(notes, samples.map(x => x * .1), rate);
  a.forEach((n, i) => assert.ok(Math.abs(n.amplitude - b[i].amplitude) < .001));
});

test('equal acoustic levels do not inherit different model confidences', () => {
  const { notes, samples } = fixture([.1, .1]);
  notes[0].amplitude = .4; notes[1].amplitude = .9;
  const output = restoreNoteDynamics(notes, samples, rate);
  assert.ok(Math.abs(output[0].amplitude - output[1].amplitude) < .005);
});

test('short repeated notes and silent evidence cannot be silently merged or erased', () => {
  const { notes, samples } = fixture();
  const repeated = [notes[0], { ...notes[0], startTimeSeconds: .3, durationSeconds: .1 }];
  const output = restoreNoteDynamics(repeated, samples, rate);
  assert.equal(output.length, 2);
  assert.equal(output[1].durationSeconds, .1);
  assert.deepEqual(restoreNoteDynamics(notes, new Float32Array(samples.length), rate), notes);
  assert.deepEqual(restoreNoteDynamics([], samples, rate), []);
  assert.throws(() => restoreNoteDynamics(notes, samples, 0), /参数/);
});
