# Operational boundaries and readiness

Status: AUTHORED_ONLY. No fixture, check, external API request, or pilot was run
for this change. The release plan forbids deployment and upload. A real Open
Cloud pilot therefore remains a release blocker, not an implied follow-up
permission. Local fixtures establish caller contracts only.

## Credentials and target isolation

Deploy selects only `ROBLOX_STAGING_API_KEY` or `ROBLOX_PRODUCTION_API_KEY`
according to `--env`. There is no fallback to `ROBLOX_API_KEY`. Bind the selected
key using `ROBLOX_<ENV>_UNIVERSE_ID` and `ROBLOX_<ENV>_PLACE_ID`, where ENV is
STAGING or PRODUCTION. Values must be the exact decimal IDs in `deploy.yml`.
Liveops supports staging only and requires its staging key and universe binding.
The CLI rejects equal staging/production keys when both are present and rejects
configured overlapping universe/place targets. Local bindings do not prove the
key's actual server-side permissions: issue distinct least-privilege keys scoped
to the intended resource and operation, and verify those scopes in the separately
authorized pilot. Never put key material in YAML, reports, fixtures or command
arguments. Other Open Cloud commands retain their own credential contracts.

Dry runs need no key and make no request. Liveops dry run emits its target URL,
topic, message byte count and SHA-256, not the event payload. These are local
audit identifiers, not provider delivery receipts. Analytics reports emit
aggregate registered counts and numeric revenue; malformed JSON errors name the
line but omit the decoder's potentially sensitive input excerpt. Keep raw input
logs access-controlled. Deploy plan metadata is authored pack content, not a
secret store; never embed credentials in catalog names or asset paths.

## Release readiness

Before an authorized release, retain the exact source revision, config/assets
digests, assessed place hash, schema2 approval evidence and backup manifest.
The release deploy path reuses the assessed place, holds its bytes across the
final quality check, and compares them before POST. Only named development
staging builds a new place. Neither offline plan nor quality approval grants
external publication authority; production additionally requires the human gate.

Readiness requires all of the following observations, not unchecked statements:

- Current consolidated checks and per-pack build inspection have passing receipts.
- Selected IDs and separately issued key scopes match, and staging/production
  resources are distinct. Never record the keys themselves.
- The backup and rollback checks in [rollback.md](rollback.md) pass on copies.
- A separately authorized pilot records target IDs, invocation interval, source
  and artifact hashes, sanitized result code and independently observed published
  place version or delivered message. Missing observation means unproved delivery.
- Resource owners and cleanup handles are recorded before any pilot starts.

## Diagnosis and reconciliation

Both callers return false on operational failure (CLI exits nonzero). No branch
automatically retries a POST, including 429. Raw response bodies, status text,
headers and thrown transport text are not printed.

| Code | Operator action |
| --- | --- |
| CREDENTIAL_MISSING | Supply only the selected environment key through the approved secret channel. |
| CREDENTIAL_SHARED | Replace reused credentials with separate scoped keys. |
| CREDENTIAL_TARGET_MISMATCH | Reconcile the key's target bindings against the selected deploy IDs. |
| CREDENTIAL_TARGET_INVALID | Select staging or production; liveops remains staging-only. |
| TARGET_ENVIRONMENT_OVERLAP | Correct distinct environment targets before any publish. |
| PUBLISH_PERMISSION_DENIED | Inspect server-side scope/expiry and selected target; do not switch to a broader key. |
| PUBLISH_RATE_LIMITED | Reconcile delivery, inspect provider limits, then schedule a separately authorized attempt. No automatic retry or Retry-After claim. |
| PUBLISH_TIMEOUT_AMBIGUOUS | Check actual target state before another invocation; timeout does not prove rejection. |
| PUBLISH_TRANSPORT_AMBIGUOUS | Connection failure may follow a committed write; reconcile target state. |
| PUBLISH_MALFORMED_REPLY | Treat publication as uncertain; inspect target through an authorized independent read. |
| PUBLISH_HTTP_ERROR | Record numeric HTTP status separately if available; reconcile target state before retry. |
| PUBLISH_ACCEPTED | Local response contract accepted; independently verify delivery before claiming operational success. |
| PUBLISH_TRANSPORT_UNSUPPORTED | No request started. Installed Bun could not launch or required fetch/abort capability is unavailable. Resolve the supported runtime; no unsafe CLI override. |
| PUBLISH_CLEANUP_FAILED | Owned helper exit or pipe cleanup was not established, or kill failed. Do not claim cleanup; retain residual/kill/reap status and investigate before another publish. |
| PUBLISH_HELPER_NONZERO | Helper exit was observed but unsuccessful. Publication remains uncertain; reconcile before retry. |

