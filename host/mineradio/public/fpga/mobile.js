const $ = id => document.getElementById(id);
const bridge = window.mineradioNative;
let currentFile, currentUrl, ready = false;
const frame = $('instrument');
const status = message => { $('music-status').textContent = message; };
function tab(instrument) {
  $('music-panel').hidden = instrument; frame.hidden = !instrument;
  $('music-tab').setAttribute('aria-pressed', String(!instrument)); $('instrument-tab').setAttribute('aria-pressed', String(instrument));
}
$('music-tab').onclick = () => tab(false); $('instrument-tab').onclick = () => tab(true);
function selectFile(file) {
  if (!file.size || file.size > 80 * 1024 * 1024) throw new Error('请选择 1..80 MB 音频');
  if (/\.(ncm|qmc\w*|lrc)$/i.test(file.name)) throw new Error('专属加密文件或歌词不能读取，请导入普通音频');
  if (currentUrl) URL.revokeObjectURL(currentUrl);
  currentFile = file; currentUrl = URL.createObjectURL(file);
  $('music-audio').src = currentUrl; $('current-title').textContent = file.name; $('convert-current').disabled = false;
  status('已读取音频，可以先试听，再导入转谱。');
}
async function receiveFile(info) {
  const response = await fetch(info.url);
  if (!response.ok) throw new Error('读取共享音频失败');
  selectFile(new File([await response.blob()], info.name, { type: info.mime || 'audio/mpeg' }));
}
$('import-local').onclick = () => $('local-audio').click();
$('local-audio').onchange = () => { try { if ($('local-audio').files[0]) selectFile($('local-audio').files[0]); } catch (e) { status(e.message); } };
$('convert-current').onclick = () => {
  if (!currentFile || !ready) return status('转谱工作台正在加载，请稍候');
  $('music-audio').pause(); tab(true);
  frame.contentWindow.postMessage({ type: 'mineradio-audio', file: currentFile }, location.origin);
};
window.addEventListener('message', e => { if (e.origin === location.origin && e.source === frame.contentWindow && e.data?.type === 'instrument-ready') ready = true; });
async function search(query) {
  if (!bridge) throw new Error('此入口请在 Android App 中使用；电脑版请打开 Mineradio 主界面');
  status('正在获取网易云曲目信息…'); $('search-results').replaceChildren();
  const result = await bridge.request('music-search', { query });
  for (const song of result.songs) {
    const li = document.createElement('li'), copy = document.createElement('div'), title = document.createElement('strong'), artist = document.createElement('span'), button = document.createElement('button');
    title.textContent = song.name; artist.textContent = song.artist; copy.append(title, artist); button.textContent = '读取音频';
    button.onclick = async () => {
      button.disabled = true; status('正在读取该曲可用的普通音频…');
      try { const file = await bridge.request('music-download', { id: song.id, name: song.name }); await receiveFile(file); }
      catch (error) { status(`${error.message}；也可从音乐 App 导出普通音频后导入。`); }
      finally { button.disabled = false; }
    };
    li.append(copy, button); $('search-results').append(li);
  }
  status(result.songs.length ? `找到 ${result.songs.length} 首；能否读取取决于该曲实际开放的音频。` : '未找到歌曲，请改用曲名搜索或导入普通音频。');
}
$('search-form').onsubmit = async e => { e.preventDefault(); try { await search($('keywords').value); } catch (error) { status(error.message); } };
bridge?.subscribe(message => {
  if (message.type === 'shared-audio') receiveFile(message).catch(e => status(e.message));
  if (message.type === 'shared-text') { $('keywords').value = message.text; search(message.text).catch(e => status(e.message)); }
});
bridge?.request('ready').then(result => {
  if (result?.file) return receiveFile(result.file);
  if (result?.text) { $('keywords').value = result.text; return search(result.text); }
}).catch(e => status(e.message));
