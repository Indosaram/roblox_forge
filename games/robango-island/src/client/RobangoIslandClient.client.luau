--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = ReplicatedStorage:WaitForChild("Forge")
local Shared = Forge.games["robango-island"].src.shared

local audio = require(script.Parent.RobangoAudio).start(
	require(Forge.core.infra.audio.SoundBank),
	require(Forge.genres["survival-coop"].module.AudioDirector),
	require(Shared.Assets),
	require(Shared.RobangoAudioCatalog)
)
script.Destroying:Connect(audio.destroy)

local Client = require(Forge.core.infra.genre.Client)
local gui = Client.start({ controls = require(Shared.GenreUI) })
gui.Destroying:Connect(audio.destroy)

-- The pack ships en-us and ko-kr; every survival-coop view picks Korean from a "ko" prefix.
local locale = game:GetService("Players").LocalPlayer.LocaleId
local names = require(Shared.EntityNames)(locale)

local GatheringClient = require(Forge.genres["survival-coop"].module.GatheringClient)
local gathering = GatheringClient.start({ locale = locale, names = names })
gui.Destroying:Connect(gathering.destroy)

local SurvivalHUD = require(Forge.genres["survival-coop"].module.SurvivalHUD)
local content = require(Shared.SurvivalContent)
local worldConfig = require(Shared.SurvivalWorldConfig)
local origin = worldConfig.tribe.origin
gui.Enabled = false
local hud = SurvivalHUD.start({
	icons = require(Forge.genres["survival-coop"].module.ItemIcons).new(content, require(Shared.Assets)),
	contextual = true,
	content = content,
	ui = {
		components = require(Forge.core["ui-kit"].Components),
		grid = require(Forge.core["ui-kit"].InventoryGrid),
		theme = require(Forge.core["ui-kit"].Theme),
	},
	settlementOrigin = Vector3.new(origin.x, origin.y, origin.z),
	locale = locale,
	names = names,
})
-- Server-published attack intent only: no client prediction can confirm a hit.
local telegraphs: { [Model]: Highlight } = {}
local telegraphConnection = game:GetService("RunService").Heartbeat:Connect(function()
	local folder = workspace:FindFirstChild("ForgeWildlife")
	if not folder then
		return
	end
	for _, model in folder:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local active = model:GetAttribute("ForgePlayerWindupUntil") ~= nil
		local marker = telegraphs[model]
		if active and not marker then
			local created = Instance.new("Highlight")
			created.Name, created.Adornee, created.Parent = "AttackWindup", model, model
			created.FillColor, created.OutlineColor = Color3.fromRGB(232, 138, 65), Color3.fromRGB(245, 241, 229)
			created.FillTransparency = 0.65
			telegraphs[model] = created
		elseif not active and marker then
			marker:Destroy()
			telegraphs[model] = nil
		end
	end
end)
gui.Destroying:Connect(function()
	telegraphConnection:Disconnect()
end)
gui.Destroying:Connect(hud.destroy)
script.Destroying:Connect(hud.destroy)

local ExtensionPanels = require(Forge.genres["survival-coop"].module.ExtensionPanels)
local panels = ExtensionPanels.start({
	ui = {
		components = require(Forge.core["ui-kit"].Components),
		theme = require(Forge.core["ui-kit"].Theme),
	},
	locale = locale,
	names = names,
	-- One sheet at a time: a panel opening closes the HUD sheet, and the reverse below.
	onOpen = hud.close,
	contextual = true,
	launchers = {
		{
			id = "bag",
			label = if string.sub(locale, 1, 2) == "ko" then "가방" else "Bag",
			open = function()
				hud.open("bag")
			end,
		},
		{
			id = "craft",
			label = if string.sub(locale, 1, 2) == "ko" then "제작" else "Craft",
			open = function()
				hud.open("craft")
			end,
		},
		{
			id = "build",
			label = if string.sub(locale, 1, 2) == "ko" then "건설" else "Build",
			open = function()
				hud.open("build")
			end,
		},
		{
			id = "skills",
			label = if string.sub(locale, 1, 2) == "ko" then "스킬" else "Skills",
			open = function()
				hud.open("skills")
			end,
		},
	},
})
hud.opened:Connect(function()
	if hud.isOpen() then
		panels.closeAll()
	end
end)
gui.Destroying:Connect(panels.destroy)
script.Destroying:Connect(panels.destroy)

local QuarterView = require(Forge.core.infra.camera.QuarterView)
local camera = QuarterView.start()
gui.Destroying:Connect(camera.stop)
script.Destroying:Connect(camera.stop)
if game:GetService("RunService"):IsStudio() then
	game:GetService("RunService"):BindToRenderStep("ForgeStudioCapture", Enum.RenderPriority.Last.Value, function()
		local position = workspace:GetAttribute("ForgeStudioCameraPosition")
		local target = workspace:GetAttribute("ForgeStudioCameraTarget")
		if typeof(position) == "Vector3" and typeof(target) == "Vector3" then
			camera.stop()
			workspace.CurrentCamera.CFrame = CFrame.lookAt(position, target)
			workspace.CurrentCamera.FieldOfView = 60
		end
	end)
	script.Destroying:Connect(function()
		game:GetService("RunService"):UnbindFromRenderStep("ForgeStudioCapture")
	end)
