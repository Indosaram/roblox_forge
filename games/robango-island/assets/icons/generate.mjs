// Atlas generation and lossless PNG slicing. Never draws replacement artwork.
import { readFile } from 'node:fs/promises';
import { inflateSync, deflateSync } from 'node:zlib';
const root = 'games/robango-island/assets/icons';
const jobs = JSON.parse(await readFile(`${root}/jobs.json`, 'utf8'));
const keys = JSON.parse(await readFile(`${root}/keys.json`, 'utf8'));
if (process.argv.includes('--preview')) keys.splice(16);
if (process.argv.includes('--existing')) {
  let covered = 0;
  while (await Bun.file(`${root}/atlas-${String(covered + 1).padStart(2, '0')}.png`).exists()) covered++;
  keys.splice(covered * 16);
}
const provenance = [];
const verification = [];
const active = new Set();
let failed = false;

function crc(bytes) {
  let c = 0xffffffff;
  for (const b of bytes) {
    c ^= b;
    for (let n = 0; n < 8; n++) c = (c >>> 1) ^ ((c & 1) ? 0xedb88320 : 0);
  }
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, bytes) {
  const body = Buffer.concat([Buffer.from(type), bytes]);
  const out = Buffer.alloc(body.length + 8);
  out.writeUInt32BE(bytes.length, 0);
  body.copy(out, 4);
  out.writeUInt32BE(crc(body), out.length - 4);
  return out;
}
function encode(width, height, pixels) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 6;
  const scan = Buffer.alloc(height * (width * 4 + 1));
  for (let y = 0; y < height; y++) pixels.copy(scan, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR', header), chunk('IDAT', deflateSync(scan)), chunk('IEND', Buffer.alloc(0))]);
}
function decode(bytes) {
  const width = bytes.readUInt32BE(16), height = bytes.readUInt32BE(20);
  if (bytes[24] !== 8 || bytes[25] !== 6 || bytes[28] !== 0) throw new Error('Expected non-interlaced RGBA8 PNG');
  const data = [];
  for (let p = 8; p < bytes.length;) {
    const length = bytes.readUInt32BE(p), type = bytes.toString('ascii', p + 4, p + 8);
    if (type === 'IDAT') data.push(bytes.subarray(p + 8, p + 8 + length));
    p += length + 12;
  }
  const scan = inflateSync(Buffer.concat(data)), stride = width * 4, pixels = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    const filter = scan[y * (stride + 1)];
    for (let x = 0; x < stride; x++) {
      const a = x >= 4 ? pixels[y * stride + x - 4] : 0;
      const b = y ? pixels[(y - 1) * stride + x] : 0;
      const c = y && x >= 4 ? pixels[(y - 1) * stride + x - 4] : 0;
      let predictor = 0;
      if (filter === 1) predictor = a;
      else if (filter === 2) predictor = b;
      else if (filter === 3) predictor = Math.floor((a + b) / 2);
      else if (filter === 4) {
        const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        predictor = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      } else if (filter !== 0) throw new Error('Unknown PNG filter');
      pixels[y * stride + x] = (scan[y * (stride + 1) + x + 1] + predictor) & 255;
    }
  }
  return { width, height, pixels };
}

if (process.argv.includes('--generate')) {
  console.log('WORKING: Robango icons - remaining real-image atlases');
  let next = 0;
  await Promise.all(Array.from({ length: 4 }, async () => {
    while (!failed && next < jobs.length) {
      const job = jobs[next++], number = String(job.number).padStart(2, '0');
      if (await Bun.file(`${root}/atlas-${number}.png`).exists()) continue;
      const child = Bun.spawn(['bun', 'C:/Users/sook/code/rmb-lanes/_tools/imagegen.mjs', '--out', `${root}/atlas-${number}.png`, '--size', '1024x1024', '--quality', 'high', '--background', 'transparent', '--ref', `${root}/atlas-01.png`, '--prompt', job.prompt], { stdout: 'pipe', stderr: 'pipe' });
      active.add(child);
      const [exit, out, err] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      active.delete(child);
      console.log(`ATLAS ${number} exit=${exit} ${out.trim()} ${err.trim()}`);
      if (exit !== 0 && !failed) {
        failed = true;
        for (const running of active) running.kill();
      }
    }
  }));
  if (failed) { console.error('IMAGEGEN_FAIL stopping all icon production'); process.exit(1); }
}

