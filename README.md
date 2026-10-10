# Roblox Game Forge

Roblox Game Forge ("Forge") is a meta-framework that **generates Roblox games from
declarative genre specs**. A genre is described once as data (loop, economy,
controls, QA scenarios, asset plan); Forge turns that description into a buildable
Roblox place with playable server and client code.

It is a developer tool and a runtime library, not a game.

## Layers

- **core/** — everything common to every game: engine-free domain logic
  (`core/domain`: economy, progression, inventory, settlement, state, procedural
  generation — pure Luau, runnable under Lune) and engine adapters
  (`core/infra`: DataStore, networking, monetization, analytics, localization,
  liveops), plus `core/anticheat` and `core/ui-kit`.
- **genres/** — reusable per-genre packages: the loop module, the genre spec
  (`genre-spec.yml`), the generator, economy and design templates, and QA
  scenarios. Shipped genres: `collect-raid`, `grow-harvest`, `survival-coop`,
  `rpg-progression`, `social-rp-fashion`, `pvp-arena`.
- **games/** — per-game packs (`game.yml`, `econ.yml`, design docs, assets,
  `src/` extensions). A pack configures genres and registers hooks; it never
  copies or edits core or genre code.
- **cli/forge/** — the `forge` command line (Lune), plus release tooling in
  `cli/release/`.

## Status

Honest current state, as of this release:

- **Structure works end to end.** `forge sweep` generates, builds, and inspects a
  game for every genre variant — 7 variants (6 genres plus the survival-coop
  crafting variant) — and reports **7/7 fully passed** on the structural columns:
  generate, files, build, inspect, spec, HUD, world, surface, load, quality.
- **Load and quality columns exist.** `sweep` runs a headless 8-actor load proof
  (join, concurrent action, save, leave, rejoin, checked for duplicate grants,
  conservation, and persistence) and writes a quality evidence receipt for the
  pack's declared tier. The receipt never mints human approval.
- **Fun and visual quality are unverified.** The receipt records them as
  human-judgment-pending in every case. No claim is made here that any generated
  game is fun, or looks good.
- **Audio is DECLARED, not playable.** Generation writes real 44.1 kHz cue files
  and the pack declares them, but the sweep's audio column reads `DECLARED`
  because the published Roblox asset ids are absent until the WAVs are uploaded
  with Roblox asset-upload scope. Until then the generated games are silent.
- **Art is prototype-grade.** Creature, prop, icon, and launch-art assets are
  first-party procedural output, not production art.
- **Studio interaction is Windows-first.** Interactive Studio runs, multi-client
  QA, and capture tooling target Windows with Roblox Studio installed. Offline
  commands (generate, build, inspect, spec, econ, plan) are platform-neutral.

## Quick start

Install the pinned toolchain, then use the CLI. All commands run from the
repository root.

```powershell
rokit install
```

Scaffold a new game pack from a genre:

```powershell
lune run cli/forge new my-game --genre collect-raid
```

Generate, build, and inspect every genre variant, and write a report to
`build/sweep/<stamp>/sweep.md`:

```powershell
lune run cli/forge sweep
```

Run full verification — lint (selene), format check (stylua), type check
(luau-lsp), the Lune spec suite, then build and inspect every eligible pack:

```powershell
lune run cli/forge check --all
```

`check` needs network access on its first run to fetch the pinned Roblox type
definitions into `build/cache/`; after that it runs offline. Run
`lune run cli/forge` with no arguments for the full command list.

## Documentation

- `docs/forge/genre-spec.md` — the genre spec format and what a generator must emit.
- `docs/release/` — CLI contract, install, support matrix, license boundaries,
  verification, and operational runbooks.
- `AGENTS.md` — layer rules and the rules an automated agent must follow.

## License

Source-available under the **Sustainable Use License v1.0** (the fair-code license
n8n uses), with a separate commercial runtime exception for games built with
Forge. See [LICENSE.md](LICENSE.md), [RUNTIME-LICENSE.md](RUNTIME-LICENSE.md), and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

This is not OSI open source: you may use and modify Forge for internal business
or non-commercial purposes, and distribute it free of charge for non-commercial
purposes. Games you publish on Roblox may be monetized (see the runtime
exception). Third-party assets, models, and platform audio keep their own terms.
