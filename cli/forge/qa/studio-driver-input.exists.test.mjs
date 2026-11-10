import { test, expect } from 'bun:test';
import { predicateCode } from './studio-driver-input.mjs';
import { spawnSync } from 'node:child_process';
import { writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';

// The HUD creates Hatch_1 only when an egg's timer elapses, and every other predicate
// source resolves its target up front and asserts it. Without 'exists' a scenario could
// not wait for a control the product builds later, which is exactly the first-play path
// of every collect-raid pack. The emitted Luau is executed under Lune against a stub
// tree (one child present, one absent) so the wait is proven by running it.
test('an exists predicate waits for a child the product creates later', async () => {
  const code = predicateCode({ source: 'exists', target: 'Players.LocalPlayer.PlayerGui.Hud.Incubators.Hatch_1' }, 'collect-raid', '1');
  // The instance itself is never subscripted: it does not exist to subscribe to.
  expect(code).toContain('FindFirstChild("Hatch_1")');
  expect(code).toContain('ChildAdded');
  // `locate` walks from `game` with FindFirstChild, so the root needs the same
  // lookup every node has; only the leaf values are stubbed, not the walking.
  const stub = [
    'local serde=require("@lune/serde")',
    'local function node(name,children) return {Name=name,Children=children,FindFirstChild=function(self,n) return (self.Children or {})[n] end} end',
    'local incubators=node("Incubators",{Hatch_1=node("Hatch_1")})',
    'local hud=node("Hud",{Incubators=incubators})',
    'local player=node("Player",{PlayerGui=node("PlayerGui",{Hud=hud})})',
    'local services={Players={LocalPlayer=player},HttpService={JSONEncode=function(_,v) return serde.encode("json",v) end}}',
    'game=node("game",services)',
    'game.GetService=function(_,name) return services[name] or node(name,{}) end',
    ''
  ].join('\n');
  const { rokitShim } = { rokitShim: homedir() + '/.rokit/bin/lune' + (process.platform === 'win32' ? '.exe' : '') };
  const lune = existsSync(rokitShim) ? rokitShim : 'lune';
  mkdirSync('.omo/tmp', { recursive: true });
  // Present child: the predicate is already satisfied (no wait).
  writeFileSync('.omo/tmp/exists-present.luau', stub + code + '\nprint(game:GetService("HttpService"):JSONEncode({matched=matches()}))');
  const present = spawnSync(lune, ['run', '.omo/tmp/exists-present.luau'], { encoding: 'utf8' });
  expect(present.stderr).toBe('');
  expect(JSON.parse(present.stdout).matched).toBe(true);
  // Absent child: false until the HUD creates it, and this is what makes the wait real.
  writeFileSync('.omo/tmp/exists-absent.luau', stub.replace('Hatch_1=node("Hatch_1")', '') + code + '\nprint(game:GetService("HttpService"):JSONEncode({matched=matches()}))');
  const absent = spawnSync(lune, ['run', '.omo/tmp/exists-absent.luau'], { encoding: 'utf8' });
  expect(absent.stderr).toBe('');
  expect(JSON.parse(absent.stdout).matched).toBe(false);
});
