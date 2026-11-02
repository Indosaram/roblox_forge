--!strict
local Journey = require("./Journey.fixture")

return {
	["capture token and Show me find wildlife nested under the role world"] = function()
		local host = Journey.new({ locale = "en-us" })
		host.enter("rw.onboarding", { x = 0, y = 5, z = 72 })
		local h = host.render()
		local id = "rw.onboarding.dodo.01.1"
		local model = assert(h.creatures[id], "real onboarding spawn replicated")
		local root = model:FindFirstChild("HumanoidRootPart")
		h.player.Character.HumanoidRootPart.Position = root.Position
		model:SetAttribute("ForgeWildlifeHealthMilli", 5000)
		local snapshot = host.session.snapshot(Journey.ACTOR).survivalExtensions
		assert(snapshot.taming and #snapshot.taming.tameable > 0, "tameable snapshot")
		h.publish(snapshot)
		assert(h.workspace:FindFirstChild("ForgeWildlife", true), "nested folder")
		assert(
			h.load("genres/survival-coop/module/PetRing")
				.downed(require("./src/shared/SurvivalContent"), { dodo = true }, "dodo", 5000),
			"downed"
		)
		assert(
			h.petRing.capturable(),
			"the Capture token finds the downed nested dodo; " .. table.concat(h.errors, ";")
		)
		h.panels.open("taming")
		local go = h.playerGui:FindFirstChild("NextStepGo", true)
		assert(go, "starter Show me affordance")
		h.click(go)
		assert(model:FindFirstChild("ForgeTameGuide"), "Show me marks the nested starter creature")
		host.factory.close()
	end,
}
