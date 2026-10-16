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

### Contract command semantics

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

## Prerequisites and usage

Install the pinned toolchain from `rokit.toml` (`rokit install`) and run `lune setup` once afterwards.
`bun` is additionally needed for the JavaScript suites (`bun test`), the deploy/liveops
transport and Studio QA.

All commands run from the repository root as `lune run cli/forge <command> [args...]`.

- `lune run cli/forge --help` (also `-h` and `help`) prints the command list to stdout and exits 0.
- `lune run cli/forge <command> --help` prints that command's usage to stdout and exits 0.
- No arguments print the usage to stderr and exit 2; an unknown command also exits 2.
- Exit codes: every command exits 0 on success and 1 on failure, except `imagediff` and
  `replay`, which use 0/1/2 as described in their sections (2 = usage or input error).
- Evidence and output directories are Git-ignored: `.omo/evidence/`, `reports/`, `build/`
  and `build/sweep/<stamp>/`.

## Commands

- `lune run cli/forge check [--only <stages>] [--skip <stages>] [--json <path>] [--pack <slug> | --project <path> | --all] [--packs-root <dir>]`
  Runs the repository verification pipeline as 13 stages, in this order. The ids are the values accepted by `--only` and `--skip`:
  1. `genre-contract`: Discovers the genre registry and validates every API 1 package.
  2. `qa-schema`: Validates every genre's QA scenario schemas (same check as `qa validate`).
  3. `selene`: Lints repository files against `selene.toml`.
  4. `stylua`: Checks repository formatting with `stylua --check .` according to `stylua.toml`.
  5. `luau-lsp`: Generates a sourcemap and analyzes Roblox and Lune code with strict typechecking and Roblox definitions.
  6. `econ`: Regenerates `GenreConfig.luau` / `EconConfig.luau` in memory for every `games/*/econ.yml` and fails with `econ drift: ...` when the file on disk differs.
  7. `game`: Validates every pack's `game.yml` (no scaffold TBDs left behind) against the genre contract.
  8. `assets`: Gates every pack's `assets/manifest.yml` for staging and fails on `Assets.luau` drift.
  9. `locale`: Runs `locale check` for every pack that has a `locale/strings.csv`.
  10. `provenance`: Runs the release provenance gate (QA-PROV-01/QA-NAME-01) for every pack that opted in with `provenance/policy.yml`; packs without a policy are skipped. See `provenance` below.
  11. `lock`: Verifies each pack's `forge-lock.yml` pins match `core/forge-package.yml` and its genres' `forge-package.yml`.
  12. `specs`: Discovers and executes all `*.spec.luau` tests under `core/`, `games/`, `cli/` and `genres/` (the suite `forge test` runs).
  13. `build`: Builds every discovered pack under `games/` with Rojo into `build/<slug>.rbxl` and inspects each built place (required instances, script entrypoints, relative requires resolve, no leaked specs or READMEs). Each target is independent: one failing pack never hides another, and a failed build is never inspected.

  `--only a,b` runs just the listed stages and `--skip a,b` omits them; an unknown id is a usage error that lists the valid ids. `--pack <slug>`, `--project <path>` and `--all` narrow only the `build` stage (which includes inspection); every other stage still covers every pack. `--packs-root <dir>` swaps the build stage's pack discovery root. Each stage prints `[<id>] PASS|FAIL (<s> s)` with its wall time, tool detail appears only on FAIL, and the run ends with `check: PASS (<n> stages, <s> s)` or `check: FAIL stages=<ids> (<s> s)`. `--json <path>` also writes a report (`schemaVersion` 1) with `ok`, a per-stage list (`id`, `ok`, `skipped`, `ms`) and `failed`, a list of the failed stage ids (`[]` when none).

- `lune run cli/forge codegen [<pack>]`
  Writes deterministic `GenreConfig.luau` for validated API 1 sources, or legacy `EconConfig.luau` without the marker (default `kaiju-egg-raiders`); `econ.yml` is the source of truth. See contract semantics above.

- `lune run cli/forge new <slug> --genre <g1,g2>`
  Resolves package-owned generators into `games/<slug>/`; see contract semantics above.

