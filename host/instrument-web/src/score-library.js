// Versioned, local-only score snapshots. Store source notes, not scaled events,
// so reopening and recompiling never applies speed/velocity twice.
export const LIBRARY_KEY = 'instrument-score-library-v1';
const MAX_TEXT = 2 * 1024 * 1024;
const MAX_SCORES = 20;

function requireValue(ok, message) {
  if (!ok) throw new Error(`曲谱库：${message}`);
}
function text(value, max = 256) {
  requireValue(typeof value === 'string' && value.length <= max, '文本字段无效或过长');
  return value;
}
function number(value, min, max, integer = false) {
  requireValue(Number.isFinite(value) && value >= min && value <= max && (!integer || Number.isInteger(value)), '音符或设置数值越界');
  return value;
}

export function validateScore(source) {
  requireValue(source?.version === 1, '不支持的曲谱存档版本');
  const p = source.project;
  requireValue(p && [0, 1, 'audio-transcription'].includes(p.format), '曲谱格式无效');
  requireValue(Array.isArray(p.tracks) && p.tracks.length > 0 && p.tracks.length <= 256, '轨道数量无效');
  let count = 0;
  const tracks = p.tracks.map((track, trackIndex) => {
    requireValue(Array.isArray(track?.notes), '缺少音符');
    count += track.notes.length;
    requireValue(count <= 50000, '单曲最多保存 50000 个音符');
    requireValue(Array.isArray(track.warnings) && track.warnings.length <= 50000, '轨道提示无效');
    return {
      title: text(track.title, 1024),
      warnings: track.warnings.map(w => text(w, 2048)),
      notes: track.notes.map((n, order) => {
        const startMs = number(n.startMs, 0, Number.MAX_SAFE_INTEGER);
        const endMs = number(n.endMs, startMs, Number.MAX_SAFE_INTEGER);
        return { startMs, endMs, durationMs: Math.max(1, endMs - startMs),
          note: number(n.note, 0, 127, true), velocity: number(n.velocity, 1, 127, true),
          channel: number(n.channel, 0, 15, true), track: trackIndex, order };
      }),
    };
  });
  requireValue(count > 0, '没有可保存的音符');
  const settings = source.settings;
  requireValue(Array.isArray(settings?.selectedTracks), '缺少音轨选择');
  requireValue(settings.selectedTracks.length <= tracks.length, '音轨选择无效');
  const selectedTracks = [...new Set(settings.selectedTracks.map(i => number(i, 0, tracks.length - 1, true)))];
  const title = text(source.title).trim();
  requireValue(title.length > 0, '请填写曲谱名称');
  let arrangement;
  if (p.arrangement) {
    requireValue(p.format === 'audio-transcription', '旋律整理来源无效');
    arrangement = {};
    for (const key of ['startSeconds', 'endSeconds']) arrangement[key] = number(p.arrangement[key], 0, 600);
    requireValue(arrangement.endSeconds > arrangement.startSeconds, '旋律选段无效');
    for (const key of ['sourceNotes', 'selectedNotes', 'melodyNotes', 'removedSimultaneous', 'folded', 'shortened'])
      arrangement[key] = number(p.arrangement[key], 0, 50000, true);
    requireValue(arrangement.melodyNotes === count && arrangement.melodyNotes <= 2048 &&
      arrangement.sourceNotes >= arrangement.selectedNotes && arrangement.selectedNotes >= count, '旋律整理统计无效');
    if (p.arrangement.mode !== undefined) {
      requireValue(p.arrangement.mode === 'polyphonic', '演奏整理模式无效');
      arrangement.mode = 'polyphonic';
      if (p.arrangement.bassBalance !== undefined) arrangement.bassBalance = number(p.arrangement.bassBalance, .25, 1);
      if (p.arrangement.bassAdjusted !== undefined) arrangement.bassAdjusted = number(p.arrangement.bassAdjusted, 0, count, true);
      for (const key of ['guideNotes', 'accompanimentNotes', 'pitchOmitted', 'boundaryOmitted', 'capacityOmitted', 'densityOmitted'])
        arrangement[key] = number(p.arrangement[key], 0, 50000, true);
      requireValue(arrangement.guideNotes === tracks[0].notes.length &&
        arrangement.accompanimentNotes === count - arrangement.guideNotes, '演奏轨统计无效');
      arrangement.maxVoices = number(p.arrangement.maxVoices, 1, 16, true);
      arrangement.maxVelocity = number(p.arrangement.maxVelocity, 1, 768, true);
      for (const key of ['lowOctaveShift', 'highOctaveShift']) {
        arrangement[key] = number(p.arrangement[key], -120, 120, true);
        requireValue(arrangement[key] % 12 === 0, '音区移调无效');
      }
    }
    // Optional extensions preserve older v1 snapshots, while newly arranged
    // scores retain the exact choices used to generate their derivative.
    for (const key of ['filtered', 'suppressed', 'merged', 'gridCollisions', 'residualFolds', 'outsideRange', 'sustainedBass'])
      if (p.arrangement[key] !== undefined) arrangement[key] = number(p.arrangement[key], 0, 50000, true);
    for (const [key, min, max] of [['onsetWindowMs', 0, 100], ['minDurationMs', 0, 250], ['bpm', 40, 240], ['gridMs', 0.001, 375], ['beatOffsetMs', 0, 2000], ['velocityScale', 1 / 127, 1]])
      if (p.arrangement[key] !== undefined) arrangement[key] = number(p.arrangement[key], min, max);
    for (const key of ['minPitch', 'maxPitch'])
      if (p.arrangement[key] !== undefined) arrangement[key] = number(p.arrangement[key], 0, 127, true);
    requireValue((arrangement.minPitch ?? 0) <= (arrangement.maxPitch ?? 127), '旋律音域无效');
    if (p.arrangement.protectSustain !== undefined) {
      requireValue(typeof p.arrangement.protectSustain === 'boolean', '长音保护选项无效');
      arrangement.protectSustain = p.arrangement.protectSustain;
    }
    if (p.arrangement.octaveShift !== undefined) {
      arrangement.octaveShift = number(p.arrangement.octaveShift, -72, 72, true);
      requireValue(arrangement.octaveShift % 12 === 0, '八度移调无效');
    }
    for (const [key, values] of [['strategy', ['balanced', 'highest', 'strongest']], ['rhythm', ['original', 'sixteenth']],
      ['repeatMode', ['preserve', 'merge']], ['pitchMode', ['phrase', 'fold']]]) {
      if (p.arrangement[key] === undefined) continue;
      requireValue(values.includes(p.arrangement[key]), '旋律整理选项无效');
      arrangement[key] = p.arrangement[key];
    }
  }
  return {
    version: 1, id: text(source.id, 100), title, fileName: text(source.fileName, 1024),
    savedAt: number(source.savedAt, 0, Number.MAX_SAFE_INTEGER, true),
    project: { format: p.format, title: text(p.title, 1024), tracks, partial: p.partial === true,
      ...(p.audioDurationSeconds !== undefined ? { audioDurationSeconds: number(p.audioDurationSeconds, .01, 600) } : {}),
      ...(arrangement ? { arrangement } : {}) },
    settings: { selectedTracks, speed: number(settings.speed, 50, 150, true), velocity: number(settings.velocity, 25, 125, true) },
  };
}

