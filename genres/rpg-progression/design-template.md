# rpg-progression design template

## Common loop (plan §11.4)

Fight -> level/abilities -> unlock regions

## Progression systems

- **Stats** (`module/Stats.luau`): xp curve `xpForLevel(level) = base * level ^ exp`,
  level lookup, and `pointsPerLevel` stat points granted on each level-up.
- **Quests** (`module/Quests.luau`): quests built from `{ kind, target, count }`
  requirements with one-time `coins`/`xp` rewards; a quest claims exactly once.
- **Regions** (`module/Regions.luau`): regions gated by a `requiredLevel`
  threshold, with a force unlock for quest-gated content.
- **BossSpawner** (`module/BossSpawner.luau`): unlocks region bosses on an
  interval schedule; a region only spawns while it is unlocked.

## Loop beats

1. Defeat enemies and region bosses to earn xp and coins.
2. Level up for stat points; spend them on abilities.
3. Meet a region's level threshold (or finish its unlock quest) to open it.
4. Turn in quests for coins and xp, then push into the next region's boss.

## Hooks

Game packs register `OnBossSpawn` / `OnBossDefeated` and drive progression from
quest and region events; they never edit this module.
