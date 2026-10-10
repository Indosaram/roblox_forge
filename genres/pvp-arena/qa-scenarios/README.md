# pvp-arena QA contract

The `execute_luau` steps in this genre's scenarios call a `ServerStorage.ForgeQA`
`BindableFunction`, invoked as `game.ServerStorage.ForgeQA:Invoke(...)`. This
genre is engine-free and cannot create that instance itself, so any pack built
from `pvp-arena` MUST wire it up server-side (see
`genres/collect-raid/module/runtime/Server.luau` for the reference shape:
`Instance.new("BindableFunction")` named `ForgeQA`, parented to
`ServerStorage`, with `OnInvoke` dispatching on the first argument).

## Operations

- `Invoke("get", key)` — returns the current value for `key` (see table below).
- `Invoke("profile")` — returns a table snapshot of the QA player's saved
  profile (used to assert several fields restored together after rejoin).
- `Invoke("seed", fields)` — writes deterministic state directly into the QA
  player's save and persists it, for `rejoin` scenarios.

## Keys used by this genre's scenarios

| key | meaning |
| --- | --- |
| `schemaVersion` | the save schema version the loaded profile is on |
| `roundState` | current match round state (`"active"` or `"ended"`) |
| `loadoutSlots` | number of loadout slots the player currently owns |
| `baseLoadoutSlots` | number of loadout slots a player owns before any slot-granting purchase |

## `profile` fields

- `elo` — the player's current rank rating.
- `loadout` — the player's currently equipped loadout name.

## `seed` fields

- `elo`, `loadout` — written into the save (used by `rejoin.yml` to simulate a saved rank and loadout).