- `lune run cli/forge plan --concept "<text>" --genre <g> --pack <slug> [--seed N]`
  Invokes package generators deterministically; see contract semantics above.

- `lune run cli/forge gen <image|mesh|sfx> --key <key> --prompt "<text>" [--pack <slug>] [--dry-run]`
  Generates one asset through the licensed provider fixed for its kind - `image` via Studio MCP (`IMAGE_GEN_URL`), `mesh` via Trellis (`TRELLIS_URL`), `sfx` via ElevenLabs (`ELEVENLABS_API_KEY`) - writes the bytes to `games/<pack>/assets/<kind>/<key>.<ext>`, and upserts the manifest entry as `NotUploaded`. `--dry-run` prints the exact request (method, URL, kind-specific body) and writes nothing, exiting 0 even without the provider's env var set; without `--dry-run` a missing env var prints the same request then exits 1 with `missing env <NAME>` before any network call. There is no `--tool` flag and no `bgm` kind (`bgm` cues come from `gen audio` below); `forge gen fulfill` below is the separate legacy path for a request produced by an earlier agent workflow.

- `lune run cli/forge gen procedural [--pack <slug>]`
  Generates a pack's creature/prop meshes entirely offline with the pure `core/domain/procgen` generators - no API keys, no network. Reads `games/<pack>/assets/procgen.yml` (each entry: `key`, `kind` `creature|prop`, `archetype`, `scale`, `body`/`accent`/`eye` as `[r, g, b]` 0-255, and a stable `seed`) plus `game.yml`'s `poly_budget` (creatures use the first of `kaiju|creature`, eggs use `egg`, other props use `prop`; fallbacks 3000/600/800), runs `Creature.generate`/`Prop.generate` under Lune, and exits 1 if any triangle count exceeds its budget. On success it writes the generated `games/<pack>/src/shared/ProcAssets.luau` specs module (`key -> {kind, archetype, spec, seed, triangleCount}`) and upserts each key into `assets/manifest.yml` as `tool: forge-procgen`, `moderation: Approved`, `assetId: 0`, printing one `<key> <kind>/<archetype> tris=<n> budget=<b>` line per asset. Kaiju runtime builds these with `core/infra/render/ProcAssets.build(specs, key)`; run `assets codegen` afterwards because the new manifest keys change `Assets.luau`.

- `lune run cli/forge gen audio [--pack <slug>] [--install]`
  Synthesises every cue in `games/<pack>/assets/audio.yml` entirely offline with the pure `core/domain/procgen` DSP (`Synth`: oscillators, ADSR, one-pole LP/HP, delay/reverb, PRNG) and composer (`Music`: chords, seeded melody, drums, intro/loop; moods `explore`/`siege`) - no API keys, no network, no `math.random`, so repeated runs are byte-identical. A cue is `kind: music` (`mood: explore|siege`), `kind: sfx` (`type: click|coin|hatch|rare|raid|error`), or `kind: ambience` (`type: wind|birds`), each with a stable `seed`. It writes 16-bit PCM mono WAVs to `games/<pack>/assets/audio/<cue>.wav`, upserts each as `tool: forge-procgen`, `moderation: Approved`, `assetId: 0`, and refreshes `Assets.luau`. With `--install` it also copies the WAVs into the newest Studio install's `content/forge/<pack>/`, which Roblox resolves as `rbxasset://forge/<pack>/<cue>.wav`.

- `lune run cli/forge econ sim [--pack <slug>] [--players N] [--days D] [--seed S] [--out <path>] [--json <path>]`
  Defaults: kaiju-egg-raiders, 20 players, 7 days, seed 1, `reports/econ-sim-<pack>.md`. `--json <path>` also writes a machine-readable result (`schemaVersion` 1). See contract semantics above for the API 1 drivers.

- `lune run cli/forge qa plan [--pack <slug>]`
  Validates pack selection and deterministic purchase slots, then writes `reports/qa-plan-<pack>.md`. It plans, not executes; see contract semantics above.

