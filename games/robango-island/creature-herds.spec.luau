--!strict
-- B2a herds and arrival creatures built by RoleWorld (production-worlds engine fixture).
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")

-- The wildlife config the role world handed SurvivalWorld (spawns, herds, maximum).
local function build(layoutId: string, seed: number): any
	local engine = Engine.new()
	local world = engine.role.build(Content, Source, Policy, function()
		return 0
	end, layoutId, seed)
	return world.roleWildlife, engine
end

local function layout(id: string): any
	for _, candidate in Content.layouts do
		if candidate.id == id then
			return candidate
		end
	end
	error("layout " .. id)
end

return {
	["grazer spawns become seeded herds of 3-5 that reach the wildlife world"] = function()
		for _, layoutId in { "rw.onboarding", "rw.explore20", "rw.a1.s2" } do
			local config = build(layoutId, 79)
			local again = build(layoutId, 79)
			local other = build(layoutId, 80)
			local authored = layout(layoutId)
			local expected = 0
			for _, spawn in authored.spawns do
				if spawn.count > 1 then
					expected += 1
				end
			end
			assert(expected > 0 and #config.herds == expected, layoutId .. " one herd per grouped spawn")
			local byId: { [string]: any } = {}
			for _, spawn in config.spawns do
				byId[spawn.id] = spawn
			end
			for index, herd in config.herds do
				local size = 1 + #herd.members
				assert(size >= 3 and size <= 5, layoutId .. " herd of 3-5: " .. herd.id)
				local leader = byId[herd.leader]
				assert(leader and string.sub(herd.leader, -2) == ".1", "leader is the first member")
				for _, member in herd.members do
					local spawn = assert(byId[member], "member registered as wildlife")
					assert(spawn.catalogId == leader.catalogId, "one species per herd")
					local d = math.sqrt(
						(spawn.position.x - leader.position.x) ^ 2 + (spawn.position.z - leader.position.z) ^ 2
					)
					assert(d > 1 and d <= 8, "member spread inside the spawn radius")
				end
				assert(again.herds[index].leader == herd.leader, "same seed, same herd")
			end
			local moved = false
			for index, spawn in config.spawns do
				local twin = other.spawns[index]
				assert(twin.id == spawn.id, "ids do not depend on the seed")
				moved = moved or twin.position.x ~= spawn.position.x
			end
			assert(moved, layoutId .. " herd layout follows the recorded seed")
			assert(#config.spawns <= config.maximum and config.maximum <= 32, "wildlife budget")
		end
	end,
	["onboarding and explore islands show a creature near the arrival point"] = function()
		for _, layoutId in { "rw.onboarding", "rw.explore10", "rw.explore20" } do
			local _, engine = build(layoutId, 79)
			local entry = layout(layoutId).anchors[1].position
			local nearest = math.huge
			for _, model in engine.game:GetService("Workspace"):GetDescendants() do
				if model:IsA("Model") and model:GetAttribute("Species") and model.PrimaryPart then
					local p = model:GetPivot().Position
					nearest = math.min(nearest, math.sqrt((p.X - entry.x) ^ 2 + (p.Z - entry.z) ^ 2))
				end
			end
			-- Inside the default-zoom camera view of a player standing at the arrival point.
			assert(nearest <= 120, layoutId .. " nearest creature " .. nearest .. " studs from arrival")
		end
	end,
}
