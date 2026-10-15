# genres/

Reusable packages sit between core services and game packs: collect-raid,
grow-harvest, survival-coop, rpg-progression, social-rp-fashion and pvp-arena.
Packs pin versions in forge-lock.yml and use config/trusted server hooks instead
of copying or modifying package code.

## New-genre extension steps

1. Create `genres/<id>/` (lowercase letter followed by lowercase letters, digits
   or hyphens, at most 64 characters). Add `forge-package.yml`:

   ```yaml
   name: your-genre
   version: 0.1.0
   requires:
     core: ^1.0.0
   genre_contract:
     api: 1
     generator: generator.luau
     runtime: module/Contract.luau
     spec: genre-spec.yml
   ```

   Name equals directory ID. Choose a range compatible with the actual core
   manifest. Versions are integer major.minor.patch; only caret ranges are
   supported (next major for major >0, next minor for 0.minor >0, next patch for
   0.0.patch). This validates compatibility, not dependency resolution. Entry
   filenames are fixed package-relative paths; alternative/traversal paths fail.
   Adding API 1 does not itself change existing package versions/pins. The
   `spec:` field is required and must be exactly `genre-spec.yml`; discovery
   refuses a package whose spec file is missing or invalid.
   Author the declarative spec with `lune run cli/forge spec init --genre <id>
   [--concept "<text>"] [--pack <slug>] [--force]`, which writes a draft
   `genres/<id>/genre-spec.yml` (`draft: true`) seeded from the genre's
   `econ-template.yml` and `design-template.md`. Fill in resources, entities,
   actions, loop, world, audio and the golden path, drop `draft: true`, then run
   `lune run cli/forge spec validate [--genre <id>]`, which reports every violation
   as `file: reason`. The format is specified in
   [docs/forge/genre-spec.md](../docs/forge/genre-spec.md).
2. Implement an engine-free adapter under module/ and export its descriptor from
   `module/Contract.luau`, typed with `core/domain/genre/Contract.luau`. Declare
   actions/events/hooks, concrete config/save validators and an instance factory.
   Use literal relative requires for smoke bundling.
3. Implement generator.luau with the Generator type in
   `cli/forge/lib/genrecontract.luau`: defaults/artifacts/controls/assets,
   deterministic driver.run/driver.simulate and QA capabilities. Exercise the
   real Executor/native adapter, not a duplicate simulator.
4. Add and declare `qa-scenarios/contract-loop.yml` and `contract-rejoin.yml`, plus
   every extra generator.qa.scenarios file. Use contract_api: 1, declared
   operations/targets, and name/genre matching filename/directory. Legacy
   econ/design templates alone do not implement API 1.
