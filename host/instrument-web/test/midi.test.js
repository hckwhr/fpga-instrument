import test from "node:test";
import assert from "node:assert/strict";
import { analyzeEvents, compileTracks, midiNoteName, parseMidi } from "../src/midi.js";
import { encodePreviewFrames, serializeCsv, serializeJsonl } from "../src/protocol.js";

const vlq = (value) => {
  const result = [value & 0x7f];
  while ((value >>= 7)) result.unshift((value & 0x7f) | 0x80);
  return result;
};
const chunk = (tag, data) => [...tag].map((char) => char.charCodeAt(0)).concat([(data.length >>> 24) & 255, (data.length >>> 16) & 255, (data.length >>> 8) & 255, data.length & 255], data);
const track = (data) => chunk("MTrk", data);
const midiFixture = () => {
  const tempo = [0, 0xff, 0x51, 3, 0x07, 0xa1, 0x20, 0, 0xff, 0x2f, 0];
  // C4 for one quarter, then overlapping E4/G4 for one quarter. The last
  // note uses running status and note-on velocity zero as note-off.
  const notes = [
    ...vlq(0), 0x90, 60, 96,
    ...vlq(480), 60, 0,
    ...vlq(0), 0x90, 64, 80,
    ...vlq(0), 67, 72,
    ...vlq(480), 64, 0,
    ...vlq(0), 67, 0,
    ...vlq(0), 0xff, 0x2f, 0,
  ];
  const header = [..."MThd"].map((char) => char.charCodeAt(0)).concat([0, 0, 0, 6, 0, 1, 0, 2, 1, 0xe0]);
  return new Uint8Array(header.concat(track(tempo), track(notes)));
};

test("parses tempo map, running status, note-on-zero and overlapping notes", () => {
  const project = parseMidi(midiFixture());
  assert.equal(project.format, 1);
  assert.equal(project.tracks[1].notes.length, 3);
  assert.equal(project.tracks[1].notes[0].startMs, 0);
  assert.equal(project.tracks[1].notes[0].durationMs, 500);
  assert.equal(project.tracks[1].notes[1].startMs, 500);
  assert.equal(project.tracks[1].notes[2].startMs, 500);
  assert.equal(midiNoteName(60), "C4");
});

test("compiles selected tracks deterministically and reports polyphony", () => {
  const project = parseMidi(midiFixture());
  const events = compileTracks(project, [1], { speed: 2, velocityScale: 0.5 });
  assert.deepEqual(events.map((event) => [event.startMs, event.deltaMs, event.noteName, event.velocity]), [[0, 0, "C4", 48], [250, 250, "E4", 40], [250, 0, "G4", 36]]);
  assert.deepEqual(analyzeEvents(events), { count: 3, durationMs: 500, maxPolyphony: 2, peakAtMs: 250, over32: false });
});

test("serializers produce explicit headers and line-bounded upload frames", () => {
  const events = [{ startMs: 0, deltaMs: 0, note: 60, noteName: "C4", velocity: 96, durationMs: 500, channel: 0, track: 1 }];
  assert.match(serializeCsv(events), /^delta_ms,note,velocity,duration_ms,channel,track\n0,C4,96,500,0,1\n$/);
  assert.equal(JSON.parse(serializeJsonl(events).split("\n")[0]).version, 1);
  assert.match(encodePreviewFrames(events)[0], /^SONG,BEGIN,1,1\n$/);
  assert.match(encodePreviewFrames(events)[1], /,[0-9A-F]{4}\n$/);
});

test("rejects SMPTE timing instead of silently changing song tempo", () => {
  const bytes = midiFixture();
  bytes[12] = 0x80;
  assert.throws(() => parseMidi(bytes), /SMPTE/);
});
