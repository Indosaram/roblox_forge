# social-rp-fashion QA contract

The `execute_luau` steps in this genre's scenarios call a `ServerStorage.ForgeQA`
`BindableFunction`, invoked as `game.ServerStorage.ForgeQA:Invoke(...)`. This
genre is engine-free and cannot create that instance itself, so any pack built
from `social-rp-fashion` MUST wire it up server-side (see
`genres/collect-raid/module/runtime/Server.luau` for the reference shape:
`Instance.new("BindableFunction")` named `ForgeQA`, parented to
`ServerStorage`, with `OnInvoke` dispatching on the first argument).

## Operations

- `Invoke("get", key)` — returns the current value for `key` (see table below).
- `Invoke("avatar")` — returns a table snapshot of the QA player's saved
  avatar/outfit state (used to assert several fields restored together after
  rejoin).
- `Invoke("seed", fields)` — writes deterministic state directly into the QA
  player's save and persists it, for `rejoin` scenarios.

## Keys used by this genre's scenarios

| key | meaning |
| --- | --- |
| `schemaVersion` | the save schema version the loaded profile is on |
| `votesCast` | number of runway votes the player has cast in the current round |
| `outfitSlots` | number of outfit slots the player currently owns |
| `baseOutfitSlots` | number of outfit slots a player owns before any slot-granting purchase |

## `avatar` fields

- `outfit` — the id of the player's currently worn outfit/look.
- `slots` — the player's current outfit slot count.

## `seed` fields

- `outfit`, `slots` — written into the save (used by `rejoin.yml` to simulate a saved outfit and slot count).
