# Support and Operations Guide

This document defines supported environments, toolchain specifications, operational procedures, and troubleshooting protocols for Roblox Game Forge.

## Platform Support Matrix

| Platform / Runtime | Support Level | Supported Capabilities | Notes and Limitations |
| --- | --- | --- | --- |
| Windows 10 / 11 (x64) | Tier 1 (Target) | Full CLI, Lune, Rojo, Studio MCP target | Primary development and verification target. Full Studio multi-actor QA, capture, and rejoin are partial historical proofs awaiting consolidated live validation. |
| Linux (x64) | Unclaimed | None claimed | Unverified. Headless operations remain unclaimed until exercised and proven. No glibc floor is guaranteed. |
| macOS | Unclaimed | None claimed | Unverified. Headless operations and Studio GUI integration remain unclaimed until exercised and proven. |

### Windows Studio Invariants and Target Support

Interactive Roblox Studio testing, place validation, and Studio MCP proxy operations target Windows. Under project rules:
- Background execution: Never present unsolicited windows on the Windows foreground.
- User authorization: Always request explicit user approval before launching Roblox Studio.
- Non-intrusive operations: Never directly manipulate the GUI with synthetic mouse clicks, key events, or window moves. All automation flows through product APIs like Studio MCP.
- Verification status: Historical receipts prove partial actor setup and motion, but real viewport capture and rejoin remain pending consolidated live verification. Non-Windows Studio automation is entirely unclaimed.

## Required Toolchain Versions

All toolchain binaries are managed by Rokit and pinned in `rokit.toml`. Do not install independent or unpinned versions:

| Tool | Pinned Version | Purpose | Upstream Source |
| --- | --- | --- | --- |
| rojo | 7.7.0 | Builds Luau projects into .rbxl place files | `rojo-rbx/rojo` |
| wally | 0.3.2 | Package manager for Luau libraries | `UpliftGames/wally` |
| lune | 0.10.5 | Standalone Luau runtime executing the Forge CLI | `lune-org/lune` |
| selene | 0.31.0 | Static linter for Luau code | `Kampfkarren/selene` |
| stylua | 2.5.2 | Opinionated code formatter | `JohnnyMorganz/StyLua` |
| luau-lsp | 1.70.1 | Language server and type analyzer | `JohnnyMorganz/luau-lsp` |

### Installing the Toolchain

In the root of the repository, execute:
```powershell
rokit install
```
Verify that each binary is available in your PATH:
```powershell
lune --version
rojo --version
selene --version
stylua --version
luau-lsp --version
```

### Auxiliary Runtimes

Forge admits the running Lune using its `_VERSION` global, not the version of a
different executable found on PATH. The release requires the exact `rokit.toml`
pin. Before mutation, generation requires pinned StyLua; build requires pinned
Rojo; check requires pinned Selene, StyLua, luau-lsp, Rojo, and its child Lune.
Missing or mismatched prerequisites report `FORGE_TOOL_UNAVAILABLE`,
`FORGE_TOOL_UNSUPPORTED`, or `FORGE_RUNTIME_UNSUPPORTED` and installation guidance.
The checks reuse Forge's existing Rokit/PATH executable resolution. They do not
install tools. Prerequisite refusal preserves previous outputs; an admitted build
that fails compilation still removes stale build outputs.

- **Node.js or Bun**: Used for peripheral evaluation or testing scripts. Version floors are not formally bounded and remain untested.
- **PowerShell / Shell**: PowerShell or standard command shells on Windows hosts can invoke the CLI. Compatibility floors are untested.
- **Roblox Studio**: Required for running `--studio` QA scenarios and Studio MCP bridging.

## Operational Modes and Boundaries

### Clean Archive Extraction (Zero Secrets)

A clean archive recipient can inspect, verify, scaffold, and build without private API keys or owner paths:
1. Extract repository archive to a clean directory.
2. Run `rokit install`.
3. Run `lune run cli/forge check`. All checks, type analysis, unit specs, and place builds execute. On a clean checkout without a local cache, this step downloads type definitions from GitHub to `build/cache/globalTypes.d.luau`. Once cached, subsequent runs are completely network-free.
4. Run `lune run cli/forge plan --concept "Treasure hunt in cloud ruins" --genre collect-raid --pack cloud-raiders --seed 123`. Scaffolding completes deterministically from local genre templates.
5. Run `lune run cli/forge build --pack cloud-raiders`. Places compile to `build/cloud-raiders.rbxl`.

### Keyless vs. Credentialed Operations

