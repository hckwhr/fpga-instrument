import test from 'node:test';
import assert from 'node:assert/strict';
import {RhythmSession} from '../src/rhythm-session.js';
import {rhythmRequest, parsePerformanceLine, performanceLine, packKeymap} from '../src/performance-protocol.js';
const pitches = [60,62,64,65,67,69,71,72,74,76,77,79];
const turn = () => new Promise(resolve => setImmediate(resolve));
function statusBits({guard=false,active=false,cue=0,keys=0,hits=0,guide=0}={}) {
  return ((2n<<70n)|(BigInt(guard)<<69n)|(BigInt(active)<<68n)|(BigInt(cue)<<36n)|
    (BigInt(keys)<<24n)|(BigInt(hits)<<12n)|BigInt(guide)).toString(16).toUpperCase().padStart(18,'0');
}
function fixture(options={}) {
  let receive, changed, locked=false, blocked=false;
  const sent=[], commands=[], hits=[], errors=[];
  let state={guard:false,active:false,cue:0,keys:0,hits:0,guide:0};
  const transport={connected:true,onData(fn){receive=fn;return()=>{};},sendText(line){
    sent.push(line);const p=line.trim().split(',');const op=+p[2];
    if (options.drop?.(op)) return Promise.resolve();
    let payload=packKeymap(pitches), code=op===1?1:0;
    if(op===6){const b=BigInt(`0x${p[3]}`);state={...state,guard:!!(b&(1n<<44n)),active:!!(b&(1n<<44n)),cue:Number((b>>12n)&0xffffffffn),guide:Number(b&4095n),hits:0};}
    if(op>=6)payload=statusBits(state);
    if(options.reject?.(op))code=3;
    receive(performanceLine(`PERF1,${p[1]},A,${op},${code},${payload}`));
    return options.write ? options.write(op) : Promise.resolve();
  }};
  const device={transport,snapshot:()=>({identity:true}),request:async c=>commands.push(c),
    onChange(fn){changed=fn;return()=>{};},acquireExclusive(){assert.equal(locked,false);locked=true;return({uncertain=false}={})=>{locked=false;blocked=uncertain;};}};
  const session=new RhythmSession(device,{timeoutMs:40,pollMs:10000,onStatus:s=>hits.push(s),onError:e=>errors.push(e),...options.session});
  return {session,sent,commands,hits,errors,receive,changed,locked:()=>locked,blocked:()=>blocked,
    setState:s=>{state={...state,...s};},getState:()=>state};
}
test('rhythm wire fields use 12-bit masks and 32-bit cue; tagged ACK is distinct from keymap',()=>{
  const line=rhythmRequest('12345678',{enabled:true,cue:0xffffffff,mask:0x801});
  assert.equal(line.length,41);assert.equal(line.split(',')[3],'0000001FFFFFFFF801');
  const r=parsePerformanceLine(performanceLine(`PERF1,12345678,A,7,0,${statusBits({guard:true,active:true,cue:0xffffffff,keys:0x801,hits:0x800,guide:1})}`).trim());
  assert.equal(r.cue,0xffffffff);assert.equal(r.hits,0x800);assert.equal(r.keys,0x801);assert.equal(r.guide,1);
  assert.throws(()=>rhythmRequest('12345678',{mask:1}));
  assert.throws(()=>rhythmRequest('12345678',{enabled:true,mask:4096}));
  assert.throws(()=>parsePerformanceLine(performanceLine(`PERF1,12345678,A,7,0,${'0'.repeat(18)}`).trim()));
});
test('open stops auto-play; exclusive lease spans cues; short taps sticky, duplicate polls do not replay; close restores map',async()=>{
  const f=fixture();await f.session.open(pitches);
  assert.deepEqual(f.commands,['STOP']);assert.ok(f.locked());
  assert.deepEqual(f.sent.map(l=>+l.split(',')[2]),[7,6,0,1,6]);
  assert.ok(await f.session.setCue(3));
  f.setState({hits:1,guide:2,keys:0}); // complete tap before polling
  f.session.accept(await f.session.request(7));f.session.accept(await f.session.request(7));
  assert.equal(f.hits.at(-2).newHits,1);assert.equal(f.hits.at(-1).newHits,0);
  f.setState({hits:3,guide:0,keys:2});f.session.accept(await f.session.request(7));assert.equal(f.hits.at(-1).newHits,2);
  f.setState({keys:0});await f.session.close();assert.equal(f.locked(),false);assert.equal(f.blocked(),false);
  assert.equal(+f.sent.at(-1).split(',')[2],2);f.session.dispose();
});
test('ACK before write completion cannot enable hardware session',async()=>{
  let finish;const f=fixture({write:op=>op===7?new Promise(r=>{finish=r;}):Promise.resolve()});
  const opening=f.session.open(pitches);await turn();assert.equal(f.session.running,false);assert.equal(f.sent.length,1);
  finish();await opening;assert.equal(f.session.running,true);
  // Avoid holding cleanup's poll write in this test.
  const close=f.session.close();await turn();finish();await close;f.session.dispose();
});
test('unmatched IDs ignored, timeout blocks uncertain session; old firmware is never silently emulated',async()=>{
  const f=fixture({drop:op=>op===7});
  const opening=f.session.open(pitches);await turn();
  f.receive(performanceLine(`PERF1,DEADBEEF,A,7,0,${statusBits()}`));
  await assert.rejects(opening,/未确认/);assert.equal(f.blocked(),true);assert.equal(f.session.running,false);f.session.dispose();
});
test('disconnect clears ownership and cannot auto-resume; inactive/stale state cannot advance game',async()=>{
  const f=fixture();await f.session.open(pitches);await f.session.setCue(1);
  assert.throws(()=>f.session.accept({...f.getState(),cue:f.session.cue-1}),/不一致/);
  assert.throws(()=>f.session.accept({...f.getState(),active:false}),/停止/);
  f.changed({connected:false,blocked:false});assert.equal(f.locked(),false);assert.equal(f.session.running,false);
  assert.equal(await f.session.setCue(2),false);f.session.dispose();
});
test('close during setup waits for confirmation and sends stop, never leaves an armed session',async()=>{
  const f=fixture();const opening=f.session.open(pitches);const closing=f.session.close();
  await opening;await closing;assert.equal(f.session.running,false);assert.equal(f.locked(),false);assert.equal(f.getState().active,false);f.session.dispose();
});
