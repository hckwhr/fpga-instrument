// No FPGA model or synthetic ACK: compile against frozen historical stage59b RTL.
// BLE radio/ESP-IDF task scheduling/board electrical behavior remain untested.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, copyFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { compileFpgaScore } from '../src/fpga-score.js';
import { encodeScoreRequest, prepareScoreUpload, parseScoreReply } from '../src/score-upload-protocol.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const source = resolve(root, 'tests/reference/stage59b');
const output = resolve(root, 'artifacts/ext4_stage60_20261019');
// ModelSim's library database cannot handle the Chinese workspace path.
// Keep the accepted FPGA build untouched and use a separate ASCII simulation tree.
const build = resolve(process.env.V3_OFFLINE_BUILD_ROOT || 'E:/Gowin/workspace/v3_ext4_stage60_20261019');
const modelSim = process.env.MODELSIM_BIN || 'E:/modelsim/win64';
const bridge = resolve(root, 'firmware/esp32s3-bridge/build-host/Debug/bridge_tests.exe');
assert(existsSync(bridge), 'Run python firmware/esp32s3-bridge/tests/run.py first');
mkdirSync(output, { recursive: true });
function run(exe, args, input, name, cwd = build) {
  const result = spawnSync(exe, args, { cwd, input, encoding: 'utf8', windowsHide: true,
    timeout: 600000, maxBuffer: 16 * 1024 * 1024 });
  const log = (result.stdout || '') + (result.stderr || '');
  writeFileSync(resolve(output, `${name}.log`), log);
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${name} failed: ${log.slice(-4000)}`);
  return log;
}
const note = (pitch, startMs, endMs, track, order) => ({ note: pitch, startMs, endMs, track, order, velocity: 72, channel: 0 });
const score = compileFpgaScore({ title: '脱机和弦与灯光验收', tracks: [
  { warnings: [], notes: [note(60, 0, 25, 0, 0), note(62, 37.5, 62.5, 0, 1)] },
  { warnings: [], notes: [note(64, 0, 25, 1, 0), note(67, 0, 25, 1, 1)] },
] });
assert.equal(score.length, 8);
const sid = '2026101900000060';
const plan = prepareScoreUpload(score, { abi: 12, words: 512, chunkWords: 8 });
const operations = [{ operation: 'CAPS', fields: [] }, ...plan.requests,
  { operation: 'PLAY', fields: [score.length, plan.crc, 1] }, { operation: 'STATUS', fields: [] }];
const requests = operations.map((r, i) => encodeScoreRequest(sid, i, r.operation, r.fields));
const hex = s => Buffer.from(s).toString('hex');
mkdirSync(build, { recursive: true });
mkdirSync(resolve(build, 'rtl'), { recursive: true });
for (const entry of readdirSync(resolve(source, 'rtl'), { withFileTypes: true })) {
  if (entry.isFile()) copyFileSync(resolve(source, 'rtl', entry.name), resolve(build, 'rtl', entry.name));
}
copyFileSync(resolve(root, 'host/instrument-web/tools/tb_ext4_v3_offline.sv'), resolve(build, 'tb_ext4_v3_offline.sv'));

// Exercise the production C bridge's complete-line buffering before giving its
// UART bytes to RTL. Draining each frame preserves the actual queue contract.
const commands = [];
for (const request of requests) {
  for (let i = 0; i < request.length; i += 20) commands.push(`B ${hex(request.slice(i, i + 20))}`);
  commands.push('W');
}
const forwarded = run(bridge, ['--pipe'], commands.join('\n') + '\n', 'bridge_requests');
const uartRequests = forwarded.split(/\r?\n/).filter(l => l.startsWith('W '))
  .map(l => Buffer.from(l.slice(2), 'hex').toString());
assert.deepEqual(uartRequests, requests);
assert(forwarded.split(/\r?\n/).filter(l => l.startsWith('R ')).every(l => l === 'R 0'));
writeFileSync(resolve(output, 'requests.txt'), uartRequests.join(''));
writeFileSync(resolve(output, 'score.hex'), score.words.map(w => w.toString(16).padStart(16, '0')).join('\n') + '\n');
for (const file of ['requests.txt', 'score.hex']) copyFileSync(resolve(output, file), resolve(build, file));

const lib = 'modelsim';
if (!existsSync(resolve(build, 'modelsim/_info'))) run(resolve(modelSim, 'vlib.exe'), [lib], undefined, 'vlib');
const project = readFileSync(resolve(source, 'fpga_instrument_av.gprj'), 'utf8');
const files = [...project.matchAll(/<File\s+path="([^"]+)"\s+type="file.verilog"\s+enable="1"\s*\/>/g)]
  .map(m => m[1]).filter(p => !/audio_pll\/|lcd_pll\/|src\/pll_init/.test(p));
assert(files.length > 40, 'Enabled project source list unexpectedly small');
writeFileSync(resolve(output, 'source-sha256.json'), JSON.stringify(files.map(file => ({
  file, sha256: createHash('sha256').update(readFileSync(resolve(source, file))).digest('hex'),
})), null, 2) + '\n');
console.log(`Compiling ${files.length} enabled current V3 sources; production RTL is unchanged.`);
run(resolve(modelSim, 'vlog.exe'), ['-work', lib, '+incdir+rtl+sim', ...files,
  'tb_ext4_v3_offline.sv'], undefined, 'compile');
console.log('Running physical UART/DAC/LED offline integration (ten-minute process limit).');
const log = run(resolve(modelSim, 'vsim.exe'), ['-c', '-lib', lib, 'tb_ext4_v3_offline',
  '+requests=requests.txt', '+replies=replies.txt',
  '+words=score.hex', `+count=${requests.length}`,
  '-l', 'simulation.transcript', '-wlf', 'simulation.wlf',
  '-do', 'run -all; quit -f'], undefined, 'simulation');
for (const file of ['replies.txt', 'simulation.transcript']) {
  if (existsSync(resolve(build, file))) copyFileSync(resolve(build, file), resolve(output, file));
}
assert.match(log, /# PASS: current V3 physical UART/);
assert(!/# \*\* (?:Error|Fatal):|# ERROR:/.test(log), log.slice(-4000));

// Pass ACTUAL RTL UART replies through production C Notify fragmentation, then
// through the same strict parser used by the browser. No golden reply fixture.
// ModelSim's Windows text output uses CRLF. DeviceSession and ScoreUploader
// remove the line terminator before strict parsing; mirror that framing here.
const actualReplies = readFileSync(resolve(output, 'replies.txt'), 'utf8').trimEnd().split(/\r?\n/);
assert.equal(actualReplies.length, requests.length);
const replyCommands = [];
for (const line of actualReplies) {
  const frame = line + '\n';
  for (let i = 0; i < frame.length; i += 3) replyCommands.push(`U ${hex(frame.slice(i, i + 3))}`);
  for (let i = 0; i < frame.length; i += 20) replyCommands.push('N 23');
}
const notifications = run(bridge, ['--pipe'], replyCommands.join('\n') + '\n', 'bridge_replies');
assert(notifications.split(/\r?\n/).filter(l => l.startsWith('R ')).every(l => l === 'R 0'));
const returned = notifications.split(/\r?\n/).filter(l => l.startsWith('N '))
  .map(l => Buffer.from(l.slice(2), 'hex').toString()).join('').trimEnd().split('\n');
assert.deepEqual(returned, actualReplies);
const parsed = returned.map((line, i) => {
  const reply = parseScoreReply(line);
  assert(reply && !reply.error, `Actual FPGA rejected request ${i}: ${line}`);
  assert.equal(reply.session, sid); assert.equal(reply.sequence, i);
  assert.equal(reply.operation, operations[i].operation);
  if (operations[i].expected) assert.deepEqual(reply.values, operations[i].expected);
  return reply;
});
assert.equal(parsed[0].capability.playback, true);
const completed = parsed.at(-1).playback;
assert.equal(completed.state, 3);
// progress is a zero-based melody index (fpga-score.js/song_timeline.v),
// not the number of completed notes: the second melody note has index 1.
assert.equal(completed.noteIndex, score.melodyCount - 1);
assert.equal(completed.length, score.length); assert.equal(completed.crc, plan.crc);
assert.equal(completed.storedValid, true); assert.equal(completed.storedCrc, plan.crc);
writeFileSync(resolve(output, 'result.json'), JSON.stringify({
  source: relative(root, source), productionRtlChanged: false,
  score: { words: score.length, crc: plan.crc, endTick: score.endTick },
  requests: requests.length, actualReplies: parsed,
  simulationPass: log.match(/# PASS:[^\r\n]+/)[0],
  limitations: ['PLL clocks modeled', 'UART bit dwell shortened to 8 clocks',
    'C bridge is native host code, not a BLE radio or ESP-IDF scheduler',
    'No board electrical/analog sound/BLE hardware observation',
    'Playback is RAM-resident; upload is not preserved across FPGA power loss'],
}, null, 2) + '\n');
console.log(log.match(/# PASS:[^\r\n]+/)[0]);
console.log(`PASS: production host compiler -> C bridge -> current V3 RTL -> C Notify -> strict browser reply parser; evidence ${output}`);
