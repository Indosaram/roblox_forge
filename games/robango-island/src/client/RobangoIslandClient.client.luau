--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = ReplicatedStorage:WaitForChild("Forge")
local Shared = Forge.games["robango-island"].src.shared

local SurvivalAudio = require(Forge.genres["survival-coop"].module.SurvivalAudio)
local audio = SurvivalAudio.start(require(Shared.AudioConfig))
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
	local wildlife = workspace:WaitForChild("Wildlife", 15)
	if wildlife then
		local function attachCreatureMesh(rig: Instance)
			if not rig:IsA("Model") or rig:FindFirstChild("ProcCreatureMesh") then
				return
			end
			local torso = rig:FindFirstChild("Torso")
			if not torso or not torso:IsA("BasePart") then
				return
			end
			local isHunter = rig:FindFirstChild("Arm1") ~= nil
			local key = if isHunter then "robango-amber-hunter" else "robango-crest-grazer"
			local built = ProcAssets.build(ProcAssetsSpecs, key, "ProcCreatureMesh")
			if built and built.PrimaryPart then
				for _, d in built:GetDescendants() do
					if d:IsA("BasePart") then
						d.Anchored = false
						d.CanCollide = false
						d.CanQuery = false
						d.CanTouch = false
						d.Massless = true
						if d ~= built.PrimaryPart then
							local w = Instance.new("WeldConstraint")
							w.Part0 = built.PrimaryPart
							w.Part1 = d
							w.Parent = d
						end
					end
				end
				built:PivotTo(torso.CFrame * CFrame.new(0, 0.2, 0))
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = torso
				weld.Part1 = built.PrimaryPart
				weld.Parent = built.PrimaryPart
				built.Parent = rig
			end
		end
		for _, child in wildlife:GetChildren() do
			task.spawn(attachCreatureMesh, child)
		end
		wildlife.ChildAdded:Connect(function(child)
			task.defer(attachCreatureMesh, child)
		end)
	end
end)
