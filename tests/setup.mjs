// 开发测试工具，不是脚本的部署依赖。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
const root = path.resolve(import.meta.dirname, '..');
const dir = path.join(root, '.test-tools');
fs.mkdirSync(dir, { recursive: true });
async function release(repo) {
  const r = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, {
    headers: { 'User-Agent': 'realm-manager-tests' }, signal: AbortSignal.timeout(30000),
  });
  if (!r.ok) throw Error(`${repo}: HTTP ${r.status}`);
  return r.json();
}
async function asset(meta, choose, output) {
  const a = meta.assets.find(choose);
  if (!a) throw Error(`Missing asset in ${meta.tag_name}: ${meta.assets.map(a => a.name)}`);
  const destination = path.join(dir, output);
  if (fs.existsSync(destination)) return destination;
  const r = await fetch(a.url, {
    headers: { 'User-Agent': 'realm-manager-tests', Accept: 'application/octet-stream' },
    signal: AbortSignal.timeout(45000),
  });
  if (!r.ok) throw Error(`${a.name}: HTTP ${r.status}`);
  const bytes = Buffer.from(await r.arrayBuffer());
  const digest = 'sha256:' + crypto.createHash('sha256').update(bytes).digest('hex');
  if (a.digest && a.digest !== digest) throw Error(`Digest mismatch: ${a.name}`);
  fs.writeFileSync(destination, bytes);
  console.log(`Downloaded ${a.name} (${bytes.length} bytes)`);
  return destination;
}
const [jq, realm] = await Promise.all([
  release('jqlang/jq'), release('zhboner/realm'),
]);
fs.writeFileSync(path.join(dir, 'realm-release.json'), JSON.stringify(realm));
if (process.platform === 'win32') await asset(jq, a => a.name === 'jq-windows-amd64.exe', 'jq.exe');
console.log(`Official release metadata: ${realm.tag_name}`);
