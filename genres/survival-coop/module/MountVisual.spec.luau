--!strict
local roblox: any = require("@lune/roblox")
local MountVisual = require("./MountVisual")

return {
	["plan attaches new rides, detaches ended ones and swaps a changed species"] = function()
		local plan = MountVisual.plan(
			{ a = "strider", c = "trotter", d = "bounder" },
			{ a = "strider", b = "x", d = "y" }
		)
		assert(#plan.detach == 2 and plan.detach[1] == "b" and plan.detach[2] == "d", "detach ended and swapped")
		assert(#plan.attach == 2, "attach new and swapped")
		assert(plan.attach[1].actor == "c" and plan.attach[1].species == "trotter", "new ride")
		assert(plan.attach[2].actor == "d" and plan.attach[2].species == "bounder", "swapped ride")
		local idle = MountVisual.plan({ a = "strider" }, { a = "strider" })
		assert(#idle.detach == 0 and #idle.attach == 0, "steady state is a no-op")
		local gone = MountVisual.plan({}, { a = "strider" })
		assert(#gone.detach == 1 and #gone.attach == 0, "dismount/death/leave detaches")
	end,
	["species reads only an active server ride"] = function()
		assert(MountVisual.species(nil) == nil, "no taming")
		assert(MountVisual.species({ walkSpeedStuds = nil, ride = nil }) == nil, "not mounted")
		assert(MountVisual.species({ walkSpeedStuds = 28, ride = { species = "strider" } }) == "strider", "mounted")
		assert(MountVisual.species({ walkSpeedStuds = 28, ride = { species = "" } }) == nil, "blank species")
	end,
	["dress makes the rig physics-inert and never shadows the rider root"] = function()
		local model = roblox.Instance.new("Model")
		local root = roblox.Instance.new("Part")
		root.Name, root.CanCollide, root.Parent = "HumanoidRootPart", true, model
		local limb = roblox.Instance.new("Part")
		limb.Name, limb.Anchored, limb.Parent = "Torso", true, model
		roblox.Instance.new("Humanoid").Parent = model
		MountVisual.dress(model)
		assert(model.Name == MountVisual.MODEL_NAME, "named")
		assert(model:FindFirstChildOfClass("Humanoid") == nil, "no humanoid")
		assert(model:FindFirstChild("HumanoidRootPart") == nil and model:FindFirstChild("MountRoot"), "root renamed")
		for _, part in { root, limb } do
			assert(not part.CanCollide and not part.CanQuery and not part.CanTouch, "no collision/query")
			assert(part.Massless and not part.Anchored, "massless and welded-ready")
		end
	end,
}
