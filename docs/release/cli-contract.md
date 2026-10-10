# CLI Contract Reference

This document provides the authoritative contract for every command, argument, schema, environment variable, exit code, and boundary condition in Roblox Game Forge.

All commands are invoked via Lune from the repository root:
```powershell
lune run cli/forge <command> [subcommand] [arguments...]
```

## Exit Code Contract

- `0`: Success. The operation completed and all invariants hold.
- `1`: Failure. A validation error occurred, an invariant failed, a required tool was missing, or invalid arguments were passed.
- Standard error (`stderr`) receives error details and validation reports. Standard output (`stdout`) receives operation summaries and formatted previews.

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
lune run cli/forge check [--pack <slug> | --project <path> | --all] [--packs-root <dir>]
```

- **Arguments**:
  - `--pack <slug>`: Check and build only the specified game pack.
  - `--project <path>`: Build and inspect a specific project file (e.g. `games/kaiju-egg-raiders/default.project.json`).
  - `--all`: Discover, build, and inspect every pack under `games/`.
  - `--packs-root <dir>`: Temporary root override for QA build matrices.
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
  10. `[lock]`: Confirms `forge-lock.yml` version pins match `core` and `genres` packages.
  11. `[specs]`: Runs all unit specs across `core/`, `cli/`, `genres/`, and `games/` via `specs-run`.
  12. `[build]`: Compiles project files to `build/<pack>.rbxl` using Rojo.
  13. `[inspect]`: Inspects `.rbxl` binaries for required instances, entry scripts, and clean require graphs.
- **Errors**: Nonzero exit code if any stage fails. One failing pack never hides errors in another pack.

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
lune run cli/forge new <slug> --genre <g1,g2>
```

- **Arguments**:
  - `<slug>`: Lowercase-kebab name for the pack (e.g. `dungeon-crawl`). Must match `^[a-z][a-z0-9%-]*$`.
  - `--genre <g1,g2>`: Comma-separated list of genre package names. Singles or recognized compound recipes (e.g. `grow-harvest,survival-coop`) are supported.
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
lune run cli/forge econ sim [--pack <slug>] [--players N] [--days D] [--seed S] [--out <path>]
```

- **Arguments**:
  - `--pack <slug>`: Target pack (default: `kaiju-egg-raiders`).
  - `--players N`: Simulated player count (default: 20; must be >= 1).
  - `--days D`: Simulation horizon in virtual days (default: 7; must be >= 1).
  - `--seed S`: Stable PRNG seed (default: 1).
  - `--out <path>`: Output markdown report path (default: `reports/econ-sim-<pack>.md`).

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
lune run cli/forge assets upload-audio [--pack <slug> | --pack-dir <dir>] [--creator-group <id>] [--cache <path>] [--dry-run]
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
  - Creates each `sfx`/`bgm` cue through the Open Cloud Assets API (creator = `--creator-group`, default the staging group), polls the operation, and records the returned `rbxassetid` plus moderation state in `assets/manifest.yml`.
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
lune run cli/forge smoke [--pack <slug>] [--local] [--cloud] [--fixture <save.json>] [--dry-run]
```

- `--local` (default): Executes `games/<pack>/smoke/smoke.luau` under Lune. Tests DataStore serialization, profile migrations, and economy math.
- `--cloud`: Posts Luau Execution session task to Roblox Open Cloud.
  - `--dry-run`: Prints the bundled task payload offline.
  - Live mode: Requires `ROBLOX_API_KEY`. Dispatches task and polls until complete.

---

### `qa`

Runs declarative, multi-actor gameplay scenarios.

```powershell
lune run cli/forge qa plan [--pack <slug>]
lune run cli/forge qa validate
lune run cli/forge qa run --pack <slug> --scenario <name> [--native|--studio] [--evidence <path>]
```

- `qa plan`: Validates scenario declarations against pack monetization and writes `reports/qa-plan-<pack>.md`.
- `qa validate`: Verifies all `genres/*/qa-scenarios/*.yml` scenario definitions against declarative schemas.
- `qa run`:
  - `--native` (default): Runs scenario inside headless Luau environment driving real `Session` and `Executor` modules using a stepped virtual clock and explicit commit barriers.
  - `--studio`: Drives scenario through a live Roblox Studio client using Studio MCP.
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
lune run cli/forge deploy --env <staging|production> [--pack <slug>] [--dry-run] [--out <path>] [--development]
lune run cli/forge deploy plan --env <staging|production> [--pack <slug>] [--out <path>] [--development]
```

- Flags:
  - `--env <staging|production>`: Target environment defined in `deploy.yml`.
  - `--pack <slug>`: Defaults to `kaiju-egg-raiders` except development requires an explicitly named pack.
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

## Unimplemented Boundaries Summary

For operational clarity, the following boundaries are deliberately not implemented in the CLI and are gated or planned offline:

1. **Locale Live Upload**: `lune run cli/forge locale sync` without `--dry-run` is refused. Use `--dry-run` to generate payloads for manual import.
2. **Product / Gamepass Live Creation**: `lune run cli/forge deploy` publishes the `.rbxl` place binary to Open Cloud. Creating developer products and gamepasses must be done through Creator Hub or planned with `deploy --dry-run`.
3. **Non-Windows Studio MCP Automation**: Interactive Studio testing targets Windows only. Linux/macOS runs are restricted to headless commands and remain unclaimed until exercised.
4. **Third-Party AI Generation Fallbacks**: If external generation API keys are missing, commands fail with explicit errors rather than falling back to unapproved providers or mock outputs.
