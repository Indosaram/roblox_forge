# grow-and-defend-garden

Second game pack (plan §11.6 M5): genres `grow-harvest` + `survival-coop`, used to
prove that a playable prototype can be built with game pack config plus hook code
only — no core or genre changes.

Pivot candidate if Kaiju Egg Raiders underperforms (§7 W9-W12).

## Loop

Buy a seed for one Coin, plant it on one of three plots, wait for timed growth,
harvest to earn barricade points and sell for Coins. Every 60 s a wave attacks;
barricade points are spent as defense power, and surviving a wave pays Coins. All
pack-specific behavior is registered through genre hooks (`OnHarvest`,
`OnWaveSpawn`, `OnWaveResolved`) in `src/server/GardenServer.server.luau`; the
pack never edits core or genre code.

## Audio

Each of the four stages plays the grow-harvest cue the genre declares for it
(`genres/grow-harvest/genre-spec.yml` `audio:`). The client starts
`core/ui-kit/genre/AudioKit` with the genre's runtime audio module
(`genres/grow-harvest/module/Audio.luau`) and the pack's uploaded ids
(`src/shared/Assets.luau`), then names the canonical action it just committed —
`audio.result("grow-harvest:plant", { ok = planted == true })`. The kit resolves the cue
from the declaration, so no cue key appears in pack code. A cue whose asset is
missing or not yet uploaded plays nothing and is recorded on the kit's folder
attribute instead of erroring.

## Layout

- `game.yml`, `econ.yml` — pack config (`genres: [grow-harvest, survival-coop]`).
- `default.project.json` — Rojo tree mapping `core/domain`, `core/infra`,
  `core/ui-kit`, both genre modules, and `src/` into `ReplicatedStorage.Forge`.
- `src/shared/Config.luau` — 3 crops (seed price, growth time, sale price) and wave tuning.
- `src/server/GardenServer.server.luau` — remote handlers, hook wiring, heartbeat.
- `src/client/GardenClient.client.luau` — top-right buy/plant/harvest/sell panel.

Studio-only debug: `ServerStorage.GardenDebug` BindableFunction accepts
`"forceWave"` (spawn the next wave now) and `"growAll"` (make every plot ready).
