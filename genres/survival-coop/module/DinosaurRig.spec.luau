--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local function loadRig(source: string?): any
	return luau.load(source or fs.readFile("genres/survival-coop/module/DinosaurRig.luau"), {
		environment = {
			Instance = roblox.Instance,
			Vector3 = roblox.Vector3,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			Enum = roblox.Enum,
		},
	})()
end
-- Rounded anatomy is a block carrying a Sphere SpecialMesh (a Ball part is always a sphere of
-- its smallest axis, so it cannot render an ellipsoid).
local function rounded(p: any): boolean
	local mesh = p:FindFirstChildOfClass("SpecialMesh")
	return mesh ~= nil and mesh.MeshType == roblox.Enum.MeshType.Sphere
end
local envelopes: { [string]: { number } } = {
	compsognathus = { 1, 1.5, 3 },
	oviraptor = { 1.5, 3, 3 },
	protoceratops = { 2.5, 3, 4 },
	gallimimus = { 2, 6, 5 },
	parasaurolophus = { 3, 7, 7 },
	stegosaurus = { 5, 6, 9 },
	ankylosaurus = { 4, 4, 7 },
	triceratops = { 5, 5, 8 },
	brachiosaurus = { 8, 24, 18 },
	utahraptor = { 3, 6, 6 },
	velociraptor = { 2, 4, 4 },
	dilophosaurus = { 3, 6, 6 },
	allosaurus = { 5, 9, 12 },
	tyrannosaurus = { 7, 12, 16 },
	smilodon = { 3, 4, 5 },
	tropicalSmilodon = { 2.5, 3.5, 5 },
	direWolf = { 2.5, 3.5, 5 },
	mammoth = { 7, 10, 12 },
	boar = { 2.5, 3, 4 },
	deer = { 2, 5, 4 },
	elephant = { 6, 9, 10 },
	crocodile = { 3, 2, 7 },
	turtle = { 1.5, 1, 2 },
	dodo = { 1.5, 2, 2 },
}
local function verifyAnatomy(module: any)
	local world = roblox.Instance.new("Workspace")
	local signatures = {}
	for species, dims in envelopes do
		local model = module.new(species, species, roblox.Vector3.zero, world)
		local root = model.PrimaryPart
		assert(root.Size == roblox.Vector3.new(dims[1], dims[2], dims[3]), "catalog envelope: " .. species)
		local signature = {}
		local count = 0
		for _, p in model:GetChildren() do
			if p:IsA("BasePart") then
				count += 1
				table.insert(signature, p.Name .. tostring(p.Size) .. tostring(p.CFrame))
				if p ~= root then
					assert(not p.CanCollide and p.Massless, "visual parts never collide")
					local j = root:FindFirstChild(p.Name .. "Joint")
					assert(j and j.Part1 == p and j.Part0.Parent == model, "all parts articulated")
					local a, b = j.Part0.CFrame * j.C0, j.Part1.CFrame * j.C1
					assert((a.Position - b.Position).Magnitude < 0.0001, "rest pivots coincide")
				end
			end
		end
		table.sort(signature)
		local key = table.concat(signature, ";")
		assert(not signatures[key], "geometry, not metadata, differs: " .. species)
		signatures[key] = true
		assert(count == model:GetAttribute("PartCount") and count <= 48, "actual part budget")
		local family = model:GetAttribute("BodyPlan")
		if family == "mammal" or family == "elephant" or family == "bird" or family == "turtle" then
			assert(not model:FindFirstChild("Tail1"), "no dinosaur tail: " .. species)
		end
		if family == "elephant" then
			assert(model:FindFirstChild("Trunk3") and model:FindFirstChild("TuskTip1"), "trunk and curled tusks")
		elseif family == "ceratopsian" then
			assert(model:FindFirstChild("Frill"), "frilled skull")
		elseif family == "sauropod" then
			assert(model.Head.CFrame.Position.Y > root.Size.Y * 0.4, "upright long neck")
		elseif family == "crocodilian" then
			assert(model.Head.Size.Y < model.Head.Size.Z * 0.2, "flat crocodile muzzle")
		elseif family == "turtle" then
			assert(model:FindFirstChild("Shell"), "turtle carapace")
		elseif family == "bird" then
			assert(model:FindFirstChild("HookBeak") and model:FindFirstChild("Wing1"), "dodo anatomy")
		end
		model:Destroy()
	end
	world:Destroy()
