# pvp-arena QA contract

pvp-arena is engine-free and creates no QA instance itself. The implemented
Studio QA surface is the generic `ServerStorage.ForgeQA` **Folder** that
`core/infra/genre/Server.luau` binds when `RunService:IsStudio()`, so any pack
started through `Server.start` gets it with no pack-side wiring. It is not a single
`BindableFunction`: call `Invoke` on a child, never on `ForgeQA` itself.

## Operations

Children of the Folder (each a `BindableFunction` unless noted):

- `dispatch:Invoke(genre, action, args, playerId)` — runs a declared client action
  through the command transport; returns the `{ ok, reason? }` result.
- `snapshot:Invoke(genre, playerId)` — returns the genre's slice of the player's
  snapshot (for pvp-arena: `phase`, ...).
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
code written against exactly this shape and are the only pvp-arena scenarios whose
code calls an implemented `ForgeQA` surface. They are `kind: smoke` plan documents: `forge qa
validate` and `forge qa plan` check their schema, and `forge qa run` (which executes only
`kind: native|studio` scenarios) refuses them. Prefer qualified actions such as
`pvp-arena:<action>` and read results from `snapshot`.

`core-loop.yml`, `first-purchase.yml` and `rejoin.yml` are legacy plan documents (`kind: smoke` /
`playtest`). Their `execute_luau` steps call a single-function
`ForgeQA:Invoke("get" | "profile" | "seed", ...)` with the keys and fields listed below.
**No code implements that function for pvp-arena**; the only `get`/`seed`
implementation is collect-raid's own single-function `ForgeQA` in
`genres/collect-raid/module/runtime/Server.luau`. Do not treat them as executable proof.

## Legacy keys (unimplemented)

| key | meaning |
| --- | --- |
| `schemaVersion` | the save schema version the loaded profile is on |
| `roundState` | current match round state (`"active"` or `"ended"`) |
| `loadoutSlots` | number of loadout slots the player currently owns |
| `baseLoadoutSlots` | number of loadout slots a player owns before any slot-granting purchase |

## Legacy `profile` fields (unimplemented)

- `elo` — the player's current rank rating.
- `loadout` — the player's currently equipped loadout name.

## Legacy `seed` fields (unimplemented)

- `elo`, `loadout` — written into the save (used by `rejoin.yml` to simulate a saved rank and loadout).
