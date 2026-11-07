import assert from 'node:assert/strict';

// Runs against the production UI and transport with an explicitly simulated
// FPGA peer. The separate RTL pin bench proves actual RGB/DAC behavior.
export async function checkHardwareRhythm(evaluate) {
  const wait = expression => evaluate(`new Promise((resolve,reject)=>{let n=0;const p=()=>{if(${expression})resolve();else if(n++>250)reject(Error('Rhythm UI timeout: '+document.querySelector('#rhythm-status').textContent));else setTimeout(p,20)};p()})`);
  await evaluate(`(async()=>{
    const {performanceLine,packKeymap}=await import('./src/performance-protocol.js');
    let buffer='';window.rhythmPeer={guard:false,active:false,cue:0,keys:0,hits:0,guide:0};window.rhythmOps=[];
    window.onBleWrite=chunk=>{
      buffer+=new TextDecoder().decode(chunk);
      while(buffer.includes('\\n')){
        const at=buffer.indexOf('\\n'),line=buffer.slice(0,at);buffer=buffer.slice(at+1);
        let response;
        if(line==='HELLO')response='OK,HC05,1,9600,8N1,DEMO=TWINKLE+ODE\\n';
        else if(line==='STOP')response='OK,STOP\\n';
        else if(line.startsWith('PERF1,')){
          const [,id,operation,payload]=line.split(','),op=+operation,s=window.rhythmPeer;
          window.rhythmOps.push(op);
          if(op===6){const b=BigInt('0x'+payload);s.guard=s.active=Boolean(b&(1n<<44n));s.cue=Number((b>>12n)&0xffffffffn);s.hits=0;s.guide=Number(b&4095n);}
          const bits=(2n<<70n)|(BigInt(s.guard)<<69n)|(BigInt(s.active)<<68n)|(BigInt(s.cue)<<36n)|(BigInt(s.keys)<<24n)|(BigInt(s.hits)<<12n)|BigInt(s.guide);
          const encoded=op>=6?bits.toString(16).toUpperCase().padStart(18,'0'):packKeymap(Array.from({length:12},(_,i)=>60+i));
          response=performanceLine('PERF1,'+id+',A,'+op+','+(op===1?1:0)+','+encoded);
        }
        if(response)window.emitBle(new TextEncoder().encode(response));
      }
    };
    document.querySelector('#connect').click();
  })()`);
  await wait(`!document.querySelector('#disconnect').disabled`);
  await evaluate(`window.dispatchEvent(new CustomEvent('instrument-mode',{detail:'rhythm'}));
    const select=document.querySelector('#rhythm-device');select.value='fpga';select.dispatchEvent(new Event('change'));`);
  await wait(`!document.querySelector('#rhythm-start').disabled`);
  assert.equal(await evaluate(`document.querySelector('input[value="challenge"]').disabled`),true);
  await evaluate(`document.querySelector('#rhythm-start').click()`);
  await wait(`window.rhythmPeer.guide===1`);
  assert.equal(await evaluate(`document.querySelector('#rhythm-points').textContent`),'00000');
  assert.equal(await evaluate(`document.querySelector('#upload-start').disabled`),true);
  await evaluate(`document.querySelector('#rhythm-keys button').click()`);
  assert.equal(await evaluate(`document.querySelector('#rhythm-points').textContent`),'00000','Touch cannot fake a physical hit');
  // A press/release entirely between reports remains a confirmed sticky hit.
  await evaluate(`window.rhythmPeer.hits=1;window.rhythmPeer.guide=0;window.rhythmPeer.keys=0`);
  await wait(`document.querySelector('#rhythm-points').textContent==='00100'`);
  await wait(`window.rhythmPeer.guide===1`); // second C4 cue
  assert.equal(await evaluate(`document.querySelector('#rhythm-points').textContent`),'00100','No automatic re-hit');
  await evaluate(`window.rhythmPeer.hits=1;window.rhythmPeer.guide=0`);
  await wait(`document.querySelector('#rhythm-points').textContent==='00200'`);
  await evaluate(`document.querySelector('#rhythm-pause').click()`);
  await wait(`!window.rhythmPeer.active&&window.rhythmOps.at(-1)===2&&!document.querySelector('#rhythm-start').disabled`);
  assert.equal(await evaluate(`document.querySelector('#rhythm-start').textContent`),'继续练习');
  await evaluate(`window.dispatchEvent(new CustomEvent('instrument-mode',{detail:'fpga'}));document.querySelector('#disconnect').click()`);
  await wait(`document.querySelector('#disconnect').disabled`);
  console.log('PASS: production rhythm UI + mocked BLE PERF1: capability, stop autoplay, RGB cues, sticky physical hits, no local fake hits, exclusive ownership, pause/map restore');
}