- `lune run cli/forge qa validate`
  Validates the registry, scenario schemas/identities and declared operations/targets. Missing declared files fail. It does not execute scenario code or gameplay; see contract semantics above.

- `lune run cli/forge qa run --pack <slug> --scenario <name> [--native|--studio] [--evidence <path>] [--record <journal.json>] [--studio-receipt <path>] [--packs-root <dir>] [--bootstrap-owned]`
  Executes one declarative QA scenario (`kind: native|studio`). `--native` (the default) runs headless against the pack's real Session/Executor/genre adapters with an explicit clock and injectable commit barriers; `--studio` drives a connected Studio client through the maintained driver (needs `bun`, see [cli/forge/qa/README.md](qa/README.md)). A missing scenario, a scenario that asserts nothing and an unreachable Studio client all FAIL: there is no skip path and `--studio` never falls back to a headless run. `--bootstrap-owned` requires `--studio`, `--studio-receipt` and `--evidence`. `--record <journal.json>` writes the command journal of the run for `forge replay`. A native scenario may declare `seed: <int>` (a non-negative integer) to seed the roll stream; a capture step takes `layers: all|world|ui`.

- `lune run cli/forge deploy --env <staging|production> [--pack <slug>]`
  Requires current release-candidate schema2 approval and reuses the assessed place bytes without rebuilding. Only explicitly named `--development` staging builds an inspected place. `deploy.yml` target IDs are literal positive finite integers or `${FORGE_<ENV>_UNIVERSE_ID}` / `${FORGE_<ENV>_PLACE_ID}` references resolved from the environment when the file loads (a reference to an unset variable is refused by name, never defaulted); an unconfigured production target stays `0/0`. Credentials are `ROBLOX_STAGING_API_KEY` or `ROBLOX_PRODUCTION_API_KEY`, with exact decimal `ROBLOX_<ENV>_UNIVERSE_ID` and `ROBLOX_<ENV>_PLACE_ID` bindings (ENV is STAGING or PRODUCTION) that must match the resolved target; there is no generic-key fallback. Production additionally requires `FORGE_ALLOW_PRODUCTION=1` and separate human authorization. The maintained helper uses installed Bun native fetch with a 30-second abort and 35-second Lune child watchdog. Missing runtime capability fails closed; no unsafe CLI override exists. Execution remains unverified.
  With `--dry-run` the command never touches the network and needs no API key or deploy ids: it reads `games/<pack>/game.yml` monetization and `deploy.yml` assets and writes `reports/deploy-plan-<pack>-<env>.md` with one `create` (id 0) or `update` (id set) row per gamepass/product, each marked `deterministic: yes`, plus the asset list. A paid random item (a `kind` of `random`/`roll`/`egg`, or any `pool`/`odds`/`random` field) exits 1 with `paid random item: <key>`. Live product/asset creation calls are intentionally not implemented.

- `lune run cli/forge provenance check --pack <slug> [--packs-root <dir>] [--json <path>]`
  Release provenance gate (plan §9.5, ADR-06). Only packs with `games/<pack>/provenance/policy.yml` are checked; `check` on a pack without one exits 1. The gate scans `locale/strings.csv` (every non-Context column), `content.yml`, `game.yml`, `econ.yml`, `deploy.yml` and manifest `key`/`source` strings after normalizing them to a skeleton (NFC-free: width/case folded, spaces, punctuation and zero-width marks dropped; invalid UTF-8 and decomposed Hangul jamo are refused as `NAME-ENCODING`). Rules: `NAME-TERM`/`NAME-STEM` (substring of the skeleton), `NAME-LETTER` (standalone capital letter in `dialogueKeyPrefixes` locale rows and `speaker` fields), `NAME-HASHED` (sha256-48 hashed proper names), `PROV-NGRAM` (8-gram hash fingerprints), `PROV-MISSING`/`PROV-STALE`/`PROV-FIELD` (sidecars `content.provenance.yml`, `econ.provenance.yml`, `locale/provenance.csv` must cover every item/key with `source`, `author` and `created`), `ASSET-TOOL`/`ASSET-PROV` (policy tool and `forge-procgen` recipe allow-list: `gen-procedural`, `gen-audio`; `author`/`created` on each manifest `provenance`), `PROV-POLICY`, `PROV-FP`. Findings go to stderr one per line as `<pack>: <file>:<locator>: <RULE> <detail>` and never print the matched banned word or gram in plain text; the summary is `provenance: PASS <pack> (...)` on stdout or `provenance: FAIL <pack> (<k> findings)` on stderr. `--json` writes `{schemaVersion: 1, ok, pack, findings}`. A fingerprint set too large for Git may live elsewhere: `provenance/fingerprints/<id>.path` holds one line naming the directory that contains `<id>.fp` and `<id>.meta.yml`. The reference-IP kit (`cli/forge/provenance/reference-ip/`: `banned-names.yml`, `policy.example.yml`, `fingerprints/namu-20261016.*`, about 2.8 MB of hashes, no source text) is shared through such a pointer.

