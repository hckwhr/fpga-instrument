// Generated reference, not a downloaded song. Requires ffmpeg only for test fixture encoding.
import { mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const folder = new URL('../evidence/', import.meta.url);
await mkdir(folder, { recursive: true });
const rate = 44100, seconds = 5, bytes = Buffer.alloc(44 + rate * seconds * 2);
bytes.write('RIFF'); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write('WAVEfmt ', 8);
bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(1, 22);
bytes.writeUInt32LE(rate, 24); bytes.writeUInt32LE(rate * 2, 28); bytes.writeUInt16LE(2, 32);
bytes.writeUInt16LE(16, 34); bytes.write('data', 36); bytes.writeUInt32LE(bytes.length - 44, 40);
const score = [[0.2, [60]], [1.3, [64]], [2.4, [67]], [3.5, [60, 64, 67]]];
for (let i = 0; i < rate * seconds; i++) {
  const t = i / rate; let value = 0;
  for (const [at, notes] of score) if (t >= at && t < at + 0.85) {
    const age = t - at;
    const env = Math.min(1, age / 0.01, (0.85 - age) / 0.05) * Math.exp(-age * 0.8);
    for (const note of notes) {
      const phase = 2 * Math.PI * 440 * 2 ** ((note - 69) / 12) * age;
      value += 0.16 * env * (Math.sin(phase) + 0.25 * Math.sin(2 * phase) + 0.1 * Math.sin(3 * phase));
    }
  }
  bytes.writeInt16LE(Math.round(value * 32767), 44 + i * 2);
}
const wav = fileURLToPath(new URL('reference-notes.wav', folder));
const mp3 = fileURLToPath(new URL('reference-notes.mp3', folder));
await writeFile(wav, bytes);
const result = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', wav, '-codec:a', 'libmp3lame', '-b:a', '192k', mp3], { encoding: 'utf8', windowsHide: true });
if (result.status !== 0) throw new Error(result.stderr || result.error?.message);
console.log('Generated reference-notes.mp3: C4, E4, G4, then C4/E4/G4 together.');
const longBytes = Buffer.alloc(44 + rate * 40 * 2);
bytes.copy(longBytes, 0, 0, 44);
longBytes.writeUInt32LE(longBytes.length - 8, 4); longBytes.writeUInt32LE(longBytes.length - 44, 40);
bytes.copy(longBytes, 44, 44); bytes.copy(longBytes, 44 + rate * 33 * 2, 44);
const longWav = fileURLToPath(new URL('reference-long.wav', folder));
await writeFile(longWav, longBytes);
const longResult = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', longWav, '-codec:a', 'libmp3lame', '-b:a', '128k', fileURLToPath(new URL('reference-long.mp3', folder))], { encoding: 'utf8', windowsHide: true });
if (longResult.status !== 0) throw new Error(longResult.stderr || longResult.error?.message);
