const pending = new Map(), listeners = new Set();
let sequence = 0;
if (window.NativeApp) {
  window.mineradioNative = {
    request(operation, payload = {}) {
      const id = String(++sequence);
      return new Promise((resolve, reject) => {
        const timeout = operation === 'save-file' ? 300000 : operation === 'music-download' ? 180000 : 60000;
        const timer = setTimeout(() => { pending.delete(id); reject(new Error('原生操作超时，请重试或重连设备')); }, timeout);
        pending.set(id, { resolve, reject, timer });
        try { NativeApp.request(id, operation, JSON.stringify(payload)); }
        catch (error) { clearTimeout(timer); pending.delete(id); reject(error); }
      });
    },
    subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    deliver(message) {
      if (message.id) {
        const p = pending.get(message.id);
        if (p) { clearTimeout(p.timer); pending.delete(message.id); message.error ? p.reject(new Error(message.error)) : p.resolve(message.result); }
      } else for (const fn of listeners) fn(message);
    },
  };
}
