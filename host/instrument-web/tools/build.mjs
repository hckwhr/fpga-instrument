import { cp, mkdir, rm, writeFile, readFile, readdir } from "node:fs/promises";
import { build } from "esbuild";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dist = resolve(root, "dist");
await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });
for (const entry of ["index.html", "styles.css", "src"]) {
  await cp(resolve(root, entry), resolve(dist, entry), { recursive: true });
}
// BLE is primary; USB is an explicitly selected fallback using the same sessions.
await mkdir(resolve(dist, "model"), { recursive: true });
await cp(resolve(root, "node_modules/@spotify/basic-pitch/model/model.json"), resolve(dist, "model/model.json"));
await cp(resolve(root, "node_modules/@spotify/basic-pitch/model/group1-shard1of1.bin"), resolve(dist, "model/group1-shard1of1.bin"));
await build({ entryPoints: [resolve(root, "src/audio-worker.js")], bundle: true, format: "esm", platform: "browser", outfile: resolve(dist, "src/audio-worker.js"), minify: true, sourcemap: false });
await mkdir(resolve(dist, 'wasm'), { recursive: true });
for (const name of ['tfjs-backend-wasm.wasm', 'tfjs-backend-wasm-simd.wasm', 'tfjs-backend-wasm-threaded-simd.wasm']) {
  await cp(resolve(root, 'node_modules/@tensorflow/tfjs-backend-wasm/dist', name), resolve(dist, 'wasm', name));
}
await cp(resolve(root, 'THIRD_PARTY_LICENSES.md'), resolve(dist, 'THIRD_PARTY_LICENSES.md'));
await cp(resolve(root, 'node_modules/@spotify/basic-pitch/LICENSE'), resolve(dist, 'model/LICENSE'));
const lock = JSON.parse(await readFile(resolve(root, 'package-lock.json'), 'utf8'));
const apacheLicense = await readFile(resolve(root, 'node_modules/@spotify/basic-pitch/LICENSE'), 'utf8');
const licenses = [];
for (const [path, info] of Object.entries(lock.packages)) {
  if (!path || info.dev) continue;
  const folder = resolve(root, path);
  const metadata = JSON.parse(await readFile(resolve(folder, 'package.json'), 'utf8'));
  licenses.push(`${metadata.name} ${metadata.version} (${metadata.license || 'see package'})`);
  const files = (await readdir(folder)).filter(name => /^(license|copying|notice)(\.|$)/i.test(name));
  for (const file of files) licenses.push(await readFile(resolve(folder, file), 'utf8'));
  if (!files.length && metadata.license === 'Apache-2.0') licenses.push(apacheLicense);
}
await writeFile(resolve(dist, 'licenses.txt'), licenses.join('\n\n'));
await writeFile(resolve(dist, '.nojekyll'), '');
console.log(`Built static host application: ${dist}`);
