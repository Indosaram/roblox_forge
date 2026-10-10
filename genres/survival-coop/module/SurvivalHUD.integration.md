# Survival HUD integration (task 15)

New files only. No existing game, shared transport, world, camera, generator or
generator-spec files are changed, so the parent's camera commits remain intact.

## Generator/client integration

In `cli/forge/lib/craftinggenerate.luau`, replace only the appended
`CraftingClient.start(gui)` require/start block with the following client source.
Keep the existing `Client.start`, `GatheringClient.start`, QuarterView.start, and
their cleanup callbacks. The starter gui remains a hidden debug/transport owner;
it must not be destroyed on startup because its Destroying signal owns camera
and gathering cleanup. Do not start CraftingClient alongside this HUD.

```luau
local SurvivalHUD = require(Forge.genres["survival-coop"].module.SurvivalHUD)
local content = require(ReplicatedStorage.Shared.SurvivalContent)
local worldConfig = require(ReplicatedStorage.Shared.SurvivalWorldConfig)
local origin = worldConfig.tribe.origin
gui.Enabled = false
local hud = SurvivalHUD.start({
    content = content,
    ui = {
        components = require(Forge.core["ui-kit"].Components),
        grid = require(Forge.core["ui-kit"].InventoryGrid),
        theme = require(Forge.core["ui-kit"].Theme),
    },
    settlementOrigin = Vector3.new(origin.x, origin.y, origin.z),
})
gui.Destroying:Connect(hud.destroy)
script.Destroying:Connect(hud.destroy)
```

Use the actual generated Shared variable/path from the template, not a new copy
of content or world config. `M.worldConfig()` currently has `tribe.origin`.
Keep the parent's already-added `QuarterView.start()` handle and its
`gui.Destroying`/`script.Destroying` stop callbacks. If replacing Client.start
entirely later, move those cleanup callbacks to `hud.gui.Destroying`; do not leave
two camera owners. `hud.destroy()` is idempotent.

Publish/regenerate the existing pack through the parent-owned publication path.
Update the generator's native fixture to map the new SurvivalHUD require and
returned `{gui,destroy}` handle, preserving its multiple Destroying callbacks
and camera lifecycle assertions. Do not overwrite the camera generator spec.

## Layout and controls

Closed state has compact upper-left vitals/status/navigation, a bottom rest
button, and no debug JSON. Desktop uses a right-hand 400-pixel scrolling sheet.
Portrait uses a bottom sheet below 58% of safe height to leave the centered
QuarterView avatar visible. ScreenInsets uses CoreUISafeInsets; controls are
48 pixels high, inventory cells 64, and modal close 44. Detail text is in the
scroll flow for touch and keyboard, rather than hover-only tooltips. This is a
layout rationale, not proof of unclipped rendering.

I/C/B open inventory/craft/build; R requests rest. Selection uses Activated.
Inventory exposes stable stacks, reservations, quality/durability, weight and
slots; one-unit storage transfers and food use the real server verbs. Recipe
inputs show unreserved amounts. Reserve/start/collect/cancel uses persisted job
IDs, restored from workshop snapshots, and timers are display estimates from
the authoritative clock. Only the server completes a job. Build uses native
Settlement.reserve footprint checks without publishing the candidate, including
the walkable entry; reserve/place/cancel uses authoritative version tuples.

All mutations share one outstanding request. Retry retains its exact frozen
tuple and ID across snapshots, transient refusal and transport failure. A
persisted outcome or explicit expired epoch releases it. Transfer completion
also recognizes the real `data.status == "confirmed"` contract. The client
subscribes to ForgeState before handshaking; settlement state comes from
`snapshots.survivalSettlement`, not the personal genre snapshot.

`Player.ForgeHUDResult.Event` emits `{request,result,status}` after replies for
the parent's exact-event native-input receipts. It is a local evidence event,
not a second command executor. Unsupported mutation capabilities are disabled
by the advertised durable action list; no wildlife attack control exists.
Building/storage additionally needs an available settlement and provisioned
membership. Catalog IDs can be translated with `options.names`; the generated
starter vocabulary plus all genre UI copy includes en/ko.

## Live acceptance still required

No Studio launch, GUI manipulation, remote action, spend or commit was performed.
Parent must render 1280x720 and 390x844, inspect en/ko text, avatar clearance,
touch thumbstick/jump overlap, scrolling reachability, and actual build origin
alignment. Exercise open/select/reserve/start/cancel/transfer/build, uncertain
reply retry, full bag, reserved stack and rejoin with real clients. No visual
quality or actual engine input acceptance is claimed by native fixtures.
