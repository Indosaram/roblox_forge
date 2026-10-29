# Quarter-view camera integration contract

`QuarterView.start(config)` is client-only and returns `setView(yaw, pitch,
distance)` and idempotent `stop()`. Defaults are yaw 45 degrees, pitch 55 degrees,
vertical FOV 30 degrees, distance 85 studs, zoom limits 60 and 110 studs, and focus
2.5 studs above HumanoidRootPart. One controller owns the local camera at a time.
The caller must stop its old controller before starting another.

The render event follows the character without changing its transparency. A
0.75-stud sphere sweep shortens the camera arm at solid geometry (the requested
zoom remains unchanged). Camera replacement restores the old camera before taking
ownership of the replacement. Stop restores camera type, subject, transform,
focus, and FOV, resets every owned local fade, and disconnects all its listeners.
Character removal/addition clears local fades and pending pinch gestures.

Tag eligible roof/foliage BaseParts or their ancestor Models `ForgeCameraRoof` or
`ForgeCameraOccluder`. Only parts returned by Camera:GetPartsObscuringTarget are
faded, using LocalTransparencyModifier 0.7 (preserving any higher preexisting
modifier). Original local modifiers are restored when clear. Server Transparency,
CanCollide, CanQuery, and avatar parts are never changed. Do not put camera tags on
solid interaction-blocking walls to make them interactable: neither local fades
nor camera collision authorize an interaction. Existing server reach/LOS checks
remain mandatory; client selection must also raycast without excluding faded parts.

Mouse wheel changes zoom by five studs per notch. TouchPinch uses the initial
distance divided by cumulative scale; it rejects consumed UI gestures and points
outside GuiService:GetInsetArea(CoreUISafeInsets).

Opt-in options (defaults unchanged when omitted):
- `zoom = { characterHeight, share, minShare, maxShare }` sets zoom by the
  character's on-screen height as a fraction of the short screen axis. The arm
  length is recomputed each frame from FOV, pitch and viewport aspect
  (`QuarterView.distanceForShare` / `screenShare`). Pinch multiplies the share by the
  cumulative scale, the wheel by 1.1 per notch, and both clamp to [minShare, maxShare].
  `api.share()` returns the current share. Robango uses 5.5 studs, 6% (range 3-15%).
- `touchRotate = false` ignores TouchRotate (fixed yaw on touch). The `[`/`]` keys
  and right-drag still rotate on PC.
- `pinchBlocked = function(x, y): boolean` switches touch zoom to raw touches:
  two fingers tracked through InputBegan/InputChanged/InputEnded scale the zoom by
  their spread (cumulative from the second finger's landing), whatever the
  gameProcessed flag says. Phones report world touches as processed, so the
  TouchPinch path above never zoomed there (p134 v54). A finger that lands where
  `pinchBlocked` returns true (UI) never joins a pinch; TouchPinch is ignored.
- `closePitch` / `closeFocusHeight` (stud zoom only) ease the pitch and focus height
  linearly from their values at `minDistance` to `pitch` / `focusHeight` at
  `maxDistance`: a low over-the-shoulder view when zoomed in. `api.zoomTo(d)` sets
  the arm with the same clamp. Robango uses pitch 55->30, 50 studs, zoom 12-60
  (`games/robango-island/src/shared/CameraConfig.luau`).

It owns no GUI and does not
consume movement/touch inputs. The HUD owner must independently use
ScreenGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets and keep interaction
controls away from the thumbstick/jump regions. Native math cannot prove mobile
composition, readability, or avatar visibility inside tight authored geometry.

## Parent-owned integration (not applied by this branch)

In the survival-coop crafting client bootstrap emitted by
`cli/forge/lib/craftinggenerate.luau` (client source assembly around lines 273-274),
after the existing GatheringClient start, use the existing `Forge` local:

```luau
local QuarterView = require(Forge.core.infra.camera.QuarterView)
local camera = QuarterView.start({ yaw = 45, pitch = 55, fieldOfView = 30,
    distance = 85, minDistance = 60, maxDistance = 110 })
gui.Destroying:Connect(camera.stop)
script.Destroying:Connect(camera.stop)
```

The generated Rojo root is `ReplicatedStorage.Forge.core`. Start once alongside
GatheringClient/CraftingClient, not per GUI redraw
or character spawn. Attach `camera.stop()` to the owning client's existing stop
path and LocalScript.Destroying. Expose the returned handle only through a local
Studio QA harness for `setView(45,55,85)`, `(135,55,60)`, `(225,55,110)` and stop;
never add a replicated camera-admin remote. Existing games, generator, core Client,
GatheringClient, SurvivalWorld, Session, and QA Studio runner were not edited.

## Evidence boundary

Run `lune run cli/forge/fixtures/camera-proof` from the repository root. The fixture loads
the actual controller source with native Lune Vector/CFrame values, explicit
render steps and event delivery; it does not substitute a second camera algorithm.
It proves lifecycle, input math, collision response and local write ownership.
It does not simulate Roblox rendering, broadphase collision, or built-in camera
scripts. Parent must execute the camera-occlusion playtest at desktop 1280x720 and
mobile 390x844, capture all three views, inspect avatar/target readability and
clipping, demonstrate roof enter/leave and respawn, and inspect cleanup. Task 14
is not visually accepted by these native checks.
