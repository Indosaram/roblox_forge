--!strict
-- B1a scatter gate: the biome-kit plan is deterministic for a recorded seed, meets the G9
-- density (>= 20 mesh vegetation instances per default-zoom screen) on every B1a role and on one
-- role per B1b kit (swamp, desert, snow/tundra, volcano), and never
-- places anything in water, on a cliff face, on a path/spawn clearing or on a gather node.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local Kits = require("./src/shared/BiomeKits")

local document = serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
local layouts: { [string]: any } = {}
for _, layout in document.layouts do
	layouts[layout.id] = layout
end

local SEED = 20261027
local function plan(id: string, seed: number): ({ any }, { any })
	local layout = layouts[id]
	local columns = Terrain.columns(layout, seed, if id == "rw.onboarding" then 16 else 32)
	return Kits.plan(layout, columns, seed, Terrain), columns
end

local cases = {}

-- Every catalog row named in a kit is unique and belongs to that kit's biome.
cases["kit rows are unique and biome-scoped"] = function()
	for kit, rows in Kits.kits do
		local seen = {}
		for _, row in rows do
			assert(not seen[row.key], "duplicate row " .. row.key)
			seen[row.key] = true
			assert(string.find(row.key, "." .. kit .. ".", 1, true), row.key .. " is not a " .. kit .. " row")
			assert(Kits.lod[row.family], "unknown family " .. row.family)
		end
	end
end

