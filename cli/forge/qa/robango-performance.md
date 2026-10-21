# Robango QA-PERF-01 layer 2 probe

Prepared, not executed. Run from the repository root against an explicitly owned,
already running Studio Play client. The probe does not open Studio, start Play,
publish, grant items, invoke game remotes or gather. Use Studio MCP product APIs,
not Windows GUI input. Record the revision, built-place SHA-256, Studio ID, device
configuration and Play invocation alongside the result.

Before Play, configure `StudioDeviceSimulatorService` through `execute_luau`:
select an available Phone from `GetDeviceListAsync()` / `GetDeviceInfoAsync()`,
call `SetDeviceAsync(id)`, `SetOrientationAsync(Enum.ScreenOrientation.Portrait)`,
`SetResolutionAsync(640, 360)` and
`SetScalingModeAsync(Enum.DeviceSimulatorScalingMode.ActualResolution)`.
Follow `deviceStep` in `studio-driver-surface.mjs`; subscribe to `PreRender` and
verify `CurrentCamera.ViewportSize == Vector2.new(360, 640)` after configuration.
Do not infer content viewport dimensions from the scaled MCP screenshot.

Immediately after the authorized Play starts, send the entire contents of
`cli/forge/qa/robango-performance.luau` to
`execute_luau({studio_id: ownedId, datamodel_type: "Client", code: source})`.
The call returns immediately; sampling runs on the client for 120 seconds, at
one-second target intervals including a baseline at zero. Subscribe to the
completion console marker `FORGE_PERFORMANCE_COMPLETE` before starting the
probe. Do not stop Play or reload the client before completion. No need for a
120-second blocking MCP call. A failed memory API is retained as a failed result,
not replaced with zero. Each sample records actual elapsed time so scheduler
delay remains visible. Peak values are sampled peaks, not continuous maxima.

After the completion event, retrieve JSON using a second Client `execute_luau`:

```lua
return game:GetService("Players").LocalPlayer.ForgePerformanceProbe.Value
```

Save that returned JSON string verbatim as
`.omo/evidence/robango-recovery/p7/performance.json` using the calling MCP driver's
JSON artifact writer (as `studio-driver.mjs` does with `writeFile`). Roblox Luau
cannot write the host filesystem. The StringValue retains the JSON until Stop;
the probe restores rendering settings after sampling. If a transport truncates
the result, retrieve `.Value:sub(first,last)` in bounded consecutive chunks and
join them before JSON parsing. Never treat truncated output as a complete run.

The rendering settings API is `settings().Rendering`, with `QualityLevel` and
`EditQualityLevel` set to `Enum.QualityLevel.Level01` and `EnableFRM=false` to
avoid adaptive quality. These are PluginSecurity properties; execute in the
authorized Studio MCP context. Refusal means the profile was not applied and
the run must not be reported as a low-end pass. The probe requires the viewport
to be configured first. Restore the prior simulator profile via the same product
API after collecting evidence.

Time origin is `Workspace.DistributedGameTime`, simulation elapsed since Play,
not client probe start or wall-clock launch of the Studio process. The first
interaction requires `ReplicatedStorage.ForgeState`, enabled visible
`ForgeSurvivalHUD/SafeArea/Vitals`, and an enabled `ForgeGather` prompt actually
reported by `ProximityPromptService.PromptShown`, within activation range and
line of sight. It observes readiness each render frame, independently of memory
sampling. If readiness already exists on attachment, the exact transition is
unknowable: `interactionStatus` is `left-censored-at-attachment` and no fabricated
time is emitted. For an exact startup observation, attach before that transition
in a fresh authorized Play. A missing prompt remains `not-observed`, not a pass.
Moving to a node changes the measured scenario; record any real input separately.

Memory uses `Stats:GetTotalMemoryUsageMb()` and key
`Stats:GetMemoryUsageMbForTag()` values. Instance count is `Stats.InstanceCount`;
part count is all client Workspace BaseParts. The draw-call proxy counts
nontransparent part centers in the camera viewport, with its definition embedded
in JSON. It is not actual GPU draw calls: terrain, batching, occlusion and mesh
complexity require separate renderer profiling. Studio memory and a phone-shaped
viewport do not establish physical low-end phone performance.

API references:
- https://create.roblox.com/docs/reference/engine/classes/RenderSettings
- https://create.roblox.com/docs/reference/engine/classes/Stats
- https://create.roblox.com/docs/reference/engine/classes/Workspace#DistributedGameTime
- https://create.roblox.com/docs/reference/engine/classes/StudioDeviceSimulatorService
