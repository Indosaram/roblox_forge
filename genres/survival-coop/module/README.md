# survival-coop module

Reusable survival-coop loop: a wave scheduler that spawns escalating waves on a
fixed interval and resolves each one against a pack-supplied defense power. Game
packs register hooks and never edit this module.

```lua
local SurvivalCoop = require("genres/survival-coop/module/SurvivalCoop")
```

## API

- `SurvivalCoop.new(config, hooks) -> SurvivalCoop`
- `coop:tick(now) -> { index: number, enemies: number }?` — the first call arms
  the schedule; a wave is returned and `OnWaveSpawn` fires once `now` reaches the
  next wave time.
- `coop:defend(waveIndex, defensePower) -> boolean` — wins when
  `defensePower >= enemiesFor(waveIndex)`; always fires `OnWaveResolved`.
- `coop:enemiesFor(waveIndex) -> number` — `baseEnemies + (waveIndex - 1) * growth`.
- `coop:waveIndex() -> number` — waves spawned so far.
- `coop:nextWaveAt() -> number?` — absolute time of the next wave, nil before the
  first tick.
- `coop:secondsUntilNext(now) -> number` — clamped countdown.
- `coop:forceNext(now) -> wave?` — pulls the next wave forward to `now` (debug
  tooling) and resumes the normal cadence.

## config

| field | type | meaning |
|---|---|---|
| `waveInterval` | `number` | seconds between waves |
| `baseEnemies` | `number` | enemies in wave 1 |
| `growth` | `number` | extra enemies added each subsequent wave |

## hooks

| hook | context |
|---|---|
| `OnWaveSpawn` | `{ index: number, enemies: number }` when a wave spawns |
| `OnWaveResolved` | `{ index: number, enemies: number, defensePower: number, won: boolean }` after `defend` |
