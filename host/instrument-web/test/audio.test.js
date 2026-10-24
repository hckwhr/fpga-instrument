import test from 'node:test';
import assert from 'node:assert/strict';
import { notesToProject, transcribeAudioFile, scorePreviewEvents } from '../src/audio.js';
import { compileTracks } from '../src/midi.js';
import { compileSelectedFpgaScore } from '../src/fpga-score.js';

test('transcription clips notes to audio duration, rejects invalid values and compiles into FPGA events', () => {
  const n = (startTimeSeconds, durationSeconds, pitchMidi, amplitude = 0.5) => ({ startTimeSeconds, durationSeconds, pitchMidi, amplitude });
  const project = notesToProject([n(1, 2, 64), n(-0.02, 0.5, 60), n(4, 1, 70), n(0, -1, 60), n(0, 1, NaN), n(0, 1, 128), n(0, 1, 60, 0)], 'reference', 2);
  const result = compileTracks(project, [0]);
  assert.deepEqual(result.map(n => [n.startMs, n.durationMs, n.note, n.velocity]), [[0, 480, 60, 64], [1000, 1000, 64, 64]]);
  assert.ok(project.tracks[0].warnings.length);
});
test('rejects proprietary audio and lyrics before decoding', async () => {
  await assert.rejects(transcribeAudioFile({ name: 'song.NCM', size: 100 }), /专属格式/);
  await assert.rejects(transcribeAudioFile({ name: 'song.lrc', size: 100 }), /歌词/);
});

test('upload preview matches encoded score ticks, pitch and velocity after speed scaling', () => {
  const project = notesToProject([
    { startTimeSeconds: .053, durationSeconds: .231, pitchMidi: 60, amplitude: .5 },
    { startTimeSeconds: .508, durationSeconds: .239, pitchMidi: 64, amplitude: .8 },
  ]);
  project.tracks[0].warnings = [];
  const score = compileSelectedFpgaScore(project, [0], { melodyTrack: 0, speed: 1.25, velocityScale: .75 });
  const events = scorePreviewEvents(score);
  const ons = score.words.filter(w => (w >> 39n & 1n) === 1n);
  assert.equal(events.length, ons.length);
  events.forEach((n, i) => {
    assert.equal(n.startMs, Number(ons[i] >> 40n) * 6.25);
    assert.equal(n.velocity, Number(ons[i] >> 10n & 127n));
    assert.equal(n.note, 48 + Number(ons[i] >> 17n & 3n) * 12 + Number(ons[i] >> 19n & 15n));
    const id = ons[i] >> 23n & 65535n;
    const off = score.words.find(w => (w >> 39n & 1n) === 0n && (w >> 23n & 65535n) === id);
    assert.equal(n.startMs + n.durationMs, Number(off >> 40n) * 6.25);
  });
});
