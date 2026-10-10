# Deterministic authoring and regeneration

`lune run cli/forge plan --concept "Crystal island explorers" --genre survival-coop --pack crystal-island --seed 7`
uses local, package-owned templates and deterministic generators, not an LLM or
remote design service. Concept text and seed do not imply arbitrary new gameplay.
Collect-raid has its richer legacy planner; the other registered starters expose
their genre defaults. Supported single genres are collect-raid, grow-harvest,
survival-coop, rpg-progression, social-rp-fashion and pvp-arena. Multi-genre
selection requires an explicitly registered recipe.

Byte reproducibility requires the same concept, seed, title, teams, binding names,
mode, genre selection, destination, package versions, toolchain and existing
authored/publication inputs. Relative package imports depend on destination.
Generation is not release approval or evidence of playable production quality.

## Ownership

Generated configuration, thin bindings, project and lock files, smoke drivers,
asset recipes and generated asset outputs belong to the generator. Core and
genre implementations are referenced, not copied into packs. Edit package hooks
or configuration rather than copying these implementations.

`src/server/GenreHooks.luau` is seeded once and thereafter preserved byte for
byte. Its `forge-hooks:1:<ordered genres>` comment identifies its contract.
An unknown version or changed selection is a regeneration conflict, even with
`--force`. Do not remove the marker to bypass migration. Unmarked existing hooks
are accepted only with matching API 1 `game.yml` metadata. Hook code is trusted
server code; preserving it does not validate its behavior. Legacy collect-raid
does not emit the generic GenreHooks module.

Existing deploy bytes, matching monetization IDs, asset publication fields and
custom entries retain the publisher's preservation rules. Files outside the
generated map are retained, except capability-owned Assets/ProcAssets/asphalt
outputs and generated audio/icon/thumbnail directories. Crafting's explicitly
authored presentation and provisioning inputs retain its existing ownership
rules. Changes to generated files can be replaced; a dirty Git tree is not an
authorization to delete unrelated files.

## Publication and recovery

Assembly validates contracts, asset recipes and budgets before publication.
`FORGE_INVALID_INPUT` identifies invalid seed/slug input;
`FORGE_INVALID_CATALOG` identifies assembly/catalog errors;
`FORGE_REGEN_CONFLICT` identifies incompatible hooks, mismatched destination,
pending transactions or destination edits during generation. The diagnostic code
prefix is stable; the trailing explanation may include a nested tool error.

The CLI generates into `<destination>.forge-stage/<slug>`, including asset
codegen and formatting, leaving the existing destination untouched while those
steps execute. A before/after byte snapshot rejects detected concurrent edits.
Publication copies prior bytes into the staging tree's `prior/` directory and
publishes `journal.json` before replacing any destination file. Every generated
file is replaced using same-volume `fs.move(source, target, true)`. The destination
directory is never moved away. Lune 0.10.5 implements this as an overwrite rename,
not a remove-then-copy operation. A completion marker precedes journal cleanup.

This is per-file replacement, **not whole-pack atomicity**. A killed process can
leave complete files from mixed revisions. Do not build, sync or play a pack
with a pending journal. On restart, `genrepublish.recover(destination)` restores
the prior revision in place; both assembly and direct publication call recovery.
Recovery itself is repeatable after interruption. Unexpected edits to affected
files stop recovery with `FORGE_RECOVERY_REQUIRED` rather than erasing those
edits. A completed transaction only needs cleanup. An ownership marker containing
the canonical destination is installed before generation. Recovery validates it
before deleting any staging state, including completion-only state. An owned
pre-journal stage is safe to remove because destination writes have not started.
An absent, malformed or mismatched ownership marker requires manual inspection;
recovery preserves that directory and its contents. A kill during the brief
ownership-marker installation itself can leave such an unowned directory.

Cleanup first installs a destination-bound `forge-publication-cleanup` marker
at `.forge-backup`, outside the staging tree. It removes that marker only after
the staging tree is gone. Restart validates the cleanup marker and resumes
removal, even if recursive deletion already removed the internal ownership or
completion files. Consumers remain blocked through this cleanup interval.

Use a single writer and stop editors/sync while publishing or recovering. This
API does not lock out another process or guarantee coherent live readers during
replacement, power-loss durability or hostile symlink handling. Registry failures
at `new` and `plan` now carry `FORGE_INVALID_CATALOG`. Direct callers of
`genrepublish.write` use the same journaled implementation as the CLI.

Forge build/check/QA consumers use `packpublication.pending` and reject a pack
with `FORGE_PUBLICATION_PENDING` while its `.forge-stage` or obsolete
`.forge-backup` sibling exists, regardless of journal contents. Completion-only,
malformed and pre-journal staging states also fail closed. Consumers do not
perform recovery. Raw Rojo commands, an already running Rojo server and manual
Studio sync bypass Forge's ingress; stop them before generation and restart only
after recovery and cleanup. These guards do not claim whole-pack crash atomicity
or concurrent reader/writer synchronization.

Pinned API evidence: [Lune filesystem implementation](https://github.com/lune-org/lune/blob/v0.10.5/crates/lune-std-fs/src/lib.rs),
[overwrite options](https://github.com/lune-org/lune/blob/v0.10.5/crates/lune-std-fs/src/options.rs),
and [Rust rename semantics](https://doc.rust-lang.org/std/fs/fn.rename.html).
The Windows interruption regression remains a required execution check, not a
claim that these sources alone prove the full publication sequence.
