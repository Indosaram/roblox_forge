---
name: liveops
description: Load when running weekly ops reports, deploying environments, or shipping live changes.
---

# liveops

## When to use

- The weekly update routine runs: metrics, live events, and update PRs.
- A build must be deployed to staging or production, or an economy/live value changes.

## Steps

1. Produce the weekly report: `lune run cli/forge report --pack <slug>` — reads
   `games/<slug>/analytics/events.jsonl` and writes a tutorial/funnel/Robux-revenue
   summary to `reports/<slug>-weekly-<date>.md`. Use `lune run cli/forge report --all`
   for a cross-game dashboard instead. Neither command broadcasts a live event or
   creates a PR; open the weekly update PR yourself once you have reviewed the report.
2. Auto-deploy to staging only:
   `lune run cli/forge deploy --env staging --pack <slug>`
   (needs `ROBLOX_API_KEY`; missing key or unset `deploy.yml` ids exit 1 before any
   network call).
3. Production: after a **human merges** the PR, a human runs
   `FORGE_ALLOW_PRODUCTION=1 lune run cli/forge deploy --env production --pack <slug>`.
4. Ship price or probability changes only as a human-authored, human-merged PR — never
   from an agent run.

## Rules

- Agent auto-deploys go to **staging only**; production requires a human merge and
  `FORGE_ALLOW_PRODUCTION=1`.
- Price/probability changes and core/genre changes require a human-merged PR; core/genre
  PRs must pass every game pack's tests.
- Open Cloud keys are per-universe and minimal-scope; agents hold staging keys only, and
  secrets are never read or printed.
- A production bundle must contain no asset still `PendingModeration`.
- No paid random items: Robux sells only deterministic items; random hatching is
  free-currency only.
- Do not modify `core/` or genre modules from a liveops run.

## Verification

- `forge report --pack <slug>` (or `--all`) exits 0 and writes the report file under
  `reports/`.
- Staging deploy exits 0; production deploy refuses (exit 1, before any network call)
  without `FORGE_ALLOW_PRODUCTION=1`.
- `lune run cli/forge check` exits 0 on the merged PR.
