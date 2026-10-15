# Genre Spec — declarative genres, core presentation, derived QA

Status: implemented.
Scope: `forge new <slug> --genre X` must produce a *playable* pack — a real HUD, a real
world, audio, and executable native QA bound to that pack — without hand-work.

Every claim about existing code carries a `path:line` citation. Line numbers are against
worktree `forge-production-release-wave1` at `f625793`.

---

## 0. Baseline the design must move

`lune run cli/forge sweep` records one independent step per variant for each of
`generate`, `files`, `build`, `inspect`, `spec`, `hud`, `world`, `audio`,
`nativeQa`, `surface`, `load` and `quality`
(`cli/forge/commands/sweep.luau:42`). `build/sweep/final/sweep.md` reports **0/7** variants fully passed:

| genre | generate | files | build | inspect | nativeQa | surface |
| --- | --- | --- | --- | --- | --- | --- |
| collect-raid | PASS | PASS | PASS | PASS | FAIL | PASS |
| grow-harvest, pvp-arena, rpg-progression, social-rp-fashion, survival-coop, survival-coop (crafting) | PASS | PASS | PASS | PASS | FAIL | FAIL |

Four distinct causes, each already visible in the code:

1. **No executable native QA per pack.** Only `survival-coop` ships `kind: native`
   scenarios; every other genre ships only `kind: smoke` / `kind: playtest`
   (`genres/*/qa-scenarios/*.yml`). Sweep's native step records "no executable scenarios"
   explicitly (`cli/forge/commands/sweep.luau:562-570`). The nine survival-coop natives all
   declare `pack: primal-isles` or `pack: fixture-survival`, so 8/9 fail against a
   freshly generated pack (`build/sweep/final/sweep.md`).
2. **The generated client is a debug panel.** `genrerender` writes
   `src/client/<Pascal>Client.client.luau` as `Client.start({controls=require(Shared.GenreUI)})`
   (`cli/forge/lib/genrerender.luau:97-99`), and that client's only surface is a
   `ScrollingFrame` of `JSONEncode`d snapshots (`core/infra/genre/Client.luau:16-23,182`).
   collect-raid is the exception: its planner renders a client that binds the genre-owned
   Hud runtime (`genres/collect-raid/generation/planner.luau:3388-3450`, requiring
   `genres/collect-raid/module/runtime/Hud` at `:1429`). Sweep classifies the two shapes at
   `cli/forge/commands/sweep.luau:420-431` and gates on it at `:661-668`.
3. **Zero world parts.** Only collect-raid has a world module
   (`genres/collect-raid/module/WorldBuilder.luau:967`) and survival-coop a crafting
   development island (`genres/survival-coop/module/SurvivalWorld.luau:43`); the generic
   server builds only a floor, a spawn and one prompt station per prompt control
   (`core/infra/genre/Server.luau:128-159`). Sweep counts place parts
   (`cli/forge/commands/sweep.luau:448-471`) and reports them at `:688`, but does not gate.
4. **Scenario UI targets do not exist.** `genrecontract.Generator.qa.targets`
   (`cli/forge/lib/genrecontract.luau:54`) names control ids that the generated
   `GenreUI.luau` must expose; sweep computes the unmatched set
   (`cli/forge/commands/sweep.luau:632-640`) but only reports it.
5. **Bare scenario names collide.** `qa run --scenario <name>` scans `registry.order` and
   takes the first `<genre>/qa-scenarios/<name>.yml` it finds
   (`cli/forge/commands/qa.luau:313-328`). Every genre ships `contract-loop.yml` and
   `contract-rejoin.yml`, so a bare name resolves by directory order, not by pack.

The design keeps every existing contract and adds one data artifact and one presentation layer.

---

## 1. The Genre Spec

### 1.1 Location and versioning

`genres/<genre>/genre-spec.yml` — data only, co-located with the module it describes
(`genres/<genre>/module/Contract.luau`), the generator (`genres/<genre>/generator.luau`) and
the scenarios (`genres/<genre>/qa-scenarios/`). The package manifest
(`cli/forge/lib/genrecontract.luau:57-62`) gains one field:

```yaml
# genres/<genre>/forge-package.yml
genre_contract:
  api: 1
  generator: generator.luau
  runtime: module/Contract.luau
  spec: genre-spec.yml        # new; required once the spec lands
```

`api` is the spec schema version; `version` is the spec's own semver, bumped whenever the
spec's *meaning* changes (a new action binding, a moved zone, a changed golden path). The
spec is validated against the runtime descriptor that already exists, so it can never drift
into a second implementation of the rules (`cli/forge/lib/genrecontract.luau:247-365` is the
model for that validation).

### 1.2 What the spec declares, and what it must reuse

The spec is a *binding* document. Every rule it mentions already exists somewhere in
`core/domain` or `genres/<id>/module`; the spec only names it so presentation, world and QA
can be derived. Where a value already exists in `PackConfig.configs[<genre>]`
(`core/domain/genre/Contract.luau:95`), the spec stores a **path into that config**, not a
copy.

Top-level keys: `api`, `version`, `id`, `runtime`, `resources` (§1.3), `entities` (§1.4),
`actions` (§1.5), `loop` (§1.6), `ui` (§1.7), `world` (§1.8), `audio` (§1.9),
`economy` (§1.10), `qa` (§1.11), `overrides` (§2.5, optional). `runtime` must equal
`RuntimeContract.id` (`core/domain/genre/Contract.luau:78`).

### 1.3 `resources` — currencies

Today the currency list is hard-coded per render (`cli/forge/lib/genrerender.luau:28`,
`currencies = { "Coins" }`) while the authoritative balance lives in each adapter's snapshot
(`collect-raid` → `coins`, `genres/collect-raid/generator.luau:180`; survival → `balance`,
`genres/survival-coop/generator.luau:74`).

```yaml
resources:
  - id: coins                  # the snapshot field name, verbatim
    name: Coins                # the text the HUD shows, next to the value
    nameKey: coin_label        # locale key (see the note below)
    assetKey: collect-raid-coin # must be a declared procgen/audio key (§3.3)
    initial: 0
    hud: { slot: resource-bar, order: 1 }
```

The spec never defines earn/spend rules: those are the adapter's, and QA asserts them
through state deltas (§1.11).

**Display text is declared, never derived.** Every player-facing string carries its own
field — `resources[].name`, `entities[].name`, `actions[].control.label`, `loop[].goal` —
beside the locale key that localises it, and the validator rejects a display string that is
missing, empty, whitespace-padded, or shaped like an identifier (`coin_label`, `harvest_crop`,
`buy-seed`). This is a hard rule because of a reproduced defect: the first wave rendered the
*key* as the label, so a player read `coin_label 9`, `harvest_crop` and `loop_buy (1/4)`. The
same rule is what makes the offline gate meaningful — `core/ui-kit/genre/HudText.luau` renders
the HUD's strings and `forge sweep`'s `hud` column runs `HudText.violations` over the same
plan, so a raw id in the visible text fails the sweep rather than being noticed in a
screenshot.

