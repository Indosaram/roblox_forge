# Maintained Studio QA driver

`qastudio.luau` invokes `bun cli/forge/qa/studio-driver.mjs --input <json>`.
The JSON contains the validated scenario and owned real server/client config.
Run from the repository root. No `.omo` executable dependency is required;
existing `.omo` configuration and evidence remain data, not tracked secrets.

The input, surface, gameplay and artifacts helpers preserve the existing MCP
transport, verify actual UserIds, and fail closed on missing events/capabilities.
The fixture is only a JSON-RPC protocol test server, never a gameplay provider.

For external observation/audio attachment use `--attach-supplement <json>`;
see `genres/survival-coop/qa-scenarios/studio-driver-contract.md` for exact fields
and remaining physical rejoin/video/crash-hook restrictions. Artifact output is
not an evaluator approval. No runtime validation was performed while authoring.

For the prepared Robango low-end performance probe (not a measured result), see
[`robango-performance.md`](robango-performance.md). It attaches to an existing
Play client, records one-second Stats samples for 120 seconds and explicitly
marks late startup observations as censored.
