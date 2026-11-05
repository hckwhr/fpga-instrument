// Only an accepted input calls hit(). No sequencer or background accompaniment.
export function createRhythmAudio() {
  let context, master;
  const voices = new Map();
  const release = lane => {
    const voice = voices.get(lane);
    if (!voice || !context) return;
    voices.delete(lane);
    voice.gain.gain.cancelAndHoldAtTime(context.currentTime);
    voice.gain.gain.linearRampToValueAtTime(0, context.currentTime + .045);
    voice.osc.stop(context.currentTime + .05);
  };
  return {
    async unlock() {
      if (!context) {
        context = new AudioContext();
        master = context.createGain(); master.gain.value = .32;
        const limiter = context.createDynamicsCompressor();
        master.connect(limiter).connect(context.destination);
      }
      await context.resume();
    },
    hit(note, speed) {
      if (!context || context.state !== 'running') return;
      release(note.lane);
      const osc = context.createOscillator(), gain = context.createGain();
      osc.setPeriodicWave(context.createPeriodicWave(new Float32Array(5), new Float32Array([0, 1, .28, .12, .04])));
      osc.frequency.value = 440 * 2 ** ((note.note - 69) / 12);
      const at = context.currentTime, end = at + Math.max(.025, note.durationMs / speed / 1000);
      gain.gain.setValueAtTime(0, at);
      gain.gain.linearRampToValueAtTime(note.velocity / 127 * .25, at + .006);
      gain.gain.exponentialRampToValueAtTime(.001, end + .05);
      osc.connect(gain).connect(master); osc.start(at); osc.stop(end + .06);
      const voice = { osc, gain }; voices.set(note.lane, voice);
      osc.onended = () => { osc.disconnect(); gain.disconnect(); if (voices.get(note.lane) === voice) voices.delete(note.lane); };
    },
    release,
    silence() { for (const lane of voices.keys()) release(lane); },
    close() { voices.clear(); if (context) void context.close().catch(() => {}); context = null; },
  };
}