5. Add fixed-clock/RNG adapter/generator specs for native mutation, invalid-input
   immutability, once-only rewards/rejoin and output determinism. Run
   `lune run cli/forge qa validate`; exercise actual new/plan/codegen/smoke/sim in
   disposable packs, typecheck/build, and obtain permission for Studio proof.
   Consult [CLI integration limits](../cli/forge/README.md#genre-contract-support-and-current-limits)
   before claiming command acceptance.

The complete small example is `cli/forge/fixtures/genres/fixture-counter/`;
production defaults scan genres, not fixtures. genreregistry.discover(root?,
coreVersion?) sorts immediate manifest-bearing directories and ignores unrelated
directories. Any incomplete/malformed package fails even when unselected. It
loads trusted code, checks descriptors agree, and requires declared scenario
files. Discovery neither validates scenario bodies nor executes gameplay. No
central registration or generic CLI/core branch on a new genre ID is required.

## Runtime contract

RuntimeContract fields: api/id/configVersion/saveVersion, actions/events/hooks,
validateConfig/validateSave/create, optional recipe. API/config/save versions
currently supported are all 1. Validators return error lists (empty means valid).
Concrete config/save schemas are package-owned. Data contains finite numbers,
strings/booleans, dense arrays or string-key maps, no functions/Instances/cycles.
Executor bounds strings to 256, containers to 1024 entries and nesting to 16;
adapters enforce semantic bounds/references.

create(config, services) receives Services={now,roll,emit}: authoritative absolute
seconds, injected roll in [0,1), declared event emission. Return an Instance with
join(playerId,savedData?), leave(playerId), dispatch(playerId,localActionId,args),
advance(epoch), snapshot(playerId), save(playerId). Join/dispatch return
{ok,reason?}. Reject illegal transitions before mutation; adapters own inventory,
wave membership, cooldowns, outcomes and reward ledgers.

An optional instance.prepareLeave(playerId) settles departure effects while the
player's committed state is still serializable. Session invokes it before the
final save envelope, then leave immediately detaches the participant before
backend release. It must be idempotent; adapters with such effects also invoke
it from leave for direct Executor callers. Arena uses it to persist disconnect
forfeit ratings for both players.

Actions declare local kebab id, exact args tuple of existing Schema validators,
client/server origin, and rate={capacity,refillPerSecond}. Capacity 1..100,
refill >0..100; typical clients use 5/2. Transport IDs are <genre>:<action>.
Executor rejects unknown/wrong-origin actions, nonmembers, nonfinite/sparse/extra
tuple values, wrong arity/schema and rate overflow. Clients must not choose
hooks/config, identity, damage/rewards, wave index or time. Roblox identity comes
from callback Player; server actions are not a client-selectable origin flag.

Use Executor.new(packConfig,orderedContracts,services,hooks?), then join/leave,
dispatchClient/dispatchServer, advance/snapshot/save. Advance is nondecreasing
and canonical-order; tests advance injected now alongside Executor time. Events
are {genre,name,playerId?,data}; trusted HookMap keys are <genre>:<hook> and every
hook is also a declared event. Cloned events flush FIFO after mutation. Hook
failures surface after commit, not rollback; this is not analytics registration.

API 1 econ.yml source:

```yaml
genre_contract:
  api: 1
  order: [your-genre]
  configs:
    your-genre: {target: 2} # Replace with your adapter's concrete schema.
```

game.yml has the same ordered genres, genre_contract: 1, and qualified QA names
(your-genre:contract-loop). Codegen renders GenreConfig; Config requires it.
Collect compatibility keeps legacy source/EconConfig. Invalid/future markers fail.
One per-player save envelope is {version=1,genres={[id]={version=1,data=save}}}.
Missing slices use defaults; unknown/future/invalid slices reject. Saves/snapshots
and loaded slices are cloned. Generic Session uses one ProfileStore, exposes
failed commits for retry and awards nothing inside persistence callbacks. Keep
server waves/matches/votes ephemeral; persist player-owned rewards/upgrades/items.
Existing collect profiles are not implicitly converted.

Fashion results preflight the full winner reward against the1e9 saved-balance
limit. A reward that cannot fit settles once with an explicit
settlement={ok=false,reason="reward exceeds balance limit"} in OnResults and
the results snapshot, without partial credit or an unsavable wallet. Ranking
remains available; the ephemeral outcome is cleared on the next lobby/round.

## Generator, artifacts and controls

GenerateInput: mode (new/plan), slug/pascal/title/concept/seed/teams/debugName/guiName.
Generator: api/id/configVersion/runtime/generate/driver/qa, optional recipe-owned
recipes={[recipeId]={normalize,driver}} and optional compatibility
legacy={generate,codegen}. New packages normally do not need legacy.
generate(input) returns {config,artifacts,controls,assetKeys,generation}:

- Artifacts are {path,content} under design/<id>/, src/shared/<id>/ or assets/<id>/.
  No absolute/backslash/colon/traversal/duplicate paths or common-file overwrite.
- Controls are {id,action,args,label,kind}. Validation accepts a local kebab ID
  or <genre>:<local-id> with the generator's exact namespace. Assembly qualifies
  local IDs. Actions must be declared client actions with a valid fixed tuple. Kinds are
  button/prompt/player-button; player-button prepends selected roster PlayerId.
  Keep IDs distinct across recipe partners. QA targets are separately declared
  strings and may be namespaced; controls are not arbitrary action editors.
- Asset keys begin <id>-. Generation is an ordered subset of procedural,
  launchart, audio. Prop-only starters supply namespaced procgen/audio YAML and
  declare procedural/audio; never fabricate creatures to pass launchart's gate.
- driver.run(executor,input) returns nonempty {name,ok,detail?} checks.
  driver.simulate(executor,input,players,days) returns balances/sourceTotal/
  sinkTotal/acceptedActions/rejectedActions. Drivers own meaningful schedules;
  simulation rejects zero accepted actions and invalid metrics. Collect balance
  targets are not universal.

Common assembly owns metadata/locks/project, deploy seed/liveops, GenreConfig,
GenreUI/GenreRuntime, server GenreHooks, thin server/client scripts, locale,
design index, smoke and merged asset inputs. It validates before writes and runs
declared keyless capabilities. Existing deploy bytes, matching monetization IDs,
asset publication fields/custom entries survive regeneration. Publication stages
tool output before replacing destination files with same-volume overwrite renames.
A journal supports restart rollback while retaining the destination directory.
This is per-file replacement, not a whole-pack atomic transaction; interrupted
packs require recovery before build/sync/play. See the
[authoring and recovery contract](../docs/release/authoring.md).

Procedural preflight resolves native meshes with the assembled game poly budget.
A declared launchart capability also requires a resolved creature entry; prop-only
inputs reject before any destination writes rather than failing after publication.

## Explicit recipes: one wallet owner

Singles need no recipe. Multiple selections require exactly one exact-partner
recipe; ordered partners define canonical execution order. Optional
recipe.validateConfig(configs) checks cross-package invariants;
recipe.create(configs,services) returns exactly those instances. This is trusted
typed code, not executable YAML or a generic cross-hook graph.

Production garden-defense-v1 is declared by survival-coop, ordered grow then
survival. Grow owns the only Coins wallet; survival uses grow's walletPort
(balance/debit/credit). Both configs use Coins; survival startingBalance must be
zero. Only grow saves balance; composed survival saves upgradeLevel, not balance.
Standalone survival owns its own wallet. Harvest yields held inventory, sale
funds buy-defense, and one active-wave win credits the same wallet once. Default
mechanics: sale +10, upgrade -10, defense 1 ->4 against 3 enemies, win +5. To prove
farming is necessary, the recipe generator normalizes both starting balances to
zero. Common assembly invokes that recipe-owned normalizer and validates the
result before writing; smoke/simulation use its coupled driver.

## Representative loops, not production assets

Adapters coordinate native collection/siege, farming, wave defense, boss/quest
progression, paired PVP and outfit voting modules. Generic starters use floor,
spawn, prompt stations, buttons and snapshot UI. Prop specs/short cues are starter
inputs, not proof they render/play or are production-ready. Fashion defaults are
data clothing tokens, not uploaded wearables. Generic packs default to empty
monetization: legacy purchase-scenario validation is not purchase execution.
Collect retains richer binders/client rendering. Headless proof cannot establish
visuals, rights/moderation, UX, performance or commercial completeness; retain
the permission-gated Studio lane.

API sources: core/domain/genre/{Contract,Executor,Validation}.luau,
core/infra/genre/{Server,Session,Clock}.luau,
cli/forge/lib/{genrecontract,genreregistry,genregenerate,genresim}.luau and actual
package generators/runtime contracts.
