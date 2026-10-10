# Provisional maintainer release dossier

Status: **artifact ASSEMBLED and reproducible; live acceptance rows OPEN**, updated
2026-10-04 at revision `269e7a9`. A local source distribution now exists with frozen hashes
(`build/forge-release.zip`), and Task 16 completed green in both the worktree and the
extracted consumer. This document still does not initiate review, authorize publication or
close the live rows, which remain BLOCKED.

## Separate release decisions

| Decision | Current status | Evidence needed to change it |
| --- | --- | --- |
| Source implementation | AUTHORED, UNVERIFIED | Settled owner handoffs, preserved generated output and current consolidated checks. |
| Framework independently usable | BLOCKED | Deterministic licensed archive, exact content manifest and successful fresh consumer with isolated tools/cache. |
| Primal game quality | BLOCKED / INCONCLUSIVE | Identity-bound actual first-play, genuine mobile touch, lawful independent comparison and real listening/motion evaluation. |
| Measured support | UNVERIFIED; no player envelope | Actual exercised eight-client workload, per-client metrics, persistent conservation, saturation and owned crash/replay proof. |
| Live operations and release authority | BLOCKED | Separately authorized pilot with independently observed delivery, compatible recovery proof and current human release approval. |

Passing source tests cannot approve the other rows. A local persistent SQLite
host does not prove Roblox DataStore service durability. An approved local
quality receipt would not grant external release permission.

## Version and runtime facts

These values are read from current manifests, not execution results or a new
release number. Final packaging must reconcile every shipped lock with them.

| Manifest | Declared version |
| --- | --- |
| `core/forge-package.yml` | `1.0.0` |
| `genres/collect-raid/forge-package.yml` | `1.0.0` |
| `genres/grow-harvest/forge-package.yml` | `0.1.0` |
| `genres/survival-coop/forge-package.yml` | `0.1.0` |
| `genres/rpg-progression/forge-package.yml` | `0.1.0` |
| `genres/social-rp-fashion/forge-package.yml` | `0.1.0` |
| `genres/pvp-arena/forge-package.yml` | `0.1.0` |

`rokit.toml` pins Rojo `7.7.0`, Lune `0.10.5`, Selene `0.31.0`, StyLua
`2.5.2`, luau-lsp `1.70.1` and Wally `0.3.2`. Windows x64 is the initial
target, not yet a verified Studio/consumer support claim. Bun `1.4` on Windows
is the intended auxiliary transport/local-host verification target; it is
separately installed, not a Rokit pin or verified minimum. Node, PowerShell,
Studio/MCP, compiler/SDK and decoder compatibility must be recorded from actual
execution. Non-Windows and multi-server support remain unclaimed. Follow
[support](support.md), [CLI contracts](cli-contract.md) and the conditional
native-toolchain rows in [verification](verification.md); source availability
or an installed executable alone is not capability proof.

## Consumer and recovery instructions

