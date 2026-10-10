# Consolidated verification preflight

Status: PREPARATION ONLY. No command below was executed for this document. This
is not Task 16 acceptance, a frozen source inventory, a release verdict, or final
review. Authored receipts and historical test totals are not current QA.

## Execution barrier and intake

Do not run validation while implementation workers are active. The coordinator
must obtain final path lists and handoffs for Tasks 1-15, reconcile generated
Primal output, complete any formatting repairs, and record a settled source map
before opening the consolidated run. Task 16 depends directly on Tasks 7-15;
their upstream Tasks 1-6 remain part of the same barrier. Re-enumerate filenames
after the last handoff: the list below is provisional, not a cap on discovery.

Keep four separate result classes: source/fixture checks; original actual Studio
QA; independent reference and audiovisual evaluation; external operational pilot.
Passing one class cannot fill a missing row in another. A failed or unavailable
required row is BLOCKED, never a green skipped test. No fixed target/test count is
an acceptance condition. Implementation completion is distinct from acceptance:
unavailable Touch, listening, independent reference or external pilot proof must
not postpone independent local checks after source authoring has settled. Record
an executed regression failure as FAIL; an unavailable/unauthorized live row is
BLOCKED with its reason. Neither is a successful skip.

Latest handoff: Tasks 6 and 14 release final ownership, Task 13 is released, and
Task 3/9/15 repairs are settled. Remaining source barrier is Task 11/native/AV
and Task 7 final intake only. Final test enumeration waits for native source
completion; no count gate applies. These source edits, not
the availability of all live acceptance proofs, keep execution closed now.

### Single-run order after final implementation handoffs

1. Run the safe three-path Primal refresh with independent complete pre/post
   pack manifests and preservation checks described below. This precedes the
   first full check and any archive freeze.
2. Reconcile final source/license paths, media origins, changelog/root selection
   and sanitized public documents. Capture and freeze the source/inventory map;
   re-enumerate test filenames once against that settled map.
3. Obtain diagnostics before building, then run the aggregate check once,
   explicit JavaScript suites, conditional native configure/build, and planned
   negative/generation/generalization fixtures. Keep independent per-row and
   per-target outcomes. If diagnostics/checks require repairs, reopen the
   affected authoring boundary, recapture changed inputs and rerun only justified
   affected checks; never retain a stale verified freeze.
4. Assemble the immutable candidate pair from the verified captured map, prove
   determinism and rights/extraction preservation, then run the fresh-consumer
   procedures. Distinguish blocked fresh installation from consumer behavior
   exercised with explicitly declared preinstalled tools.
5. Run actual permitted Studio QA serially, with the owned local persistent
   host outside the editor Job, current identity, original evidence and observed
   cleanup. Attempt only available authorized routes. Record unavailable Touch,
   listening/reference and external pilot rows separately without delaying or
   invalidating completed independent checks. They still block full acceptance.

No step in this sequence is authorized for execution by this preflight update.

All commands use the repository or extracted consumer root as working directory.
Use a newly allocated owned directory beneath the process TEMP directory for
disposable source copies, credentials-free profiles, fixture databases and
extraction. Reject preexisting fixture names. Record ownership before allocation;
save original logs and hashes outside disposable copies before cleanup. Never
alter the real pack to produce a negative test. Do not copy user caches, auth
files, editor sessions or inherited cloud/provider secrets into a consumer.

Local loopback fixture requests to an owned 127.0.0.1 server are allowed in the
eventual local validation run. They do not authorize Open Cloud, DataStore,
uploads, publishing, provider evaluation or any other external write. In
particular, Studio `studio-datastore` mode remains prohibited under local-only
authorization. Read-only tool/definitions downloads are a distinct dependency,
not an offline guarantee. No install or server launch occurs during preflight.

## Tools and discovery

