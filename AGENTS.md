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

## Layer rules (plan §11.1)

- **Core** — everything common to all games: data storage, economy engine, monetization, analytics, localization, liveops, asset/deploy pipeline, agent skills. Internally split into `core/domain` (engine-free pure Luau: economy, progression, state — runnable under Lune) and `core/infra` (engine adapters: DataStore, networking, Instances).
- **Genre Module** — reusable per-genre loop rules, standard events, QA scenario templates, economy templates. Shared by many games.
- **Game Pack** — per-game `game.yml`, design docs, `econ.yml`, assets, product lists, and game-specific Luau extensions in `src/`.
- Game packs never copy or modify core or genre code; they only register hooks (e.g. `OnHarvest`, `OnWaveSpawn`). New capabilities are added upward as config options or hooks.
- `core` and `genres` are semver-versioned packages; each game pack pins versions in its own lockfile.
- Agent auto-deploys go to staging only. Production deploys, price/probability changes, and core/genre changes require a human-merged PR (core/genre PRs must pass every game pack's tests).

## Commands

- `rokit install` — install the pinned toolchain from `rokit.toml`.
- `lune run cli/forge check` — full verification: selene, `stylua --check`, `luau-lsp analyze`, Lune specs, then `rojo build` plus built-place inspection for **every** eligible game pack, each target reported independently. Narrow it with `--pack <slug>`, `--project <path>` or `--all`. Provided by `cli/forge`.
- `lune run cli/forge build [--all | --pack <slug> | --project <path>]` — build game places into `build/<target>.rbxl`; with no selector the default pack is built. Provided by `cli/forge`.
- `stylua .` — format the repository.

## Repository map

```
roblox-game-forge/
  AGENTS.md                    # agent rules, layer rules, approval gates
  .gitignore  .gitattributes
  cli/
    forge/                     # Lune CLI: new, sweep, trends, gen, econ, locale, qa, quality, deploy, report
  core/                        # packages common to every game
    domain/                    # engine-free pure Luau: economy/, progression/, state/
    infra/                     # engine adapters: data/, net/, monetization/, analytics/, localization/, liveops/
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
  .github/workflows/           # CI (lint, specs, rojo build)
```
