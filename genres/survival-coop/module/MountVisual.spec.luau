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
	["skinned seat sits the rider over the spine bone and keeps the mount feet on the ground"] = function()
		-- Ridge strider (gallimimus): 6-stud root, spine 3.5 studs up, rider root standing 3 studs up.
		local offset, lift = MountVisual.seat(6, 3.5, 3)
		local riderAboveFloor = 3.5 * (1 + MountVisual.BACK_PAD) + MountVisual.RIDER_ABOVE_BACK
		assert(math.abs(lift - (riderAboveFloor - 3)) < 1e-9, "lift raises the rider onto the back")
		assert(math.abs((3 + lift + offset - 3) - 0) < 1e-9, "mount floor stays on the ground")
		local lowOffset, lowLift = MountVisual.seat(1, 0.3, 3)
		assert(lowLift == 0 and math.abs(3 + lowOffset - 0.5) < 1e-9, "a low back never sinks the rider")
	end,
	["pet body follows its owner, holds on stay and is hidden while ridden"] = function()
		local companions = { deployed = "p", pets = { p = { id = "p", species = "gallimimus" } } }
		assert(MountVisual.pet({ companions = companions }) == "p|gallimimus", "deployed pet shows")
		companions.ride = "p"
		assert(MountVisual.pet({ companions = companions }) == nil, "ridden pet is the mount body")
		assert(MountVisual.pet(nil) == nil and MountVisual.pet({ companions = {} }) == nil, "none deployed")
		local near = { MountVisual.followGoal(0, 0, 0, -1, 2, 2, false) }
		assert(near[1] == nil, "inside slack stays put")
		local gx, gz, jump = MountVisual.followGoal(0, 0, 0, -1, 30, 0, false)
		assert(gx and gz and not jump and gz > 0, "walks behind the owner")
		local _, _, far = MountVisual.followGoal(0, 0, 0, -1, 500, 0, false)
		assert(far == true, "teleports when left far behind")
		assert(MountVisual.followGoal(0, 0, 0, -1, 30, 0, true) == nil, "stay holds its spot")
	end,
}
