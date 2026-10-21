--!strict
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Gathering = require("../../genres/survival-coop/module/Gathering")

return {
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
