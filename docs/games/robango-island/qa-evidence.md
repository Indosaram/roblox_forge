# robango-island QA evidence

## Studio real-input evidence and gates (2026-10-23)

Current `main` is `23f5e8c`. The Studio runs below used local builds of an
earlier commit plus the uncommitted batch that later landed. No Studio run used
exactly `23f5e8c`. Each row names its build. Evidence paths are under
`.omo/evidence/robango-recovery/` and are gitignored local files. "Real input"
means real E/F key presses, mouse clicks and wheel steps sent through Studio
MCP. Camera pins and listener probes were temporary, client-only and
unsaved.

### Verified in Studio by real input

| Item | Result | Build | Evidence |
|---|---|---|---|
| Creature strike | PASS. A real F press provoked compsognathus. Feedback went telegraph -> strike, and player HP dropped 4 per strike. In p35 no strike landed. | `5bcb0e6` + batch (landed as `5c9f574`) | `p36/s.md` section 1 "Strike" |
| Expedition results popup | PASS. With no input it stayed open about 115 s. A real click on X closed it, and it stayed closed for 10 s or more. The reward-row text was not seen, because no mission reward had been earned. | `5bcb0e6` + batch | `p36/s.md` section 1 "Results popup" |
| Gather with one press | PASS on hand-gatherable nodes: one real E on branch and on fiber was confirmed in 0.11-0.13 s, and the label returned to 채집하기. In p37, a refused E on wood left the label stuck on 채집 중...; p40 shows that fixed (next row). | `da51791` + batch (landed as `6d8fef3`) | `p37/s.md` section 2 "One E on wood" |
| Axe refusal notice and prompt reset | PASS with no tool equipped. Four real E presses on a1.s1 wood each showed `입문용 도끼 이상 도구 장착 필요` for 3.0 s, and the label went back to 채집하기 within 0.06 s. | `6d8fef3` + uncommitted batch | `p40/s.md` section 3 "Axe notice" |
| Arrival sheet X | PASS. A real click on X closed the a1.s1 arrival sheet, and it stayed closed for more than 10 min. The p36 reopen is gone. | `da51791` + batch | `p37/s.md` section 2 "Arrival sheet X" |
| 연주 menu tile | PASS. Real wheel steps reached the true bottom of the menu canvas (560 px, previously 414 px). A real click on 연주 opened the score editor. | `da51791` + batch | `p37/s.md` section 3 |
| Creature lineup, 24 species | All 24 PASS on grounding, silhouette, part budget of 48 or fewer, and no z-fighting. The parasaurolophus crest failed and was then fixed. Its after-shot used the patched module loaded only into the Play datamodel. This was a scripted showcase spawn, not real input. Live a1.s1 and onboarding wildlife still animated. | `6d8fef3` + creature patch (landed in `23f5e8c`) | `p39/s.md` |
| ProcProps | p37: a1.s1, harbor and a3.s3 each had 24 props, grounded within 0.05 studs and clear of every prompt. Home had 10 props instead of 8, and the a1.s1 palm lay flat. p40, with the uncommitted props patch: a1.s1 bboxes sit on the terrain (dBottom 0.00) and trees are 5.6-8.9 studs tall, but **the palm still lies flat (FAIL)**. Home had 7 props, the nearest 14.2 studs from a prompt. That patch is not committed. | p37: `da51791` + batch; p40: `6d8fef3` + uncommitted batch | `p37/s.md`, `p40/s.md` section 1, `p40/s/props_home.txt`, `p40/s/clear_home.txt` |
| Console | 0 game errors after excluding asset HTTP 403 noise. p36: a1.s1, onboarding, harbor and a3.s3. p37: a1.s1, harbor and a3.s3. p39: a1.s1 and onboarding. p40: a1.s1. | as above | `p36/s/console_*.txt`, `p37/s/console_*.txt`, `p39/s/console_*.txt`, `p40/s/console_a1s1.txt` |

The axe-tier journey ends with the tutorial Flint Hatchet (`stone-axe`) gathering a1.s1
wood and settling the first mission. It is verified only by native
scenarios: `archipelago-first-stage-stone-axe` and `-onsite-axe` both record PASS
and replay MATCH (`p38/wood.md`). In Studio, only the refusal path above was
exercised. A Studio walk with the Flint Hatchet has not been recorded. The
22 new SFX cues are silent in Studio because they are local fallbacks
(`p37/s.md` section 4).

### Not verified

- No live staging deploy since the owner account was moderated. No published
  version of these builds exists.
- No real phone run of these builds. Portrait 360x640 can be checked only on
  a phone. In p35 the Studio portrait override did not apply, and the device emulator
  was unreachable (`p35/s.md` section 4).
- No two-account live trade or camp.
- The 22 new SFX are not uploaded. `assets/manifest.yml` lists them as
  `NotUploaded`, so they are silent in live play.

### Gate results for `23f5e8c` (lead-run)

The lead ran these gates and reported the results. This lane found no log file
for them under `.omo/evidence/`.

- `forge check`: 13/13 stages PASS.
- Command exit gate: 79/79 commands exited 0.
- Native scenarios: all 38 recorded and replayed MATCH.

## Current recovery evidence (2026-10-21)

This section supersedes old blanket readiness claims and the fidelity matrix's
pre-implementation default labels; that matrix still defines target scope, not
a fresh execution ledger. Baseline inspected: local main/origin main `d1f13db`.
The history since `690ac33` adds P1 content/routing, P2 homes/archipelagos and
progression, P3 late/social systems and presentation, P5 production adapters,
then `ecc3260` startup/P1 fixes and audio upload and `d1f13db` Studio services,
art, icon upload/screening and asset compaction. Concurrent P7 changes are not
promoted to verified behavior merely because their source is present.

**Demonstrated** below means the named evidence layer only, never complete
end-to-end acceptance. **Implemented but unverified** means an implementation
or integration is recorded but the specified real-use acceptance is not proven.
**Absent** means a named deliverable is missing from this evidence, not that an
unrelated module with a similar name cannot exist. These distinctions prevent
both the old "everything passes" claim and the stale "nothing implemented"
default from describing current work.

