// Offline comparison of a user's existing recognition result. Does not run the
// model, access player profiles, connect to BLE, or publish music/recordings.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { arrangeInstrumentalScore, arrangeAudioMelody, INSTRUMENTAL_ARRANGEMENT_DEFAULTS } from '../src/audio-arrangement.js';
import { compileFpgaScore, compileSelectedFpgaScore } from '../src/fpga-score.js';
import { serializeScore, parseScore } from '../src/score-library.js';
import assert from 'node:assert/strict';

const [input, destination] = process.argv.slice(2);
if (!input || !destination) throw new Error('Usage: node tools/evaluate-arrangement.mjs recognition.json output-directory');
const source = JSON.parse(await readFile(resolve(input), 'utf8'));
const output = resolve(destination);
await mkdir(output, { recursive: true });
const sourceSnapshot = JSON.stringify(source);
const notes = project => project.tracks.flatMap(t => t.notes);
function summary(result) {
  const compiled = compileFpgaScore(result.project);
  return { ...result.report, events: compiled.length, maxVoicesIncludingTails: compiled.maxVoices,
    maxVelocityIncludingTails: compiled.maxVelocity, lastReleaseSeconds: compiled.endTick * .00625,
    summedNoteDurationSeconds: notes(result.project).reduce((sum, n) => sum + n.endMs - n.startMs, 0) / 1000 };
}
const old = arrangeAudioMelody(source, { ...INSTRUMENTAL_ARRANGEMENT_DEFAULTS, confirmed: true });
const current = arrangeInstrumentalScore(source, { confirmed: true });
const excerpt = arrangeInstrumentalScore(source, { confirmed: true, endSeconds: 30 });
const results = { wholeSong: { before: summary(old), after: summary(current) }, first30Seconds: summary(excerpt) };
assert.equal(JSON.stringify(source), sourceSnapshot);
for (const [name, result] of [['whole-song', current], ['first-30-seconds', excerpt]]) {
  const selectedTracks = result.project.tracks.map((_, i) => i).filter(i => result.project.tracks[i].notes.length);
  const archive = serializeScore({ version: 1, id: `instrumental-${name}`, savedAt: Date.now(),
    title: result.project.title, fileName: 'recognition-result', project: result.project,
    settings: { selectedTracks, speed: 100, velocity: 100 } });
  const restored = parseScore(archive);
  assert.deepEqual(compileFpgaScore(restored.project).words, compileFpgaScore(result.project).words);
  compileSelectedFpgaScore(restored.project, selectedTracks, { melodyTrack: 0, velocityScale: 1.25 });
  await writeFile(resolve(output, `${name}.fpga-score.json`), archive);
}
await writeFile(resolve(output, 'comparison.json'), JSON.stringify(results, null, 2) + '\n');
console.log(JSON.stringify(results, null, 2));