`rokit.toml` pins Lune 0.10.5, Rojo 7.7.0, Selene 0.31.0, StyLua 2.5.2,
luau-lsp 1.70.1 and Wally 0.3.2. Read-only filesystem inspection found each
pinned executable in Rokit storage, plus PATH entries for Rokit, Bun, Node,
Windows PowerShell, PowerShell 7, CMake, FFmpeg and ffprobe. `cl` was not on the
inspected PATH; this does not establish that Visual Studio is absent. No binary
was invoked and no binary version or compatibility was verified. Record actual
versions and executable digests when the barrier opens. Bun is required by
`bun:test`, `Bun.serve` and the new `bun:sqlite` host, not interchangeable with
Node. The existing quality suites use `node:test` and have separate commands.

`cli/forge/commands/check.luau` runs genre/QA schema, Selene, StyLua check,
Roblox per-pack and standard-platform CLI LSP, econ/game/assets/locale/lock,
child `specs-run`, then independently builds and inspects every selected pack.
`--pack` or `--packs-root` selects build targets, not all other check stages.
It does not discover JavaScript tests or compile native recorder helpers.
`cli/forge/lib/specs.luau` precompiles `.luau` sources and discovers only
`*.spec.luau` recursively under core, games, cli and genres.

The definitions cache is `build/cache/globalTypes.d.luau`, fetched from the
luau-lsp 1.70.1 `scripts/globalTypes.d.luau` URL if missing or invalid, with
SHA-256 `2857efa8245485f8c25c19c018ee1ef9b46afab4efd2ea70fc3257cd3faf7080`.
The eight-case historical harness requires this already verified cache and
does not download it. Do not call a clean consumer network-free.

## Exact command matrix

Each invocation needs its own stdout, stderr, exit code, start/end interval,
source/config/assets/build hashes and cleanup result. Run the aggregate once
after repairs, not separate duplicate lint/spec/build passes. A later source
change or failure justifies affected reruns and a new source binding.

| Row | Actual invocation | Required result and boundary |
| --- | --- | --- |
| L | `lune run cli/forge check --all` | Exit 0; retain every stage and each target's build/inspect result, output and digest. No fixed historical 1297/four-pack count. |
| G | `lune run .omo/evidence/generalization-proof --build` | Run in disposable source copy containing the historical harness and its four helper modules; eight named generated cases below. Preserve new receipt separately. |
| C1 | `rokit install --no-trust-check` | Only after reviewed pins, actual bootstrap version/source contract and clean manifest discovery. Child-only empty owned ROKIT_ROOT isolates storage/auth, not Windows home discovery. Record downloads/versions; no invocation now. |
| C2 | `lune run cli/forge new consumer-island --genre collect-raid` | Fresh extracted consumer; assert destination absent first. |
| C3 | `lune run cli/forge plan --concept "Defend ancient groves" --genre survival-coop --pack consumer-grove --seed 42` | Same consumer, exact deterministic parameters. |
| C4 | `lune run cli/forge build --pack consumer-island` | Fresh place and embedded identity/sidecar, not old output. |
| C5 | `lune run cli/forge check --all` | Extracted consumer exit 0, including generated consumer packs; original shipped-file changes accounted separately. |
| U1 | `lune run cli/forge --help` | Existing CLI returns nonzero usage; do not require help exit 0. |
| U2 | `lune run cli/forge unknown-cmd` | Nonzero actionable usage, no writes or secret disclosure. |
| P | `lune run cli/release/package --out build/forge-release.zip` | Only after verified authorized commits, clean recorded shipped source and frozen rights inventory. Not a dirty-tree candidate command. |
| P2 | `lune run cli/release/package --out build/forge-repeat.zip` | Optional final committed reproducibility pair; fresh names required. Candidate determinism is tested before commits as below. |

The source preparation/extraction procedures below deliberately use library
APIs; there is no `--candidate`, `--freeze`, `--refresh` or `--offline` CLI flag.
Do not invent one or run the production archive CLI to bypass its clean-HEAD
contract. Git mutation remains outside this preparation.

### JavaScript tests omitted by Lune discovery

Execute every current row after the barrier. These are separate invocations so
each suite retains its own exit, not one last-exit-wins shell command. They are
the currently observed filenames, not a count gate. Add later test handoffs and
re-enumerate once after source freeze before execution. Do not run a
`.fixture.mjs` as a standalone test.

