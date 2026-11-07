// New PERF1 frames through the unchanged production C bridge, for every BLE
// split and notification MTU. This does not impersonate physical hardware.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {rhythmRequest,performanceLine} from '../../../host/instrument-web/src/performance-protocol.js';
const executable=process.argv[2];
assert.ok(executable,'Pass compiled bridge_tests executable');
const hex=s=>Buffer.from(s).toString('hex');
let count=0;
for(const request of [rhythmRequest('11223344',{enabled:true,cue:0xffffffff,mask:0x801}),rhythmRequest('11223345',{poll:true}),rhythmRequest('11223346')]){
  const [,id,op]=request.split(',');
  const reply=performanceLine(`PERF1,${id},A,${op},0,BFFFFFFFFF801800001`);
  for(let split=1;split<request.length;split++)for(const mtu of [23,64,247]){
    const input=[`B ${hex(request.slice(0,split))}`,`B ${hex(request.slice(split))}`,'W'];
    const expected=['R 0','R 0',`W ${hex(request)}`];
    for(let i=0;i<reply.length;i+=3){input.push(`U ${hex(reply.slice(i,i+3))}`);expected.push('R 0');}
    for(let i=0;i<reply.length;i+=mtu-3){input.push(`N ${mtu}`);expected.push(`N ${hex(reply.slice(i,i+mtu-3))}`);}
    const run=spawnSync(executable,['--pipe'],{input:input.join('\n')+'\n',encoding:'utf8'});
    assert.equal(run.status,0,run.stderr);
    assert.deepEqual(run.stdout.trimEnd().replace(/\r/g,'').split('\n'),expected);count++;
  }
}
console.log(`PASS: ${count} rhythm PERF1 fragmented request/notification roundtrips through unchanged production bridge`);
