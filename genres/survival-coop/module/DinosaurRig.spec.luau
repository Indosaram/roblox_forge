--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
return {
	["procedural dinosaur rigs have connected distinctive anatomy and collision root"] = function()
		local module = luau.load(fs.readFile("genres/survival-coop/module/DinosaurRig.luau"), {
			environment = {
				Instance = roblox.Instance,
				Vector3 = roblox.Vector3,
				CFrame = roblox.CFrame,
				Color3 = roblox.Color3,
				Enum = roblox.Enum,
			},
		})()
		local world = roblox.Instance.new("Workspace")
		for _, kind in { "grazer", "hunter" } do
			local model = module.new(kind, kind .. "-01", roblox.Vector3.new(0, 4, 0), world)
			local root = assert(model:FindFirstChild("HumanoidRootPart"), "root")
			assert(root.CanCollide and not root.Anchored, "dynamic collision body")
			assert(
				model:FindFirstChild("Head") and model:FindFirstChild("Jaw") and model:FindFirstChild("Tail4"),
				"head jaw and tapered tail"
			)
			assert((model:FindFirstChild("Neck3") ~= nil) == (kind == "grazer"), "long neck grazer silhouette")
			assert((model:FindFirstChild("Arm1") ~= nil) == (kind == "hunter"), "theropod forearms")
			local joints = 0
			for _, child in root:GetChildren() do
				if child:IsA("Motor6D") then
					assert(child.Part0.Parent == model and child.Part1.Parent == model, "connected anatomy")
					local pivot0, pivot1 = child.Part0.CFrame * child.C0, child.Part1.CFrame * child.C1
					assert((pivot0.Position - pivot1.Position).Magnitude < 0.0001, "rest pose retained")
					joints += 1
				end
			end
			assert(joints >= 20, "bounded multi-part anatomy")
			assert(root.HeadJoint.Part0.Name == (if kind == "grazer" then "Neck3" else "Neck"), "head follows neck")
			assert(
				root.JawJoint.Part0.Name == "Head" and root.Tail4Joint.Part0.Name == "Tail3",
				"articulated jaw and tail"
			)
		end
	end,
}