```text
bun test cli/forge/lib/opencloud-transport.spec.mjs
node --test cli/forge/lib/qualityav.spec.mjs
node --test cli/forge/lib/qualityjudge.spec.mjs
bun test cli/forge/qa/studio-driver.test.mjs
bun test cli/forge/qa/studio-driver-gameplay.test.mjs
bun test cli/forge/qa/studio-driver-input.test.mjs
bun test cli/forge/qa/studio-driver-lifecycle.test.mjs
bun test cli/forge/qa/studio-driver-process.test.mjs
bun test cli/forge/qa/studio-driver-rejoin.test.mjs
bun test cli/forge/qa/studio-driver-session.test.mjs
bun test cli/forge/qa/studio-driver-surface.test.mjs
bun test cli/forge/qa/studio-driver-wildlife.test.mjs
bun test cli/release/capacity-collector.test.mjs
bun test cli/release/capacity-persistence.test.mjs
bun test cli/release/capacity-workload.test.mjs
bun test cli/release/capacity-recovery.test.mjs
bun test cli/release/local-persistence-host.test.mjs
```

The Node suites currently use fixture/fake subprocess coverage, not actual
listening or decoder execution. The Studio helper tests likewise do not prove
real owned launch, touch, registration, recording or cleanup. Re-read imports
at final intake if the owner changes the runner. `studio-driver-contention.mjs`
currently has no standalone test filename; driver coverage is not permission to
omit a later adjacent suite.

Late inspected Bun suites cover application-state replay conservation, overflow
refusal and immutable transfer binding (capacity-persistence), and missing
measured backend identity or empty transitions before evidence writes (rejoin).
They are authored fixtures, not executed live crash evidence.

### Required Lune suites and real subprocess cases

Row L must include `genregenerate.spec.luau`, `genrepublish.spec.luau`,
`genrecontract.spec.luau`, `craftinggenerate.spec.luau`, `buildidentity.spec.luau`,
`buildtargets.spec.luau`, `cli/release/package.spec.luau`,
`core/infra/data/Compatibility.spec.luau`, `ProfileStore.spec.luau`, existing
fencing/transfer/budget specs, capture/receipt/evaluator/gate/deploy specs,
`opencloud.spec.luau`, `opencloud-process.spec.luau`,
`cli/forge/commands/deploy-transport.spec.luau`, liveops/report specs and
`cli/release/capacity.spec.luau`. Final discovery must also include new backend
and dedicated rejoin/epoch specs as their owners deliver them.

Late intake confirms `core/infra/data/LoopbackBackend.spec.luau`,
`ObservedBackend.spec.luau` and `RuntimeBackend.spec.luau` are present under
the recursive `core` spec root. They are included by Row L without an extra
command. Task 7 now provisionally covers their first-party source and the local
host/PersistenceConfig; this is not a freeze. `qualityreceipt.spec.luau` now
contains `whole test rejoin requires one transition per actor on every epoch
edge`: the document has a flat transitions array with one unique actor per
adjacent epoch edge, not one transition per whole test. Missing/duplicate actor
transitions and changed mapping must reject. Re-read final settled schema before
binding producer output. The new `studio-driver-rejoin.test.mjs` is listed above;
owner-final intake still covers later additions.

`opencloud-process.spec.luau` starts the actual owned
`cli/forge/lib/opencloud-process.fixture.mjs` through Bun. READY follows stdin
EOF; the parent triggers the deadline only after observing READY. Require exit
status, stdout/stderr EOF and closed stdin, not helper-only success. The
production watchdog is 35 seconds with a 5-second bounded reap; kill/reap/pipe
failure must retain residual ownership. Its pipe fixture has an owned loopback
handle, not an external request. The explicit native-fetch JS suite above remains
required. Contradictory provider `error`/`errors` plus version must reject;
benign extra place metadata is intentionally allowed.

