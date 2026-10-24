import * as tf from '@tensorflow/tfjs';
import { setWasmPaths } from '@tensorflow/tfjs-backend-wasm';
import { noteFramesToTime, outputToNotesPoly } from '@spotify/basic-pitch';

// Basic Pitch 1.0.1 framing/output names from Spotify inference.ts.
// Dispose intermediates per window; upstream evaluateModel retains them across the song.
const RATE = 22050, WINDOW = 43844, OVERLAP_HALF = 3840, HOP = 36164;
self.onmessage = async ({ data: { samples, threshold, minNoteMs } }) => {
  let model;
  try {
    self.postMessage({ type: 'progress', stage: 'load', percent: 0 });
    setWasmPaths(new URL('../wasm/', import.meta.url).href);
    await tf.setBackend('wasm'); await tf.ready();
    model = await tf.loadGraphModel(new URL('../model/model.json', import.meta.url).href);
    const frames = [], onsets = [];
    const count = Math.ceil((samples.length + OVERLAP_HALF) / HOP);
    const maxFrames = Math.floor(samples.length * 86 / RATE);
    for (let i = 0; i < count && frames.length < maxFrames; i++) {
      const input = new Float32Array(WINDOW);
      const offset = i * HOP - OVERLAP_HALF;
      const from = Math.max(0, offset), to = Math.min(samples.length, offset + WINDOW);
      input.set(samples.subarray(from, to), from - offset);
      const outputs = tf.tidy(() => {
        const batch = tf.tensor3d(input, [1, WINDOW, 1]);
        const result = model.execute(batch, ['Identity_1', 'Identity_2']);
        return result.map(t => t.slice([0, 15, 0], [1, t.shape[1] - 30, -1]).squeeze([0]));
      });
      try {
        const [f, o] = await Promise.all(outputs.map(t => t.array()));
        const remaining = maxFrames - frames.length;
        frames.push(...f.slice(0, remaining)); onsets.push(...o.slice(0, remaining));
      } finally { outputs.forEach(t => t.dispose()); }
      self.postMessage({ type: 'progress', stage: 'model', percent: (i + 1) / count });
    }
    const notes = noteFramesToTime(outputToNotesPoly(frames, onsets, threshold, threshold, Math.ceil(minNoteMs * 86 / 1000)));
    self.postMessage({ type: 'result', notes });
  } catch (error) {
    self.postMessage({ type: 'error', message: `转谱引擎：${error.message}` });
  } finally { model?.dispose(); }
};
