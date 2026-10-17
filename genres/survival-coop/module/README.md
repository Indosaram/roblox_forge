# survival-coop module

Reusable survival-coop loop: a wave scheduler that spawns escalating waves on a
fixed interval and resolves each one against a pack-supplied defense power. Game
packs register hooks and never edit this module.

```lua
local SurvivalCoop = require("genres/survival-coop/module/SurvivalCoop")
```

## API

- `SurvivalCoop.new(config, hooks) -> SurvivalCoop`
- `coop:tick(now) -> { index: number, enemies: number }?` — the first call arms
  the schedule; a wave is returned and `OnWaveSpawn` fires once `now` reaches the
  next wave time.
- `coop:defend(waveIndex, defensePower) -> boolean` — wins when
  `defensePower >= enemiesFor(waveIndex)`; always fires `OnWaveResolved`.
- `coop:enemiesFor(waveIndex) -> number` — `baseEnemies + (waveIndex - 1) * growth`.
- `coop:waveIndex() -> number` — waves spawned so far.
- `coop:nextWaveAt() -> number?` — absolute time of the next wave, nil before the
  first tick.
- `coop:secondsUntilNext(now) -> number` — clamped countdown.
- `coop:forceNext(now) -> wave?` — pulls the next wave forward to `now` (debug
  tooling) and resumes the normal cadence.

## config

| field | type | meaning |
|---|---|---|
| `waveInterval` | `number` | seconds between waves |
| `baseEnemies` | `number` | enemies in wave 1 |
| `growth` | `number` | extra enemies added each subsequent wave |

## hooks

| hook | context |
|---|---|
| `OnWaveSpawn` | `{ index: number, enemies: number }` when a wave spawns |
| `OnWaveResolved` | `{ index: number, enemies: number, defensePower: number, won: boolean }` after `defend` |

## Taming and mounts

- `TamingRuntime.new(config) -> Runtime` — server-authoritative wild stun gauges, capture (`Taming` rules in
  `core/domain/taming`, roll from `Rng:fork("capture")`), penned animals and the active ride. Idempotent per
  `(actor, requestId)`; no entitlement input exists on any call.
- `Mounts.catalog(content, rules)` / `Mounts.resolve(catalog, species, skin, zone)` — rideable is a species flag,
  speed and carry are species values, PvP opt-in zones clamp speed to one shared cap, and a paid skin resolves to the
  free same-species speed and carry (it never adds carry capacity).


## Extensions

A generic seam lets a lane plug a new durable system (taming, camp, contracts, market, ...) into the
running survival-coop game without editing `core/infra/genre/Session.luau` again.

**Server.** `Services.survivalExtensions: { Extension }?` (`core/domain/genre/Contract.luau`):

```lua
export type Extension = {
	id: string, -- lowercase-kebab, unique; snapshot key
	handles: (action: string) -> boolean,
	command: (actor, action, args, CommandContext, origin: "client" | "server", admit: () -> Result) -> Result,
	snapshot: ((actor) -> (StateData?, string?))?, -- merged as snapshot.survivalExtensions[id]
	recover: ((actor, max: number) -> any)?, -- swept with transfer/gathering/wildlife recovery
	epoch: ((actor, action) -> (number?, string?))?, -- else the ledger epoch is used
}
```

`Session.command` checks the four built-in ports (wildlife, gathering, transfer, settlement) first, then
routes to the first extension whose `handles(action)` is true, under the same busy/pending discipline.
The extension owns its idempotency/persistence and must call `admit()` (contract validation + rate
limit) before mutating. Actions must still be declared in the genre Contract and the durable policy;
unknown or undeclared actions are rejected before any extension is consulted.

**Bootstrap.** `module/Extensions.luau` holds `factories: { (ctx) -> (Extension & { close: (() -> Result)? })? }`.
`SurvivalBootstrap` builds every factory with
`ctx = { content, store() (Fenced over the bootstrap backend/options), backend, options, now, nowMillis, world, members(), personalTransfer(actor) }`,
exposes the results as `services.survivalExtensions` and calls each `close` (reverse order) from `api.close()`.
A factory returning nil is disabled.

**Client.** `module/ExtensionPanels.luau` holds `factories: { (ctx) -> { destroy }? }` with
`ctx = { ui = { components, theme }, locale, send(action, args) -> Result, onSnapshot(cb) -> unsubscribe }`.
`onSnapshot` delivers `snapshot.survivalExtensions` from the ForgeState channel; `send` issues a durable
command with a retained request id. The pack client only calls `ExtensionPanels.start`.

### Lane recipe

1. Add `genres/survival-coop/module/<Name>Extension.luau` exporting `factory(ctx)` that returns an Extension
   (wrap your runtime; persist through `ctx.store()`; release leases in `close`).
2. Append `require("./<Name>Extension").factory` to `factories` in `module/Extensions.luau`.
3. In `module/Contract.luau`: add each action descriptor to `actions` (id, args schema, origin, rate) and
   append the same ids (no namespace) to `extensionActions`.
4. Regenerate the durable policy: `lune run cli/forge codegen robango-island --durable`
   (never hand-edit `GenreDurable.luau`; `forge check` stage `econ` reports durable drift).
5. Optional UI: add `module/<Name>Panel.luau` exporting `factory(ctx)` and append it to
   `ExtensionPanels.factories`.
6. Spec it next to the module (`<Name>Extension.spec.luau`), then
   `lune run cli/forge test Session Options Server SurvivalBootstrap Extensions --quiet`.
