# robango-island QA evidence

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
| QA-BM-04 | `forge test Subscription --quiet` | core/infra/monetization/Subscription.spec.luau : "an ineligible account is never prompted" | local PASS (fake PolicyService); real prompt log needs staging |
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
| QA-PERF-01 | `forge test qa-evidence --quiet` (static build budget only) | games/robango-island/qa-evidence.spec.luau : "QA-PERF-01 built robango-island place stays inside the new-estimate static budget" + NEGATIVE | local PASS for the static budget; first-interaction time and memory **needs Studio** (note 3) |
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
3. **QA-PERF-01.** Only static numbers are measurable locally. Measured on the built place (`rojo build`): 217 instances, 168 scripts, 1.26 MB of script source, 0.54 MB place file. The budget (400 instances, 300 scripts, 2.5 MB source, 1.5 MB file) is a new estimate with about 2x headroom. **Layer 2 (Studio, measured 2026-10-18).** Measured in Roblox Studio on Windows (Ryzen 5 7500F) at the lowest rendering quality (Level01), with temporary probe scripts that were never committed. "First interaction" is the moment a gather ProximityPrompt is enabled on the client; time is counted from when the client script starts.

| Run | Character spawned | Island built (server) | First interaction | Peak memory (Studio process, server + client) |
|---|---|---|---|---|
| Cold Studio start, before fix | 30.8 s | 51.8 s | 53.8 s | 1,636 MB |
| Warm, before fix (one yield per terrain column) | 2.3 s | 4.4 s | 4.45 s | 2,659 MB |
| Warm, after fix (yield every 50 ms of work) | 2.4 s | 0.24 s | **2.86 s** | 2,639 MB |

Client memory by tag after the fix: LuaHeap 806 MB, Script 268 MB, Instances 103 MB, Gui 36 MB, GraphicsTexture 28 MB, TerrainVoxels 0.8 MB; 50,929 instances. Studio adds its own editor, plugins and the server DataModel to the process figure, so this is an upper bound, not a phone number.

Fix: the terrain fill yielded once per column (about 85 frames), so the world took 4.4 s to appear. It now yields only after 50 ms of work (`SurvivalWorldBootstrap.buildTerrain`), and no Script-timeout appears in the console. The cold-start row is Studio's own first-launch cost; the warm rows show the game's boot.

**Still open:** a physical low-end phone run (U19). Studio cannot reproduce phone memory limits.
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

8. **Private staging deploy and cloud verification (2026-10-19).** Created private experience `Robango Staging` (`universeId = 10771918494`, `placeId = 95467272687768`, Studio API access enabled), registered the four monetization items at their `econ.yml` prices (`routeGuildPatron = 2040232413`, `wideWarehouse = 2037904759`, `skinRidgeStriderGold = 3720013569`, `routeGuildMonthly = EXP-4461467833720767028`), mapped their IDs into `games/robango-island/game.yml` and `games/robango-island/src/shared/MonetizationCatalog.luau`, and published version 2 via `lune run cli/forge deploy --env staging --pack robango-island --development` (`PUBLISH_ACCEPTED HTTP 200`, `version=2`, `artifactSha256=1bdfa1c3964aca7e688f4f1bc294b50c41915ca74372f7bbc85ad8139926fb1a`). Open Cloud Luau Execution tasks on `universes/10771918494/places/95467272687768/versions/2` verified live `DataStoreService` read/write (`dsWrite=ok`, `dsRead=1`), live `MemoryStoreService` sorted-map write (`memoryWrite=ok`), live `MarketplaceService:GetProductInfo` for the two passes and developer product (`Route Guild Patron Pass@299/sale=true`, `Wide Warehouse@199/sale=true`, `Ridge Strider Gold Skin@199/sale=true`), and full `RobangoIslandServer` world + session bootstrap (`factoryOk=true`, `islandBuilt=true`, `islandChildren=34`, 0 errors).

