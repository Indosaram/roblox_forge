# collect-raid module

Genre-level coordinator for collect-and-raid games. It owns one core `Vault` per
team, wraps the core `Siege` schedule that opens raid windows, and reports game
events through hooks.

Game packs never copy or edit this module. They pass a `config` and register
`hooks`.

## `CollectRaid.new(config, hooks)`

`config` fields:

| field | type | meaning |
| --- | --- | --- |
| `teams` | `{ string }` | team names; each team gets its own core Vault |
| `siege.period` | `number` | seconds per siege cycle (see core `Siege`) |
| `siege.duration` | `number` | active window in seconds, must be `< period` |
| `siege.maxTake` | `number` | max items a single raid may move |

`hooks` fields (all optional):

| hook | ctx shape | when it fires |
| --- | --- | --- |
| `OnCollect` | `{ team: string, itemId: string, raidable: boolean }` | after `collect` deposits into a team vault |
| `OnRaid` | `{ attacker: string, defender: string, moved: number }` | after a raid moves at least one item (`moved > 0`); never fires for a successful window against an empty vault |
| `OnSiegePhase` | `{ phase: "idle" \| "active", secondsLeft: number }` | when `phase` observes a siege phase change |

## Methods

- `collect(team, itemId, raidable)` - deposits the item into that team's vault and
  calls `OnCollect`.
- `phase(elapsed)` - wraps core `Siege.phase`; returns `(phase, secondsLeft)` and
  calls `OnSiegePhase` only when the phase changes.
- `raid(attackerTeam, defenderTeam, elapsed, isShielded?)` - returns `(moved, nil)`
  on success, or `(0, reason)` with `reason` one of `"siege not active"`,
  `"shielded"`, or `"same team"`. Never moves non-raidable items.
- `counts()` - returns `{ [team]: number }` of raidable items per team.
- `totalCounts()` - returns `{ [team]: number }` of every item per team, raidable
  or locked; use this to confirm a deposit landed when `counts()` alone can't
  distinguish "no items" from "items exist but are all locked".

## Example

```lua
local CollectRaid = require("genres/collect-raid/module/CollectRaid")

local raid = CollectRaid.new({
	teams = { "red", "blue" },
	siege = { period = 300, duration = 60, maxTake = 5 },
}, {
	OnCollect = function(ctx)
		print(ctx.team .. " collected " .. ctx.itemId)
	end,
	OnRaid = function(ctx)
		print(ctx.attacker .. " took " .. ctx.moved .. " from " .. ctx.defender)
	end,
	OnSiegePhase = function(ctx)
		print("siege " .. ctx.phase .. " (" .. ctx.secondsLeft .. "s left)")
	end,
})

raid:collect("red", "egg-1", true)
raid:phase(300) -- active; OnSiegePhase fires
local moved, reason = raid:raid("red", "blue", 305)
```
