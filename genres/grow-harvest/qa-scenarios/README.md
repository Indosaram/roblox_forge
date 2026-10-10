# grow-harvest QA contract

The `execute_luau` steps in this genre's scenarios call a `ServerStorage.ForgeQA`
`BindableFunction`, invoked as `game.ServerStorage.ForgeQA:Invoke(...)`. This
genre is engine-free and cannot create that instance itself, so any pack built
from `grow-harvest` MUST wire it up server-side (see
`genres/collect-raid/module/runtime/Server.luau` for the reference shape:
`Instance.new("BindableFunction")` named `ForgeQA`, parented to
`ServerStorage`, with `OnInvoke` dispatching on the first argument).

## Operations

- `Invoke("get", key)` — returns the current value for `key` (see table below).
- `Invoke("snapshotCoins")` — captures the QA player's current coin balance so
  a later step can assert a delta against it via `get("lastCoinSnapshot")`.
- `Invoke("seed", fields)` — writes deterministic state directly into the QA
  player's save and persists it, for `rejoin` scenarios.

## Keys used by this genre's scenarios

| key | meaning |
| --- | --- |
| `schemaVersion` | the save schema version the loaded profile is on |
| `cropsReady` | number of planted crops whose growth timer has elapsed |
| `inventory` | number of harvested crops sitting in the player's inventory |
| `coins` | the player's current coin balance |
| `lastCoinSnapshot` | coin balance captured by the most recent `snapshotCoins` call |
| `plots` | number of plots the player currently owns |
| `basePlots` | number of plots a player owns before any plot-granting purchase |

## `seed` fields

- `crops` — array of `{ id, plantedAt }` to write into the save (used by `rejoin.yml` to simulate an elapsed growth timer).
