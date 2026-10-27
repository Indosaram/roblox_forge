--!strict
-- B3 mesh swap: the station parts keep every tag, prompt and attribute, built placements clone
-- the mesh kit under a still-tagged station part, and the G24 cut-away fades only from inside.
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Cutaway = require("./src/client/Cutaway")
local roblox: any = require("@lune/roblox")

-- One fake row per catalog key the pack uses: a body mesh plus a cut-away roof mesh.
local function templates(engine: any): { [string]: any }
	local rows = {}
	local keys = {}
	for _, key in engine.meshes.STRUCTURES do
		keys[key] = true
	end
	for _, key in engine.meshes.DRESSING do
		keys[key] = true
	end
	for _, piece in engine.meshes.SET_PIECES do
		keys[piece.row] = true
	end
	for _, set in engine.meshes.FACILITIES do
		keys[set.row] = true
	end
	for key in keys do
		local m = engine.newInstance("Model")
		m.Name = key
		local body = engine.newInstance("MeshPart")
		body.Name, body.Size, body.Position = key, roblox.Vector3.new(6, 3, 6), roblox.Vector3.new(0, 1.5, 0)
		body.CFrame = roblox.CFrame.new(body.Position)
		body.Parent = m
		local roof = engine.newInstance("MeshPart")
		roof.Name, roof.Size, roof.Position = key .. "__cut", roblox.Vector3.new(6, 2, 6), roblox.Vector3.new(0, 4, 0)
		roof.CFrame = roblox.CFrame.new(roof.Position)
		roof.Parent = m
		rows[key] = m
	end
	return rows
end

