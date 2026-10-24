--!strict
-- p77 Studio QA setup: the archipelago stage seed meets the selected stage's gates, and the
-- species gallery lays out every content species. Both are inert outside Studio.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local Archipelago = require("../../core/domain/island/Archipelago")
local Content: any = require("./src/shared/SurvivalContent")

local function setup(): any
	return luau.load(fs.readFile("games/robango-island/src/server/StudioSetup.luau"), {
		environment = {
			Instance = roblox.Instance,
			Vector3 = roblox.Vector3,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			UDim2 = roblox.UDim2,
			Enum = roblox.Enum,
		},
	})()
end

local function rig(): any
	local stub: any = {}
	function stub.new(species, id, position, parent)
		local model = roblox.Instance.new("Model")
		model.Name = id
		local root = roblox.Instance.new("Part")
		root.Name, root.Position, root.Parent = "HumanoidRootPart", position, model
		model:SetAttribute("Species", species)
		model.PrimaryPart, model.Parent = root, parent
		return model
	end
	stub.grounded = 0
	function stub.ground()
		stub.grounded += 1
	end
	return stub
end

local function workspace(gallery: boolean?): any
	local attributes: any = { ForgeStudioGallery = gallery }
	local root = roblox.Instance.new("Folder")
	return {
		root = root,
		filled = 0,
		Terrain = {},
		GetAttribute = function(_, key)
			return attributes[key]
		end,
		SetAttribute = function(_, key, value)
			attributes[key] = value
		end,
	}
end

return {
	["Studio stage seed meets every archipelago stage's gates (p77 level_gate)"] = function()
		local Setup = setup()
		for _, layout in Content.layouts do
			local template, stage = string.match(layout.id, "^(rw%.a%d+)%.s(%d+)$")
			if template then
				local need = Setup.stageGates(Content, template, tonumber(stage))
				local state, reason = Archipelago.open(Content, {
					id = "studio",
					index = need.index,
					seed = 1,
					revision = "r",
					ttl = 1800,
					entryBuffer = 0,
					actor = "1",
				}, { level = need.level, developmentRank = need.rank, instabilityAccess = need.index }, 0)
				assert(state, layout.id .. " stage 1 opens: " .. tostring(reason))
				state.stage = tonumber(stage)
				for id in need.completed do
					state.completed[id] = true
				end
				local ok, refused = Archipelago.admit(
					state,
					Content,
					{ level = need.level, developmentRank = need.rank, instabilityAccess = need.index },
					0,
					0
				)
				assert(ok, layout.id .. " admitted: " .. tostring(refused))
			end
		end
		assert(Setup.stageGates(Content, "rw.a1", 1).level == 30, "rw.a1 needs level 30, not the old 2")
	end,
	["the Studio server seeds through stageGates and only under IsStudio"] = function()
		local server = fs.readFile("games/robango-island/src/server/RobangoIslandServer.server.luau")
		local first = assert(string.find(server, 'if RunService:IsStudio() and worldRole == "archipelago"', 1, true))
		local seed = assert(string.find(server, "StudioSetup).stageGates(", 1, true))
		assert(seed > first, "stage seed sits inside the Studio-only departure helper")
		assert(not string.find(server, "math.max(2, state.level)", 1, true), "fixed level 2 seed removed")
		assert(
			string.find(server, "isStudio = RunService:IsStudio(),\n\tworkspace = workspace,", 1, true),
			"gallery guard"
		)
	end,
	["species gallery is inert outside Studio and without the attribute"] = function()
		local Setup = setup()
		for _, case in { { false, true }, { true, nil } } do
			local stub = rig()
			local ws = workspace(case[2])
			local env = { isStudio = case[1], workspace = ws, content = Content, rig = stub }
			assert(Setup.gallery(env) == nil and stub.grounded == 0, "inert")
		end
	end,
	["Studio species gallery places all 24 species, labelled, on a walk then attack loop"] = function()
		local Setup = setup()
		local stub = rig()
		local ws = workspace(true)
		ws.Terrain.FillBlock = function()
			ws.filled += 1
		end
		local states, loop, folder: any = {}, nil, nil
		folder = Setup.gallery({
			isStudio = true,
			workspace = ws,
			content = Content,
			rig = stub,
			parent = ws.root,
			center = roblox.Vector3.new(0, 0, 900),
			spawn = function(fn)
				loop = fn
			end,
			wait = function()
				local model = folder:GetChildren()[1]
				table.insert(states, model:GetAttribute("ForgeWildlifeState"))
				if #states == #Setup.LOOP then
					folder.Parent = nil
				end
			end,
		})
		assert(folder and ws.filled == 1, "gallery built on a terrain pad")
		local species, positions = {}, {}
		for _, model in folder:GetChildren() do
			species[model:GetAttribute("Species")] = true
			local label = model.PrimaryPart:FindFirstChild("ForgeGalleryName")
			assert(label and label:IsA("BillboardGui"), "labelled: " .. model.Name)
			assert(label:FindFirstChildOfClass("TextLabel").Text == model:GetAttribute("Species"), "label text")
			local p = model.PrimaryPart.Position
			local key = math.floor(p.X) .. "," .. math.floor(p.Z)
			assert(not positions[key], "one species per grid cell")
			positions[key] = true
		end
		for _, detail in Content.wildlifeDetails do
			assert(species[detail.id], "gallery shows " .. detail.id)
		end
		assert(#folder:GetChildren() == 24 and stub.grounded == 24, "all 24 species grounded")
		assert(loop, "animation loop scheduled")
		loop()
		assert(states[1] == "walk" and table.find(states, "strike"), "walk then attack: " .. table.concat(states, ","))
		local CreaturePose = require("./src/client/CreaturePose")
		for _, state in states do
			local clip = CreaturePose.sample({ state = "", elapsed = 0 }, state, 12, false, 0.1)
			assert(clip == "walk" or clip == "windup" or clip == "attack", "client poses " .. state .. " as " .. clip)
		end
	end,
}
