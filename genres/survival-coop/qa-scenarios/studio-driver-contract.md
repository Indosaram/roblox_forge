# Actual Studio scenario contract

The five task 20 manifests use `kind: studio`, `contract_api: 1`, two real mapped
clients, the existing ForgeAction/ForgeQA transport, and canonical result bindings.
They are executable definitions, not evidence of successful play or art approval.
Each requires a fresh owned development server; it does not seed business state.

## Inputs and observations

`keyboard` uses the product `user_keyboard_input` API. `click` measures the real
button center and uses `user_mouse_input`; it refuses invisible/clipped controls.
Both subscribe before input and require the corresponding event. A click with
`resultAction` waits for a matching ForgeHUDResult packet and preserves its actual
result for `bind_result`. API Success without Activated/result fails closed.
The QA08 coordinate-conversion problem remains an actual runtime investigation;
these operations do not claim to fix it or bypass it with callback invocation.

`equip` invokes Humanoid:EquipTool on a real server-projected Tool in the actor's
Backpack and waits for Equipped. It does not write inventory or equipment state.
`wait_for` subscribes to the named property/attribute signal or ForgeQA.StateChanged,
checks the exact predicate, and uses one bounded timeout. Craft completion waits
compare observed vitals clock to the canonical job finishAt, not fixed sleeps.
`bind_snapshot` extracts a scalar or the unique key matching a field/value from
the authoritative snapshot. It does not derive item IDs or manufacture results.
Bound path segments may use `{ref: job, prefix: 'start-'}` for runtime UI names.

Offscreen controls are reached through product scrollUp/scrollDown input, with a
CanvasPosition signal per bounded segment, never direct CanvasPosition writes.
Clicks use the measured Instance's product instance_path to avoid the previously
observed raw-coordinate conversion. Activated/result remains mandatory.

## Measured evidence and external supplements

Captures contain `actor` (verified tostring(LocalPlayer.UserId)), `studio_id`
(transport provenance), actual CurrentCamera viewport `width`/`height`, image
SHA-256, scenario step, and monotonic elapsed seconds. `outcome.clients` contains
`{actor, studio_id}`. Two views of the same actor are not two actors. The existing
transport still requires distinct mapped Studio IDs; multiplexing two clients
through one Studio ID needs a product datamodel selector and cannot be guessed.

Each step records `startedSeconds` and `elapsedSeconds` using performance.now.
Advancing the game clock never advances measured first-play time. Automated
scenario actions do not establish unprompted human discovery.

The runner emits `outcome.runSha256`, digesting measured scenario, clients, steps,
inputs, calls and captures. After external recording/observation, invoke:

```text
bun cli/forge/qa/studio-driver.mjs --attach-supplement <input-json>
```

Input is `{document: <existing qa evidence JSON>, supplement: {...}}`. Supplement
fields are `runSha256`, `audio: [{path, sha256, ...}]`, and
`firstPlay: {goals: {<goal-id>: {goalDigest, actors, step, elapsedSeconds,
observation, unprompted, shortcut}}}`. Paths are repository-relative existing
audio files. The helper hashes bytes, requires measured actor/action/time links,
retains supplied observations unchanged, and prints the enriched evidence
document; it does not overwrite the source evidence. Persist that stdout through
the caller's artifact publication path. No goal or approval is synthesized.
The existing qualityevaluate.validateObservations remains the evaluator boundary.

Use the already verified external event-driven WASAPI `Loopback` route in
`.omo/evidence/forge-output-quality-survival/audio-prerequisites-samples/ForgeQAAudio.cs`.
The prerequisite receipt is in the root checkout's `audio-route-verification.md`.
Actual Studio playback/recording/listening is still unproven. No duplicate audio
recorder is introduced here.

## Physical limitations and remaining proof

`full-coop-rejoin` deliberately fails at `rejoin`: the discovered adapter has no
product operation to disconnect and reconnect one real test client to the same
server and UserId. A complete lifecycle adapter must subscribe on the server to
PlayerRemoving/PlayerAdded before triggering the product operation, verify both
events for that exact UserId and a replacement client mapping, recheck ownership,
and retain the prior server. EndTest/start test, respawn, save/restore, and a
handshake are not substitutes. Existing StudioTest two-client ownership is kept.

The manifests cover gather/craft/cancel/food/rest/build/warehouse operations,
equipment, in-range attacks, a real temporary occluding wall, lethal loot and
duplicate-death conservation, plus roof fading and runtime captures. Device steps
use the retained StudioDeviceSimulatorService contract, discover device IDs by
DeviceForm, and subscribe to actual ViewportSize before setters. Captures with
angles: 3 rotate through the product's RightBracket camera controls, not camera
CFrame writes. Motion traces record actual state, health, velocity, position and
Motor6D C0 on PostSimulation at up to 20 Hz/600 frames. They explicitly report
video: false: no discovered video capture API exists, so image/state traces do
not claim full motion-video approval. Device state and owned trace/wall instances
are restored/disposed at teardown.

Native transfer-crash-matrix.yml and gather-craft-settle.yml retain the canonical
callback commit barriers, serialized reload and exact recovery conservation.
The live product ForgeQA surface does not expose a durable backend commit hook;
injecting one from execute_luau would replace production behavior. That live
crash-boundary proof and physical rejoin remain unavailable, not silently passed.
The retained StudioTestService route offers ExecuteMultiplayerTestAsync/EndTest,
not same-UserId reconnection to the retained server. Actual audio/video approvals
remain separate from successful scenario assertions.
No tests, builds, analyzers, Studio sessions, captures, or review ran while these
definitions were authored.

The maintained executable dependency set is cli/forge/qa/studio-driver*.mjs;
qastudio invokes that tracked entry point. Existing .omo scratch/config/artifact
files are not the delivered runner. Deferred checks: lune run cli/forge check;
bun test cli/forge/qa; then the five owned Studio scenarios.

## Supplemental task 13 observations

`motion_begin` with a `home` coordinate installs a server-side state-attribute and
Heartbeat subscription before movement. `motion_end` with ordered `observations`
consumes retained and subsequent samples: mode, physical displacement, home
distance, and both actual actors' distances. The wildlife scenario records
grazer flee/roam and hunter warn/chase/return/idle, including both clients beyond
the catalog radii. Home coordinates come from the pack's authored spawn policy;
they are reference measurements, never assignments to the NPC.

The malformed attack sends an extra damage argument through the existing real
client command envelope. Executor's one-target tuple contract returns `invalid
tuple`; before/after server snapshots must retain the full inventory (including
weapon durability and loot) and replicated authoritative NPC health unchanged.

Path-failure proof remains specifically unavailable through the read-only
adapter: WildlifeWorld owns a private Path per asynchronous ComputeAsync, its
serial fence, requested endpoints and failure flag. No event exposes those
correlated values. A separate PathfindingService computation would be a different
request and cannot establish that the NPC consumed its failure. Do not report
idle or a blocked ray as path-failure proof. Closing this case requires a future
read-only product path-result observation hook carrying NPC ID, serial, exact
start/goal, PathStatus and consumed failure transition; no product hook was added
during the fullcheck barrier.
