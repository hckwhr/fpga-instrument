// Basic Pitch amplitude is mean model activation, not measured loudness.
// Estimate relative dynamics locally from windowed energy at the detected
// fundamental and two harmonics. This is NOT instrument/source separation:
// overlapping harmonics can contribute to more than one recognized note.
export function restoreNoteDynamics(notes, samples, sampleRate) {
  if (!(samples instanceof Float32Array) || !Number.isFinite(sampleRate) || sampleRate <= 0)
    throw new Error('音频力度分析参数无效');
  if (!notes.length || !samples.length) return notes;
  const windows = new Map();
  const strength = note => {
    const duration = note.durationSeconds;
    const frequency = 440 * 2 ** ((note.pitchMidi - 69) / 12);
    if (!Number.isFinite(frequency) || frequency <= 0 || !Number.isFinite(duration) || duration <= 0) return 0;
    // Up to 186 ms for bass resolution; stay inside short notes whenever
    // possible, so the next attack does not set the previous note's velocity.
    const size = Math.min(4096, Math.max(128, Math.floor(duration * sampleRate * .8)));
    if (!windows.has(size)) {
      const weights = Float32Array.from({ length: size }, (_, i) => .5 - .5 * Math.cos(2 * Math.PI * i / (size - 1)));
      windows.set(size, { weights, sum: weights.reduce((a, b) => a + b, 0) });
    }
    const { weights, sum } = windows.get(size);
    const probes = duration * sampleRate > size * 1.5 ? [.25, .5, .75] : [.5];
    const values = probes.map(fraction => {
      const inside = Math.max(size / sampleRate / 2, Math.min(duration - size / sampleRate / 2, duration * fraction));
      const center = Math.round((note.startTimeSeconds + inside) * sampleRate);
      const start = center - Math.floor(size / 2);
      let energy = 0;
      for (const [harmonic, weight] of [[1, 1], [2, .5], [3, .25]]) {
        if (frequency * harmonic >= sampleRate / 2) continue;
        const coefficient = 2 * Math.cos(2 * Math.PI * frequency * harmonic / sampleRate);
        let previous = 0, before = 0;
        for (let i = 0; i < size; i++) {
          const value = (samples[start + i] || 0) * weights[i] + coefficient * previous - before;
          before = previous; previous = value;
        }
        energy += weight * Math.max(0, previous * previous + before * before - coefficient * previous * before);
      }
      return Math.sqrt(energy) * 2 / sum;
    });
    values.sort((a, b) => a - b);
    return values[Math.floor(values.length / 2)];
  };
  const energies = notes.map(strength);
  const sorted = energies.filter(e => e > 1e-9).sort((a, b) => a - b);
  if (!sorted.length) return notes; // Silence/invalid evidence cannot invent new dynamics.
  const reference = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * .95))];
  return notes.map((note, i) => ({ ...note,
    // Modest compression keeps quiet recognized material audible; clip only
    // the top 5% reference peaks. Preserve all detected attacks and durations.
    amplitude: Math.max(.04, Math.min(1, (energies[i] / reference) ** .65)),
  }));
}
