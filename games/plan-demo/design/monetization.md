# Sky Whale Egg Keepers - Monetization

## Strategy

The store is a thank-you for players who enjoy the loop, never a gate. Every
Robux item is deterministic: the label names exactly what is granted, and random
hatching runs only on free `Coins`. There is no paid loot box.

## Price ladder

| Tier | Robux | Item |
| --- | ---: | --- |
| pass/coins2x | 699 | 2x Coins |
| pass/vipSlots | 699 | VIP Slots +4 |
| pass/autoLock | 199 | Auto Lock |
| product/creaturePack | 99 | Guaranteed Rare Creature Pack |
| product/hatchSpeedup | 699 | Hatch Speed-Up |
| product/siegeShield | 99 | Siege Shield |
| product/luckBoost | 199 | Server Luck Boost 15m |

Ladder source: `price_ladder` in `genres/collect-raid/econ-template.yml` (low 99, mid 199, high 499, premium 699).

## Game passes

- **2x Coins** (699 Robux) - Doubles coin income.
- **VIP Slots +4** (699 Robux) - Adds four production slots.
- **Auto Lock** (199 Robux) - Auto-locks your creatures before a siege.

## Developer products

- **Guaranteed Rare Creature Pack** (99 Robux) - Grants one fixed Rare creature.
- **Hatch Speed-Up** (699 Robux) - Instantly finishes the current hatch.
- **Siege Shield** (99 Robux) - Blocks one incoming siege for 30 minutes.
- **Server Luck Boost 15m** (199 Robux) - Improves free-hatch odds for the server for 15 minutes.

## First-purchase moment

The simulator spaces the first `Coins`-blocked moment to 10-30 minutes, where the deterministic shelf (starting with the 99-Robux Guaranteed Rare Creature Pack) is offered before the next egg becomes affordable.

## Fairness rules

- Every Robux item is deterministic: the label names exactly what is granted.
- Random hatching runs only on free currency; no Robux ever opens a random roll.
- The luck boost only shifts free-hatch odds and never sells a random item.
- A team siege only moves free-produced Common value; paid creatures are never stolen.
