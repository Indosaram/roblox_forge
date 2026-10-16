# core/domain/

Engine-free pure Luau: economy calculations, state machines, and growth formulas
(plan §11.1). Lune has no engine API, so only `core/domain` runs in Lune specs
and simulations.

**Allowed:** plain Luau only. **Forbidden:** `game`, `Instance`, `task`, and any
Roblox service. Engine access belongs in `core/infra`.

Subpackages: `economy/`, `progression/`, `state/`, `procgen/`, `island/` — semver-versioned with core.
