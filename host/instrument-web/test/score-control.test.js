import test from 'node:test';
import assert from 'node:assert/strict';
import { encodeScoreFrame, decodeScoreFrame, parseScoreReply, prepareScoreUpload } from '../src/score-upload-protocol.js';
import { ScoreUploadSession } from '../src/score-upload.js';
import { DeviceSession } from '../src/device-session.js';
import { ScoreReceiverModel } from '../tools/score-receiver-model.mjs';

const sid='0123456789ABCDEF';
const score={words:[0x0000008000034300n,0x0000020000034300n],length:2,endTick:2,melodyCount:1};
function fixture(playback=true) {
  const data=new Set(),status=new Set(),sent=[];
  const model=new ScoreReceiverModel({playback});
  const f={model,sent,hook:null};
  const transport={connected:true,onData(fn){data.add(fn);return()=>data.delete(fn);},onStatus(fn){status.add(fn);return()=>status.delete(fn);},
    async sendText(frame, options){assert.equal(options.newline,false);sent.push(frame);const reply=model.receive(frame);
      if(f.hook) return f.hook({frame,reply,op:decodeScoreFrame(frame.trim())[3],emit:f.emit});
      if(reply)f.emit(reply);
    }};
  f.emit=bytes=>data.forEach(fn=>fn(bytes));
  f.connect=connected=>{transport.connected=connected;status.forEach(fn=>fn({state:connected?'connected':'disconnected'}));};
  f.device=new DeviceSession(transport);
  f.session=new ScoreUploadSession(f.device,{timeoutMs:15,writeTimeoutMs:40,retries:1});
  return f;
}
test('control CAPS is explicit and status parser rejects noncanonical or inconsistent state',()=>{
  const reply=(op,v)=>parseScoreReply(encodeScoreFrame(['ACK2',sid,4,op,...v]).trim());
  assert.equal(reply('CAPS',[12,512,8]).capability.playback,undefined);
  assert.equal(reply('CAPS',[12,512,8,1]).capability.playback,true);
  assert.equal(reply('CAPS',[12,512,8,2]),null);
  assert.deepEqual(reply('STATUS',[2,4,132,'ABCD',1,'CDEF']).playback,{state:2,noteIndex:4,length:132,crc:'ABCD',storedValid:true,storedCrc:'CDEF'});
  for(const v of [[5,0,2,'ABCD',1,'ABCD'],[1,0,0,'0000',0,'0000'],[0,0,0,'ABCD',0,'0000'],[0,0,0,'0000',0,'ABCD'],[0,'01',2,'ABCD',1,'ABCD'],[0,256,2,'ABCD',1,'ABCD'],[0,0,513,'ABCD',1,'ABCD']])assert.equal(reply('STATUS',v),null);
  assert.equal(reply('STOP',[2,0,2,'ABCD',1,'ABCD']),null);
  assert.equal(reply('PLAY',[0,0,2,'ABCD',1,'ABCD']),null);
});
test('legacy upload capability never enables numbered playback',async()=>{
  const f=fixture(false); await f.session.probe();
  await assert.rejects(f.session.control('PLAY',score),/播放能力/);
  assert.equal(f.sent.length,1);
});
test('PLAY STOP and STATUS retries are identical and cause only one execution',async()=>{
  const f=fixture(); await f.session.probe();await f.session.upload(score);
  const lost=new Set();
  f.hook=({op,reply,emit})=>{if(!lost.has(op)){lost.add(op);return;} emit(new TextEncoder().encode(reply.slice(0,11)));emit(reply.slice(11));};
  assert.equal((await f.session.control('PLAY',score)).state,1);
  assert.equal((await f.session.control('STATUS')).length,2);
  assert.equal((await f.session.control('STOP')).state,0);
  assert.equal(f.model.plays,1);assert.equal(f.model.stops,1);
  for(const op of lost){const frames=f.sent.filter(s=>s.includes(`,${op},`));assert.equal(frames.length,2);assert.equal(frames[0],frames[1]);}
});
test('explicit NOSCORE CONTENT BUSY rejection preserves the next sequence for correction',async()=>{
  const f=fixture();await f.session.probe();
  await assert.rejects(f.session.control('PLAY',score),/NOSCORE/);
  await f.session.control('STATUS');
  await f.session.upload(score);
  await assert.rejects(f.session.control('PLAY',{...score,words:[...score.words].reverse()}),/CONTENT/);
  await f.session.control('PLAY',score);
  await assert.rejects(f.session.control('PLAY',score),/BUSY/);
  await f.session.control('STOP');
  assert.equal(f.model.plays,1);assert.equal(f.device.snapshot().blocked,false);
});
test('mismatched PLAY identity and bad CRC never satisfy a pending request',async()=>{
  const f=fixture();await f.session.probe();await f.session.upload(score);
  f.hook=({frame,reply,emit})=>{const fields=decodeScoreFrame(reply.trim());fields[7]='FFFF';emit(encodeScoreFrame(fields));emit(reply.replace('ACK2','ACK3'));};
  await assert.rejects(f.session.control('PLAY',score),/未知/);
  assert.equal(f.model.plays,1);assert.equal(f.session.playback,null);assert.equal(f.device.snapshot().blocked,true);
});
test('early ACK followed by failed or hung write is unknown and cannot enable follow-up control',async()=>{
  for(const hung of [false,true]){
    const f=fixture();await f.session.probe();await f.session.upload(score);
    f.hook=({reply,emit})=>{emit(reply);if(hung)return new Promise(()=>{});throw Error('write failed');};
    await assert.rejects(f.session.control('PLAY',score),/未知/);
    assert.equal(f.model.plays,1);assert.equal(f.session.playback,null);assert.equal(f.device.snapshot().blocked,true);
    await assert.rejects(f.session.control('STOP'),/播放能力/);
  }
});
test('control excludes old commands and upload; disconnect clears playback and capability',async()=>{
  const f=fixture();await f.session.probe();await f.session.upload(score);
  let deliver;
  f.hook=({reply,emit})=>{deliver=()=>emit(reply);};
  const play=f.session.control('PLAY',score);
  await assert.rejects(f.device.request('PING'),/上一条/);
  await assert.rejects(f.session.upload(score),/尚未结束/);
  deliver();await play;
  assert.equal(f.session.playback.state,1);
  f.connect(false);f.connect(true);
  assert.equal(f.session.playback,null);assert.equal(f.session.capability,null);
  await assert.rejects(f.session.control('STATUS'),/播放能力/);
});
test('repeated STATUS is a cached snapshot; fresh sequence returns updated state',async()=>{
  const f=fixture();await f.session.probe();await f.session.upload(score);await f.session.control('PLAY',score);
  let first=true;
  // This fixture contains one note; keep its index valid while changing state.
  f.hook=({reply,emit})=>{if(first){first=false;f.model.playState=2;f.model.noteIndex=0;return;}emit(reply);};
  assert.equal((await f.session.control('STATUS')).state,1);
  assert.equal((await f.session.control('STATUS')).state,2);
});