The locale key is still required: `genrespec.localeEntries` pairs every declared key with its
display string and the pack's `locale/strings.csv` is generated from that pair (en-us carries
the declared text; other locale columns are empty, which is how a Roblox localization table
says "not translated yet").

### 1.4 `entities` — catalog rows

Entities are the *content* the HUD renders and the world places. Their `kind` vocabulary is
closed and drawn from what the six generators already emit:

| kind | source of truth | example |
| --- | --- | --- |
| `source`, `creature`, `egg`, `merge-family` | `collect-raid` planner config | `genres/collect-raid/generation/planner.luau:1002,1171` |
| `crop`, `plot` | grow-harvest schema | `genres/grow-harvest/module/Schema.luau` |
| `boss`, `quest` | rpg-progression | `genres/rpg-progression/module/BossSpawner.luau`, `Quests.luau` |
| `outfit`, `theme`, `round` | social-rp-fashion | `genres/social-rp-fashion/module/Outfit.luau`, `ThemeRound.luau` |
| `item`, `recipe`, `structure`, `wildlife` | survival content document | `core/domain/survival/Content.luau` |
| `defense` | survival wave mode | `genres/survival-coop/module/GardenDefense.luau` |

```yaml
entities:
  - id: ember
    kind: source
    name: Ember spring                   # display text (§1.3)
    nameKey: source_ember
    assetKey: collect-raid-ember-egg
    configPath: [ sources, ember ]     # into PackConfig.configs["collect-raid"]
```
`configPath` is how the spec points at data instead of duplicating it; it resolves with the
same dense-table rules the domain already enforces (`core/domain/genre/Validation.luau:9-26`).

### 1.5 `actions` — player actions, bound to existing domain actions

This is the load-bearing section. Each row binds one existing `Contract.Action`
(`core/domain/genre/Contract.luau:49-54`) to one player-facing control
(`core/infra/genre/Options.luau:9-15`), and states the preconditions and effects **by name**
so QA can assert them.

```yaml
actions:
  - action: collect-raid:buy-source      # RuntimeContract.actions[i].id, namespaced
    control:
      id: collect-raid:buy-source        # regex at core/infra/genre/Options.luau:56
      label: Buy source                  # the button/prompt text, never the key
      labelKey: buy_source
      kind: prompt                       # button | prompt | player-button (Options.luau:66)
      args: ["ember"]                    # arity-checked (Options.luau:77)
      ui: { slot: action-bar, order: 1 }
    preconditions:
      - ref: insufficient-coins          # the adapter's own refusal reason
      - ref: rate-limited                # Executor.debitRate (Executor.luau:194-209)
    effects:
      - { path: [coins], delta: -50 }    # golden-path expectation (§1.11)
      - { path: [sources, ember, owned], delta: 1 }
```

The `ref` list points at refusal reasons the adapter already returns; the spec does not
re-implement them. Two preconditions are free for every genre: origin/arity/schema validation
(`core/domain/genre/Executor.luau:164-193`) and the token bucket (`:194-209`). Durable
actions stage through `Executor.stageClient`/`stageServer` (`:240-281`) and the spec binds
them by naming the action in the pack's durable policy (`core/infra/genre/Options.luau:202-292`).

### 1.6 `loop` — core loop stages

Stages are ordered and keyed to events the runtime already emits
(`RuntimeContract.events`, `core/domain/genre/Contract.luau:83`; collect-raid's seven events
at `genres/collect-raid/module/Contract.luau:17`; survival's three at
`genres/survival-coop/module/Contract.luau:176`).

```yaml
loop:
  - id: buy
    actions: ["collect-raid:buy-source"]
    goal: Buy a source       # the objective line's text, never the key
    goalKey: loop_buy
  - id: hatch
    actions: ["collect-raid:hatch"]
    on: OnCollect            # the event that closes the stage
  - id: raid
    actions: ["collect-raid:raid"]
    on: OnRaid
```

The loop drives the HUD's objective/progress element (§1.7) and the golden path (§1.11). It
adds no timer: `Executor.advance` (`core/domain/genre/Executor.luau:302-310`) is the only
clock. The objective renders as `<goal>  (<stage>/<stages>)`, e.g. `Buy a source  (1/5)`.

### 1.7 `ui` — HUD bindings

The five HUD elements map to five slots, each bound to spec ids:

```yaml
ui:
  resourceBar:  { resources: [coins], order: 1 }
  actionButtons: { from: actions, kinds: [button, prompt, player-button], order: 2 }
  inventoryGrid: { entityKind: creature, order: 3 }      # omit when the genre has none
  objective:    { from: loop, order: 4 }
  notifications: { kinds: [info, refuse, reward], order: 5 }
```

`ui.actionButtons.from: actions` is what makes the derived `GenreUI.luau` complete by
construction: every action with a `control` becomes a control, so sweep's
referenced-vs-exposed check (`cli/forge/commands/sweep.luau:632-640`) can only pass.

### 1.8 `world` — zones, nodes, spawn

The spec declares zones and placements; the builder (§2.2) turns them into Instances.

```yaml
world:
  name: World
  spawn: { zone: hub, offset: [0, 1, 0] }
  zones:
    - { id: hub,   kind: plaza,  center: [0, 0, 0],  size: [80, 1, 80] }
    - { id: red,   kind: base,   center: [-60, 0, 0], size: [40, 1, 40], team: Red }
    - { id: blue,  kind: base,   center: [60, 0, 0],  size: [40, 1, 40], team: Blue }
    - { id: arena, kind: arena,  center: [0, 0, 0],   radius: 28 }
  nodes:
    - { id: ember-incubator, zone: red, kind: incubator, position: [-60, 1, 4], control: collect-raid:buy-source }
    - { id: ember-node,      zone: hub, kind: node, position: [0, 1, 8], version: 1 }
```

This is deliberately the shape `WorldBuilder.Layout` already consumes — ground, bases, arena,
decorations, flowers (`genres/collect-raid/module/WorldBuilder.luau:55-62`), with the theme
split out (`:132-140`) — and the shape `SurvivalWorld.Config` already consumes for spawn,
reachability and wildlife spawns (`genres/survival-coop/module/SurvivalWorld.luau:17-34`).
A `node` with a `control` is exactly the prompt station the generic server already builds
(`core/infra/genre/Server.luau:138-157`), promoted from "one Part in a row" to a placement.

### 1.9 `audio` — cues bound to actions and events

Cue definitions reuse `audiocues.Cue` verbatim — `key`, `kind` ∈ {music, sfx, ambience},
`type` ∈ {click, coin, hatch, rare, raid, error}, `mood` ∈ {explore, siege}, `duration`,
`sampleRate`, `seed` (`cli/forge/lib/audiocues.luau:18-38`):

```yaml
audio:
  cues:
    - { key: collect-raid-buy, kind: sfx, type: coin, duration: 0.2, seed: 0 }
  bindings:
    - { on: "action:collect-raid:buy-source", cue: collect-raid-buy }
    - { on: "event:OnRaid", cue: collect-raid-raid, dedupe: 0.5 }
```

