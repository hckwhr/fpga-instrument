import { readFile, writeFile } from "node:fs/promises";
import { parseMidi } from "../src/midi.js";
import { compileFpgaScore, renderScoreRom } from "../src/fpga-score.js";

// Explicit melody track per slot. Other note tracks are all accompaniment.
const [first, firstTrack, second, secondTrack, output] = process.argv.slice(2);
if (!output || process.argv.length !== 7) {
  console.error("Usage: node tools/export-fpga-score.mjs first.mid melodyTrack second.mid melodyTrack output.v");
  process.exitCode = 1;
} else {
  const scores = [];
  for (const [path, track] of [[first, firstTrack], [second, secondTrack]])
    scores.push(compileFpgaScore(parseMidi(await readFile(path)), { melodyTrack: Number(track) }));
  await writeFile(output, renderScoreRom(scores));
  const report = scores.map(({ words, events, ...metadata }) => metadata);
  await writeFile(`${output}.json`, JSON.stringify(report, null, 2) + "\n");
  console.log(JSON.stringify(report, null, 2));
}
