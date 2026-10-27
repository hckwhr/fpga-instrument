// Desktop layout reuses the workbench controls and their existing listeners.
// No second transport or device state is created here.
const $ = selector => document.querySelector(selector);
const bridge = window.top.instrumentBluetooth;
const shell = $('#workspace');
const content = document.createElement('div');
content.className = 'desktop-main';
const aside = document.createElement('aside');
aside.className = 'ble-sidebar';
aside.setAttribute('aria-labelledby', 'ble-sidebar-heading');
aside.innerHTML = `<header class="ble-heading"><span class="ble-symbol" aria-hidden="true">ᛒ</span><div><p class="ble-eyebrow">WIRELESS CONNECTION</p><h2 id="ble-sidebar-heading">连接你的乐器</h2></div></header><p class="ble-intro">扫描附近的 BLE 设备，选择「行者无疆」开始连接。</p><section class="ble-scan"><div class="ble-scan-title"><h3>附近设备</h3><span id="ble-scan-count">待扫描</span></div><div id="ble-scan-actions"></div><p id="ble-scan-message" role="status">开启设备电源与电脑蓝牙后，点击扫描。</p><ul id="ble-devices" aria-label="扫描到的 BLE 设备"></ul></section>`;
const siteHeader = $('.site-header');
const connectionContent = $('.device-content > div');
const devicePanel = $('#device-panel');
const summary = $('#device-panel > summary');
summary.firstElementChild.textContent = '演奏控制与曲谱上传';
summary.lastElementChild.textContent = '设备应答确认';
for (const node of [...shell.children]) {
  if (node !== siteHeader) content.append(node);
}
aside.insertBefore(siteHeader, aside.querySelector('.ble-scan'));
aside.append(connectionContent);
shell.append(content, aside);
const navigation = document.createElement('nav');
navigation.className = 'function-rail';
navigation.setAttribute('aria-label', 'FPGA 功能导航');
navigation.innerHTML = `<span class="rail-brand" aria-hidden="true">F<span>STUDIO</span></span>
  <a href="#source-section" aria-current="location"><span aria-hidden="true">01</span>导入转谱</a>
  <a href="#performance-home"><span aria-hidden="true">02</span>整理试听</a>
  <a href="#device-panel"><span aria-hidden="true">03</span>上传演奏</a>
  <a href="#library-section"><span aria-hidden="true">♫</span>曲谱库</a>
  <a href="#performance-visuals"><span aria-hidden="true">∿</span>电脑可视化</a>
  <a href="#ble-sidebar-heading"><span aria-hidden="true">ᛒ</span>BLE 连接</a>
  <a href="#board-visuals"><span aria-hidden="true">▥</span>FPGA 联动</a>
  <button type="button" id="rail-player"><span aria-hidden="true">◁</span>播放器</button>`;