collect-raid's hand-wired handlers (`genres/collect-raid/module/runtime/Audio.luau:135-330`)
are the reference implementation of these bindings (state diffs, notify/prompt classifiers,
siege-phase music swap) and stay as declared overrides (§2.5) rather than being re-derived.

### 1.10 `economy` — parameters and simulation targets

```yaml
economy:
  startingBalance: { path: [balance] }          # config path, not a copy
  simulation: { sourceTotal: ">0", sinkTotal: ">0", rejectionRate: "<0.2" }
```

The parameters live in `PackConfig.configs[<genre>]` and `econ.yml` (rendered at
`cli/forge/lib/genreproject.luau:51-113`). The spec adds only the *assertion* the existing
simulator produces — `genrecontract.SimMetrics` (`cli/forge/lib/genrecontract.luau:33-39`),
driven by `Driver.simulate` (`cli/forge/lib/genrecontract.luau:40-43`).

### 1.11 `qa` — the golden path

The golden path is an ordered action sequence with expected state deltas, and it is the
single source of the derived native scenario (§4).

```yaml
qa:
  players: ["1"]
  starterState: { balance: 0, team: red }
  goldenPath:
    - { op: begin_clock }
    - { op: join, player: "1" }
    - { op: dispatch, player: "1", action: collect-raid:buy-source, args: ["ember"] }
      expect: { resultOk: true }
    - { op: expect_snapshot, player: "1", genre: collect-raid, field: coins, equals: 0 }
    - { op: advance_elapsed, seconds: 5 }
    - { op: dispatch, player: "1", action: collect-raid:hatch, args: [1] }
      expect: { resultOk: true }
    - { op: save, player: "1" }
    - { op: leave, player: "1" }
    - { op: restore, player: "1" }
      expect: { resultOk: true }
```
Every `op` is a member of `qascenario.OPERATIONS`
(`cli/forge/lib/qascenario.luau:29-68`); every expectation is already a comparator the
harness implements (`equals`, `not_equals`, `at_least`, `at_most`, `is_nil` —
`cli/forge/lib/qascenario.luau:97`, applied at `cli/forge/lib/qaharness.luau:162-186`). The
golden path is the machine-readable form of the `Driver.run` check list that every genre
already writes by hand (`genres/collect-raid/generator.luau:119-145`,
`genres/grow-harvest/generator.luau:9-41`, `genres/survival-coop/generator.luau:62-81`).

---

## 2. Core presentation layer contracts

Three modules, one package: `core/ui-kit/genre/`. They sit in `core/ui-kit`, which the pack
project already mounts (`cli/forge/lib/genreproject.luau:126-128`).

### 2.1 `HudKit.luau` — genre-agnostic HUD

```lua
HudKit.start({
  spec      : Spec,                      -- §1
  controls  : { Options.Control },       -- derived from spec.ui, validated by Options
  subscribe : (cb: (StateData) -> ()) -> (),
  dispatch  : (action: string, args: {any}) -> Result,
  locale    : string,
  assets    : { [string]: string },
}) -> ScreenGui
```

Three guarantees are structural, not conventions:

- **Safe area by construction.** The ScreenGui is created with
  `ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets` and one `SafeArea` frame carries every
  element, exactly as the survival HUD already does
  (`genres/survival-coop/module/SurvivalHUD.luau:93-98`). The kit has no code path that
  parents an element to the raw ScreenGui. This closes a real gap: collect-raid's HUD has
  **no** `ScreenInsets` at all and positions its phone bar by measuring the Roblox touch jump
  button (`genres/collect-raid/module/runtime/Hud.luau:327-330,302-311`).
- **Player-facing text only.** Every visible string comes from the spec's declared display
  data through `HudText` (§1.3): `HudText.resource(name, value)` renders `Coins  1.2K`,
  `HudText.objective(goal, i, n)` renders `Buy a source  (1/5)`, and an inventory cell shows
  the entity's declared name rather than the entity id it is keyed by. `HudText.assertVisible`
  refuses an identifier-shaped string at runtime, so a HUD cannot regress into showing
  `coin_label 9` even if a caller passes the key.
- **Stable instance identities.** One control registry keyed by `scope .. ":" .. id` creates
  each button once, then only mutates `Text`, `LayoutOrder`, `Active`, `Interactable` and
  `BackgroundTransparency`; hidden controls are `Visible = false`, never destroyed
  (`genres/survival-coop/module/SurvivalHUD.luau:7-55`). This is the fix for a reproduced
  defect: destroying the grid on every section change replaced every inventory button, so a
  click subscribed before the switch fired on a dead button while the injected click hit the
  new one (`genres/survival-coop/module/SurvivalHUD.luau:351-356`). QA and Studio click
  targets address instances by exact stable `Name`
  (`genres/collect-raid/module/runtime/Hud.luau:781-782,833-836`), so identity stability is
  a QA contract, not a nicety.

Element contracts: `resource-bar` (one label per spec resource), `action-bar` (one control
per `ui.actionButtons`, kind ∈ {button, prompt, player-button}, mirroring
`Options.Control.kind`), `inventory-grid` (portrait cells keyed by entity id; re-render gated
on a multiset key so an unchanged snapshot allocates nothing —
`genres/collect-raid/module/runtime/Hud.luau:604-640,761-763`), `objective` (spec loop stage
+ progress), `notifications` (transient toasts, never layout participants —
`genres/collect-raid/module/runtime/Hud.luau:1252-1262`).

Phone layout (viewport height < 500 → bottom action bar + modal sheets) is a HudKit
responsibility, generalized from `genres/collect-raid/module/runtime/Hud.luau:284-330`, and
it must keep the jump-button reservation
(`genres/collect-raid/module/runtime/Hud.luau:302-311,337-360`) so the bar never covers the
avatar.

**Reserved regions.** Roblox core UI owns two corners and a strip, and the kit places nothing
in them:

| region | owner | kit placement |
| --- | --- | --- |
| top-left | the chat window | nothing: the resource row is right-aligned at the top, the objective under it |
| bottom-right (phones) | the touch jump button | the action row sits left of its measured footprint |
| bottom-centre (desktop) | the backpack hotbar | the action row is lifted above it (`M.HOTBAR_RESERVE`) |

`M.CHAT_RESERVE` documents the desktop chat footprint the layout is built around; the Studio
driver measures the live chat frame instead of trusting it, records it as `chat` in the
capture geometry, and fails a capture whose owned UI overlaps it (`CRITICAL_UI_CHAT_OVERLAP`).
This closes a reproduced defect: the first wave put the resource pill and the action row on
top of the chat window on desktop and over the chat area on phones. Transient toasts render
under the reserved chat region (they used to enter 60px above their own region, i.e. off
screen), so a notice never covers the chat, the resource strip or the action row.

### 2.2 `WorldKit.luau` — parametric world from spec zones

