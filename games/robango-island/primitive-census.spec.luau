--!strict
-- G10 primitive census (asset-audit L8): with every uploaded mesh row available (B3 building and
-- town rows exported by gen_buildings.py, the B1 node rows and the B1 biome kit rows), a built role
-- shows no visible non-mesh BasePart. Gameplay handles (prompts, taps, collision) stay as invisible
-- Parts. Each visible primitive is filed under its owner; only the creature part rig (a species
-- whose skinned template is not loaded: DinosaurRig, genre/L4) and the NPC/castaway stand-ins (no
-- figure row yet: L6) may remain. Run with CENSUS=1 in the environment to print the table.
local fs = require("@lune/fs")
local process = require("@lune/process")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local HomeContent = require("../../core/domain/home/HomeContent")
local Home = require("../../core/domain/home/HomeState")
local roblox: any = require("@lune/roblox")

local ROLES = { "rw.onboarding", "rw.town", "rw.explore10", "rw.harbor", "rw.a1.s1", "rw.home" }
-- Owners whose primitives this lane may leave (named in the report).
local EXTERNAL = { ["creature-rig (L4/genre)"] = true, ["npc-figure (L6)"] = true }

--- Every row key gen_buildings.py exports (its ROWS table).
local function buildingRows(): { string }
	local source = fs.readFile("games/robango-island/assets/blender/gen_buildings.py")
	local block = assert(string.match(source, "\nROWS = (%b[])"), "ROWS table")
	local keys = {}
	for key in string.gmatch(block, '%("([%w%.%-]+)",') do
		table.insert(keys, key)
	end
	assert(#keys >= 60, "gen_buildings rows: " .. #keys)
	return keys
end

local function mesh(engine: any, name: string, y: number): any
	local value = engine.newInstance("MeshPart")
	value.Name, value.Size = name, roblox.Vector3.new(4, 4, 4)
	value.Position, value.CFrame = roblox.Vector3.new(0, y, 0), roblox.CFrame.new(0, y, 0)
	return value
end

--- Injects fake templates for every uploaded row into the engine's mesh seams.
local function loadAll(engine: any)
	local rows = {}
	for _, key in buildingRows() do
		local model = engine.newInstance("Model")
		model.Name = key
		mesh(engine, key, 2).Parent = model
		mesh(engine, key .. "__cut", 6).Parent = model
		rows[key] = model
	end
	engine.meshes.setTemplates(rows)
	local shared = engine.forge.games["robango-island"].src.shared
	if shared.NodeMeshes then
		local nodes = {}
		for _, row in shared.NodeMeshes.ROWS do
			nodes[row.full] = mesh(engine, row.full, 1.5)
			nodes[row.depleted] = mesh(engine, row.depleted, 1)
		end
		shared.NodeMeshes.setTemplates(nodes)
	end
	-- BiomeKits.load returns its shared template table when there is no InsertService.
	local kits = shared.BiomeKits.load({}, {})
	for _, list in shared.BiomeKits.kits do
		for _, row in list do
			kits[row.key] = mesh(engine, row.key, 2)
		end
	end
end

local function owner(part: any): string
	local current = part.Parent
	while current do
		if current.GetAttribute and current:GetAttribute("Species") ~= nil then
			return "creature-rig (L4/genre)"
		end
		current = current.Parent
	end
	local facility = part:GetAttribute("ForgeHarborFacility")
	if
		(type(facility) == "string" and string.sub(facility, 1, 4) == "npc.")
		or string.find(part.Name, "Castaway", 1, true)
	then
		return "npc-figure (L6)"
	end
	return "L8"
end

--- Visible primitives under the role world: owner -> count and label -> count.
local function census(engine: any): ({ [string]: number }, { [string]: number })
	local root = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld")
	local owners, labels = {}, {}
	for _, part in root:GetDescendants() do
		if not part:IsA("BasePart") or part.ClassName == "MeshPart" or part.Transparency == 1 then
			continue
		end
		local who = owner(part)
		owners[who] = (owners[who] or 0) + 1
		if not EXTERNAL[who] then
			local label = if process.env.CENSUS == "full"
				then part.Name
				else string.gsub(string.gsub(part.Name, "rw%.[%w%.%-]+", "<role>"), "%-?%d+", "#")
			labels[label] = (labels[label] or 0) + 1
		end
	end
	return owners, labels
end

local function describe(map: { [string]: number }): string
	local list = {}
	for key, n in map do
		table.insert(list, key .. "=" .. n)
	end
	table.sort(list)
	return table.concat(list, ", ")
end

local function build(id: string, templates: boolean): (any, any)
	local engine = Engine.new()
	if templates then
		loadAll(engine)
	end
	local world = engine.role.build(Content, Source, Policy, function()
		return 0
	end, id, 1776)
	if id == "rw.home" then
		local rules = HomeContent.rules(Content)
		world.renderHome(engine.home.plan(Content, Home.new("owner", rules, 1776), rules))
	end
	return engine, world
end

return {
	["with every mesh row loaded no lane-owned primitive is visible on the role layouts"] = function()
		local failures, lines = {}, {}
		for _, id in ROLES do
			local engine, world = build(id, true)
			local owners, labels = census(engine)
			local total = 0
			for _, n in owners do
				total += n
			end
			table.insert(
				lines,
				string.format("%s\tvisible=%d\t%s\t| %s", id, total, describe(owners), describe(labels))
			)
			if (owners.L8 or 0) > 0 then
				table.insert(failures, id .. ": " .. owners.L8 .. " primitives (" .. describe(labels) .. ")")
			end
			world.destroy()
		end
		if process.env.CENSUS then
			print("\n" .. table.concat(lines, "\n"))
		end
		assert(#failures == 0, table.concat(failures, "\n"))
	end,
}