Place success requires a positive integral `versionNumber` in a JSON object.
Message success requires an empty JSON object. These are local assumed response
contracts pending the real pilot. The pinned Lune 0.10.5 FetchParams has no
caller deadline or cancellation API. The maintained adapter instead launches
`bun cli/forge/lib/opencloud-transport.mjs` from the repository root without a
shell. It sends a JSON header frame and raw held artifact bytes through stdin;
credentials are never arguments, files or protocol output. Native fetch uses a
30-second AbortController deadline through response consumption, disallows
redirects, bounds response bytes and emits only sanitized response fields. Lune
owns a 35-second watchdog covering startup/stdin/output, kills only its helper
and waits up to five additional seconds for status and pipe EOF. The pinned API
has no stdout/stderr close method: both are drained concurrently; stdin is closed.
Kill/status/pipe failures and unconfirmed reap produce cleanup failure, not a
clean timeout. Timeout or lost acknowledgement remains ambiguous;
neither layer retries. These lifecycle properties are authored, not verified.

Consumer discovery must record `bun --version` and `lune --version` during the
authorized verification phase. The current target is installed Bun 1.4 on Windows
with pinned Lune 0.10.5; no executable is bundled, installed or resolved through
an absolute workstation path. Other versions/platforms remain unclaimed. The
helper and specs are first-party authored source under repository licensing;
installed runtimes retain their own license terms. No third-party code is vendored.

## Deferred local checks and cleanup

After the implementation barrier, invoke `lune run cli/forge check --all` once
in the Task 16 matrix. It discovers `cli/forge/commands/deploy-transport.spec.luau`,
`cli/forge/lib/opencloud.spec.luau`, `cli/forge/commands/liveops.spec.luau`,
`cli/forge/lib/liveopsplan.spec.luau` and `cli/forge/lib/report.spec.luau`. Liveops uses
an injected synchronous request function and local fixture files: no HTTP server,
sleep, polling or credentials are required. The fixture refuses a preexisting
owned path, removes only its created pack directory in cleanup, and propagates
both assertion and cleanup failures. The pure adapter specs own no resources.

The deploy fixture creates synthetic schema2 admission evidence with the existing
runtime fixture and real quality gate. It exercises approved release bytes through
the actual caller and shared adapter, all without replacing authorization logic.
It also checks refusal for missing credentials/human intent/evaluator and stale
artifact bytes. Its unavailable-transport case is injected and never invokes the network.

Also run `bun test cli/forge/lib/opencloud-transport.spec.mjs` in Task 16: Lune's
spec discovery does not discover this Bun file. It exercises native fetch against
owned loopback servers, subscribes to request receipt before abort, and checks
response loss without retries. No sleeps or external endpoints are involved.
The complete Lune-to-helper process watchdog still needs execution evidence;
native-helper tests alone do not establish parent kill/reap behavior.

`opencloud-process.spec.luau` now authors real child/pipe coverage for normal exit
and kill/reap triggered by the child's READY barrier after stdin EOF. It invokes
no external service and does not wait 35 seconds. Execution remains deferred.
Successful place responses deliberately allow extra provider metadata but reject
explicit error/errors envelopes; only the integral version is retained. Message
success still requires an empty object. The native response tests cover both rules.

For an eventual authorized pilot, retain original failure logs and hashes before
cleanup, close only recorded task-owned actors/processes, unregister subscriptions,
and record actual exits and residual resources. A request that may have committed
cannot be undone by deleting a local receipt or re-running the CLI.
