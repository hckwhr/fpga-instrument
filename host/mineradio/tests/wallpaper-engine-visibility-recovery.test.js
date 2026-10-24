'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../public/js/modules/07-fx/03-wallpaper-engine-library.js'), 'utf8')
  .replace(/^initializeWallpaperEngineLibrary\(\);\s*$/m, '');
function harness() {
  const timers = new Map(), calls = { start: 0, preview: 0, play: 0, pause: 0 };
  let nextTimer = 0;
  const classes = new Set(['wallpaper-engine-active']);
  const video = { play() { calls.play++; return Promise.resolve(); }, pause() { calls.pause++; } };
  const context = vm.createContext({
    console, Map, Set, Promise,
    localStorage: { getItem() { return null; }, setItem() {} },
    window: { desktopWindow: { onWallpaperEngineHostBoundsChanged() {} } },
    document: { hidden: true, body: { classList: { contains: k => classes.has(k), remove: (...ks) => ks.forEach(k => classes.delete(k)) } },
      getElementById: id => id === 'wallpaper-engine-video' ? video : null },
    desktopRuntimeState: { visible: true, minimized: false },
    setTimeout(fn) { const id = ++nextTimer; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); },
  });
  vm.runInContext(source, context);
  const item = { id: 'a'.repeat(24), title: 'Test scene', enginePlayable: true, hasPreview: true };
  context.wallpaperEngineSelection = { active: true, kind: 'engine', id: item.id, mediaType: 'video' };
  context.wallpaperEngineProjects = [item];
  context.wallpaperEngineNativeSessionId = 'b'.repeat(24);
  context.wallpaperEngineLayerToken = 1;
  for (const name of ['updateWallpaperEngineEntryUi', 'restoreOriginalBackgroundAfterWallpaperEngine',
    'clearWallpaperEngineLayerMedia', 'clearWallpaperEngineFreezeFrame', 'stopWallpaperEngineCaptureStream', 'showToast']) context[name] = () => {};
  context.reportWallpaperEngineCaptureResult = () => Promise.resolve({ ok: true });
  context.stopWallpaperEngineNativeSession = () => { context.wallpaperEngineNativeSessionId = ''; return Promise.resolve({ ok: true }); };
  context.startWallpaperEngineNativeBackground = () => { calls.start++; return Promise.resolve(); };
  context.applyWallpaperEngineBackground = () => { calls.preview++; };
  return { context, calls, item, video, timers, async flush() { await new Promise(resolve => setImmediate(resolve)); },
    fire() { const entry = timers.entries().next().value; assert.ok(entry, 'expected recovery timer'); timers.delete(entry[0]); entry[1](); } };
}

test('visible desktop resumes Scene even when Chromium visibility is stale', () => {
  const h = harness();
  h.context.wallpaperEngineHostBoundsPreparing = true;
  h.context.handleWallpaperEngineHostBoundsChange({ phase: 'restart' });
  assert.equal(h.calls.start, 1);
  assert.equal(h.context.wallpaperEngineHostBoundsPreparing, false);
});

test('actually minimized host must not resume a Scene', () => {
  const h = harness(); h.context.desktopRuntimeState.minimized = true;
  h.context.wallpaperEngineHostBoundsPreparing = true;
  h.context.handleWallpaperEngineHostBoundsChange({ phase: 'restart' });
  assert.equal(h.calls.start, 0);
});

test('verified native restore can precede the renderer window-state update', () => {
  const h = harness(); h.context.desktopRuntimeState.minimized = true;
  h.context.wallpaperEngineHostBoundsPreparing = true;
  h.context.handleWallpaperEngineHostBoundsChange({ phase: 'restart', forceVisibleHost: true });
  assert.equal(h.calls.start, 1);
});

test('WE video playback trusts desktop visibility instead of stale page occlusion', async () => {
  const h = harness(); h.context.wallpaperEngineSelection.kind = 'media';
  h.context.requestWallpaperEngineVideoPlayback(h.video, h.item, 'media', 1, false, 0);
  await h.flush();
  assert.equal(h.calls.play, 1); assert.equal(h.calls.pause, 0);
});