end

local DinosaurRig = require(Forge.genres["survival-coop"].module.DinosaurRig)
local CreaturePose = require(script.Parent.CreaturePose)
local function startCreatureAnimation(rigPose: (Model, string, number, number) -> ()): { destroy: () -> () }
	local RunService = game:GetService("RunService")
	local registry: { [Model]: { state: string, elapsed: number } } = {}
	local connections: { RBXScriptConnection } = {}
	local destroyed = false
	local function discover(instance: Instance)
		local model = if instance:IsA("Model") then instance else instance:FindFirstAncestorOfClass("Model")
		if
			model
			and model:IsA("Model")
			and model:FindFirstChild("Torso")
			and model:FindFirstChild("HumanoidRootPart")
		then
			registry[model] = registry[model] or { state = "idle", elapsed = 0 }
		end
	end
	local function bind(folder: Instance)
		for _, child in folder:GetDescendants() do
			discover(child)
		end
		table.insert(connections, folder.DescendantAdded:Connect(discover))
		table.insert(
			connections,
			folder.DescendantRemoving:Connect(function(child)
				if child:IsA("Model") then
					registry[child] = nil
				end
			end)
		)
	end
	for _, child in workspace:GetChildren() do
		if child.Name == "Wildlife" or child.Name == "OwnedCreatures" or child.Name == "ForgeWildlife" then
			bind(child)
		end
	end
	table.insert(
		connections,
		workspace.ChildAdded:Connect(function(child)
			if child.Name == "Wildlife" or child.Name == "OwnedCreatures" or child.Name == "ForgeWildlife" then
				bind(child)
			end
		end)
	)
	table.insert(connections, workspace.DescendantAdded:Connect(discover))
	table.insert(
		connections,
		RunService.RenderStepped:Connect(function(dt)
			local viewCamera = workspace.CurrentCamera
			for model, animation in registry do
				local root = model.PrimaryPart
				if not model:IsDescendantOf(workspace) then
					registry[model] = nil
					continue
				end
				if not root then
					continue
				end
				local distance = if viewCamera then (viewCamera.CFrame.Position - root.Position).Magnitude else 0
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				local speed = root.AssemblyLinearVelocity.Magnitude
				local serverState = model:GetAttribute("ForgeWildlifeState")
				if humanoid and humanoid.Health <= 0 then
					serverState = "dead"
				end
				local state, elapsed = CreaturePose.sample(
					animation,
					if type(serverState) == "string" then serverState else nil,
					speed,
					model:GetAttribute("Rider") ~= nil or model:GetAttribute("ForgeMountSpecies") ~= nil,
					dt
				)
				-- At long range hold the articulated silhouette. Telegraphs remain active.
				if
					distance <= 100
					or state == "warning"
					or state == "windup"
					or state == "attack"
					or state == "dead"
					or state == "stun"
				then
					rigPose(model, state, elapsed, speed)
				end
			end
		end)
	)
	return {
		destroy = function()
			if destroyed then
				return
			end
			destroyed = true
			for _, connection in connections do
				connection:Disconnect()
			end
			table.clear(connections)
			table.clear(registry)
		end,
	}
end
local creatureAnimation = startCreatureAnimation(DinosaurRig.pose)
gui.Destroying:Connect(creatureAnimation.destroy)
script.Destroying:Connect(creatureAnimation.destroy)

local ProcAssets = require(Forge.core.infra.render.ProcAssets)
local ProcAssetsSpecs = require(Shared.ProcAssets)
task.spawn(function()
	local island = workspace:WaitForChild("DevelopmentIsland", 15)
	if island then
		local propPlacements = {
			{ key = "robango-flint-crystal", name = "FlintCrystalMesh", cf = CFrame.new(-10.2, 2.2, 13.2) },
			{ key = "survival-coop-starter-prop", name = "FlintRockMesh", cf = CFrame.new(-11.8, 1.4, 14.6) },
			{ key = "robango-supply-crate", name = "WarehouseCrateMesh", cf = CFrame.new(13.2, 1.2, -9.2) },
			{ key = "robango-forest-tree", name = "CampTreeMeshNW", cf = CFrame.new(-26, 3.2, 8) },
			{ key = "robango-forest-tree", name = "CampTreeMeshNE", cf = CFrame.new(22, 3.2, 8) },
			{ key = "robango-forest-tree", name = "CampTreeMeshSW", cf = CFrame.new(-24, 3.2, 22) },
		}
		for _, item in propPlacements do
			local built = ProcAssets.build(ProcAssetsSpecs, item.key, item.name)
			if built and built.PrimaryPart then
				for _, d in built:GetDescendants() do
					if d:IsA("BasePart") then
						d.CanCollide = false
						d.CanQuery = false
						d.CanTouch = false
					end
				end
				built:PivotTo(item.cf)
				built.Parent = island
			end
		end
	end
end)
