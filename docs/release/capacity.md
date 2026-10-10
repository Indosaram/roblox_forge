# Capacity collection and support policy

Status: **AUTHORED; execution checks and live proof pending.** No supported
player count has been established. Unit fixtures test admission logic, not live
Studio capacity or recovery.

## Command and authority

After the source/check barrier and Studio launch authorization:

```text
lune run cli/release/capacity --pack primal-isles --players 8 --out .omo/evidence/forge-production-release/task-14-capacity.json
```

`FORGE_CAPACITY_DRIVER` names the maintained MCP transport configuration with
`command`, `args`, `editor: {executable}`, `buildPath` and `ownershipToken`.
Without it no Studio allocation occurs. Existing output is refused. The owned
artifact directory is `<out>.artifacts`, created exclusively. No existing
database or configured Studio instance is adopted.

The CLI checks current pack source/config/assets, marked build bytes and identity
sidecar before launch. It fingerprints all Luau/MJS sources under `cli/release`
and `cli/forge/qa` as collector provenance, then rechecks both fingerprints and
actual build bytes after collection. Changed inputs invalidate admission.
Collector exit code, status and verdict must agree.

`--evidence <file>` remains untrusted offline telemetry intake. It can report
candidate quantiles and original file SHA-256; it cannot admit actors or publish
a measured envelope. PASS, cleanup, conservation or self-hash fields supplied in
that file confer no authority. `--recovery transfer` remains accepted for command
compatibility; the maintained live route now always collects the full matrix.

## Sequential owned matrix

`capacity-matrix.mjs` invokes the maintained collector, never an executable path
provided by evidence. It runs MEASUREMENT, ESCROWED, CREDITED, FINALIZED,
LEASE_ACQUIRED and LEASE_RENEWED sequentially. Each checkpoint receives a fresh
owned SQLite database and random namespace/token. Its local host stays alive
across that checkpoint's distinct owned crash/restart Jobs; all Jobs close before
the host closes. Different checkpoint namespaces avoid reusing depleted resources
or treating a previously completed request as a new durable transition.

Lease acquisition first discovers a real leased gathering key in an owned
warmup Job, closes it, waits its actual persisted expiry through the runtime
selector and starts a held acquisition Job in the same namespace. Renewal selects
an observed leased gathering record and triggers the existing authoritative
refresh. After each crash, the persisted expiry is respected, a fresh acquisition
is held, and the actual stale writer is rejected without changing durable bytes.
The controller's exact expiry deadline is cancellable; time passage is the
behavior under test, not a retry delay.

Transfer phases use the existing pre-dispatch gate and real HUD input, retained
original request, observed durable barrier and exact owned Job termination.
Restart keeps the database, waits the persisted leases, admits fresh loaded
actors, replays the original envelope without changing its epoch and reads the
complete namespace independently. Stale ingress refusal is not successful replay;
terminal source FINALIZED and destination CREDITED receipts must independently
prove recovery and conserve owned inventory plus uncredited escrow.

Every checkpoint retains its complete JSON receipt and database SHA-256/length.
Admission rereads original files after cleanup, verifies hashes/content, opens
the retained database read-only and compares its complete sorted namespace
keyset with the final independent readback. These local hashes provide integrity
and current-source binding, not cryptographic signing. Cancellation closes owned
resources; unresolved cleanup stops subsequent allocations. Original evidence is
retained, not deleted by the collector.

## Separate verdicts

`capacity-admission.mjs` recomputes evidence properties rather than promoting
producer `ok`, `noLoss`, generic recovery callbacks or bridge-proof flags.

- `supportedEnvelope.measured` concerns only the actual eight-client workload.
  It requires unique loaded actors/sessions, current build, one complete shared
  300-second window, finite original samples, each client's nearest-rank frame
  p95 <= 33.3 ms and the same server p95 limit, memory, hardware/version,
  configured NPC census, runtime payload
  policy, backend budget/outcomes and commit latency. Full acknowledged commit
  chains must connect independent DB endpoints. Gather grant/charge transitions,
  catalog mint/craft/build costs and original replay readbacks prove quantities.
- `recovery.status` remains BLOCKED until all five durable checkpoint proofs and
  all five declared saturation kinds pass independent validation.
