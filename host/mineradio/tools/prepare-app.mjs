import { cp, mkdir, readFile, writeFile, readdir } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const shared = resolve(root, '../instrument-web/dist');
await cp(shared, resolve(root, 'public/instrument'), { recursive: true });
for (const name of ['LICENSE', 'NOTICE.md']) await cp(resolve(root, name), resolve(root, 'public', name));
const assets = resolve(root, 'android/app/src/main/assets');
await mkdir(assets, { recursive: true });
// Android entry is maintained inside this Mineradio fork. The complete desktop
// UI remains in public/index.html with its own integration button.
for (const name of ['mobile.html', 'fpga', 'instrument', 'LICENSE', 'NOTICE.md']) await cp(resolve(root, 'public', name), resolve(assets, name), { recursive: true });
// Android runs the actual FPGAvedio player and its shared workbench. Only the
// platform adapter differs; no second player UI or conversion implementation.
for (const name of ['css', 'js', 'vendor', 'assets']) await cp(resolve(root, 'public', name), resolve(assets, name), { recursive: true });
for (const entry of await readdir(resolve(root, 'public'), { withFileTypes: true })) {
  if (entry.isFile() && /\.(js|json)$/.test(entry.name)) await cp(resolve(root, 'public', entry.name), resolve(assets, entry.name));
}
const desktop = (await readFile(resolve(root, 'public/index.html'), 'utf8'))
  .replace(/<link\s+href="https:\/\/fonts\.googleapis\.com\/[^>]+>/g, '');
// Bundle the already installed QR encoder; no external QR service receives
// the session URL. instrument-web already uses esbuild for its app bundle.
const requireShared = createRequire(resolve(root, '../instrument-web/package.json'));
const { build } = requireShared('esbuild');
await build({ entryPoints: [resolve(root, 'node_modules/qrcode/lib/browser.js')], bundle: true, format: 'iife', globalName: 'AndroidQRCode', platform: 'browser', minify: true, outfile: resolve(assets, 'fpga/qrcode.js') });
await cp(resolve(root, 'node_modules/qrcode/license'), resolve(assets, 'fpga/qrcode-LICENSE'));
await writeFile(resolve(assets, 'android.html'), desktop.replace('<head>', '<head>\n  <script src="fpga/native-rpc.js"></script>\n  <script src="fpga/qrcode.js"></script>\n  <script src="fpga/android-player.js"></script>\n  <script src="fpga/android-shell.js"></script>\n  <link rel="stylesheet" href="fpga/android-player.css">'));
await cp(resolve(root, 'build/icon.png'), resolve(root, 'android/app/src/main/res/drawable/fpga_launcher.png'));
await writeFile(resolve(assets, 'upstream.json'), JSON.stringify({ repository: 'https://github.com/XxHuberrr/Mineradio-paused', commit: 'd43de565acabfdc1a9c9820a27e81a98ccbebcef', license: 'GPL-3.0-only', version: JSON.parse(await readFile(resolve(root, 'package.json'))).version }));
console.log('Prepared Mineradio desktop integration and offline Android assets.');
