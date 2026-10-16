# CLI Contract Reference

This document provides the authoritative contract for every command, argument, schema, environment variable, exit code, and boundary condition in Roblox Game Forge.

All commands are invoked via Lune from the repository root:
```powershell
lune run cli/forge <command> [subcommand] [arguments...]
```

## Exit Code Contract

| Code | Meaning |
| --- | --- |
| `0` | Success. The operation completed and all invariants hold. `--help`, `-h` and `help` also exit 0. |
| `1` | Failure. A validation error occurred, an invariant failed, a required tool was missing, or a subcommand received invalid arguments. This is the exit code of every command not listed below. |
| `2` | Usage error at the entry point: no arguments, or an unknown command (usage is printed to `stderr`). |

Three commands carry a more specific contract:

| Command | `0` | `1` | `2` |
| --- | --- | --- | --- |
| `imagediff` | images identical | images differ | usage error, unreadable file or PNG decode error |
| `replay` | journal replays to the recorded state (`MATCH`) | replay diverges (`MISMATCH`) | usage error, unreadable file or invalid journal |
| (entry point) | `--help` / `-h` / `help` | any other command failure | no arguments, unknown command |

- `lune run cli/forge --help` (or `-h`, `help`) prints the command list to `stdout` and exits 0. `lune run cli/forge <command> --help` prints that command's usage to `stdout` and exits 0. With no arguments the usage goes to `stderr` and the exit code is 2.
- Standard error (`stderr`) receives error details and validation reports. Standard output (`stdout`) receives operation summaries and formatted previews.
- Run `lune setup` once after installing the toolchain with Rokit. `bun` is required for the JavaScript suites, the deploy/liveops transport and Studio QA.
- Generated evidence and output directories are gitignored: `.omo/evidence/`, `reports/`, `build/`, and `build/sweep/<stamp>/`.

Prerequisite admission uses exact versions from `rokit.toml`, before generation
recovery/staging, build output deletion/overlay creation, or check pipeline writes.
`FORGE_TOOL_UNAVAILABLE` identifies an unsuccessful required version probe;
`FORGE_TOOL_UNSUPPORTED` identifies a mismatched or unparseable version;
`FORGE_RUNTIME_UNSUPPORTED` identifies the running Lune mismatch;
`FORGE_TOOLCHAIN_INVALID` identifies a missing or malformed shipped pin.
These failures return nonzero with installation guidance, without forwarding raw
tool output. Build reports its failure through its existing output summary.
Runtime admission precedes command module imports. Auxiliary Node/Bun/PowerShell
runtimes are not global prerequisites for scaffold, build, or check.

---

## Command Reference

### `check`

Runs the complete repository verification pipeline in sequential stages.

```powershell
lune run cli/forge check [--pack <slug> | --project <path> | --all] [--packs-root <dir>] [--only <stages>] [--skip <stages>] [--json <path>]
```

