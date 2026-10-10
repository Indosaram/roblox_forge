# Settlement conflict native integration

Run from the repository root:

```text
lune run cli/forge/fixtures/settlement-conflict/check
lune run cli/forge qa run --pack fixture-survival --scenario settlement-conflict --packs-root cli/forge/fixtures/settlement-conflict --evidence .omo/evidence/forge-output-quality-survival/wave2/task-10-cli.json
```

`check` invokes the real Settlement and Transaction specifications, then places
Transaction transitions inside actual FencedStore update callbacks. It owns
coroutines parked on the existing QA backend's exact commit signal. A member's
reservation wins against an owner's captured version and fresh same-cell request.
A separate parked build commit observes a membership revocation durably written
before its callback resumes. No sleep, synthetic success, or duplicate rule
implementation is used.

The final actual fenced record is serialized as JSON and passed to a fresh Lune
process (`check restore <json>`). That process reconstructs the backend, acquires
a new fenced lease, checks retained IDs and inventory, and refuses a second
demolition refund. This proves the direct mechanism's restart behavior, not a
production save-schema validator or durable command coordinator.

The CLI now uses the production action registry and actual Session -> Bridge ->
Runtime route. The harness creates one budgeted fenced tribe owner from the
target's canonical content. Session's top-level `survivalSettlement` snapshot is
read directly, not copied into player state. Warehouse cost/refund and failed
full-slot demolition, conflicting placements, commit-barrier revocation, replay
and serialized owner reload are asserted against that owner.

The server-only invite step simulates an already accepted invitation. It does
not prove the later player-facing request/accept consent UI. Geometric authority
uses server fixture coordinates, not client reachability booleans or Studio.
Reload releases the old tribe owner, serializes durable backend records and
reconstructs the runtime without overwriting saved state. Final cleanup releases
the owned tribe lease.

No shared adapter, Session, Content, or persistence files are owned by this fixture.