- Overall `status` is PASS and exit code zero only when both verdicts pass, all
  retained artifacts bind and cleanup is proven. Missing saturation/recovery
  does not erase an independently measured workload envelope. Missing measured
  proof does not discard useful raw metrics.

The workload comprises eight server actors, one shared-mutation actor and seven
personal-only actors, not an eight-member tribe. The tribe limit remains four.
The configured owner gathers, crafts cord, deposits six wood and builds one
floor. Other actors gather within existing node charges. No recharge, mint,
clock advance or direct domain-command shortcut supplies happy workload inputs.
A failed eight-client run does not establish a lower capacity: measure a separate
reduced workload before claiming one. Multi-server and Roblox live service
capacity remain unclaimed.

## Backend metric contract

The authoritative direct local-host observation is `local-sqlite-cas`, bound to
namespace and host epoch, with finite cumulative window, bounded outcomes,
complete coverage and no pending requests. Its budget unit is concurrent
authenticated HTTP request slots (default configured maximum 64), not a
Roblox quota. The authenticated `/observation` route excludes itself from
workload counters. Requests rejected before the HTTP application's callback
cannot be inferred from host counters alone.

Runtime Loopback/ObservedBackend outcomes must independently be complete and
classified. Every runtime request joins its host outcome by actual backend epoch
and host operation ID, route, key and read/CAS revision fields; every host request
in the workload delta must be accounted for. HTTP 429 is unhandled, never retried
into assumed success. Confirmed CAS 409 is a bounded conflict, not a throttle.
Transport/protocol ambiguity, missing rows, pending calls and trace overflow
block admission. Runtime bounds remain 256 outcomes/commits and 16 MB; host
retention is 4096 outcomes. Zero handled throttles is acceptable only with a
complete classified trace. Roblox UpdateAsync samples are retained under
`auxiliaryEngineObservations` with `applicableToMeasuredBackend: false`, not
substituted for the local host's budget. Admitted `server.frames` and
`server.memory` retain count, p50, p95 and maximum alongside each client's metrics.

## Saturation and remaining capability blockers

Loaded `ServerStorage.ForgeCapacity.limits` returns actual runtime payload,
receipt, job, player-admission and NPC limits. `collectSaturation` retains raw
operations, limits, boundary/refusal observations, independent full readbacks and
cleanup. `validateSaturationRow` independently checks those rows.

Retained jobs use real Reserve/Cancel controls to the unchanged retained limit,
then `JOB_QUEUE_FULL`; each cancelled job and inventory is checked independently.
NPC saturation uses the actual Studio-only WildlifeWorld registration closure,
temporary owned rigs and synchronous cleanup. An already-full world contributes
its existing census and a real max+1 refusal, never fabricated acceptance.

Three required saturation routes remain explicitly unavailable:

- `EXACT_PAYLOAD_PUBLIC_OPERATION_UNAVAILABLE`: legitimate public actions have
  no arbitrary byte-padding operation; a validator-only padded save is not an
  actual committed limit probe.
- `EXACT_RECEIPT_PUBLIC_OPERATION_UNAVAILABLE`: reaching 4096 shared receipts
  competes with other unchanged resource, command and inventory limits; no
  isolated bound-plus-one public operation is claimed.
- `ACTUAL_EXTRA_CLIENT_ADMISSION_UNAVAILABLE`: the probe lacks an owned actual
  additional-client allocation/termination port. A string actor or synthetic
  Session join is not an observed ninth-client rejection.

These blockers belong to recovery/saturation, not measured performance. No flags
or generic callback helpers bypass them. Their owners must implement legitimate
producers before overall Task 14 approval becomes possible.

## Verification boundary

Adjacent `capacity-admission.test.mjs` fixtures exercise successful narrow
measurement reconciliation and terminal transfer logic, plus slow samples,
missing actors, request correlation, payload, quantity, cleanup and original
epoch failures. `capacity-matrix.test.mjs` exercises sequential cleanup, retained
hashes and allocation refusal after unresolved resources using UNIT runners.
`capacity.spec.luau` preserves the offline-intake boundary. None is live proof.
All tests, diagnostics, formatting, build and live runs remain pending the
parent's consolidated source barrier; do not treat authored fixtures as passing
results.