```lua
WorldKit.plan(spec.world, theme?) -> { Part }        -- pure data, one authority
WorldKit.build(spec.world, theme, parent, types) -> Folder
WorldKit.node(spec.world, nodeId, parent?) -> Instance?
WorldKit.minimumParts(spec.world) -> number          -- the world gate's part floor
WorldKit.minimumZoneParts(spec.world, zoneId) -> number
WorldKit.coversSpawn(spec.world) -> boolean
```

`plan` is the one mapping: it turns zones, nodes and the spawn into the world's parts as pure
data (name, role, size, CFrame position/rotation, colour, material), and `build` instantiates
exactly that plan. The same plan is what the offline bake and the sweep's `world` column
measure, so the built place and the gate can never disagree about what a world is.

Geometry is set with `CFrame`, never with `Position`/`Rotation`: Lune's Roblox library keeps a
part's CFrame and silently drops a Position write, which is exactly how every baked world in
the first wave collapsed onto the origin (a floor plate at 0,0,0 and nothing else visible).

A world is *playable*, not merely present:

- **Ground under the spawn.** The zone floors cover their zones (slabs, or a flat cylinder
disc for a radius zone) and a floor part must contain the spawn's horizontal position with a
top surface at the spawn's own level.
- **Per-zone density.** Each zone carries its floor, its rim/boundary walls, four corner
pillars, a lit centre beacon, decorative rocks and trees scattered deterministically from a
hash of the zone id, and one distinct prop per node — a counter and sign for a `station`, a
dome and ring for an `incubator`, a roofed stall for a `depot`, a crate cluster for a plain
`node` — each carrying its `ProximityPrompt` when the node declares a control.
- **A spawn layout the camera can see.** A pad, a lit marker and four posts.
- **An environment.** `WorldKit.ENVIRONMENT` (lighting, atmosphere, skybox) is baked into the
place's project file by `genreproject` and applied at runtime by the generated world server
from the same table. Colour is the one place the two encodings differ: the runtime path goes
through `Color3.fromRGB` (0..255) while a project file's `Color3` takes 0..1 components, so
`WorldKit.rojoColor3` converts. Writing the 0..255 triple straight through clamps every
channel to 1 and renders the whole place flat white, which is why the sweep's `world` column
also checks that every baked `Lighting`/`Atmosphere` colour stays in 0..1.

The gates are the plan itself: `minimumParts`/`minimumZoneParts` (85% of the plan, so a
dropped decorative part is tolerated and an unbaked world is not) and `coversSpawn`. The bake
refuses a world below them, and the sweep's `world` column measures the built place against
them: part floor for the world and for every zone, ground under the spawn, a baked
`Atmosphere`/`Sky` environment, and every baked environment colour inside the project file's
0..1 range. The part budget is unchanged
(`Theme.budget.worldPartsMax`, `:139`) and is still a hard error when exceeded.

### 2.3 `AudioKit.luau` — cue bindings

```lua
AudioKit.start({ spec.audio, subscribe, remotes, locale, contentIds }) -> ()
```

Engine-free policy, injected playback: the survival audio module already separates policy
from playback so specs are deterministic (`genres/survival-coop/module/SurvivalAudio.luau:29-30,112`),
and only Roblox-shipped content ids are accepted (`:5-22`). collect-raid's dedupe window,
crossfade and local-only notifications (`genres/collect-raid/module/runtime/Audio.luau:74-77,243-256`)
become optional binding attributes (`dedupe`, `local`) rather than hard-wired handlers.

### 2.4 What the pack gets

`genrerender` emits, for a non-legacy pack:

| file | today | after |
| --- | --- | --- |
| `src/client/<Pascal>Client.client.luau` | `Client.start({controls=...})` (`cli/forge/lib/genrerender.luau:97-99`) | `HudKit.start({spec=...})` + `AudioKit.start(...)` |
| `src/shared/GenreSpec.luau` | — | serialized spec |
| `src/shared/GenreUI.luau` | serialized controls (`cli/forge/lib/genrerender.luau:56-58`) | derived from `spec.ui.actionButtons`, `label` = display text |
| `src/server/<Pascal>World.server.luau` | — | `WorldKit.start(WorldSpec, ...)`: uses the baked world, wires prompts |
| `src/shared/WorldSpec.luau` | — | serialized `spec.world` |
| `locale/strings.csv` | — | `genrespec.renderLocaleCsv(spec, locales)` |
| `default.project.json` | hand-written per pack | includes `Lighting` + `Atmosphere`/`Sky` from `WorldKit.ENVIRONMENT` |

A **legacy** pack (collect-raid) keeps its own gameplay server *and* gets the standard surface
through the same renderer: `src/server/<Pascal>Genre.server.luau` starts
`core.infra.genre.Server` with the genre's declared runtime contract, so
`ForgeAction`/`ForgeState`/`ForgePersistence` exist and, in Studio, so does the `ForgeQA`
folder the QA driver addresses. Without it a legacy pack cannot be admitted by the driver at
all (`ForgeState missing`). The pack's own server keeps running its world and loop.

`GenreUI.luau` stays, because `Options.validateControls` is the authority on control
legality (`core/infra/genre/Options.luau:39-86`) and sweep loads it as the pack's declared
control list (`cli/forge/commands/sweep.luau:401-416`). It becomes a *derived* artifact:
same bytes, one source.

### 2.5 Genre overrides — an explicit hook, not a loophole

```yaml
overrides:
  client: { module: genres/collect-raid/module/runtime/Hud }   # collect-raid
  world:  { module: genres/collect-raid/module/WorldBuilder }
  audio:  { module: genres/collect-raid/module/runtime/Audio }
  uiTargets: { buy-egg-button: collect-raid:buy-source }       # legacy Hud Names
```

An override is legal only when declared in the spec, and it must still satisfy the same
guarantees: safe area, stable names, part budget, cue bindings. Sweep's `clientKind`
(`cli/forge/commands/sweep.luau:420-431`) grows a fourth kind, `core HUD kit client`, which
counts as playable exactly like `genre runtime client` (`:661`).

**collect-raid** keeps all three overrides in wave 1 (its Hud, WorldBuilder and Audio are
richer than the kit) but declares them, and its generated client keeps binding the genre
runtime client (`genres/collect-raid/generation/planner.luau:3408,3421-3470`). **survival-coop**
keeps `SurvivalHUD`/`SurvivalWorld` as overrides; the generic client is used for the other
five genres immediately.

A client override may be scoped to one config mode with `mode:`:

```yaml
overrides:
  client: { module: genres/survival-coop/module/SurvivalHUD, mode: crafting }
```

The override then applies only to a pack whose config selects that mode, and every other mode renders
the kit's HUD. **survival-coop** uses this: `SurvivalHUD` is the crafting bootstrap's own interface
(bag, build, workshop) and implements no wave control, so the default wave mode binds the kit's HUD,
whose action bar carries the wave's `buy-defense` prompt control and its `defend-active` button. The
HUD gate measures the *effective* mode-specific owner, so it never validates a HUD the pack does not
bind.

