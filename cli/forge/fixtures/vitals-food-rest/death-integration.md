# DeathBundle Session integration proposal

Status: fixture specification only. The current Session has no durable server
command ingress, and CraftingAdapter has no DeathBundle binding. This is not a
passing task 9 scenario and must not be registered as executable QA yet.

## Durable server ingress

Add `Session.commandServer(actorId, request)` through the same internal command
implementation as `Session.command`, parameterized by trusted origin. Executor
must validate and stage against that origin using its existing action registry,
schema validation, clock refresh, event queue, and candidate apply path.

The common path must keep existing profile locking, pending candidates, backend
commit, replay outcomes, and result validation. Bind origin into the canonical
request identity so a client cannot replay a server receipt. No remote route may
invoke commandServer or accept an origin, actor, time, equipment map, or server
identity from the client. Server and client durable action allowlists must be
explicit. A fresh server event gets the currently issued ledger epoch; retries
retain the original epoch and request ID.

`dispatchServer` is non-durable and must not be used as the implementation of
death drop, pickup, expiry, or inventory-affecting respawn.

## Caller ports and persisted data

- Server identity comes from the runtime host: the Roblox binding supplies
  `game.JobId`; the native host supplies its generated process/session identity.
  Reject an unavailable identity. Do not ship a constant fallback.
- A trusted equipment registry returns the actor's actual equipped inventory
  IDs. An unavailable registry is different from an authoritative empty set.
- A trusted death-location query captures the actual death position. Persist
  that position with the bundle; pickup reach is recomputed from server player
  coordinates and the persisted position. Never accept a client reach flag.
- Persist DeathBundle.save, carried inventory, vitals, the actual-death sequence,
  and captured bundle locations in the same player candidate. Shared tribe
  warehouse data is not part of this candidate.
- Rebinding a saved serverId requires a successful profile ownership lock and an
  explicit migration policy for old-world locations. The current pure module
  intentionally offers no unrestricted rebind operation.

## Proposed action tuples and request identities

All tuples below are server-origin actions passed to commandServer. A later
client pickup intent may identify a bundle, but the server resolves actor,
location, reach, and authority before invoking the durable command.

| Action | Exact args | Stable request identity |
| --- | --- | --- |
| death-drop | `{}` | `death-drop:<actor>:<persisted-next-death-sequence>` |
| death-pickup | `{deathId}` | server-issued pickup intent ID retained across retry |
| death-expire | `{deathId}` | `death-expire:<actor>:<deathId>:<persisted-expiry>` |

The adapter allocates a death sequence only for a real alive-to-dead transition.
It must not increment on repeated ticks observing an already-dead actor. Since
current advance mutates vitals in memory, integrate the transition by staging
the death-causing vitals advance together with the inventory/bundle candidate;
do not first publish death and then attempt an independent inventory save.

At expiry, commit DeathBundle.expire even when a pickup is rejected as expired.
An expired pickup refusal alone does not durably remove the bundle. Queue expiry
commands from the authoritative scheduler; no sleep or silent memory purge.

## Actual Session fixture sequence

Use the real Session, Executor, ProfileStore and fault-injectable backend. Extend
the trusted fixture catalog with an equipped item and a partially reserved stack.
Use Unix milliseconds 1790899200000, not a manually patched Vitals state. Host
identity is created once by the native runner and retained for same-host reload.

1. Join, supply registered equipment and coordinates, reserve part of one stack,
   and advance to the newcomer death boundary. Stage death-drop with a failed
   backend commit. Assert inventory, vitals, bundles, and sequence are unchanged.
2. Retry the same request 100 times. Assert one death sequence and no dropped
   newcomer bag. Attempt client ingress for each server-only action and assert
   refusal before any candidate is applied.
3. Durably respawn, accumulate at least 1800000 online milliseconds, then cause
   the next actual death. Assert equipped and reserved quantities remain, the
   remaining bag is in exactly one private bundle, and expiry is death+600000.
4. Suspend the backend commit at its callback, assert no candidate is visible,
   resume that exact callback, then replay 100 times. No duplicate split IDs or
   second bundle may appear.
5. Close, encode backend state as JSON, launch a fresh native process, reacquire
   profile ownership, and replay the same event under the explicit host-rebind
   policy. Assert unchanged receipt, sequence, reservations, and quantities.
6. Refuse pickup for a different owner, wrong server, dead actor, and out-of-reach
   position. Fill carried capacity and assert whole-bundle pickup changes neither
   side. Free capacity, move to the bounded reachable location, then commit one
   pickup; retry 100 times and assert exact inventory conservation.
7. Create another bundle, advance to expiry-1 and verify it exists. At exact
   expiry, fail the expiry save and assert durable state remains unchanged. Retry
   expiry, restart from JSON, and assert the bundle is absent. Pickup must never
   resurrect expired inventory.
8. Assert no tribe warehouse copy appears in personal data. Capture the exact
   source hashes and command receipt only after all real Session assertions pass.

Prerequisites: parent-owned commandServer/common-origin implementation; adapter
ownership release after Workshop; trusted equipment and location ports; explicit
lock-governed server rebind contract. Roblox world bindings remain task 12 work.
