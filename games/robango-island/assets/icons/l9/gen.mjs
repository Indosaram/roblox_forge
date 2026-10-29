// L9 painted restyle: generate atlases through imagegen.mjs. Usage: bun gen.mjs <id...>
// Atlas "a" is text-only; the others take l9/atlas-a.png as the style reference.
import { readFileSync, existsSync } from 'node:fs';
const dir = 'games/robango-island/assets/icons/l9';
const jobs = JSON.parse(readFileSync(`${dir}/jobs.json`, 'utf8'));
const style = readFileSync(`${dir}/style.txt`, 'utf8').trim();
export function prompt(atlas) {
  const subjects = Object.values(atlas.subjects).map((s, i) => `${i + 1}: ${s}`).join('; ');
  const ref = atlas.id === 'a' ? '' : ' Match the attached reference atlas exactly in outline weight, painterly shading, lighting and palette; do not copy its objects.';
  const n = Object.keys(atlas.subjects).length;
  const empty = n < 16 ? ` Cells ${n + 1} through 16 stay completely empty and transparent.` : '';
  return `${style}${ref} Row-major subjects: ${subjects}.${empty}`;
}
const ids = process.argv.slice(2);
await Promise.all(jobs.atlases.filter(a => ids.includes(a.id)).map(async atlas => {
  const out = `${dir}/atlas-${atlas.id}.png`;
  if (existsSync(out)) return console.log(`SKIP ${out}`);
  const args = ['bun', 'C:/Users/sook/code/rmb-lanes/_tools/imagegen.mjs', '--out', out, '--size', '1024x1024', '--quality', 'high', '--background', 'transparent', '--prompt', prompt(atlas)];
  if (atlas.id !== 'a') args.push('--ref', `${dir}/atlas-a.png`);
  const child = Bun.spawn(args, { stdout: 'pipe', stderr: 'pipe' });
  const [code, o, e] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
  console.log(`ATLAS ${atlas.id} exit=${code} ${o.trim().slice(-300)} ${e.trim().slice(-300)}`);
}));
