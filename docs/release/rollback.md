# Backup and rollback readiness

This is a refusal-oriented runbook, not an executed recovery receipt. No backup,
restore, deployment or persistent-service pilot is authorized by this document.
The save contracts in [upgrades.md](upgrades.md) are authoritative.

## Before changing saved state

Inventory every affected namespace, wrapper version, payload version, nested
envelope, command ledger and transfer journal. Record the forward binary and
proposed rollback binary revisions and hashes. Distinguish ProfileStore keys from
FencedStore keys; their wrappers are not interchangeable.

Create a backup manifest through the separately authorized storage procedure.
It must identify the source namespace/key set and revisions, snapshot interval,
writer quiescence observation, integrity hashes, access controls and retention.
Back up both sides of each transfer together with escrow, credit, finality and
command outcomes. Do not copy only balances or inventory. Keep secrets and raw
player data out of the public release receipt; reference protected backup IDs.

Readiness is false until a copied backup can be decoded by the intended forward
and rollback binaries and compared for unchanged quantities, request identity,
committed results and journals. Retain the comparison receipt and exact binary
hashes. Existence of a backup file or a successful local memory fixture is not
proof of restorable production state.

## Rollback decision

Refuse an older binary if any current wrapper or payload version exceeds its
documented read support, if schemas or key coverage are unknown, or if the
backup lacks coherent transfer/command history. ProfileStore returns
`unsupported record version` without altering unsupported records; future payload
versions are also refused by the relevant schema boundary. Pre-guard binaries
can ignore wrapper markers and are not safe rollback candidates. Retire those
writers before migration rather than trusting a marker to constrain them.

Do not downgrade a version integer, restore defaults, erase receipts, reset
fencing generations, refund escrow, or restore one side of a credited transfer
to make an old binary start. Keep the compatible newer binary, or obtain explicit
authorization for a coherent restore while all writers remain quiesced. Any
restore needs an independently reviewed key set and a post-restore comparison
against the manifest before writers resume. Forge does not provide a production
backup/restore command; these are observable operator prerequisites, not a
claimed automatic restore facility.

## Recovery after an uncertain result

Reconcile the actual published place version against the retained assessed
artifact before a second publish. For liveops, observe recipient state and any
event-specific idempotency record: the publisher supplies no delivery identity
that makes an arbitrary repeated event safe. A timeout is uncertainty, not a
rollback instruction.

For durable transfers, reacquire both leases under normal fencing rules, retain
the journal, and drive recovery forward to confirmed FINALIZED. CREDITED alone
does not complete recovery. A lost acknowledgement is not permission for another
debit. Finality cleanup requires its normal expiry and generation checks.

Stop recovery and record a blocker if quiescence, compatible schemas, coherent
snapshot coverage or outcome reconciliation cannot be observed. Retain original
failed snapshots and logs; clean only resources listed in the recovery ownership
record. Task 8 fixtures and Task 15 transport fixtures remain local contracts,
not evidence of a real persistent backend restore.
