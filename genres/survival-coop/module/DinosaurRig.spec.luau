--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
return {
	["every catalog species has bounded articulated geometry and sampled poses"] = function()
		local module = luau.load(fs.readFile("genres/survival-coop/module/DinosaurRig.luau"), {
			environment = {
				Instance = roblox.Instance,
				Vector3 = roblox.Vector3,
				CFrame = roblox.CFrame,
				Color3 = roblox.Color3,
				Enum = roblox.Enum,
			},
		})()
		local content = require("../../../games/robango-island/src/shared/SurvivalContent")
		local world = roblox.Instance.new("Workspace")
		local signatures: { [string]: boolean } = {}
		for _, species in assert(content.wildlifeDetails, "species catalog") do
			local model = module.new(species.id, species.id, roblox.Vector3.new(0, 4, 0), world)
			local feature = model:GetAttribute("Silhouette")
			assert(type(feature) == "string" and not signatures[feature], "distinct authored anatomy")
			signatures[feature] = true
			local count = 0
			for _, part in model:GetChildren() do
				if part:IsA("BasePart") then
					count += 1
				end
			end
			assert(count * 12 < 600, "far silhouette triangle budget")
			for _, pose in { "idle", "walk", "run", "attack", "hurt", "stun", "dead", "ridden", "rest" } do
				module.pose(model, pose, 0.1, 20)
			end
			module.pose(model, "walk", 0.1, 20)
			assert(model.PrimaryPart.Thigh1Joint.Transform ~= roblox.CFrame.identity, "sampled pose")
			model:Destroy()
		end
		local count = 0
		for _ in signatures do
			count += 1
		end
		assert(count == 24, "all catalog species")
	end,
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
