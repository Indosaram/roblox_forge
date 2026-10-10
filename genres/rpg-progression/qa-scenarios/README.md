# rpg-progression QA contract

The `execute_luau` steps in this genre's scenarios call a `ServerStorage.ForgeQA`
`BindableFunction`, invoked as `game.ServerStorage.ForgeQA:Invoke(...)`. This
genre is engine-free and cannot create that instance itself, so any pack built
from `rpg-progression` MUST wire it up server-side (see
`genres/collect-raid/module/runtime/Server.luau` for the reference shape:
`Instance.new("BindableFunction")` named `ForgeQA`, parented to
`ServerStorage`, with `OnInvoke` dispatching on the first argument).

## Operations

- `Invoke("get", key)` — returns the current value for `key` (see table below).
- `Invoke("progress")` — returns a table snapshot of the QA player's saved
  progression (used to assert several fields restored together after rejoin).
- `Invoke("seed", fields)` — writes deterministic state directly into the QA
  player's save and persists it, for `rejoin` scenarios.

## Keys used by this genre's scenarios

| key | meaning |
| --- | --- |
| `schemaVersion` | the save schema version the loaded profile is on |
| `xp` | the player's current experience total |
| `region` | the id of the region the player is currently in/unlocked |
| `xpMultiplier` | the active xp multiplier (from a boost purchase) |

## `progress` fields

- `level` — the player's current level.
- `region` — the id of the player's currently unlocked region.

## `seed` fields

- `level`, `xp`, `region` — written into the save (used by `rejoin.yml` to simulate saved progression).