export function serializeScore(score) {
  const data = JSON.stringify(validateScore(score));
  requireValue(data.length <= MAX_TEXT, '存档超过 2 Mi 字符上限，请减少音轨');
  return data;
}
export function parseScore(data) {
  requireValue(typeof data === 'string' && data.length <= MAX_TEXT, '存档过大');
  return validateScore(JSON.parse(data));
}

export class ScoreLibrary {
  constructor(storage) { this.storage = storage; }
  backend() {
    try { return this.storage ?? globalThis.localStorage; }
    catch { throw new Error('曲谱库：浏览器禁止本地存储；仍可导出曲谱存档'); }
  }
  list() {
    const storage = this.backend();
    requireValue(storage, '本地存储不可用');
    const raw = storage.getItem(LIBRARY_KEY);
    if (raw === null) return [];
    requireValue(raw.length <= MAX_TEXT, '本地曲谱库过大，未覆盖原数据');
    let data;
    try { data = JSON.parse(raw); }
    catch { throw new Error('曲谱库：本地数据损坏，未覆盖原数据'); }
    requireValue(data?.version === 1 && Array.isArray(data.scores) && data.scores.length <= MAX_SCORES, '本地存档版本或数量无效，未覆盖原数据');
    const scores = data.scores.map(validateScore);
    requireValue(new Set(scores.map(s => s.id)).size === scores.length, '重复存档编号，未覆盖原数据');
    return scores.sort((a, b) => b.savedAt - a.savedAt);
  }
  write(scores) {
    requireValue(scores.length <= MAX_SCORES, '最多保存 20 首，请先导出并移除不再使用的曲谱');
    const data = JSON.stringify({ version: 1, scores });
    requireValue(data.length <= MAX_TEXT, '曲谱库空间不足，请先导出并移除不再使用的曲谱');
    try { this.backend().setItem(LIBRARY_KEY, data); }
    catch { throw new Error('曲谱库：保存失败或浏览器空间不足，原存档未被替换；请导出文件备份'); }
  }
  save(source, id = null) {
    const scores = this.list();
    if (id) requireValue(scores.some(s => s.id === id), '该存档已被移除，请另存为新曲谱');
    const score = validateScore({ ...source, version: 1, id: id || crypto.randomUUID(), savedAt: Date.now() });
    this.write([score, ...scores.filter(s => s.id !== score.id)]);
    return score;
  }
  remove(id) {
    const scores = this.list();
    const removed = scores.find(s => s.id === id);
    requireValue(removed, '存档不存在');
    this.write(scores.filter(s => s.id !== id));
    return removed;
  }
  restore(source) {
    const score = validateScore(source);
    const scores = this.list();
    requireValue(!scores.some(s => s.id === score.id), '同编号存档已存在，未覆盖');
    this.write([score, ...scores]);
  }
}
