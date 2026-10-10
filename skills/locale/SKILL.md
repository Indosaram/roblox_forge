---
name: locale
description: Load when extracting strings, translating, or syncing a game pack's localization.
---

# locale

## When to use

- Client literals were added or changed and `locale/strings.csv` must cover them.
- A translation pass or offline localization payload plan is due for a game pack.

## Steps

1. Verify coverage first:
   `lune run cli/forge locale check --pack <slug>`
   It fails when a client literal is missing from `locale/strings.csv` or a `ko-kr`
   value is empty, and prints `locale check: PASS (<file>, N strings)` otherwise.
   `--pack` defaults to `kaiju-egg-raiders`.
2. Build the offline localization payload from the reviewed CSV:
   `lune run cli/forge locale sync --dry-run --pack <slug>`
3. Review `reports/locale-sync-<slug>.json`: its entries contain key, source,
   context, and translations; its locales identify the CSV language columns.
   This command plans a payload only. It does not upload or confirm remote tables.
4. Re-run `lune run cli/forge locale check --pack <slug>` and `lune run cli/forge check`.

## Rules

- `forge locale check` is the gate: never skip it after touching strings or literals.
- Every game uses the same flow (plan §11.3): extraction, agent translation, then the
  Localization API — no per-game fork of the pipeline.
- Live upload and remote table confirmation require a separate implemented and
  authorized integration. An offline JSON report is not evidence of API sync.
- `ko-kr` must never be left empty; Automatic Translation [R9] plus agent review fills it.
- Translation happens in the agent lane; specs must not make network calls.
- Never read or print secrets; no Roblox publishing from this workflow.
- Do not modify `core/` or genre modules for a game-pack string change.

## Verification

- `lune run cli/forge locale check --pack <slug>` prints `locale check: PASS`.
- `lune run cli/forge locale sync --dry-run --pack <slug>` writes the intended
  entries and locales to `reports/locale-sync-<slug>.json` without an upload.
- `lune run cli/forge check` exits 0.