---

## 3. How the generator consumes the spec

### 3.1 One path for `forge new` and `forge plan`

Both already funnel through `generate.assemble` (`cli/forge/commands/new.luau:82-93`,
`cli/forge/commands/plan.luau:211-221`), which resolves the registry
(`cli/forge/lib/genreregistry.luau:56-162`), calls each `generator.generate`
(`cli/forge/lib/genregenerate.luau:47-49`), validates the result
(`cli/forge/lib/genregenerate.luau:53-54`), and renders common artifacts
(`cli/forge/lib/genregenerate.luau:187`).

The spec enters at two points, both additive:

1. `genreregistry.discover` loads and validates the spec beside the runtime descriptor, so a
   malformed spec fails the whole catalog exactly as a malformed generator does
   (`cli/forge/lib/genreregistry.luau:135-146`).
2. `genrerender.render` reads the spec to render `GenreSpec.luau`, `WorldSpec.luau`, the
   derived `GenreUI.luau`, and the client/server binders
   (`cli/forge/lib/genrerender.luau:8-19,56-58,97-99`).

`Generated` (`cli/forge/lib/genrecontract.luau:25-31`) gains `spec: Spec`; `Generator`
(`cli/forge/lib/genrecontract.luau:44-56`) gains `spec: string` (the file name). Both
validated by `validateGenerated` (`cli/forge/lib/genrecontract.luau:365-488`).

### 3.2 Filling a spec from a concept, with no API keys

`forge plan` is already deterministic and keyless: the same concept + seed writes the same
bytes (`cli/forge/commands/plan.luau:1-12,44-47`). The agent-facing addition is one command
and one contract:

- `forge spec init --genre X --concept "<text>" --pack <slug>` writes a **draft**
  `genres/<id>/genre-spec.yml` seeded from the genre's `econ-template.yml` plan block and
  `design-template.md` (`cli/forge/lib/planner.luau`, `genres/collect-raid/generation/defaults.luau`)
  — the same templates `plan` reads today.
- A coding agent fills the draft: add `resources`/`entities`/`actions` rows, name the zones,
  bind cues, write the golden path. The agent edits **data and hook bodies only**; it never
  writes HUD, world or client code, because those are derived.
- `forge spec validate` (and `forge check`, `cli/forge/commands/check.luau:20-28`) reports
  `file: reason` per violation. Determinism is preserved: spec bytes in → pack bytes out, and
  `forge-lock.yml` pins genre versions (`cli/forge/lib/genregenerate.luau:201-206`).

### 3.3 Validation rules

New `cli/forge/lib/genrespec.luau`, `M.validate(spec, runtime, registry) -> { string }`,
invoked from `genreregistry.discover`. Rules, each reusing an existing validator:

| rule | authority |
| --- | --- |
| `api`/`id`/`version` present; `id` = package id; `runtime` = `RuntimeContract.id` | `Validation.id` (`core/domain/genre/Validation.luau:6-8`), `core/domain/genre/Contract.luau:78` |
| every `actions[].action` exists in `runtime.actions` with matching origin | `Executor.validate` (`core/domain/genre/Executor.luau:171-173`) |
| every `actions[].control` passes control legality (namespaced id, arity, arg schema, kind) | `Options.validateControls` (`core/infra/genre/Options.luau:39-86`) |
| `ui.actionButtons` covers exactly the controls that exist | derived-set equality; same rule sweep applies (`cli/forge/commands/sweep.luau:632-640`) |
| every `assetKey`/cue `key` is declared by procgen/audio and vice versa | `cli/forge/lib/genregenerate.luau:171-186` |
| entity `kind` ∈ the closed vocabulary (§1.4) | this document; table in `genrespec.luau` |
| `configPath` resolves in `PackConfig.configs[id]` | `Validation.dense` (`core/domain/genre/Validation.luau:9-26`) |
| zone bounds finite; node position inside its zone; spawn inside its zone | `Validation.finite` (`core/domain/genre/Validation.luau:3-5`) |
| golden path ops ∈ `qascenario.OPERATIONS`, expectations use known comparators, at least one assertion, and the path starts from `starterState` with consistent `effects` | `cli/forge/lib/qascenario.luau:29-68,72,97`; derived-scenario check (§4) |

A spec that fails any rule fails `discover`, so `forge new`, `forge plan`, `forge check`,
`forge sweep` and `forge build` all refuse to run against it.

---

## 4. Auto-derived QA

### 4.1 Derivation

New `cli/forge/lib/qagen.luau`, `M.derive(spec, runtime, controls, packConfig) -> qascenario.Scenario`.
It emits one `kind: native` scenario per pack per genre from `spec.qa.goldenPath`, using the
existing schema (`cli/forge/lib/qascenario.luau:99-127`) and the existing operation
vocabulary. `players`, `fixtures`, `data.durable` and `starterState` come from the spec; the
`expect_snapshot` fields come from the spec's `effects` and `starterState` deltas, so the
scenario asserts the **domain's** numbers, not the spec's prose.

Concretely, for collect-raid the derived scenario is the machine form of
`genres/collect-raid/generator.luau:119-145`; for survival-coop, of
`genres/survival-coop/generator.luau:62-81`.

### 4.2 Bound to the pack's real control ids

The scenario's `steps[].action` and `steps[].target` are the spec's namespaced control ids
(the regex at `core/infra/genre/Options.luau:56`), which are exactly the ids the derived
`GenreUI.luau` exposes and
the ids sweep compares (`cli/forge/commands/sweep.luau:632-640`). A genre that keeps a
client override declares its legacy Names in `overrides.uiTargets` (§2.5), which
`qagen` translates back to the spec action — so collect-raid's `buy-egg-button`
(`genres/collect-raid/module/runtime/Hud.luau:833-836`) and `raid-target` (`:781-782`)
resolve to `collect-raid:buy-source` and `collect-raid:raid` instead of reading as unmatched.

### 4.3 Namespaced resolution (the collision fix)

`game.yml` already stores namespaced scenario names —
`qa_scenarios = ["<genre>:<name>", ...]` (`cli/forge/lib/genregenerate.luau:74-76`,
`cli/forge/lib/genrerender.luau:33`) — and `qa plan` already parses
`^([^:]+):([^:]+)$` when `genre_contract` is present
(`cli/forge/commands/qa.luau:110-116`). Only `qa run` is bare-name
(`cli/forge/commands/qa.luau:313-328`). The fix:

1. `qa run --scenario <genre>:<name>` resolves directly to
   `registry.packages[genre].path .. "/qa-scenarios/" .. name .. ".yml"` via
   `qascenario.path` (`cli/forge/lib/qascenario.luau:929-931`). No scan, no order dependence.
2. A bare name is accepted only as a legacy alias when **exactly one** registered genre
   ships it; otherwise it is a usage error naming the namespaced forms. (This preserves the
   existing contract-loop/contract-rejoin entry points without preserving the ambiguity.)
