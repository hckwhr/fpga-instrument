import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { ScoreLibrary, LIBRARY_KEY, serializeScore, parseScore } from '../src/score-library.js';
import { parseMidi, compileTracks } from '../src/midi.js';
import { notesToProject } from '../src/audio.js';

const midi = parseMidi(await readFile(new URL('./fixtures/fpga-scores/twinkle.mid', import.meta.url)));
const source = () => ({ title: '小星星', fileName: 'twinkle.mid', project: midi,
  settings: { selectedTracks: [0], speed: 125, velocity: 75 } });
function fixture() {
  const values = new Map();
  const storage = { getItem: k => values.get(k) ?? null, setItem: (k, v) => values.set(k, v) };
  return { values, storage, library: new ScoreLibrary(storage) };
}
test('MIDI snapshot restores source notes and settings without scaling twice', () => {
  const { library, storage } = fixture();
  const saved = library.save(source());
  const restored = new ScoreLibrary(storage).list()[0];
  assert.equal(restored.id, saved.id);
  assert.deepEqual(restored.settings, source().settings);
  const options = { speed: 1.25, velocityScale: 0.75 };
  assert.deepEqual(compileTracks(restored.project, [0], options), compileTracks(midi, [0], options));
  assert.equal(library.list().length, 1);
  library.save({ ...source(), title: '更新的标题' }, saved.id);
  assert.equal(library.list().length, 1);
  assert.equal(library.list()[0].title, '更新的标题');
});
test('audio snapshot keeps warnings, partial flag, and independent source notes', () => {
  const { library } = fixture();
  const project = notesToProject([{ startTimeSeconds: 0.1, durationSeconds: 0.5, pitchMidi: 60, amplitude: 0.8 }]);
  project.partial = true;
  const saved = library.save({ ...source(), project });
  project.tracks[0].notes[0].note = 90;
  const restored = parseScore(serializeScore(saved));
  assert.equal(restored.project.tracks[0].notes[0].note, 60);
  assert.deepEqual(restored.project.tracks[0].warnings, project.tracks[0].warnings);
  assert.equal(restored.project.partial, true);
});
test('remove supports undo without overwriting a newer same-id record', () => {
  const { library } = fixture();
  const saved = library.save(source());
  const removed = library.remove(saved.id);
  assert.equal(library.list().length, 0);
  library.restore(removed);
  assert.deepEqual(library.list(), [saved]);
  assert.throws(() => library.restore(removed), /已存在/);
});
test('storage quota failure preserves previous snapshot and reports failure', () => {
  const { library, storage, values } = fixture();
  const saved = library.save(source());
  const original = values.get(LIBRARY_KEY);
  storage.setItem = () => { throw new Error('quota'); };
  assert.throws(() => library.save({ ...source(), title: 'bad update' }, saved.id), /保存失败/);
  assert.equal(values.get(LIBRARY_KEY), original);
});
test('corrupt and unsupported stored data are never overwritten by a save', () => {
  for (const raw of ['{broken', '{"version":2,"scores":[]}', '{"version":1,"scores":[null]}']) {
    const { library, values } = fixture(); values.set(LIBRARY_KEY, raw);
    assert.throws(() => library.save(source()), /曲谱库/);
    assert.equal(values.get(LIBRARY_KEY), raw);
  }
});
test('backup import rejects invalid versions, notes, settings and oversized input', () => {
  const { library } = fixture();
  const score = library.save(source());
  for (const mutate of [
    s => { s.version = 2; }, s => { s.project.tracks[0].notes[0].note = 128; },
    s => { s.project.tracks[0].notes[0].endMs = -1; }, s => { s.settings.speed = 0; },
    s => { s.settings.selectedTracks = [999]; }, s => { s.title = ''; },
  ]) {
    const bad = structuredClone(score); mutate(bad);
    assert.throws(() => parseScore(JSON.stringify(bad)), /曲谱库/);
  }
  assert.throws(() => parseScore(' '.repeat(2 * 1024 * 1024 + 1)), /过大/);
});
test('two library instances read current storage before changing it; capacity is bounded', () => {
  const { library, storage } = fixture();
  const second = new ScoreLibrary(storage);
  library.save(source()); second.save(source());
  assert.equal(library.list().length, 2);
  for (let n = 2; n < 20; n++) library.save(source());
  assert.throws(() => second.save(source()), /20 首/);
  assert.equal(library.list().length, 20);
});
