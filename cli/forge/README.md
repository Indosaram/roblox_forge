# cli/forge/

The Lune-based `forge` CLI for building, checking, and operating games in the repository.

## Genre-contract support and current limits

Current source routes new/plan, version-marked codegen/econ sim, and QA discovery
through filesystem-discovered API 1 packages. See the [extension guide](../../genres/README.md)
for actual APIs. Command run(args,context?) supports internal packsDir/genresDir/
reportsDir roots for sandbox proofs; these are not CLI flags. Args include the
command token. No central branch on a new genre ID is needed.

Integration remains in progress; routing is not verified all-genre playability.
Control validation accepts local IDs or the generator's exact namespace, and
assembly qualifies local IDs for the runtime boundary. Selected recipes supply
their own generation normalizer and coupled driver. Generated composition and
build acceptance still require the captured proofs. `check` discovers the same registry, validates QA
schemas and compares GenreConfig or legacy EconConfig according to the source
format. These checks do not replace generated runtime and scenario execution.

### Contract command semantics (supersede legacy descriptions below)

- `new <slug> --genre <g1,g2>` resolves descriptors and assembles validated defaults.
  Singles are supported by selection; multiple genres need exactly one exact-set
  recipe (production grow-harvest + survival-coop, canonical grow then survival).
  Arbitrary mixtures, duplicate/unknown IDs and existing destinations reject.
  Generic output includes API 1 econ/GenreConfig, qualified QA names, runtime/UI/
  hooks, real starter binders, smoke/assets and locks. Collect's legacy capability
  retains its original format/binders. New econ.yml is hand-owned, unmarked.
- `plan --concept ... --genre <comma-list> --pack <slug>` uses the same selection
  rules and package generators. Flags include seed (default 0), title, teams,
  debug-name, gui-name, force. It emits a plan GENERATED econ marker; regeneration
  requires that marker or force. Only collect uses the legacy roster/template
  tuner and egg balance targets. Generic loops are representative, not complete
  commercial games. Assembly validates inputs before writing, runs only declared
  keyless procedural/launchart/audio steps, assets codegen and stylua; no provider,
  install or publish. Deploy bytes, matching paid IDs and asset publication fields/
  custom entries survive. Post-write tool/I/O failure may leave partial output.
- `codegen [pack]`: API 1 econ marker resolves/validates descriptors and writes
  GenreConfig.luau; no marker preserves legacy EconConfig. Invalid/future markers
  fail, never fall back. Never hand-edit generated projections.
- `econ sim` retains documented flags/defaults, but API 1 uses package drivers
  through Executor, with balances/sources/sinks/accepted/rejected metrics. Invalid
  config/metrics or zero accepted actions fail. Singles use a fresh full-pack
  executor per driver; recipes use their owner's coupled driver once. Legacy egg sim output is
  unchanged; an empty legacy egg loop is not successful farming proof.
- `qa validate` validates all manifest-bearing packages and scenario schemas,
  including declared files/operations/targets. It does not execute opaque YAML
  code or prove playability. `qa plan` requires qualified names and all generator
  scenarios for contract packs; contract smoke estimate >60s fails (60 allowed).
  Legacy bare names expand across selected genres and retain budget warnings.
  Planning writes a report, not an execution receipt or rendering proof.

## Commands

- `lune run cli/forge check`
  Runs the full repository verification pipeline in order:
  1. `selene`: Lints repository files against `selene.toml`.
  2. `stylua`: Checks repository formatting with `stylua --check .` according to `stylua.toml`.
  3. `luau-lsp`: Generates sourcemap and analyzes Roblox and Lune code with strict typechecking and Roblox definitions.
  4. `econ`: Regenerates `EconConfig.luau` in memory for every `games/*/econ.yml` and fails with `econ drift: ...` when the file on disk differs.
  5. `game`: Validates every pack's `game.yml` (no scaffold TBDs left behind).
  6. `assets`: Gates every pack's `assets/manifest.yml` for staging and fails on `Assets.luau` drift.
  7. `locale`: Runs `locale check` for every pack that has a `locale/strings.csv`.
  8. `lock`: Verifies each pack's `forge-lock.yml` pins match `core/forge-package.yml` and its genres' `forge-package.yml`.
  9. `specs`: Discovers and executes all `*.spec.luau` tests under `core/`, `games/`, `cli/`, and `genres/`.
  10. `build`: Compiles `games/kaiju-egg-raiders/default.project.json` to `build/kaiju-egg-raiders.rbxl`.
  11. `inspect`: Opens `build/kaiju-egg-raiders.rbxl`, verifies required instances, scans scripts, and verifies all relative requires resolve cleanly without leaking spec files or READMEs.

