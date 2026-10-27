// Platform adapter for the real FPGAvedio player. The player, audio graph and
// FPGA workbench continue to use their existing implementation.
(() => {
  'use strict';
  document.documentElement.classList.add('android-player');
  const native = window.mineradioNative;
  const originalFetch = window.fetch.bind(window);
  const downloads = new Map();
  const json = value => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } });
  window.androidAudioUrl = address => {
    const url = new URL(address, location.href);
    const base = new URL('.', location.href);
    if (url.origin !== base.origin || !url.pathname.startsWith(base.pathname)) throw new Error('音频必须先下载到手机');
    return url.href;
  };
  window.fetch = async (input, options) => {
    const url = new URL(input instanceof Request ? input.url : input, location.href);
    if (url.origin !== location.origin || !url.pathname.startsWith('/api/')) return originalFetch(input, options);
    if (!native) throw new Error('手机原生服务未就绪');
    if (url.pathname === '/api/login/status') return json(await native.request('music-status'));
    if (/\/status$/.test(url.pathname)) return json({ loggedIn: false, connected: false });
    if (url.pathname === '/api/logout') { downloads.clear(); return json(await native.request('music-logout')); }
    if (url.pathname === '/api/user/playlists') return json(await native.request('music-playlists', { offset: Number(url.searchParams.get('offset') || 0), limit: Number(url.searchParams.get('limit') || 48) }));
    if (url.pathname === '/api/playlist/tracks') return json(await native.request('music-playlist-tracks', { id: url.searchParams.get('id'), offset: Number(url.searchParams.get('offset') || 0), limit: Number(url.searchParams.get('limit') || 48) }));
    if (url.pathname === '/api/search') {
      const result = await native.request('music-search', { query: url.searchParams.get('keywords'), offset: Number(url.searchParams.get('offset') || 0), limit: Number(url.searchParams.get('limit') || 20) });
      return json({ ...result, songs: result.songs.map(song => ({ ...song, source: 'netease', platform: 'netease' })) });
    }
    if (url.pathname === '/api/song/url') {
      const id = url.searchParams.get('id');
      if (!downloads.has(id)) downloads.set(id, native.request('music-download', { id }).catch(error => { downloads.delete(id); throw error; }));
      return json(await downloads.get(id));
    }
    if (url.pathname === '/api/lyric') return json(await native.request('music-lyric', { id: url.searchParams.get('id') }));
    throw new Error('此音乐平台服务目前仅支持电脑版；手机可导入音频或搜索网易云公开曲目');
  };
  document.addEventListener('DOMContentLoaded', async () => {
    // Keep upstream layout and controls; only platform capabilities differ.
    window.searchProviderCanSearch = provider => provider === 'netease';
    window.maybeRunStartupLoginGuide = () => {};
    // Phone QR flow uses the same official authorization endpoint as desktop.
    // Cookies never cross the native bridge or reach localStorage.
    const account = document.createElement('button');
    account.id = 'android-account'; account.type = 'button'; account.textContent = '网易云登录';
    const panel = document.createElement('dialog'); panel.id = 'android-login';
    panel.innerHTML = '<form method="dialog"><button class="android-login-close" aria-label="关闭">×</button></form><h2>网易云账号</h2><p id="android-login-status" role="status">正在读取账号状态…</p><canvas id="android-login-qr" hidden></canvas><p id="android-login-help" hidden>保存二维码到相册，打开网易云音乐 → 扫一扫 → 相册，识别后确认登录，再返回这里。也可以用另一台设备扫码。</p><div class="android-login-actions"><button type="button" id="android-login-refresh">生成二维码</button><button type="button" id="android-login-save" hidden>保存到相册</button><button type="button" id="android-login-logout" hidden>退出账号</button></div>';
    document.body.append(account, panel);
    const status = panel.querySelector('#android-login-status');
    const canvas = panel.querySelector('canvas');
    const save = panel.querySelector('#android-login-save');
    const refresh = panel.querySelector('#android-login-refresh');
    const logout = panel.querySelector('#android-login-logout');
    const help = panel.querySelector('#android-login-help');
    let generation = 0, pollTimer = 0;
    const stopPoll = () => { generation++; clearTimeout(pollTimer); };
    const accountStatus = info => {
      window.loginStatus = info;
      window.loginStatusChecked = true;
      window.loginStatusCheckFailed = false;
      account.textContent = info.loggedIn ? (info.nickname || '网易云已登录') : '网易云登录';
      status.textContent = info.loggedIn ? '已登录：' + (info.nickname || '网易云用户') : '登录后按你的账号权限获取歌曲';
      logout.hidden = !info.loggedIn; refresh.hidden = !!info.loggedIn;
      if (info.loggedIn) { canvas.hidden = save.hidden = help.hidden = true; downloads.clear(); }
    };
    const showError = error => { status.textContent = error.message || String(error); };
    const beginLogin = async () => {
      stopPoll(); const run = generation; refresh.disabled = true;
      canvas.hidden = save.hidden = help.hidden = true;
      status.textContent = '正在获取网易云登录二维码…';
      try {
        const result = await native.request('music-login-key');
        if (run !== generation || !panel.open) return;
        await window.AndroidQRCode.toCanvas(canvas, result.url, { width: 240, margin: 2 });
        canvas.hidden = save.hidden = help.hidden = false;
        status.textContent = '等待扫码，请在网易云音乐里确认登录';
        const poll = async () => {
          if (run !== generation || !panel.open) return;
          if (document.hidden) { pollTimer = setTimeout(poll, 1800); return; }
          try {
            const info = await native.request('music-login-check', { key: result.key });
            if (run !== generation || !panel.open) return;
            if (info.code === 803 && info.loggedIn) { accountStatus(info); window.showToast?.('网易云登录成功，可以搜索播放'); return; }
            if (info.code === 800) { status.textContent = '二维码已过期，请重新生成'; save.hidden = true; return; }
            if (info.code === 803) { status.textContent = '授权已返回，但账号校验未通过，请重新登录'; return; }
            status.textContent = info.code === 802 ? '已扫码，请在网易云音乐中确认' : '等待扫码，请在网易云音乐里确认登录';
            pollTimer = setTimeout(poll, 1800);
          } catch (error) { if (run === generation) showError(error); }
        };
        pollTimer = setTimeout(poll, 1200);
      } catch (error) { if (run === generation) showError(error); }
      finally { if (run === generation) refresh.disabled = false; }
    };
    window.showLoginModal = async () => {
      if (panel.open) return;
      stopPoll(); const run = generation; panel.showModal();
      canvas.hidden = save.hidden = help.hidden = true;
      status.textContent = '正在读取账号状态…';
      try {
        const info = await native.request('music-status');
        if (run !== generation || !panel.open) return;
        accountStatus(info); if (!info.loggedIn) await beginLogin();
      } catch (error) { if (run === generation) showError(error); }
    };
    account.addEventListener('click', window.showLoginModal);
    panel.addEventListener('close', () => { stopPoll(); refresh.disabled = false; });
    refresh.addEventListener('click', beginLogin);
    save.addEventListener('click', async () => {
      save.disabled = true;
      try { await native.request('save-login-qr', { data: canvas.toDataURL('image/png').split(',')[1] }); status.textContent = '已保存到相册，请在网易云扫一扫中选择图片'; }
      catch (error) { showError(error); }
      finally { save.disabled = false; }
    });
    logout.addEventListener('click', async () => {
      stopPoll();
      try { accountStatus(await native.request('music-logout')); downloads.clear(); }
      catch (error) { showError(error); }
    });
    native?.request('music-status').then(info => { account.textContent = info.loggedIn ? (info.nickname || '网易云已登录') : '网易云登录'; }).catch(() => {});
    window.setSearchMode?.('netease');
    const wordmark = document.querySelector('#splash-wordmark');
    wordmark.textContent = 'FPGAvedio'; wordmark.setAttribute('aria-label', 'FPGAvedio');
    const header = document.createElement('div');
    header.id = 'android-brand'; header.textContent = 'FPGAvedio';
    document.body.append(header);
    const importButton = document.createElement('button');
    importButton.id = 'android-import'; importButton.type = 'button'; importButton.textContent = '导入音乐';
    importButton.addEventListener('click', () => window.triggerUploadInput('audio'));
    document.body.append(importButton);
    const importShared = async file => {
      const response = await originalFetch(window.androidAudioUrl(file.url));
      if (!response.ok) throw new Error('共享音频读取失败');
      await window.handleFiles([new File([await response.blob()], file.name, { type: file.mime || 'audio/mpeg' })]);
    };
    const receive = async event => {
      try {
        if (event.file || event.type === 'shared-audio') await importShared(event.file || event);
        if (event.text) { const input = document.querySelector('#search-input'); input.value = event.text; input.dispatchEvent(new Event('input', { bubbles: true })); }
      } catch (error) { window.showToast?.(error.message); }
    };
    if (native) {
      native.subscribe(event => { if (event.type === 'shared-audio' || event.type === 'shared-text') receive(event); });
      try { await receive(await native.request('ready')); } catch (error) { window.showToast?.(error.message); }
    }
  });
})();
