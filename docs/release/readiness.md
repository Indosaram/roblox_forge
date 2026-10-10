# Release readiness (PREPARATION_ONLY)

> **PREPARATION_ONLY — BLOCKED. Not an audit. Not acceptance. No release approval.**
>
> This file is Task 18 *preparation*: a truthful map of what the plan requires, what evidence
> currently exists, and exactly what proof is still missing. It does **not** audit Task 18 and
> does **not** close any of the 22 acceptance items, and it does not authorize publication,
> packaging, deployment or external distribution. The audited successor `task-18-audit.json`
> exists and still reports BLOCKED, because the live rows below remain unproven. Acceptance
> stays **0/22**: locally provable rows now carry receipts at a recorded revision, live rows
> stay BLOCKED.

Status line: **release BLOCKED; local framework evidence current at `269e7a9`; Task 18 incomplete.**

## 0. Current local state (recorded 2026-10-04, revision `269e7a9`)

The rows provable without a live client are green and bound to a committed revision:

| Fact | Value |
| --- | --- |
| Aggregate gate | `lune run cli/forge check --all` exit 0 in 257 s; all 13 stages PASS; specs 1383 passed / 0 failed |
| Extracted-consumer gate | same command inside the extracted archive: exit 0 in 235 s; all 13 stages PASS; specs 1383 / 0 |
| Release archive | `build/forge-release.zip` sha256 `4bfd0861...deddda`, reproduced byte-identically by a second run |
| Archive contents | 858 files, 0 paths matching `.git`/`.omo`/`build`/`reports`/secret/credential/`*.log` |
| Receipt inventory | 36 of 36 task happy/failure receipts, `task-16-matrix.json`, `task-18-audit.json`, `F1.json`, `F4.json` |
| Distributable hygiene | 0 workstation-path and 0 secret-shape lines across the 17 `docs/release/` files and the shipped root documents |
| Source state | six local commits on branch `forge-production-release-wave1`; no push, PR, remote CI, deploy or spend |

Everything else below stays as written: the live, reference, listening, touch, capacity and
operational rows are still BLOCKED, and no row is upgraded by the local green state.

---

## 1. Ideal-state map (IS-1 … IS-7)

Receipt paths are relative to `.omo/evidence/forge-production-release/`. "Partial evidence"
means a file was read during preparation; it is not a passing result.

