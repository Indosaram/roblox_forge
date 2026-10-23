# AGENTS.md — Roblox Game Forge

## Purpose

Roblox Game Forge is a meta-framework for AI-agent-driven planning, building, and operating Roblox games of any genre. It separates reusable engine-agnostic core packages, genre modules, and per-game packs so a new game is mostly configuration plus hook code. The first game pack is **Kaiju Egg Raiders**, a monetizable viral game in the `collect-raid` genre.

## Hard rules

- Never show anything on the Windows foreground.
- Ask the user before launching Roblox Studio.
- Never manipulate the GUI directly (click, key input, window move, focus change); do GUI work only through product APIs such as Studio MCP.
- Never auto-submit login credentials.
- Confirm with the user before any paid action (for example group creation cost).
- Git is the single source of code: Studio MCP `multi_edit` is forbidden; the flow is disk edit -> lint -> Git -> Rojo sync.
- Do not use non-commercial generative models: AudioCraft weights (CC-BY-NC), Roblox Cube (research only), Hunyuan3D-2 (excludes Korea, EU, UK). TRELLIS (MIT) is allowed.
- No paid random items: Robux sells only deterministic items, and random hatching runs only on free currency.
- No 1:1 personal-base theft structure and no "Steal a ..." title pattern; design around team siege instead.
- Never hand-edit generated files: `EconConfig.luau`, `GenreConfig.luau`, `Assets.luau`, `ProcAssets.luau` (and `SurvivalContent.luau`). Edit the source (`econ.yml`, `assets/manifest.yml`, `content.yml`) and run the codegen (`forge codegen`, `forge assets codegen`, `forge gen procedural`, `forge content codegen`).
- All randomness goes through `core/domain/random/Rng` with a recorded seed (`Rng.new(seed)`, `:fork(label)`); never call `math.random` or `os.time` for game logic.
- Domain code takes time as a parameter (explicit clock); it never reads wall-clock time itself.
- Run every command from the repository root: rokit resolves `rokit.toml` from the current directory.
- Never create files named `nul` (Windows reserved name; it is gitignored).

## Layer rules (plan §11.1)

