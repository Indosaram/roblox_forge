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
- `0a85071`: none.
- `e00b1c2`:
  - `core/domain/island/ArchipelagoTerrain.luau`, `core/infra/render/MeshAdapter.luau`
- `ba14665`: none (CLI only).
- The 2026-10-23 late-service batch (the commit this note ships in) is the
  largest of these: 7 core files and 66 `genres/survival-coop` files. New genre
  modules are `Stance.luau`, `StanceExtension.luau`, `GuideEvents.luau`,
  `GuidePanel.luau`, `OperationExtension.luau`, `OperationPanel.luau`,
  `OrganizationsPanel.luau`, `RecipeMarks.luau` and `CosmeticVisual.luau`; new
  core files are `core/domain/survival/Spoilage.luau` and its spec. Run
  `git show --name-only -- core genres` on that commit for the full list.

**Not landed.** The ProcProps patch is still uncommitted. It touches
`core/domain/procgen/Prop.luau`, `core/domain/procgen/Prop.spec.luau` and
`cli/forge/lib/procgen.luau`, and it is not covered by this note.

## ADR-11: `locale/strings.csv` ships as a LocalizationTable, not as Luau tables (2026-10-23)

**Decision.** The pack's authored text reaches the client through a single
LocalizationTable built from `games/robango-island/locale/strings.csv`, mounted
at `Forge.games["robango-island"].Strings` by `default.project.json`. The three
modules that hand-copied those rows — `EntityNames.luau` (23.5 KB),
`JournalText.luau` (11.1 KB) and `MissionText.luau` (11.9 KB) — are deleted, and
a 2.9 KB `src/shared/PackText.luau` rebuilds the entity names and the authored
journal and mission lines from the table at runtime.

**Why.** The QA-PERF-01 static source budget (`qa-evidence.spec.luau`) caps the
built place at 3,000,000 source bytes and the batch had crossed it at 3,009,159.
A LocalizationTable is not a script, so the CSV no longer counts against source
bytes; it costs 66 KB of place file instead, which has its own, looser budget.

**Consequences.**
- `strings.csv` is the single source of this text. Adding a row is enough; there
  is no Luau copy to keep in step, and no codegen step either.
- Specs read the same builder over the real CSV through
  `games/robango-island/PackText.fixture.luau`, which is not built into the place.
- A pack that wants pack text on the client follows the same shape; nothing in
  `core` or `genres` changed for it.

**Evidence.** `entity-names.spec.luau`, `mission-text.spec.luau` (EN and KO for
every mission `dialogueKeys` entry, plus a case asserting the project ships the
table and the client reads it), `social-panels.spec.luau`, and QA-PERF-01 itself,
which now measures 2,959,389 source bytes and 1,250,997 place bytes.

## ADR-12: Player copy lives in `locale/strings.csv`, not in Luau tables (2026-10-24, `03ecb30`, `888ea31`)

**Decision.** ADR-11 now covers all player-facing text, not just the pack's
authored rows. Copy for the survival-coop screens used by this pack lives in
`games/robango-island/locale/strings.csv` (with its `provenance.csv` row) and
reaches the client through the same LocalizationTable. Modules read it by key:
- `ScreenText.use(PackText.lookup(rows, "scr."))` for the recovered screens and
  the navigator (p94b);
- `PackLocale.use(PackText.lookup(rows, ""))` plus `PackLocale.rows(tbl, prefixes?)`,
  which gives a module's local table an `__index` fallback to the CSV (p94c,
  p97);
- `PackText.lookup` / `PackText.names` for pack text and entity names (ADR-11).

An unknown `scr.*` key renders "" and never its id. With no lookup installed,
`PackLocale` returns nil, so other packs behave as before.

**Why.** QA-PERF-01. Text in a Luau table counts as script source; a
LocalizationTable does not. The batch reached 3,012,722 source bytes against
the 3,000,000 limit (`p94/fix.md`). After p94 the margin to the 2,985,000-byte
future limit was 120 bytes, and `b5a8fa2` left 24 bytes. p97 moved the remaining
text tables (782 new rows) and measured sourceBytes 2,911,288, futureBytes
2,923,724, a 61,276-byte margin (`p97/headroom.md`). The budget was not raised.

**Rule for new strings.**
- Add the row to `strings.csv` (en-us and ko-kr) and `provenance.csv`; do not add
  a Luau text table or a Luau copy of a CSV row.
- Use the module's namespace (`scr.`, `hud.`, `soc.`, `chr.`, `mus.`, `fct.`,
  `ctr.`, `cli.`, `brl.`, `act.`, `trv.`, `exp.`, `wld.`). If an unprefixed key
  already exists with different text, add a namespaced key rather than change it.
- Specs that load these modules install `games/robango-island/PackText.fixture`,
  which reads the real CSV.
- Run `forge check --only locale,provenance`; a row flagged by the provenance
  n-gram gate stays out until a human reviews it (five such strings remain in
  Luau, listed in `p97/headroom.md`).

**Evidence.** `RecoveredScreens.spec.luau` (every literal `scr.*` key has
en-us and ko-kr rows), the spec adaptations in `p94/fix.md` and
`p97/headroom.md`, and QA-PERF-01 in `qa-evidence.spec.luau`. p97 reports a
full `forge test` run of 2850 passed, 0 failed. The moved text has not been
viewed in Studio on `888ea31` (see [qa-evidence.md](qa-evidence.md)).