test('live Scene interruption retries at most three times before preview fallback', async () => {
  const h = harness();
  h.context.wallpaperEngineLayerFailed(h.item, 'engine', 1);
  await h.flush();
  assert.equal(h.calls.preview, 0);
  assert.equal(h.timers.size, 1);
  for (let i = 0; i < 3; i++) {
    h.fire();
    assert.equal(h.calls.start, i + 1);
    h.context.wallpaperEngineLayerFailed(h.item, 'engine', h.context.wallpaperEngineLayerToken);
    await h.flush();
  }
  assert.equal(h.calls.preview, 1); assert.equal(h.timers.size, 0);
  assert.equal(h.context.wallpaperEngineHostBoundsPreparing, false, 'fallback must not block a later manual selection');
});

test('switching wallpaper cancels pending recovery, including an old stop completion', async () => {
  const h = harness(); let releaseStop;
  h.context.stopWallpaperEngineNativeSession = () => new Promise(resolve => { releaseStop = resolve; });
  h.context.wallpaperEngineLayerFailed(h.item, 'engine', 1);
  h.context.cancelWallpaperEngineHostRecovery(true);
  h.context.wallpaperEngineLayerToken++;
  h.context.wallpaperEngineSelection.id = 'c'.repeat(24);
  // Another selection may independently be recovering when the old stop ends.
  h.context.wallpaperEngineHostRecoveryInFlight = true;
  releaseStop({ ok: true }); await h.flush();
  assert.equal(h.timers.size, 0); assert.equal(h.calls.start, 0);
});

test('initial launch failure is not retried as a previously healthy Scene', async () => {
  const h = harness(); h.context.wallpaperEngineNativeSessionId = '';
  h.context.wallpaperEngineLayerFailed(h.item, 'engine', 1);
  await h.flush();
  assert.equal(h.calls.preview, 1); assert.equal(h.timers.size, 0);
});

test('duplicate ended/error callbacks cannot replace a pending Scene recovery', async () => {
  const h = harness();
  h.context.wallpaperEngineLayerFailed(h.item, 'engine', 1);
  h.context.wallpaperEngineLayerFailed(h.item, 'engine', 1);
  await h.flush();
  assert.equal(h.calls.preview, 0); assert.equal(h.timers.size, 1);
});

test('native media hide/restore resumes video even without a page visibility transition', async () => {
  const h = harness(); h.context.wallpaperEngineSelection.kind = 'media';
  h.context.desktopRuntimeState.minimized = true;
  h.context.syncWallpaperEngineMediaHostVisibility();
  assert.equal(h.calls.pause, 1); assert.equal(h.calls.play, 0);
  h.context.desktopRuntimeState.minimized = false;
  h.context.syncWallpaperEngineMediaHostVisibility(); await h.flush();
  assert.equal(h.calls.play, 1);
});

test('late playback request cannot cancel the new wallpaper playback retry', () => {
  const h = harness();
  const retry = h.context.setTimeout(() => {});
  h.context.wallpaperEngineVideoRetryTimer = retry;
  h.context.requestWallpaperEngineVideoPlayback(h.video, h.item, 'media', 0, false, 0);
  assert.equal(h.context.wallpaperEngineVideoRetryTimer, retry);
  assert.equal(h.timers.size, 1);
});

test('non-desktop browser still obeys Page Visibility', () => {
  const h = harness(); h.context.window.desktopWindow = null;
  h.context.wallpaperEngineHostBoundsPreparing = true;
  h.context.handleWallpaperEngineHostBoundsChange({ phase: 'restart' });
  assert.equal(h.calls.start, 0);
  h.context.document.hidden = false;
  h.context.handleWallpaperEngineHostBoundsChange({ phase: 'restart' });
  assert.equal(h.calls.start, 1);
});