shell.prepend(navigation);
const home = $('.result-panel');
home.id = 'performance-home';
$('#result-heading').textContent = '整理与试听';
home.querySelector('.section-number').textContent = '02';
// Put the transformation before the score display, so editing does not require
// scrolling past the entire piano roll after each recognition run.
home.querySelector('.stats').before($('#arrangement-panel'));
$('.source-panel').id = 'source-section';
$('.score-library').id = 'library-section';
// Keep the original controls/listeners. The physical order follows the task,
// with both optional visualization surfaces AFTER upload instead of between steps.
const computerVisuals = $('#performance-visuals');
$('.workspace-grid').replaceWith($('.source-panel'));
content.append($('.source-panel'), home, devicePanel, $('.score-library'), computerVisuals, $('#board-visuals'), $('footer'));
const workflow = document.createElement('nav');
workflow.className = 'workflow-steps'; workflow.setAttribute('aria-label', '歌曲上传流程');
workflow.innerHTML = '<a href="#source-section"><span>01</span>导入转谱</a><span aria-hidden="true">›</span><a href="#performance-home"><span>02</span>整理试听</a><span aria-hidden="true">›</span><a href="#device-panel"><span>03</span>上传演奏</a>';
content.prepend(workflow);
// Upload is the main operation; built-in demos are optional and stay available.
const builtIn = $('#board-heading').closest('section');
const builtInDetails = document.createElement('details');
builtInDetails.className = 'built-in-tools';
builtInDetails.innerHTML = '<summary>板端内置曲目与设备检测</summary>';
builtIn.replaceWith(builtInDetails); builtInDetails.append(builtIn);
$('.device-content').prepend($('#upload-heading').closest('section'));
summary.firstElementChild.textContent = '03 · 上传与板端播放';
const nextButtons = [];
for (const [parent, target, label] of [[$('.source-panel'), '#performance-home', '下一步：整理与试听 →'], [home, '#device-panel', '下一步：上传到 FPGA →'], [devicePanel.querySelector('.device-content'), '#board-visuals', '查看 FPGA 联动状态 →']]) {
  const link = document.createElement('a'); link.href = target; link.className = 'button workflow-next'; link.textContent = label;
  parent.append(link); nextButtons.push(link);
}
$('#rail-player').onclick = () => window.top.document.querySelector('#mode-player').click();
function jump(target, link) {
  if (target === devicePanel) devicePanel.open = true;
  const container = aside.contains(target) ? aside : content;
  if (document.documentElement.classList.contains('android-workbench')) {
    window.scrollTo({ top: window.scrollY + target.getBoundingClientRect().top - navigation.offsetHeight - 12, behavior: 'smooth' });
  } else if (matchMedia('(max-width: 800px)').matches) window.scrollTo({ top: container === aside ? aside.offsetTop : 0, behavior: 'smooth' });
  // Scroll only our pane: scrollIntoView also scrolls the host iframe's ancestors.
  const inset = container === content ? workflow.offsetHeight + 16 : 8;
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
  container.scrollTo({ top: container.scrollTop + target.getBoundingClientRect().top - container.getBoundingClientRect().top - inset, behavior: reducedMotion ? 'instant' : 'smooth' });
  for (const item of navigation.querySelectorAll('a')) {
    if (item === link) item.setAttribute('aria-current', 'location'); else item.removeAttribute('aria-current');
  }
  target.setAttribute('tabindex', '-1'); target.focus({ preventScroll: true });
}
for (const link of [...navigation.querySelectorAll('a'), ...workflow.querySelectorAll('a'), ...nextButtons]) link.onclick = event => {
  event.preventDefault(); jump($(link.getAttribute('href')), navigation.querySelector(`[href="${link.getAttribute('href')}"]`));
};
$('#connection-state').addEventListener('click', event => {
  event.stopImmediatePropagation();
  jump($('#ble-sidebar-heading'), navigation.querySelector('[href="#ble-sidebar-heading"]'));
}, true);
let scrollFrame = 0;
content.addEventListener('scroll', () => {
  if (scrollFrame) return;
  scrollFrame = requestAnimationFrame(() => {
    scrollFrame = 0;
    const top = content.getBoundingClientRect().top;
    const links = [...navigation.querySelectorAll('a')].filter(link => content.contains($(link.getAttribute('href'))));
    const atBottom = content.scrollTop + content.clientHeight >= content.scrollHeight - 2;
    const active = atBottom ? links.at(-1) : links.filter(link => $(link.getAttribute('href')).getBoundingClientRect().top <= top + workflow.offsetHeight + 35).at(-1) || links[0];
    for (const link of navigation.querySelectorAll('a')) {
      if (link === active) link.setAttribute('aria-current', 'location'); else link.removeAttribute('aria-current');
    }
  });
});
$('#ble-scan-actions').append(connectionContent.querySelector('.connection-controls'));
$('#connect').textContent = '扫描 BLE 设备';
$('#connect').classList.add('primary');
$('#serial-help').textContent = window.top.mineradioNative ? '使用手机原生 BLE 连接 ESP32-S3。点击扫描，在设备列表选择“行者无疆”。' : '使用 ESP32-S3 BLE 桥接。无需在 Windows 设置中配对；连接后请识别设备、确认板端响应。';
const cancel = document.createElement('button');
cancel.id = 'ble-scan-stop'; cancel.type = 'button'; cancel.className = 'button plain';
cancel.textContent = '停止扫描'; cancel.hidden = true;
$('#ble-scan-actions .connection-controls').append(cancel);
document.documentElement.classList.add('desktop-workbench');
devicePanel.open = true;
const list = $('#ble-devices');
if (window.top.mineradioNative) {
  $('#ble-scan-count').textContent = '手机蓝牙';
  $('#ble-scan-message').textContent = '点击扫描，授权附近设备后选择你的乐器。';
  list.hidden = true;
}
let scan = null;
const connectionMessage = () => {
  if (!scan || scan.scanning || scan.reason !== 'selected') return;
  const connected = !$('#disconnect').disabled;
  $('#ble-scan-message').textContent = connected ? 'BLE 已连接 · 板端状态以设备应答为准' : $('#connect').disabled ? '正在连接所选设备…' : '连接未建立或已断开，可重新扫描。';
};
function render(state) {
  scan = state;
  // UUID validation may reject before BleTransport emits `connecting`.
  // In that case no disabled-attribute mutation occurs to cancel the chooser.
  if (state.scanning && !$('#connect').disabled) bridge.cancel(state.requestId);
  cancel.hidden = !state.scanning;
  $('#ble-scan-count').textContent = `${state.devices.length} 个设备`;
  $('#ble-scan-message').textContent = state.scanning ? '正在扫描 · 点击设备连接' : ({ selected: '正在连接所选设备…', cancelled: '已停止扫描，可重新扫描。', timeout: '扫描已超时。请检查设备电源与蓝牙后重试。', navigation: '页面变化，扫描已取消。' }[state.reason] || '扫描已结束');
  list.replaceChildren();
  for (const device of state.devices) {
    const row = document.createElement('li');
    const button = document.createElement('button');
    button.type = 'button'; button.className = 'ble-device';
    button.disabled = !state.scanning;
    const name = document.createElement('strong'); name.textContent = device.deviceName;
    const detail = document.createElement('small'); detail.textContent = device.deviceId;
    const label = document.createElement('span');
    label.textContent = state.deviceId === device.deviceId ? '已选择' : '连接 ↗';
    const description = document.createElement('div'); description.append(name, detail);
    button.append(description, label);
    button.onclick = () => bridge.select(state.requestId, device.deviceId);
    row.append(button); list.append(row);
  }
  connectionMessage();
}
new MutationObserver(connectionMessage).observe($('#disconnect'), { attributes: true, attributeFilter: ['disabled'] });
new MutationObserver(connectionMessage).observe($('#connect'), { attributes: true, attributeFilter: ['disabled'] });
if (bridge) {
  // Arm the host before the workbench calls requestDevice in its click handler.
  $('#connect').addEventListener('click', () => bridge.scan(), true);
  const unsubscribe = bridge.onState(render);
  cancel.onclick = () => { if (scan?.scanning) bridge.cancel(scan.requestId); };
  // Validation/Bluetooth failures can occur before a chooser callback exists.
  new MutationObserver(() => {
    if (!$('#connect').disabled && scan?.scanning) bridge.cancel(scan.requestId);
  }).observe($('#connect'), { attributes: true, attributeFilter: ['disabled'] });
  window.addEventListener('pagehide', () => {
    if (scan?.scanning) bridge.cancel(scan.requestId);
    unsubscribe();
  }, { once: true });
}
window.dispatchEvent(new Event('resize'));
