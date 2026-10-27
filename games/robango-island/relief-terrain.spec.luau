--!strict
-- A3 relief terrain (G8, G15): opted-in Robango islands use the seeded multi-octave height field.
-- Same recorded seed, same island; relief of at least 40 studs on explore islands; every authored
-- node, anchor and spawn on dry land outside cliffs and water; the generated coast-to-coast trail
-- takes at least 3 minutes at walk speed 16; legacy layouts keep the old generator.
local serde = require("@lune/serde")
local Content = require("./src/shared/SurvivalContent")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")

local SEED = 1776
local WALK = 16

local function relief(): { any }
	local out = {}
	for _, layout in Content.layouts do
		if Terrain.relief(layout) then
			table.insert(out, layout)
		end
	end
	return out
end

local function explore(layout: any): boolean
	return layout.id ~= "rw.onboarding"
end

return {
	["Robango explore and archipelago islands are 3072 square, onboarding 1024, all relief opted in"] = function()
		local count = 0
		for _, layout in Content.layouts do
			local id = layout.id
			local side = layout.bounds.max.x - layout.bounds.min.x
			local depth = layout.bounds.max.z - layout.bounds.min.z
			if
				string.match(id, "^rw%.a%d+%.s%d+$")
				or string.match(id, "^rw%.explore%d+$")
				or string.match(id, "^rw%.frontier%d+$")
			then
				assert(side == 3072 and depth == 3072, id .. " is " .. side .. "x" .. depth)
				assert(Terrain.relief(layout), id .. " opts in")
				count += 1
			elseif id == "rw.onboarding" then
				assert(side == 1024 and depth == 1024, "onboarding is " .. side .. "x" .. depth)
				assert(Terrain.relief(layout), "onboarding opts in")
			else
				assert(not Terrain.relief(layout), id .. " keeps the legacy generator")
			end
			if layout.terrain then
				assert(math.floor(layout.terrain.seed) == layout.terrain.seed, id .. " records an integer seed")
			end
		end
		assert(count == 26, "explore/archipelago layouts: " .. count)
	end,
	["the same recorded seed gives the same island and another seed a different one"] = function()
		for _, layout in relief() do
			local a = serde.encode("json", Terrain.columns(layout, SEED, 64))
			local b = serde.encode("json", Terrain.columns(layout, SEED, 64))
			assert(a == b, layout.id .. " is deterministic")
			local moved = table.clone(layout)
			moved.terrain = table.clone(layout.terrain)
			moved.terrain.seed += 1
			assert(a ~= serde.encode("json", Terrain.columns(moved, SEED, 64)), layout.id .. " island seed matters")
		end
	end,
	["explore islands have at least 40 studs of relief, cliffs, water and a dirt trail"] = function()
		for _, layout in relief() do
			if not explore(layout) then
				continue
			end
			local columns = Terrain.columns(layout, SEED, 32)
			local low, high, rock, mud, dirt = math.huge, -math.huge, 0, 0, 0
			for _, column in columns do
				if not column.beach then
					low, high = math.min(low, column.top), math.max(high, column.top)
				end
				rock += if column.material == "Rock" then 1 else 0
				mud += if column.wet then 1 else 0
				dirt += if column.material == "Ground" then 1 else 0
			end
			assert(high - low >= 40, string.format("%s relief %.1f", layout.id, high - low))
			assert(rock > 0, layout.id .. " has cliffs")
			assert(mud > 0, layout.id .. " has a pond or stream")
			assert(dirt > 0, layout.id .. " has a dirt trail")
		end
	end,
	["every node, anchor and spawn stands on dry land, never in a cliff or water"] = function()
		local failures = {}
		for _, layout in relief() do
			local field = Terrain.field(layout, SEED)
			for _, list in { layout.resourceNodes, layout.anchors, layout.spawns } do
				for _, item in list do
					local p = item.position
					local where = layout.id .. ":" .. item.id
					if field.coast.depth(p.x, p.z) <= 0 then
						table.insert(failures, where .. " offshore")
						continue
					end
					local y = field.height(p.x, p.z)
					if y <= Terrain.SEA then
						table.insert(failures, where .. " under the sea")
					end
					if field.water(p.x, p.z) then
						table.insert(failures, where .. " in water")
					end
					-- RoleWorld re-grounds nodes, stations and docks on this ground by ray; it stays
					-- within a step of the authored height so approach paths stay walkable.
					if math.abs(y - p.y) > 2.5 then
						table.insert(failures, string.format("%s ground %.1f vs authored %.1f", where, y, p.y))
					end
					for _, d in { { 6, 0 }, { -6, 0 }, { 0, 6 }, { 0, -6 } } do
						if math.abs(field.height(p.x + d[1], p.z + d[2]) - y) > 2.5 then
							table.insert(failures, where .. " beside a cliff")
							break
						end
					end
				end
			end
		end
		assert(#failures == 0, table.concat(failures, "\n"))
	end,
	["the coast-to-coast trail is walkable and takes at least 3 minutes at walk speed 16"] = function()
		for _, layout in relief() do
			if not explore(layout) then
				continue
			end
			local field = Terrain.field(layout, SEED)
			local trail = field.trails[1]
			local seconds = Terrain.length(trail) / WALK
			assert(seconds >= 180, string.format("%s crossing %.0f s", layout.id, seconds))
			assert(field.coast.depth(trail[1].x, trail[1].z) < 0.06, layout.id .. " trail starts at the coast")
			assert(field.coast.depth(trail[#trail].x, trail[#trail].z) < 0.06, layout.id .. " trail ends at the coast")
			-- Scripted walk: 2-stud steps on the generated ground never rise more than a step. Inside
			-- authored clearings the catalog geometry rules (walkable-paths.spec covers it).
			local previous: number? = nil
			for i = 2, #trail do
				local a, b = trail[i - 1], trail[i]
				local n = math.max(1, math.ceil(math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) / 2))
				for s = 0, n do
					local x, z = a.x + (b.x - a.x) * s / n, a.z + (b.z - a.z) * s / n
					local y = field.height(x, z)
					if previous and field.clear(x, z) > 72 then
						assert(
							y - previous <= 2.5,
							string.format("%s trail climbs %.1f at %.0f,%.0f", layout.id, y - previous, x, z)
						)
					end
					previous = y
				end
			end
		end
	end,
	["legacy layouts keep the old generator and a relief seed is only read when opted in"] = function()
		for _, layout in Content.layouts do
			if not Terrain.relief(layout) and layout.id ~= "rw.home" then
				assert(Terrain.surface(layout, SEED, 0, 0) == nil, layout.id .. " has no relief surface")
			end
		end
	end,
}