- `lune run cli/forge provenance fingerprint --corpus <dir> --set <id> --out <dir>` / `provenance fingerprint --names <file> --salt <salt>`
  Hashes every `.txt` in a (gitignored) corpus into a sorted, de-duplicated `<id>.fp` of 12-hex sha256-48 hashes of skeleton 8-grams, skipping digit-only grams and grams present in at least half of the documents (site chrome), plus `<id>.meta.yml` (per-document sha256 and gram counts, `count`, `fpSha256`). Identical input writes identical bytes. `--names` prints `hashedNames` entries for a reviewed proper-name list.

- `lune run cli/forge locale check [--pack <slug>]`
  Verifies that every player-facing client literal (`Text = "..."` assignments and `string.format(...)` templates) is covered by the pack's `locale/strings.csv` and that no row is missing a `ko-kr` translation, printing `locale check: PASS`/`FAIL` with the pack and string count.

- `lune run cli/forge locale sync [--pack <slug>] [--dry-run]`
  Reads `games/<pack>/locale/strings.csv`, builds the Localization Tables API payload (one entry per row with `key`/`source`/`context` and a translation per locale column), and in dry-run writes `reports/locale-sync-<pack>.json`, printing the entry count. Dry-run is also the default when `ROBLOX_API_KEY` is unset or `deploy.yml` `localizationTableId` is `0`; live upload is not implemented, so a sync that clears those conditions exits 1 asking for `--dry-run`. No network calls happen in either case.

- `lune run cli/forge build [--all | --pack <slug> | --project <path>] [--packs-root <dir>]`
  Builds game places with Rojo into `build/<slug>.rbxl` and inspects each built place. With no selector the default pack `kaiju-egg-raiders` is built to `build/kaiju-egg-raiders.rbxl`; `--all` builds every discovered pack under `games/`, `--pack` one pack and `--project` one project file. Selectors are mutually exclusive. Each target is built and inspected independently, so one failing target never stops another; a target whose build failed is never inspected.

- `lune run cli/forge inspect <path.rbxl> [--project <project.json>]`
  Checks required instance classes, relative require resolution and leaked specs/README modules. Without a project it retains the Kaiju compatibility assertions. With a project it checks the declared script entrypoints and hook modules against that generated project's paths/classes instead of requiring Kaiju-specific names/remotes.

- `lune run cli/forge trends [--fixture <path>] [--out <path>]`
  Collects the top Roblox experiences per genre and writes a markdown report (default `reports/trends-<YYYY-MM-DD>.md`): experience count, total CCU, and median gamepass price per genre, plus genres with no directory under `genres/` flagged as new Genre Module candidates (plan section 11.4). Live mode fetches the Explore `top-playing-now` sort via `@lune/net` and exits 1 with a clear message if the fetch fails; `--fixture` reads a saved JSON payload instead and never touches the network.

- `lune run cli/forge report [--pack <slug>] [--events <path>] [--out <path>]`
  Reads a JSON-lines analytics log (default `games/<pack>/analytics/events.jsonl`), counts events against `core/infra/analytics/Events.luau`, and writes the weekly liveops report to `reports/<pack>-weekly-<YYYY-MM-DD>.md`: event counts, tutorial completion rate, Robux revenue, and the `session_start -> egg_purchase -> egg_hatch -> robux_purchase` funnel.

