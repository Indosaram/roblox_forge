-- Studio MCP execute_luau, datamodel_type = Client, in an already running Play.
-- See robango-performance.md. This probe never triggers gameplay or starts Play.
-- check analyzes cli/ with Lune globals; Roblox engine globals are read from the
-- execution environment, following the MarketPanel convention.
local env: any = getfenv()
local game: any = env.game
local workspace: any = env.workspace
local settings: any = env.settings
local Enum: any = env.Enum
local Vector2: any = env.Vector2
local Instance: any = env.Instance
local task: any = env.task
local RaycastParams: any = env.RaycastParams
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Stats = game:GetService("Stats")
local HttpService = game:GetService("HttpService")
local PromptService = game:GetService("ProximityPromptService")
assert(RunService:IsStudio() and RunService:IsRunning(), "RUNNING_STUDIO_PLAY_REQUIRED")
local player = assert(Players.LocalPlayer, "CLIENT_REQUIRED")
assert(not player:FindFirstChild("ForgePerformanceProbe"), "PROBE_ALREADY_EXISTS")

local camera = assert(workspace.CurrentCamera, "CAMERA_REQUIRED")
assert(camera.ViewportSize == Vector2.new(360, 640), "CONFIGURE_360X640_SIMULATOR_FIRST")
local rendering = settings().Rendering
local before = {
	quality = rendering.QualityLevel,
	editQuality = rendering.EditQualityLevel,
	frm = rendering.EnableFRM,
}
-- Both documented rendering modes are pinned; no automatic quality adaptation.
rendering.QualityLevel = Enum.QualityLevel.Level01
rendering.EditQualityLevel = Enum.QualityLevel.Level01
rendering.EnableFRM = false
assert(rendering.QualityLevel == Enum.QualityLevel.Level01, "QUALITY_NOT_APPLIED")

local slot = Instance.new("StringValue")
slot.Name = "ForgePerformanceProbe"
slot.Value = HttpService:JSONEncode({ status = "sampling" })
slot.Parent = player
local attachedAt = workspace.DistributedGameTime
local started = os.clock()
local samples = {}
local shown = {}
local firstInteraction
local attachedReady = false
local connections = {}
local tags =
	{ "LuaHeap", "Script", "Instances", "Gui", "GraphicsTexture", "GraphicsMeshParts", "TerrainVoxels", "Sounds" }
local peaks = { totalMemoryMb = 0, instanceCount = 0, workspaceParts = 0, drawCallProxy = 0, tagsMb = {} }

local function hudVisible()
	local gui = player:FindFirstChildOfClass("PlayerGui")
	local hud = gui and gui:FindFirstChild("ForgeSurvivalHUD")
	local safe = hud and hud:FindFirstChild("SafeArea")
	local vitals = safe and safe:FindFirstChild("Vitals")
	return hud ~= nil
		and hud:IsA("ScreenGui")
		and hud.Enabled
		and safe ~= nil
		and safe.Visible
		and vitals ~= nil
		and vitals.Visible
		and vitals.AbsoluteSize.X > 0
		and vitals.AbsoluteSize.Y > 0
end

local function usable(prompt)
	if not prompt.Enabled or not prompt:IsDescendantOf(workspace) then
		return false
	end
	local anchor = prompt.Parent
	local position = if anchor and anchor:IsA("Attachment")
		then anchor.WorldPosition
		elseif anchor and anchor:IsA("BasePart") then anchor.Position
		else nil
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not position or not root or (position - root.Position).Magnitude > prompt.MaxActivationDistance then
		return false
	end
	if prompt.RequiresLineOfSight then
		local params = RaycastParams.new()
		params.FilterDescendantsInstances = { player.Character }
		params.FilterType = Enum.RaycastFilterType.Exclude
		local hit = workspace:Raycast(camera.CFrame.Position, position - camera.CFrame.Position, params)
		return hit == nil or hit.Instance == (if anchor:IsA("Attachment") then anchor.Parent else anchor)
	end
	return true
end

