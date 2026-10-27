// A2 pilot uploader: Open Cloud Assets API create + operation poll.
// Usage (repo root): bun games/robango-island/assets/blender/upload.mjs <env-file> <out-json> <file>...
// .fbx -> assetType Model, .png -> assetType Decal. Key: ROBLOX_ASSET_API_KEY, else ROBLOX_STAGING_API_KEY.
// Creator: FORGE_OWNER_USER_ID. The key is never printed.
import { readFileSync, writeFileSync } from 'node:fs';
import { basename, extname } from 'node:path';

const [envFile, outJson, ...files] = process.argv.slice(2);
if (!envFile || !outJson || files.length === 0) {
  console.error('usage: upload.mjs <env-file> <out-json> <file>...');
  process.exit(2);
}
if (files.length > 10) {
  console.error('refused: at most 10 uploads per batch');
  process.exit(2);
}
const env = Object.fromEntries(
  readFileSync(envFile, 'utf8')
    .split(/\r?\n/)
    .map(l => l.match(/^([A-Z0-9_]+)=(.*)$/))
    .filter(Boolean)
    .map(m => [m[1], m[2].replace(/^"|"$/g, '')]),
);
const keyName = env.ROBLOX_ASSET_API_KEY ? 'ROBLOX_ASSET_API_KEY' : 'ROBLOX_STAGING_API_KEY';
const key = env[keyName];
const userId = env.FORGE_OWNER_USER_ID;
if (!key || !userId) {
  console.error('missing key or FORGE_OWNER_USER_ID');
  process.exit(1);
}
console.log(`key=${keyName} creator user=${userId}`);

const types = { '.fbx': ['Model', 'model/fbx'], '.png': ['Decal', 'image/png'] };
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function create(file) {
  const [assetType, mime] = types[extname(file).toLowerCase()];
  const name = basename(file, extname(file));
  const request = {
    assetType,
    displayName: name,
    description: 'Robango Island A2 asset-pipeline pilot (generated in Blender).',
    creationContext: { creator: { userId: String(userId) } },
  };
  const form = new FormData();
  form.append('request', JSON.stringify(request));
  form.append('fileContent', new Blob([readFileSync(file)], { type: mime }), basename(file));
  const res = await fetch('https://apis.roblox.com/assets/v1/assets', {
    method: 'POST',
    headers: { 'x-api-key': key },
    body: form,
  });
  const body = await res.text();
  return { file, assetType, status: res.status, body: safeJson(body) };
}

function safeJson(t) {
  try { return JSON.parse(t); } catch { return t.slice(0, 500); }
}

async function poll(opPath) {
  for (let i = 0; i < 40; i++) {
    const res = await fetch(`https://apis.roblox.com/assets/v1/${opPath}`, { headers: { 'x-api-key': key } });
    const body = safeJson(await res.text());
    if (res.status === 429) { await sleep(5000); continue; }
    if (body && body.done) return { status: res.status, body, polls: i + 1 };
    await sleep(Math.min(2000 * (i + 1), 10000));
  }
  return { status: 'timeout' };
}

const results = [];
for (const file of files) {
  const created = await create(file);
  const entry = { ...created };
  const op = created.body && created.body.path;
  if (created.status === 200 && op) entry.operation = await poll(op);
  const resp = entry.operation?.body?.response;
  entry.assetId = resp?.assetId ?? null;
  entry.moderation = resp?.moderationResult ?? null;
  console.log(`${basename(file)} type=${entry.assetType} http=${entry.status} assetId=${entry.assetId} moderation=${JSON.stringify(entry.moderation)}`);
  if (!entry.assetId) console.log(`  detail: ${JSON.stringify(entry.operation ?? entry.body).slice(0, 400)}`);
  results.push(entry);
}
writeFileSync(outJson, JSON.stringify(results, null, 2));