- `lune run cli/forge codegen [<pack>]`
  Writes deterministic GenreConfig.luau for validated API 1 sources, or legacy EconConfig.luau without the marker (default kaiju-egg-raiders). See contract semantics above; econ.yml is the source of truth.

- `lune run cli/forge new <slug> --genre <g1,g2>`
  Resolves package-owned generators; see contract semantics above for artifacts, recipes, compatibility and current integration gaps.

- `lune run cli/forge plan --concept "<text>" --genre <g> --pack <slug> [--seed N]`
  Invokes package generators deterministically; see contract semantics above. Collect retains its roster/template/tuner and rich binders; generic starters are representative, not production-complete games.

- `lune run cli/forge gen <image|mesh|sfx> --key <key> --prompt "<text>" [--pack <slug>] [--dry-run]`
  Generates one asset through the licensed provider fixed for its kind - `image` via Studio MCP (`IMAGE_GEN_URL`), `mesh` via Trellis (`TRELLIS_URL`), `sfx` via ElevenLabs (`ELEVENLABS_API_KEY`) - writes the bytes to `games/<pack>/assets/<kind>/<key>.<ext>`, and upserts the manifest entry as `NotUploaded`. `--dry-run` prints the exact request (method, URL, kind-specific body) and writes nothing, exiting 0 even without the provider's env var set; without `--dry-run` a missing env var prints the same request then exits 1 with `missing env <NAME>` before any network call. There is no `--tool` flag and no `bgm` kind (`bgm` cues come from `gen audio` below); `forge gen fulfill` below is the separate legacy path for a request produced by an earlier agent workflow.

- `lune run cli/forge gen procedural [--pack <slug>]`
  Generates a pack's creature/prop meshes entirely offline with the pure `core/domain/procgen` generators - no API keys, no network. Reads `games/<pack>/assets/procgen.yml` (each entry: `key`, `kind` `creature|prop`, `archetype`, `scale`, `body`/`accent`/`eye` as `[r, g, b]` 0-255, and a stable `seed`) plus `game.yml`'s `poly_budget` (creatures use the first of `kaiju|creature`, eggs use `egg`, other props use `prop`; fallbacks 3000/600/800), runs `Creature.generate`/`Prop.generate` under Lune, and exits 1 if any triangle count exceeds its budget. On success it writes the generated `games/<pack>/src/shared/ProcAssets.luau` specs module (`key -> {kind, archetype, spec, seed, triangleCount}`) and upserts each key into `assets/manifest.yml` as `tool: forge-procgen`, `moderation: Approved`, `assetId: 0`, printing one `<key> <kind>/<archetype> tris=<n> budget=<b>` line per asset. Kaiju runtime builds these with `core/infra/render/ProcAssets.build(specs, key)`; run `assets codegen` afterwards because the new manifest keys change `Assets.luau`.

- `lune run cli/forge gen audio [--pack <slug>] [--install]`
  Synthesises every cue in `games/<pack>/assets/audio.yml` entirely offline with the pure `core/domain/procgen` DSP (`Synth`: oscillators, ADSR, one-pole LP/HP, delay/reverb, PRNG) and composer (`Music`: chords, seeded melody, drums, intro/loop; moods `explore`/`siege`) - no API keys, no network, no `math.random`, so repeated runs are byte-identical. A cue is `kind: music` (`mood: explore|siege`), `kind: sfx` (`type: click|coin|hatch|rare|raid|error`), or `kind: ambience` (`type: wind|birds`), each with a stable `seed`. It writes 16-bit PCM mono WAVs to `games/<pack>/assets/audio/<cue>.wav`, upserts each as `tool: forge-procgen`, `moderation: Approved`, `assetId: 0`, and refreshes `Assets.luau`. With `--install` it also copies the WAVs into the newest Studio install's `content/forge/<pack>/`, which Roblox resolves as `rbxasset://forge/<pack>/<cue>.wav`.