The settled authored `genrepublish.spec.luau` interruption matrix starts actual
Lune children with READY/GO before work and stdout BARRIER before termination,
then restarts recovery in a separate process. Publication cases cover `owned`,
`backed-up`, `journal-staged`, `journal-installed`, each of three `replaced`
indices (including a new file), `complete-staged`, `complete`, `cleanup-marked`,
`cleanup-removed` and `cleanup-finished`. Recovery cases first kill publication
after replacement 3, then kill at `restore-staged` for old-file indices 1/3,
`restored` indices 1/2/3 (including new-file deletion),
`recovery-complete-staged`, `recovery-complete`, and the three cleanup events.
Restart asserts exact prior rollback or retained completed revision, new-file
presence/absence, unchanged user bytes and cleared markers. Reader admission
remains pending until final cleanup. Destination-bound `.forge-backup` cleanup
ownership survives recursive stage removal; forged/mismatched ownership refuses.
All cases remain unrun and included through Row L, behind Task 6/11/runtime and
the global authoring barrier. These are explicit between-operation barriers,
not termination inside a filesystem syscall, power-loss durability or atomic
whole-pack publication proof.

Compatibility specs terminate distinct processes at ESCROWED, CREDITED and
FINALIZED durable-before-ACK barriers, then replay from serialized storage.
Verify source/destination quantities, exactly-once replay, higher fencing epoch,
future-schema refusal and process reaping. Local JSON subprocess evidence is
not actual Studio persistent rejoin, live crash or Roblox service evidence.

## Per-target negative fixture

The existing buildtargets spec named `check --packs-root fails the malformed
pack and still verifies the valid one` calls `resolveTargets/runTargets`, not
the complete CLI. Keep that spec, and execute one real negative CLI in a
disposable source copy after its positive aggregate. The unproven requirement is
that CLI selector parsing reaches every selected target, command-level failure
aggregation does not short-circuit the good sibling, and the top-level process
exits nonzero despite that sibling's success. Use these exact fixture
files, authored with apply_patch only in that copy:

```text
build/task16-negative/good/game.yml: name: Task16 Good
build/task16-negative/good/default.project.json:
{"name":"Task16Good","tree":{"$className":"DataModel","ServerScriptService":{"Main":{"$path":"src/Main.server.luau"}}}}
build/task16-negative/good/src/Main.server.luau: print("task16 owned fixture")
build/task16-negative/broken/game.yml: name: Task16 Broken
build/task16-negative/broken/default.project.json:
{"name":"Task16Broken","tree":{"$className":"DataModel","ServerScriptService":{"Missing":{"$path":"missing.server.luau"}}}}
build/task16-negative/partial/game.yml: name: Task16 Partial
```

Run `lune run cli/forge check --all --packs-root build/task16-negative`.
Require nonzero overall exit, partial declaration error, broken build FAIL with
inspect SKIPPED, and good build/inspect PASS with its own fresh digest. A failure
in an earlier check stage does not excuse missing target rows. Preserve all
output. The existing stale-artifact spec proves removal before failed rebuild;
do not seed stale files in the real build directory. Clean only owned fixtures
after evidence is durable.

## Generation, preservation and eight generalization cases

In a disposable source copy, run the following exact plan command once per
genre, replacing only the two occurrences of the loop variable through normal
PowerShell argument expansion:

```powershell
$genres = @('collect-raid','grow-harvest','survival-coop','rpg-progression','social-rp-fashion','pvp-arena')
foreach ($genre in $genres) {
  & lune run cli/forge plan --concept 'Crystal island explorers' --genre $genre --pack "release-task3-$genre" --seed 7
  if ($LASTEXITCODE -ne 0) { throw "Generation failed: $genre" }
}
```

Capture each complete relative path/SHA-256 map, repeat the identical command
at the same destination, and require equality. For five nonlegacy starters,
edit only the authored body of `src/server/GenreHooks.luau`, retain its
`forge-hooks:1:<genre>` marker and hook map, regenerate, and compare exact hook
bytes. For collect-raid preserve a task-owned extra file instead. Run
`lune run cli/forge smoke --pack release-task3-<genre>` with each actual slug,
then one `lune run cli/forge check --all` for this six-starter disposable copy,
not six repeated repository-wide checks. Invalid seed `nan`, missing genre and
hook version 99 must refuse without changing the prior tree. Snapshot after
the intentional invalid-marker edit so that edit is not miscounted as drift.