| Command / Category | Network Required? | Credentials Required? | Failure Behavior Without Credentials |
| --- | --- | --- | --- |
| `check` | First run only (definitions cache) | None | Keyless. Requires network if `build/cache/globalTypes.d.luau` is absent; once cached, runs network-free. |
| `build` | No | None | Invokes local Rojo compiler. Writes to `build/<pack>.rbxl`. |
| `inspect` | No | None | Reads local `.rbxl` binary place file. |
| `new` / `plan` | No | None | Scaffolds files deterministically from local genre templates. |
| `codegen` | No | None | Regenerates Luau config from local `econ.yml`. |
| `econ sim` | No | None | Simulates in-memory economy over local data models. |
| `gen procedural` | No | None | Generates meshes and icons using pure mathematical generators. |
| `gen audio` | No | None | Synthesises WAV waveforms via pure Luau DSP. |
| `gen image` | Yes | `IMAGE_GEN_URL` | Exits 1 with `missing env IMAGE_GEN_URL` before any call. |
| `gen mesh` | Yes | `TRELLIS_URL` | Exits 1 with `missing env TRELLIS_URL` before any call. |
| `gen sfx` | Yes | `ELEVENLABS_API_KEY` | Exits 1 with `missing env ELEVENLABS_API_KEY` before any call. |
| `assets check` | No | None | Validates licenses against local allow-list. |
| `assets status` | Yes | `ROBLOX_API_KEY` | Exits 1 with missing key error before connecting. |
| `deploy --dry-run` / `deploy plan` | No | No API credentials; local evaluator authority for assessed release plans | Requires current release approval or explicit named development staging. Writes markdown by default, JSON with `--out`; proves no API success or external authorization. |
| `deploy` (live) | Yes | Selected `ROBLOX_STAGING_API_KEY` or `ROBLOX_PRODUCTION_API_KEY` and matching universe/place bindings; `FORGE_ALLOW_PRODUCTION=1` for production only | No generic-key fallback. Local quality gate precedes credentials and side effects. Assessed release uploads approved bytes without rebuilding; named development staging builds and inspects first. |
| `locale check` | No | None | Scans client literals and local `strings.csv`. |
| `locale sync --dry-run` | No | None | Generates JSON payload offline. |
| `liveops push --dry-run` | No | None | Prints target URL and `topic`, `messageBytes`, `messageSha256`; no raw event payload. |
| `liveops push` (live) | Yes | `ROBLOX_STAGING_API_KEY`, `ROBLOX_STAGING_UNIVERSE_ID` | No generic-key fallback. Missing, shared or mismatched credentials refuse before request. |
| `smoke --local` | No | None | Executes local Lune smoke scripts. |
| `smoke --cloud` (live) | Yes | `ROBLOX_API_KEY` | Exits 1 before posting Open Cloud Luau execution task. |
| `qa run --native` | No | None | Executes deterministic Luau test harness over pure clock. |
| `qa run --studio` | Local loopback | Studio MCP receipt | Exits 1 if Studio connection receipt is absent. |

## Starter vs. Release Approval

The framework enforces quality gates before code or assets can be published to production:

```
[ Starter Tier / Legacy Unassessed ]
      │
      ▼ (offline scaffolding, passes quality check without external authority)
[ Vertical Slice ]
      │
      ▼ (requires attested observation receipt, no disqualifiers)
[ Release Candidate ]
      │
      ▼ (requires authorized evaluator attestation + digest binding)
[ Staging / Production Deployment ]
```

1. **Starter Tier / Legacy Unassessed**: Initial project state. Validated by `lune run cli/forge quality check --pack <slug> --target starter`. Passes without attestation files or external evaluator environment variables. Legacy packs without `quality.yml` evaluate as unassessed.
2. **Release Candidate**: Production-ready game state. Validated by `lune run cli/forge quality check --pack <slug> --target release-candidate`.
   - Requires `FORGE_QUALITY_EVALUATOR` environment variable matching the evaluator identity.
   - Requires `FORGE_QUALITY_ATTESTATION` path pointing to an attestation document matching the receipt digest.
   - Profile must contain no unassessed disqualifiers, no failed criteria, and no failed first-play goals.
   - Release builds bind exact SHA-256 digests across source, assets, rubric, evidence, and build place binaries.

Production planning and publishing, and nondevelopment staging, require a declared release-candidate and current approved receipt. Local attestations are not cryptographic signatures. Live assessed deploy reuses `build/<pack>.rbxl` and its current identity evidence rather than rebuilding it. Build changed artifacts separately and obtain new quality evidence before release. Missing, malformed, inconclusive, or stale evidence refuses before report writes, builds, or network calls.

Legacy packs remain unassessed and retain normal build support. The explicit exception is `deploy plan --env staging --pack <slug> --development` (or live deployment with the same named staging flags). It never approves a release and cannot override a release-candidate declaration or production target. Development live deploy uses the shared inspected build and identity-sidecar path. Offline plans require no API key or production switch and do not prove API success or human authorization.

## Operational Recovery and Troubleshooting

### Toolchain Failures

- **Symptom**: `selene`, `stylua`, or `luau-lsp` command not found.
  - **Resolution**: Run `rokit install`. Ensure your user PATH environment variable includes `%USERPROFILE%\.rokit\bin` (Windows) or `~/.rokit/bin` (Unix).
- **Symptom**: `luau-lsp` reports definitions error.
  - **Resolution**: `cli/forge/commands/check.luau` checks `build/cache/globalTypes.d.luau` against SHA-256 `2857efa8245485f8c25c19c018ee1ef9b46afab4efd2ea70fc3257cd3faf7080`. If missing, it downloads definitions from `https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.70.1/scripts/globalTypes.d.luau`. Ensure network access on first run and writable `build/cache/`.