- `lune run cli/forge econ sim [--pack <slug>] [--players N] [--days D] [--seed S] [--out <path>]`
  Defaults: kaiju-egg-raiders, 20 players, 7 days, seed 1, reports/econ-sim-<pack>.md. API 1 uses package drivers; legacy runs seeded econsim sessions/income/eggs/hatches/sieges. An unrelated schema is not meaningful proof merely because legacy parsing returns a report.
- `lune run cli/forge qa plan [--pack <slug>]`
  Validates pack selection and deterministic purchase slots, then writes reports/qa-plan-<pack>.md. See contract semantics above for qualified names and budget gates. It plans, not executes.

- `lune run cli/forge qa validate`
  Validates the registry, scenario schemas/identities and declared operations/targets. Missing declared files fail. Smoke rejects click/capture. It does not execute scenario code or gameplay.

- `lune run cli/forge deploy --env <staging|production> [--pack <slug>]`
  Requires current release-candidate schema2 approval and reuses the assessed place bytes without rebuilding. Only explicitly named `--development` staging builds an inspected place. Live target IDs must be positive finite integers. Credentials are `ROBLOX_STAGING_API_KEY` or `ROBLOX_PRODUCTION_API_KEY`, with exact decimal `ROBLOX_<ENV>_UNIVERSE_ID` and `ROBLOX_<ENV>_PLACE_ID` bindings (ENV is STAGING or PRODUCTION); there is no generic-key fallback. Production additionally requires `FORGE_ALLOW_PRODUCTION=1` and separate human authorization. The maintained helper uses installed Bun native fetch with a 30-second abort and 35-second Lune child watchdog. Missing runtime capability fails closed; no unsafe CLI override exists. Execution remains unverified.
  With `--dry-run` the command never touches the network and needs no API key or deploy ids: it reads `games/<pack>/game.yml` monetization and `deploy.yml` assets and writes `reports/deploy-plan-<pack>-<env>.md` with one `create` (id 0) or `update` (id set) row per gamepass/product, each marked `deterministic: yes`, plus the asset list. A paid random item (a `kind` of `random`/`roll`/`egg`, or any `pool`/`odds`/`random` field) exits 1 with `paid random item: <key>`. Live product/asset creation calls are intentionally not implemented.

- `lune run cli/forge locale check [--pack <slug>]`
  Verifies that every player-facing client literal (`Text = "..."` assignments and `string.format(...)` templates) is covered by the pack's `locale/strings.csv` and that no row is missing a `ko-kr` translation, printing `locale check: PASS`/`FAIL` with the pack and string count.

- `lune run cli/forge locale sync [--pack <slug>] [--dry-run]`
  Reads `games/<pack>/locale/strings.csv`, builds the Localization Tables API payload (one entry per row with `key`/`source`/`context` and a translation per locale column), and in dry-run writes `reports/locale-sync-<pack>.json`, printing the entry count. Dry-run is also the default when `ROBLOX_API_KEY` is unset or `deploy.yml` `localizationTableId` is `0`; live upload is not implemented, so a sync that clears those conditions exits 1 asking for `--dry-run`. No network calls happen in either case.

- `lune run cli/forge build`
  Runs Rojo to build `games/kaiju-egg-raiders/default.project.json` into `build/kaiju-egg-raiders.rbxl`.

- `lune run cli/forge inspect <path.rbxl> [--project <project.json>]`
  Checks required instance classes, relative require resolution and leaked specs/README modules. Without a project it retains the Kaiju compatibility assertions. With a project it checks the declared script entrypoints and hook modules against that generated project's paths/classes instead of requiring Kaiju-specific names/remotes.