test('exhausted sequence disables control without sending and fresh CAPS restores it',async()=>{
  const f=fixture();await f.session.probe();
  f.session.sequence=65536;
  let latest;f.session.onChange(s=>{latest=s;});
  await assert.rejects(f.session.control('STATUS'),/编号已用尽/);
  assert.equal(f.sent.length,1);assert.equal(latest.capability,null);assert.equal(latest.playback,null);
  await assert.rejects(f.session.control('STOP'),/播放能力/);
  await f.session.probe();await f.session.control('STATUS');
  assert.equal(f.sent.length,3);
});

test('disposed session cannot restart commands or capability probes',async()=>{
  const f=fixture();await f.session.probe();
  f.session.dispose();
  assert.equal(f.session.snapshot().capability,null);
  await assert.rejects(f.session.control('STATUS'),/已关闭/);
  await assert.rejects(f.session.probe(),/已关闭/);
  assert.equal(f.sent.length,1);assert.equal(f.device.snapshot().blocked,false);
});

test('STATUS retains the last dated ACK while pending, then replaces it; failure clears it', async () => {
  const f = fixture(); await f.session.probe(); await f.session.upload(score);
  const before = Date.now(); await f.session.control('PLAY', score);
  const prior = f.session.snapshot();
  assert.ok(prior.playbackUpdatedAt >= before && prior.playbackUpdatedAt <= Date.now());
  let deliver;
  f.hook = ({ reply, emit }) => { deliver = () => emit(reply); };
  const status = f.session.control('STATUS');
  assert.deepEqual(f.session.snapshot().playback, prior.playback);
  assert.equal(f.session.snapshot().playbackUpdatedAt, prior.playbackUpdatedAt);
  deliver(); await status;
  assert.ok(f.session.snapshot().playbackUpdatedAt >= prior.playbackUpdatedAt);
  f.hook = () => {};
  await assert.rejects(f.session.control('STATUS'), /未知/);
  assert.equal(f.session.snapshot().playback, null);
  assert.equal(f.session.snapshot().playbackUpdatedAt, 0);
});