Row G exercises collect-raid, grow-harvest, survival-coop, rpg-progression,
pvp-arena, social-rp-fashion, filesystem-only fixture-counter, and composed
grow-harvest/survival-coop. Helpers are `generalization-proof-build.luau`,
`generalization-proof-qa.luau`, `generalization-counter-generator.luau` and
`generalization-counter-runtime.luau` beside the harness. It also checks actual
new/plan callers, invalid selections/catalogs and emitted gameplay. Its output
overwrites `.omo/evidence/generalization-proof.md` and removes its temporary
tree even after failure: run only in the owned copy, preserve original outer
stdout/stderr and collect failure artifacts before cleanup if needed. The
historical helper's direct Rojo lane is not proof of new embedded identity;
Row L owns current all-pack identity/sidecar inspection.

Primal refresh now uses `lune run cli/release/refresh-primal-consumer` from the
worktree root after the authoring barrier. This supersedes blanket assembly.
The inspected helper loads actual econ.yml and existing WorldConfig, calls
crafting.render, and passes a selected map as the sixth publish.write argument.
It preserves nodes/origin/keys/config and adds warehousePosition only if absent.
Only SurvivalProvision.luau, SurvivalFactory.luau and SurvivalWorldConfig.luau
may differ; unchanged GenreHooks is included solely as an ownership guard.

Before the first full check and before any verified archive freeze, capture a
complete relative-path/byte-hash manifest of the pack, execute this helper, then
capture a second complete manifest independently. Require every path outside
those three and GenreHooks bytes unchanged, with no extra or missing files.
Verify actual selected-publication argument support and journal behavior;
the helper's printed three-file claim is not evidence. First demonstrate this
preservation in an owned copy. No blanket media/assets codegen or generated
hand edits. Rendering/formatting and the helper remain unexecuted now.

Publication is per-file journaled replacement with restart rollback, not atomic
whole-pack replacement or power-loss fsync. Any `.forge-stage`/`.forge-backup`
file or directory blocks consumers. Stop writers/readers before explicit
recovery; never delete an unowned marker to make a check pass.

## Immutable candidate and fresh consumer

After final source intake, collect selected ordinary files as `{path, bytes}`,
reject symlinks/case collisions, and call `package.assertNoPublication(root)`
before and after capture. Load package with the exact `luau.load(...)("module")`
pattern and explicit require mapping in `cli/release/package.spec.luau`;
ordinary require would execute its CLI. Use these actual library calls:

```luau
local frozen, unknown = packageModule.freezeInventory(entries, policy)
assert(#unknown == 0, table.concat(unknown, ", "))
-- Replace only the inventory entry in this captured map with:
-- packageModule.canonical(frozen) .. "\n"
local candidate = packageModule.captureCandidate(entries, baselineRevision)
local zipA, manifestA = packageModule.assembleCandidate(candidate)
local zipB, manifestB = packageModule.assembleCandidate(candidate)
assert(zipA == zipB and manifestA == manifestB)
```

This is the invocation contract for the coordinator's owned harness, not a claim
that a separate candidate CLI/harness already exists. `baselineRevision` is the
actual 40/64-hex revision captured at execution, not a made-up clean revision.
Persist the unknown-path list with reasons before refusing; final intake includes
this document and all late native/host/epoch source, tests and build files.
Do not freeze live worker files. Inventory self-hash is excluded only from its
own `files`; the outer manifest hashes the inventory. Candidate state is
`immutable-candidate-not-committed`, binding full captured bytes. The production
CLI later reads immutable committed Git blobs and rejects dirty/unrecorded
shipped content. Compare candidate/final content maps, not whole ZIP hashes
across changed revision metadata.

