import test from 'node:test';
import assert from 'node:assert/strict';
import {packKeymap,unpackKeymap,performanceRequest,performanceLine,parsePerformanceLine,decodeRecordingBlock,recordingWav} from '../src/performance-protocol.js';
import {PerformanceSession} from '../src/performance-session.js';
const map=Array.from({length:12},(_,i)=>60+i);
const decode=line=>parsePerformanceLine(line.trim());
test('all 12 keys and octave extrema round-trip; reject invalid mappings',()=>{
  assert.deepEqual(unpackKeymap(packKeymap(map)),map);
  assert.deepEqual(unpackKeymap(packKeymap([48,83,...map.slice(2)])),[48,83,...map.slice(2)]);
  for(const bad of [[],[...map,60],map.map(()=>84),map.map(()=>NaN)])assert.throws(()=>packKeymap(bad));
  assert.throws(()=>unpackKeymap('F'.repeat(18)));
  assert.equal(performanceRequest('01234567',1,map).length,41);
});
test('CRC, boundaries, canonical stream shape and standard IMA decoding',()=>{
  const line=performanceLine(`PERF1,12345678,D,0000,0000,00,${'A'.repeat(160)}`);
  assert.equal(line.length,196);
  const block=decode(line), result=decodeRecordingBlock(block);
  assert.equal(result.pcm.length,240);assert.ok(result.pcm.every(x=>x===0));
  // Code 7 at index 0 produces +11 and advances index by eight (IMA standard).
  const ref=decodeRecordingBlock({...block,payload:'d3'+'A'.repeat(158)});
  assert.deepEqual([...ref.pcm.slice(0,3)],[11,41,104]);
  assert.throws(()=>decode(line.replace(',0000,0000,',',0001,0000,')));
  assert.throws(()=>decode(performanceLine(`PERF1,12345678,D,0000,0000,59,${'A'.repeat(160)}`)));
  const wav=recordingWav([new Int16Array([-32768,0,32767])]);
  const view=new DataView(wav.buffer);assert.equal(view.getUint32(24,true),12000);
  assert.equal(view.getUint32(40,true),6);assert.equal(view.getInt16(44,true),-32768);assert.equal(view.getInt16(48,true),32767);
});
function fixture(){
  let receiver,status,locked=false,blocked=false;
  const sent=[];
  const transport={connected:true,onData(fn){receiver=fn;return()=>{};},sendText(line){sent.push(line);return Promise.resolve();}};
  const device={transport,onChange(fn){status=fn;return()=>{};},acquireExclusive(){if(locked)throw Error('busy');locked=true;return({uncertain=false}={})=>{locked=false;blocked=uncertain;};}};
  const session=new PerformanceSession(device,{timeoutMs:1000,leaseMs:10000});
  const ack=(id,op,s=0)=>performanceLine(`PERF1,${id},A,${op},${s},${packKeymap(map)}`);
  return{session,sent,receive:line=>receiver(line),ack,status:s=>status(s),blocked:()=>blocked,locked:()=>locked};
}
async function start(f){const p=f.session.command(3);await new Promise(r=>setImmediate(r));const id=f.sent[0].split(',')[1];f.receive(f.ack(id,3));await p;return id;}
test('record actual PCM blocks, stop and end acknowledgement, export only complete take',async()=>{
  const f=fixture();try{
    const id=await start(f);
    const data=performanceLine(`PERF1,${id},D,0000,0000,00,${'A'.repeat(160)}`);
    for(const char of data)f.receive(new Uint8Array([char.charCodeAt(0)]));
    assert.equal(f.session.snapshot().seconds,.02);assert.equal(f.session.snapshot().saved,null);
    const p=f.session.stop();f.receive(f.ack(id,4));f.receive(performanceLine(`PERF1,${id},E,0001,0`));await p;
    assert.equal(f.session.snapshot().saved.bytes.length,524);assert.equal(f.locked(),false);assert.equal(f.blocked(),false);
  }finally{f.session.dispose();}
});
test('missing/duplicate/corrupt frames and wrong predictor fail closed; stale ID ignored',async()=>{
  for(const body of ['D,0001,0000,00','D,0000,0001,00','D,0000,0000,01']){
    const f=fixture();try{const id=await start(f);f.receive(performanceLine(`PERF1,DEADBEEF,E,0000,0`));assert.ok(f.locked());
      f.receive(performanceLine(`PERF1,${id},${body},${'A'.repeat(160)}`));assert.equal(f.session.snapshot().saved,null);assert.ok(f.blocked());
    }finally{f.session.dispose();}
  }
});
test('legacy firmware refusal and held-key busy never claim success or poison link',async()=>{
  for(const kind of ['legacy','busy']){
    const f=fixture();try{const p=f.session.command(kind==='legacy'?0:1,map);const rejected=assert.rejects(p);await new Promise(r=>setImmediate(r));
      const id=f.sent[0].split(',')[1];f.receive(kind==='legacy'?'ERR,COMMAND\n':f.ack(id,1,2));await rejected;
      assert.equal(f.session.snapshot().capability,null);assert.equal(f.blocked(),false);
    }finally{f.session.dispose();}
  }
});
test('disconnect invalidates take; cannot continue or save partial data',async()=>{
  const f=fixture();try{await start(f);f.status({connected:false,blocked:false});assert.equal(f.session.snapshot().recording,false);assert.equal(f.session.snapshot().saved,null);assert.equal(f.locked(),false);}finally{f.session.dispose();}
});
test('early ACK and recording data wait for write completion; rejected write cannot claim success',async()=>{
  for(const rejectWrite of [false,true]){
    let receiver,finish,reject;
    const transport={connected:true,onData(fn){receiver=fn;return()=>{};},sendText(line){
      const id=line.split(',')[1];queueMicrotask(()=>{
        receiver(performanceLine(`PERF1,${id},A,3,0,${packKeymap(map)}`));
        receiver(performanceLine(`PERF1,${id},D,0000,0000,00,${'A'.repeat(160)}`));
      });return new Promise((a,b)=>{finish=a;reject=b;});}};
    const device={transport,onChange(){return()=>{};},acquireExclusive(){return()=>{};}};
    const session=new PerformanceSession(device,{timeoutMs:500,leaseMs:10000});
    try{const p=session.command(3);const outcome=rejectWrite?assert.rejects(p):p;await new Promise(r=>setImmediate(r));
      assert.equal(session.snapshot().recording,false);
      if(rejectWrite)reject(Error('failed'));else finish();await outcome;
      assert.equal(session.snapshot().recording,!rejectWrite);
      assert.equal(session.snapshot().seconds,rejectWrite?0:.02);
    }finally{session.dispose();}
  }
});
