# Sky Whale Egg Keepers - Launch Checklist

All items are unchecked. `USER DECISION` and `USER CONFIRMATION` items require the
owner to act; do not tick them from an automated run.

## Build

- [ ] `lune run cli/forge check` exits 0 on a clean checkout
- [ ] `lune run cli/forge codegen` output (`EconConfig`) matches `econ.yml`
- [ ] `default.project.json` builds the place without errors
- [ ] `assets/procgen.yml` matches the roster in `econ.yml`
- [ ] Server heartbeat and client FPS within budget

## Content

- [ ] First egg reachable from `currencies.Coins.starting` 100
- [ ] Merge families wired: 3 Common -> Rare, 3 Rare -> Legendary
- [ ] Siege window: 120 s open every 600 s period, maxTake 3
- [ ] Tutorial step fires: Buy your first egg from the base shop
- [ ] Tutorial step fires: Hold the incubator prompt to hatch it
- [ ] Tutorial step fires: Watch the creature produce Coins on the parade slot
- [ ] Tutorial step fires: Buy a bigger egg with the Coins you earned
- [ ] Tutorial step fires: Merge three of a kind into the next rarity
- [ ] Tutorial step fires: Open the store and read the deterministic item labels
- [ ] Egg odds panel shows each pool before purchase

## Monetization

- [ ] Game pass configured: 2x Coins (699 Robux)
- [ ] Game pass configured: VIP Slots +4 (699 Robux)
- [ ] Game pass configured: Auto Lock (199 Robux)
- [ ] Product configured: Guaranteed Rare Creature Pack (99 Robux)
- [ ] Product configured: Hatch Speed-Up (699 Robux)
- [ ] Product configured: Siege Shield (99 Robux)
- [ ] Product configured: Server Luck Boost 15m (199 Robux)
- [ ] Every product is deterministic; no Robux path opens a random roll
- [ ] Product IDs replaced from `0` with live Roblox asset IDs
- [ ] Prices reviewed against `design/monetization.md`

## Compliance

- [ ] Maturity questionnaire submitted (mild fantasy violence only, no blood)
- [ ] No romance, no gambling, no paid randomness declared
- [ ] Probability disclosure shown on every egg purchase
- [ ] Social features limited to default Roblox chat
- [ ] Store listing text and thumbnails match `design/store-listing.md`

## Ops

- [ ] DataStore profile migration path tested
- [ ] Rejoin and offline-collection path tested
- [ ] Anticheat counters alarm at their sustained thresholds
- [ ] Rollback plan documented for the public switch

## Publish

- [ ] Group ownership needs 100 Robux (USER DECISION)
- [ ] Staging experience created
- [ ] Place uploaded to the staging experience
- [ ] Staging smoke test passed end to end
- [ ] Production Roblox asset IDs swapped into `game.yml`
- [ ] Public switch (USER CONFIRMATION)

Pack: `plan-demo` / genre: `collect-raid`.