Compare every current media byte against its existing approved assetRecords
SHA and its origin Git blob from the recorded commit; capture path/hash/origin
as individual results. There are 36 historical Kaiju/plan-demo media records,
plus the separately recorded Primal WAV. Historical fingerprints are not
generation receipts. Do not update an approved media hash just to pass. Inspect
third-party notices/redistribution grants, exact pinned upstream license basis,
and source scope coverage. Unknown rights block the archive.

Extract both candidate archives using an independent ZIP reader into new owned
directories. Verify safe paths, no collisions, sorted entries/fixed metadata,
binary preservation, every manifest length/hash and all notices. An excluded
secret/scratch sentinel in a disposable candidate source must appear in neither
entry names nor bytes. Inject extraction/write failure and retain failure
evidence before removing only owned fresh outputs. Existing outputs must survive.

Run C1-C5 from extraction, with no `.git` directory, owner paths or copied caches.
Follow the source-backed procedure in install.md: `ROKIT_ROOT` isolates storage,
cache, aliases and auth, but install still discovers every ancestor manifest and
real Windows known-folder home `.rokit`/`.aftman`/`.foreman` declarations.
Fake HOME/USERPROFILE does not isolate that discovery. Inspect those locations
without modifying user manifests; any additional discovered declaration blocks
strict fresh installation. Use the recorded bootstrap explicitly, an empty owned
ROKIT_ROOT and sanitized allowlisted child PATH/environment without developer
cache fallback or credentials. Empty child USERPROFILE only disables Forge's
own fallback probe, not Rokit's known-folder search. No account creation,
self-install/update, registry/PATH mutation or invented ROKIT_HOME.
The inspected source commit c8f279983046739d3a80a2d5fe976da08d26add7 declares
Cargo 1.2.0; installed Rokit version/behavior remains unverified. Match it before
using the source-backed install flag. If clean discovery is unavailable, report
extracted-consumer behavior with explicitly declared preinstalled tools separately
from BLOCKED fresh installation. Build revision may read `unknown` without Git; archive manifest
and source digests must still bind the consumer. Record download provenance and
verify no parent-worktree dependency. Missing-tool/unsupported-runtime probes
use an owned launcher environment with only the selected tool absent, never
rename installed binaries. An actionable nonzero error must precede writes.

## Actual QA rows and blockers

After launch authorization, current schema discovery, owned background launch
and a current build identity are ready, the actual commands are:

```text
lune run cli/forge qa run --pack primal-isles --scenario release-first-play --studio --studio-receipt .omo/evidence/forge-production-release/task-6-discovery.json --evidence .omo/evidence/forge-production-release/task-13-first-play.json
lune run cli/forge qa run --pack primal-isles --scenario release-rejoin --studio --studio-receipt .omo/evidence/forge-production-release/task-6-discovery.json --evidence .omo/evidence/forge-production-release/task-13-rejoin.json
lune run cli/release/capacity --pack primal-isles --players 8 --out .omo/evidence/forge-production-release/task-14-capacity.json
lune run cli/release/capacity --pack primal-isles --players 8 --recovery transfer --out .omo/evidence/forge-production-release/task-14-transfer-recovery.json
```

Task 14's final released transfer integration supersedes older missing-envelope
and pending-export notes. Following owned crash and distinct replacement
actor/backend admission, it sends the exact observed original command envelope
unchanged through authenticated replacement ingress; neither request ID nor
epoch is rewritten. Stale-epoch rejection is command replay rejection, not
recovery success. Independently require persisted source FINALIZED receipt and
stateVersion, destination CREDITED receipt with exact immutable binding,
inventory plus uncredited-escrow ownership conservation and stable application
readback. Missing terminal proof remains BLOCKED. No producer callback/export
handoff remains pending. Actual startup lease barriers, lawful cap saturation
and throttle classification/proof remain unavailable or unmeasured live rows,
alongside Touch/listening/reference/pilot; they must not be inferred from this
authored transfer route. Neither capacity command has run.

`task-6-discovery.json` is a planned output from actual discovery, not an existing
capability claim. Its `driver` requires actual transport command/args,
`editor.executable`, ownershipToken, buildPath, packDir and runtime identity;
do not copy historical IDs/tokens or publish local absolute paths. Capacity
reads `FORGE_CAPACITY_DRIVER` as a private JSON config path. No driver means a
nonzero missing-proof report; `--evidence` capacity intake is not a live run.
Serialize first-play/rejoin/capacity against owned Studio resources.