local function ready(requireShown)
	if not game:GetService("ReplicatedStorage"):FindFirstChild("ForgeState") or not hudVisible() then
		return nil
	end
	local candidates = if requireShown then shown else workspace:GetDescendants()
	for key, value in candidates do
		local item = if requireShown then key else value
		if item:IsA("ProximityPrompt") and item.Name == "ForgeGather" and usable(item) then
			return item:GetFullName()
		end
	end
	return nil
end

-- Subscribe before checking existing state. PromptShown proves engine admission,
-- including prompt exclusivity; already-ready attachment is left-censored.
table.insert(
	connections,
	PromptService.PromptShown:Connect(function(prompt)
		shown[prompt] = true
	end)
)
table.insert(
	connections,
	PromptService.PromptHidden:Connect(function(prompt)
		shown[prompt] = nil
	end)
)
attachedReady = ready(false) ~= nil

table.insert(
	connections,
	RunService.PreRender:Connect(function()
		if firstInteraction == nil and not attachedReady then
			local prompt = ready(true)
			if prompt then
				firstInteraction = { secondsFromPlay = workspace.DistributedGameTime, prompt = prompt }
			end
		end
	end)
)

local function sample(index)
	local parts, proxy = 0, 0
	for _, item in workspace:GetDescendants() do
		if item:IsA("BasePart") then
			parts += 1
			local _, visible = camera:WorldToViewportPoint(item.Position)
			if visible and item.Transparency < 1 and item.LocalTransparencyModifier < 1 then
				proxy += 1
			end
		end
	end
	local row = {
		index = index,
		secondsFromAttach = os.clock() - started,
		secondsFromPlay = workspace.DistributedGameTime,
		totalMemoryMb = Stats:GetTotalMemoryUsageMb(),
		instanceCount = Stats.InstanceCount,
		workspaceParts = parts,
		drawCallProxy = proxy,
		tagsMb = {},
		viewport = { camera.ViewportSize.X, camera.ViewportSize.Y },
	}
	for _, name in tags do
		local value = Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag[name])
		row.tagsMb[name] = value
		peaks.tagsMb[name] = math.max(peaks.tagsMb[name] or 0, value)
	end
	for _, key in { "totalMemoryMb", "instanceCount", "workspaceParts", "drawCallProxy" } do
		peaks[key] = math.max(peaks[key], row[key])
	end
	table.insert(samples, row)
end

task.spawn(function()
	local ok, failure = pcall(function()
		sample(0)
		for index = 1, 120 do
			-- Sampling cadence is the measurement itself, not a readiness sleep.
			local remaining = started + index - os.clock()
			if remaining > 0 then
				task.wait(remaining)
			end
			sample(index)
		end
	end)
	for _, connection in connections do
		connection:Disconnect()
	end
	rendering.QualityLevel = before.quality
	rendering.EditQualityLevel = before.editQuality
	rendering.EnableFRM = before.frm
	slot.Value = HttpService:JSONEncode({
		schemaVersion = 1,
		status = if ok then "complete" else "failed",
		error = if ok then nil else tostring(failure),
		placeId = game.PlaceId,
		universeId = game.GameId,
		jobId = game.JobId,
		actorId = player.UserId,
		profile = { quality = "Level01", automaticQuality = false, viewport = { 360, 640 } },
		attachedAtPlaySeconds = attachedAt,
		clock = "Workspace.DistributedGameTime (simulation elapsed since Play; not host launch latency)",
		firstInteraction = firstInteraction,
		interactionStatus = if attachedReady
			then "left-censored-at-attachment"
			elseif firstInteraction then "observed"
			else "not-observed",
		drawCallProxyDefinition = "count of nontransparent BaseParts whose centers project inside the viewport; NOT GPU draw calls, batching, occlusion or terrain",
		samplePeriodSeconds = 1,
		durationSeconds = 120,
		peaks = peaks,
		samples = samples,
	})
	print("FORGE_PERFORMANCE_COMPLETE")
end)
return HttpService:JSONEncode({
	status = "sampling",
	result = "Players.LocalPlayer.ForgePerformanceProbe.Value",
	attachedAtPlaySeconds = attachedAt,
})