## Testing and debugging tools

- `lune run cli/forge test [filters...] [--quiet] [--slowest N] [--json <path>]`
  Discovers and runs every `*.spec.luau` under `core/`, `games/`, `cli/` and `genres/` (the same suite as the `check` `specs` stage). A test runs when any filter is a substring of its spec path or of `path :: testName`; no filters runs everything. `--quiet` prints only FAIL lines and the summary, `--slowest N` lists the N slowest tests before the summary, and `--json <path>` writes a machine-readable report. Exits 1 when any test fails. `specs-run` remains as a hidden alias. JavaScript suites (`*.test.mjs`, `*.spec.mjs`) are not discovered by Lune; run them with `bun test <file>` (see [docs/release/verification.md](../../docs/release/verification.md)).

- `lune run cli/forge replay <journal.json> [--json]`
  Re-executes a command journal recorded by `qa run --record` and compares the result with the recorded one. Exits 0 on `MATCH`, 1 on `MISMATCH` and 2 on a usage or input error. `--json` prints a machine-readable result.

- `lune run cli/forge imagediff <base.png> <compare.png> [--diff <out.png>] [--threshold <n>] [--ignore x1:y1-x2:y2[,..]] [--crop x:y:w:h] [--json]`
  Compares two PNG screenshots pixel by pixel. Prints `imagediff: identical` or `imagediff: N different pixels (P%) bbox=x1,y1,x2,y2`; `--diff` writes a diff image, `--threshold` sets the per-pixel tolerance, `--ignore` masks regions, `--crop` compares one rectangle and `--json` prints one JSON object (`schemaVersion` 1). Exits 0 when identical, 1 when different and 2 on a usage or decode error.

- `lune run cli/forge sweep [--genres a,b,...] [--out <dir>] [--stamp <text>]`
  Baseline playability sweep: generates a fresh pack for every registered genre (plus `survival-coop` in crafting mode) into a scratch packs root outside `games/`, then records, per genre and independently, `generate`, `files`, `build`, `inspect`, `spec`, `nativeQa` and `surface` results with step timings, so one failing genre never stops another. Writes `sweep.json` (`schemaVersion` 1) and `sweep.md` to `--out` (default `build/sweep/<stamp>/`); `--stamp` names the run directory and must be letters, digits, `.`, `_` or `-`. Exits 1 when any genre is not fully green.

- `lune run cli/forge spec init --genre <id> [--concept "<text>"] [--pack <slug>] [--force]`
  Writes a draft `genres/<id>/genre-spec.yml` seeded from the genre's `econ-template.yml` and `design-template.md`. The draft is valid but incomplete: an agent fills it in and then removes `draft: true`. See [docs/forge/genre-spec.md](../../docs/forge/genre-spec.md).

- `lune run cli/forge spec validate [--genre <id>]`
  Reports every declarative genre-spec violation as `file: reason`. A spec that fails any rule fails genre discovery, so every other command refuses to run against it.

- `lune run cli/forge content check --file <path>`
  Validates a versioned survival content catalog (items, recipes, nodes, structures, wildlife) and prints every violation with its field path. Catalog refs, caps, cycles and fixed-point quantities are checked before anything is written.

- `lune run cli/forge content codegen --pack <slug> [--packs-root <dir>]`
  Writes `games/<pack>/src/shared/SurvivalContent.luau` from the pack's `content.yml`. Deterministic: identical input produces byte-identical output.

## Quality gate

`quality` handles a pack's quality profile (`quality.yml`: tier, reference package, anchored rubric, first-play goals). Nothing here approves fun or visual quality on its own: a profile that validates is a well-formed claim, a self-declared verdict fails, and a missing evaluator or inconclusive evidence cannot approve.

- `lune run cli/forge quality validate [--file <path>] [--pack <slug>]`
  Validates one quality profile document and prints every schema violation with its field path. Schema only.