The newly authored local backend can be launched eventually with
`bun cli/release/local-persistence-host.mjs`; it consumes `FORGE_LOCAL_DB`,
`FORGE_LOCAL_TOKEN` (fresh 64-hex secret), `FORGE_LOCAL_NAMESPACE` (1-32 lowercase
alphanumeric/hyphen), and `FORGE_LOCAL_PORT` (0 for an ephemeral port, or integer
1024-65535). Set them only
in the owned child's environment, use a fresh owned SQLite path and exclusive
loopback port, and never log the token. Start/ready/stop integration and actual
Studio bridge/restart proof await the Task 9 handoff. Its current SQLite reopen
unit test does not itself establish a killed-process recovery or HTTP bridge.
The current suite now authors real loopback HTTP cases: missing/wrong auth 403,
foreign namespace 400, malformed JSON 503, oversized CAS value 400, concurrent
same-revision writes yielding one 200 and one 409, exact winner readback and
stale-CAS refusal. It uses port 0, checks listening/hostname, bounds fetch with
AbortSignal, and stops/removes owned state in finally. These are source
assertions, not executed HTTP or crash proof. No npm install or bundled binary is needed
for Bun's SQLite/HTTP builtins. Task 6 owns READY/start/ownership configuration
integration; a source-only direct `openStore` close/reopen is not crash proof.

Require original desktop/mobile captures with measured device/logical/safe-area
and decoded raster geometry, schema2 receipts, schema1 loaded server/two-client
handshakes, actual action/session/revision ordering and no mutation shortcuts.
Observe multiple angles, UI overlap, cooperative conserved quantities, natural
wildlife failure/recovery and original refusal evidence. Mouse Activated or
keyboard controls on portrait dimensions do not prove genuine Touch or
uncoached discovery. Genuine Touch is unavailable in the inspected MCP schema;
retain that blocker until an actual supported product route is delivered.

Rejoin needs distinct old/new actor connection epochs, observed old process exit,
same profile/backend namespace, durable committed/load revisions and retained
item IDs/quantities. Memory restore is not rejoin. Capacity needs eight actual
clients, actual workload and NPC count, per-client frame p50/p95, memory,
complete serialized payloads, budget/throttle and commit latency. Require p95
<=33.3 ms for every client, bounded payloads, no unhandled throttle and conserved
state. No extrapolated lower or multi-server envelope. Live crash requires
currently held/unexpired commit or lease ticket, exact owned termination,
durable-before-ACK evidence and distinct restart/replay; synthetic callbacks and
old expired tickets are not authority.

Native acquisition is a separate pending intake owned by Task 11's native child.
Existing `cli/forge/tools/ForgeQAAudio.cs` and `capture-audio.ps1` record the
default endpoint whole mix, not an identity-bound muxed process recording.
They cannot satisfy the new requirement by themselves. No maintained new native
build source/config was present at initial intake. A later read found
`cli/forge/native/qualityav-capture/CMakeLists.txt`: CMake >=3.21, C++20,
Windows SDK/C++/WinRT, WASAPI, Windows.Graphics.Capture and Media Foundation;
system libraries only. Its exact listed translation units are `src/main.cpp`,
`session.cpp`, `process_identity.cpp`, `qpc_clock.cpp`, `audio_capture.cpp`,
`video_capture.cpp` and `mux_writer.cpp`. Several are still being authored.
Once all sources and an x64 Windows SDK/MSVC environment are delivered, the
source-backed planned configure/build commands are:

```text
cmake -S cli/forge/native/qualityav-capture -B build/task16-qualityav-native -G "Visual Studio 17 2022" -A x64 -DCMAKE_SYSTEM_VERSION=10.0.26100.0
cmake --build build/task16-qualityav-native --config Release
```

