# survival-coop QA contract

The `execute_luau` steps in this genre's scenarios call a `ServerStorage.ForgeQA`
`BindableFunction`, invoked as `game.ServerStorage.ForgeQA:Invoke(...)`. This
genre is engine-free and cannot create that instance itself, so any pack built
from `survival-coop` MUST wire it up server-side (see
`genres/collect-raid/module/runtime/Server.luau` for the reference shape:
`Instance.new("BindableFunction")` named `ForgeQA`, parented to
`ServerStorage`, with `OnInvoke` dispatching on the first argument).

## Operations

- `Invoke("get", key)` — returns the current value for `key` (see table below).
- `Invoke("run")` — returns a table snapshot of the QA player's saved co-op
  run state (used to assert several fields restored together after rejoin).
- `Invoke("seed", fields)` — writes deterministic state directly into the QA
  player's save and persists it, for `rejoin` scenarios.

## Keys used by this genre's scenarios

| key | meaning |
| --- | --- |
| `schemaVersion` | the save schema version the loaded profile is on |
| `waveIndex` | the index of the most recent night wave that spawned |
| `lastWaveWon` | whether the most recent wave was successfully defended |
| `loadoutSlots` | number of loadout slots the player currently owns |
| `baseLoadoutSlots` | number of loadout slots a player owns before any slot-granting purchase |
| `crafted` | number of items the player has crafted |

## `run` fields

- `day` — the current day count of the co-op run.
- `floor` — the current floor/depth of the co-op run.
- `resources` — the player's current resource count.

## `seed` fields

- `day`, `floor`, `resources` — written into the save (used by `rejoin.yml` to simulate a saved co-op run).