- `lune run cli/forge quality evaluate --pack <slug> --capture <dir> --reference <path> --out <path> [--observations <path>]`
  Invokes the configured evaluator on bound first-play evidence (`FORGE_QUALITY_EVALUATOR` / `FORGE_QUALITY_ATTESTATION`).

- `lune run cli/forge quality evaluate --pack <slug> --sweep <dir> [--out <path>] [--captures <dir>] [--av <path>] [--packs-root <dir>]`
  Builds an evidence receipt for a sweep pack from the sweep's own columns, its headless load proof and native QA results (default output `<dir>/quality/<pack>.json`); `--captures` and `--av` attach a Studio capture manifest and an AV source receipt.

- `lune run cli/forge quality check --pack <slug> [--target starter|vertical-slice|release-candidate] [--receipt <path>] [--packs-root <dir>]`
  Checks the declared tier (a target may not downgrade it). `starter` passes without approval; higher tiers need a current digest-bound receipt. With `--evidence <path>` or `--sweep <dir>` (and optional `--out <path>`) it validates a sweep evidence receipt against the declared tier instead.


## Asset pipeline

`assets/manifest.yml` is the single source of truth for a pack's assets. Each entry has `key` (unique, `[a-zA-Z][a-zA-Z0-9_]*`), `kind` (`mesh|image|sfx|bgm|model`), `tool` (from the allow-list in `cli/forge/lib/licenses.luau`), `source` (prompt or Creator Store/library reference), an optional local `path`, `assetId` (`0` = not uploaded yet), and `moderation` (`Approved|PendingModeration|Rejected|NotUploaded`).

- `lune run cli/forge assets check [--pack <slug>] [--env staging|production] [--manifest <path>]`
  Parses and gates a manifest with the pure `cli/forge/lib/assets.luau`: every `tool` must pass the license registry, keys must be unique, `production` requires `Approved` with `assetId > 0`, and `staging` allows `PendingModeration`/`NotUploaded` but never `Rejected`. On top of that per-env gate it always applies the framework gate (`assets.checkFramework`) regardless of `--env`: every asset must come from `forge-procgen` or `roblox-audio-library`, be `Approved`, and carry no TBD/placeholder `source`/`path`, so a shipped manifest can never regress to hand-made or unapproved assets. Entries written by `forge gen image|mesh|sfx` or `forge gen fulfill` (`NotUploaded`/`PendingModeration`, non-framework tools) therefore fail `assets check` and the `check [assets]` stage until they are replaced by framework-generated, Approved assets. Prints `assets check: PASS (<n> assets, env=<env>)` or each error then `assets check: FAIL` (exit 1).

- `lune run cli/forge assets codegen [--pack <slug>]`
  Writes `games/<pack>/src/shared/Assets.luau` (sorted `key -> "rbxassetid://<id>"`, `""` when the id is unset) and `games/<pack>/asphalt.toml` (image/sfx/bgm inputs only; meshes and models are excluded because Asphalt does not upload them via the web API). Never hand-edit the generated `Assets.luau`.

- `lune run cli/forge assets status [--pack <slug>]`
  Refreshes `moderation` for every uploaded asset through the Open Cloud Assets API (`GET https://apis.roblox.com/assets/v1/assets/<assetId>` with `x-api-key` from `ROBLOX_API_KEY`) and writes the manifest back. With `ROBLOX_API_KEY` unset it exits 1 with `Error: ROBLOX_API_KEY is not set; assets status needs Open Cloud access` before any network call.

