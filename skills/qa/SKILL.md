---
name: qa
description: Load when validating QA scenarios, planning a test run, or verifying a build end to end.
---

# qa

## When to use

- Before committing or deploying: lint, specs, build, and scenario coverage must pass.
- A genre QA scenario (tutorial, core loop, first purchase, rejoin) needs verification.

## Steps

1. Validate every genre's QA scenarios: `lune run cli/forge qa validate`
2. Plan the run for one pack: `lune run cli/forge qa plan --pack <slug>`
3. Run the full pipeline: `lune run cli/forge check` — selene, `stylua --check .`,
   luau-lsp analyze, econ drift, all `*.spec.luau` under `core/`, `games/`, `cli/`,
   `genres/`, `rojo build`, then built-place inspection.
4. Run actual local smoke with `lune run cli/forge smoke --pack <slug> --local`,
   or the separately configured cloud lane. Finish under 60s; cloud submits one
   task per invocation with a 300s service timeout, not a QA scenario scheduler.
   A missing local smoke script exits 0; treat this as missing proof, not a pass.
5. After permission to launch Studio, use the MCP playtest lane, inject inputs, and capture
   `screen_capture` frames for each genre scenario.

## Rules

- `forge plan` produces starters, not quality approvals. Run `forge quality validate`
  for declaration schema and `forge quality check --pack <slug>` for the declared
  tier. Starter success is explicitly not release approval. Higher targets need
  current source/config/assets/build/reference/evidence digests and an authorized
  evaluator receipt; missing, failed or inconclusive evaluation fails closed.
- `forge quality evaluate --pack <slug> --capture <dir> --reference <path> --out <path>`
  invokes the configured evaluator on actual first-play evidence. Do not substitute
  assertions, synthetic captures or invented grades for judgment. Configure
  `FORGE_QUALITY_EVALUATOR` and `FORGE_QUALITY_ATTESTATION` for receipt checks.
- `forge deploy plan --pack <slug> --env staging --out <path>` is local-only and
  gates declared release-candidates against `build/<slug>.rbxl` before network
  preflight. `--development` explicitly permits staging development for lower
  tiers only; it never authorizes a release-candidate. Legacy packs without
  profiles remain unassessed. Production human authorization remains separate.

- API 1 uses qualified `<genre>:<scenario>` names and requires every generator's
  declared scenarios, including contract-loop/rejoin. Scenarios declare
  contract_api: 1, operations and declared targets. Validation checks schema;
  planning writes a report, not execution proof. Contract smoke estimates >60s
  fail (60 allowed); legacy bare selections retain warnings. Measure actual
  headless runtime under 60s. No prose-pinning tests.
- Deterministic drivers run the actual Executor/native adapters with fixed RNG
  and nondecreasing clocks. Assert native state, rejected-input immutability,
  once-only settlement and rejoin, not just ok. Composition proof requires
  baseline loss, farm/sell/upgrade win and one wallet reward, not separate sims.
- Generic Studio QA lives in server-only ServerStorage.ForgeQA, a Folder with
  individual BindableFunctions. Call qa.dispatch:Invoke(genre,action,args,playerId),
  qa.snapshot:Invoke(genre,playerId), qa.advanceTo:Invoke(epoch),
  qa.save:Invoke(playerId) (Result then envelope), qa.restore:Invoke(playerId,save).
  beginClock:Invoke() freezes a base; advanceElapsed:Invoke(seconds) advances from
  it. StateChanged.Event signals the exact revision. Do not call Invoke on the
  Folder; schema validation alone cannot prove scenario code uses the correct API.
  This surface exists only in Studio, not as replicated admin remotes or a
  guaranteed Open Cloud API. Collect retains its separate legacy QA surface.
- Subscribe to the exact async state/profile signal before triggering action,
  then await with bounded timeout. No fixed sleeps/polling delays. Explicit clock
  advance tests time without waiting for wall time.
- Check discovers the contract registry, validates QA schemas and compares
  GenreConfig or legacy EconConfig against the source format. Run actual
  generated smoke/build proof as well; schema validation does not execute QA.
- Generic starters have no paid catalog. Legacy purchase-scenario validation is
  not purchase execution. Headless checks do not establish production assets,
  rendered fashion, multiplayer UX or performance.

- CI smoke must stay under 60s; keep specs fast and self-contained.
- No network calls in specs; no Roblox publishing or asset uploading from tests.
- Headless servers cannot verify client rendering — that is why the MCP playtest lane
  exists; run both lanes, never one as a substitute for the other.
- Never manipulate the GUI directly; do GUI work only through product APIs such as
  Studio MCP, and ask the user before launching Roblox Studio.
- Judge QA screenshots only after assets are approved (not `PendingModeration`).
- Do not modify `core/` or genre modules to make a game-pack test pass.

## Verification

- `lune run cli/forge check` exits 0 and reports all specs passing.
- The CI smoke run completes in under 60 seconds.
- Playtest screenshots exist for supported tutorial/core loop/rejoin behavior.
  First-purchase proof requires a real deterministic catalog, not empty starter
  monetization or schema-only validation of a legacy scenario.