| IS | Plan statement | Delivering tasks | Expected happy / failure receipts | Currently inspected partial evidence | Exact unresolved proof |
| --- | --- | --- | --- | --- | --- |
| IS-1 | Clean supported-machine installation and documented keyless build/check | 1, 7, 17 | `task-1-happy.json` / `task-1-failure.json`; `task-7-happy.json` / `task-7-failure.json`; `task-17-happy.json` / `task-17-failure.json` | `task-1-authored.json` (AUTHORED_ONLY, sample/legacy tiers and unclaimed platforms corrected); `task-7-authored.json` (rights intake 837 selected paths / 799 source / 37 media, `unknown: []`, provisional); `task-17-preparation.json` (PROVISIONAL_DOSSIER_PREPARED) | No clean archive consumer run; no twice-identical archive; no fresh isolated consumer `rokit install` + documented workflow; no missing-tool / malformed-command refusal executed; no content manifest or artifact hashes |
| IS-2 | Stable generation/hooks and compatible saved state | 3, 7, 8 | `task-3-happy.json` / `task-3-failure.json`; `task-7-happy.json` / `task-7-failure.json`; `task-8-happy.json` / `task-8-failure.json` | `task-16-receipt.json` rows `refresh-owned-copy` and `refresh-real-tree` (exit 0, exactly 3 generated paths changed, other 40 byte-identical, `COPY_REPEAT_IDENTICAL=yes`, `GENERATED_MATCH_COPY=yes`); `task-3-authored.json` (per-file publication journal, pending-journal refusal, pre-journal/replace recovery regressions *authored*); `task-8-authored.json` (legacy/v1 wrapper compatibility, future-wrapper refusal, distinct-process ESCROWED/CREDITED/FINALIZED replay regressions *authored*) | Six-genre starter regeneration + determinism + hook preservation + invalid-config refusals not run; interruption/recovery regressions unexecuted; save-upgrade/future-envelope/stale-writer cases not in a passing consolidated matrix; `ObservedBackend.spec` and `RuntimeBackend.spec` currently FAIL in `check-all.log` |
| IS-3 | Reference-reviewed desktop/mobile first-play, visuals, motion and audible feedback | 9, 10, 11, 13 | `task-9-happy.json` / `task-9-failure.json`; `task-10-happy.json` / `task-10-failure.json`; `task-11-happy.json` / `task-11-failure.json`; `task-13-happy.json` / `task-13-failure.json` | `task-10-authored.json` (AUTHORED_ONLY, `acquisitionStatus: BLOCKED`, `referenceCapturesAcquired: false`, bounded research found no qualifying route); `task-11-authored.json` + `task-11-capture-authored.json` (native producer authored); `task-16-receipt.json` native attempt 3 recorded exit 0 linking `qualityav-capture.exe`; `task-13-authored.json` (AUTHORED_PARTIAL, fail-closed touch preflight) | No qualifying independent reference; no listening tool; no actual capture or native runtime invocation; no genuine touch in the inspected MCP schema; first-play/rejoin scenarios never executed; no motion/auditory observation |
| IS-4 | Original identity-bound device/action/audiovisual evidence and honest refusal | 4, 5, 6, 11 | `task-4-happy.json` / `task-4-failure.json`; `task-5-happy.json` / `task-5-failure.json`; `task-6-happy.json` / `task-6-failure.json`; `task-11-happy.json` / `task-11-failure.json` | `task-4-authored.json` (device/logical/raster separated; original JPEG/PNG bytes preserved, no conversion); `task-5-authored.json` (schema-2 global admission, loaded handshake + action transcript authored); `task-6-discovery.json` (`status: BLOCKED`, `list_roblox_studios({})` → `studios: []`, all four required capabilities unavailable, `admission.executedReadiness: false`) | No live capture, no original desktop/portrait bytes, no real loaded server/both-client handshake receipt; refusal fixtures not passing — `qastudio.spec` "original baseline JPEG … refused" and "discovery availability never substitutes …" currently FAIL; no receipt-schema invalidation run |
| IS-5 | Multiplayer conservation through contention, rejoin, crash and measured load | 8, 13, 14 | `task-8-happy.json` / `task-8-failure.json`; `task-13-happy.json` / `task-13-failure.json`; `task-14-happy.json` / `task-14-failure.json`; plus `task-14-capacity.json` | `task-14-authored.json` `finalEnvelopeIntegration` (supersedes earlier missing-envelope statements) and `crashTransferWired` (supersedes earlier pre-dispatch refusal) — both **authored only, not run**; `task-8-authored.json` and `task-13-authored.json` authored regressions/scenarios | Not "waiting on tools" alone — concrete unimplemented or unmeasured mechanisms remain: runtime-only local persistence pre-start configuration; concrete recovery/replay and semantic conservation adapter; configured cap saturation and lawful contention failure workload; bounded recovery restart/cleanup stage integration; hardware and configured/observed NPC census; handled throttle classification. Also unresolved by explicit statement: startup lease barriers, general conservation, unknown-throttle handling. `supportedEnvelope.measured=false`, `measuredPlayers=null`, `crossServer=false`; genuine physical rejoin and live crash/restart never executed |
| IS-6 | Reproducible licensed artifact, upgrades/support and recovery runbooks | 1, 2, 7, 15, 16 | `task-1/2/7/15/16-happy.json` and matching `-failure.json` | `task-2-upstream-verification.json` (UPSTREAM_BODY_MATCH_VERIFIED_ONLY: 9 sections exact returned-text match, 3639 UTF-8 bytes, SHA-256 `919f3c04…ebed564e`, mutable `master` limitation); `LICENSE.md` / `RUNTIME-LICENSE.md` / `THIRD_PARTY_NOTICES.md` / `shipped-licenses.json` authored; `task-15-authored.json` bounded single-attempt transport authored; `task-16-receipt.json` IN_PROGRESS_EXECUTION_RECEIPT | Aggregate `lune run cli/forge check --all` currently **FAILS** (see §4); no source freeze, no archive, no fresh consumer, no completed JS suites, no runbook recovery execution, no operational pilot |
| IS-7 | Correct target/credentials and current production approval | 5, 12, 15, 18 | `task-5-happy.json` / `task-5-failure.json`; `task-12-happy.json` / `task-12-failure.json`; `task-15-happy.json` / `task-15-failure.json`; `task-18-happy.json` / `task-18-failure.json` | `task-12-authored.json` (fail-closed production authorization authored); `task-15-authored.json` (credential isolation/sanitized single attempt authored); current code-path check: `qualityreceipt.luau` `M.validateReference` defined at line 650 and called from `M.check` (line 1505) at line 1615, returning INCONCLUSIVE on failure | **No current production approval and none is granted here.** `deploy-transport.spec` currently FAILS on rubric anchors; no credential/target receipts; no live operational pilot (unauthorized); no `task-18-audit.json` |

## 2. Gap map (GAP-1 … GAP-9)