The exact fresh-consumer commands are maintained in
[installation](install.md#consumer-setup):

```powershell
rokit install
lune run cli/forge new consumer-island --genre collect-raid
lune run cli/forge plan --concept "Defend ancient groves" --genre survival-coop --pack consumer-grove --seed 42
lune run cli/forge build --pack consumer-island
lune run cli/forge check --all
```

These commands have now been run inside the extracted archive at `269e7a9` (`new`, `plan`,
`build`, `check --pack`, `check --all`, every one exit 0). The extracted consumer needed
network access for the first definitions download; keyless does not mean a fresh consumer is
network-free. The `--help` route still returns nonzero usage and is not a successful-install
probe. Require independent extraction, manifest
byte comparison, no owner paths or inherited caches, actionable missing-tool
failure before writes, and actual command/exit evidence.

Use [support diagnosis](support.md#operational-recovery-and-troubleshooting),
[publication recovery](authoring.md#publication-and-recovery),
[save upgrades](upgrades.md) and [backup/rollback](rollback.md), rather than
inventing restore commands. Unsupported saves fail closed; recovery preserves
leases, command outcomes and transfer journals. After an ambiguous publish,
reconcile independently before any separately authorized repeat. There is no
automatic production backup/restore facility.

## Required proof checklist

The first two boxes are satisfied locally at `269e7a9` with recorded receipts. The remaining
boxes stay open, and the evidence filenames in the next section are deliverables, not links to
fabricated passing receipts.

- [x] **Deterministic distribution and fresh consumer (Tasks 1, 7, 16, 17).** DONE LOCALLY at
  `269e7a9`: two `lune run cli/release/package` runs produced byte-identical archives
  (sha256 `4bfd0861...deddda`); the extracted archive holds 858 files with 0 paths matching
  `.git`/`.omo`/`build`/`reports`/secret/credential/`*.log`; inside it `new`, `plan`, `build`,
  `check --pack` and `check --all` all exited 0 with specs 1383 / 0; dirty-source and
  unknown-rights refusals were observed (`FORGE_PACKAGE_DIRTY`, `FORGE_LICENSE_UNKNOWN`); a
  malformed command refused with usage and leaked no secret. The missing-tool refusal stays
  UNPROVEN because a tool-less PATH could not be produced here. Receipts: `task-1-happy.json`,
  `task-1-failure.json`, `task-7-happy.json`, `task-7-failure.json`, `task-16-happy.json`,
  `task-16-matrix.json`. [Contract](install.md).
- [x] **SUL, runtime exception and all media (Tasks 2, 7).** DONE LOCALLY for the shipped byte
  set: `LICENSE.md`, `RUNTIME-LICENSE.md`, `THIRD_PARTY_NOTICES.md` and
  `docs/release/shipped-licenses.json` ship, and the rights inventory was refrozen through the
  module's own authoring path to 856 records covering every shipped path, with
  `cli/forge/lib/deadline.luau` added to the owner-approved `coveredSourcePaths`. Every shipped
  byte is compared against its frozen record at package time, so a changed digest refuses
  rather than being re-approved. The upstream SUL returned-text comparison remains historical,
  narrow evidence; third-party permission still never follows automatically from Forge's
  exception. [Boundaries](license-boundaries.md),
  [inventory procedure](install.md#rights-inventory-gate).
- [ ] **Authoring and saves (Tasks 3, 8, 9).** Prove all registered starters,
  deterministic regeneration, preserved hooks/user files, interrupted journal
  recovery and pending-reader refusal. Prove supported upgrades preserve
  quantities/outcomes, future schemas and stale writers reject, and distinct
  process replay at durable transfer barriers is conservative. Preserve Primal
  authored configuration/media during its targeted generated refresh. Local
  fixtures do not substitute for real rejoin/crash. [Authoring](authoring.md),
  [upgrades](upgrades.md), [verification](verification.md).
- [ ] **Original identity-bound evidence and cleanup (Tasks 4, 5, 6).** Bind
  actual loaded server and clients to source/config/assets/build bytes, retain
  original PNG/supported baseline JPEG and decoded raster separately from
  measured logical/device/safe-area geometry, and validate ordered actor/session
  actions without shortcuts. Reject stale builds, swapped actors, fabricated
  dimensions and resized substitutes. Prove owned launch, cancellation, late
  allocation and actual descendant exit; EndTest acknowledgement is insufficient.
  [Studio QA](studio-qa.md), [authorization](authorization.md).
- [ ] **Independent reference (Task 10).** Acquire an already independent
  full-loop source with immutable identity, complete component/capture rights,
  original desktop and portrait/touch observations, and a rubric fixed before
  candidate evaluation. Current first-party benchmark is inadmissible; no
  qualifying reference has been acquired. [Reference contract](reference-evidence.md).
- [ ] **Actual audiovisual observation (Task 11).** Verify the maintained
  recorder and decoder, original session/process-bound synchronized tracks,
  clock/frame/sample coverage, real delivered audio and timestamp-linked
  listening/motion observations for gather/craft/hit/ambient. Native compilation,
  WAV hashes, decoded levels and an image-only judge are not listening. Missing
  capability stays INCONCLUSIVE. [Audiovisual contract](audiovisual.md).
- [ ] **First-play, touch and genuine rejoin (Tasks 9, 13).** Observe uncoached
  desktop and portrait play, multiple camera angles, legible critical UI, actual
  touch input, gathering/crafting/eating/resting/building/combat/shared warehouse,
  contention/refusal and wildlife blocked-path recovery. Rejoin replaces real
  sessions, proves old exits and durable reload of the same profile/namespace
  with conserved items/revisions. Portrait keyboard/mouse and same-session
  restore do not qualify. [Scenario execution](verification.md#actual-qa-rows-and-blockers).
- [ ] **Workload, limits and crash (Task 14).** Start with eight real clients,
  configured NPCs and actual caps; record each client's frame p50/p95, memory,
  full serialized wrapper bytes, backend budget/throttle and commit latency
  over the exercised window with hardware/version identity. Require each p95
  at most 33.3 ms, payload within the actual EnvelopeBudget policy, no unhandled
  throttle and conserved state. Separate saturation/refusal from happy workload.
  Terminate owned processes at held durable transfer/lease barriers, restart
  against retained storage and replay without duplication. Neither idle sampling
  nor inferred lower/multi-server capacity qualifies. [Capacity](capacity.md).
- [ ] **Operations and authority (Tasks 12, 15).** Prove legacy/stale/inconclusive
  production refusal, scoped target/credential isolation and bounded sanitized
  single-attempt transport, including timeout/429/malformed/permission failures
  and real helper cleanup. Local fixtures/dry runs do not establish API delivery.
  Separately authorize and observe the live pilot and compatible backup/rollback;
  current local-only scope leaves that pilot blocked. [Operations](operations.md),
  [authorization](authorization.md), [rollback](rollback.md).
- [ ] **Consolidation and final audit (Tasks 16-18, F1-F4).** Run the settled
  all-pack matrix, separate JavaScript/native rows, registered starters and
  existing generalization cases with individual exits and retained failures.
  Do not promote historical totals to current proof. Complete final artifact
  and consumer evidence, then readiness/compliance/quality/manual-QA/fidelity
  audit under their own execution gates. This drafting launches none of them.
  [Exact matrix](verification.md).

## Evidence index and pending filenames

All maintainer evidence names below are relative to
`.omo/evidence/forge-production-release/`. This private evidence directory is
excluded from the source archive. Authored receipts document implementation
intent, not passing QA. Before distributing any evidence separately, prepare
a sanitized index of permitted originals and hashes; do not export private
workstation paths, tokens, raw player data or credentials.

Current preparation inputs are `task-1-authored.json` through
`task-15-authored.json`, `task-5-identity-authored.json`,
`task-2-upstream-verification.json` and `task-16-preflight.json`.
`task-17-preparation.json` records this drafting only. Older partial receipts
can lag later owner handoffs; final intake must reconcile them, not treat a
filename or authored status as authority.

| Owner | Exact pending receipts/artifacts |
| --- | --- |
| Tasks 1-12 | For each task number, `task-N-happy.json`, `task-N-failure.json`, and originals/logs under `task-N/` with a SHA-256 index. `N` is the corresponding task number, not a literal output filename. |
| Task 6 discovery | `task-6-discovery.json`, actual schema/invocations and owned resource/exit evidence. |
| Task 13 | `task-13-first-play.json`, `task-13-rejoin.json`, `task-13-happy.json`, `task-13-failure.json`, originals and SHA-256 index under `task-13/`. |
| Task 14 | `task-14-capacity.json`, `task-14-happy.json`, `task-14-failure.json`, workload/metrics/barrier/snapshot/replay/exit originals and SHA-256 index under `task-14/`. |
| Task 15 | `task-15-happy.json`, `task-15-failure.json`, sanitized fixture and separately authorized pilot proof under `task-15/` with SHA-256 index. |
| Task 16 | `task-16-matrix.json`, `task-16-happy.json`, `task-16-failure.json`, per-command/per-target and fresh-consumer originals under `task-16/` with SHA-256 index. |
| Task 17 | `task-17-happy.json`, `task-17-failure.json`, final consumer/tamper/leak/cleanup proof under `task-17/` with SHA-256 index; repository outputs `build/forge-release.zip` and `build/forge-release-manifest.json`. |
| Task 18 and final wave | `task-18-audit.json`, `task-18-happy.json`, `task-18-failure.json`, `task-18/` originals/index, `F1.json`, `F2.json`, `F3.json`, `F4.json`; public `docs/release/readiness.md`. |

Every acceptance receipt must record actual revision and shipped
source/config/assets/build identity, literal invocation, process/actor identity,
execution interval, original artifact hashes, exit/verdict and owned cleanup or
residuals. A missing required receipt or changed shipped byte keeps release
BLOCKED. Reference/AV supporting filenames must come from actual acquisition
and their maintained contracts; none are invented here.

## Current dependencies and distribution hold

Task 17 depends on Task 16; Task 16 depends on Tasks 7-15 and their upstream
contracts. Final source intake still needs settled lifecycle/rejoin/recording,
persistence/generated-consumer, workload/crash and operational handoffs.
Independent reference acquisition, real listening capability, genuine touch,
fresh-consumer profile isolation and actual runtime observations remain pending.
The current capacity handoff specifically lacks usable pre-dispatch transfer
and startup lease crash integration; safe refusal is not recovery proof.

The production command has now been run from the committed tree at `269e7a9`:
`lune run cli/release/package --out build/forge-release.zip` exits 0 and binds the
revision, versions, inventory and file hashes in `build/forge-release-manifest.json`.
It requires clean recorded shipped source and fresh output names, and there is no
dirty-source override: a shipped byte change refuses until the rights inventory is
refrozen. The live acceptance rows above remain open.

Both documentation/package gaps flagged here are now resolved and verified:
`CHANGELOG.md` is in the package root selection and appeared in the extracted
archive, and the distributable hygiene scan reports 0 workstation-path and 0
secret-shape lines across the 17 `docs/release/` files and the shipped root
documents. This checklist and `readiness.md` are inside the frozen shipped set,
so the freeze notice in section 7 is satisfied.

No push, PR, remote CI, upload, deployment, provider call or spend is authorized.
Preserve paused packs, unrelated edits and user files. Required human production
approval remains separate from local artifact preparation. All Task 17 acceptance
boxes stay unchecked until final artifacts and consumer evidence exist.