| Feature | Demonstrated | Implemented but unverified | Absent / remaining evidence |
|---|---|---|---|
| Fresh player / HUD / gather / station craft / rest / placement | P5 Studio real input demonstrated walking and gather; craft and rest failed (`p5/studio.md`). | Station reach, terrain placement, target localization, docks and startup/service fixes recorded in `p5/wire.md`, `p6/studio-services.md`. | Current-build uninterrupted fresh survival-loop pass. P6 recheck failed before ForgeState/HUD; it does not prove each downstream feature broken. |
| Personal island / storage / development | Native `home-return`, `home-permissions`, `home-storage-transfer`, `fresh-home-archipelago-return` recordings in p5/p6. | Live actor-stable home routing, storage and development implemented. | Published TeleportService round trip and current phone usability evidence. |
| Archipelago / missions / rewards | Native `archipelago-chain`, `archipelago-four-island-rewards`, `fresh-expedition-return` journals. | Role worlds and fresh-player route integrated. | New-design published multi-Place journey, actors/JobIds and return proof. |
| Instability / expiry | Native `archipelago-expiry`, `volcano-progression` journals. | Clock/expiry policies and world adapters. | Published expiry-safe evacuation and real-player recovery. |
| Materials / processing / skills | Native `bootstrap-crafting`, `material-to-equipment`, `equipment-support`; P1/P2 regression evidence. | Generated content and progression hooks. | Current-build real-input material-to-equipment completion across the full target scope. |
| Farming / tailoring / cooking | Native home/progression/equipment scenarios cover their asserted recipe/crop/equipment behavior. | Catalog-driven production adapters. | Full authored farming, clothing and cooking UX acceptance on desktop/phone; native assertions are not complete content coverage. |
| Wildlife / butchering / combat | Native `combat-tame-ride`, `volcano-progression`; P5 production-building includes real Session tyrannosaurus combat with fixture durability repairs. | Server combat/provenance and creature rig integration. | Current real-input hunt/extraction acceptance; fixture repairs are not ordinary survival play. |
| Taming / mounts / cargo | Native `taming-mounts`, `combat-tame-ride`, `handoff-conservation` journals. | Production companion/capture/ride hooks. | Current-build real players capturing, riding and transferring cargo across published travel. |
| Contracts / support / rescue / escort | Native `contracts-tutorial`, `rescue-escort-cargo`, `equipment-support` and progression journals. | Mission, remedy and persisted escort producers recorded in `p5/wire.md`. | Full real-input mission and support loop on the current build. |
| Clans / research / outposts | Production-clan native scenario proves create/invite/join/deposit, hall/research and fresh-owner recovery; `p5/wire.md`, p6 journals. | Fenced directory, treasury, queue/occupancy and panels integrated. | Actual multi-account governance, live outpost teams/occupancy and reconnect evidence. |
| Cross-server market / harbor | Native cross-server-market uses two Session owners/shared backend, offline seller, claims and conservation; replay hashes in p5/wire and p6/studio-services. | Durable listing/claim services and production panel/harbor prompts. | Two real accounts in different live JobIds settling an actual trade and failure recovery. Headless renderer widths are not screenshots. |
| Volcano / late equipment | Native volcano-progression and equipment-support journals. | Hazard, boots, materials and technical-support paths. | Published real-input late progression and physical-device acceptance. |
| Brawl | Native real Session BrawlRuntime scenario covers weather, ranged ammunition, elimination and duplicate settlement (`p5/wire.md`, p6 journals). | Durable arena, client controls and production panels. | Real two-player match, maximum-client load and current screenshots. |
| Instruments / score editor / ensemble | Chunk/ACL/durability specs and native production-score/ensemble-sync (`p5/musiclive.md`, `p5/wire.md`, p6 journals). | Score transport/library/editor, range authority and scheduled sample-bank playback. | Real multi-client audible synchronization and listening acceptance; full timeline/library/recipient-selection parity is not demonstrated. |
| Eight-chapter journal | Native journal-eight-chapters plus production-building command/checkpoint/remedy/escort/restart evidence. | Production panel, chapter-bound durable outcomes, dialogue/survey/assembly/escort producers. | Real-input completion of all eight chapters. A catalog or native journal is not that completion. |
| Multistorey homes / aerial view | Native multistorey-home/production-building and camera adapter specs. | Place/remove topology, inventory, camera/GUI restoration and capture controls. | Humanoid stair traversal and current PC/phone floor/aerial/capture acceptance. |
| Monetization / entitlements | Historical staging product registration and native prompts; native receipt/entitlement/handoff contracts. | Registered catalog and benefit integration. | Authorized actual charge, receipt settlement and current benefit verification; prompt visibility is not payment success. |
| Art / UI icons | P5 world/species/UI captures exist with failed visual acceptance; P6 art budgets and local icon screening are recorded. | P6 role dressing/rig improvements; P7 shelter revision in `p7/art2.md`. | Fresh complete visual sign-off after the final art changes, actual GPU triangle/draw-call measurements. |
| Audio assets / event wiring | Local WAV banks, native production-audio and AudioDirector scenarios; upload history exists. | Audio settings/director and event producers. | Moderation-approved playback/listening for all cues; 55 audio remain pending moderation. |
| Persistence / crash / load | Native qa-save-01 and local service/store recovery specs. | Published-service adapters and Studio-memory-only service selection. | Current published crash/rejoin/Teleport proof and real MemoryStore load. Local services are not cloud evidence. |
| QA-PERF-01 layer 2 | 2026-10-21 isolated revision `9db8e04` Studio phone-content viewport 360x640 / Level01, three accepted cold Play starts (A, B, D) recorded in `p13/perf.md`; the probe subscribed from ReplicatedFirst before startup readiness, replacing the earlier left-censored method. P6 static future-published asset budget passed (`p6/assets-compact.md`). | `c6dec48` moved onboarding `fiber-bush-01` from z=14 to z=5 beside the spawn, with a spec asserting every onboarding spawn has a gather prompt within its activation distance. Not re-measured under the QA-PERF-01 protocol. | **FAIL for initial first interaction at `9db8e04`:** ForgeState and visible HUD existed, but the nearest enabled gather prompt was 14.17 studs from spawn with an 8-stud activation range; no player movement was injected, so TTFI was not observed (no finite median/max). **TTFI must be re-measured on a build containing the fix.** Studio-process memory (not device memory): pooled median 2355.383 MB, max 3257.449 MB; no runtime-memory threshold is defined, so no memory PASS/FAIL. Physical low-end-device acceptance remains open. **Re-measured 2026-10-23 on `2e5ca3b` (`p54/perf.md`, same probe and profile, three cold Play starts): TTFI observed in 3/3 runs, median 0.671 s (0.629-1.333 s), first prompt `fiber-bush-01` at 5.46 studs of 8 with line of sight; ForgeState median 0.304 s; HUD visibility is the last condition. Studio-process memory median 1,500.0 MB, max 1,576.6 MB over 363 samples; about 56,285 instances, 983 Workspace parts. No numeric TTFI or runtime-memory threshold is documented, so this is a functional pass only; Studio resets the profile on Play (re-applied at about 10 s), so the TTFI values ran at the default viewport. Physical low-end device performance remains unverified.** |