console.log('WORKING: Robango icons - slicing and alpha validation');
const tiles = [];
for (let number = 1; (number - 1) * 16 < keys.length; number++) {
  const path = `${root}/atlas-${String(number).padStart(2, '0')}.png`;
  const atlas = decode(await readFile(path));
  for (let cell = 0; cell < 16; cell++) {
    const key = keys[(number - 1) * 16 + cell];
    if (!key) break;
    const insetX = Math.round(atlas.width / 4 * 0.05), insetY = Math.round(atlas.height / 4 * 0.05);
    const x = Math.round((cell % 4) * atlas.width / 4) + insetX, y = Math.round(Math.floor(cell / 4) * atlas.height / 4) + insetY;
    const w = Math.round((cell % 4 + 1) * atlas.width / 4) - x - insetX;
    const h = Math.round((Math.floor(cell / 4) + 1) * atlas.height / 4) - y - insetY;
    const pixels = Buffer.alloc(w * h * 4);
    for (let row = 0; row < h; row++) atlas.pixels.copy(pixels, row * w * 4, ((y + row) * atlas.width + x) * 4, ((y + row) * atlas.width + x + w) * 4);
    const visited = new Uint8Array(w * h), components = [];
    for (let p = 0; p < w * h; p++) {
      if (visited[p] || pixels[p * 4 + 3] < 8) continue;
      const points = [p]; visited[p] = 1;
      let touches = false;
      for (let q = 0; q < points.length; q++) {
        const n = points[q], cx = n % w, cy = Math.floor(n / w);
        touches ||= cx === 0 || cy === 0 || cx === w - 1 || cy === h - 1;
        for (const neighbor of [cx ? n - 1 : -1, cx < w - 1 ? n + 1 : -1, cy ? n - w : -1, cy < h - 1 ? n + w : -1]) {
          if (neighbor >= 0 && !visited[neighbor] && pixels[neighbor * 4 + 3] >= 8) { visited[neighbor] = 1; points.push(neighbor); }
        }
      }
      components.push({ points, touches });
    }
    const largest = Math.max(...components.map(c => c.points.length));
    for (const component of components) if (component.touches && component.points.length < largest / 4) {
      for (const p of component.points) pixels.fill(0, p * 4, p * 4 + 4);
    }
    for (let p = 0; p < w * h; p++) if (pixels[p * 4 + 3] < 8) pixels.fill(0, p * 4, p * 4 + 4);
    const resized = Buffer.from(await new Bun.Image(encode(w, h, pixels)).resize(96, 96).png().toBuffer());
    const tile = decode(resized);
    let clear = 0, visible = 0;
    for (let p = 3; p < tile.pixels.length; p += 4) { if (tile.pixels[p] === 0) clear++; if (tile.pixels[p] > 128) visible++; }
    if (!clear || !visible) throw new Error(`Invalid transparency or empty icon ${key}`);
    let borderVisible = 0;
    for (let n = 0; n < 96; n++) {
      for (const p of [n, 95 * 96 + n, n * 96, n * 96 + 95]) {
        if (tile.pixels[p * 4 + 3] >= 8) borderVisible++;
      }
    }
    verification.push({ key, atlas: number, cell: cell + 1, width: 96, height: 96, clear, visible, borderVisible });
    const file = `${root}/${key}.png`;
    await Bun.write(file, resized);
    tiles.push(tile);
    provenance.push(`| ${key}.png | atlas-${String(number).padStart(2, '0')}.png cell ${cell + 1} | gpt-image Responses API / imagegen.mjs | 2026-10-21 | ${clear} clear; ${visible} visible pixels |`);
  }
}
const columns = 16, width = columns * 96, height = Math.ceil(tiles.length / columns) * 96, pixels = Buffer.alloc(width * height * 4);
for (let i = 0; i < tiles.length; i++) {
  const x = i % columns * 96, y = Math.floor(i / columns) * 96;
  for (let row = 0; row < 96; row++) tiles[i].pixels.copy(pixels, ((y + row) * width + x) * 4, row * 96 * 4, (row + 1) * 96 * 4);
}
await Bun.write(`${root}/contact-sheet.png`, encode(width, height, pixels));
for (let start = 0; start < tiles.length; start += 128) {
  const count = Math.min(128, tiles.length - start), pageHeight = Math.ceil(count / columns) * 96;
  const page = pixels.subarray(start / columns * 96 * width * 4, (start / columns * 96 + pageHeight) * width * 4);
  await Bun.write(`${root}/contact-sheet-${String(start / 128 + 1).padStart(2, '0')}.png`, encode(width, pageHeight, page));
}
await Bun.write(`${root}/verification.json`, JSON.stringify({ count: tiles.length, icons: verification }, null, 2));
console.log(`ICONS_COMPLETE count=${tiles.length} size=96x96 alpha=verified contact=${width}x${height}`);
console.log(provenance.join('\n'));