- **Core** — everything common to all games: data storage, economy engine, monetization, analytics, localization, liveops, asset/deploy pipeline, agent skills. Internally split into `core/domain` (engine-free pure Luau: economy, progression, state — runnable under Lune) and `core/infra` (engine adapters: DataStore, networking, Instances).
- **Genre Module** — reusable per-genre loop rules, standard events, QA scenario templates, economy templates. Shared by many games.
- **Game Pack** — per-game `game.yml`, design docs, `econ.yml`, assets, product lists, and game-specific Luau extensions in `src/`.
- Game packs never copy or modify core or genre code; they only register hooks (e.g. `OnHarvest`, `OnWaveSpawn`). New capabilities are added upward as config options or hooks.
- `core` and `genres` are semver-versioned packages; each game pack pins versions in its own lockfile.
- Agent auto-deploys go to staging only. Production deploys, price/probability changes, and core/genre changes require a human-merged PR (core/genre PRs must pass every game pack's tests).

## Commands

`forge` below means `lune run cli/forge`. `lune run cli/forge --help` (or `-h`, `help`) prints usage to stdout and exits 0; `lune run cli/forge <cmd> --help` prints that command's usage and exits 0. No arguments prints usage to stderr and exits 2; an unknown command exits 2. Every other command exits 1 on failure.

- `rokit install` — install the pinned toolchain from `rokit.toml`, then run `lune setup` once. `bun` is also needed for the JS suites, deploy/liveops transport and Studio QA.
- `forge check` — full verification: genre-contract, qa-schema, selene, stylua, luau-lsp, econ, game, assets, locale, provenance, lock, specs, build (the `build` stage runs `rojo build` plus built-place inspection for **every** eligible game pack, each target reported independently). `--pack <slug>`, `--project <path>` and `--all` narrow only build + inspect.
- `forge build [--all | --pack <slug> | --project <path>]` — build places into `build/<target>.rbxl`; with no selector the default pack is built.
- `forge codegen [<pack>]`, `forge new <slug> --genre <g1,g2>`, `forge plan`, `forge gen`, `forge assets`, `forge locale`, `forge deploy`, `forge liveops`, `forge report`, `forge trends`, `forge quality`, `forge spec`, `forge content`: see `lune run cli/forge <cmd> --help`.
- `stylua .` — format the repository.

## Fast loop

Do not run the full gate for every edit. Iterate with the narrowest command that covers the change, batch independent changes, and run `forge gate` once per batch before committing.

0. `forge gate [--pack <slug>] --json <path>` — the one pre-commit gate: `check` without specs/build first (lint, types, econ/assets/content drift fail in seconds), then concurrently the sharded specs, every native qa scenario of the pack recorded and replayed, `build --all` and `smoke --local`. Ends with `gate: PASS|FAIL|INVALID`. INVALID means a tracked or untracked source file changed during the run: never edit the tree (or merge worker patches) while a gate runs. Do not hand-write .cmd batches of check + scenarios.

1. `lune setup` once after `rokit install` (generates Luau type definitions).
2. `forge test <substring> [more filters] --quiet` — run only the Lune specs whose path matches a substring. Also `--slowest N` (slowest specs), `--json <path>` (machine-readable result) and `--jobs N|auto` (worker processes; default auto = cores - 1, `--jobs 1` runs in-process). A full unfiltered run records per-test durations in `build/cache/spec-timings.json`, which later runs use to balance shards. `specs-run` remains a hidden alias.
   After editing `content.yml`, `econ.yml` or `assets/manifest.yml`, run the matching codegen before any gate; `forge check --only econ,assets` catches a stale generated file in seconds.
3. `forge check --only <stages>` (comma-separated) or `forge check --skip <stages>`; stage ids: `genre-contract,qa-schema,selene,stylua,luau-lsp,econ,game,assets,locale,provenance,lock,specs,build`. Each stage prints its seconds and the run ends with `check: PASS ...` or `check: FAIL stages=...`.
4. `forge check --json <path>` — writes `{schemaVersion: 1, ok, stages, failed}`; `failed` is a list of stage ids.
5. Reproduce QA deterministically: `forge qa run --pack <slug> --scenario <name> --record <journal.json>`, then `forge replay <journal.json> [--json]` (exit 0 MATCH, 1 MISMATCH, 2 error). Native scenarios take `seed: <int>`; `capture` steps take `layers: all|world|ui`.
6. Compare screenshots with `forge imagediff <base.png> <compare.png> [--diff out.png] [--threshold n] [--ignore x1:y1-x2:y2[,..]] [--crop x:y:w:h] [--json]` (exit 0 identical, 1 different, 2 usage or decode error).
7. Other machine-readable runs: `forge smoke --local --strict`, `forge econ sim --json <path>`, `forge sweep --stamp <text>` (writes `sweep.json`, schemaVersion 1).

Evidence and output go to gitignored directories, so never commit them: `.omo/evidence/`, `reports/`, `build/`, `build/sweep/<stamp>/`.

## Docs

- [skills/](skills/README.md) — per-layer agent skills (3d, audio, locale, econ, qa, liveops).
- [cli/forge/README.md](cli/forge/README.md) — CLI behavior and genre-contract command semantics.
- [genres/README.md](genres/README.md) — genre module extension guide and APIs.
- [docs/release/cli-contract.md](docs/release/cli-contract.md) — CLI exit-code and output contract.
- [docs/forge/genre-spec.md](docs/forge/genre-spec.md) — declarative genre-spec format.

## Repository map

```
roblox_forge/
  AGENTS.md                    # agent rules, layer rules, approval gates
  .gitignore  .gitattributes
  docs/                        # release/ (operations, contracts), forge/ (genre-spec), research/, review/
  cli/
    forge/                     # Lune CLI
      commands/                # one file per command (+ command specs)
      lib/                     # shared libraries and their *.spec.luau
      qa/                      # Studio QA drivers (mjs)
      fixtures/                # spec and proof fixtures
    release/                   # release packaging, capacity, persistence readiness
  core/                        # packages common to every game
    domain/                    # engine-free pure Luau
      command/  crafting/  economy/  genre/  inventory/  procgen/
      progression/  random/  settlement/  state/  survival/
    infra/                     # engine adapters
      analytics/  audio/  camera/  data/  genre/  liveops/
      localization/  monetization/  net/  render/
    anticheat/
    ui-kit/
  genres/
    collect-raid/  grow-harvest/  survival-coop/
    rpg-progression/  social-rp-fashion/  pvp-arena/
      module/  qa-scenarios/  econ-template.yml  design-template.md
  games/
    kaiju-egg-raiders/         # first game pack (collect-raid)
      game.yml  design/  econ.yml  src/  assets/  locale/  deploy.yml
    grow-and-defend-garden/    # second pack (grow-harvest + survival-coop)
    plan-demo/                 # generated sample pack
  skills/                      # per-layer agent skills: 3d, audio, locale, econ, qa, liveops
  reports/                     # generated output (gitignored)
  .github/workflows/           # CI (lint, specs, rojo build)
```
