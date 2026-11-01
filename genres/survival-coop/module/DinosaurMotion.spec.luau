--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local environment = {
	Instance = roblox.Instance,
	Vector3 = roblox.Vector3,
	CFrame = roblox.CFrame,
	Color3 = roblox.Color3,
	Enum = roblox.Enum,
}
return {
	["dinosaur poses follow physical speed confirmed health and strike with bounded cleanup"] = function()
		local rig =
			luau.load(fs.readFile("genres/survival-coop/module/DinosaurRig.luau"), { environment = environment })()
		local motion =
			luau.load(fs.readFile("genres/survival-coop/module/DinosaurMotion.luau"), { environment = environment })()
		local world = roblox.Instance.new("Workspace")
		for _, kind in { "hunter", "grazer" } do
			local model = rig.new(kind, kind, roblox.Vector3.zero, world)
			local root = model.PrimaryPart
			root.Position = root.CFrame.Position
			local state = { mode = "chase", healthMilli = 40000, strike = 0 }
			local rest = {}
			for _, joint in root:GetChildren() do
				rest[joint.Name] = joint.C0
			end
			local controller = motion.new(model, root, state, 0)
			controller.update(state, 100, roblox.Vector3.new(0, 8, 0))
			assert(root["Thigh1Joint"].C0 == rest.Thigh1Joint, "blocked or vertical movement is not walking")
			assert(root.TorsoJoint.C0 ~= rest.TorsoJoint, "idle breathing")
			controller.update(state, 200, roblox.Vector3.new(10, 0, 0))
			assert(root["Thigh1Joint"].C0 ~= rest.Thigh1Joint, "physical velocity drives stride")
			local pose = root.TorsoJoint.C0
			controller.update(state, 210, roblox.Vector3.zero)
			assert(root.TorsoJoint.C0 == pose, "20 Hz write budget")
			state.mode = "telegraph"
			controller.update(state, 300, roblox.Vector3.zero)
			assert(model:GetAttribute("ForgeWildlifeFeedback") == "telegraph", "warning follows state")
			assert(root.JawJoint.C0 ~= rest.JawJoint, "readable warning pose")
			state.mode, state.strike = "chase", 1
			controller.update(state, 400, roblox.Vector3.zero)
			assert(model:GetAttribute("ForgeWildlifeFeedback") == "strike", "strike attempt cue")
			state.healthMilli = 30000
			controller.update(state, 500, roblox.Vector3.zero)
			assert(model:GetAttribute("ForgeWildlifeFeedback") == "hurt", "confirmed health decrease")
			controller.update(state, 900, roblox.Vector3.zero)
			assert(model:GetAttribute("ForgeWildlifeFeedback") == nil, "duplicate state does not replay cues")
			state.healthMilli, state.mode = 0, "dead"
			controller.update(state, 1000, roblox.Vector3.zero)
			controller.update(state, 1500, roblox.Vector3.new(10, 0, 0))
			pose = root.TorsoJoint.C0
			controller.update(state, 1700, roblox.Vector3.new(10, 0, 0))
			assert(
				root.TorsoJoint.C0 == pose and model:GetAttribute("ForgeWildlifeFeedback") == "dead",
				"settled death overrides locomotion"
			)
			assert(
				root.Position == roblox.Vector3.zero and state.strike == 1,
				"presentation cannot move root or issue strikes"
			)
			controller.destroy()
			controller.destroy()
			controller.update(state, 1800, roblox.Vector3.zero)
			for _, joint in root:GetChildren() do
				assert(joint.C0 == rest[joint.Name], "rest pose restored")
			end
			assert(
				not model:FindFirstChild("WildlifeFeedback") and model:GetAttribute("ForgeWildlifeFeedback") == nil,
				"feedback disposed"
			)
		end
	end,
	-- D2 R07: an onboarding rig's coat tint (ForgeCoatTint) is the resting fill of its one feedback
	-- Highlight; a cue swaps it to the outline look and the coat returns afterwards.
	["a coat tint fills the rig at rest and yields to feedback cues"] = function()
		local rig =
			luau.load(fs.readFile("genres/survival-coop/module/DinosaurRig.luau"), { environment = environment })()
		local motion =
			luau.load(fs.readFile("genres/survival-coop/module/DinosaurMotion.luau"), { environment = environment })()
		local world = roblox.Instance.new("Workspace")
		local model = rig.new("grazer", "coat", roblox.Vector3.zero, world)
		local coat = roblox.Color3.fromRGB(240, 150, 50)
		model:SetAttribute("ForgeCoatTint", coat)
		local state = { mode = "idle", healthMilli = 40000, strike = 0 }
		local controller = motion.new(model, model.PrimaryPart, state, 0)
		local fill = model:FindFirstChild("WildlifeFeedback")
		assert(fill.Enabled and fill.FillColor == coat and fill.FillTransparency < 1, "coat shows at rest")
		state.healthMilli = 30000
		controller.update(state, 100, roblox.Vector3.zero)
		assert(fill.Enabled and fill.FillTransparency == 1, "a hurt cue shows the outline only")
		controller.update(state, 600, roblox.Vector3.zero)
		assert(fill.Enabled and fill.FillTransparency == motion.COAT_FILL, "the coat returns after the cue")
		controller.destroy()
		local plain = rig.new("grazer", "plain", roblox.Vector3.zero, world)
		motion.new(plain, plain.PrimaryPart, state, 0)
		assert(not plain:FindFirstChild("WildlifeFeedback").Enabled, "no coat, no resting fill")
	end,
}
