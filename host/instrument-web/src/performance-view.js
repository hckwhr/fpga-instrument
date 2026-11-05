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
    <p class="hint" id="record-state" role="status">连接设备后可直接开始；首次使用会自动检查录音支持。</p>
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
  let saved=null,url=null,awake=false,action=null,actionMessage='';
  function setPollingPaused(paused) {
    window.dispatchEvent(new CustomEvent('instrument-performance-operation', {detail:paused}));
  }
  function render(){
    const state=session.snapshot(), d=device.snapshot();
    // Background STATUS / waveform queries briefly own the link. They must not
    // toggle a manual button between enabled/disabled while a user clicks it.
    // A click reserves priority, waits for the in-flight reply, then sends once.
    const available=d.connected&&!d.blocked&&!state.busy&&!action;
    $('#performance-probe').disabled=!available;
    for(const id of ['#keymap-apply','#keymap-reset'])$(id).disabled=!available||!state.capability;
    $('#record-start').disabled=!available;
    $('#record-start').textContent=action?.kind==='record' ? '正在准备录音…' : state.recording ? '● 正在录音' : '● 开始录音';
    $('#record-stop').disabled=!state.recording||state.stopping;
    $('#performance-hardware').textContent=state.capability?'设备支持键位设置与录音':'尚未检查支持；首次录音会自动检查';
    $('#performance-message').textContent=actionMessage||state.message;
    $('#record-state').textContent=!d.connected ? '请先连接 BLE 或 USB。' : d.blocked ? '通信状态未知，请断开重连后再试。' :
      actionMessage || (state.recording ? state.message : '点击开始录音；状态查询会自动让出通信，结束后可试听与保存。');
    setPollingPaused(Boolean(action)||state.busy);
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
  function waitForIdle(signal) {
    return new Promise((resolve,reject)=>{
      let unsubscribe=()=>{},timer;
      const finish=error=>{clearTimeout(timer);unsubscribe();signal.removeEventListener('abort',cancel);error?reject(error):resolve();};
      const cancel=()=>finish(new Error('录音准备已取消，未发送新的录音请求'));
      const check=()=>{
        const d=device.snapshot();
        if(signal.aborted)cancel();
        else if(!d.connected||d.blocked)finish(new Error('连接不可用，请重连后重试'));
        else if(!d.busy)finish();
      };
      unsubscribe=device.onChange(check);
      signal.addEventListener('abort',cancel,{once:true});
      timer=setTimeout(()=>finish(new Error('当前传输尚未结束，请完成上传或采样后重新点击')),12000);
      check();
    });
  }
  async function manual(kind,task) {
    if(action||session.snapshot().busy)return;
    const current={kind,controller:new AbortController()};action=current;
    actionMessage=device.snapshot().busy?'正在等待当前通信结束，随后执行你的操作…':'正在检查设备…';render();
    try {
      await waitForIdle(current.controller.signal);
      if(current.controller.signal.aborted)return;
      await task(current.controller.signal);
      actionMessage='';
    } catch(error){actionMessage=error.message;}
    finally{if(action===current)action=null;render();}
  }
  async function run(task){try{await task();}catch(error){actionMessage=error.message;render();}}
  $('#performance-probe').onclick=()=>manual('probe',async()=>{const reply=await session.command(0);if(reply.status===1){setNotes(reply.notes);$('#keymap-preset').value='custom';saveDraft();}});
  $('#keymap-apply').onclick=()=>{const draft=notes();void manual('map',()=>session.command(1,draft));};
  $('#keymap-reset').onclick=()=>manual('map',()=>session.command(2));
  $('#record-start').onclick=()=>manual('record',async signal=>{
    $('#record-preview').pause();
    if(!session.snapshot().capability)await session.command(0);
    if(signal.aborted)throw new Error('录音准备已取消，未发送新的录音请求');
    actionMessage='等待 FPGA 开始录音…';render();
    await session.command(3);
  });
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
  document.addEventListener('visibilitychange',()=>{if(document.hidden){action?.controller.abort();if(session.snapshot().recording)void run(()=>session.stop());}});
  window.addEventListener('instrument-visibility',event=>{if(!event.detail)action?.controller.abort();});
  window.addEventListener('instrument-mode',event=>{if(event.detail==='rhythm')action?.controller.abort();});
  const unsub=[session.onChange(render),device.onChange(render)];
  window.addEventListener('pagehide',()=>{action?.controller.abort();session.dispose();unsub.forEach(fn=>fn());setPollingPaused(false);if(url)URL.revokeObjectURL(url);},{once:true});
  render();return session;
}