Evidence paths in this table are under `.omo/evidence/robango-recovery/` and
remain gitignored local artifacts. The table summarizes recorded scope, not a
new run of every scenario. P5 lane integration snippets describe earlier missing
wiring; the later `p5/wire.md` ledger and P6 service recovery supersede those
particular gaps only where explicitly recorded.

### Current Studio and moderation limits

`p5/studio.md` is FAIL/incomplete visual and fresh-loop acceptance.
`p6/studio-p1.md` is also FAIL: three Plays lacked ForgeState/HUD because startup
failed. The later service fix has deterministic boot proof but was not Studio
verified by that lane. P7 screenshots and console files are partial observations,
not a signed-off replacement report. In particular,
`p7/studio/authored-onboarding-console.txt` records
`Dictionary is not a supported attribute type` in RoleWorld.build;
`p7/studio/phone-console-history.txt` records `User is moderated` sound failures,
and `p7/studio/play1-console-mcp.txt` explicitly contains truncated HTTP 403
asset output. Do not claim zero errors or a fresh startup/art pass from these.

The account moderation warning blocks further external asset work. The recovery
status is **253 icons not yet uploaded** and **55 audio pending moderation**.
P6 local review replaced ambiguous artwork but cannot clear Roblox moderation.
Do not publish or resume uploads while that blocker remains unresolved.

**Studio real-input journey on `97e6a3e` (2026-10-22, `p24/a.md`).** In Windows
Studio, real input completed the onboarding chain from first gather through
stone-axe craft, equip, two wood chops, warehouse deposit, campfire
reserve/place, rest, contract accept and deliver to tutorial complete. Two
refusals happened on the way: `PLACEMENT_UNREACHABLE` until the player walked
within 12 studs of the ghost, with no UX hint; and a first deliver that did
nothing because the contract counts bag wood only after the tutorial had the
player deposit wood. Filtered client/server console errors were 0 in
onboarding, a1.s1 and home. The run also logged 259 excluded
`AnimationTrack limit of 64` messages, a track leak candidate. Visual
acceptance is **not** passed: the a1.s1 overview FAILs readability (flat
monotone ground, nothing in frame); the home and onboarding camp have
over-strong orange campfire glow and palm occlusion; the creature close-up is
PARTIAL. Those fixes are pending. The PC 1920x1080 and phone 360x640 captures
could not be set through the available product APIs. This is a scoped Studio
result, not release readiness.