return {
	["mesh stations keep tags prompts and attributes and hide their gameplay part"] = function()
		local engine = Engine.new()
		engine.meshes.setTemplates(templates(engine))
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.harbor", 1776)
		local stations, dressed = 0, 0
		for _, part in engine.game:GetService("CollectionService"):GetTagged("ForgeSurvivalStation") do
			stations += 1
			assert(part:GetAttribute("ForgeStationId") and part:GetAttribute("ForgeStationKind"), part.Name .. " attrs")
			local visual = part:FindFirstChild("ForgeMeshVisual")
			if visual then
				dressed += 1
				assert(part.Transparency == 1, "gameplay part hidden behind the mesh")
				for _, child in visual:GetDescendants() do
					if child:IsA("BasePart") then
						assert(not child.CanCollide and not child.CanQuery, "station mesh never blocks reach")
					end
				end
			end
		end
		assert(stations >= 5 and dressed == stations, "every harbor station dressed: " .. dressed .. "/" .. stations)
		local relay = assert(world.tieredStations["station.signal-relay.t1"], "relay registered")
		local prompt = relay:FindFirstChild("ForgeStationPanel")
		assert(prompt and prompt:GetAttribute("ForgePanel") == "technical-support", "relay prompt kept")
		local workbench = assert(world.tieredStations["station.workbench.t1"], "harbor workbench registered")
		local talk = false
		for _, child in workbench:GetChildren() do
			talk = talk or (child.ClassName == "ProximityPrompt" and child:GetAttribute("ForgeDialogue") ~= nil)
		end
		assert(talk, "harbor workbench dialogue prompt kept")
		local root = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld")
		assert(root:FindFirstChild("visitor-portal.set"), "rift set piece beside the visitor portal")
		assert(root:FindFirstChild("set.town.dock"), "harbor dock set piece")
		world.destroy()
		engine.meshes.setTemplates(nil)
	end,
	["structure kits swap to mesh rows within the footprint and build placement keeps the station"] = function()
		local engine = Engine.new()
		local rows = templates(engine)
		engine.meshes.setTemplates(rows)
		local kits = engine.newInstance("Folder")
		for _, definition in Content.structures do
			local kit = engine.dressing.structure(kits, definition, 4)
			assert(engine.meshes.structureKit(kit, definition, 4), "mesh row for " .. definition.id)
			assert(kit:GetAttribute("ForgeMeshRow") == engine.meshes.STRUCTURES[definition.id], definition.id)
			local cut = false
			for _, part in kit:GetDescendants() do
				assert(part.ClassName == "MeshPart", definition.id .. " keeps a primitive part")
				assert(
					part.Size.X <= definition.footprintX * 4 + 2 and part.Size.Z <= definition.footprintZ * 4 + 2,
					definition.id .. " overhangs the footprint"
				)
				cut = cut or part:GetAttribute("ForgeCutaway") == true
			end
			assert(cut, definition.id .. " cut-away mesh tagged")
		end
		-- Placement path: SurvivalWorld clones the kit under the authoritative station part.
		local bootstrap = engine.load("games/robango-island/src/server/SurvivalWorldBootstrap.luau", {
			["./WorldDressing"] = engine.dressing,
			["./StructureMeshes"] = engine.meshes,
		}, { Parent = { RoleWorld = engine.role, HomeWorld = engine.home, BrawlWorld = {} } })
		local world = bootstrap(Content, Source, Policy, function()
			return 0
		end, "home", false)
		local live = assert(world.structureKits:FindFirstChild("workbench"))
		assert(live:GetAttribute("ForgeMeshRow") == "bld.workbench.t1", "live kit is the mesh row")
		local Settlement = require("../../core/domain/settlement/Settlement")
		local ports = world.settlementPorts(roblox.Vector3.zero, roblox.Vector3.new(0, 2, 0))
		local state = Settlement.new({ tribeId = "camp", width = 8, depth = 8, cellStuds = 4, maxMembers = 4 }, "1")
		local definition
		for _, candidate in Content.structures do
			if candidate.id == "workbench" then
				definition = candidate
			end
		end
		state = assert(Settlement.reserve(state, "1", 0, 0, {
			id = "build",
			x = 1,
			z = 1,
			rotation = 1,
			definition = table.clone(definition),
		}))
		state = assert(Settlement.commit(state, "1", 1, "build"))
		ports.publish(state)
		local placed = assert(engine.game:GetService("Workspace"):FindFirstChild("workbench"), "placed station")
		local structureId = placed:GetAttribute("ForgeStructureId")
		assert(type(structureId) == "string" and state.structures[structureId], "structure id kept")
		assert(
			engine.game:GetService("CollectionService"):HasTag(placed, "ForgeSurvivalStation"),
			"placed workbench is still a station"
		)
		local visual = placed:FindFirstChild("workbench")
		assert(visual and visual:GetAttribute("ForgeMeshRow") == "bld.workbench.t1", "mesh clone under the part")
		assert(placed.Transparency == 1 and placed.CanCollide == false, "footprint part hidden by the kit")
		world.destroy()
		engine.meshes.setTemplates(nil)
	end,
	["without mesh templates the primitive kits stay"] = function()
		local engine = Engine.new()
		local kits = engine.newInstance("Folder")
		for _, definition in Content.structures do
			local kit = engine.dressing.structure(kits, definition, 4)
			assert(not engine.meshes.structureKit(kit, definition, 4), "no template, no swap")
			assert(#kit:GetChildren() > 1, definition.id .. " primitive kit intact")
		end
	end,
	["cut-away fades only while the character is inside a footprint"] = function()
		local house = {
			key = "house",
			box = { cframe = roblox.CFrame.new(0, 4, 0), size = roblox.Vector3.new(16, 8, 12) },
		}
		local wall = {
			key = "wall",
			box = { cframe = roblox.CFrame.new(9, 4, 0), size = roblox.Vector3.new(1, 8, 8) },
		}
		local far = {
			key = "far",
			box = { cframe = roblox.CFrame.new(60, 4, 0), size = roblox.Vector3.new(16, 8, 12) },
		}
		local groups = { house, wall, far }
		local inside = Cutaway.plan(roblox.Vector3.new(2, 2, 1), groups)
		assert(inside.house and inside.wall and not inside.far, "inside fades the house and its adjoining wall")
		local outside = Cutaway.plan(roblox.Vector3.new(0, 2, 20), groups)
		assert(next(outside) == nil, "outside fades nothing")
		local onRoof = Cutaway.plan(roblox.Vector3.new(0, 12, 0), groups)
		assert(next(onRoof) == nil, "standing on the roof is not indoors")
		local rotated = {
			key = "turned",
			box = {
				cframe = roblox.CFrame.new(0, 4, 0) * roblox.CFrame.Angles(0, math.rad(90), 0),
				size = roblox.Vector3.new(20, 8, 4),
			},
		}
		assert(Cutaway.plan(roblox.Vector3.new(0, 2, 8), { rotated }).turned, "footprint follows the yaw")
		assert(next(Cutaway.plan(roblox.Vector3.new(8, 2, 0), { rotated })) == nil, "outside the turned footprint")
	end,
}