3. Pack-local derived scenarios are searched first:
   `<packsDir>/<pack>/qa-scenarios/<genre>.<name>.yml`. `:` is not a legal filename
   character on Windows, so the on-disk separator is `.` and the `genre:`/`name:` fields
   inside the file carry the identity — the file already validates that `name` matches its
   filename (`cli/forge/commands/qa.luau:66-68`), and `qascenario.validate` must accept the
   dotted filename.

### 4.4 Where derived scenarios live, and who runs them

`generate.write` writes them into the pack at
`games/<slug>/qa-scenarios/<genre>.<name>.yml` as part of the assembly
(`cli/forge/lib/genrepublish.luau:309-397`), so a freshly generated scratch pack under
`build/sweep/<stamp>/packs/<slug>` (`cli/forge/commands/sweep.luau:742-748`) carries its own
QA. Sweep then runs the pack's own scenarios rather than the genre directory's
(`cli/forge/commands/sweep.luau:555-612`), which is what makes the nativeQa column meaningful
per variant.

**One binding rule for both entry points.** `qa run` enforces `raw.pack == pack`
(`cli/forge/commands/qa.luau:366-371`) while sweep calls `qaharness.runNative` directly and
never checks it (`cli/forge/commands/sweep.luau:587`). Derived scenarios always declare the
generated pack's slug, and sweep must apply the same pack check, so the two paths can never
disagree about whether a scenario applies.

### 4.5 Studio stays smoke + screenshots

`kind: studio` scenarios keep the operations that need a rendered client — `capture`,
`walk_to`, `activate_prompt`, `click`, `touch`, `keyboard`, `wait_for`, `device`
(`cli/forge/lib/qascenario.luau:75-95`) — for first-play, occlusion, UI and screenshot
evidence. No game rule is ever asserted only in Studio; every rule assertion is native.

---

## 5. Migration plan

### 5.1 Sweep columns

`M.STEP_NAMES` (`cli/forge/commands/sweep.luau:42`) becomes:
```
generate, files, build, inspect, spec, hud, world, audio, nativeQa, surface
```

| column | probe | passes when |
| --- | --- | --- |
| `spec` | `genrespec.validate` on the variant's genres | every spec valid, and the generated pack contains `src/shared/GenreSpec.luau` |
| `hud` | pack's client entry + control list | client is `core HUD kit client` or a declared override client; ScreenGui carries `CoreUISafeInsets`; every `ui.actionButtons` control exists with a stable `Name`; **`HudText.violations` finds no visible string that is a raw spec id**; and **`HudContrast.violations` finds every text/chip pair at or above the WCAG AA floor, with every label stroked and the objective chipped** (`cli/forge/commands/sweep.luau`) |
| `world` | built place vs `WorldKit.plan` | part floor for the world and for every zone, a floor part covering the spawn, a baked `Atmosphere`/`Sky` environment, and every baked environment colour inside the project file's 0..1 range (a 0..255 triple renders clamped to white); a world override is measured by its own module instead (`cli/forge/commands/sweep.luau`) |
| `audio` | spec bindings vs cue keys | every bound action/event resolves to a declared cue key |
| `surface` | unchanged data, stricter gate | `hud` and `world` and `audio` all pass, and `unmatchedTargets` is empty (`cli/forge/commands/sweep.luau:632-640`) |

Each increment below flips named cells to PASS and nothing else.

### 5.2 Increments

**I1 — Spec schema, loader, validator, `forge spec init/validate`.**
Adds `cli/forge/lib/genrespec.luau`, the manifest `spec` field, six draft specs (one per
genre) and the six `spec` cells.
Gate: `spec` PASS for all 7 variants; `sweep` still 0/7 overall. `forge check` clean.

**I2 — HudKit + generic client + derived `GenreUI`/`GenreSpec`.**
Replaces `Client.start` in `genrerender` (`cli/forge/lib/genrerender.luau:97-99`) for the five
non-legacy genres; collect-raid keeps its declared client override.
Gate: `hud` PASS for grow-harvest, pvp-arena, rpg-progression, social-rp-fashion, survival-coop,
survival-coop (crafting); `surface` PASS for all 7.

**I3 — WorldKit + `WorldSpec` + world server binder.**
Gate: `world` PASS for all 7 — every baked place carries the plan's part floor for the world
and for each zone, ground under the spawn, and the baked `Atmosphere`/`Sky` environment;
collect-raid's declared world override is measured by its own builder instead.

**I4 — AudioKit + cue bindings.**
Gate: `audio` PASS for all 7.

**I5 — `qagen` derived native scenarios + namespaced `qa run` resolution.**
Gate: `nativeQa` PASS for collect-raid, grow-harvest, pvp-arena, rpg-progression,
social-rp-fashion; `qa run --scenario collect-raid:core-loop` and the same bare name resolve
identically, and `grow-harvest:contract-loop` no longer depends on directory order.

**I6 — Per-genre overrides + survival native rebinding.**
Rebind survival-coop's nine native scenarios to the generated pack (or replace them with
derived ones plus the two mechanism-specific natives that need `fixture-survival`:
`transfer-crash-matrix`, `settlement-conflict`), and declare the collect-raid/survival
overrides.
Gate: `nativeQa` PASS for survival-coop and survival-coop (crafting); **7/7 variants fully
passed**.

### 5.3 Per-genre notes

| genre | client in wave 1 | world | notes |
| --- | --- | --- | --- |
| collect-raid | genre runtime client (override) | WorldBuilder (override) | controls come from the legacy Hud, not `GenreUI` — `controls = {}` at `genres/collect-raid/generator.luau:114` while `qa.targets` names three ids at `:196`; the spec must declare the legacy Names |
| grow-harvest | HudKit | WorldKit | 4 controls already exist (`genres/grow-harvest/generator.luau:101-130`) |
| pvp-arena | HudKit | WorldKit | controls are un-namespaced ids, namespaced by the assembly (`cli/forge/lib/genregenerate.luau:64-70`) |
| rpg-progression | HudKit | WorldKit | three controls, all namespaced (`genres/rpg-progression/generator.luau:105-127`) |
| social-rp-fashion | HudKit | WorldKit | one `player-button` control exercises the roster path (`core/infra/genre/Client.luau:80-86`) |
| survival-coop | SurvivalHUD (override) | SurvivalWorld (override) | nine natives bound to `primal-isles`/`fixture-survival`; mode selection stays in `genres/survival-coop/module/Mode.luau:29-62` |

---

## 6. Non-goals and risks

### 6.1 Non-goals

- **No rules in the spec.** The spec names domain actions, refusal reasons and state fields;
  it never computes an outcome. `Executor` remains the only validator
  (`core/domain/genre/Executor.luau:164-209`).
- **No core runtime change.** `Contract`, `Executor`, `Session`, `Server`, `Options` keep
  their closed types (`core/domain/genre/Contract.luau:77-94`,
  `core/infra/genre/Options.luau:87-105`). Presentation is a separate layer precisely because
  `Contract.Instance` has no presentation surface (`core/domain/genre/Contract.luau:65-76`).
