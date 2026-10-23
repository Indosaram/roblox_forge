--!strict
-- Generated ProcAssets props dress every organic role (harbor + 20 stages) and the home.
local Content = require("./src/shared/SurvivalContent")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local ProcProps = require("./src/shared/ProcProps")
local ProcAssets = require("./src/shared/ProcAssets")
local RenderBudget = require("./src/shared/RenderBudget")
local serde = require("@lune/serde")

local MIN_PROPS = 12
local MIN_HOME_PROPS = 6
local SEED = 79

local function roles(): { any }
	local list = {}
	for _, layout in Content.layouts :: any do
		if Terrain.organic(layout) or layout.id == "rw.home" then
			table.insert(list, layout)
		end
	end
	return list
end

local function plan(layout: any, seed: number): { ProcProps.Placement }
	local columns = if layout.id == "rw.home" then {} else Terrain.columns(layout, seed, 32)
	return ProcProps.plan(layout, columns, seed)
end

return {
	["every organic role and the home get biome-correct procedural props"] = function()
		local list = roles()
		assert(#list == 22, "harbor + 20 stages + home, got " .. #list)
		for _, layout in list do
			local placements = plan(layout, SEED)
			local floor = if layout.id == "rw.home" then MIN_HOME_PROPS else MIN_PROPS
			assert(#placements >= floor, layout.id .. " has only " .. #placements .. " procedural props")
			assert(#placements <= ProcProps.MAX_PER_ROLE, layout.id .. " exceeds the per-role cap")
			local allowed = ProcProps.allowed(layout)
			local keys: { [string]: boolean } = {}
			for _, item in placements do
				assert(table.find(allowed, item.biome), layout.id .. " used off-biome set " .. item.biome)
				assert(table.find(ProcProps.SETS[item.biome], item.key), item.key .. " is not in " .. item.biome)
				local entry = (ProcAssets :: any)[item.key]
				assert(entry and entry.kind == "prop", item.key .. " is not a generated prop")
				keys[item.key] = true
			end
			local distinct = 0
			for _ in keys do
				distinct += 1
			end
			assert(distinct >= 3, layout.id .. " repeats one prop (" .. distinct .. " distinct)")
			-- The role's primary biome is represented (not only shore or camp fill).
			local primary = layout.biomes[1]
			if ProcProps.SETS[primary] and layout.id ~= "rw.home" then
				local found = false
				for _, item in placements do
					found = found or item.biome == primary
				end
				assert(found, layout.id .. " has no " .. primary .. " props")
			end
		end
	end,
	["every biome set has 2-4 distinct generated props"] = function()
		for name, set in ProcProps.SETS do
			assert(#set >= 2 and #set <= 4, name .. " set size")
			for _, key in set do
				assert((ProcAssets :: any)[key] and (ProcAssets :: any)[key].kind == "prop", key .. " missing")
			end
		end
	end,
	["procedural prop plan is deterministic and seed-dependent"] = function()
		local changed = false
		for _, layout in roles() do
			local a = serde.encode("json", plan(layout, SEED))
			assert(a == serde.encode("json", plan(layout, SEED)), layout.id .. " plan is not deterministic")
			changed = changed or a ~= serde.encode("json", plan(layout, SEED + 1))
		end
		assert(changed, "seed must drive the plan")
	end,
	["procedural props keep clear of objectives paths spawns and nodes"] = function()
		for _, layout in roles() do
			local home = layout.id == "rw.home"
			for _, item in plan(layout, SEED) do
				local p = item.position
				if not home then
					assert(not Terrain.protected(layout, p.x, p.z, ProcProps.MARGIN), layout.id .. " blocks navigation")
				end
				local radius = if home then ProcProps.HOME_CLEARANCE else ProcProps.NODE_CLEARANCE
				for _, node in layout.resourceNodes do
					assert(
						(p.x - node.position.x) ^ 2 + (p.z - node.position.z) ^ 2 >= radius ^ 2,
						layout.id .. " prop inside node " .. node.id
					)
				end
				for _, anchor in layout.anchors do
					local r = if home then ProcProps.HOME_CLEARANCE elseif anchor.id == "objective" then 40 else 24
					assert(
						(p.x - anchor.position.x) ^ 2 + (p.z - anchor.position.z) ^ 2 >= r ^ 2,
						layout.id .. " prop inside anchor " .. anchor.id
					)
				end
				for _, path in layout.paths do
					for i = 2, #path.points do
						assert(
							Terrain.distance(p.x, p.z, path.points[i - 1], path.points[i]) >= path.width / 2,
							layout.id .. " prop on path " .. path.id
						)
					end
				end
				if home then
					assert(math.sqrt(p.x ^ 2 + p.z ^ 2) >= 24, "tall prop inside camp radius")
				end
			end
			-- Negative mutation: the predicate rejects an objective-centred prop.
			for _, anchor in layout.anchors do
				if anchor.id == "objective" then
					assert(not ProcProps.clear(layout, anchor.position.x, anchor.position.z), "objective clearance")
				end
			end
		end
	end,
	["low profile caps procedural prop builds and high stays within the role cap"] = function()
		local low, high = RenderBudget.profiles.low, RenderBudget.profiles.high
		for _, layout in roles() do
			local placements = plan(layout, SEED)
			local lowKept = ProcProps.limit(placements, low)
			assert(#lowKept == math.min(#placements, low.meshBuildsMax), layout.id .. " low cap")
			assert(#lowKept <= 2, "low profile builds at most two props")
			assert(#ProcProps.limit(placements, high) <= ProcProps.MAX_PER_ROLE, layout.id .. " high cap")
			for index, item in lowKept do
				assert(item == placements[index], "low keeps the nearest-first prefix")
			end
		end
	end,
}
