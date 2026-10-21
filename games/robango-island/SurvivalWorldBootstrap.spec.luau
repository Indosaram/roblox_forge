--!strict
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Gathering = require("../../genres/survival-coop/module/Gathering")
local Policy = require("./src/shared/WildlifePolicy")
local Taming = require("./src/shared/TamingConfig")

return {
	["onboarding census has five species safe tameable herbivores and edge predators"] = function()
		local engine = Engine.new(true)
		local world = engine.preview(Content, Source, Policy, function()
			return 0
		end, "onboarding", true)
		local species, safe, predators = {}, false, 0
		local details = {}
		for _, detail in Content.wildlifeDetails do
			details[detail.id] = detail
		end
		for _, spawn in world.roleWildlife.spawns do
			species[spawn.catalogId] = true
			local p = spawn.position
			local distance = math.sqrt((p.x + 6) ^ 2 + p.z ^ 2)
			local detail = assert(details[spawn.catalogId], "real species, not behavior stand-in")
			-- Grassland/forest/beach carry no catalog predator; the edge threat is the
			-- territorial boar, which attacks players who come close.
			if detail.behaviour == "predator" or detail.behaviour == "territorial" then
				predators += 1
				assert(distance >= 30, "threat outside camp")
			elseif
				table.find({ "dodo", "turtle", "protoceratops", "parasaurolophus", "triceratops" }, spawn.catalogId)
				and table.find(Taming.tameable, spawn.catalogId)
				and distance <= 40
			then
				safe = true
			end
		end
		local count = 0
		for _ in species do
			count += 1
		end
		assert(count >= 5 and safe and predators >= 1 and predators <= 2, "readable initial census")
		local crowns, tiers, fronds, rocks = 0, 0, 0, 0
		for _, part in engine.parts do
			if part.Name:find("Forest", 1, true) then
				assert(not part.CanQuery and not part.CanCollide, "foliage never blocks reach")
				if part.Name:find("canopy", 1, true) then
					if part:IsA("WedgePart") then
						tiers += 1
					else
						crowns += 1
					end
				elseif part.Name:find("frond", 1, true) then
					fronds += 1
				end
			elseif part.Name:find("flint-outcrop-01.cluster.rock", 1, true) then
				rocks += 1
			end
		end
		assert(crowns >= 4 and tiers >= 4 and fronds >= 6, "three forest archetypes")
		assert(rocks >= 3 and rocks <= 5, "faceted camp rock cluster")
		world.destroy()
	end,
	["onboarding gather prompts are enabled at walkable server reach points"] = function()
		local engine = Engine.new(true)
		local world = engine.preview(Content, Source, nil, nil, "onboarding", true)
		world.publishNodes(Gathering.new(Source.worldRevision, Content, Source.nodes))
		engine.move("1", { x = 0, y = 3, z = 0 })
		local client = engine.gatherClient("1", function()
			return { ok = true, durable = { actions = { "survival-coop:gather" }, sessionEpoch = 0 } }
		end)
		local count = 0
		for _, part in engine.parts do
			if part:GetAttribute("ForgeNodeId") then
				local prompt = part:FindFirstChild("ForgeGather")
				assert(prompt and prompt.Enabled, part.Name .. " enabled prompt")
				assert(prompt.Parent == part and part:IsA("BasePart"), "node owns prompt directly")
				assert(not prompt.RequiresLineOfSight, "dressing cannot hide prompt")
				local walkable = { x = part.Position.X + 3, y = 3, z = part.Position.Z }
				local distance = math.sqrt(9 + (part.Position.Y - walkable.y) ^ 2)
				assert(distance <= prompt.MaxActivationDistance, "walkable clearing is within prompt reach")
				engine.move("1", walkable)
				count += 1
			end
		end
		assert(count == #Source.nodes, "every onboarding node checked")
		local warehouse
		for _, part in engine.parts do
			if part.Name == "Warehouse" then
				warehouse = part
			end
		end
		assert(warehouse and warehouse:FindFirstChild("ForgeWarehouse").Enabled, "warehouse interaction exists")
		client.destroy()
		world.destroy()
	end,
}