Read-only native capability follow-up found Visual Studio 2022 BuildTools,
MSVC storage/default version 14.44.35207, actual Hostx64/x64 `cl.exe` and
`link.exe`, `VsDevCmd.bat`, and the Visual Studio CMake executable with
`cmake-3.31` support directory. Both SDK 10.0.26100.0 and 10.0.28000.0 contain
the inspected audio activation, C++/WinRT capture and HWND interop headers and
x64 mmdevapi/mfreadwrite/windowsapp libraries. The inspected activation header
guards process loopback with `NTDDI_VERSION >= NTDDI_WIN10_FE`; CMake explicitly
defines `NTDDI_VERSION=0x0A00000A`. Configure pins the observed 10.0.26100.0 SDK
and x64 Visual Studio generator rather than relying on PATH compiler selection.
Use the inspected Visual Studio CMake executable if PATH CMake is unsuitable;
resolve its local installation privately. No binary version probe, environment
activation, compile or link has run. Filesystem presence removes an asserted
missing-install claim, not the unverified toolchain/capture row. If final
compiler/SDK capability fails, record the missing component and block this row;
no automatic download or installation is authorized.

Record the actual selected generator/compiler/SDK; PATH CMake presence is not
proof it selects a compatible compiler. Native owner must confirm final command
and source list before this conditional row can run. Compilation is not capture
or listening QA. Do not call a decoder to infer listening. Existing FFmpeg presence
does not prove owned source, synchronization, actual delivery to an evaluator,
listening or temporal observations.

No researched reference jointly established independently authored full-loop
Roblox gameplay, immutable source and complete capture/media rights. No genuine
listening tool was found in inspected capabilities. Both remain explicit
BLOCKED/INCONCLUSIVE rows. Acquisition must preserve original PNG/baseline JPEG
and original AV bytes, bind source/rights/rubric/clock/coverage, and never resize,
transcode or self-reference to obtain approval. An image-only judge cannot pass
audio. The operational pilot is separately unauthorized; local transport
fixtures, dry runs and generated authorization receipts never prove API delivery.

## Named dependencies before consolidated execution

| Owner | Required handoff |
| --- | --- |
| Task 3 | Settled publication/regeneration source and preservation/crash limitations; no pending journal. |
| Task 5 | Current identity emission, decoded exact scripts, global stale/action admission. |
| Task 6 | Final driver/session/process/contention paths; actual registration/cleanup route, barrier controller and fresh epoch execution; current discovery after authorization. |
| Task 7 | Final covered source paths and origin statements, all media-to-origin comparisons, frozen candidate procedure, isolated consumer profile; native extensions/build files explicitly inventoried. |
| Task 8 | Compatibility subprocess cases and retained future-schema/fencing semantics. |
| Task 9 | Preserved generated Primal refresh, real local persistent bridge/host tests, commit/load/lease/throttle ports, stable product touch targets; no DataStore writes. |
| Task 10 | Qualifying independent rights-cleared reference and actual original comparable captures; currently unavailable. |
| Task 11 | Bounded judge lifecycle, dedicated epoch/rejoin receipt specs, native build/recording handoff, real decoder/source coverage and genuine listening route. |
| Task 13 | Final scenario grammar/controls and actual touch/discovery evidence, not portrait keyboard smoke. |
| Task 14 | Collector/workload/recovery connected to Task 9 ports, actual cap/lease/transfer barriers, eight-client workload and per-target cleanup. |
| Task 15 | Parent watchdog/EOF/reap specs plus native-fetch JS suite; sanitized single-attempt provider handling. External pilot remains unauthorized. |
| Coordinator | Final path re-enumeration, valid refreshed authored receipts, execution barrier release, exact invocation/log ledger and justified repair reruns. |

At initial intake `task-1-authored.json` failed JSON parsing; its authorized
syntax-only delimiter repair now parses, with hashes and claims untouched and
unverified. Other receipts can also become stale
while workers edit. This is a source-inspection finding, not a failed QA run.
The final matrix must retain every missing dependency and every actual failure,
resource residual and unverified claim. Preparation completion does not close
Task 16, Tasks 17-18, or F1-F4.
