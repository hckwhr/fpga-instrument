import test from 'node:test';
import assert from 'node:assert/strict';
import { boardPlaybackView } from '../src/board-monitor.js';

const identity = { length: 6, crc: 'ABCD', notes: [{ note: 60 }, { note: 62 }, { note: 64 }] };
const playing = { state: 2, noteIndex: 0, length: 6, crc: 'ABCD' };
test('board position is zero-based and requires matching score and fresh numbered reply', () => {
  assert.equal(boardPlaybackView(playing, identity, 100, 101).position, 0);
  assert.equal(boardPlaybackView({ ...playing, noteIndex: 2 }, identity, 100, 5099).position, 2);
  for (const data of [{ ...playing, crc: 'FFFF' }, { ...playing, length: 8 }, null])
    assert.equal(boardPlaybackView(data, identity, 100, 101).position, -1);
  assert.equal(boardPlaybackView(playing, null, 100, 101).matched, false);
  for (const at of [0, 102, -5000]) assert.equal(boardPlaybackView(playing, identity, at, 101).position, -1);
  assert.equal(boardPlaybackView(playing, identity, 100, 5100).fresh, false);
});
test('preparation, stop, finish, fault, and invalid indices never light a board key', () => {
  for (const state of [0, 1, 3, 4])
    assert.equal(boardPlaybackView({ ...playing, state }, identity, 100, 101).position, -1);
  for (const noteIndex of [-1, .5, 3, 255])
    assert.equal(boardPlaybackView({ ...playing, noteIndex }, identity, 100, 101).position, -1);
});