- `lune run cli/forge trends [--fixture <path>] [--out <path>]`
  Collects the top Roblox experiences per genre and writes a markdown report (default `reports/trends-<YYYY-MM-DD>.md`): experience count, total CCU, and median gamepass price per genre, plus genres with no directory under `genres/` flagged as new Genre Module candidates (plan section 11.4). Live mode fetches the Explore `top-playing-now` sort via `@lune/net` and exits 1 with a clear message if the fetch fails; `--fixture` reads a saved JSON payload instead and never touches the network.

- `lune run cli/forge report [--pack <slug>] [--events <path>] [--out <path>]`
  Reads a JSON-lines analytics log (default `games/<pack>/analytics/events.jsonl`), counts events against `core/infra/analytics/Events.luau`, and writes the weekly liveops report to `reports/<pack>-weekly-<YYYY-MM-DD>.md`: event counts, tutorial completion rate, Robux revenue, and the `session_start -> egg_purchase -> egg_hatch -> robux_purchase` funnel.

## Asset pipeline

`assets/manifest.yml` is the single source of truth for a pack's assets. Each entry has `key` (unique, `[a-zA-Z][a-zA-Z0-9_]*`), `kind` (`mesh|image|sfx|bgm|model`), `tool` (from the allow-list in `cli/forge/lib/licenses.luau`), `source` (prompt or Creator Store/library reference), an optional local `path`, `assetId` (`0` = not uploaded yet), and `moderation` (`Approved|PendingModeration|Rejected|NotUploaded`).

- `lune run cli/forge assets check [--pack <slug>] [--env staging|production] [--manifest <path>]`
  Parses and gates a manifest with the pure `cli/forge/lib/assets.luau`: every `tool` must pass the license registry, keys must be unique, `production` requires `Approved` with `assetId > 0`, and `staging` allows `PendingModeration`/`NotUploaded` but never `Rejected`. On top of that per-env gate it always applies the framework gate (`assets.checkFramework`) regardless of `--env`: every asset must come from `forge-procgen` or `roblox-audio-library`, be `Approved`, and carry no TBD/placeholder `source`/`path`, so a shipped manifest can never regress to hand-made or unapproved assets. Entries written by `forge gen image|mesh|sfx` or `forge gen fulfill` (`NotUploaded`/`PendingModeration`, non-framework tools) therefore fail `assets check` and the `check [assets]` stage until they are replaced by framework-generated, Approved assets. Prints `assets check: PASS (<n> assets, env=<env>)` or each error then `assets check: FAIL` (exit 1).

- `lune run cli/forge assets codegen [--pack <slug>]`
  Writes `games/<pack>/src/shared/Assets.luau` (sorted `key -> "rbxassetid://<id>"`, `""` when the id is unset) and `games/<pack>/asphalt.toml` (image/sfx/bgm inputs only; meshes and models are excluded because Asphalt does not upload them via the web API). Never hand-edit the generated `Assets.luau`.

- `lune run cli/forge assets status [--pack <slug>]`
  Refreshes `moderation` for every uploaded asset through the Open Cloud Assets API (`GET https://apis.roblox.com/assets/v1/assets/<assetId>` with `x-api-key` from `ROBLOX_API_KEY`) and writes the manifest back. With `ROBLOX_API_KEY` unset it exits 1 with `Error: ROBLOX_API_KEY is not set; assets status needs Open Cloud access` before any network call.

