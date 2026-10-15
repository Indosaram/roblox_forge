# Changelog

## Unreleased - provisional source release preparation

Status: **BLOCKED / UNVERIFIED**. These notes describe authored source and
contracts, not a published version, verified framework, approved game, measured
support envelope or live operational approval. No release archive or content
hash is declared by this dossier. See the
[maintainer release checklist](docs/release/release-checklist.md) for required
proof and the current dependency barrier.

### Authored changes awaiting consolidated verification

- Source-archive installation, pinned toolchain and coherent package contracts;
  deterministic packaging and rights inventory mechanisms. Fresh installation,
  reproducibility and extracted-consumer execution remain unverified. See
  [installation](docs/release/install.md) and [support](docs/release/support.md).
- Sustainable Use License v1.0 tooling terms and the commercial Roblox game
  runtime exception, retaining third-party boundaries. Source-available does
  not mean OSI open source. Shipped-media byte comparison and final notice
  coverage remain pending. See [license boundaries](docs/release/license-boundaries.md).
- Deterministic authoring, preserved hook contracts, per-file journaled
  publication and pending-publication consumer guards. This is not whole-pack
  atomicity; interruption and preservation proof remain required. See
  [authoring](docs/release/authoring.md).
- Save-wrapper compatibility, future-schema refusal, fencing and durable
  transfer recovery contracts. Local fixture design does not establish actual
  Studio rejoin or persistent-service recovery. See [upgrades](docs/release/upgrades.md).
- Original capture geometry, loaded runtime identity, action ordering,
  ownership/cleanup, audiovisual, independent-reference and rejoin admission
  mechanisms. Actual desktop/touch first-play, original recording, genuine
  listening and a qualifying independent reference remain unproved. See
  [Studio QA](docs/release/studio-qa.md),
  [reference evidence](docs/release/reference-evidence.md) and
  [audiovisual evaluation](docs/release/audiovisual.md).
- Primal reference-consumer and local persistence integration, capacity
  collection and recovery preparation. No measured player support is claimed;
  an eight-client exercised workload and actual crash/replay proof are required.
  See [capacity](docs/release/capacity.md).
- Fail-closed release authorization, scoped operational transport and recovery
  runbooks. Legacy packs remain unassessed; buildability is not production
  permission. No live operational pilot or external publication is approved.
  See [authorization](docs/release/authorization.md),
  [operations](docs/release/operations.md) and [rollback](docs/release/rollback.md).

### Adoption and upgrade limits

Keep CLI, core, genres and locks from one coherent source archive; independent
per-pack dependency resolution is not promised. Existing package versions are
manifest facts, not a newly assigned Forge release version. Consult the
[checklist version table](docs/release/release-checklist.md#version-and-runtime-facts).
Use a fresh extraction rather than overwriting an existing project. Preserve
authored hooks and user files, and inspect supported save versions before any
rollback. Never reset saves or downgrade version markers to make an older
binary load them. Existing and paused packs are not silently retrofitted.

The [consolidated verification preflight](docs/release/verification.md) is an
execution plan, not passing results. Historical test totals, authored receipts,
source hashes and dry runs do not close release acceptance.

## 2026-10-15 - agent harness improvements

Status: tooling and test-support changes for agents and maintainers working in
this repository. No release claim is made; the unreleased section above still
governs release status.

### Faster, more selective verification

- `forge check` accepts `--only <stage ids>` and `--skip <stage ids>` to run a
  subset of stages, and `--json <path>` to write a machine-readable result. It
  now reports seconds per stage and ends with a summary line naming any failed
  stages.
- `forge test [filters...] [--quiet] [--slowest N] [--json path]` runs the specs
  matching the filters, hides passing output with `--quiet`, lists the N slowest
  tests with `--slowest`, and writes results with `--json`. The runner behind it
  is `M.run` in `cli/forge/lib/specs.luau`.
- `forge smoke --local --strict` fails a pack that has no smoke script instead of
  skipping it.
- Specs resolve scratch directories through `cli/forge/lib/tempdir.luau`, so they
  no longer assume a Unix `/tmp`. `cli/forge/lib/profile.luau` records named
  timing spans and prints them as text or JSON.

### Screenshot comparison

- `forge imagediff <base.png> <compare.png> [--diff out.png] [--threshold n]
  [--ignore x1:y1-x2:y2] [--crop x:y:w:h] [--json]` compares two PNGs. Exit code
  0 means identical, 1 different, 2 usage or decode error.
- QA scenario `capture` steps accept `layers: all|world|ui` to capture only the
  3D world or only the owned UI.

### Deterministic randomness and replay

- `core/domain/random/Rng.luau` is the single seeded random generator. Genre
  servers draw all randomness from it and log `[forge] session seed` at start so a
  session can be reproduced.
- A native QA scenario may declare a top-level `seed: <int>` to fix its roll
  stream.
- `core/domain/command/Journal.luau` records command streams.
  `forge qa run --record <journal.json>` writes one during a run, and
  `forge replay <journal.json> [--json]` replays it. Exit code 0 means MATCH,
  1 MISMATCH, 2 error.

### Reports

- `forge econ sim --json <path>` writes a versioned (schemaVersion 1) result
  next to the markdown report.
- `forge sweep --stamp <text>` names the run, and `sweep.json` is now versioned
  (schemaVersion 1) and records per-step timings.

### Game data

- Collect-raid gamepass effects (the `coins2x` multiplier and the `vipSlots` slot
  bonus) now live in each pack's `econ.yml` rather than in code.
- The collect-raid `Loop.newPlayer` now requires an explicit time argument;
  callers that relied on the implicit clock must pass one.
