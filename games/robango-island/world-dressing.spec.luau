--!strict
local Content = require("./src/shared/SurvivalContent")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local Dressing = require("./src/server/WorldDressing")
local HomeWorld = require("./src/server/HomeWorld")
local HomeContent = require("../../core/domain/home/HomeContent")
local Home = require("../../core/domain/home/HomeState")
local serde = require("@lune/serde")

local function validate(layout: any, plan: any)
	assert(#plan.parts <= 768 and #plan.props <= 96, "world art budget")
	for _, prop in plan.props do
		assert(not Terrain.protected(layout, prop.position.x, prop.position.z, 16), "prop blocks navigation")
	end
end

return {
	["authored landmarks reach the production dressing plan"] = function()
		local count = 0
		for _, layout in Content.layouts :: any do
			if layout.art then
				count += 1
				local landmark = layout.art.landmark
				local plan = Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)
				local found = false
				for _, part in plan.parts do
					if part.id == landmark.id .. ".base" then
						found = true
						assert(
							part.position.x == landmark.position.x and part.position.z == landmark.position.z,
							"landmark position changed twice"
						)
						assert(
							part.size.x == landmark.size.x and part.size.z == landmark.size.z,
							"landmark footprint changed"
						)
					end
				end
				assert(found, "authored landmark omitted: " .. layout.id)
			end
		end
		assert(count == 20, "all authored expedition landmarks must ship")
	end,
	["volcano has luminous flows ash and hot spring effects"] = function()
		local lava, ash, steam = false, false, false
		for _, layout in Content.layouts :: any do
			local plan = Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)
			for _, part in plan.parts do
				lava = lava or (part.effect == "lava" and part.material == "Neon")
				ash = ash or part.effect == "ash"
				steam = steam or part.effect == "steam"
			end
		end
		assert(lava and ash and steam, "volcanic effects missing")
	end,
	["home camp includes crops storage fire and path without repeated awnings"] = function()
		local rules = HomeContent.rules(Content)
		local parts = HomeWorld.plan(Content, Home.new("owner", rules, 79), rules)
		local ids = {}
		for _, part in parts do
			ids[part.id] = true
			assert(not string.find(part.id, ".awning", 1, true), "duplicated starter shelters")
		end
		assert(
			ids["home.fire.embers"] and ids["home.farm.soil"] and ids["home.storage.body"] and ids["home.path"],
			"home camp components missing"
		)
	end,
	["world dressing is deterministic budgeted and preserves catalog clearance for every role"] = function()
		for _, layout in Content.layouts :: any do
			local columns = Terrain.columns(layout, 79, 32)
			local plan = Dressing.plan(layout, columns, Terrain)
			validate(layout, plan)
			assert(
				serde.encode("json", plan)
					== serde.encode("json", Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)),
				layout.id
			)
			local wet, dry = false, false
			for _, column in columns do
				wet = wet or column.top < -4
				dry = dry or column.top > 0
			end
			if string.match(layout.id, "^rw%.a%d+%.s%d+$") then
				assert(wet and dry, "archipelago must have shore and dry land: " .. layout.id)
			end
		end
	end,
	["world dressing negative mutation rejects props inside objective and over budget"] = function()
		local layout: any = (Content.layouts :: any)[1]
		local p = layout.anchors[1].position
		local plan: any = { parts = {}, props = { { position = p } } }
		assert(not pcall(validate, layout, plan), "clearance mutation must fail")
		plan.props = {}
		for i = 1, 769 do
			plan.parts[i] = {}
		end
		assert(not pcall(validate, layout, plan), "part budget mutation must fail")
		assert(not pcall(Terrain.columns, layout, 79, 0), "zero cell must fail instead of looping")
	end,
	["home art expands fenced shelter without replacing durable land"] = function()
		local rules = HomeContent.rules(Content)
		local home = Home.new("owner", rules, 79)
		for _, rank in { 1, 5 } do
			home.landRank = rank
			local parts = HomeWorld.plan(Content, home, rules)
			local shelter, fence = false, false
			for _, part in parts do
				shelter = shelter or part.id == "home.shelter.bedroll"
				fence = fence or string.find(part.id, "home.fence.", 1, true) ~= nil
			end
			assert(shelter and fence and parts[1].size.x == rules.landSizes[rank], "home visual rank projection")
		end
	end,
}