- `lune run cli/forge assets upload-audio [--pack <slug> | --pack-dir <dir>] [--creator-group <id>] [--cache <path>] [--dry-run]`
  Publishes a pack's synthesised WAV cues (`sfx`/`bgm` entries with a local `path`) through the Open Cloud Assets API: one `POST https://apis.roblox.com/assets/v1/assets` multipart create per cue (creator = `--creator-group`, default `570462331`, i.e. the staging group), then a bounded poll of `GET https://apis.roblox.com/assets/v1/operations/<id>` until it finishes. The returned `rbxassetid` and moderation state are written into `assets/manifest.yml` (the existing provenance block is kept) and `src/shared/Assets.luau` is refreshed, so a cue resolves to `rbxassetid://<id>` instead of a dev-only `rbxasset://` path. `--pack-dir` targets a scratch pack outside `games/` (e.g. a `forge sweep` pack).
  The upload is idempotent by artifact sha256: a cue whose exact bytes were published before is reused from `build/audio-upload-cache.json` (keyed by the bare sha256 hex, so the same WAV serves every pack and sweep) rather than re-uploaded, and `--dry-run` prints what would be published with no key and no network. A missing `ROBLOX_API_KEY` or a key without the `asset:write` scope stops the command and prints the exact API error (for example `create HTTP 403 Forbidden: {"code":"PERMISSION_DENIED","message":"User not authenticated"}`). Pending moderation is reported on its own line (`audio playable: <n> of <n> cues approved`) and never treated as playable.

- `lune run cli/forge gen fulfill <requestFile> --key <assetKey> [--asset-id <n>]`
  Reads a pending request written by `forge gen` (`kind`, `prompt`, `tool`, `pack`), appends it to `games/<pack>/assets/manifest.yml` (`NotUploaded` without `--asset-id`, `PendingModeration` with it), and marks the request `status = "fulfilled"`.

`forge check` runs an `assets` stage after `econ`: for every pack with `assets/manifest.yml` it gates the manifest for staging and fails on `Assets.luau` drift with `run: lune run cli/forge assets codegen --pack <pack>`.
- `lune run cli/forge smoke [--pack <slug>] [--local] [--cloud] [--fixture <save.json>] [--dry-run]`
  Runs a pack's smoke checks. Default (`--local`) loads `games/<pack>/smoke/smoke.luau` and runs its pure checks (profile save round-trip, econ config validity, DataStore-safe serialization, and profile migration defaults), printing `PASS <name>` or `FAIL <name>: <detail>` per check and `smoke: PASS (<n> checks)`/`smoke: FAIL`; a pack without a smoke script prints `smoke: no smoke script for <pack>` and exits 0. `--fixture <save.json>` runs the round-trip against a decoded save instead (the checks fail when coins is not a finite number). `--cloud` bundles the smoke source and posts `POST https://apis.roblox.com/cloud/v2/universes/<id>/places/<id>/luau-execution-session-tasks` (`{"script": ..., "timeout": "300s"}`, one task per invocation) with `ROBLOX_API_KEY`, then polls the task path every 5 seconds up to 300 seconds and prints the final state; missing key or unset staging ids exit 1 before any network call, and `--dry-run` prints the method, URL, and first 400 characters of the body offline.
- `lune run cli/forge report --all [--out <path>]`
  Multi-game dashboard: for every `games/<pack>/` directory reads `games/<pack>/analytics/events.jsonl` when it exists (falling back to the shared `cli/forge/fixtures/events-sample.jsonl` for `kaiju-egg-raiders`, else zero rows), summarizes each pack with the same report functions, and writes `reports/dashboard-<YYYY-MM-DD>.md` with one row per pack (players, tutorial completion %, payers, Robux revenue).
- `lune run cli/forge liveops push --pack <slug> --event <id> [--dry-run]`
  Reads the staging `universeId` and configured event. Requires `ROBLOX_STAGING_API_KEY` and exact decimal `ROBLOX_STAGING_UNIVERSE_ID`, with no generic fallback; shared loaded keys and overlapping environment targets are refused. `--dry-run` prints `POST <url>`, topic, messageBytes and messageSha256, not raw payload, and supports unset ID 0. The default helper uses installed Bun with a 30-second fetch abort and 35-second owned-process watchdog; unavailable capability fails closed with `PUBLISH_TRANSPORT_UNSUPPORTED`. The shared adapter never retries and emits sanitized permission, rate-limit, timeout, malformed-reply and transport codes. See [operations](../../docs/release/operations.md) for contracts and remaining live-pilot limits.
