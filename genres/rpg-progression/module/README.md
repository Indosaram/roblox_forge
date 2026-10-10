# rpg-progression module

Reusable rpg-progression pieces: stats and leveling, quests, region unlocks, and
region boss schedules. Engine-free pure Luau; game packs pass a config and
register hooks instead of editing this module.

## Stats

`Stats.new(config, level?)` starts a state at `level` (default `1`) with 0 xp and
0 stat points. `Stats.addXp(state, amount)` consumes xp into whole levels and
returns `(level, levelsGained)`; each level gained grants `pointsPerLevel` stat
points. `Stats.xpForLevel(config, level)` is the xp needed to advance from
`level` to `level + 1`; `Stats.levelForXp(config, totalXp)` is the inverse over
cumulative xp.

### Stats config

| key              | type   | meaning                                             |
| ---------------- | ------ | --------------------------------------------------- |
| `base`           | number | xp to advance from level 1 to level 2 (`base * 1^exp`) |
| `exp`            | number | curve exponent; `xpForLevel(level) = base * level ^ exp` |
| `pointsPerLevel` | number | stat points granted per level gained                |

## Quests

`Quests.new(defs)` builds quest state from definitions of
`{ id, requirements = { { kind, target, count } }, reward = { coins?, xp? } }`.
`Quests.progress(state, { kind, target, count })` advances every unclaimed quest
requirement that matches, clamps at the target count, and returns the ids it just
completed. `Quests.isComplete(state, id)` reports completion.
`Quests.claim(state, id)` pays the reward exactly once and returns `nil` on a
repeat or an incomplete claim.

## Regions

`Regions.new(defs)` takes ordered `{ id, name, requiredLevel }` definitions.
`Regions.isUnlocked(regions, id, level)` is true at or above the threshold, or
after `Regions.unlock(regions, id)` (quest-gated content).
`Regions.unlockedIds(regions, level)` lists open regions in definition order, and
`Regions.requiredLevel(regions, id)` reads a threshold.

## BossSpawner

`BossSpawner.new(config, hooks)` builds a per-region schedule from
`regions = { { region, interval, bossIds = { ... } } }`, where each roster cycles
in order. `spawner:tick(now, isUnlocked)` arms each unlocked region on its first
tick, then rotates to the next roster id every interval and fires `OnBossSpawn`
for that id, unless the id is already active (still un-defeated from an earlier
spawn) — the roster keeps rotating either way, but a spawn that would duplicate
a live boss is skipped so `activeCount`/`isActive` always agree with the spawn
events a pack has actually received. `spawner:defeat(id)` removes an active boss
and fires `OnBossDefeated`, returning `false` when it was not active.
`spawner:isActive(id)` and `spawner:activeCount()` inspect the live set.

### Hooks

| hook             | ctx shape                              | when it fires                    |
| ---------------- | -------------------------------------- | -------------------------------- |
| `OnBossSpawn`    | `{ id: string, region: string, spawnedAt: number }` | a region spawns its next boss |
| `OnBossDefeated` | `{ id: string, region: string, spawnedAt: number }` | `defeat` removes an active boss |

## Example

```lua
local Stats = require("genres/rpg-progression/module/Stats")
local Quests = require("genres/rpg-progression/module/Quests")
local Regions = require("genres/rpg-progression/module/Regions")
local BossSpawner = require("genres/rpg-progression/module/BossSpawner")

local stats = Stats.new({ base = 100, exp = 1.5, pointsPerLevel = 3 })
Stats.addXp(stats, 250) -- level 2, 3 stat points

local regions = Regions.new({ { id = "plains", name = "Plains", requiredLevel = 1 } })

local spawner = BossSpawner.new({
	regions = { { region = "plains", interval = 120, bossIds = { "goblin-king" } } },
}, {
	OnBossSpawn = function(boss)
		print(boss.id .. " spawned in " .. boss.region)
	end,
})
spawner:tick(0, function(region)
	return Regions.isUnlocked(regions, region, stats.level)
end)
```