### Economic and Asset Drift Failures

- **Symptom**: `check` fails at stage `econ` with `econ drift: ... is out of date`.
  - **Cause**: Someone modified `games/<pack>/econ.yml` without running codegen.
  - **Resolution**: Run `lune run cli/forge codegen <pack>`. Commit the updated `GenreConfig.luau` or `EconConfig.luau`.
- **Symptom**: `check` fails at stage `assets` with `assets drift: ... is out of date`.
  - **Cause**: Assets manifest modified without updating Lua module bindings.
  - **Resolution**: Run `lune run cli/forge assets codegen --pack <pack>`.
- **Symptom**: `check` fails with `paid random item: <key>`.
  - **Cause**: A paid developer product or gamepass was configured with random probabilities or lootbox mechanics.
  - **Resolution**: Project rules prohibit paid random items. Convert the reward to free currency or sell deterministic items only.

### Studio MCP Connection Issues

- **Symptom**: `qa run --studio` fails with `Studio discovery receipt not found` or `studio_connected: false`.
  - **Cause**: Studio MCP proxy is not connected or discovery receipt has not been generated.
  - **Resolution**: Do not attempt to bypass this with headless fallbacks. Verify Studio is running with MCP proxy enabled, generate the receipt, and rerun with `--studio-receipt <path>`.

### Deployment Refusals

- **Symptom**: `refusing production deploy: set FORGE_ALLOW_PRODUCTION=1`.
  - **Cause**: Production safety guardrail triggered.
  - **Resolution**: Obtain the required human-merged production approval and explicit external-release authorization before setting `FORGE_ALLOW_PRODUCTION=1` in the deployment terminal. The switch alone proves neither approval nor API success; offline plans do not require it.
- **Symptom**: `deploy quality: QUALITY_GATE_FAILED`.
  - **Cause**: The place artifact does not meet release-candidate criteria or is unassessed.
  - **Resolution**: Inspect `games/<pack>/quality.yml` and the current schema-2 receipt and attestation. Rebuild changed artifacts separately and collect current evidence before assessed release. For non-release development only, use `--env staging --pack <slug> --development`; a declared release-candidate cannot use that exception.
- **Symptom**: `deploy quality: LEGACY_UNASSESSED`.
  - **Resolution**: The pack has no assessed quality profile. Normal builds remain supported. Use explicitly named development staging for development work; production plans and publishing remain refused.
- **Symptom**: `invalid deploy target: ... require positive finite integers`.
  - **Resolution**: Correct the selected environment's `universeId` and `placeId` in `deploy.yml`, or set the variable its `${FORGE_<ENV>_UNIVERSE_ID}` / `${FORGE_<ENV>_PLACE_ID}` reference names. This configuration change invalidates prior assessed evidence; obtain current approval before release.

See [Release authorization](authorization.md) for the artifact, evaluator, credential, and human-approval boundaries.

Deploy requires exact decimal `ROBLOX_<ENV>_UNIVERSE_ID` and `ROBLOX_<ENV>_PLACE_ID` strings matching the selected `deploy.yml` target, which may itself be a literal id or a `${FORGE_<ENV>_UNIVERSE_ID}` / `${FORGE_<ENV>_PLACE_ID}` reference resolved from the environment. Liveops requires the staging universe binding only. `CREDENTIAL_MISSING`, `CREDENTIAL_SHARED`, and `CREDENTIAL_TARGET_MISMATCH` identify credential refusals; `TARGET_ENVIRONMENT_OVERLAP` refuses shared configured environment targets. Equal staging/production keys are rejected when both are loaded. Local bindings do not prove provider-side permissions.

Deploy and liveops make one POST attempt and do not automatically retry, including HTTP 429. They report `PUBLISH_PERMISSION_DENIED`, `PUBLISH_RATE_LIMITED`, `PUBLISH_TIMEOUT_AMBIGUOUS`, `PUBLISH_TRANSPORT_AMBIGUOUS`, `PUBLISH_MALFORMED_REPLY`, `PUBLISH_HTTP_ERROR`, or `PUBLISH_ACCEPTED`, without raw provider body/status text or thrown transport text. Reconcile actual target state before any separately authorized repeat after an uncertain result. Accepted response validation is not delivery proof.

Deploy/liveops use installed Bun native fetch through a repository-relative helper, with a 30-second abort and Lune-owned 35-second kill/reap watchdog. Missing executable or fetch capability yields `PUBLISH_TRANSPORT_UNSUPPORTED`; there is no unsafe CLI override. Target runtime is Bun 1.4 on Windows with Lune 0.10.5; consumer version discovery and all execution remain deferred, and a real authorized pilot remains unproved. See [Operations](operations.md) for code-specific recovery and [Rollback](rollback.md) before another publish or restore.

Retain sanitized numeric HTTP status when available, accepted deploy version and `artifactSha256`, and accepted liveops message SHA-256 for reconciliation. These fields are local audit output, not independent delivery evidence. A synthetic schema2 authorized deploy caller fixture now exercises the real quality gate, artifact bytes and shared adapter. Its execution remains deferred; it is not live authorization evidence.
