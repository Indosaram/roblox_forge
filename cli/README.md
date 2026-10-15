# cli/

Agent-facing command line for Roblox Game Forge, implemented as Lune scripts.

This is the single entry point for scaffolding, checks, generation, simulation,
localization, QA, deployment, and reporting (see the tool layers in
[docs/ROBLOX_VIRAL_GAME_PLAN.md](../docs/ROBLOX_VIRAL_GAME_PLAN.md), section 11.3).

- `cli/forge/` holds every forge command, e.g. `lune run cli/forge check`. Run
  `lune run cli/forge --help` for the command list and see
  [forge/README.md](forge/README.md) for each command's arguments, exit codes and
  output. `cli/forge/qa/` is the Studio QA driver (`.mjs`, run with `bun`; see
  [forge/qa/README.md](forge/qa/README.md)).
- `cli/release/` holds the release tooling, run directly as Lune scripts from the
  repository root: `lune run cli/release/package` builds the release archive and
  `lune run cli/release/capacity` collects capacity evidence. The `.mjs` files
  there (`capacity-*.mjs`, `local-persistence-host.mjs`, `persistence-readiness.mjs`)
  are the Bun runners and modules behind the capacity tooling (the Lune script
  starts `capacity-collector.mjs` with `bun`); their `*.test.mjs` suites are run
  with `bun test <file>`. See [docs/release/](../docs/release/) for the contracts.
- Setup: install the toolchain pinned in `rokit.toml`, then run `lune setup` once.
  `bun` is needed for the JavaScript suites, deploy/liveops transport and Studio QA.