end
local function verifyPoses(module: any)
	local world = roblox.Instance.new("Workspace")
	for species in envelopes do
		local model = module.new(species, species, roblox.Vector3.zero, world)
		local root = model.PrimaryPart
		local seen = {}
		for _, state in { "idle", "walk", "run", "attack", "hurt", "death", "ridden" } do
			local transforms = {}
			module.pose(model, state, 0.1, 18)
			for _, j in root:GetChildren() do
				if j:IsA("Motor6D") then
					table.insert(transforms, j.Name .. tostring(j.Transform))
				end
			end
			table.sort(transforms)
			local key = table.concat(transforms, ";")
			assert(not seen[key], "distinct pose: " .. species .. "/" .. state)
			seen[key] = true
		end
		module.pose(model, "idle", 0.1, 18)
		local idle = root.TorsoJoint.Transform
		module.pose(model, "attack", 0.1, 18)
		assert(
			(root.TorsoJoint.Transform.Position - idle.Position).Magnitude > root.Size.Z * 0.01,
			"attack has readable body displacement"
		)
		module.pose(model, "idle", 0.1, 18)
		assert(root.TorsoJoint.Transform == idle, "state reset and deterministic clock")
		model:Destroy()
	end
	world:Destroy()
end
return {
	["onboarding species have defining anatomy within bounded part counts"] = function()
		local module = loadRig()
		local world = roblox.Instance.new("Workspace")
		local features: { [string]: { string } } = {
			dodo = { "HookBeak", "BeakHook", "TailFan", "Wing1", "Neck" },
			turtle = { "Shell", "Scute0", "Scute-1", "Scute1", "SideScute-1", "SideScute1" },
			protoceratops = { "Frill", "FrillLobe1", "Beak", "BeakHook" },
			parasaurolophus = { "BackwardCrest", "CrestTip", "DuckBill" },
			triceratops = { "Frill", "FrillLobe1", "Horn-1", "Horn1", "NoseHorn", "Beak" },
			boar = { "Tusk-1", "Tusk1", "Dorsal1", "Dorsal5", "Ear1" },
		}
		for species, names in features do
			local model = module.new(species, species, roblox.Vector3.zero, world)
			local count = 0
			for _, p in model:GetChildren() do
				if p:IsA("BasePart") then
					count += 1
				end
			end
			assert(count <= 48 and count == model:GetAttribute("PartCount"), species .. " part budget")
			for _, name in names do
				assert(model:FindFirstChild(name), species .. " defining feature: " .. name)
			end
			assert(model.Countershade.Color.R > model.Torso.Color.R, "lighter belly")
			if species == "turtle" then
				assert(rounded(model.Shell), "domed shell")
				assert(
					model.Shell.Size.X > model.Torso.Size.X and model.Shell.Size.Z > model.Torso.Size.Z,
					"shell covers torso"
				)
			elseif species == "parasaurolophus" then
				assert(
					model.CrestTip.CFrame.Position.Y > model.Head.CFrame.Position.Y
						and model.CrestTip.CFrame.Position.Z > model.Head.CFrame.Position.Z,
					"backward rising crest"
				)
			elseif species == "dodo" then
				assert(
					model.BeakHook.CFrame.Position.Y < model.HookBeak.CFrame.Position.Y
						and model.BeakHook.CFrame.Position.Z < model.HookBeak.CFrame.Position.Z,
					"downturned beak"
				)
			elseif species == "boar" then
				assert(not model:FindFirstChild("Horn1"), "tusks not brow horns")
			end
			model:Destroy()
		end
		world:Destroy()
	end,
	["all body families avoid balloon cores and use rounded tapered limbs"] = function()
		local world = roblox.Instance.new("Workspace")
		local module = loadRig()
		for species, dims in envelopes do
			local model = module.new(species, species, roblox.Vector3.zero, world)
			for _, p in model:GetChildren() do
				if p:IsA("Part") and p ~= model.PrimaryPart and p.Name ~= "Head" then
					if
						rounded(p)
						and not p.Name:match("^Thigh")
						and not p.Name:match("^Foreleg")
						and not p.Name:match("^ForeShin")
						and not p.Name:match("^Arm")
						and not p.Name:match("^Shin")
						and p.Name ~= "Shell"
					then
						assert(
							math.max(p.Size.X, p.Size.Y, p.Size.Z) <= dims[3] * 0.4,
							"balloon: " .. species .. "/" .. p.Name
						)
					end
					if p.Name:match("^Thigh") or p.Name:match("^Foreleg") then
						assert(rounded(p), "rounded limb")
						local shin = model[if p.Name:match("^Thigh")
							then p.Name:gsub("Thigh", "Shin")
							else p.Name:gsub("Foreleg", "ForeShin")]
						assert(p.Size.Y > shin.Size.Y, "thigh wider than shin")
					end
				end
			end
			model:Destroy()
		end
		world:Destroy()
	end,
	["skin luminance feet contact and curved frill reject black disconnected primitives"] = function()
		local world = roblox.Instance.new("Workspace")
		local module = loadRig()
		local function linear(c: number): number
			return if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
		end
		for species in envelopes do
			local model = module.new(species, species, roblox.Vector3.zero, world)
			for _, p in model:GetChildren() do
				if not p:IsA("BasePart") or p == model.PrimaryPart then
					continue
				end
				if not string.find(p.Name, "Eye") and not string.find(p.Name, "Pupil") then
					local c = p.Color
					assert(
						0.2126 * linear(c.R) + 0.7152 * linear(c.G) + 0.0722 * linear(c.B) >= 0.08,
						"skin luminance: " .. species .. "/" .. p.Name
					)
				end
				if string.match(p.Name, "^Foot") or string.match(p.Name, "^Forefoot") then
					assert(rounded(p), "elliptical foot, never block")
					local joint = model.PrimaryPart[p.Name .. "Joint"]
					local shin = joint.Part0
					local extent = shin.Size.X
					local gap = math.abs(p.CFrame.Position.Y + p.Size.Y / 2 - (shin.CFrame.Position.Y - extent / 2))
					assert(gap < 0.05, "foot touches shin: " .. species .. "/" .. p.Name)
					assert(p.Color == model.Torso.Color and p.Size.Y < p.Size.Z, "flattened skin foot")
				end
			end
			if model:GetAttribute("BodyPlan") == "ceratopsian" then
				assert(model.Frill:IsA("Part") and rounded(model.Frill), "curved frill")
				assert(
					model:FindFirstChild("FrillLobe1") and model:FindFirstChild("FrillFace0"),
					"fan lobes and inset rim"
				)
			end
			model:Destroy()
		end
		world:Destroy()
	end,
	["neck and tail cores overlap continuously with feet on the envelope floor"] = function()
		local module = loadRig()
		local world = roblox.Instance.new("Workspace")
		for _, species in { "brachiosaurus", "tyrannosaurus", "triceratops", "stegosaurus", "velociraptor" } do
			local model = module.new(species, species, roblox.Vector3.zero, world)
			for _, chain in
				{ { name = "Neck", count = if species == "brachiosaurus" then 6 else 0 }, { name = "Tail", count = 4 } }
			do
				for i = 2, chain.count do
					local a, b = model[chain.name .. (i - 1)], model[chain.name .. i]
					assert(rounded(a) and b.Size.Y < a.Size.Y, "rounded continuous taper")
					local gap = (a.CFrame.Position - b.CFrame.Position).Magnitude - (a.Size.X + b.Size.X) / 2
					assert(gap < 0.1, "adjacent segment gap: " .. species)
				end
			end
			for _, side in { -1, 1 } do
				local foot = model["Foot" .. side]
				assert(
					math.abs(foot.CFrame.Position.Y - foot.Size.Y / 2 + model.PrimaryPart.Size.Y / 2) <= 0.5,
					"foot grounding"
				)
			end
			model:Destroy()
		end
		world:Destroy()
	end,
	["species skin has distinct pigments countershade markings and pupils"] = function()
		local module = loadRig()
		local world = roblox.Instance.new("Workspace")
		local colors = {}
		for species in envelopes do
			local model = module.new(species, species, roblox.Vector3.zero, world)
			local body = model.Torso
			assert(not colors[tostring(body.Color)], "species pigment must differ")
			colors[tostring(body.Color)] = true
			assert(
				body.Material
					== roblox.Enum.Material[if model:GetAttribute("BodyPlan") == "mammal"
							or model:GetAttribute("BodyPlan") == "elephant"
						then "Plastic"
						elseif model:GetAttribute("BodyPlan") == "bird" then "SmoothPlastic"
						elseif
							model:GetAttribute("BodyPlan") == "turtle"
							or model:GetAttribute("BodyPlan") == "armored"
						then "Slate"
						else "Leather"],
				"skin material by class (fur is plastic: fabric renders near black)"
			)
			assert(model.Pupil1.Material == roblox.Enum.Material.SmoothPlastic, "glossy eyes")
			assert(
				model.Countershade.Color ~= body.Color and model.FlankPattern1.Color ~= body.Color,
				"pattern contrast"
			)
			assert(model.Pupil1.Color ~= model.Eye1.Color, "readable pupil")
			model:Destroy()
		end
		world:Destroy()
	end,
	["tusks antlers jaw and armor stay attached to the head and back in idle and attack"] = function()
		local module = loadRig()
		local world = roblox.Instance.new("Workspace")
		local function bounds(p: any)
			local lo, hi = roblox.Vector3.one * math.huge, -roblox.Vector3.one * math.huge
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local z = if p:IsA("WedgePart") and sy == 1 then 1 else sz
						local v = p.CFrame:PointToWorldSpace(p.Size / 2 * roblox.Vector3.new(sx, sy, z))
						lo, hi = lo:Min(v), hi:Max(v)
					end
				end
			end
			return lo, hi
		end
		local function touches(a: any, b: any, slack: number): boolean
			local a0, a1 = bounds(a)
			local b0, b1 = bounds(b)
			for _, k in { "X", "Y", "Z" } do
				if a0[k] > b1[k] + slack or b0[k] > a1[k] + slack then
					return false
				end
			end
			return true
		end
		local attached: { [string]: { string } } = {
			mammoth = { "Tusk-1", "Tusk1", "TuskTip-1", "TuskTip1", "Jaw" },
			elephant = { "Tusk-1", "Tusk1", "TuskTip-1", "TuskTip1", "Jaw" },
			deer = { "Antler-1", "Antler1", "AntlerTip-1", "AntlerTip1", "Jaw" },
			compsognathus = { "Jaw", "TeethRow-1", "TeethRow1" },
			tyrannosaurus = { "Jaw", "TeethRow-1", "TeethRow1" },
			boar = { "Tusk-1", "Tusk1", "Jaw" },
		}
		for species, names in attached do
			local model = module.new(species, species, roblox.Vector3.zero, world)
			local root = model.PrimaryPart
			local tips = {}
			for _, state in { "idle", "attack" } do
				module.pose(model, state, 0.25, 0)
				local done = { [root] = true }
				local progress = true
				while progress do
					progress = false
					for _, j in root:GetChildren() do
						if j:IsA("Motor6D") and done[j.Part0] and not done[j.Part1] then
							j.Part1.CFrame = j.Part0.CFrame * j.C0 * j.Transform * j.C1:Inverse()
							done[j.Part1], progress = true, true
						end
					end
				end
				for _, name in names do
					local p = model[name]
					local parent = root[name .. "Joint"].Part0
					assert(
						(
							parent == model.Head
							or parent.Parent == model.Head.Parent
								and root[parent.Name .. "Joint"].Part0 == model.Head
						) and touches(p, parent, root.Size.Magnitude * 0.01),
						"detached from head: " .. species .. "/" .. state .. "/" .. name
					)
				end
				local tip = model.Head.CFrame:PointToObjectSpace(
					model.Jaw.CFrame:PointToWorldSpace(roblox.Vector3.new(0, 0, -model.Jaw.Size.Z / 2))
				)
				tips[state] = tip.Y
			end
			assert(tips.attack < tips.idle - model.Head.Size.Y * 0.1, "attack drops the jaw tip: " .. species)
			if species == "deer" then
				assert(model["Antler1"].Size.Y < root.Size.Y * 0.2, "antlers are not oversized blades")
			end
			model:Destroy()
		end
		local anky = module.new("ankylosaurus", "anky", roblox.Vector3.zero, world)
		local shell, torso = anky.Shell, anky.Torso
		-- A broad low dome over splayed legs: wider than the torso, never wider than the envelope.
		assert(
			shell.Size.X <= anky.PrimaryPart.Size.X and shell.Size.Y <= torso.Size.Y * 1.1,
			"armor sized to the back"
		)
		assert(shell.CFrame.Position.Y > torso.CFrame.Position.Y and touches(shell, torso, 0), "armor sits on the back")
		world:Destroy()
	end,
	["catalog body plans use exact clearance and real distinct geometry"] = function()
		verifyAnatomy(loadRig())
	end,
	["all species have distinct deterministic action poses"] = function()
		verifyPoses(loadRig())
	end,
	["unknown species and invalid envelope reject before creating a rig"] = function()
		local module = loadRig()
		local world = roblox.Instance.new("Workspace")
		assert(not pcall(module.new, "unknown", "bad", roblox.Vector3.zero, world), "unknown species rejected")
		assert(
			not pcall(module.new, "dodo", "bad", roblox.Vector3.zero, world, roblox.Vector3.new(-1, 2, 3)),
			"negative size rejected"
		)
		assert(#world:GetChildren() == 0, "invalid inputs leave no world instances")
		world:Destroy()
	end,
	["anatomy and pose regressions are mutation proved"] = function()
		local source = fs.readFile("genres/survival-coop/module/DinosaurRig.luau")
		local flattened, replacements =
			string.gsub(source, '\n\tif family == "sauropod" then', '\n\tif family == "never" then', 1)
		assert(replacements == 1 and not pcall(verifyAnatomy, loadRig(flattened)), "removed long neck must fail")
		local frozen, edits = string.gsub(
			source,
			'local attacking = state == "attack" or state == "strike"',
			"local attacking = false",
			1
		)
		assert(edits == 1 and not pcall(verifyPoses, loadRig(frozen)), "removed attack must fail")
	end,
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
			assert(root.HeadJoint.Part0.Name == (if kind == "grazer" then "Neck6" else "Neck"), "head follows neck")
			assert(
				root.JawJoint.Part0.Name == "Head" and root.Tail4Joint.Part0.Name == "Tail3",
				"articulated jaw and tail"
			)
		end
	end,
}
