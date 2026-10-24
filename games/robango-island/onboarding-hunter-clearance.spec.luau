--!strict
-- p81: a new player doing the day-1 guides on the onboarding island (live rw.onboarding role and
-- the Studio onboarding preview) never stands where a hunter can reach them. A hunter only
-- engages an actor within its leash of its home (Wildlife.decide disengages beyond leashStuds)
-- and strikes from attackStuds, so every day-1 interaction point must lie further than
-- leashStuds + attackStuds from every hunter home, and never closer than MIN_CLEARANCE studs.
-- Grazers flee and never strike, so they may stay near camp.
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Archetype = require("../../core/domain/survival/Archetype")

local MIN_CLEARANCE = 40

type Point = { id: string, x: number, z: number }

-- Hostile species and the radius around their home inside which they can strike a player.
local function threats(): { [string]: number }
	local reach: { [string]: number } = {}
	for _, definition in Content.wildlife do
		if Archetype.engine(definition.behavior) == "hunter" then
			reach[definition.id] = math.max(MIN_CLEARANCE, definition.leashStuds + definition.attackStuds)
		end
	end
	return reach
end

local function partPoints(engine: any, points: { Point })
	for _, part in engine.parts do
		if part.Name == "Warehouse" or part.Name == "SurvivalSpawn" then
			table.insert(points, { id = part.Name, x = part.Position.X, z = part.Position.Z })
		end
	end
	for _, part in engine.game:GetService("CollectionService"):GetTagged("ForgeSurvivalStation") do
		table.insert(points, { id = part.Name, x = part.Position.X, z = part.Position.Z })
	end
end

local function violations(label: string, spawns: { any }, points: { Point }, errors: { string }): number
	local reach = threats()
	local hostile = 0
	for _, spawn in spawns do
		local radius = reach[spawn.catalogId or spawn.speciesId]
		if not radius then
			continue
		end
		hostile += 1
		local nearest, at = math.huge, "?"
		for _, point in points do
			local d = math.sqrt((spawn.position.x - point.x) ^ 2 + (spawn.position.z - point.z) ^ 2)
			if d < nearest then
				nearest, at = d, point.id
			end
		end
		if nearest < radius then
			table.insert(
				errors,
				string.format("%s %s is %.1f studs from %s (needs %d)", label, spawn.id, nearest, at, radius)
			)
		end
	end
	return hostile
end

return {
	["p81 onboarding hunters stay clear of every day-1 interaction point"] = function()
		local errors: { string } = {}
		local clock = function()
			return 0
		end
		-- Studio onboarding preview: projected rw.onboarding spawns over the development island.
		local preview = Engine.new(nil, true)
		local world = preview.preview(Content, Source, Policy, clock, "onboarding", true)
		local points: { Point } = {
			{ id = "Campfire", x = -6, z = 0 },
			{ id = "Workbench", x = 6, z = 0 },
			{ id = "CampOrigin", x = Source.tribe.origin.x, z = Source.tribe.origin.z },
		}
		for _, node in Source.nodes do
			table.insert(points, { id = node.id, x = node.position.x, z = node.position.z })
		end
		partPoints(preview, points)
		local hostile = violations("preview", world.roleWildlife.spawns, points, errors)
		assert(hostile >= 1, "preview keeps an edge threat")
		world.destroy()
		-- Live onboarding role.
		local engine = Engine.new(nil, true)
		local live = engine.role.build(Content, Source, Policy, clock, "rw.onboarding", 1776)
		local layout = live.layout
		points = {}
		for _, node in layout.resourceNodes do
			table.insert(points, { id = node.id, x = node.position.x, z = node.position.z })
		end
		for _, anchor in layout.anchors do
			-- The hazard anchor is the island's danger corner, not a guide destination.
			if anchor.id ~= "hazard" then
				table.insert(points, { id = anchor.id, x = anchor.position.x, z = anchor.position.z })
			end
		end
		for id, target in live.journalTargets do
			table.insert(points, { id = id, x = target.position.x, z = target.position.z })
		end
		local tribe = live.roleSource.tribe
		table.insert(points, { id = "warehouse", x = tribe.warehousePosition.x, z = tribe.warehousePosition.z })
		table.insert(points, { id = "camp-origin", x = tribe.origin.x, z = tribe.origin.z })
		partPoints(engine, points)
		hostile += violations("rw.onboarding", layout.spawns, points, errors)
		assert(hostile >= 2, "both onboarding worlds checked hunters")
		assert(#errors == 0, table.concat(errors, "\n"))
	end,
}
