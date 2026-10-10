# Wildlife integration contract (task 13)

Durable combat now runs through actual Session admission, PersonalAggregate CAS,
FencedStore shared ownership and ItemTransfer mint delivery. Task 13 still needs
parent adoption of generated server artifacts and actual Studio proof; no existing
pack was edited by this worker.

## Generated server wiring now supplied

craftinggenerate emits `src/shared/WildlifePolicy.luau` and passes it to the
generated SurvivalFactory and SurvivalWorldBootstrap. The factory binds one
fenced wildlife owner at `persistencePrefix:provisionId:wildlife-v1`, using the
existing epoch clock, personal owner resolver and recovery scheduler. Bootstrap
publishes durable NPC health after command/recovery and releases its source lease
on close. SurvivalWorld registers DinosaurRig models for grazer-01 and hunter-01,
projects membership/vitals/equipment and queues NPC strikes in its existing
vitals/death queue. A missing epoch retains the strike; retry preserves request ID.

Parent adoption: regenerate in an isolated fixture and port only these generated
server/shared changes to the developmental pack, preserving parent UI/camera.
The added generated artifact is WildlifePolicy; server entry point, factory,
world bootstrap and GenreDurable also change. Existing content and spear recipe
remain the source of weapons; no starter spear or client damage grant was added.

HUD attack contract: submit `survival-coop:attack` with `{targetId}` through the
existing command transport. Registered models expose ForgeWildlifeId,
ForgeWildlifeKind, ForgeWildlifeState, ForgeWildlifeHealthMilli and deadline.
These are presentation/selection only; server validates physical positions,
facing, LOS, usable registered equipment and cooldown. Do not enable the control
for an old pack without the new server lifecycle. Confirmed result uses
`data.status == "confirmed"` and stateVersion; pending is not success.

Procedural rigs have articulated original anatomy (long-neck quadruped grazer,
biped hunter, jaw, eyes, segmented tapering tail), server physics collision and
Motor6D joints. Native anatomy/connection proof is not rendered approval or an
animation quality claim. Parent still owns multi-angle render/live evaluation.

## Reusable ports (already connected by generated bootstrap)

`Wildlife.catalog(content, policy)` validates a server-authored combat policy
against existing content IDs. Generated WildlifePolicy supplies
`species.grazer` and `species.hunter` with `healthMilli`, `damageMilli`, and `drops`
(item/quantity pairs); supply `weapons.spear` with damageMilli, wearMilli,
rangeStuds (maximum 8), facingDot (0..1), and cooldownMillis. The native fixture's
20/40 health, 10 hunter damage and 20 spear damage are provisional test values,
not an automatically installed economy policy. Policy must be shipped source or
config so the quality receipt binds it.

Create `WildlifeWorld.new` once in the server bootstrap, with canonical content,
policy, maximum (1..32), and monotonic integer `nowMillis`. Register two actual
unanchored Humanoid rigs with `register(model, uniqueSpawnId, catalogId)`. IDs must
never be recycled within a durable world incarnation. The binding owns server
network authority, path computation, Humanoid movement, sensing, raycasts and
replicated state/deadline attributes. It does not manufacture dinosaur art.

Use Session membership plus current authoritative vitals for `alive(actorId)`.
Use the existing SurvivalWorld registered-tool `survivalDeath.equipment` callback
for `equipment(actorId)`; never read tool names/client equipment claims. Both
callbacks are synchronous server projections.

`damage(actorId, strikeId, damageMilli)` must synchronously enqueue the existing
`survival-coop:vitals-damage` server command, NOT change Humanoid health. Prefix
strikeId with a unique world incarnation. Retain one epoch/request ID and exact
payload until the existing command journal resolves it; route through the same
queue as SurvivalWorld death/respawn, so rest termination and death ownership
remain unchanged. Do not regenerate IDs on retry. The binding emits an intent
once and assumes enqueue succeeds without yielding.

The Contract already declares target-only `survival-coop:attack`. Include it in
the generated durable.actions list. Install one WildlifeBridge in both Options
services and actual server Services as `survivalWildlife`. Its `resolve(actor)`
returns the same WildlifeRuntime for all actors sharing this world. Session now
routes that service through its existing authenticated admission/busy lane and
bounded recovery scheduler; no remote or parallel command executor was added.

Create `WildlifeRuntime.new(config, fencedStore)` after binding the Session. Use
a stable world key and the SAME backend/session identity as the personal owners;
`resolvePersonal(actor)` returns `session.personalTransfer(actor)`. Supply content,
combat catalog, initial NPC states keyed by the registered spawn IDs,
carriedContainer, maxReceipts, `now` (integer epoch seconds), `nowMillis`
(persistent epoch milliseconds, NOT process uptime), and `access(actor,target)`
delegating to `world.access`. Clock must stay comparable across process restart.
Initial states initialize only an empty source; persisted health wins on rejoin.

The owner protocol is: fenced intent locks NPC and actor; personal CAS commits
wear/cooldown and charge receipt; shared CAS applies damage once and atomically
stages the lethal mint; ItemTransfer credits/finalizes loot; personal command
journal commits final result; shared intent finalizes. Shared state never stores
personal inventory. Ambiguous failures return pending, not success. Accepted
intents recover after TTL; new expired requests refuse. Normal Session commands
and epoch rotation drive pending combat recovery first and fail closed while it
cannot settle. Equipment changes before the personal charge can cause a durable
rejection instead of free damage. After charge, recovery never recharges.

Call `session.recoverTransfers(actor, bound)` on the existing lifecycle scheduler.
After command/recovery obtain bridge.snapshot(actor), then publish each returned
durable NPC with `world.publish(npc)`. Snapshot may include applied damage while
loot remains pending; do not present that as a confirmed command result. The
runtime source lease must be acquired before allowing ingress. Missing runtime
returns WILDLIFE_UNAVAILABLE, never fallback success.

Receipts are bounded and retained, with admission rejecting at capacity; no
active/pending receipt is evicted. Provision the bound for this vertical slice.
The source requires maxReceipts times largest drop list <=4096 and each drop
fits its item stack. There is no indefinite receipt compaction in this increment.
CraftingAdapter preserves versioned combat charge receipts and actor cooldown
through all ordinary saves/hydration. Do not activate confirmed HUD capability
until this parent wiring is present and live QA succeeds.

## Actual engine QA still required

Run the parent-owned `wildlife-spatial` Studio scenario on desktop and mobile with
two real clients. Observe grazer sensing at 12 and release beyond 24; hunter warn
at 12, chase, one-second telegraph, attack at 4, two-second post-strike cooldown,
and return at home leash 40. Closest distance then actor ID determines targets;
target changes restart warning. Move the attacking player inside/outside eight
studs, turn away, unequip/break/reserve the spear, and insert a collidable obstacle
before the exact strike. Record server roots, rays, states, health, durability,
and journal IDs. Force a path failure and verify idle without movement teleport
or hit. Kill/retry/rejoin and verify one durable grant. Capture three viewpoints
and muted visual telegraph feedback. No native test proves rendering or fun.

Call `destroy()` before removing task-owned rigs. It disconnects all signals,
invalidates outstanding path callbacks and removes owned attributes. Rig removal
and server queue teardown remain bootstrap-owned. No Studio resources were
created by this child.