- `lune run cli/forge assets upload-audio [--pack <slug> | --pack-dir <dir>] [--creator-group <id> | --creator-user <id>] [--cache <path>] [--dry-run]`
  Publishes a pack's synthesised WAV cues (`sfx`/`bgm` entries with a local `path`) through the Open Cloud Assets API: one `POST https://apis.roblox.com/assets/v1/assets` multipart create per cue (creator = `--creator-group <id>` or `--creator-user <id>`, else `FORGE_ROBLOX_CREATOR_GROUP_ID` / `FORGE_ROBLOX_CREATOR_USER_ID`; there is no built-in default id, and a missing creator is refused before any request), then a bounded poll of `GET https://apis.roblox.com/assets/v1/operations/<id>` until it finishes. The returned `rbxassetid` and moderation state are written into `assets/manifest.yml` (the existing provenance block is kept) and `src/shared/Assets.luau` is refreshed, so a cue resolves to `rbxassetid://<id>` instead of a dev-only `rbxasset://` path. `--pack-dir` targets a scratch pack outside `games/` (e.g. a `forge sweep` pack).
  The upload is idempotent by artifact sha256: a cue whose exact bytes were published before is reused from `build/audio-upload-cache.json` (keyed by the bare sha256 hex, so the same WAV serves every pack and sweep) rather than re-uploaded, and `--dry-run` prints what would be published with no key and no network. A missing `ROBLOX_API_KEY` or a key without the `asset:write` scope stops the command and prints the exact API error (for example `create HTTP 403 Forbidden: {"code":"PERMISSION_DENIED","message":"User not authenticated"}`). Pending moderation is reported on its own line (`audio playable: <n> of <n> cues approved`) and never treated as playable.

- `lune run cli/forge gen fulfill <requestFile> --key <assetKey> [--asset-id <n>]`
  Reads a pending request written by `forge gen` (`kind`, `prompt`, `tool`, `pack`), appends it to `games/<pack>/assets/manifest.yml` (`NotUploaded` without `--asset-id`, `PendingModeration` with it), and marks the request `status = "fulfilled"`.

`forge check` runs an `assets` stage after `econ`: for every pack with `assets/manifest.yml` it gates the manifest for staging and fails on `Assets.luau` drift with `run: lune run cli/forge assets codegen --pack <pack>`.
- `lune run cli/forge smoke [--pack <slug>] [--local] [--cloud] [--strict] [--fixture <save.json>] [--dry-run]`
  Runs a pack's smoke checks. Default (`--local`) loads `games/<pack>/smoke/smoke.luau` and runs its pure checks (profile save round-trip, econ config validity, DataStore-safe serialization, and profile migration defaults), printing `PASS <name>` or `FAIL <name>: <detail>` per check and `smoke: PASS (<n> checks)`/`smoke: FAIL`; a pack without a smoke script prints `smoke: no smoke script for <pack>` and exits 0, unless `--strict` is given, which makes a missing smoke script a failure. `--fixture <save.json>` runs the round-trip against a decoded save instead (the checks fail when coins is not a finite number). `--cloud` bundles the smoke source and posts `POST https://apis.roblox.com/cloud/v2/universes/<id>/places/<id>/luau-execution-session-tasks` (`{"script": ..., "timeout": "300s"}`, one task per invocation) with `ROBLOX_API_KEY`, then polls the task path every 5 seconds up to 300 seconds and prints the final state; missing key or unset staging ids exit 1 before any network call, and `--dry-run` prints the method, URL, and first 400 characters of the body offline.
- `lune run cli/forge report --all [--out <path>]`
  Multi-game dashboard: for every `games/<pack>/` directory reads `games/<pack>/analytics/events.jsonl` when it exists (falling back to the shared `cli/forge/fixtures/events-sample.jsonl` for `kaiju-egg-raiders`, else zero rows), summarizes each pack with the same report functions, and writes `reports/dashboard-<YYYY-MM-DD>.md` with one row per pack (players, tutorial completion %, payers, Robux revenue).
- `lune run cli/forge liveops push --pack <slug> --event <id> [--dry-run]`
  Reads the staging `universeId` and configured event. Requires `ROBLOX_STAGING_API_KEY` and exact decimal `ROBLOX_STAGING_UNIVERSE_ID`, with no generic fallback; shared loaded keys and overlapping environment targets are refused. `--dry-run` prints `POST <url>`, topic, messageBytes and messageSha256, not raw payload, and supports unset ID 0 (an unset `${FORGE_STAGING_UNIVERSE_ID}` reference reads the same as `0`). The default helper uses installed Bun with a 30-second fetch abort and 35-second owned-process watchdog; unavailable capability fails closed with `PUBLISH_TRANSPORT_UNSUPPORTED`. The shared adapter never retries and emits sanitized permission, rate-limit, timeout, malformed-reply and transport codes. See [operations](../../docs/release/operations.md) for contracts and remaining live-pilot limits.

