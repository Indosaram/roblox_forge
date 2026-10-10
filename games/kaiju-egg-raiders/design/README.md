# Kaiju Egg Raiders - design

Concept: kaiju egg raiders ember tidal siege islands

Kaiju Egg Raiders is a collect-raid pack. Buy an egg, hatch it in seconds, and let the creature earn Coins at the base; spend those Coins on bigger eggs, merge 3-of-a-kind up a rarity, and join the team siege every 10 minutes to raid the rival vault. Sessions target 30
minutes; every 600 seconds a 120 second team siege window
opens on the shared vault.

## Pillars

- Hatch in under 60 seconds: the first egg pays for itself inside the first minute.
- Merge upward: three of a kind fuse into the next rarity, so the roster keeps growing.
- Team siege, never personal theft: raids only touch the shared enemy vault.
- Everything paid is deterministic: Robux buys fixed items, random hatching is free-currency only.

## Core loop

Buy an egg, hatch it in seconds, and let the creature earn Coins at the base; spend those Coins on bigger eggs, merge 3-of-a-kind up a rarity, and join the team siege every 10 minutes to raid the rival vault.

## Social and siege

Two teams each defend a shared vault. Every siege period a window opens for a fixed duration and squads move up to max_take eggs from the enemy vault. Personal bases are never a raid target. The design deliberately avoids 1:1 personal-base theft
and the "Steal a ..." title pattern, and routes all conflict through the team vault
siege instead.

## Retention

Retention leans on three hooks: daily quests (Hatch 3 eggs (+100 Coins), Buy 5 eggs (+150 Coins), Join 1 siege (+300 Coins)), a weekly liveops cadence, and the merge ladder that turns a Common roster into a long-tail Legendary collection goal.

## Roster

Eggs: Ember Egg (50 Coins), Tidal Egg (250 Coins).

Creatures: Ember Pup (Common, 1/s), Ember Stalker (Rare, 3/s), Ember Titan (Legendary, 8/s), Tidal Hatchling (Common, 1/s), Tidal Serpent (Rare, 3/s), Tidal Titan (Legendary, 8/s).

## Balance

Tuned by `forge plan` against the economy simulator; see `balance.md` for the
section-7 targets and `monetization.md` for the store strategy.