-- Determinism: the same seed gives identical placements; a different seed moves them.
cases["same seed gives the same scatter, another seed moves it"] = function()
	local a = plan("rw.a1.s1", SEED)
	local b = plan("rw.a1.s1", SEED)
	assert(#a == #b and #a > 0, "plan size differs or is empty")
	for i = 1, #a do
		local p, q = a[i], b[i]
		assert(
			p.key == q.key and p.x == q.x and p.z == q.z and p.yaw == q.yaw and p.scale == q.scale,
			"placement " .. i .. " differs"
		)
	end
	local c = plan("rw.a1.s1", SEED + 1)
	local moved = #c ~= #a or c[1].x ~= a[1].x
	assert(moved, "a different seed must change the scatter")
end

-- Kit map per catalog section 2.
cases["roles map to the catalog kits"] = function()
	assert(Kits.kitsFor(layouts["rw.a2.s1"])[1] == "jungle", "tropical uses the jungle kit")
	assert(Kits.kitsFor(layouts["rw.a1.s3"])[1] == "savanna", "rw.a1.s3 uses the savanna kit")
	assert(Kits.kitsFor(layouts["rw.explore20"])[1] == "savanna", "explore20 uses the savanna kit")
	assert(Kits.kitsFor(layouts["rw.a1.s2"])[1] == "lake", "rw.a1.s2 uses the lake kit")
	assert(Kits.kitsFor(layouts["rw.harbor"])[1] == "beach", "harbor uses the beach kit")
	assert(Kits.kitsFor(layouts["rw.a2.s2"])[1] == "swamp", "swamp roles use the swamp kit")
	assert(Kits.kitsFor(layouts["rw.a1.s4"])[1] == "desert", "desert roles use the desert kit")
	assert(Kits.kitsFor(layouts["rw.a4.s1"])[1] == "tundra", "snow roles use the tundra kit")
	assert(Kits.kitsFor(layouts["rw.a5.s1"])[1] == "volcano", "volcano roles use the volcano kit")
	assert(Kits.kitsFor(layouts["rw.frontier40"])[1] == "tundra", "a mixed role uses its first biome's kit")
	for _, kit in Kits.allKits do
		assert(Kits.packages[kit] and Kits.kits[kit], kit .. " has a package and rows")
	end
	-- B1b MeshParts are named with underscores; the loader maps them back to the row key.
	assert(Kits.modelKey["veg_swamp_dead_bare"] == "veg.swamp.dead-bare", "B1b model names alias row keys")
end

-- Each B1b kit is deterministic on a role of its own biome.
cases["B1b kits: same seed gives the same scatter"] = function()
	for _, id in { "rw.a2.s2", "rw.a1.s4", "rw.a4.s1", "rw.a5.s1" } do
		local a = plan(id, SEED)
		local b = plan(id, SEED)
		assert(#a == #b and #a > 0, id .. ": plan size differs or is empty")
		for i = 1, #a do
			assert(
				a[i].key == b[i].key and a[i].x == b[i].x and a[i].z == b[i].z,
				id .. ": placement " .. i .. " differs"
			)
		end
	end
end

local VEG = { tree = true, shrub = true, fern = true, grass = true }
local ROLES = {
	"rw.a1.s1",
	"rw.a1.s2",
	"rw.a1.s3",
	"rw.a2.s1",
	"rw.a3.s3",
	"rw.explore10",
	"rw.explore20",
	"rw.harbor",
	"rw.onboarding",
	-- B1b kits: swamp, desert, snow (tundra kit), volcano.
	"rw.a2.s2",
	"rw.a1.s4",
	"rw.a4.s1",
	"rw.a5.s1",
}
cases["no water, cliff or path placements and >= 20 vegetation per screen"] = function()
	for _, id in ROLES do
		local layout = layouts[id]
		local placements, columns = plan(id, SEED)
		local ground = Kits.ground(columns)
		local kitsSeen: { [string]: { [string]: boolean } } = {}
		-- Nothing in water, on cliffs, on protected ground or on gather nodes; heights are the
		-- shared terrain top at that point (no raycast).
		for _, p in placements do
			assert(
				Kits.allowed(layout, Terrain, ground, p.x, p.z, 1),
				id .. ": " .. p.key .. " placed on blocked ground"
			)
			local top = ground.top(p.x, p.z) :: number
			assert(top > Kits.LAND_TOP, id .. ": " .. p.key .. " in water")
			assert(ground.slope(p.x, p.z) <= Kits.CLIFF_SLOPE, id .. ": " .. p.key .. " on a cliff")
			assert(p.y == top, id .. ": height is not the terrain top")
			kitsSeen[p.kit] = kitsSeen[p.kit] or {}
			if VEG[p.family] then
				kitsSeen[p.kit][p.key] = true
			end
		end
		-- Plant mix: each inland kit shows at least 5 distinct vegetation types (A2b found 2 too few).
		local inland = Kits.kitsFor(layout)[1]
		local types = 0
		for _ in kitsSeen[inland] or {} do
			types += 1
		end
		assert(types >= 5, id .. ": only " .. types .. " vegetation types from the " .. inland .. " kit")
		-- Density: count vegetation per default-zoom screen window (100 x 220 studs) over windows
		-- that are mostly scatterable land; the median window must hold >= 20, the worst >= 12.
		local counts = {}
		local low, high = layout.bounds.min, layout.bounds.max
		for wx = low.x, high.x - 100, 50 do
			for wz = low.z, high.z - 220, 55 do
				local open, probes = 0, 0
				for sx = wx + 5, wx + 95, 10 do
					for sz = wz + 5, wz + 215, 10 do
						probes += 1
						if Kits.allowed(layout, Terrain, ground, sx, sz, 1) then
							open += 1
						end
					end
				end
				if open / probes >= 0.8 then
					local n = 0
					for _, p in placements do
						if VEG[p.family] and p.x >= wx and p.x < wx + 100 and p.z >= wz and p.z < wz + 220 then
							n += 1
						end
					end
					table.insert(counts, n)
				end
			end
		end
		if #counts == 0 then
			-- Small or crowded roles (harbor, onboarding): no whole screen is open ground, so measure
			-- vegetation per scatterable area and scale it to one screen.
			local open = 0
			for sx = low.x, high.x, 8 do
				for sz = low.z, high.z, 8 do
					if Kits.allowed(layout, Terrain, ground, sx, sz, 1) then
						open += 64
					end
				end
			end
			local veg = 0
			for _, p in placements do
				if VEG[p.family] then
					veg += 1
				end
			end
			local perScreen = veg / math.max(open, 1) * Kits.SCREEN_AREA
			assert(perScreen >= 20, id .. ": vegetation per open screen area " .. perScreen .. " < 20")
			print(
				string.format("%s: %d placements, %.0f veg per screen-area of open ground", id, #placements, perScreen)
			)
			continue
		end
		table.sort(counts)
		local median = counts[math.ceil(#counts / 2)]
		assert(median >= 20, id .. ": median vegetation per screen " .. median .. " < 20")
		assert(counts[1] >= 12, id .. ": sparsest open screen holds " .. counts[1])
		print(
			string.format(
				"%s: %d placements, %d windows, veg/screen min %d median %d max %d",
				id,
				#placements,
				#counts,
				counts[1],
				median,
				counts[#counts]
			)
		)
	end
end

-- Client LOD rules (catalog LOD columns + low-profile lever 1).
cases["LOD distances and low-profile grass lever"] = function()
	assert(
		Kits.visible("grass", 150, false) and not Kits.visible("grass", 150, true),
		"low profile hides grass past 120"
	)
	assert(not Kits.visible("fern", 300, false) and Kits.visible("tree", 500, true), "fern 256 / tree 512")
	-- Every family a kit row uses (B1a and B1b) has LOD distances.
	for kit, rows in Kits.kits do
		for _, row in rows do
			assert(Kits.visible(row.family, 0, true), kit .. ": " .. row.key .. " has no LOD family")
		end
	end
end

-- Live staging v30/v31: voxel terrain rounds a FillBlock top up to the 4-stud grid (onboarding
-- column tops 2.0 render at 4.0), so kits seated on the planned column top were buried (768 of
-- 1969 on the real engine: every clutter row, most ferns and rocks). The onboarding role must
-- place kits from the InsertService package and seat each one on the rendered surface.
cases["onboarding places package kits on the rendered terrain surface"] = function()
	local roblox: any = require("@lune/roblox")
	local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
	local Content = require("./src/shared/SurvivalContent")
	local engine = Engine.new(nil, true)
	-- A package shaped like the uploads: a Model of MeshParts named by row key, ground-centred.
	local loads = 0
	local insert = {
		LoadAsset = function(_, _id: number): any
			loads += 1
			local model = engine.newInstance("Model")
			for _, rows in Kits.kits do
				for _, row in rows do
					local part = engine.newInstance("MeshPart")
					-- Clutter rows ship as ~0.02-stud flat cards (real package sizes).
					local height = if row.family == "clutter" then 0.02 else 3
					part.Name, part.Size = row.key, roblox.Vector3.new(4, height, 4)
					part.Parent = model
				end
			end
			function model:FindFirstChildWhichIsA(kind: string): any
				for _, child in self:GetDescendants() do
					if child:IsA(kind) then
						return child
					end
				end
				return nil
			end
			return model
		end,
	}
	local getService = engine.game.GetService
	engine.game.GetService = function(self, key)
		return if key == "InsertService" then insert else getService(self, key)
	end
	local workspace = engine.game:GetService("Workspace")
	-- The rendered surface sits a voxel step above the planned column top, as on Roblox.
	local raycast = workspace.Raycast
	workspace.Raycast = function(self, origin, direction, params)
		local hit = raycast(self, origin, direction, params)
		return if hit
			then { Instance = hit.Instance, Normal = hit.Normal, Position = hit.Position + roblox.Vector3.new(0, 2, 0) }
			else nil
	end
	local Source = require("./src/shared/SurvivalWorldConfig")
	-- RoleWorld reads the generated asset ids at load; reload it with them registered.
	engine.forge.games["robango-island"].src.shared.Assets = require("./src/shared/Assets")
	local role = engine.load("games/robango-island/src/server/RoleWorld.luau", {
		["./WorldDressing"] = engine.dressing,
		["./StructureMeshes"] = engine.meshes,
		["./OpeningDirector"] = engine.load("games/robango-island/src/server/OpeningDirector.luau", {}, nil),
	}, nil)
	local world = role.build(Content, Source, require("./src/shared/WildlifePolicy"), function()
		return 0
	end, "rw.onboarding", 1776)
	local folder = workspace:FindFirstChild("ForgeRoleWorld"):FindFirstChild("ForgeBiomeKits")
	assert(folder, "onboarding builds a ForgeBiomeKits folder")
	local count = folder:GetAttribute("ForgeKitCount")
	local parts = folder:GetChildren()
	assert(loads > 0 and type(count) == "number" and count > 0 and count == #parts, "kits placed: " .. tostring(count))
	for _, part in parts do
		local p = part.CFrame.Position
		local hit = workspace:Raycast(roblox.Vector3.new(p.X, 512, p.Z), roblox.Vector3.new(0, -1024, 0), {
			IgnoreWater = true,
		})
		assert(hit, part.Name .. " has no ground")
		local bottom = p.Y - part.Size.Y / 2
		assert(bottom - hit.Position.Y >= -0.3 - 1e-6, part.Name .. " sits below the rendered surface")
		assert(bottom - hit.Position.Y <= 0.05 + 1e-6, part.Name .. " floats above the rendered surface")
		assert(p.Y + part.Size.Y / 2 > hit.Position.Y, part.Name .. " is buried")
	end
	world.destroy()
end

cases["NEGATIVE: water, cliff faces and paths are rejected"] = function()
	local layout = layouts["rw.a1.s1"]
	local columns = Terrain.columns(layout, SEED, 32)
	local ground = Kits.ground(columns)
	-- Columns cover land only; sea is any point with no column (the island's outer rim).
	local wet = { x = layout.bounds.max.x + 48, z = 0 }
	assert(ground.top(wet.x, wet.z) == nil, "probe point must be sea")
	local steep = nil
	for _, column in columns do
		if ground.slope(column.x, column.z) > Kits.CLIFF_SLOPE then
			steep = steep or column
		end
	end
	assert(wet and not Kits.allowed(layout, Terrain, ground, wet.x, wet.z, 1), "a sea column must be rejected")
	assert(steep and not Kits.allowed(layout, Terrain, ground, steep.x, steep.z, 1), "a cliff column must be rejected")
	local point = layout.paths[1].points[1]
	assert(not Kits.allowed(layout, Terrain, ground, point.x, point.z, 1), "a path point must be rejected")
	assert(not Kits.allowed(layout, Terrain, ground, 99999, 99999, 1), "off-island must be rejected")
end

-- D1 (G21) startup budget, staging v36 on SM-N981N: onboarding TTFI ~32 s / PSS ~1.0-1.1 GB.
-- Each role loads only its own kits (no all-kit server preload), and kits go in nearest the spawn
-- first: a bounded first batch, then fixed-size batches, never the whole island in one frame.
cases["D1: a role loads only its own kits and no server start preloads every kit"] = function()
	for _, id in ROLES do
		local kits = Kits.kitsFor(layouts[id])
		assert(#kits >= 1 and #kits <= 3, id .. " loads " .. #kits .. " kits (budget 3 of " .. #Kits.allKits .. ")")
	end
	local server = fs.readFile("games/robango-island/src/server/RobangoIslandServer.server.luau")
	assert(not string.find(server, "BiomeKits.allKits", 1, true), "the server never preloads every kit package")
	local role = fs.readFile("games/robango-island/src/server/RoleWorld.luau")
	assert(
		string.find(role, "BiomeKits.load, BiomeKits.kitsFor(layout)", 1, true),
		"the role build starts its own kit loads before the terrain writes"
	)
end

cases["D1: kit batches are nearest-first, bounded, and the first batch fills the spawn screen"] = function()
	assert(Kits.KIT_FIRST_MAX <= 400 and Kits.KIT_BATCH <= 300, "placement budget")
	for _, id in { "rw.onboarding", "rw.explore10", "rw.a1.s1", "rw.a1.s2", "rw.harbor" } do
		local layout = layouts[id]
		local entry = layout.anchors[1].position
		for _, anchor in layout.anchors do
			entry = if anchor.id == "entry" then anchor.position else entry
		end
		local placements = plan(id, SEED)
		local batches = Kits.batches(placements, entry)
		local total, last = 0, -1
		for index, batch in batches do
			local cap = if index == 1 then Kits.KIT_FIRST_MAX else Kits.KIT_BATCH
			assert(#batch <= cap, id .. ": batch " .. index .. " holds " .. #batch .. " > " .. cap)
			for _, p in batch do
				local d = (p.x - entry.x) ^ 2 + (p.z - entry.z) ^ 2
				assert(d >= last, id .. ": batches are not nearest-first")
				if index == 1 then
					assert(d <= Kits.KIT_FIRST_RADIUS ^ 2, id .. ": first batch reaches past the first radius")
				end
				last = d
			end
			total += #batch
		end
		assert(total == #placements, id .. ": batches drop or repeat placements")
		-- B1 must not regress: the spawn's default-zoom screen (220 x 100 landscape) gets the same
		-- vegetation from the first batch as from the whole plan, and >= 20 where the role is dressed.
		local function screenVeg(list: { any }): number
			local n = 0
			for _, p in list do
				if VEG[p.family] and math.abs(p.x - entry.x) <= 110 and math.abs(p.z - entry.z) <= 50 then
					n += 1
				end
			end
			return n
		end
		local first, all = screenVeg(batches[1]), screenVeg(placements)
		assert(first == all or first >= 20, id .. ": first batch shows " .. first .. " of " .. all .. " screen veg")
		if id ~= "rw.harbor" then
			assert(first >= 20, id .. ": spawn screen veg " .. first .. " < 20")
		end
		print(
			string.format(
				"%s: %d kits, first batch %d (screen veg %d), %d batches",
				id,
				#placements,
				#batches[1],
				first,
				#batches
			)
		)
	end
end

cases["D1: a role loads only its own creature templates up front"] = function()
	local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
	local Content = require("./src/shared/SurvivalContent")
	local Dressing = Engine.new().dressing
	local role = Engine.new().role
	for _, id in { "rw.onboarding", "rw.explore10", "rw.town", "rw.a1.s1" } do
		local layout = layouts[id]
		local columns = Terrain.columns(layout, SEED, if id == "rw.onboarding" then 16 else 32)
		local species = role.roleSpecies(Content, layout, Dressing.plan(layout, columns, Terrain).fauna)
		assert(#species <= 8, id .. " loads " .. #species .. " creature packages up front (budget 8 of 24)")
		for _, spawn in layout.spawns do
			if table.find(role.MESH_SPECIES, spawn.speciesId) then
				assert(table.find(species, spawn.speciesId), id .. ": " .. spawn.speciesId .. " is not loaded up front")
			end
		end
	end
end
-- D2 F3: a 58-stud veg.jungle.buttress-giant beside the onboarding spawn filled the whole default
-- view. Trees stay ARRIVAL_CLEAR.tree studs and rocks ARRIVAL_CLEAR.rock studs from every arrival
-- (entry spawn and the archipelago yard spawn), on every dressed role layout. With the L3 ~30-stud
-- cap the clearing is sized to the cold-open sight line, no wider, so trees still frame the spawn.
cases["D2: no tree or rock kit crowds an arrival on any role layout"] = function()
	local sight = Kits.ARRIVAL_SIGHT
	local needed = sight.treeTop / math.tan(math.rad(sight.pitch)) + sight.crownRadius
	assert(Kits.ARRIVAL_CLEAR.tree >= needed, "tree clearing covers the 35-degree cold-open sight line")
	assert(Kits.ARRIVAL_CLEAR.tree <= needed + 8, "tree clearing no wider than the sight line needs")
	assert(Kits.ARRIVAL_CLEAR.rock >= 32, "rock clearing")
	local ids = table.clone(ROLES)
	for _, extra in { "rw.town", "rw.brawl", "rw.team-outpost" } do
		table.insert(ids, extra)
	end
	for _, id in ids do
		local layout = layouts[id]
		local arrivals = Kits.arrivals(layout)
		assert(#arrivals >= 1, id .. " has an arrival")
		if string.match(id, "^rw%.a%d+%.s%d+$") then
			assert(#arrivals == 2, id .. ": the yard spawn is an arrival")
		end
		for _, p in plan(id, SEED) do
			local radius = Kits.ARRIVAL_CLEAR[p.family]
			if radius then
				for _, point in arrivals do
					local d = math.sqrt((p.x - point.x) ^ 2 + (p.z - point.z) ^ 2)
					assert(d >= radius, string.format("%s: %s %.0f studs from an arrival", id, p.key, d))
				end
			end
		end
	end
	-- The D2 Studio seed (1776): the onboarding plan still dresses the island with trees.
	local trees = 0
	for _, p in plan("rw.onboarding", 1776) do
		trees += if p.family == "tree" then 1 else 0
	end
	assert(trees >= 60, "onboarding keeps its trees: " .. trees)
	-- Framed, not blocked: trees stand just outside the clearing around the onboarding spawn.
	local layout = layouts["rw.onboarding"]
	local entry = Kits.arrivals(layout)[1]
	local framing = 0
	for _, p in plan("rw.onboarding", 1776) do
		local d = math.sqrt((p.x - entry.x) ^ 2 + (p.z - entry.z) ^ 2)
		framing += if p.family == "tree" and d <= Kits.ARRIVAL_CLEAR.tree + 48 then 1 else 0
	end
	assert(framing >= 4, "trees frame the onboarding spawn: " .. framing)
end

return cases