## Environment variables

Owner-specific Roblox ids and secrets are never committed. `games/<pack>/deploy.yml`
normally declares its target as `${FORGE_<ENV>_UNIVERSE_ID}` / `${FORGE_<ENV>_PLACE_ID}`
references, resolved from the environment when `forge deploy` loads the file; an
unset reference is refused with the variable's name. `cli/forge/publish-staging.sh`
additionally sources a gitignored `.env.local` beside the repository root when one
exists, so a local workflow keeps its ids out of Git.

| Variable | Used by | Meaning |
| --- | --- | --- |
| `FORGE_STAGING_UNIVERSE_ID` | `deploy`, `liveops push`, `smoke --cloud`, `publish-staging.sh` | Staging experience (universe) id the pack targets. |
| `FORGE_STAGING_PLACE_ID` | `deploy`, `smoke --cloud`, `publish-staging.sh` | Staging start place id. |
| `FORGE_PRODUCTION_UNIVERSE_ID` / `FORGE_PRODUCTION_PLACE_ID` | `deploy` | Production target ids when a pack declares them; unconfigured production stays `0/0`. |
| `ROBLOX_STAGING_API_KEY` / `ROBLOX_PRODUCTION_API_KEY` | `deploy`, `liveops push` | Open Cloud keys, one per environment; no generic-key fallback. |
| `ROBLOX_STAGING_UNIVERSE_ID` / `ROBLOX_STAGING_PLACE_ID` (and `ROBLOX_PRODUCTION_*`) | `deploy`, `liveops push` | Exact decimal credential-scope bindings; they must match the resolved `deploy.yml` target, so a key scoped to another experience is refused (`CREDENTIAL_TARGET_MISMATCH`). |
| `ROBLOX_API_KEY` | `assets status`, `assets upload-audio`, `locale check`, `smoke --cloud` | Open Cloud key for asset, localization and cloud-smoke calls. |
| `FORGE_ROBLOX_CREATOR_GROUP_ID` / `FORGE_ROBLOX_CREATOR_USER_ID` | `assets upload-audio` | Creator that owns uploaded audio; exactly one, no default id. `--creator-group` / `--creator-user` override. |
| `FORGE_OWNER_USER_ID` | `publish-staging.sh` | Real owner user id written into a published survival pack's provisioning config; no default. |
| `FORGE_STAGING_OWNER_USER_ID` / `FORGE_QA_ACTOR_IDS` | `forge gen` / `forge sweep` crafting generation | Staging owner and the closed QA actor allowlist recorded in a generated crafting pack. |
| `FORGE_ALLOW_PRODUCTION` | `deploy` | Must be `1` to pass the production human gate; it replaces neither human approval nor external-release authorization. |
| `FORGE_QUALITY_EVALUATOR` / `FORGE_QUALITY_ATTESTATION` / `FORGE_QUALITY_EVALUATOR_ARGS` / `FORGE_QUALITY_EVALUATOR_EXECUTABLE` | `deploy`, `assets check`, `quality` | Release-candidate evaluator identity, attestation path and invocation. |
| `IMAGE_GEN_URL` / `TRELLIS_URL` / `ELEVENLABS_API_KEY` | `forge gen image\|mesh\|sfx` | Licensed provider endpoints and keys; a missing variable is reported before any network call. |
| `FORGE_LOCAL_DB` / `FORGE_LOCAL_TOKEN` / `FORGE_LOCAL_NAMESPACE` / `FORGE_LOCAL_PORT` | local host | Local server binding; the token is runtime-only and never shipped. |

`.env.example` lists these names with empty values; copy it to `.env.local` (Git-ignored)
for a local workflow. Internal QA and quality harness knobs (`FORGE_QA_*`,
`FORGE_QUALITY_AV_*`, `FORGE_CAPACITY_DRIVER`) are read by their own modules.