- **No new currency or monetization system.** `resources` binds existing snapshot fields;
  `monetization` stays in `game.yml` (`cli/forge/lib/genrerender.luau:29`). Robux sells only
  deterministic items, random hatching stays on free currency, and there is no 1:1
  personal-base theft structure or "Steal a ..." title pattern (AGENTS.md).
- **No LLM or API keys in planning.** `forge spec init` seeds a draft; an agent fills it by
  editing data.
- **No Studio-only logic verification, and no hand-built per-pack world.** Studio covers
  smoke and screenshots only; every pack's world comes from `spec.world`.

### 6.2 Risks

| risk | mitigation |
| --- | --- |
| Spec drifts from the runtime descriptor | `genrespec.validate` checks against `runtime.actions` and fails `discover`; a stale spec cannot be generated against |
| Derived scenarios ossify a bug | Scenarios assert domain-produced snapshots only; the spec cannot express a rule (`cli/forge/lib/qascenario.luau:2-11`); `Driver.run` stays as the independent check |
| HudKit regresses collect-raid's phone HUD | collect-raid keeps a declared client override in wave 1; the kit must reproduce the jump-button reservation (`genres/collect-raid/module/runtime/Hud.luau:302-311,337-360`), compared by screenshot |
| Part budget blowout | `Theme.budget.worldPartsMax` (`genres/collect-raid/module/WorldBuilder.luau:1008-1017`) becomes a `world` column gate |
| `:` in scenario filenames is illegal on Windows | dotted on-disk names, namespaced identity inside the file (§4.3) |
| Two client shapes drift apart | `clientKind` gains `core HUD kit client` and `surface` requires a playable kind (`cli/forge/commands/sweep.luau:420-431,661`) |
| `Options.services` is survival-shaped and closed (`core/infra/genre/Options.luau:156-200`) | presentation takes no service port; it subscribes to `ForgeState` and calls `ForgeAction`, which already exist (`core/infra/genre/Server.luau:63-67,92-99`) |

---

## 7. World feedback, the derived world path, and collect-raid generalization

### 7.1 `world.nodes[].feedback` — what a node shows

The spec already says which node carries which control (§1.8). A node may also declare
`feedback`: the snapshot field it reflects and the copy it pops up, so the world's
reaction to the loop is derived from the same document as the HUD. It is presentation
only — the runtime reads a field the adapter already publishes, plays a cue the spec
already declares, and computes no outcome.

```yaml
nodes:
  - id: plot-a
    zone: farm
    kind: node
    position: [8, 1, 0]
    feedback:
      - kind: growth          # growth | health | lamp | outfit | counter
        field: plots.1        # a dotted snapshot path
        entity: carrot
        label: Crop           # the floating-text copy (declared, never derived)
        labelKey: fb_crop
        cue: grow-harvest-plant
```

| kind | field shape | the world shows |
| --- | --- | --- |
| `growth` | a plot entry (`{cropId, ready}`) | a crop that grows through empty / sprout / ripe, by size and colour |
| `health` | a number | a BillboardGui bar over the enemy, and a defeat state at zero |
| `lamp` | any value | a PointLight and neon prop while the field equals `active` |
| `outfit` | an equipped map | a real accessory worn on the character while it holds `entity` |
| `counter` | a number | only its floating-text delta (`Coins +10`) |

Every binding is validated by `core/ui-kit/genre/WorldFeedback.violations`, which
`genrespec.validate` runs, so a malformed binding fails `genreregistry.discover` rather
than rendering nothing. `M.state`/`M.deltas` are pure, so the specs and the gate measure
exactly the numbers `WorldFeedback.start` applies at runtime.

### 7.2 The derived world path

`qagen.deriveWorldPath` publishes a second scenario per pack,
`qa-scenarios/<genre>.world-path.yml`, from the same spec: it walks the acting player to
the first node whose control is bound to a golden-path action (`walk_to`), triggers that
node's `ProximityPrompt` with real engine input (`activate_prompt`, key E), reads the
committed result back through `expect_result`, and captures the world's reaction. A genre
whose world is a declared override publishes none — its own builder placed its prompts,
so the shared kit cannot promise the path resolves.

A prompt is dispatched by the **server** (`WorldKit.start` → `session.dispatch`), which is
also why `HudKit` no longer dispatches on `PromptTriggered`: one trigger must run one
action, not two. The world server publishes the committed result whether it succeeded or
not, so a refusal is visible to the client and to the QA driver.

### 7.3 collect-raid generalization — what the spec expresses today

`forge new`/`forge plan` render every genre through one path, and collect-raid is the one
genre that keeps declared client, world and audio overrides. This section states how far
collect-raid can be expressed through the spec and the kits without losing the HUD and
world it ships, and what stays an override.

**Implemented (low risk, no gameplay change).**

| capability | how |
| --- | --- |
| display text | `resources[].name`, `entities[].name`, `actions[].control.label` and `loop[].goal` are declared and gated by `HudText.violations`; a raw id in visible text fails the sweep |
| locale | `genrespec.renderLocaleCsv` and `serializeLocaleStrings` write the pack's `locale/strings.csv` and `src/shared/LocaleStrings.luau` from the spec, legacy packs included |
| QA derivation | `qagen.derive` publishes `qa-scenarios/collect-raid.golden-path.yml` for a legacy pack exactly as for a generic one |
| ForgeQA surface | `genrerender.surfaceFiles` starts `core.infra.genre.Server` from the spec's control list and runtime contract, which is what admits a legacy pack to the Studio driver at all |
| control identity | `overrides.uiTargets` maps `buy-egg-button`, `Hatch_1` and `raid-target` to the actions they drive, so the sweep's referenced-vs-exposed check resolves them instead of reading them as unmatched |

**Remaining overrides, and why.**

| override | why the kit cannot take it over in this wave |
| --- | --- |
| `client` (`module/runtime/Hud.luau`) | The legacy HUD is a gameplay surface the kit does not have: phone sheets that re-parent live buttons, a touch-jump-button measurement, a store panel driven by `Catalog`, an odds list, quest rows and incubator timers. `HudKit` renders a resource bar, an action bar, an inventory grid, an objective and notices. Moving collect-raid onto the kit would delete those surfaces, not generalize them. |
| `world` (`module/WorldBuilder.luau`) | The builder is a gameplay authority, not only geometry: it places incubators, siege walls and per-team bases with attributes the pack's server reads back, and it is the reference `WorldKit` was generalized from. `WorldKit.plan` covers zones, nodes, decor and spawn — not team siege structures. |
| `audio` (`module/runtime/Audio.luau`) | The runtime module swaps music on the siege phase, which is a genre rule, not a binding. `AudioKit` now implements the same declarative bindings (action, event+field, dedupe, local) and gained `controlActions` so a namespaced prompt control resolves to its action's cue. |
| controls are HUD Names, not `GenreUI` | `controls = {}` in the generator; the real controls are HUD instance Names. `overrides.uiTargets` makes them legible; making them real `GenreUI` rows requires the kit to own the HUD (first row). |

