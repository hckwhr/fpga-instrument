import { compileTracks } from './midi.js';

// 把音符起止时间编译成板端事件，而非传送原始 MP3/PCM。
// 4096 个事件通常对应 2048 个完整音符；每个音符的 ON/OFF 共用身份。
// 曲谱准入的 16 声部含释放尾音，是调度与混音余量限制，
// 不等于硬件合成引擎的 32 复音规模。

// ABI 12/13: absolute 6.25 ms ticks at panel speed 100; 512/4096 events.
// ABI 13 retains the 64-bit layout; progress byte is modulo 256, while board
// validator/timeline count full progress. Short scores remain ABI 12 byte-exact.
// Both versions retain
// at most 16 events/group and 16 occupied lanes including conservative tails.
// The renderer remains the existing 32-lane bank; this admission bound prevents
// stealing and guarantees enough time for the sequential allocator in one slot.
export const SCORE_LIMITS = Object.freeze({ events: 4096, group: 16, lanes: 16, velocity: 768, tailTicks: 6 });
const reject = (reason) => { throw new Error(`FPGA 曲谱: ${reason}`); };

export function compileFpgaScore(project, { melodyTrack = 0 } = {}) {
  if (!Number.isInteger(melodyTrack) || !project.tracks[melodyTrack]?.notes.length) reject("指定的旋律轨道没有音符");
  const warnings = project.tracks.flatMap((track) => track.warnings);
  if (warnings.length) reject(warnings.join("; "));
  const source = project.tracks.flatMap((track) => track.notes)
    .sort((a, b) => a.startMs - b.startMs || a.track - b.track || a.order - b.order);
  if (!source.length || source.length * 2 > SCORE_LIMITS.events) reject("音符事件数必须为 1..4096");
  let progress = 0;
  const notes = source.map((note, id) => {
    if (!Number.isInteger(note.note) || !Number.isInteger(note.velocity) || note.velocity < 1 || note.velocity > 127 ||
        !Number.isInteger(note.channel) || note.channel < 0 || note.channel > 15) reject('音高、力度或通道数据无效');
    if (note.channel === 9) reject("鼓轨不能按钢琴音高演奏，请移除鼓轨");
    if (note.note < 48 || note.note > 83) reject(`音高 ${note.note} 超出 C3..B5`);
    const start = Math.round(note.startMs / 6.25), end = Math.round(note.endMs / 6.25);
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end <= start || end > 0xffffff)
      reject("音符时长量化后为零或时间超出 24 位范围");
    const melody = note.track === melodyTrack;
    return { ...note, id, start, end, melody, progress: melody ? progress++ : 0 };
  });
  if (progress > 2048) reject("旋律进度超过 2048 个音符");
  const melody = notes.filter((n) => n.melody);
  if (melody.some((n, i) => i && n.start < melody[i - 1].end)) reject("显示旋律轨需单声部；其它轨可复音");
  // Release recurrence gain -= (gain >> 8) + 1, max gain 4080: <1200 samples.
  // At fastest speed a tick is 200 samples. Retain full velocity for six ticks
  // as a conservative amplitude/occupancy bound, including repeated same pitch.
  const occupancy = notes.flatMap((n) => [
    { tick: n.start, voices: 1, velocity: n.velocity },
    { tick: n.end + SCORE_LIMITS.tailTicks, voices: -1, velocity: -n.velocity },
  ]).sort((a, b) => a.tick - b.tick || a.voices - b.voices);
  let voices = 0, velocity = 0, maxVoices = 0, maxVelocity = 0;
  for (const change of occupancy) {
    voices += change.voices; velocity += change.velocity;
    maxVoices = Math.max(maxVoices, voices); maxVelocity = Math.max(maxVelocity, velocity);
  }
  if (maxVoices > SCORE_LIMITS.lanes) reject(`含尾音占用 ${maxVoices} 声部，当前离线调度上限 16`);
  if (maxVelocity > SCORE_LIMITS.velocity) reject(`含尾音力度和 ${maxVelocity}，超过音量余量上限 768`);
  const events = notes.flatMap((n) => [{ ...n, tick: n.start, on: true }, { ...n, tick: n.end, on: false }])
    .sort((a, b) => a.tick - b.tick || Number(a.on) - Number(b.on) || a.id - b.id);
  let groupSize = 0, maxGroup = 0;
  const words = events.map((event, i) => {
    groupSize++;
    event.last = i === events.length - 1 || events[i + 1].tick !== event.tick;
    maxGroup = Math.max(maxGroup, groupSize);
    if (event.last) groupSize = 0;
    return (BigInt(event.tick) << 40n) | (BigInt(event.on) << 39n) | (BigInt(event.id) << 23n) |
      (BigInt(event.note % 12) << 19n) | (BigInt(Math.floor((event.note - 48) / 12)) << 17n) |
      (BigInt(event.velocity) << 10n) | (BigInt(event.last) << 9n) |
      (BigInt(event.melody) << 8n) | BigInt(event.progress & 255);
  });
  if (maxGroup > SCORE_LIMITS.group) reject(`同刻 ${maxGroup} 个事件，超过 16`);
  const endMs = typeof project.tempoMap === 'function' ? Math.max(...project.tracks.map(t => project.tempoMap(t.endTick))) : Math.max(...source.map(n => n.endMs));
  const endTick = Math.round(endMs / 6.25);
  if (!Number.isSafeInteger(endTick) || endTick > 0xffffff || endTick < events.at(-1).tick) reject("曲谱结束时间无效");
  return { abi: events.length > 512 || progress > 255 ? 13 : 12, title: project.title, events, words, length: events.length, endTick, melodyCount: progress,
    maxGroup, maxVoices, maxVelocity, quantizationMs: Math.max(...notes.flatMap((n) =>
      [Math.abs(n.start * 6.25 - n.startMs), Math.abs(n.end * 6.25 - n.endMs)])) };
}

