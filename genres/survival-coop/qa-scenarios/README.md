# survival-coop QA contract

survival-coop is engine-free and creates no QA instance itself. The implemented
Studio QA surface is the generic `ServerStorage.ForgeQA` **Folder** that
`core/infra/genre/Server.luau` binds when `RunService:IsStudio()`, so any pack
started through `Server.start` gets it with no pack-side wiring. It is not a single
`BindableFunction`: call `Invoke` on a child, never on `ForgeQA` itself.

## Operations

Children of the Folder (each a `BindableFunction` unless noted):

- `dispatch:Invoke(genre, action, args, playerId)` — runs a declared client action
  through the command transport; returns the `{ ok, reason? }` result.
- `snapshot:Invoke(genre, playerId)` — returns the genre's slice of the player's
  snapshot (for survival-coop: `lastWaveWon`, `balance`, ...).
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
code written against exactly this shape and are the only survival-coop scenarios whose
code calls an implemented `ForgeQA` surface. They are `kind: smoke` plan documents: `forge qa
validate` and `forge qa plan` check their schema, and `forge qa run` (which executes only
`kind: native|studio` scenarios) refuses them. Prefer qualified actions such as
`survival-coop:<action>` and read results from `snapshot`.

The other `contract_api: 1` scenarios here (`kind: native` / `kind: studio`) use the
native adapters and the Studio driver described in `studio-driver-contract.md`;
they do not call a function named `ForgeQA`.

`core-loop.yml`, `first-purchase.yml`, `rejoin.yml` and `tutorial.yml` are legacy plan documents (`kind: smoke` /
`playtest`). Their `execute_luau` steps call a single-function
`ForgeQA:Invoke("get" | "run" | "seed", ...)` with the keys and fields listed below.
**No code implements that function for survival-coop**; the only `get`/`seed`
implementation is collect-raid's own single-function `ForgeQA` in
`genres/collect-raid/module/runtime/Server.luau`. Do not treat them as executable proof.

## Legacy keys (unimplemented)

| key | meaning |
| --- | --- |
| `schemaVersion` | the save schema version the loaded profile is on |
| `waveIndex` | the index of the most recent night wave that spawned |
| `lastWaveWon` | whether the most recent wave was successfully defended |
| `loadoutSlots` | number of loadout slots the player currently owns |
| `baseLoadoutSlots` | number of loadout slots a player owns before any slot-granting purchase |
| `crafted` | number of items the player has crafted |

## Legacy `run` fields (unimplemented)

- `day` — the current day count of the co-op run.
- `floor` — the current floor/depth of the co-op run.
- `resources` — the player's current resource count.

## Legacy `seed` fields (unimplemented)

- `day`, `floor`, `resources` — written into the save (used by `rejoin.yml` to simulate a saved co-op run).