**What would move the needle.** Each is additive and changes no existing contract:

1. Declared HUD slots beyond the five (`store`, `odds`, `quests`, `incubators`) so the kit
   can render what collect-raid's sheets render.
2. A `world.structures` section for team-owned siege geometry, consumed by `WorldKit.plan`.
3. `audio.bindings[].phase` — a music swap keyed to a declared event — so the siege music
   becomes a binding rather than a handler.

---

## Appendix A — places where existing code contradicts this plan

1. **collect-raid declares no controls but declares QA targets.** `controls = {}` at
   `genres/collect-raid/generator.luau:114`, `qa.targets = { "collect-raid:buy-source", ... }`
   at `:196`, while the real controls are Hud instance Names (`buy-egg-button`,
   `raid-target`) at `genres/collect-raid/module/runtime/Hud.luau:781-782,833-836`. Its sweep
   `surface.controls.manifest` is therefore `"genre runtime (not enumerated)"`
   (`cli/forge/commands/sweep.luau:677`). The spec's `overrides.uiTargets` is required to
   make this legible; without it, "bound to the pack's real control ids" is unimplementable
   for collect-raid.
2. **`qa run` and `sweep` disagree on pack binding.** `qa run` fails a mismatched pack
   (`cli/forge/commands/qa.luau:366-371`); sweep runs the same scenario against the generated
   pack without checking (`cli/forge/commands/sweep.luau:587`). §4.4 makes the check
   symmetric.
3. **Sweep collects HUD/world data but gates on HUD shape alone.** `beyondDebugPanel`
   (`cli/forge/commands/sweep.luau:661`) is the whole `surface` verdict, so `placeParts = 0`
   and non-empty `unmatchedTargets` still read PASS. §5.1 fixes the gate.
4. **collect-raid's HUD has no safe-area guarantee.** `SurvivalHUD` sets
   `ScreenInsets = CoreUISafeInsets` (`genres/survival-coop/module/SurvivalHUD.luau:95`);
   `Hud.luau` has no `ScreenInsets`/`SafeArea` at all and hand-positions around the touch
   jump button (`genres/collect-raid/module/runtime/Hud.luau:302-311,327-360`).
5. **`Generator.qa` is a name list, not a path.** `{ scenarios, operations, targets }`
   (`cli/forge/lib/genrecontract.luau:54`) cannot express a golden path, so scenario
   derivation must read the spec (§3.1) rather than this field.
6. **Only collect-raid has a `legacy` generator.** `cli/forge/lib/genregenerate.luau:46,49`
   selects `generator.legacy.generate`, and the legacy branch rewrites `require` paths and
   skips `Options.validate`/`runtime.render` (`cli/forge/lib/genregenerate.luau:111-154`).
   Any "one path for `forge new` and `forge plan`" claim must keep this branch working or
   migrate collect-raid off it first.
7. **Survival-coop's natives are pack-bound to fixtures.** All nine `kind: native` files in
   `genres/survival-coop/qa-scenarios/` declare `pack: primal-isles` or `pack: fixture-survival`,
   so they can never validate a freshly generated pack as-is (`build/sweep/final/sweep.md`).

## Appendix B — files read

Core: `core/infra/genre/{Client,Server,Options,CommandTransport}.luau`,
`core/domain/genre/{Contract,Executor,Validation}.luau`.
CLI: `cli/forge/lib/{genrerender,genregenerate,genreregistry,genreproject,genrecontract,genrepublish,procgen,audiocues,qascenario,qaharness}.luau`,
`cli/forge/commands/{new,plan,qa,sweep,check}.luau`. Genres: `genres/<id>/{generator.luau,module/Contract.luau,qa-scenarios/}`,
`genres/collect-raid/{generation/planner.luau,module/runtime/{Hud,Audio}.luau,module/WorldBuilder.luau}`,
`genres/survival-coop/module/{Mode,Capabilities,SurvivalHUD,SurvivalWorld,SurvivalAudio}.luau`.
Evidence: `build/sweep/final/sweep.md`.

## Appendix C — the load and quality columns

Two columns turn the sweep from a build gate into an evidence gate for a
*generated* pack. Both run in the same headless pass as every other step.

**`load`** (`cli/forge/lib/loadproof.luau`) drives the real
`core/infra/genre/Session` over a real `ProfileStore` — the real `Executor` and
the real genre adapters — with eight actors on the pack's own derived golden
path, no Studio and no clock sleep. Each actor joins, runs the loop
concurrently at one logical instant, saves, leaves and rejoins, and the run is
compared against a single-actor reference over the same roster. The invariants
are `join`, `no-errors`, `rate-limits` (the primary's accepted/refused vector is
unchanged under load), `no-duplicate-grants` (concurrency accepts no more than
the reference, and a replayed durable command changes nothing), `conservation`
(every numeric leaf is a finite non-negative safe number and every saved
envelope passes the genre's own `validateSave`) and `persistence` (every leaf
the reference preserved across save/leave/rejoin is preserved for every actor).
It deliberately does not assert that peers leave each other untouched: an arena
duel moves two ratings and a cooperative wave is shared, so that would fail
adversarial genres for a reason that is not a defect.

A **live Studio 8-client run is not attempted**. The triggerless launcher
(`cli/forge/qa/studio-qa-launch.mjs`) registers one scheduled demand task per
run, so it launches a single owned client and has no eight-client mode; the
maintained capacity route (`cli/release/capacity*.mjs`) needs
`FORGE_CAPACITY_DRIVER` plus a 300-second live engine window, i.e. a Studio
allocation. Launching Studio requires explicit user approval and would put
windows on the foreground, both of which the project's hard rules forbid in an
autonomous run, and the user's own Studio (pid 18060) and the staging place must
not be touched. The headless proof is therefore the gate; the live route stays
available for a human-supervised run.

**`quality`** (`cli/forge/lib/qualityscaffold.luau`,
`cli/forge/lib/qualityevidence.luau`, `cli/forge/commands/quality.luau`)
generation now emits a `quality.yml` for every pack, declaring the `starter`
tier only: an explicit "not a release claim" with the loop text taken from the
genre spec the pack ships. The sweep records an evidence receipt per variant
under `<sweep-out>/quality/<slug>.json` from its own columns plus the load proof
and native-QA results, and the column passes only when that receipt validates
against the declared tier. `forge quality evaluate --pack <slug> --sweep <dir>
[--captures <visual-run-dir>] [--av <av-source.json>]` records the same receipt
with a Studio capture manifest and its visual-content gate verdicts and an AV
source receipt attached when those exist, and `forge quality check --pack <slug>
--evidence <path>` validates one. A receipt never mints human approval: fun and
visual quality stay `human-judgment-pending` and `releaseApproved` is always
`false`; a document that claims otherwise is refused.