// Match the integer-ms preview timing. Preserve indices for the melody choice.
export function compileSelectedFpgaScore(project, selectedTracks, { melodyTrack, speed = 1, velocityScale = 1 } = {}) {
  if (!project || !Array.isArray(selectedTracks) || !selectedTracks.length ||
      selectedTracks.some(i => !Number.isInteger(i) || !project.tracks[i]) || !selectedTracks.includes(melodyTrack)) reject('请选择轨道及其中的单声部旋律轨');
  if (!Number.isFinite(speed) || speed <= 0 || !Number.isFinite(velocityScale) || velocityScale <= 0) reject('速度或力度设置无效');
  const events = compileTracks(project, selectedTracks, { speed, velocityScale });
  return compileFpgaScore({ title: project.title, tracks: project.tracks.map((track, index) => ({
    warnings: selectedTracks.includes(index) ? track.warnings : [],
    notes: events.filter(n => n.track === index).map((n, order) => ({ ...n, endMs: n.startMs + n.durationMs, order })),
  })) }, { melodyTrack });
}

export function renderScoreRom(scores) {
  if (scores.some(score => score.length > 512 || score.melodyCount > 255)) reject("内置 ROM 导出仍限 512 事件/255 旋律音符");
  if (scores.length !== 2) reject("当前 ROM 包需要两首曲谱");
  const lines = ["`default_nettype none", "// Generated by export-fpga-score.mjs. Do not edit ROM data manually.",
    "module song_timeline_rom(input wire clk, select, input wire [8:0] index,",
    "    output reg [63:0] data, output wire [9:0] length,",
    "    output wire [23:0] end_tick, output wire [7:0] melody_count);",
    "    reg [63:0] rom [0:1023];", "    initial begin"];
  for (let song = 0; song < 2; song++) for (let i = 0; i < 512; i++)
    lines.push(`        rom[${song * 512 + i}] = 64'h${(scores[song].words[i] ?? 0n).toString(16).padStart(16, "0")};`);
  lines.push("    end", "    always @(posedge clk) data <= rom[{select,index}];",
    `    assign length = select ? 10'd${scores[1].length} : 10'd${scores[0].length};`,
    `    assign end_tick = select ? 24'd${scores[1].endTick} : 24'd${scores[0].endTick};`,
    `    assign melody_count = select ? 8'd${scores[1].melodyCount} : 8'd${scores[0].melodyCount};`,
    "endmodule", "`default_nettype wire", "");
  return lines.join("\n");
}
