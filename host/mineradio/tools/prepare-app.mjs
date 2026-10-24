import { cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const shared = resolve(root, '../instrument-web/dist');
await cp(shared, resolve(root, 'public/instrument'), { recursive: true });
for (const name of ['LICENSE', 'NOTICE.md']) await cp(resolve(root, name), resolve(root, 'public', name));
const assets = resolve(root, 'android/app/src/main/assets');
await mkdir(assets, { recursive: true });
// Android entry is maintained inside this Mineradio fork. The complete desktop
// UI remains in public/index.html with its own integration button.
for (const name of ['mobile.html', 'fpga', 'instrument', 'LICENSE', 'NOTICE.md']) await cp(resolve(root, 'public', name), resolve(assets, name), { recursive: true });
await writeFile(resolve(assets, 'upstream.json'), JSON.stringify({ repository: 'https://github.com/XxHuberrr/Mineradio-paused', commit: 'd43de565acabfdc1a9c9820a27e81a98ccbebcef', license: 'GPL-3.0-only', version: JSON.parse(await readFile(resolve(root, 'package.json'))).version }));
console.log('Prepared Mineradio desktop integration and offline Android assets.');