| GAP | Plan statement | Tasks | Currently inspected partial evidence | Exact unresolved proof |
| --- | --- | --- | --- | --- |
| GAP-1 | Missing root onboarding and clean consumer proof | 1, 7, 17 | Authoring receipts for 1/7/17 exist; rights intake provisional | Clean-consumer onboarding never executed; root README/help exercised by an independent consumer; missing-tool failure path unproven |
| GAP-2 | Checkout pins are not isolated dependencies; public/save contracts undefined | 1, 2, 3, 7, 8 | Authored CLI/license/authoring/upgrades contracts; refresh determinism rows exit 0 | Isolated dependency install, published save-envelope/upgrade contract exercised end-to-end, package manifest mismatch refusal, archive contents verification |
| GAP-3 | QA14 logical viewport/raster conflation and incomplete captures | 4, 6, 9, 13 | Geometry separation authored; discovery receipt written with `studios: []` | Admissible original captures with measured device/logical/raster mapping; `qastudio` JPEG-decode and owned-run-build-identity specs currently FAIL; touch absent from schema |
| GAP-4 | Independent reference/listening/motion approval absent | 10, 11, 13 | Bounded alternative research complete with **no qualifying route**; rubric/rights contracts authored | Independently authored full-loop reference with immutable revision and complete media rights; a tool that actually listens/decodes motion; original synchronized AV capture |
| GAP-5 | Genuine rejoin/live crash/capacity proof incomplete | 8, 13, 14 | Authored recovery/replay/workload/hardware modules; `finalEnvelopeIntegration` supersedes the missing-envelope objection | Actual eight admitted clients with measured p50/p95, payload and commit latency; live termination at durable barriers with restart from real snapshots; startup lease, cap saturation, conservation and throttle handling (§1 IS-5) |
| GAP-6 | Real operational support and release recovery unproved | 1, 12, 15, 16, 17 | Authored operations/rollback docs and bounded transport; Task 16 receipt in progress | Aggregate check green after repairs; runbook recovery exercised; live operational pilot (separately authorized, currently not); archive + dossier |
| GAP-7 | LEGACY_UNASSESSED may succeed for deployment | 12 | Fail-closed authorization authored | Executed refusal receipts proving legacy/inconclusive/stale/downgrade targets reject **before** network or build side effects |
| GAP-8 | Final evaluator weaker than supplement action admissibility | 4, 5 | Schema-2 admission, action-transcript validation and `validateReference` present in current source | Passing adversarial fixtures for stale/shortcut/out-of-order/forged evidence; `qualityreceipt.spec` partial-receipt refusal and `deploy-transport.spec` currently FAIL |
| GAP-9 | Ownership/local hashes do not prove loaded runtime or listening | 5, 6, 11, 12 | Discovery receipt proves honest refusal only (`studios: []`, capabilities false) | Loaded runtime bound to current source/config/build/asset digests with real server + both client handshakes; capture source identity and listening coverage; local attestation never substitutes for signing or runtime proof |

## 3. Expected receipt inventory

Every task `N` in 1…18 must produce, under `.omo/evidence/forge-production-release/`:

- `task-N-happy.json` and `task-N-failure.json` — **36 files**
- capture/log artifacts in `task-N/` with a SHA-256 index
- `task-16-matrix.json` (Task 16 consolidated matrix), `task-18-audit.json` (Task 18 audit)

Final verification wave: `F1.json`, `F2.json`, `F3.json`, `F4.json` — **4 files**.

Each receipt must carry: revision; shipped-source/config/build/asset digest; actual tool
invocation; process/actor identity; timestamp interval; original artifact hashes; exit
code/verdict; cleanup outcome. Missing real capability is recorded as BLOCKED, never as a
successful skip or a native substitute.

**Current inventory (revision `269e7a9`):** 36 of 36 required happy/failure receipts present;
`F1.json` and `F4.json` present (`F2.json` code review and `F3.json` manual QA still absent);
`task-18-audit.json` present and BLOCKED; `task-16-matrix.json` present. Receipts written for
tasks 6, 9, 10, 11, 13 and 14 record `status: BLOCKED` and name the missing real surface, so
presence is never mistaken for a passing live result.

## 4. Current validation state (recorded, bound to `269e7a9`)

Superseded: the earlier `check-all.log` failing run (luau-lsp/specs/inspect FAIL, 1354 passed /
9 failed, 290 `spec module found in place` errors) is historical. Those defects were repaired —
they were a Lune 0.10.5 timer/stdio liveness class plus type and fixture defects — and the
current recorded run is green:

