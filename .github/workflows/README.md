# ci.yml
Runs the repository's verification on ubuntu-latest for every push (any branch) and every pull request. Steps, in order:

1. **Checkout**: actions/checkout@v4.
2. **Install rokit**: CompeyDev/setup-rokit@v0.1.2 installs the rokit tool manager.
3. **Install tools**: `rokit install --no-trust-check` installs the toolchain pinned in rokit.toml (rojo, wally, lune, selene, stylua, luau-lsp).
4. **Set up lune type definitions**: `lune setup` generates the Luau type definitions that selene and the specs need.
5. **Install bun**: oven-sh/setup-bun@v2, installed before `forge check` and used by the JS suites.
6. **Run forge check**: `lune run cli/forge check`, the full repository verification.
7. **Run JS suites**: the JavaScript suites that Lune discovery omits (see docs/release/verification.md), each run as its own invocation so one failure does not hide the others; the step fails if any suite fails. `cli/release/capacity-collector.test.mjs` is excluded because it spawns Windows PowerShell/CIM and fails off Windows.
8. **Run local smoke**: `lune run cli/forge smoke --pack kaiju-egg-raiders --local`.
9. **Detect cloud credentials**: records only whether the `ROBLOX_API_KEY` secret is set (a boolean, never the value) as a step output.
10. **Run cloud smoke**: `lune run cli/forge smoke --pack kaiju-egg-raiders --cloud`, only when the secret is set. This is the only step that receives `ROBLOX_API_KEY` in its environment.
