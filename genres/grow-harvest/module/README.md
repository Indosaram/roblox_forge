# grow-harvest module

Reusable grow-harvest loop: plant a crop in a plot, wait for timed growth, harvest
it, and sell it. Growth timing reuses `core/domain/progression/HatchTimer`; sale
credits an internal `core/domain/economy/Wallet`. Game packs register hooks and
never edit this module.

```lua
local GrowHarvest = require("genres/grow-harvest/module/GrowHarvest")
```

## API

- `GrowHarvest.new(config, hooks) -> GrowHarvest`
- `garden:plant(plotIndex, cropId, now) -> boolean` — fails on unknown crop,
  occupied plot, or index outside `1..plotCount`.
- `garden:harvest(plotIndex, now) -> cropId?` — nil until ready; clears the plot
  and fires `OnHarvest` on success.
- `garden:sell(cropId) -> number` — credits the wallet by the crop's `sellPrice`
  and returns it; errors on an unknown crop.
- `garden:cropAt(plotIndex) -> cropId?`
- `garden:isReady(plotIndex, now) -> boolean`
- `garden:remaining(plotIndex, now) -> number`
- `garden:balance() -> number` — wallet balance in `config.currency`.
- `garden.wallet` — the underlying `Wallet`, for pack-side credits (wave rewards).
- `garden:readyAll(now)` — marks every planted crop ready (debug tooling).

## config

| field | type | meaning |
|---|---|---|
| `crops` | `{ [string]: { growthSeconds: number, sellPrice: number } }` | crops by id |
| `plotCount` | `number` | number of plantable plots |
| `currency` | `string?` | wallet currency, defaults to `"Coins"` |
| `startingBalance` | `number?` | optional wallet seed |

## hooks

Called with a table `{ plot: number, cropId: string, now: number }`.

| hook | when |
|---|---|
| `OnPlant` | after a crop is planted |
| `OnHarvest` | after a ready crop is harvested and the plot cleared |
