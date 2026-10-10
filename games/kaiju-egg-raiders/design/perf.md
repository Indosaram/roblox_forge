# Kaiju Egg Raiders - Performance Budgets

Budgets protect the 30-second first loop and the 10-minute siege on low-end mobile.
Remote limits come from `src/shared/Config.luau` (`Config.anticheat`); the part budget
applies to the `KaijuEggRaidersWorld` model built by `src/server/World.luau` (`World.build`).

## Budgets

| Metric | Budget | Notes |
| --- | --- | --- |
| Server heartbeat | >= 55 Hz | 55/60 = 8.3% headroom under the 60 Hz target |
| Client FPS (low-end mobile) | >= 30 FPS | floor is 30 FPS; target 60 FPS on desktop |
| BaseParts in `KaijuEggRaidersWorld` | <= 6000 | replicad part count of the world model |
| Client memory | < 800 MB | RSS/total memory on low-end mobile |
| Remote calls / s / player | sustained <= 8.7, burst <= 25 | derived from `Config.anticheat` (below) |

## Remote call budget per player

Each remote is a per-player token bucket. Sustained rate is `refillPerSecond`;
burst is `capacity`. Totals: sustained 2 + 2 + 2 + 2 + 0.2 + 0.5 = 8.7 calls/s,
burst 5 + 5 + 5 + 5 + 2 + 3 = 25 calls.

| Remote | Capacity (burst) | Refill/s (sustained) |
| --- | --- | --- |
| BuyEgg | 5 | 2 |
| HatchEgg | 5 | 2 |
| Merge | 5 | 2 |
| ClaimQuest | 5 | 2 |
| Raid | 2 | 0.2 |
| StoreOpen | 3 | 0.5 |

`Raid` (capacity 2, refill 0.2/s) is the tightest gate: at most 2 raid calls per burst
and 1 every 5 s sustained, matching the 120 s siege window inside the 600 s period.

## Measurement procedure

1. Server heartbeat - open Studio, run in Play mode, enable the MicroProfiler
   (`Ctrl+F6`) and read the "Heartbeat" / server frame bars over a 60 s siege window.
   Record the minimum observed Hz, not the average.
2. Client FPS - use the Stats service (`game:GetService("Stats")`) or the MicroProfiler
   frame time; sample a low-end mobile device profile for 60 s during a siege and record
   the 1st-percentile FPS.
3. BaseParts - in the command bar run
   `#workspace:GetDescendants()` filtered to `BasePart` under `workspace.KaijuEggRaidersWorld`,
   i.e. `local n = 0 for _, d in workspace:GetDescendants() do if d:IsA("BasePart") and
   d:IsDescendantOf(workspace.KaijuEggRaidersWorld) then n += 1 end end print(n)`.
   Count after `World.build()` has parented the model.
4. Client memory - read memory from the MicroProfiler memory view or the developer
   console on the low-end device after 5 minutes in a siege; record the peak, not the start.
5. Remotes - assert against `Config.anticheat` counters in `core/anticheat`; a healthy
   client stays well under the sustained column, so sustained is the alarm threshold.

## Results

forge plan runs offline and cannot open a Studio session, so every measured value below
is TBD until a human captures it in Studio and fills this table in.

| Metric | Budget | Measured | Method | Status |
| --- | --- | --- | --- | --- |
| Server heartbeat | >= 55 Hz | TBD | MicroProfiler server frames | TBD |
| Client FPS (low-end mobile) | >= 30 FPS | TBD | Stats service, 1st percentile | TBD |
| BaseParts in `KaijuEggRaidersWorld` | <= 6000 | TBD | `workspace:GetDescendants` filter | TBD |
| Client memory | < 800 MB | TBD | MicroProfiler memory view | TBD |
| Remote calls/s/player | <= 8.7 sustained | TBD | `core/anticheat` counters | TBD |

## Regression triggers

- Any change to `src/server/World.luau` part counts requires a fresh
  `workspace:GetDescendants` count before merge.
- Any new remote must add a `Config.anticheat` entry with `capacity` and
  `refillPerSecond`, and the sustained total (currently 8.7/s) must be re-summed.
- A heartbeat under 55 Hz or client FPS under 30 FPS on the mobile profile blocks release
  until the offending system is profiled and fixed.
