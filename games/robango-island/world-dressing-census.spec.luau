--!strict
-- L2 primitive census (asset-audit G10): on every layout the WorldDressing plan emits no visible
-- primitive dressing. A plan part counts as meshed only when it belongs to a kit whose kind has a
-- B3 row (StructureMeshes.DRESSING); every other plan part is a primitive the player would see.
-- The B1 biome kits (BiomeKits.plan) carry the vegetation instead: each role's spawn screen keeps
-- at least MIN_VEG mesh vegetation placements.
local Content = require("./src/shared/SurvivalContent")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local Dressing = require("./src/server/WorldDressing")
local Meshes = require("./src/server/StructureMeshes")
local BiomeKits = require("./src/shared/BiomeKits")

-- One default-zoom landscape phone screen (BiomeKits.SCREEN_AREA, 220 x 100 studs) around a spawn.
local HALF_LONG, HALF_SHORT = 110, 50
local MIN_VEG = 20
local SEED = 79

local function columnsFor(layout: any, seed: number): { any }
	return if layout.id == "rw.home"
		then {}
		else Terrain.columns(layout, seed, if layout.id == "rw.onboarding" then 16 else 32)
end

--- Primitive dressing parts of one plan: kind -> count, and the total.
local function census(plan: any): ({ [string]: number }, number)
	local kinds: { [string]: number } = {}
	local total = 0
	for _, part in plan.parts do
		if part.kit and Meshes.DRESSING[part.kitKind] then
			continue
		end
		local kind = part.kitKind or part.id
		kinds[kind] = (kinds[kind] or 0) + 1
		total += 1
	end
	return kinds, total
end

local function describe(kinds: { [string]: number }): string
	local list = {}
	for kind, n in kinds do
		table.insert(list, kind .. "=" .. n)
	end
	table.sort(list)
	return table.concat(list, ",")
end

return {
	["every layout's dressing plan emits zero primitive dressing parts"] = function()
		local failures = {}
		for _, layout in Content.layouts :: any do
			local kinds, total = census(Dressing.plan(layout, columnsFor(layout, SEED), Terrain))
			if total > 0 then
				table.insert(failures, layout.id .. " " .. total .. " (" .. describe(kinds) .. ")")
			end
		end
		assert(#failures == 0, "primitive dressing:\n" .. table.concat(failures, "\n"))
	end,
	["every kit kind the plan or the home camp emits has a B3 row or is a B1 kit placement"] = function()
		local rows: { [string]: boolean } = {}
		for _, layout in Content.layouts :: any do
			for _, part in Dressing.plan(layout, columnsFor(layout, SEED), Terrain).parts do
				assert(part.kit, layout.id .. " loose primitive " .. part.id)
				assert(Meshes.DRESSING[part.kitKind], layout.id .. " kit kind without a row: " .. part.kitKind)
				rows[Meshes.DRESSING[part.kitKind]] = true
			end
		end
		assert(rows["bld.tent"] and rows["town.road-sign"], "camp and wayfinding rows in use")
	end,
	["B1 kit rows replace the scatter: >= 20 mesh vegetation on every spawn screen"] = function()
		local failures = {}
		for _, layout in Content.layouts :: any do
			if layout.id == "rw.home" then
				continue
			end
			local columns = columnsFor(layout, SEED)
			local placements = table.clone(BiomeKits.plan(layout, columns, SEED, Terrain))
			-- The dressing plan's own B1 rows (spawn grove, landmarks) render through the same kits.
			for _, p in Dressing.plan(layout, columns, Terrain).kits do
				table.insert(placements, p)
			end
			for _, at in BiomeKits.arrivals(layout) do
				local best = 0
				for _, box in { { HALF_LONG, HALF_SHORT }, { HALF_SHORT, HALF_LONG } } do
					local n = 0
					for _, p in placements do
						if
							p.family ~= "rock"
							and p.family ~= "clutter"
							and math.abs(p.x - at.x) <= box[1]
							and math.abs(p.z - at.z) <= box[2]
						then
							n += 1
						end
					end
					best = math.max(best, n)
				end
				if best < MIN_VEG then
					table.insert(failures, string.format("%s (%d,%d) %d", layout.id, at.x, at.z, best))
				end
			end
		end
		assert(
			#failures == 0,
			"spawn screens under " .. MIN_VEG .. " mesh vegetation:\n" .. table.concat(failures, "\n")
		)
	end,
	["NEGATIVE: a primitive scatter kit is counted"] = function()
		local layout: any = (Content.layouts :: any)[1]
		local plan = Dressing.plan(layout, columnsFor(layout, SEED), Terrain)
		Dressing.kit(plan.parts, "biome.mutant", { x = 0, y = 0, z = 0 }, "palm", Dressing.palette(layout))
		local kinds, total = census(plan)
		assert(total > 0 and (kinds.palm or 0) > 0, "a primitive palm must be counted")
	end,
}
