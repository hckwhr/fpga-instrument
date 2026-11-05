// Touch navigation for the existing player; desktop hover panels are not a
// navigation model on a phone. Keep the original queues, library and controls.
document.addEventListener('DOMContentLoaded', () => {
  if (!window.mineradioNative) return;
  const button = document.createElement('button');
  button.id = 'android-menu'; button.type = 'button'; button.setAttribute('aria-label', '打开功能菜单');
  button.setAttribute('aria-expanded', 'false');
  button.innerHTML = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 6h16M4 12h16M4 18h16"/></svg>';
  const drawer = document.createElement('dialog'); drawer.id = 'android-drawer';
  drawer.innerHTML = '<div class="android-drawer-head"><div><strong>FPGAvedio</strong><small>你的音乐与 FPGA 乐器</small></div><button type="button" aria-label="关闭菜单" id="android-menu-close">×</button></div><div id="android-drawer-account"></div><nav aria-label="功能导航"><button type="button" data-page="home">音乐首页<span>搜索与继续播放</span></button><button type="button" data-page="queue">当前队列<span>查看正在播放的歌曲</span></button><button type="button" data-page="playlists">我的歌单<span>网易云与本地歌单</span></button><button type="button" data-page="fpga">FPGA 播放<span>转谱、上传与 BLE 连接</span></button><button type="button" data-page="visual">视觉设置<span>背景与播放器效果</span></button></nav><div id="android-drawer-import"></div><p class="android-drawer-note">音乐在手机试听，曲谱交给乐器演奏。</p>';
  document.body.append(button, drawer);
  const rhythmLink = document.createElement('button'); rhythmLink.type = 'button'; rhythmLink.dataset.page = 'rhythm';
  rhythmLink.innerHTML = '节奏大师<span>下落音符、跟练与节拍挑战</span>';
  drawer.querySelector('[data-page="fpga"]').after(rhythmLink);
  drawer.querySelector('#android-drawer-account').append(document.querySelector('#android-account'));
  drawer.querySelector('#android-drawer-import').append(document.querySelector('#android-import'));
  button.onclick = () => { drawer.showModal(); button.setAttribute('aria-expanded', 'true'); };
  drawer.querySelector('#android-menu-close').onclick = () => drawer.close();
  drawer.addEventListener('close', () => button.setAttribute('aria-expanded', 'false'));
  drawer.addEventListener('click', event => { if (event.target === drawer && event.clientX >= drawer.getBoundingClientRect().right) drawer.close(); });
  for (const id of ['android-account', 'android-import']) document.querySelector('#' + id).addEventListener('click', () => drawer.close());

  const now = document.createElement('section'); now.id = 'android-now-playing';
  now.setAttribute('aria-label', '当前音乐');
  now.innerHTML = '<div class="android-section-label">YOUR MUSIC / 你的音乐</div><div class="android-now-main"><div id="android-now-art" aria-hidden="true"><img hidden alt=""><span>♪</span></div><div class="android-now-copy"><p class="android-now-kicker">当前歌曲</p><h1 id="android-now-title">从一首歌开始</h1><p id="android-now-artist">搜索音乐，或从侧边菜单导入</p></div></div><button type="button" id="android-send-current" disabled><span>当前歌曲 → FPGA</span><svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M5 12h14m-6-6 6 6-6 6"/></svg></button><p id="android-now-hint">选择歌曲后，可直接带入 FPGA 转谱工作台</p>';
  document.querySelector('#empty-home .empty-home-shell').prepend(now);
  const send = now.querySelector('#android-send-current');
  let importing = false, previousArt = '';
  const syncTrack = () => {
    if (document.hidden) return;
    const song = window.currentCoverSong?.() || window.playQueue?.[window.currentIdx];
    const available = !!(song && window.audio?.currentSrc);
    const title = available ? song.name || '当前歌曲' : '从一首歌开始';
    const artist = available ? song.artist || '本地音乐' : '搜索音乐，或从侧边菜单导入';
    if (now.querySelector('#android-now-title').textContent !== title) now.querySelector('#android-now-title').textContent = title;
    if (now.querySelector('#android-now-artist').textContent !== artist) now.querySelector('#android-now-artist').textContent = artist;
    send.disabled = importing || !available;
    const src = available ? window.songCoverSrc?.(song, 400) || '' : '';
    if (src !== previousArt) {
      previousArt = src;
      const img = now.querySelector('img'); img.hidden = !src;
      if (src) img.src = window.coverProxySrc(src); else img.removeAttribute('src');
      now.querySelector('#android-now-art').classList.toggle('has-art', !!src);
    }
    if (!available && !document.querySelector('#control-title-text').textContent) document.querySelector('#control-title-text').textContent = '尚未播放';
  };
  now.querySelector('img').onerror = () => { now.querySelector('img').hidden = true; now.querySelector('#android-now-art').classList.remove('has-art'); };
  send.onclick = async () => {
    if (importing || send.disabled) return;
    importing = true; send.disabled = true;
    try { await window.importCurrentSongToFpga(); }
    finally { importing = false; syncTrack(); }
  };
  syncTrack();
  const trackTimer = setInterval(syncTrack, 800);
  window.addEventListener('pagehide', () => clearInterval(trackTimer), { once: true });

  const panel = document.querySelector('#playlist-panel');
  const setPage = page => {
    document.body.dataset.androidPage = page;
    drawer.querySelectorAll('[data-page]').forEach(item => item.setAttribute('aria-current', item.dataset.page === page ? 'page' : 'false'));
  };
  const showHome = () => {
    setPage('home'); panel.classList.remove('show', 'peek');
    window.homeForcedOpen = true; window.homeSuppressed = false;
    window.updateEmptyHomeVisibility?.();
  };
  const showLibrary = tab => {
    setPage(tab === 'queue' ? 'queue' : 'playlists');
    window.switchPlaylistTab(tab);
    panel.classList.add('show'); panel.classList.remove('peek');
    window.flushDeferredQueuePanel?.('android-navigation');
    if (tab === 'playlists') window.refreshUserPlaylists?.(true);
  };
  // Disable only automatic edge hover, retaining explicit button navigation.
  window.isPlaylistEdgeTrigger = () => false;
  const originalPeek = window.setPeek;
  window.setPeek = (element, on, key) => { if (key !== 'pl') return originalPeek(element, on, key); };
  window.playlistPanelPinned = false;
  window.togglePlaylistPanel = force => {
    const open = ['queue', 'playlists'].includes(document.body.dataset.androidPage);
    if (force === false || (force !== true && open)) showHome();
    else showLibrary('queue');
  };
  window.openHomeLibrary = window.openHomeDashboardLibrary = () => showLibrary('playlists');
  window.toggleMiniQueue = event => { event?.stopPropagation(); showLibrary('queue'); };
  const sub = panel.querySelector('.fx-sub'); if (sub) sub.textContent = '你的音乐，按自己的顺序播放';
  const close = document.createElement('button'); close.className = 'fx-mini-btn'; close.textContent = '返回';
  close.onclick = showHome; panel.querySelector('.queue-head-act').append(close);
  drawer.querySelector('nav').addEventListener('click', event => {
    const page = event.target.closest('[data-page]')?.dataset.page; if (!page) return;
    drawer.close();
    if (page === 'fpga' || page === 'rhythm') { document.querySelector(`#mode-${page}`).click(); return; }
    document.querySelector('#mode-player').click();
    if (page === 'visual') { window.toggleFxPanel(true); return; }
    if (page === 'home') showHome(); else showLibrary(page);
  });
  // Search stays reachable even when a library page is active.
  document.querySelector('#search-input').addEventListener('focus', () => {
    drawer.close(); window.closePlaylistPanelSoft?.('search');
  });
  showHome();
});