- **Arguments**:
  - `--pack <slug>`: Narrow the `build` stage (and its inspection) to the specified game pack. Every other stage still runs against the whole repository.
  - `--project <path>`: Narrow `build` and inspection to a specific project file (e.g. `games/kaiju-egg-raiders/default.project.json`).
  - `--all`: Build and inspect every pack under `games/` (the default when no selector is given).
  - `--packs-root <dir>`: Temporary root override for the `build` stage's discovery, used by QA build matrices.
  - `--only <stages>`: Comma-separated stage ids; run only these stages.
  - `--skip <stages>`: Comma-separated stage ids; run every stage except these.
  - `--json <path>`: Write the machine-readable report (see [JSON Schemas](#json-schemas)).
  - Stage ids: `genre-contract`, `qa-schema`, `selene`, `stylua`, `luau-lsp`, `econ`, `game`, `assets`, `locale`, `provenance`, `lock`, `specs`, `build`. An unknown id, a duplicate flag, or a flag without a value is a usage failure that lists the valid ids.
  - `--pack`, `--project`, `--all` and `--packs-root` narrow only `build` and its inspection; they never narrow the other stages.
- **Output**: each stage prints `[<stage>] PASS|FAIL (<seconds> s)` (tool detail appears only on FAIL), and the run ends with one summary line: `check: PASS (<n> stages, <seconds> s)` or `check: FAIL stages=<id,id> (<seconds> s)`.
- **Pipeline Execution Stages**:
  1. `[genre-contract]`: Discovers all packages in `genres/` and validates `forge-package.yml` compatibility.
  2. `[qa-schema]`: Validates all scenario YAML files against contract schemas.
  3. `[selene]`: Lints code against `selene.toml`.
  4. `[stylua]`: Checks code formatting with `stylua --check .`.
  5. `[luau-lsp]`: Analyzes project types with strict settings using `build/cache/globalTypes.d.luau`. If the definition file is not cached, downloads it from GitHub (`https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.70.1/scripts/globalTypes.d.luau`) and validates SHA-256 `2857efa8245485f8c25c19c018ee1ef9b46afab4efd2ea70fc3257cd3faf7080`.
  6. `[econ]`: Validates that `EconConfig.luau` or `GenreConfig.luau` matches `econ.yml`.
  7. `[game]`: Validates `game.yml` structure and ensures no placeholder TBD values remain.
  8. `[assets]`: Checks asset licenses against allow-lists and verifies `Assets.luau` does not drift.
  9. `[locale]`: Verifies client literals have translations in `locale/strings.csv`.
  10. `[provenance]`: Runs the release provenance gate (QA-PROV-01/QA-NAME-01) for every pack with `provenance/policy.yml`; packs without a policy are skipped. See [`provenance`](#provenance).
  11. `[lock]`: Confirms `forge-lock.yml` version pins match `core` and `genres` packages.
  12. `[specs]`: Runs all unit specs across `core/`, `cli/`, `genres/`, and `games/` in a child process (the same runner as `test`).
  13. `[build]`: Compiles project files to `build/<pack>.rbxl` using Rojo, then inspects each `.rbxl` binary for required instances, entry scripts, and clean require graphs. A failed build is never inspected.
- **Errors**: Exit 1 if any stage fails. One failing pack never hides errors in another pack.

---

### `build`

Compiles project definitions into binary Roblox place files (`.rbxl`).

```powershell
lune run cli/forge build [--all | --pack <slug> | --project <path>] [--packs-root <dir>]
```

- **Arguments**:
  - With no arguments, builds default pack `kaiju-egg-raiders` to `build/kaiju-egg-raiders.rbxl`.
  - `--all`: Compiles every discoverable pack in `games/` to `build/<slug>.rbxl`.
  - `--pack <slug>`: Compiles specified pack to `build/<slug>.rbxl`.
  - `--project <path>`: Compiles specified project file to `build/project-<slug>-<tag>.rbxl`.
  - `--packs-root <dir>`: Sets custom discovery root; writes to `build/packs-<root>-<tag>/<slug>.rbxl`.
- **Output**:
  - Binary place file at the resolved output path.
  - Summary logs showing Rojo build status and place inspection results.

---

### `inspect`

Internal place file inspection tool.

```powershell
lune run cli/forge inspect <path.rbxl> [--project <project.json>]
```

- **Behavior**: Reads the binary `.rbxl` file, checks for required service hierarchy, verifies ModuleScript requires resolve without circular leaks or spec module contamination, and confirms all script entrypoints exist.

---

### `new`

Scaffolds a new game pack directory from genre templates and runs initial codegen.

```powershell
lune run cli/forge new <slug> --genre <g1,g2> [--mode crafting]
```

- **Arguments**:
  - `<slug>`: Lowercase-kebab name for the pack (e.g. `dungeon-crawl`). Must match `^[a-z][a-z0-9%-]*$`.
  - `--genre <g1,g2>`: Comma-separated list of genre package names. Singles or recognized compound recipes (e.g. `grow-harvest,survival-coop`) are supported.
  - `--mode crafting`: Selects the crafting runtime variant. It is valid only with `--genre survival-coop` alone and may be given once; any other combination exits 1.
- **Outputs Created**:
  - `games/<slug>/game.yml`
  - `games/<slug>/econ.yml`
  - `games/<slug>/deploy.yml`
  - `games/<slug>/forge-lock.yml`
  - `games/<slug>/default.project.json`
  - `games/<slug>/assets/manifest.yml`
  - `games/<slug>/src/shared/EconConfig.luau` or `GenreConfig.luau`

---

### `plan`

Generates a complete starter game pack deterministically from a concept string without external LLM calls or network requests.

```powershell
lune run cli/forge plan --concept "<text>" --genre <genre> --pack <slug> [--seed N] [--title "<text>"] [--teams A,B,...] [--debug-name <name>] [--gui-name <name>] [--force]
```

- **Arguments**:
  - `--concept "<text>"`: One-line game concept (required).
  - `--genre <genre>`: Genre module under `genres/` (required, e.g. `collect-raid`).
  - `--pack <slug>`: New pack directory under `games/` (required, lowercase-kebab).
  - `--seed N`: Integer random seed for procedural balance (default: 0).
  - `--title "<text>"`: Override derived title.
  - `--teams A,B,...`: Comma-separated team names (default: `Red,Blue`).
  - `--debug-name <name>`: Debug menu binding name (default: `<Pascal>Debug`).
  - `--gui-name <name>`: ScreenGui name (default: `<Pascal>Gui`).
  - `--force`: Overwrite existing files if destination directory already exists.
- **Invariants**: Given identical concept, genre, and seed, the command always produces byte-identical files. Writes starter output; generation does not grant quality or release approval.

---

### `codegen`

Regenerates Luau configuration modules from YAML declarations.

```powershell
lune run cli/forge codegen [<pack>]
```

- **Arguments**:
  - `<pack>`: Optional target pack slug (default: `kaiju-egg-raiders`).
- **Behavior**: Inspects `games/<pack>/econ.yml`. For API 1 genre contracts, writes `src/shared/GenreConfig.luau`. For legacy configs, writes `src/shared/EconConfig.luau`.

---

### `econ sim`

Runs an offline Monte Carlo simulation of a pack's free-currency progression and monetization balance.

```powershell
lune run cli/forge econ sim [--pack <slug>] [--players N] [--days D] [--seed S] [--out <path>] [--json <path>]
```

- **Arguments**:
  - `--pack <slug>`: Target pack (default: `kaiju-egg-raiders`).
  - `--players N`: Simulated player count (default: 20; must be >= 1).
  - `--days D`: Simulation horizon in virtual days (default: 7; must be >= 1).
  - `--seed S`: Stable PRNG seed (default: 1).
  - `--out <path>`: Output markdown report path (default: `reports/econ-sim-<pack>.md`).
  - `--json <path>`: Also write the machine-readable result (see [JSON Schemas](#json-schemas)). The markdown report is still written.

---

### `gen`

Generates assets through procedural math engines or external AI providers.

#### Subcommand: `gen procedural`
```powershell
lune run cli/forge gen procedural [--pack <slug>] [--obj] [--preview]
```
- Fully offline. Reads `games/<pack>/assets/procgen.yml`, runs pure Luau mesh algorithms, writes `src/shared/ProcAssets.luau`, and registers entries in `assets/manifest.yml`.
- `--preview`: Generates software-rasterized PPM images under `assets/preview/`.

#### Subcommand: `gen icons`
```powershell
lune run cli/forge gen icons [--pack <slug>]
```
- Fully offline. Renders 128x128 PPM icons for procedural creatures and eggs into `assets/icons/`.

#### Subcommand: `gen launchart`
```powershell
lune run cli/forge gen launchart [--pack <slug>]
```
- Fully offline. Renders two 512x512 icons and two 1920x1080 thumbnails as deterministic PNGs into `assets/icon/` and `assets/thumbnails/`.

#### Subcommand: `gen audio`
```powershell
lune run cli/forge gen audio [--pack <slug>] [--install]
```
- Fully offline. Synthesises WAV waveforms (16-bit PCM mono) from `assets/audio.yml` cues using pure Luau DSP synth and composer.
- `--install`: Copies generated WAV files to the local Roblox Studio content directory under `content/forge/<pack>/` so that `rbxasset://forge/<pack>/<cue>.wav` URLs resolve during Studio runs.

#### Subcommand: `gen <image|mesh|sfx>`
```powershell
lune run cli/forge gen <image|mesh|sfx> --key <assetKey> --prompt "<text>" [--pack <slug>] [--dry-run]
```
- External AI asset generation:
  - `image`: Routes to Studio MCP (`IMAGE_GEN_URL`), produces PNG.
  - `mesh`: Routes to Trellis (`TRELLIS_URL`), produces GLB.
  - `sfx`: Routes to ElevenLabs (`ELEVENLABS_API_KEY`), produces MP3.
- `--dry-run`: Prints planned request method, URL, headers, and body without making network calls.
- Missing credentials without `--dry-run` trigger immediate failure: `missing env <NAME>`.

#### Subcommand: `gen fulfill`
```powershell
lune run cli/forge gen fulfill <requestFile> --key <assetKey> [--asset-id <n>]
```
- Appends completed generation request records to `assets/manifest.yml`.

---

### `assets`

Manages asset manifest gating, Luau code bindings, moderation status, and audio publishing.

```powershell
lune run cli/forge assets check [--pack <slug>] [--env staging|production] [--manifest <path>]
lune run cli/forge assets codegen [--pack <slug>]
lune run cli/forge assets status [--pack <slug>]
lune run cli/forge assets upload-audio [--pack <slug> | --pack-dir <dir>] [--creator-group <id> | --creator-user <id>] [--cache <path>] [--dry-run]
```

- `assets check`:
  - Enforces license allow-list (`cli/forge/lib/licenses.luau`).
  - Blocks forbidden generator models (AudioCraft, Roblox Cube, Hunyuan3D-2).
  - In `production`, requires moderation `Approved` and `assetId > 0`.
- `assets codegen`:
  - Generates `src/shared/Assets.luau` mapping asset keys to `rbxassetid://<id>` strings.
  - Writes `asphalt.toml` for supported formats.
- `assets status`:
  - Requires `ROBLOX_API_KEY`.
  - Queries Open Cloud Assets API for moderation updates on uploaded assets.
- `assets upload-audio`:
  - Requires `ROBLOX_API_KEY` with the `asset:write` scope; a key without it stops the command and prints the exact API error.
  - Creates each `sfx`/`bgm` cue through the Open Cloud Assets API (creator = `--creator-group <id>` or `--creator-user <id>`, else `FORGE_ROBLOX_CREATOR_GROUP_ID` / `FORGE_ROBLOX_CREATOR_USER_ID`; exactly one creator may be given, there is no default creator, and a missing creator is refused with exit 1 before any request), polls the operation, and records the returned `rbxassetid` plus moderation state in `assets/manifest.yml`.
  - Idempotent by artifact sha256 via `build/audio-upload-cache.json`; `--dry-run` makes no network call.
  - Reports pending moderation separately and never treats it as playable.

---

### `content`

Validates and generates code for survival and crafting content catalogs.

```powershell
lune run cli/forge content check --file <path>
lune run cli/forge content codegen --pack <slug>
```

- `content check`: Validates schema integrity, recipe circular dependencies, inventory caps, node definitions, and fixed-point quantities.
- `content codegen`: Compiles `games/<pack>/content.yml` into `games/<pack>/src/shared/SurvivalContent.luau`.

---

### `provenance`

Release provenance gate for packs that opted in with `games/<pack>/provenance/policy.yml` (plan §9.5, ADR-06).

```powershell
lune run cli/forge provenance check --pack <slug> [--packs-root <dir>] [--json <path>]
lune run cli/forge provenance fingerprint --corpus <dir> --set <id> --out <dir>
lune run cli/forge provenance fingerprint --names <file> --salt <salt>
```

- **Output**: PASS prints `provenance: PASS <pack> (<s> strings, <e> entries, <a> assets, sets=<ids>)` to stdout. FAIL prints one finding per line to stderr as `<pack>: <file>:<locator>: <RULE> <detail>`, then `provenance: FAIL <pack> (<k> findings)`. Matched banned words and reference grams are never printed in plain text (a list index or hash is printed instead).
- **Rule ids**: `PROV-POLICY`, `PROV-FP`, `PROV-MISSING`, `PROV-STALE`, `PROV-FIELD`, `PROV-NGRAM`, `NAME-TERM`, `NAME-STEM`, `NAME-LETTER`, `NAME-HASHED`, `NAME-ENCODING`, `ASSET-TOOL`, `ASSET-PROV`.
- **JSON**: `--json` writes `{schemaVersion: 1, ok, pack, findings: [{rule, file, locator, detail}]}` (`[]` when empty).
- **Fingerprint sets**: `provenance/fingerprints/<id>.fp` + `<id>.meta.yml`, or a one-line `<id>.path` naming the directory that holds them (used for sets kept outside the pack or outside Git).
- **Exit codes**: 0 PASS; 1 FAIL, argument error, missing policy for the named pack, or parse error. 2 is not used.

### `locale`

Localization management and validation.

```powershell
lune run cli/forge locale check [--pack <slug>]
lune run cli/forge locale sync [--pack <slug>] [--dry-run]
```

- `locale check`: Scans client Luau code for string literals and validates coverage in `locale/strings.csv`. Confirms no empty translations exist for required locales (e.g. `ko-kr`).
- `locale sync`:
  - Reads `locale/strings.csv` and builds localization table payloads.
  - In `--dry-run` mode, outputs JSON structure to `reports/locale-sync-<pack>.json`.
  - **Boundary condition**: Live upload of localization tables is deliberately unimplemented. Running without `--dry-run` exits 1 with message: `locale sync: live upload is not implemented (offline plan only); re-run with --dry-run`.

---

### `trends`

Gathers competitive Roblox metrics and market trends.

```powershell
lune run cli/forge trends [--fixture <path>] [--out <path>]
```

- Fetches top experiences from Roblox Explore API or reads a local JSON file via `--fixture`.
- Analyzes CCU distributions and median gamepass pricing across genres.
- Writes summary markdown to `reports/trends-<YYYY-MM-DD>.md`.

---

### `report`

LiveOps analytics reporting.

```powershell
lune run cli/forge report [--pack <slug>] [--events <path>] [--out <path>]
lune run cli/forge report --all [--out <path>]
```

- Parses JSONL event streams matching `core/infra/analytics/Events.luau`.
- Reports funnel conversion, retention metrics, and Robux spend.
- `--all`: Compiles a multi-game overview report into `reports/dashboard-<YYYY-MM-DD>.md`.

---

### `liveops`

Publishes runtime liveops events to game servers.

```powershell
lune run cli/forge liveops push --pack <slug> --event <id> [--dry-run]
```

- Reads event definition from `games/<pack>/liveops.yml`.
- `--dry-run`: Prints the target URL and JSON metadata `topic`, `messageBytes`, `messageSha256`, not the raw event payload. No credentials or request; unset universe ID 0 is reported without claiming delivery.
- Live mode: Requires `ROBLOX_STAGING_API_KEY` and `ROBLOX_STAGING_UNIVERSE_ID` matching the configured positive integer staging universe ID as an exact decimal string. No `ROBLOX_API_KEY` fallback. Sends broadcast envelope `{v=1, kind, from="forge-cli", data}` to topic `forge-liveops`.
- Equal loaded staging/production keys and overlapping configured universe targets are refused. A POST is attempted once, without automatic retry. Shared sanitized operational result codes are documented under deploy below.

---

### `smoke`

Executes end-to-end smoke tests against game packs.

```powershell
lune run cli/forge smoke [--pack <slug>] [--local] [--cloud] [--fixture <save.json>] [--dry-run] [--strict]
```

- `--local` (default): Executes `games/<pack>/smoke/smoke.luau` under Lune. Tests DataStore serialization, profile migrations, and economy math. A pack with no smoke script is skipped.
  - `--strict`: With `--local`, a pack with no smoke script is a failure (exit 1) instead of a skip.
- `--cloud`: Posts Luau Execution session task to Roblox Open Cloud.
  - `--dry-run`: Prints the bundled task payload offline.
  - Live mode: Requires `ROBLOX_API_KEY`. Dispatches task and polls until complete.

---

### `qa`

Runs declarative, multi-actor gameplay scenarios.

```powershell
lune run cli/forge qa plan [--pack <slug>]
lune run cli/forge qa validate
lune run cli/forge qa run --pack <slug> --scenario <name> [--native|--studio] [--evidence <path>] [--record <journal.json>] [--packs-root <dir>] [--studio-receipt <path>] [--bootstrap-owned]
```

- `qa plan`: Validates scenario declarations against pack monetization and writes `reports/qa-plan-<pack>.md`.
- `qa validate`: Verifies all `genres/*/qa-scenarios/*.yml` scenario definitions against declarative schemas.
- `qa run`:
  - `--native` (default): Runs scenario inside headless Luau environment driving real `Session` and `Executor` modules using a stepped virtual clock and explicit commit barriers. A native scenario may declare `seed: <int>` to seed the roll stream; `seed` is rejected on any other scenario kind.
  - `--studio`: Drives scenario through a live Roblox Studio client using Studio MCP. A `capture` step selects its `layers` as `all`, `world` or `ui`.
  - `--evidence <path>`: Writes the run's evidence JSON.
  - `--record <journal.json>`: Writes the run's command journal (see [JSON Schemas](#json-schemas)); replay it with `replay`.
  - `--packs-root <dir>`: Resolves the pack and its scenarios under this root instead of `games/`.
  - `--studio-receipt <path>`: With `--studio`, the Studio discovery receipt the run is bound to.
  - `--bootstrap-owned`: With `--studio`, requires `--studio-receipt` and `--evidence`; also writes `<evidence>.discovery.json`. See [Studio QA](studio-qa.md).
  - Invariants: A scenario that asserts nothing is rejected. A Studio scenario that cannot reach a client fails immediately without falling back to headless execution.

---

### `quality`

Enforces quality profiles, rubric compliance, and release attestation gates.

```powershell
lune run cli/forge quality validate [--file <path>] [--pack <slug>]
lune run cli/forge quality evaluate --pack <slug> --capture <dir> --reference <path> --out <path> [--observations <path>]
lune run cli/forge quality check --pack <slug> [--target starter|vertical-slice|release-candidate] [--receipt <path>] [--packs-root <dir>]
```

- `quality validate`: Validates schema of `quality.yml` (rubrics, disqualifiers, first-play goals). Does not approve quality.
- `quality evaluate`: Executes external evaluator executable or imports supplied observations to evaluate first-play evidence against rubrics.
  - `--sweep <dir>` selects the evidence-receipt path instead: it records a receipt for a sweep pack from the sweep's own columns, its headless 8-actor load proof and its native QA results. `--captures <visual-run-dir>` and `--av <av-source.json>` attach a Studio capture manifest and an AV source receipt when one exists.
  - An evidence receipt never mints human approval: fun and visual quality stay `human-judgment-pending`, and `releaseApproved` is always `false`.
- `quality check`:
  - Evaluates declared tier against target tier.
  - Target `starter`: Passes without evaluator attestation.
  - Target `release-candidate`: Validates that `FORGE_QUALITY_EVALUATOR` matches receipt, `FORGE_QUALITY_ATTESTATION` verifies receipt digest, and all criteria and goals pass with no disqualifiers.
  - `--evidence <path>` (or `--sweep <dir>`) validates an evidence receipt against the pack's declared tier instead: every column must pass, the receipt must bind the declared profile, and the two human-judgment fields must still say `human-judgment-pending`.

---

### `deploy`

Publishes assessed place bytes to Roblox staging or production. Only explicit development staging builds a place during deployment.

```powershell
lune run cli/forge deploy --env <staging|production> [--pack <slug>] [--pack-dir <dir>] [--dry-run] [--out <path>] [--development]
lune run cli/forge deploy plan --env <staging|production> [--pack <slug>] [--pack-dir <dir>] [--out <path>] [--development]
```

- Flags:
  - `--env <staging|production>`: Target environment defined in `deploy.yml`.
  - `--pack <slug>`: Defaults to `kaiju-egg-raiders` except development requires an explicitly named pack.
  - `--pack-dir <dir>`: Names the pack directory directly (for example a scratch sweep pack) instead of `games/<pack>`.
  - `--dry-run`: Generates a plan offline without an API key, production switch, build, or network call. Local quality authorization still applies.
  - `--out <path>`: With `plan` or `--dry-run`, writes JSON to the given path; otherwise refused. Without `--out`, writes markdown to `reports/deploy-plan-<pack>-<env>.md`. Both forms print the markdown preview.
  - `--development`: Explicit staging-only exception requiring `--pack <slug>`. Refused for production and declared release-candidate profiles. Reports `STAGING_DEVELOPMENT`, never release approval.
  - Duplicate flags, unknown flags (including `--target`), missing values, and invalid pack slugs are refused.
- Release candidate checks:
  - Production and nondevelopment staging, including offline plans, require declared `release-candidate` tier and a current approved schema-2 quality receipt and evaluator attestation. Missing profiles return `LEGACY_UNASSESSED`; normal builds remain available.
  - Missing, malformed, inconclusive, stale, or downgraded quality evidence refuses before report writes, builds, or network requests. The gate binds source/config/assets/build and actual loaded runtime evidence; local hash attestation is not cryptographic signing.
  - Live deployment requires the selected `ROBLOX_STAGING_API_KEY` or `ROBLOX_PRODUCTION_API_KEY`, with no `ROBLOX_API_KEY` fallback. A `deploy.yml` target id is a literal positive finite integer or a `${FORGE_<ENV>_UNIVERSE_ID}` / `${FORGE_<ENV>_PLACE_ID}` reference resolved from the environment when the file loads; an unset reference is refused by name before any network call, never defaulted. `ROBLOX_<ENV>_UNIVERSE_ID` and `ROBLOX_<ENV>_PLACE_ID` must exactly match the resolved target as decimal strings. Equal loaded environment keys and overlapping configured universe/place targets are refused. Live production additionally requires `FORGE_ALLOW_PRODUCTION=1`; the switch does not replace human-merged approval or explicit external-release authorization.
- Artifact behavior:
  - Assessed deployment publishes the existing approved `build/<pack>.rbxl` without rebuilding. Changed artifacts must be built and assessed separately before deployment.
  - Live development staging uses `buildtargets.runTarget` to build and inspect the place and emit its identity sidecar.
  - The final quality check precedes upload; held upload bytes must still match the artifact after that check.
- Plan output includes `quality`, `externalReleaseAuthorized: false`, and `apiVerified: false`. Successful dry-run is not API proof or permission to publish. See [Release authorization](authorization.md).
- Deploy and liveops operational refusals include `CREDENTIAL_MISSING`, `CREDENTIAL_SHARED`, `CREDENTIAL_TARGET_MISMATCH`, and `TARGET_ENVIRONMENT_OVERLAP`. The shared credential adapter also rejects unsupported environments with `CREDENTIAL_TARGET_INVALID`.
- Transport emits sanitized codes: `PUBLISH_PERMISSION_DENIED` (401/403), `PUBLISH_RATE_LIMITED` (429), `PUBLISH_TIMEOUT_AMBIGUOUS` (408/504 or thrown timeout), `PUBLISH_TRANSPORT_AMBIGUOUS`, `PUBLISH_MALFORMED_REPLY`, `PUBLISH_HTTP_ERROR`, or `PUBLISH_ACCEPTED`. No raw provider body/statusMessage or thrown transport text is printed. No POST is automatically retried.
- Result lines include numeric HTTP status when available. Accepted deploy output includes the place version and `artifactSha256`; accepted liveops output includes the message SHA-256 and universe ID. These audit identifiers do not independently prove publication or delivery.
- Accepted place responses require a JSON object with positive integral `versionNumber`; accepted liveops responses require an empty JSON object. These local response contracts do not establish actual delivery. The maintained subprocess adapter uses installed Bun native fetch (30-second abort) and Lune process ownership (35-second kill/reap watchdog). Missing executable/fetch capability refuses with `PUBLISH_TRANSPORT_UNSUPPORTED`; there is no unsafe CLI override. These timings and cleanup are authored, not executed proof. See [Operations](operations.md) and [Rollback](rollback.md).
- **Boundary condition**: Developer product and gamepass creation APIs are not implemented. `deploy --dry-run` plans creations and updates; live deploy publishes place binary versions only.

---

### `sweep`

Baseline playability sweep: generates a fresh pack for every registered genre (plus `survival-coop` in `--mode crafting` as one extra variant) into a scratch packs root outside `games/`, then records each step independently.

```powershell
lune run cli/forge sweep [--genres a,b,...] [--out <dir>] [--stamp <text>]
```

- **Arguments**:
  - `--genres a,b,...`: Sweep only the named genres (`survival-coop` still contributes both of its variants). An empty or duplicate token is a usage failure.
  - `--out <dir>`: Output directory (default `build/sweep/<stamp>/`).
  - `--stamp <text>`: Run stamp used in the default output directory and recorded in `sweep.json` (default: the UTC time `YYYYMMDDTHHMMSSZ`). Letters, digits, `.`, `_` and `-` only.
- **Steps per genre**: `generate`, `files`, `build`, `inspect`, `spec`, `hud`, `world`, `audio`, `nativeQa`, `surface`, `load`, `quality`. One genre failing never stops another.
- **Output**: `sweep.json` (see [JSON Schemas](#json-schemas)) and `sweep.md` in the output directory, plus the scratch packs under `<out>/packs/` (cleared at the start of each run). Exit 1 when any genre is not fully green or the arguments are invalid.

---

### `spec`

Genre specification tooling.

```powershell
lune run cli/forge spec init --genre <id> [--concept "<text>"] [--pack <slug>] [--force]
lune run cli/forge spec validate [--genre <id>]
```

- `spec init`: Writes a draft `genres/<id>/genre-spec.yml` seeded from the genre's `econ-template.yml` and `design-template.md`. The draft is valid but incomplete (`draft: true`); `--force` overwrites an existing spec.
- `spec validate`: Reports every declarative genre-spec violation as `file: reason` (optionally for one `--genre`). A spec that fails any rule fails genre discovery, so every other command that reads the registry refuses to run against it. Exit 1 on any violation.

---

### `test`

Runs the unit specs (`*.spec.luau`) across `core/`, `games/`, `cli/` and `genres/`. `specs-run` remains as a hidden alias.

```powershell
lune run cli/forge test [filters...] [--quiet] [--slowest N] [--json <path>]
```

- **Arguments**:
  - `filters...`: Substring filters; a test runs when any filter occurs in its spec path or in `<spec path> :: <test name>`. No filter runs everything. A filter that matches no test fails.
  - `--quiet`: Do not print a line for each passing test; failures are always printed.
  - `--slowest N`: Print the N slowest tests (`SLOW <ms> ms <spec> :: <test>`) before the summary.
  - `--json <path>`: Write the machine-readable result (see [JSON Schemas](#json-schemas)).
- **Output**: a final `specs: <passed> passed, <failed> failed, <files> files, <seconds> s` line. Exit 0 only when at least one test ran and none failed; otherwise 1.

---

### `replay`

Replays a recorded command journal (written by `qa run --record`) and compares the resulting state with the recorded state.

```powershell
lune run cli/forge replay <journal.json> [--json]
```

- **Exit codes**: `0` `MATCH`, `1` `MISMATCH`, `2` usage error, unreadable file or invalid journal (unsupported `schemaVersion`, hash mismatch, malformed body).
- `--json`: Prints the verdict as one JSON object instead of text.
- The journal format is described under [JSON Schemas](#json-schemas).

---

### `imagediff`

Compares two PNG screenshots pixel by pixel.

```powershell
lune run cli/forge imagediff <base.png> <compare.png> [--diff <out.png>] [--threshold n] [--ignore x1:y1-x2:y2[,..]] [--crop x:y:w:h] [--json]
```

- **Arguments**:
  - `--diff <out.png>`: Write a diff image.
  - `--threshold n`: Per-pixel tolerance, a number from 0 to 1.
  - `--ignore x1:y1-x2:y2[,..]`: Rectangles (inclusive pixel bounds, `x2 >= x1`, `y2 >= y1`) excluded from the comparison.
  - `--crop x:y:w:h`: Compare only this region (`w` and `h` at least 1).
  - `--json`: Print one JSON object instead of text (see [JSON Schemas](#json-schemas)).
  - A repeated flag, an unknown flag, or a count of positional arguments other than two is a usage error.
- **Output**: `imagediff: identical`, or `imagediff: <n> different pixels (<p>%) bbox=x1,y1,x2,y2` (with `size WxH vs WxH` appended when the sizes differ).
- **Exit codes**: `0` identical, `1` different, `2` usage error, unreadable file, PNG decode error or an unwritable `--diff` path.

---

## JSON Schemas

Every machine-readable document carries `"schemaVersion": 1`. A consumer must reject a different version.

### `check --json`

```json
{
  "schemaVersion": 1,
  "ok": false,
  "stages": [{ "id": "selene", "ok": true, "skipped": false, "ms": 1234.5 }],
  "failed": ["stylua"]
}
```

- `stages`: one entry per stage id in pipeline order. A stage not selected by `--only`/`--skip` has `skipped: true`, `ok: true`, `ms: 0`. `ms` is wall time in milliseconds.
- `failed`: the ids of failed stages, always a list (`[]` when none). `ok` is `true` exactly when `failed` is empty.

### `test --json`

```json
{
  "schemaVersion": 1,
  "passed": 10,
  "failed": 1,
  "files": 3,
  "durationMs": 842.1,
  "failures": [{ "file": "core/x.spec", "test": "name", "error": "message" }],
  "tests": [{ "file": "core/x.spec", "test": "name", "ok": true, "ms": 1.2 }]
}
```

### `econ sim --json`

Legacy-economy packs (`mode: "legacy"`):

```json
{
  "schemaVersion": 1, "pack": "kaiju-egg-raiders", "seed": 1, "players": 20, "days": 7,
  "mode": "legacy", "startingSupply": 0,
  "series": [{ "day": 1, "supply": 0, "inflationPercent": 0 }],
  "totalProduced": 0, "totalSpent": 0,
  "monetization": [{ "kind": "gamepasses", "name": "VIP Slots +4", "price": 699 }]
}
```

Genre-contract packs (`mode: "genre"`) carry `schemaVersion`, `pack`, `seed`, `players`, `days`, `mode` and `rows`, one row per genre sorted by id:

```json
{ "genre": "collect-raid", "sources": 0, "sinks": 0, "accepted": 0, "rejected": 0 }
```

### `sweep.json`

```json
{
  "schemaVersion": 1,
  "stamp": "20261015T000000Z",
  "command": "lune run cli/forge sweep",
  "genres": [{
    "genre": "collect-raid", "label": "collect-raid", "slug": "...", "mode": null, "packDir": "...", "ok": true,
    "steps": { "generate": { "ok": true, "durationMs": 12.3 }, "build": { "ok": false, "error": "first error line", "durationMs": 4.5 } }
  }],
  "summary": {
    "total": 1, "passed": 0, "failed": 1,
    "stepNames": ["generate", "files", "build"],
    "stepFailures": { "build": 1 },
    "failures": [{ "genre": "collect-raid", "step": "build", "error": "first error line" }]
  }
}
```

- `mode` is `"crafting"` for the `survival-coop` crafting variant and absent otherwise.
- Every step carries `ok` and `durationMs`; a failing step carries `error`. A step missing from a report counts as a failure. `summary.failures` is sorted by genre, step, then error.

### `imagediff --json`

```json
{
  "schemaVersion": 1, "identical": false, "sameSize": true, "differing": 42, "total": 2073600, "percent": 0.002,
  "bbox": { "x1": 1, "y1": 2, "x2": 3, "y2": 4 },
  "base": { "path": "a.png", "width": 1920, "height": 1080 },
  "compare": { "path": "b.png", "width": 1920, "height": 1080 },
  "diff": "diff.png"
}
```

`bbox` is absent when the images are identical; `diff` is absent without `--diff`.

### Command journal (`qa run --record`, `replay`)

```json
{
  "schemaVersion": 1,
  "hash": "<16 lowercase hex digits>",
  "journal": {
    "meta": { "seed": 1, "genre": "collect-raid", "scenario": "golden-path" },
    "entries": [{ "kind": "command", "actor": "p1", "action": "collect", "args": [], "requestId": "r1", "atMillis": 0 }],
    "stateHash": "<16 lowercase hex digits>"
  }
}
```

- `entries[].kind` is one of `command`, `advance`, `join`, `leave`, `save`, `reload`; `actor`, `action`, `args` and `requestId` are optional; `atMillis` is required. `meta.genre`, `meta.scenario` and `stateHash` are optional.
- `hash` is an FNV-1a 64-bit digest of the journal body. Decoding refuses an unknown `schemaVersion`, an unknown envelope or journal field, and a `hash` that does not match the body.

---

## Unimplemented Boundaries Summary

For operational clarity, the following boundaries are deliberately not implemented in the CLI and are gated or planned offline:

1. **Locale Live Upload**: `lune run cli/forge locale sync` without `--dry-run` is refused. Use `--dry-run` to generate payloads for manual import.
2. **Product / Gamepass Live Creation**: `lune run cli/forge deploy` publishes the `.rbxl` place binary to Open Cloud. Creating developer products and gamepasses must be done through Creator Hub or planned with `deploy --dry-run`.
3. **Non-Windows Studio MCP Automation**: Interactive Studio testing targets Windows only. Linux/macOS runs are restricted to headless commands and remain unclaimed until exercised.
4. **Third-Party AI Generation Fallbacks**: If external generation API keys are missing, commands fail with explicit errors rather than falling back to unapproved providers or mock outputs.
