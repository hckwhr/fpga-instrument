import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { parseMidi } from "../src/midi.js";
import { compileFpgaScore, renderScoreRom } from "../src/fpga-score.js";
import { encodeUploadFrames } from "../src/protocol.js";
const root = new URL("./fixtures/fpga-scores/", import.meta.url);
const load = async (name) => parseMidi(await readFile(new URL(name + ".mid", root)));
test("both complete arranged MIDI songs compile deterministically through shared parser", async () => {
  const scores = [compileFpgaScore(await load("twinkle")), compileFpgaScore(await load("ode"))];
  assert.deepEqual(scores.map(s => [s.length,s.endTick,s.melodyCount,s.maxGroup,s.maxVoices,s.maxVelocity,s.quantizationMs]),
    [[360,9408,84,5,5,228,0],[132,3072,30,9,9,400,0]]);
  for (const score of scores) {
    const active = new Set();
    for (const [i,word] of score.words.entries()) {
      const e=score.events[i];assert.equal(Number(word>>40n),e.tick);
      assert.equal(Number((word>>23n)&65535n),e.id);
      if(e.on) {assert.ok(!active.has(e.id));active.add(e.id);} else {assert.ok(active.delete(e.id));}
    }
    assert.equal(active.size,0);
  }
  assert.equal(scores[0].words[0].toString(16).padStart(16,"0"),"0000008000038100"); // tick 0, ID 0, C4, velocity 96, melody
  assert.match(renderScoreRom(scores),/always @\(posedge clk\) data <= rom/);
});

test("future score upload frames carry fixed words, offsets and CRCs", async () => {
  const score = compileFpgaScore(await load("twinkle"));
  const frames = encodeUploadFrames(score);
  const begin = frames[0].trim().split(",");
  const commit = frames.at(-1).trim().split(",");
  assert.deepEqual(begin.slice(0, 4), ["SONG1", "BEGIN", String(score.words.length), String(score.endTick)]);
  assert.match(begin[4], /^[0-9A-F]{4}$/);
  assert.deepEqual(commit, ["SONG1", "COMMIT", String(score.words.length), begin[4]]);
  const data = frames.slice(1, -1);
  assert.equal(data.length, Math.ceil(score.words.length / 8));
  data.forEach((frame, index) => {
    const fields = frame.trim().split(",");
    assert.equal(fields[0], "SONG1");
    assert.equal(fields[1], "DATA");
    assert.equal(Number(fields[2]), index * 8);
    assert.ok(fields[4].length <= 128 && fields[4].length % 16 === 0);
    assert.match(fields[5], /^[0-9A-F]{4}$/);
    assert.ok(frame.length <= 256);
  });
});
test("compiler rejects unsupported controls, drums, range and collapsed durations", async () => {
  for (const [mutate, error] of [
    [p=>p.tracks[0].warnings.push("unsupported CC"),/unsupported CC/],
    [p=>p.tracks[0].notes[0].channel=9,/鼓轨/],
    [p=>p.tracks[0].notes[0].note=84,/C3/],
    [p=>p.tracks[0].notes[0].endMs=0.1,/量化/],
  ]) {const p=await load("ode");mutate(p);assert.throws(()=>compileFpgaScore(p),error);}
});
test("admission counts release tails and velocity headroom, never silently drops", async () => {
  const p=await load("ode");
  const n={...p.tracks[1].notes[0],startMs:0,endMs:6.25,velocity:20};
  p.tracks[1].notes=Array.from({length:16},(_,i)=>({...n,order:i}));
  assert.throws(()=>compileFpgaScore(p),/声部/);
  p.tracks[1].notes=Array.from({length:6},(_,i)=>({...n,velocity:127,order:i}));
  assert.throws(()=>compileFpgaScore(p),/音量/);
  p.tracks[1].notes=Array.from({length:8},(_,i)=>({...n,endMs:100,order:i})).concat(
    Array.from({length:8},(_,i)=>({...n,startMs:100,endMs:200,order:i+8})));
  // A melody plus two sets of eight overlap within the conservative tail window.
  assert.throws(()=>compileFpgaScore(p),/声部/);
});
test("maximum envelope release fits the six-tick reservation at 150 BPM", () => {
  let gain=4080,samples=0;while(gain>0){gain=Math.max(0,gain-(gain>>8)-1);samples++;}
  assert.ok(samples<1200);console.log(`maximum release: ${samples} samples`);
});
test("tempo changes survive ms conversion and channel features are reported", () => {
  const bytes=Buffer.from([77,84,104,100,0,0,0,6,0,0,0,1,0,96,
    77,84,114,107,0,0,0,27,0,144,60,80,96,128,60,0,
    0,255,81,3,15,66,64,0,144,62,80,96,128,62,0,0,255,47,0]);
  const p=parseMidi(bytes),s=compileFpgaScore(p);
  assert.deepEqual(s.events.map(e=>e.tick),[0,80,80,240]);
  const changed=Buffer.from(bytes);changed[23]=176; // CC instead of note-on
  assert.throws(()=>compileFpgaScore(parseMidi(changed)),/未实现 MIDI/);
  for (const [mutate, error] of [
    [b=>b[24]=128,/invalid channel data/],
    [b=>b.fill(0,34,37),/invalid tempo/],
    [b=>b[33]=2,/invalid tempo/],
    [b=>b[11]=2,/invalid MIDI track count/],
  ]) {
    const bad=Buffer.from(bytes);mutate(bad);
    assert.throws(()=>parseMidi(bad),error);
  }
});
