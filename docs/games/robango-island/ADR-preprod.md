# robango-island preprod decision notes

The original ADR-preprod.md (ADR-01..ADR-08) was kept in a gitignored research
folder (`.omo/ulw-research/20261016-023844-durango/preprod/`) that is no longer
present in this checkout. This file records decisions made after that, starting
2026-10-23. Other docs still cite ADR-07 and ADR-08 by number; this file does
not restate them.

## ADR-09: Axe and pickaxe tool-tier policy (2026-10-23, `23f5e8c`)

**Decision.** A gather node that requires a tool also accepts any owned tool of
the same family at the same or a higher tier. Before this, only the exact item
id was accepted, so the tutorial Flint Hatchet (`stone-axe`) could not cut
`starter-axe` wood on a1.s1.

**Shape.**
- The core schema gains an optional `toolPolicy` (`core/domain/survival/ContentV2.luau`).
- `genres/survival-coop/module/ToolTiers.luau` adds `accepts(content, required, candidate)`.
- The pack declares its families in `games/robango-island/content.yml` (`toolPolicy`, sourceId `lead-p38-axe-tier`):
  - axe: `stone-axe` 1, `starter-axe` 1, `axe-t1` 2, `axe-t2` 3, `axe-t3` 4
  - pickaxe: `stone-pick` 1, `starter-pickaxe` 1, `pickaxe-t1` 2, `pickaxe-t2` 3, `pickaxe-t3` 4
- `SurvivalFactory.luau` admission uses `ToolTiers.accepts`. The equipped and durability checks are unchanged.

**Consequences.**
- Lower tiers and tools from another family are still refused.
- A tool outside every family (for example `starter-club`) still needs an exact match.
- A pack with no `toolPolicy` keeps the old exact-id behaviour.
- The refusal notice reads `<tool> 이상 도구 장착 필요`.
- Six native replay hashes changed: crafting jobs freeze a copy of the content policies, and that copy now includes `toolPolicy`. The journals themselves are byte-identical (`.omo/evidence/robango-recovery/p38/wood.md`).

**Evidence.**
- `ToolTiers.spec.luau` and `games/robango-island/tool-tiers.spec.luau`.
- The native journeys `archipelago-first-stage-stone-axe` and `-onsite-axe` record PASS and replay MATCH.
- Studio showed the refusal path only (`p40/s.md`). See [qa-evidence.md](qa-evidence.md#studio-real-input-evidence-and-gates-2026-10-23).

## ADR-10: Core and genre changes landed on main without a PR (2026-10-23)

**Record.** AGENTS.md requires a human-merged PR for core/genre changes. On the
owner's instruction, the robango commits below went to `main` directly with no
PR. Every game pack's tests still ran in the lead's gates; for `23f5e8c` that was
check 13/13, 79/79 commands and 38 replays MATCH.

Core and genre files changed per commit (`git show --name-only -- core genres`):

- `5bcb0e6`:
  - `core/domain/island/ArchipelagoTerrain.luau`
  - `genres/survival-coop/module/ExpeditionModels.luau`, `ExpeditionPanels.luau`, `ExpeditionPanels.spec.luau`, `ExpeditionText.luau`
  - `genres/survival-coop/module/ExtensionPanels.luau`, `SurvivalHUD.luau`, `SurvivalHUDModel.luau`, `SurvivalHUDModel.spec.luau`
- `5c9f574`:
  - `genres/survival-coop/module/ExpeditionPanels.luau`, `ExpeditionPanels.spec.luau`
  - `genres/survival-coop/module/GatheringClient.luau`, `GatheringClient.spec.luau`, `GatheringRuntime.luau`, `GatheringRuntime.spec.luau`
  - `genres/survival-coop/module/MusicText.luau`, `ScoreEditorPanel.luau`, `ScoreEditorPanel.spec.luau`
  - `genres/survival-coop/module/Wildlife.luau`, `WildlifeWorld.luau`
- `813fb07`:
  - `core/domain/island/ArchipelagoTerrain.luau`
- `da51791`: none.
- `6d8fef3`:
  - `genres/survival-coop/module/ExpeditionPanels.luau`, `ExpeditionPanels.spec.luau`, `ExpeditionSheet.luau`
  - `genres/survival-coop/module/ExtensionPanels.luau`, `GatheringClient.luau`, `GatheringClient.spec.luau`
- `23f5e8c`:
  - `core/domain/island/ArchipelagoTerrain.luau`, `core/domain/survival/ContentV2.luau`
  - `genres/survival-coop/module/DinosaurRig.luau`, `DinosaurRig.spec.luau`
  - `genres/survival-coop/module/GatheringClient.luau`, `GatheringClient.spec.luau`, `GatheringClientPrompt.spec.luau`
  - `genres/survival-coop/module/SurvivalWorld.luau`, `ToolTiers.luau`, `ToolTiers.spec.luau`

**Not landed.** The ProcProps patch is still uncommitted. It touches
`core/infra/render/MeshAdapter.luau`, `core/domain/procgen/Prop.luau`,
`core/domain/procgen/Prop.spec.luau` and `cli/forge/lib/procgen.luau`, and it
is not covered by this note.
