# Save compatibility and rollback

This is an implementation contract, not a production-storage or Studio rejoin
receipt. Task 8 verification remains deferred to the consolidated release matrix.

## Supported envelopes

| Layer | Read support | Write form and upgrade policy |
| --- | --- | --- |
| ProfileStore storage wrapper | Legacy table without `version`, or `version = 1` | Version 1 `{ version, data, lock? }`; legacy upgrade is committed with the normal successful load/save/release. |
| ProfileSchema payload | Caller-selected current version and older integer versions starting at 0 | Pure ordered migration steps, then missing defaults, then current version. Current generic Session payload is version 1; game payload versions remain caller-owned. |
| FencedStore storage wrapper | Version 1 only | Version 1 `{ version, generation, revision, data, lease? }`; acquire increments generation, each committed operation increments revision. No legacy ProfileStore-to-fenced conversion. |
| PersonalAggregate data | Version 1 only | `stateRevision`, full `envelope`, and version 1 `itemTransfers`; inventory has one owner, projected through its lens. |
| ItemTransfer journal | Version 1 only | Preserve request bindings, escrow, destination credit, terminal state version, and finality receipts. Missing journal initializes empty only on a supported aggregate. |
| Generic Session command ledger | Version 2 | Retain epochs, bindings, expiry, results and state versions. No automatic legacy-ledger conversion is promised. |

Wrapper and payload versions are independent. Never point ProfileStore at fenced
keys: their namespaces and ownership contracts differ. The new wrapper marker
does not opt any existing pack into personal aggregates or durable transfers.

`ProfileStore` refuses unsupported wrapper versions before invoking migration or
altering a lock, and refuses save/release/releaseLock when persisted payload
version exceeds the caller's candidate version. Errors return
`unsupported record version`. The last backend callback determines the outcome,
including when an earlier callback accepted a legacy record. Existing bounded
backend retries and injected backoff remain unchanged.

Caller migration must reject unsupported payloads before returning a candidate.
`ProfileSchema` rejects future integer versions; generic Session additionally
validates its envelope and genre schemas. ProfileSchema's existing malformed
version normalization to 0 is retained, not advertised as a repair policy.
Do not use migration to mint currency, drop inventory, erase outcomes, rewrite
request identity, or reset lease/fencing counters. Do not restore from defaults
after an unsupported-version failure.

## Fixtures and upgrade acceptance

`core/infra/data/fixtures/profile-legacy.json` represents the shipped unversioned
wrapper with payload version 0, 27 coins, 10 wood, an active legacy session lock,
and a committed version 2 command outcome. The additive upgrade to wrapper and
payload version 1 preserves these values. Acquiring an expired lock changes its
owner through normal locking rules; it does not bypass an active lease.

The adjacent `Compatibility.spec.luau` drives a real Lune subprocess using a
JSON-backed local adapter. After the adapter writes an ESCROWED, CREDITED, or
FINALIZED record, it emits an explicit barrier and blocks on stdin before
acknowledging the commit. The parent terminates that process, checks its exit,
then starts a distinct replay process with the serialized records. A 30-second
deadline kills only the owned child if the barrier or completion never arrives.
No fixed sleep or timing-based race determines the interruption.

Replay reacquires expired leases, upgrades/reopens the legacy fixture, preserves
its command outcome, and drives the actual transfer coordinator forward with
authorization revoked after escrow. It requires final quantities 7 and 3 and
the same finalized state version on repeated requests. Existing FencedStore,
PersonalAggregate and ItemTransfer specs cover stale writers, CAS, callback
replay, failed/lost acknowledgements, limits, expiry and finality cleanup.

These fixtures prove local serialization and process isolation only. They do
not prove Roblox DataStore durability, network partition handling, two actual
Studio clients, or a player leaving and rejoining a persistent backend. Tasks
13 and 14 must supply those independent receipts; a same-session restore or a
memory-backed Studio server cannot substitute.

## Safe rollback

Before deploying a schema-changing binary, inventory every affected namespace
and nested envelope version, retain an explicit backup with its source revision
and request/transfer journals, and test both the forward binary and intended
rollback binary against copied serialized records. Quiesce writers before any
administrative restore. Never restore only one side of a credited transfer.

An older binary may reopen only schemas it actually supports. Pre-guard
ProfileStore binaries ignore wrapper versions and must not be assumed safe
rollback targets. A wrapper marker alone cannot stop an already deployed old
binary; retire unsupported writers before migration. If compatibility cannot
be demonstrated, keep the newer binary or perform an explicitly authorized,
coherent backup restore while writers remain stopped. No automatic downgrade,
reset, receipt deletion, or escrow refund is a recovery option.

Recovery after escrow is forward-only: reacquire both leases, retain all durable
receipts and drive `advance` until FINALIZED is confirmed. CREDITED is not final
success. Lost acknowledgement is uncertainty, not permission to repeat a debit.
Cleanup requires expired durable finality and destination generation fencing;
mint receipts remain under their producer's retention contract.

Source regeneration is separate from save migration. Task 3 uses a per-file
replacement journal with restart rollback and pending-journal consumer guards,
not whole-pack atomic publication. It neither upgrades nor restores saved data.

## Deferred verification

After the implementation barrier, run `lune run cli/forge check --all` once in
the consolidated matrix. Record exact invocations, revisions, hashes, process
identities, intervals and exit codes in Task 8 happy/failure receipts. Happy
proof requires legacy upgrade plus distinct-process reopen/replay with unchanged
quantities and outcomes. Failure proof requires unsupported versions unchanged,
stale writers refused, and termination at all three durable transfer barriers
without duplicate credit or acknowledgement of an uncommitted result.

Fixture cleanup cancels deadline tasks, terminates and reaps only owned child
processes, releases replay leases, and removes only its temporary directory.
Consolidated verification must retain original logs and failed snapshots before
any evidence cleanup; production/Studio resources require separate ownership
and cleanup evidence.
