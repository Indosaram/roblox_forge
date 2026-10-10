# core/anticheat/

Common anti-exploit checks shared by every game (plan §8, §11):

- server-authoritative carry/transport state
- per-second movement-distance validation
- interaction-distance validation
- RemoteEvent rate limiting

Pure validation rules live in `core/domain`; this package wires them to engine
network callbacks. Game packs register hooks instead of editing this code.

`core/anticheat` is engine-free pure Luau (`--!strict`), so it runs and is tested
under Lune. Time is always passed in; the modules never read a clock themselves.

## RateLimiter

Per `(key, action)` token bucket. `key` is normally `tostring(player.UserId)` and
`action` is the remote name.

```lua
local RateLimiter = require(Forge.core.anticheat.RateLimiter)

local limiter = RateLimiter.new({
	BuyEgg = { capacity = 5, refillPerSecond = 2 },
	Raid = { capacity = 2, refillPerSecond = 0.2 },
})

local allowed, reason = limiter:allow(tostring(player.UserId), "BuyEgg", os.clock())
if not allowed then
	return false, reason -- "rate limited: BuyEgg" or "unknown action"
end
```

- `RateLimiter.new(config)` — `config` maps an action name to
  `{ capacity: number, refillPerSecond: number }`. Each action starts full and
  refills at `refillPerSecond` up to `capacity`; one call spends one token.
- `limiter:allow(key, action, now)` — returns `(true, nil)` when a token was
  spent, else `(false, reason)`. `reason` is `"unknown action"` when the action
  is not configured, otherwise `"rate limited: <action>"`.
- `limiter:forget(key)` — drops every bucket for one key (call it when a player
  leaves).

## Validate

Pure guards for untrusted remote arguments. All return a `boolean`.

- `Validate.isString(value, maxLen)` — `value` is a string of at most `maxLen`
  characters.
- `Validate.isIndex(value, min, max)` — `value` is an integer in `[min, max]`.
- `Validate.isFiniteNumber(value)` — `value` is a real number (not NaN or
  infinity).

## Distance

Engine-free checks over `{ x: number, y: number, z: number }` tables.

- `Distance.withinReach(a, b, maxStuds)` — `b` is within `maxStuds` of `a`
  (boundary inclusive).
- `Distance.movementPlausible(prev, cur, dt, maxSpeed)` — moving from `prev` to
  `cur` over `dt` seconds stays within `maxSpeed` studs/second. A non-positive
  `dt` is never plausible.