- `lune run cli/forge check --all` in the worktree: exit 0, 257 s, every stage PASS
  (`genre-contract`, `qa-schema`, `selene`, `stylua`, `luau-lsp`, `econ`, `game`, `assets`,
  `locale`, `lock`, `specs`, `build`, `inspect`), specs **1383 passed / 0 failed**.
- The same command inside the extracted archive: exit 0, 235 s, every stage PASS, specs 1383 / 0.
- `task-16-matrix.json` records each of the four packs (`kaiju-egg-raiders`,
  `grow-and-defend-garden`, `plan-demo`, `primal-isles`) with luau-lsp, build and inspect PASS.
- Evidence logs with SHA-256 bindings: `wave1/.omo/check-final.log`, `wave1/.omo/consumer-check.log`,
  `wave1/.omo/specs-run3.log`; receipts under `.omo/evidence/forge-production-release/`.

This certifies the framework rows only. It certifies no live client, no reference, no listening
route, no eight-client measurement and no production approval.

## 5. Hard capability blockers (remain BLOCKED, never a successful skip)

| Blocker | Observed basis |
| --- | --- |
| Genuine touch input | `task-6-discovery.json`: inspected MCP schema has no Touch; keyboard/mouse only |
| Listening / audiovisual evaluation | Bounded tool-catalog queries returned no listening interface; image-only judging cannot approve |
| Independent reference | `task-10-authored.json`: bounded research complete, no qualifying full-loop + rights + immutable-source candidate; `referenceCapturesAcquired: false` |
| Live external pilot | No separate authorization; no cloud writes, publishing, uploads or provider invocation performed |
| Studio connectivity | `task-6-discovery.json`: actual `list_roblox_studios({})` returned `{"studios":[]}`; no process, session or instance created; an empty list does not prove the authored owned launch route is unavailable, but no Studio QA row can start without a connected instance. The prior session's owned QA receipts under `wave1/` are historical and are never restated as current proof |
| Source freeze / archive | Explicitly not run; rights reconciliation is provisional and awaits a stable post-repair boundary |

## 6. Source and artifact freshness requirements

1. **Receipts bind to the tree they were produced from.** Every receipt must record the revision
   plus shipped source/config/build/asset digests. A receipt whose digests no longer match the
   current tree is stale and cannot support approval.
2. **Freeze boundary recorded.** The repaired tree is committed as six local commits on
   `forge-production-release-wave1`, HEAD `269e7a9`; the aggregate check and the extracted
   consumer both pass at that revision, and the archive was built from those committed bytes.
   Any later source change invalidates these receipts and requires a new recorded run.
3. **Rights/media digests are immutable.** The 37 approved media digests must be compared against
   current bytes; a changed digest is never re-approved by recomputation. The 837/799/37 intake
   counts are descriptive, not a coverage gate, and the selected-tree reconciliation must be
   repeated by immutable byte comparison after the stable boundary.
4. **Evidence schema versioning.** Capture schema-2 plus `geometryDigest` bindings are required;
   incompatible older receipts must be explicitly invalidated rather than silently reinterpreted.
5. **Historical receipts are historical.** The `native1297` / `allpack4` / `generalization8` /
   `scopedPASS` receipts and earlier QA14 failure receipts are provenance, not current proof, and
   are never restated as current success.
6. **Capability honesty.** No receipt may claim touch, listening, independent reference or a live
   pilot that current discovery shows unavailable.
7. **This documentation enters the freeze.** See §7.

## 7. Coordination notice for the active Task 16 validation owner

> **This public documentation addition changes the final selected inventory.**
> `docs/release/readiness.md` and `.omo/evidence/forge-production-release/task-18-preparation.json`
> are two newly created files in the execution tree. They must be included in the final
> selected-path reconciliation and must enter the **source freeze before any archive is built**;
> an archive produced without them is missing required release documentation.
> **Do not interrupt in-flight repairs to act on this notice** — record it and apply it at the
> stable post-repair boundary when the freeze is computed.

No direct message was steered at the running validation worker while preparing this file, for
exactly that reason; the notice is carried in this document and in the preparation receipt.

## 8. Scope of this file

Performed: read-only inspection of the plan, execution ledger, current `docs/release/`,
evidence directory listings, and the receipts/logs named above; authoring of this file and of
`task-18-preparation.json`.

Not performed, and not implied by this file: F1–F4, code review, tests, lints, builds, source
edits outside the two owned files, Studio launches, packaging, archives, commits, pushes, PRs,
remote CI, deploys, uploads, provider calls or spend.

Known documentation debt carried forward: release documents still contain local inspection
detail and require the distributable workstation-path/secret audit before archiving; this file
uses repository-relative paths only.