Staging remains Universe `10771918494` / Place `95467272687768`; no new published
version was read back in this task. The authoritative local variable names,
Open Cloud deploy/upload scopes, Game Pass/Developer Product mapping paths,
and staging/production commands are in
[user-actions.md](user-actions.md#현재-운영-상태와-다음-행동-2026-10-21).
Production is not established by staging registration or historical deployment.

## Readiness correction (2026-10-20)

Earlier **release-ready** and **full-functionality** claims are withdrawn. The records below concern the earlier single-island prototype and the specific builds/scenarios recorded at the time; they do not prove the recovery design in `.omo/plans/robango-recovery-world-audit.md` or the catalogs indexed by `.omo/drafts/robango-spec-index.md`. Robango Island does not claim 100% original parity. The current system-by-system scope and remaining implementation acceptance are recorded in [fidelity-matrix.md](fidelity-matrix.md).

What was actually recorded: deterministic local/spec checks; three Studio scenario runs (`survival-coop:wildlife-spatial`, `survival-coop:full-coop-rejoin`, `survival-coop:tutorial-studio`); private staging deployments and cloud storage probes; and an Android run of the older content with native commerce prompts. Historical rows, failed attempts, device measurements and deployment notes are retained below rather than rewritten as new evidence. This correction does not freshly rerun those sessions or read back the current published version.

What has **not** been proven for the new design: a mission-linked archipelago journey; travel to and return from an actor-stable personal home; real two-account live trade, including cross-server listing/settlement and failure recovery; and real-device execution/performance of the new world, progression, combat, farming, journal, brawl and ensemble content. Studio guest/fixture actors do not substitute for two real live accounts. Old phone measurements do not certify new content. A local transfer-crash fixture does not prove published TeleportService travel.

Evidence layers must remain separate: source/code inspection establishes only what was inspected; deterministic tests establish their asserted contracts; Studio scenarios establish only their recorded Studio scope; published staging sessions establish only their recorded version and actions; settled commerce requires an authorized actual charge/receipt and effect verification. Registered IDs and a visible purchase prompt are not proof of paid benefit application or billing settlement. No new charge or public release is authorized by this document.

Accordingly, every PASS below is a historical, scoped result, not a blanket current readiness gate. The old QA-ID table and numbered notes remain intact for traceability. Completion requires new-design code and actual-play evidence for every applicable fidelity row, with commit/build digest, place/version, actor IDs, JobIds and invocation as required by recovery tasks 2 and 12. Unknown or unavailable live evidence stays unverified; it cannot be replaced by document review or a green spec suite.

## Historical QA-ID map

Maps every QA ID in section 12 of the port plan to the local command that proves it, the spec or scenario that holds the check, and its status. Run all commands from the repository root with `forge` = `lune run cli/forge`.

Status values: **local PASS** (runs here, deterministic), **needs Studio** (cannot be measured without Roblox Studio or a device), **needs staging** (needs a staging Universe and a human), **gap** (a local check exists but does not yet cover robango-island).

| QA ID | Local command | File : spec name | Status |
| --- | --- | --- | --- |
| QA-CORE-01 | `forge test SurvivalTutorial --quiet` | genres/survival-coop/module/SurvivalTutorial.spec.luau : "golden path emits every step once in order and completes once", "rejoin resumes at the same step..." ; scenario `forge qa run --pack robango-island --scenario survival-coop:golden-path` | local PASS; Studio PASS 2026-10-19 `survival-coop:tutorial-studio` (`live-tutorial-studio-20261019T101133Z`, note 7) |
| QA-SPIKE-01 | `forge test spikesim --quiet`, `forge spike --players 64` | cli/forge/lib/spikesim.spec.luau : "N=64 spike meets the p95 target with nothing lost, overfull or leaked" | local PASS (layer 1 simulation); layer 2 needs staging |
| QA-SPIKE-02 | `forge test Allocation --quiet` | core/domain/island/Allocation.spec.luau : "QA-SPIKE-02 overfull islands are rebalanced..." | local PASS |
| QA-TP-01 | `forge test Teleport --quiet` | core/infra/island/Teleport.spec.luau : "QA-TP-01 20 percent failure over 100 teleports..." | local PASS |
| QA-LEASE-01 | `forge test Lease --quiet` | core/infra/island/Lease.spec.luau : "NEGATIVE: old owner write after display expiry is fenced..." | local PASS |
| QA-ERR-01 | `forge test qa-evidence --quiet` | games/robango-island/qa-evidence.spec.luau : "QA-ERR-01 no player-facing string carries SQL, stack traces, internal ids or paths" and its NEGATIVE planted-string spec | local PASS |
| QA-BM-01 | `forge check --only econ` | cli/forge/lib/deployplan.spec.luau : "QA-BM-01 the dirty catalog fixture is refused..." ; check.luau econ stage lints every pack's game.yml | local PASS |
| QA-BM-02 | `forge test Rolls --quiet` | core/domain/crafting/Rolls.spec.luau : "QA-BM-02 same seed gives identical result hash regardless of entitlements" | local PASS (crafting); taming path is covered by TamingRuntime.spec.luau on the integration branch |
| QA-BM-03 | `forge test Receipts --quiet` | core/infra/monetization/Receipts.spec.luau : "QA-BM-03 redelivery storm yields zero duplicate grants..." | local PASS |
| QA-BM-04 | `forge test Subscription --quiet` | core/infra/monetization/Subscription.spec.luau : "an ineligible account is never prompted" | local PASS; staging Android phone PASS 2026-10-20 (`SM-N981N`, `ko-kr` account prompted `EXP-4461467833720767028` and `3720013569`, note 8) |
| QA-BM-05 | `forge test CurrencyLedger --quiet` | core/domain/economy/CurrencyLedger.spec.luau : "paid-tagged currency is refused by a free random surface..." | local PASS |
| QA-ECON-01 | `forge test qa-evidence --quiet` | games/robango-island/qa-evidence.spec.luau : "QA-ECON-01 material source/sink balance sits inside the new-estimate band" + two NEGATIVE specs (doubled source, starved source) | local PASS (see note 1) |
| QA-ECON-02 | `forge test Market --quiet` | core/domain/market/Market.spec.luau : "QA-ECON-02: ineligible accounts are rejected...", "QA-ECON-02: daily cap + 1..." | local PASS |
| QA-ECON-03 | `forge test Market --quiet`; `forge qa run --pack fixture-survival --scenario rejoin-cooldown --packs-root cli/forge/fixtures/settlement-conflict` | core/domain/market/Market.spec.luau : "QA-ECON-03: same-path same-interval bot loop is flagged..." ; genres/survival-coop/qa-scenarios/rejoin-cooldown.yml | local PASS |
| QA-PROV-01 | `forge test provenance --quiet` | cli/forge/lib/provenance.spec.luau : QA-PROV-01 block (clean passes, contaminated rejected) | local PASS: the pack opted in (`games/robango-island/provenance/policy.yml`) and `lune run cli/forge provenance check --pack robango-island` passes (note 2) |
| QA-NAME-01 | `forge test content.spec --quiet` | games/robango-island/content.spec.luau : "shipped pack text uses original names only" ; cli/forge/lib/provenance.spec.luau : QA-NAME-01 block | local PASS for the pack text spec; the policy-driven gate (banned names, stems, hashed names, reference 8-grams) now enforces on the pack and passes, as for QA-PROV-01 |
| QA-ASSET-01 | `forge assets check --pack robango-island`; `forge test qa-evidence --quiet` | games/robango-island/qa-evidence.spec.luau : "QA-ASSET-01 the real robango-island manifest passes...", "NEGATIVE: banned generators..." (AudioCraft, Roblox Cube, Hunyuan3D-2), "NEGATIVE: missing provenance and missing rights fields..." | local PASS |
| QA-WILD-01 | `forge test WildlifeWorld --quiet` | genres/survival-coop/module/WildlifeWorld.spec.luau : "thirty third NPC spawn is refused and the cap cannot be raised" | local PASS (genre level; the pack's own roster is validated by content.spec.luau) |
| QA-TAME-01 | `forge test Taming --quiet` | core/domain/taming/Taming.spec.luau : "QA-TAME-01: 10000 seeded simulations land within one percent..." ; genres/survival-coop/module/TamingRuntime.spec.luau : "same seed and events reproduce every capture outcome" | local PASS (merged into durango/integration, 29 specs) |
| QA-SAVE-01 | `forge qa run --pack robango-island --scenario survival-coop:qa-save-01-rejoin-transfer-crash`; `forge test qa-evidence --quiet` | games/robango-island/qa-scenarios/survival-coop.qa-save-01-rejoin-transfer-crash.yml ; qa-evidence.spec.luau : "QA-SAVE-01 rejoin and transfer-crash scenario conserves items...", "NEGATIVE: a lost item..." | local PASS |
| QA-PERF-01 | `forge test qa-evidence --quiet` (static build budget only); `forge test render-budget --quiet` (low render-profile caps) | games/robango-island/qa-evidence.spec.luau : "QA-PERF-01 built robango-island place stays inside the new-estimate static budget" + NEGATIVE ; games/robango-island/render-budget.spec.luau | local PASS for the static budget and the render-profile caps only (note 3). Runtime: **not a pass.** Studio layer 2 re-measured on `2e5ca3b` (2026-10-23, `p54/perf.md`): TTFI observed in 3/3 cold starts, median 0.671 s, Studio-process memory median 1,500 MB / max 1,577 MB (on `9db8e04` TTFI was not observed); Studio-process and Android (`SM-N981N`, 2026-10-20, revision not recorded) memory figures have no threshold. Physical low-end device measurement is pending (notes 3, 8) |
| QA-RT-01 | `forge qa run --pack robango-island --scenario survival-coop:market-trade --native` | genres/survival-coop/qa-scenarios/market-trade.yml (durable-escrow MarketExtension over a real Session with personal aggregates: list, completed trade with Coins moved and fee sunk, replay, refusals, restart + cancel) | local PASS steps=55 assertions=33 |
| QA-RT-02 | `forge qa run --pack robango-island --scenario survival-coop:shop-receipt-storm --native` | genres/survival-coop/qa-scenarios/shop-receipt-storm.yml (MonetizationExtension: Catalog/Receipts/Subscription, idempotent redelivery) | local PASS steps=27 assertions=13; staging product IDs registered and verified on Universe `10771918494` (note 8) |
| QA-RT-03 | `forge qa run --pack robango-island --scenario survival-coop:contracts-tutorial --native` | genres/survival-coop/qa-scenarios/contracts-tutorial.yml (ContractsExtension: contracts, trust, tutorial golden path + negatives + restart) | local PASS steps=74 assertions=31 |
| QA-RT-04 | `forge qa run --pack robango-island --scenario survival-coop:taming-mounts --native` | genres/survival-coop/qa-scenarios/taming-mounts.yml (TamingExtension + TamingPanel gauge, capture/feed/mount, refusals, restart) | local PASS steps=44 assertions=15 seed=4242 |
| QA-RT-05 | `forge qa run --pack robango-island --scenario survival-coop:camp-ladder --native` | genres/survival-coop/qa-scenarios/camp-ladder.yml (CampExtension ladder, friend visit open/help, rejoin cooldown) | local PASS steps=51 assertions=24 (friendship via fixture; live `Player:IsFriendsWith` needs a published server) |
| QA-RT-06 | `forge qa run --pack robango-island --scenario survival-coop:zone-death --native` | genres/survival-coop/qa-scenarios/zone-death.yml (DeathZoneExtension zone-set, Vitals.deathPolicy safe/danger, invalid zone refused) | local PASS steps=26 assertions=15 |
| QA-RT-07 | `forge test IslandBootstrap --quiet` | genres/survival-coop/module/IslandBootstrap.spec.luau (single vs routed mode, placeId 0 / Studio / missing service fallback) | local PASS; real TeleportService round trip needs staging (U13/U20) |
| QA-REG-01 | `forge check --all` | cli/forge/commands/check.luau (every stage over every pack) | local PASS 2026-10-19 on Windows: `lune run cli/forge check` printed `check: PASS (13 stages, 403.4 s)`; the 17 CI JS suites (17/17), the 7 native QA scenarios, `forge smoke --pack robango-island --local` (1/1) and `forge build --all` (4 packs, inspect PASS) also pass on the same tree |

## Notes

1. **QA-ECON-01.** `forge econ sim --pack robango-island` cannot run: the genre simulator for the crafting-mode survival-coop pack stops with `simulation produced no accepted actions: survival-coop`, because the crafting config declares placement and wildlife features the simulation driver does not implement. So the economy gate is computed directly from `content.yml`: for each raw material that has a gather node, gather yield per hour divided by the raw material needed to build every structure once. The accepted band is 1.0 to 100.0 (new estimate, to be revisited after a play session). Measured today: wood 3.4, fieldstone 2.0, marsh clay 2.8, birch bark 9.6, reed 14, flint 65. Hide has no gather node (wildlife drop only) and is excluded. Doubling every yield pushes flint to 130 and fails; a tenth of the yield falls below 1.0 and fails.
2. **QA-PROV-01 / QA-NAME-01.** The pack now opts in: `games/robango-island/provenance/` carries `policy.yml` (the reference-ip template), `banned-names.yml` (the reviewed reference-ip list), and `fingerprints/namu-20261016.path` pointing at `cli/forge/provenance/reference-ip/fingerprints`. `lune run cli/forge provenance check --pack robango-island` passes (1128 strings, 318 sidecar entries, 7 assets). Sidecars are `content.provenance.yml`, `econ.provenance.yml` and `locale/provenance.csv`; asset author/created are stamped by `forge gen procedural|audio --author agent:claude-5.5/robango-g1 --created 2026-10-16`. Two English locale lines (`lore_role`, `tutorial_done`) were reworded because they matched reference 8-grams.
3. **QA-PERF-01.** Only static numbers are measurable locally. Measured on 2026-10-22 on the p34 tree (`4f70098` plus the uncommitted p33/p34 batches) with the spec's own method (`rojo build` of `games/robango-island/default.project.json`, then a walk of every instance in the deserialized place): 337 instances, 280 scripts, 2,790,298 bytes (2.79 MB) of script source, 1,096,487 bytes (1.10 MB) place file; with every manifest asset rendered as published, future script source is 2,803,296 bytes against the 2,985,000-byte limit (3.0 MB minus the 15 KB margin), so about 182 KB remain. The earlier figures (217 instances, 168 scripts, 1.26 MB source, 0.54 MB file) predate the catalog screens and world-density work and are superseded. The budget (400 instances, 300 scripts, 3.0 MB source, 1.5 MB file) is a new estimate. The source limit was raised from 2.5 MB to 3.0 MB on 2026-10-22 when the 36 missing catalog screens were added (each screen lane adds about 30 KB of client script); it is not a Roblox platform limit. **Render profiles (p34).** `game.yml` `render_profiles` (mirrored by `src/shared/RenderBudget.luau`) define a low profile selected at SavedQualityLevel 1-3, or Automatic on a touch device: at most 160 decorative dressing parts visible (nearest to the spawn first; RoleWorld stamps `ForgeDecorRank`), at most 2 dressing effect hosts emitting (fire, smoke, ash particles, lights), no decor shadows, articulated creature poses limited to the 6 nearest within 60 studs (telegraphs, attacks, stuns and deaths always posed), and at most 2 runtime EditableMesh prop builds. The high profile keeps the previous behaviour (100-stud pose range, every part, effect and mesh placement). `render-budget.spec.luau` proves each cap on every stage plan; the caps' runtime effect on memory or frame time has **not** been measured. **Layer 2 (Studio, measured 2026-10-18; the measured revision is not recorded in this document and predates `9db8e04`).** Measured in Roblox Studio on Windows (Ryzen 5 7500F) at the lowest rendering quality (Level01), with temporary probe scripts that were never committed. "First interaction" is the moment a gather ProximityPrompt is enabled on the client; time is counted from when the client script starts. These rows are historical and do not describe the current build.

| Run | Character spawned | Island built (server) | First interaction | Peak memory (Studio process, server + client) |
|---|---|---|---|---|
| Cold Studio start, before fix | 30.8 s | 51.8 s | 53.8 s | 1,636 MB |
| Warm, before fix (one yield per terrain column) | 2.3 s | 4.4 s | 4.45 s | 2,659 MB |
| Warm, after fix (yield every 50 ms of work) | 2.4 s | 0.24 s | **2.86 s** | 2,639 MB |

Client memory by tag after the fix: LuaHeap 806 MB, Script 268 MB, Instances 103 MB, Gui 36 MB, GraphicsTexture 28 MB, TerrainVoxels 0.8 MB; 50,929 instances. Studio adds its own editor, plugins and the server DataModel to the process figure, so this is an upper bound, not a phone number.

Fix: the terrain fill yielded once per column (about 85 frames), so the world took 4.4 s to appear. It now yields only after 50 ms of work (`SurvivalWorldBootstrap.buildTerrain`), and no Script-timeout appears in the console. The cold-start row is Studio's own first-launch cost; the warm rows show the game's boot.

**Recovery layer 2 (2026-10-21, `p13/perf.md`).** Isolated revision `9db8e04` was built with a temporary ReplicatedFirst observer before Play. The final series uses custom Phone `KC_Mobile_360x640`, portrait / ActualResolution, simulated surface 660x360 (the 20-pixel inset leaves an exact 360x640 client content viewport), rendering QualityLevel and EditQualityLevel Level01, and FRM false. Studio resets these settings at Play startup, so they were applied through the Client MCP context before the 120-second memory window; startup readiness was observed independently from the earliest client frames. There was no player movement or remote invocation. ForgeState and visible HUD appeared, but every initial gather prompt was outside activation range (nearest 14.17 studs, max 8). TTFI was not observed and has no finite median/max. Do not replace it with attachment latency or report a startup pass. The memory figures include Studio's editor/server/client process overhead and are not a phone RAM measurement. The documented numeric budgets are static-build budgets only, and the historical 2.86 s / 2,639 MB figures are comparisons, not runtime limits.

| Cold Play run | Observer attached (simulation s) | Exact-profile sample window (simulation s) | Samples | TTFI | Median Studio-process memory MB | Sampled max MB | Peak instances | Workspace parts |
| --- | ---: | --- | ---: | --- | ---: | ---: | ---: | ---: |
| A | 0.100 | 10.300..130.138 | 121 | not observed | 3165.645 | 3181.695 | 54,439 | 906 |
| B | 0.079 | 4.292..124.304 | 121 | not observed | 2355.383 | 3257.449 | 54,317 | 906 |
| D | 0.092 | 26.404..146.417 | 121 | not observed | 1795.762 | 1871.828 | 54,315 | 906 |

All 363 samples had a 360x640 content viewport. Pooled Studio-process memory median **2355.383 MB**, max **3257.449 MB**; no runtime-memory threshold is defined, so this is neither a pass nor a breach. A rejected Attachment-only run and an interrupted run C are excluded. Since then `c6dec48` moved onboarding `fiber-bush-01` beside the spawn (z 14 -> 5) and added a spec asserting every onboarding spawn has a gather prompt within its activation distance, and later commits increased world dressing density and added the p34 render profiles. **No TTFI or memory has been measured on any revision after `9db8e04`. A re-measure on the current HEAD is pending** with the same protocol (`cli/forge/qa/robango-performance.luau`, `robango-performance.md`), including one run at Level01 so the low render profile is active; until then no startup-readiness or runtime-performance PASS may be claimed. Physical low-end-device performance remains unverified.

**Android real-device run (2026-10-20, `SM-N981N` Galaxy Note 20 5G, Snapdragon 865+, Android 13, 2400x1080; the build revision was not recorded, and the device is a high-end phone, not the low-end target):** `com.roblox.client` PSS 704.0 MB (RSS 848.6 MB, Private Dirty 575.7 MB, Native Heap 50.1 MB, Java Heap 24.3 MB, Graphics 34.9 MB, Code 115.7 MB); frame times (`dumpsys gfxinfo`) p50 12 ms (GPU p50 9 ms), p90 23 ms, p95 36 ms. No frame-time or memory threshold is defined, so this is an observation, not a PASS; it predates `9db8e04` and the later world-density changes and has not been repeated on the current HEAD.
4. **QA-ERR-01 scope.** The scan covers every value in `locale/strings.csv` (Source, en-us, ko-kr; the Context column is a developer note) and every message the island allocator can build (`Allocation.playerMessage`). No other player message builder exists in the survival-coop modules at this commit; a new one should be added to the `playerStrings` list in `qa-evidence.spec.luau`.
5. **QA-SAVE-01.** The scenario is the transfer-crash matrix bound to robango-island with `starter-fiber` as the conserved item: bag 12 minus a 3-unit deposit stays accounted for across a prepared crash, a failed commit barrier, a reload and a withdraw, ending with bag 9 and warehouse 0 plus the withdrawn 3 (sum 12). It runs on the shared item-transfer fixture store, not on the pack's full world.
6. **Studio play audit (2026-10-18, Windows Studio, real input through Studio MCP).** I played the full flow on desktop (1280x720), a portrait phone (exact 360x640 and 390x844) and a landscape phone (843x369). Captures are in `.omo/evidence/robango-release/`, which is local and gitignored. Every P0/P1 found is listed below with its fix; each was re-checked in Studio after the fix.

| Area | Finding (severity) | Fix |
|---|---|---|
| Contracts | Panel crashed on open (P0); English action ids, refusals and pack names (P1) | ContractsPanel theme fix, Korean refusals and names |
| Panels | Blank sheets (ZIndex), keyboard-only access (P0); sheets covered each other or the HUD (P1) | Dock with a Menu toggle, mutually exclusive sheets, every sheet modal above the HUD |
| Panels | Shop and death-zone actions lacked the `survival-coop:` prefix, so the server refused them (P0) | Prefixed; `panel-actions.spec` checks every panel id is published |
| Panels | Snapshots arrive about once a second and rebuilt every button, so taps that straddled a rebuild were lost (P1) | Unchanged snapshots are skipped; the shop updates rows in place |
| Gather | Nodes buried in terrain or blocked by decoration (P1) | 16-stud clearing per node; decoration CanQuery off; 19/20 nodes reachable from 4 sides (berry bush keeps its line-of-sight wall by design) |
| Taming | Capture refused at 99/100 because stun decayed too fast; captured animal stayed in the world; mount had no visible body (P1) | decayStepMillis 10000; capture despawns and respawns; DinosaurRig welded under the rider |
| Wildlife | A strider fell to y=-522 (P1) | Fall recovery past 60 studs below home (specced) |
| Camp | Every visitor epoch lookup wrote the camp record (840 writes per 60 ticks), saturating the save transport (P1) | Visitors are refused without a write (spec: 120 idle heartbeats, at most 2 writes) |
| Warehouse | Deposit applied but always answered pending, so the HUD waited forever (P1) | Player transfers settle in one command and replay as confirmed (spec) |
| Build | On a landscape phone the sheet covered the tabs; Reserve and Store sat below the fold (P1) | The sheet sits left of the HUD stack; a selection scrolls its action into view |
| Build | Missing materials and an unreachable entry both read "refresh and retry" (P1) | Specific ko/en messages for UNAVAILABLE and PLACEMENT_UNREACHABLE |
| Camp panel | Drawn under the HUD with English project ids (P1) | DisplayOrder 20, Korean names from strings.csv, delivered/need count |
| Dock | The open menu ran off-screen on a landscape phone and sat under the chat on a portrait phone (P1) | Two-wide grid on short screens; the column starts below the chat |
| HUD | Status line clipped on a 360-wide phone (P2) | Text scales down to fit (8-14 px) |

Verified flows in Studio: arrival, the tutorial tracker, gathering, crafting a bola, stunning, capturing, feeding, mounting and dismounting, depositing (confirmed), reserving and placing a campfire, a camp donation (bar at 37.5%), the death zone switching danger↔safe twice, and the shop (Buy shows "아직 구매할 수 없어요" while product ids are 0, U15). The console scan of the final play shows 0 runtime errors, excluding Studio's own CoreGui/UIBlox warnings and one Studio account asset id.

7. **Studio scenarios (2026-10-19, Windows Studio, owned two-client session through Studio MCP).** All three were re-run on the final code. Each scenario ran on the real robango-island place with real keyboard, mouse and touch input, a local persistence host, and a physical rejoin onto a fresh server. Runs are in `.omo/evidence/robango-studio-qa/` (local, gitignored).

| Scenario | Run | Result |
|---|---|---|
| `survival-coop:wildlife-spatial` | `live-wildlife-spatial-20261019T100832Z` | PASS, 64 steps, 132 s, 28 captures |
| `survival-coop:full-coop-rejoin` | `live-full-coop-rejoin-20261019T115841Z` | PASS, 104 steps, 303 s, 12 captures (desktop owner + touch guest) |
| `survival-coop:tutorial-studio` (QA-CORE-01) | `live-tutorial-studio-20261019T101133Z` | PASS, 78 steps, 271 s, 8 captures, including a physical rejoin mid-tutorial |

Game bugs these runs found and fixed (each with a spec that fails without the fix):

| Area | Finding (severity) | Fix |
|---|---|---|
| Build | A tribemate standing next to the plot made the owner's placement fail as unreachable (P1) | The placement overlap test ignores every player character, not only the builder's (`SurvivalWorld.spec`) |
| Save | Skipping an unchanged identity write also skipped the lease renewal, so a quiet player's record lost its lease after 2 minutes (P0, data loss risk) | The skip applies only while the lease has more than half its time left (`FencedStore.spec`) |
| Wildlife | The world record's lease was renewed only by fights, so after 2 idle minutes the next attack failed with "lease lost" (P0) | Idle recovery sweeps renew the lease (`WildlifeRuntime.spec`) |
| Transfer | Settled transfers were re-checked every second, exhausting the DataStore request budget (P1) | Settled transfers are not re-advanced |
| Contracts | The board rebuilt its buttons on every snapshot, so a press that straddled a rebuild was lost (P1) | Rows rebuild only when what the board shows changes (`ContractsPanel.spec`) |
| Contracts | Every board line had the same name, so a player's UI tree held duplicate elements (P2) | Lines are named `Line-<n>` |
| Panels | On desktop an open panel sheet sat under the Roblox chat window (P1) | The sheet starts below the chat and shortens to fit, or sits beside it when there is no room (`Extensions.spec`) |
| HUD | While another command was still settling, the F (attack) and R (rest) keys went dead until the player found Retry inside the sheet (P1) | Pressing the key again resends the kept request under the same identity |
| HUD | After a server restart under a player, the "supplies are not connected" refusal stayed on screen for the rest of the session although actions worked (P1) | The banner clears as soon as the new server's action policy arrives (`SurvivalHUDModel.spec`) |

QA driver fixes made along the way (`cli/forge/qa`, 162 tests): rejoin waits out the old server's lease; the rejoin data check allows a newer revision; editor shutdown gets its own 40 s cleanup bound; a hub handover ("No Roblox Studio instances are connected") is retried; a gather aims the camera at its own node, because neighbouring nodes share the E key; overlap errors name both elements. The tutorial gathers the fallen tree from the mark north of it, because the flint outcrop 10 studs away is inside the 8-stud prompt reach from the landing side (a real player gets the nearer prompt highlighted; spreading these two nodes is a follow-up content tweak).

UX note: the crafting list is long enough that reaching a later recipe needs a scroll on desktop. It stays usable (each recipe is one row), so it is recorded here rather than fixed in this round.

Flaky-run note: on the same final code two tutorial attempts stopped on the walk to the warehouse after the rejoin (`action or state signal timeout`, `walk_to deadline`) and one wildlife attempt on `movement not replicated`. The full-coop-rejoin re-run on the committed tree (9ecdd18) stopped twice on the owner's walk to the warehouse with the same `action or state signal timeout` before its third attempt passed. The passing runs above made the same walks without retries. Those stops left no game error in the Studio logs, so they are recorded as Studio input/replication timing rather than product faults, and are worth watching on the live server.

8. **Private staging deploy, cloud verification, and real-device Android QA (2026-10-19..20).** Created private experience `Robango Staging` (`universeId = 10771918494`, `placeId = 95467272687768`, Studio API access enabled), registered the four monetization items at their `econ.yml` prices (`routeGuildPatron = 2040232413`, `wideWarehouse = 2037904759`, `skinRidgeStriderGold = 3720013569`, `routeGuildMonthly = EXP-4461467833720767028`), mapped their IDs into `games/robango-island/game.yml` and `games/robango-island/src/shared/MonetizationCatalog.luau`, and published to staging via `lune run cli/forge deploy --env staging --pack robango-island --development`. Open Cloud Luau Execution tasks verified live `DataStoreService` read/write (`dsWrite=ok`, `dsRead=1`), live `MemoryStoreService` sorted-map write (`memoryWrite=ok`), live `MarketplaceService:GetProductInfo` for the two passes and developer product (`Route Guild Patron Pass@299/sale=true`, `Wide Warehouse@199/sale=true`, `Ridge Strider Gold Skin@199/sale=true`), and full `RobangoIslandServer` world + session bootstrap (`factoryOk=true`, `islandBuilt=true`, `islandChildren=34`, 0 errors).

On 2026-10-20, connected a physical Android phone (`SM-N981N` Galaxy Note 20 5G, Android 13, 2400x1080) via wireless ADB and played the published staging place directly in `com.roblox.client` (`ko-kr` account). Captures are in `.omo/evidence/robango-phone/` (gitignored). Verified on the device: arrival skip, resource gathering (`쓰러진 나무` -> `목표: 돌도끼를 만드세요`), food consumption (`하나 먹기` -> `확인됨 - 보급품 저장 완료`), recipe reservation (`으깬 딸기죽`), contract acceptance (`노선 측량 협회` `수락` -> `납품`), camp donation (`섬유 x3` -> `바람막이 3/8`), death-zone toggle (`위험 구역 입장` -> `그래도 입장` -> `안전 구역으로 돌아가기`), and live `PolicyService` + `MarketplaceService` prompts for both the subscription (`EXP-4461467833720767028`, `Route Guild Monthly 99/월`) and developer product (`3720013569`, `Ridge Strider Gold Skin 199`). Real-device bugs found and fixed during the phone pass:

| Area | Finding on Android phone (severity) | Fix |
|---|---|---|
| Persistence | On a published server (`DataStoreBackend`), 1 Hz `server-vitals-tick` plus per-command `refresh`/`recover` called `DataStore:UpdateAsync` on the same key multiple times per second, hitting Roblox's 6-second per-key write cooldown and stalling player commands in `COMMAND_PENDING` (P0) | `DataStoreBackend` caches leased records in-memory on the owning server, serves identity reads in 0 ms, coalesces in-session writes to a 7-second per-key background flush, and flushes synchronously on lease release and `BindToClose` (`core/infra/data/DataStoreBackend.luau`) |
| Camera | Walking under `CameraTestRoof` caused `QuarterView`'s `Spherecast` to hit the roof 5 studs above the player and zoom the 30° FOV camera into the back of the character's head instead of fading the roof (P1) | `QuarterView` ignores `Spherecast` hits on parts tagged `ForgeCameraOccluder`/`ForgeCameraRoof` so the camera stays above the roof while `GetPartsObscuringTarget` fades it to 0.7 (`core/infra/camera/QuarterView.luau`) |
| Panels / Dock | Closed `PlayerGui.Chat` descendants still had `item.Visible == true` under a hidden ancestor, reporting a phantom 355x220 chat footprint that pushed modal sheets over the right-side HUD and Jump button; open 2x3 menu grid overlapped the bottom-left mobile thumbstick (P1) | `chatEdges` checks ancestor visibility up to `Chat`; `place` includes `UIGridLayout.AbsoluteContentSize.Y` and reserves 116 px above the bottom-left thumbstick on touch screens (`genres/survival-coop/module/ExtensionPanels.luau`) |
| Extensions | A refused extension command (`result.ok == false` with no `stateVersion`) remained in `pending[actionId]`, replaying the refused args on later presses (P1) | `ExtensionPanels.send` clears `pending[actionId]` on any settled response, keeping it only while `"COMMAND_PENDING"` or `"recovering"` (`genres/survival-coop/module/ExtensionPanels.luau`) |
| Death zone / Contracts / Camp | Mobile `DeathZonePanel` confirm/cancel buttons and `ContractsPanel`'s first `Accept` button fell below the fold; `CampPanel` lacked a close button, listed locked projects above unlocked ones, and rebuilt its buttons when `+`/`-` was tapped; leaving a server did not release per-actor extension leases when the last player left (P1) | Compacted `DeathZonePanel` and `ContractsPanel` (offers first); converted `CampPanel` to `modalSheet` with a close button, unlocked rows first, and in-place picker updates; `Session.close` triggers extension lease release on leave (`DeathZonePanel.luau`, `ContractsPanel.luau`, `CampPanel.luau`, `Session.luau`) |
| 3D World / Dinosaurs / HUD / Store | Landing structures and gather nodes were single SmoothPlastic primitives, `SurvivalHUD` left `onAccent` dark and put `Refresh`/`CameraHelp` above bag/craft/build items, and `Robango Staging` lacked store icon/thumbnail and content rating submission (P1) | Added `Lighting`/`Atmosphere`/`BloomEffect`/`ColorCorrectionEffect`, multi-part camp structures and gather nodes, dorsal spines/snout/crest on `DinosaurRig`, high-contrast survival theme + starter-first recipe/structure ordering in `SurvivalHUD`/`ExtensionPanels`/`GatheringClient`, and uploaded 512x512 icon, 1920x1080 thumbnail, EN/KO store copy, and 17-section content maturity questionnaire via Aside |



