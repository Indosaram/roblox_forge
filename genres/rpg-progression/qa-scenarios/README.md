# rpg-progression QA contract

rpg-progression is engine-free and creates no QA instance itself. The implemented
Studio QA surface is the generic `ServerStorage.ForgeQA` **Folder** that
`core/infra/genre/Server.luau` binds when `RunService:IsStudio()`, so any pack
started through `Server.start` gets it with no pack-side wiring. It is not a single
`BindableFunction`: call `Invoke` on a child, never on `ForgeQA` itself.

## Operations

Children of the Folder (each a `BindableFunction` unless noted):

- `dispatch:Invoke(genre, action, args, playerId)` — runs a declared client action
  through the command transport; returns the `{ ok, reason? }` result.
- `snapshot:Invoke(genre, playerId)` — returns the genre's slice of the player's
  snapshot (for rpg-progression: `activeBosses`, ...).
- `commandServer:Invoke(playerId, requestId, actionId, args)` — declared durable
  server actions only.
- `beginClock:Invoke()` — freezes the clock and returns the base epoch;
  `advanceElapsed:Invoke(seconds)` advances from that base;
  `advanceTo:Invoke(epoch)` advances to an absolute epoch.
- `save:Invoke(playerId)` — returns the Result, then the save envelope;
  `restore:Invoke(playerId, envelope)` restores it.
- `revision:Invoke()` — the current state revision; `StateChanged` (a
  `BindableEvent`) fires with each new revision. Subscribe before acting, then await it.

## Scenarios

`contract-loop.yml` and `contract-rejoin.yml` (`contract_api: 1`) have `execute_luau`
code written against exactly this shape and are the only rpg-progression scenarios whose
code calls an implemented `ForgeQA` surface. They are `kind: smoke` plan documents: `forge qa
validate` and `forge qa plan` check their schema, and `forge qa run` (which executes only
`kind: native|studio` scenarios) refuses them. Prefer qualified actions such as
`rpg-progression:<action>` and read results from `snapshot`.

`core-loop.yml`, `first-purchase.yml`, `rejoin.yml` and `tutorial.yml` are legacy plan documents (`kind: smoke` /
`playtest`). Their `execute_luau` steps call a single-function
`ForgeQA:Invoke("get" | "progress" | "seed", ...)` with the keys and fields listed below.
**No code implements that function for rpg-progression**; the only `get`/`seed`
implementation is collect-raid's own single-function `ForgeQA` in
`genres/collect-raid/module/runtime/Server.luau`. Do not treat them as executable proof.

## Legacy keys (unimplemented)

| key | meaning |
| --- | --- |
| `schemaVersion` | the save schema version the loaded profile is on |
| `xp` | the player's current experience total |
| `region` | the id of the region the player is currently in/unlocked |
| `xpMultiplier` | the active xp multiplier (from a boost purchase) |

## Legacy `progress` fields (unimplemented)

- `level` — the player's current level.
- `region` — the id of the player's currently unlocked region.

## Legacy `seed` fields (unimplemented)

- `level`, `xp`, `region` — written into the save (used by `rejoin.yml` to simulate saved progression).
