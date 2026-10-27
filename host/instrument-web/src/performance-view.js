import { PerformanceSession } from './performance-session.js';
import { packKeymap } from './performance-protocol.js';
import { midiNoteName } from './midi.js';

export function createPerformanceView(device) {
  const section = document.createElement('section'); section.id = 'live-performance'; section.className = 'live-performance';
  section.innerHTML = `<div class="section-heading"><h2>我的演奏</h2><span class="monitor-origin">实体键设置 · FPGA 录音回传</span></div>
    <div class="connection-controls"><button class="button" id="performance-probe">读取设备设置</button><span id="performance-hardware" class="hint">尚未确认固件支持</span></div>
    <div class="performance-cards"><article class="performance-card"><h3>12 键，自由定义</h3>
    <p class="hint">按实体键从左到右排列。自定义音高适用于复音与琴弦模式，保留当前音色和表情。</p>
    <div class="connection-controls"><label>键阶预设 <select id="keymap-preset"><option value="white">C 大调 · Do Re Mi</option><option value="chromatic">半音阶 · C4—B4</option><option value="pentatonic">五声音阶</option><option value="custom">自定义</option></select></label></div>
    <div class="keymap-grid" id="keymap-grid"></div>
    <div class="connection-controls"><button class="button primary" id="keymap-apply">应用到实体键</button><button class="button" id="keymap-reset">恢复板端默认</button></div>
    <p class="hint" id="keymap-state">编辑保存在本机；下发成功后才会改变实体键。请先松开所有键。</p></article>
    <article class="performance-card recording-card"><div class="record-heading"><h3>录下这一段</h3><span id="record-clock">00:00</span></div>
    <p class="hint">回传 FPGA 最终混音，包含和弦与表情效果。无需打开麦克风。</p>
    <div class="record-meter" aria-hidden="true"><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span></div>
    <div class="connection-controls"><button class="button primary" id="record-start">● 开始录音</button><button class="button" id="record-stop" disabled>■ 结束并回传</button></div>
    <p class="hint">最长 60 秒 · 12 kHz 压缩回传 · 保持连接与页面在前台。音频高频范围低于板端原始输出。</p>
    <div id="record-result" hidden><p id="record-description" class="hint"></p><audio id="record-preview" controls preload="metadata"></audio><button class="button" id="record-save">保存 WAV 录音</button></div>
    </article></div><p id="performance-message" class="hint" role="status">连接设备后读取扩展功能。</p>`;
  document.querySelector('footer').before(section);
  const $ = s => section.querySelector(s), session = new PerformanceSession(device);
  const presets = {white:[60,62,64,65,67,69,71,72,74,76,77,79],chromatic:Array.from({length:12},(_,i)=>60+i),pentatonic:[60,62,64,67,69,72,74,76,79,81,60,67]};
  const selects = [];
  for (let i=0;i<12;i++) {
    const label=document.createElement('label'), select=document.createElement('select');
    label.textContent=`键 ${i+1}`; select.setAttribute('aria-label',`左起第 ${i+1} 键音高`);
    for(let n=48;n<=83;n++) { const option=document.createElement('option');option.value=String(n);option.textContent=midiNoteName(n);select.append(option); }
    label.append(select);$('#keymap-grid').append(label);selects.push(select);
    select.onchange=()=>{$('#keymap-preset').value='custom';saveDraft();render();};
  }
  const notes=()=>selects.map(s=>Number(s.value));
  function setNotes(value){selects.forEach((s,i)=>s.value=String(value[i]));}
  function saveDraft(){try{localStorage.setItem('performance-keymap',JSON.stringify(notes()));}catch{/* Draft still usable for this session. */}}
  setNotes(presets.white);
  try {const saved=JSON.parse(localStorage.getItem('performance-keymap'));packKeymap(saved);setNotes(saved);$('#keymap-preset').value='custom';} catch{/* Default editable draft. */}
  $('#keymap-preset').onchange=()=>{const preset=presets[$('#keymap-preset').value];if(preset){setNotes(preset);saveDraft();render();}};
  let saved=null,url=null,awake=false;
  function render(){
    const state=session.snapshot(), d=device.snapshot();
    const available=d.connected&&!d.blocked&&!d.busy&&!state.busy;
    $('#performance-probe').disabled=!available;
    for(const id of ['#keymap-apply','#keymap-reset','#record-start'])$(id).disabled=!available||!state.capability;
    $('#record-stop').disabled=!state.recording||state.stopping;
    $('#performance-hardware').textContent=state.capability?'设备支持键位设置与录音':'尚未确认支持；旧固件需要更新';
    $('#performance-message').textContent=state.message;
    const seconds=Math.floor(state.seconds);$('#record-clock').textContent=`${String(Math.floor(seconds/60)).padStart(2,'0')}:${String(seconds%60).padStart(2,'0')}`;
    section.dataset.recording=String(state.recording);
    if(awake!==state.recording){
      awake=state.recording;
      window.top.mineradioNative?.request('keep-awake',{enabled:awake}).catch(()=>{});
    }
    $('#keymap-state').textContent=!state.capability?'草稿保存在本机；连接后读取设备设置。':state.capability.custom?
      (packKeymap(notes())===packKeymap(state.capability.notes)?'当前编辑值与 FPGA 已生效键位一致。':'草稿尚未应用。FPGA 当前使用另一组自定义键位。'):'FPGA 正在使用菜单默认键阶；下发后将使用这组自定义音高。';
    if(saved!==state.saved&&state.saved){
      saved=state.saved;$('#record-preview').pause();if(url)URL.revokeObjectURL(url);
      url=URL.createObjectURL(new Blob([saved.bytes],{type:'audio/wav'}));$('#record-preview').src=url;
      $('#record-result').hidden=false;$('#record-description').textContent=`${new Date(saved.created).toLocaleString()} · ${saved.seconds.toFixed(2)} 秒 · FPGA 真实演奏`;
    }
  }
  async function run(action){try{await action();}catch(error){$('#performance-message').textContent=error.message;}}
  $('#performance-probe').onclick=()=>run(async()=>{const reply=await session.command(0);if(reply.status===1){setNotes(reply.notes);$('#keymap-preset').value='custom';saveDraft();render();}});
  $('#keymap-apply').onclick=()=>run(()=>session.command(1,notes()));
  $('#keymap-reset').onclick=()=>run(()=>session.command(2));
  $('#record-start').onclick=()=>run(async()=>{$('#record-preview').pause();await session.command(3);});
  $('#record-stop').onclick=()=>run(()=>session.stop());
  $('#record-save').onclick=()=>run(async()=>{
    if(!saved)return;
    const name=`FPGA演奏-${new Date(saved.created).toISOString().replace(/[:.]/g,'-')}.wav`;
    if(window.top.mineradioNative){
      let binary='';for(let i=0;i<saved.bytes.length;i+=8192)binary+=String.fromCharCode(...saved.bytes.subarray(i,i+8192));
      await window.top.mineradioNative.request('save-file',{name,mime:'audio/wav',data:btoa(binary)});
    }else{const link=document.createElement('a');link.href=url;link.download=name;link.click();}
    $('#performance-message').textContent='已请求保存 WAV 录音';
  });
  document.addEventListener('visibilitychange',()=>{if(document.hidden&&session.snapshot().recording)void run(()=>session.stop());});
  const unsub=[session.onChange(render),device.onChange(render)];
  window.addEventListener('pagehide',()=>{session.dispose();unsub.forEach(fn=>fn());if(url)URL.revokeObjectURL(url);},{once:true});
  render();return session;
}
