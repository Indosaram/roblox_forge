# grow-and-defend-garden

Second game pack (plan §11.6 M5): genres `grow-harvest` + `survival-coop`, used to
prove that a playable prototype can be built with game pack config plus hook code
only — no core or genre changes.

Pivot candidate if Kaiju Egg Raiders underperforms (§7 W9-W12).

## Loop

Plant crops on three plots, wait for timed growth, harvest to earn barricade
points and sell for Coins. Every 60 s a wave attacks; barricade points are spent
as defense power, and surviving a wave pays Coins. All pack-specific behavior is
registered through genre hooks (`OnHarvest`, `OnWaveSpawn`, `OnWaveResolved`) in
`src/server/GardenServer.server.luau`; the pack never edits core or genre code.

## Layout

- `game.yml`, `econ.yml` — pack config (`genres: [grow-harvest, survival-coop]`).
- `default.project.json` — Rojo tree mapping `core/domain`, both genre modules,
  and `src/` into `ReplicatedStorage.Forge`.
- `src/shared/Config.luau` — 3 crops and wave tuning.
- `src/server/GardenServer.server.luau` — remote handlers, hook wiring, heartbeat.
- `src/client/GardenClient.client.luau` — top-right plant/harvest/sell panel.

Studio-only debug: `ServerStorage.GardenDebug` BindableFunction accepts
`"forceWave"` (spawn the next wave now) and `"growAll"` (make every plot ready).
