# core/domain/island/

Engine-free island topology, allocation, and expedition rules (plan §5.1, §5.2,
§11.1, §11.5). Pure Luau, covered by Lune specs; the engine adapters
(IslandRouter, Teleport, Lease, IslandDirectory) live in `core/infra/island`.

- `Topology` — place kinds (`landing`, `homestead`, `harbor`, `expedition`,
  `contested` [P2]), per-kind capacity (forge policy 8, overrides may only lower
  it), and allowed travel transitions.
- `Allocation` — deterministic allocator: rebalances already-overfull islands,
  places arrivals under the cap, opens instances within a budget, and queues the
  rest. Ties are broken with `Rng:fork`. `playerMessage` returns localization keys
  and numeric params only (no ids, SYS-198); queue positions are approximated.
- `Expedition` — route card -> `{templateId, seed, delta, expiresAt}`; seed via
  `Rng:fork("expedition")` from route id and rotation window (24 h, ADR-05);
  expiry is judged against a passed `now`; deltas over 50% of the DataStore key
  limit are sharded by zone.
