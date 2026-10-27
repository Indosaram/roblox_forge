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

return cases
