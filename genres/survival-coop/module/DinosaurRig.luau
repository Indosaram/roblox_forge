--!strict
-- Original procedural silhouettes: long-neck quadruped and biped theropod.
-- Articulated low-poly anatomy is a rig mechanism, not a rendered quality verdict.
local M = {}
-- Authored geometry only; gameplay values remain in the content catalog.
-- Features alter anatomy rather than recoloring one fused creature mesh.
local silhouettes: { [string]: { kind: string, scale: number, feature: string } } = {
	compsognathus = { kind = "hunter", scale = 0.25, feature = "scuttle" },
	oviraptor = { kind = "hunter", scale = 0.4, feature = "feathers" },
	protoceratops = { kind = "grazer", scale = 0.45, feature = "frill" },
	gallimimus = { kind = "hunter", scale = 0.65, feature = "longlegs" },
	parasaurolophus = { kind = "grazer", scale = 0.8, feature = "backcrest" },
	stegosaurus = { kind = "grazer", scale = 1, feature = "plates" },
	ankylosaurus = { kind = "grazer", scale = 0.8, feature = "club" },
	triceratops = { kind = "grazer", scale = 0.9, feature = "horns" },
	brachiosaurus = { kind = "grazer", scale = 2, feature = "highneck" },
	utahraptor = { kind = "hunter", scale = 0.8, feature = "sickle" },
	velociraptor = { kind = "hunter", scale = 0.5, feature = "slender" },
	dilophosaurus = { kind = "hunter", scale = 0.8, feature = "twincrest" },
	allosaurus = { kind = "hunter", scale = 1.4, feature = "brow" },
	tyrannosaurus = { kind = "hunter", scale = 1.8, feature = "heavyjaw" },
	smilodon = { kind = "grazer", scale = 0.6, feature = "saber" },
	tropicalSmilodon = { kind = "grazer", scale = 0.5, feature = "cat" },
	direWolf = { kind = "grazer", scale = 0.55, feature = "muzzle" },
	mammoth = { kind = "grazer", scale = 1.5, feature = "wool" },
	boar = { kind = "grazer", scale = 0.45, feature = "bristles" },
	deer = { kind = "grazer", scale = 0.55, feature = "antlers" },
	elephant = { kind = "grazer", scale = 1.3, feature = "trunk" },
	crocodile = { kind = "grazer", scale = 0.65, feature = "flatjaw" },
	turtle = { kind = "grazer", scale = 0.22, feature = "shell" },
	dodo = { kind = "hunter", scale = 0.28, feature = "roundbeak" },
}
function M.new(kind: string, id: string, position: Vector3, parent: Instance): Model
	local species = kind
	local silhouette = silhouettes[species]
	if silhouette then
		kind = silhouette.kind
	end
	assert(kind == "grazer" or kind == "hunter", "UNKNOWN_DINOSAUR")
	local model = Instance.new("Model")
	model.Name = id
	local root = Instance.new("Part")
	root.Name, root.Size, root.Transparency, root.CanCollide = "HumanoidRootPart", Vector3.new(2, 2, 3), 1, true
	root.CFrame, root.Parent = CFrame.new(position), model
	local green = if kind == "grazer" then Color3.fromRGB(78, 138, 86) else Color3.fromRGB(164, 92, 54)
	local accent = if kind == "grazer" then Color3.fromRGB(48, 96, 56) else Color3.fromRGB(76, 44, 32)
	local belly = Color3.fromRGB(208, 196, 146)
	local function anatomy(name: string, size: Vector3, offset: CFrame, color: Color3, wedge: boolean?): BasePart
		local part: BasePart = if wedge then Instance.new("WedgePart") else Instance.new("Part")
		part.Name, part.Size, part.CFrame, part.Color = name, size, root.CFrame * offset, color
		part.Material, part.TopSurface, part.BottomSurface =
			Enum.Material.SmoothPlastic, Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		part.CanCollide, part.Massless, part.Parent = false, true, model
		local joint = Instance.new("Motor6D")
		joint.Name, joint.Part0, joint.Part1, joint.C0, joint.Parent = name .. "Joint", root, part, offset, root
		return part
	end
	anatomy("Torso", Vector3.new(3, 2.5, 5), CFrame.new(0, 0, 0), green)
	anatomy("Belly", Vector3.new(2.5, 0.7, 3.6), CFrame.new(0, -1, 0), belly)
	for spine = 1, 3 do
		anatomy("Spine" .. spine, Vector3.new(0.45, 0.65, 1.1), CFrame.new(0, 1.45, -1.8 + spine * 1.3), accent, true)
	end
	for side = -1, 1, 2 do
		anatomy("Thigh" .. side, Vector3.new(1.1, 2, 1.6), CFrame.new(side * 1.4, -1.1, 1), green)
		anatomy("Shin" .. side, Vector3.new(0.7, 1.6, 0.8), CFrame.new(side * 1.4, -2.4, 1), accent)
		anatomy("Foot" .. side, Vector3.new(1.1, 0.5, 1.8), CFrame.new(side * 1.4, -3, 0.5), belly)
		if kind == "grazer" then
			anatomy("Foreleg" .. side, Vector3.new(0.9, 2.5, 1.0), CFrame.new(side * 1.2, -1.8, -1.6), green)
		else
			anatomy(
				"Arm" .. side,
				Vector3.new(0.45, 1.1, 0.55),
				CFrame.new(side * 1.55, -0.3, -1.8) * CFrame.Angles(math.rad(-30), 0, 0),
				green
			)
			anatomy("Claw" .. side, Vector3.new(0.35, 0.25, 0.8), CFrame.new(side * 1.55, -0.9, -2.2), belly, true)
		end
	end
	for segment = 1, 4 do
		anatomy(
			"Tail" .. segment,
			Vector3.new(1.8 - segment * 0.3, 1.5 - segment * 0.24, 2),
			CFrame.new(0, 0.15 + segment * 0.08, 2 + segment * 1.4) * CFrame.Angles(math.rad(4), 0, 0),
			if segment % 2 == 0 then accent else green,
			true
		)
	end
	local headY, headZ = 1.1, -3.6
	if kind == "grazer" then
		for segment = 1, 3 do
			anatomy(
				"Neck" .. segment,
				Vector3.new(1.25, 1.8, 1.3),
				CFrame.new(0, segment * 1.1, -1.8 - segment * 0.7) * CFrame.Angles(math.rad(-25), 0, 0),
				green
			)
		end
		headY, headZ = 4, -4.4
	else
		anatomy("Neck", Vector3.new(1.8, 2, 1.8), CFrame.new(0, 0.7, -2.3), green)
	end
	anatomy("Head", Vector3.new(1.8, 1.25, 2.3), CFrame.new(0, headY, headZ), green)
	anatomy("Snout", Vector3.new(1.4, 0.75, 1.2), CFrame.new(0, headY - 0.1, headZ - 1.4), green, true)
	anatomy("Crest", Vector3.new(0.5, 0.75, 1.5), CFrame.new(0, headY + 0.85, headZ + 0.2), accent, true)
	anatomy("Jaw", Vector3.new(1.5, 0.4, 2), CFrame.new(0, headY - 0.6, headZ - 0.1), belly)
	for side = -1, 1, 2 do
		anatomy(
			"Eye" .. side,
			Vector3.new(0.16, 0.32, 0.34),
			CFrame.new(side * 0.92, headY + 0.15, headZ - 0.45),
			Color3.fromRGB(245, 196, 62)
		)
	end
	-- Preserve the authored silhouette while giving motion anatomical pivots.
	-- Descendants follow their parent joint instead of separating during a pose.
	local function link(name: string, parentName: string, pivot: Vector3)
		local part = model:FindFirstChild(name) :: BasePart
		local parentPart = model:FindFirstChild(parentName) :: BasePart
		local joint = root:FindFirstChild(name .. "Joint") :: Motor6D
		local frame = root.CFrame * CFrame.new(pivot)
		joint.Part0, joint.C0, joint.C1 =
			parentPart, parentPart.CFrame:ToObjectSpace(frame), part.CFrame:ToObjectSpace(frame)
	end
	link("Belly", "Torso", Vector3.new(0, -1, 0))
	for spine = 1, 3 do
		link("Spine" .. spine, "Torso", Vector3.new(0, 1.25, -1.8 + spine * 1.3))
	end
	for side = -1, 1, 2 do
		link("Thigh" .. side, "Torso", Vector3.new(side * 1.4, -0.2, 1))
		link("Shin" .. side, "Thigh" .. side, Vector3.new(side * 1.4, -1.9, 1))
		link("Foot" .. side, "Shin" .. side, Vector3.new(side * 1.4, -2.9, 0.8))
		if kind == "grazer" then
			link("Foreleg" .. side, "Torso", Vector3.new(side * 1.2, -0.6, -1.6))
		else
			link("Arm" .. side, "Torso", Vector3.new(side * 1.55, 0.2, -1.8))
			link("Claw" .. side, "Arm" .. side, Vector3.new(side * 1.55, -0.8, -2.2))
		end
		link("Eye" .. side, "Head", Vector3.new(side * 0.92, headY + 0.15, headZ - 0.45))
	end
	for segment = 1, 4 do
		link(
			"Tail" .. segment,
			if segment == 1 then "Torso" else "Tail" .. (segment - 1),
			Vector3.new(0, 0.2, 1.6 + segment * 1.4)
		)
	end
	if kind == "grazer" then
		for segment = 1, 3 do
			link(
				"Neck" .. segment,
				if segment == 1 then "Torso" else "Neck" .. (segment - 1),
				Vector3.new(0, segment * 1.1 - 0.7, -1.8 - segment * 0.7)
			)
		end
	end
	if kind == "hunter" then
		link("Neck", "Torso", Vector3.new(0, 0.3, -1.8))
	end
	link("Head", if kind == "grazer" then "Neck3" else "Neck", Vector3.new(0, headY, headZ + 0.8))
	link("Snout", "Head", Vector3.new(0, headY - 0.1, headZ - 1.0))
	link("Crest", "Head", Vector3.new(0, headY + 0.6, headZ + 0.2))
	link("Jaw", "Head", Vector3.new(0, headY - 0.4, headZ + 0.7))
	if silhouette then
		local feature = silhouette.feature
		local quadruped = feature == "saber"
			or feature == "cat"
			or feature == "muzzle"
			or feature == "wool"
			or feature == "bristles"
			or feature == "antlers"
			or feature == "trunk"
			or feature == "flatjaw"
			or feature == "shell"
			or feature == "club"
			or feature == "horns"
			or feature == "frill"
			or feature == "plates"
		if quadruped then
			-- Short neck species keep a head on shoulders, not the long-neck base.
			for segment = 1, 3 do
				local neck = model:FindFirstChild("Neck" .. segment) :: BasePart
				neck.Size = Vector3.new(1.3, 0.6, 0.7)
				local joint = root:FindFirstChild("Neck" .. segment .. "Joint") :: Motor6D
				joint.C0 = CFrame.new(0, 0.15, -0.4)
				joint.C1 = CFrame.identity
			end
		end
		local function signature(name: string, size: Vector3, offset: CFrame, parentName: string, wedge: boolean?)
			local part = anatomy(name, size, offset, accent, wedge)
			link(name, parentName, offset.Position)
			return part
		end
		if feature == "frill" or feature == "horns" then
			signature("Frill", Vector3.new(3.4, 2.4, 0.4), CFrame.new(0, headY + 0.3, headZ + 0.6), "Head")
		end
		if
			feature == "horns"
			or feature == "antlers"
			or feature == "saber"
			or feature == "wool"
			or feature == "bristles"
		then
			for side = -1, 1, 2 do
				signature(
					"Horn" .. side,
					Vector3.new(0.35, if feature == "antlers" then 2.7 else 1.6, 0.5),
					CFrame.new(side * 0.7, headY + (if feature == "saber" then -1 else 0.8), headZ - 1.3),
					"Head",
					true
				)
			end
			if feature == "horns" then
				signature("NoseHorn", Vector3.new(0.4, 1, 0.5), CFrame.new(0, headY + 0.4, headZ - 1.8), "Head", true)
			end
		end
		if feature == "trunk" or feature == "wool" then
			signature("Trunk", Vector3.new(0.6, 3.5, 0.7), CFrame.new(0, headY - 1.6, headZ - 1.8), "Head")
		end
		if feature == "trunk" or feature == "muzzle" or feature == "cat" or feature == "saber" then
			for side = -1, 1, 2 do
				signature(
					"Ear" .. side,
					Vector3.new(if feature == "trunk" then 2 else 0.5, 1.2, 0.3),
					CFrame.new(side * 1.2, headY + 0.6, headZ + 0.2),
					"Head",
					true
				)
			end
		end
		if feature == "plates" or feature == "bristles" then
			for index = 1, 5 do
				signature(
					"Plate" .. index,
					Vector3.new(0.35, if feature == "plates" then 2 else 0.7, 1),
					CFrame.new((index % 2 - 0.5) * 0.6, 1.8, -2.5 + index),
					"Torso",
					true
				)
			end
		end
		if feature == "club" or feature == "shell" then
			signature("ArmorDome", Vector3.new(3.8, 1.5, 5.5), CFrame.new(0, 1, 0), "Torso")
			if feature == "club" then
				signature("TailClub", Vector3.new(2.6, 1.2, 1.8), CFrame.new(0, 0.4, 7.8), "Tail4")
			end
		end
		if feature == "feathers" or feature == "sickle" then
			for side = -1, 1, 2 do
				signature(
					"FeatherFan" .. side,
					Vector3.new(0.2, 1.4, 2.2),
					CFrame.new(side * 1.7, -0.2, -1.2),
					"Arm" .. side,
					true
				)
			end
		end
		if feature == "twincrest" or feature == "brow" then
			for side = -1, 1, 2 do
				signature(
					"Brow" .. side,
					Vector3.new(0.35, if feature == "twincrest" then 1 else 0.4, 1.8),
					CFrame.new(side * 0.6, headY + 0.8, headZ),
					"Head",
					true
				)
			end
		end
		if feature == "heavyjaw" then
			(model:FindFirstChild("Head") :: BasePart).Size = Vector3.new(2.8, 2, 3.6)
		elseif feature == "backcrest" then
			signature("BackwardCrest", Vector3.new(0.5, 0.5, 3), CFrame.new(0, headY + 1, headZ + 1), "Head")
		elseif feature == "longlegs" then
			for side = -1, 1, 2 do
				(model:FindFirstChild("Shin" .. side) :: BasePart).Size = Vector3.new(0.5, 2.8, 0.6)
			end
		elseif feature == "flatjaw" then
			(model:FindFirstChild("Head") :: BasePart).Size = Vector3.new(2, 0.6, 4)
		elseif feature == "roundbeak" then
			(model:FindFirstChild("Torso") :: BasePart).Size = Vector3.new(4, 4, 4)
		end
		-- Rebuild rest positions after editing neck joint frames, before scaling.
		-- All joints were authored parent-before-child except head accessories,
		-- so repeated bounded passes also settle those signature children.
		for _ = 1, 8 do
			for _, joint in root:GetChildren() do
				if joint:IsA("Motor6D") and joint.Part0 and joint.Part1 then
					joint.Part1.CFrame = joint.Part0.CFrame * joint.C0 * joint.C1:Inverse()
				end
			end
		end
		-- Scale articulated geometry and both joint frames together.
		for _, part in model:GetChildren() do
			if part:IsA("BasePart") then
				part.Size *= silhouette.scale
				local relative = root.CFrame:ToObjectSpace(part.CFrame)
				part.CFrame = root.CFrame * (relative.Rotation + relative.Position * silhouette.scale)
			end
		end
		for _, joint in root:GetChildren() do
			if joint:IsA("Motor6D") then
				joint.C0 = joint.C0.Rotation + joint.C0.Position * silhouette.scale
				joint.C1 = joint.C1.Rotation + joint.C1.Position * silhouette.scale
			end
		end
		model:SetAttribute("Species", species)
		model:SetAttribute("Silhouette", feature)
	end
	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight, humanoid.WalkSpeed, humanoid.RequiresNeck = 2, if kind == "grazer" then 12 else 14, false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = parent
	return model
end
-- Deterministic pose sampling; callers own their render connection and clock.
function M.pose(model: Model, state: string, elapsed: number, speed: number)
	local root = model.PrimaryPart
	if not root then
		return
	end
	local stride = math.sin(elapsed * (if state == "run" then 9 else 5))
	local moving = state == "walk" or state == "run" or state == "ridden"
	for _, child in root:GetChildren() do
		if child:IsA("Motor6D") then
			local name = child.Name
			local angle = 0
			if moving and (string.find(name, "Thigh") or string.find(name, "Foreleg")) then
				angle = stride * math.min(speed / 20, 0.65) * (if string.find(name, "-1") then -1 else 1)
			elseif string.find(name, "Tail") then
				angle = math.sin(elapsed * 2) * 0.06
			elseif string.find(name, "Neck") then
				angle = math.sin(elapsed * 1.5) * 0.025
			end
			if state == "attack" or state == "windup" or state == "telegraph" then
				if name == "HeadJoint" or name == "JawJoint" then
					angle = math.sin(math.min(elapsed * 4, math.pi)) * 0.5
				end
			elseif state == "hurt" then
				angle = math.sin(math.min(elapsed / 0.2, 1) * math.pi) * 0.2
			elseif state == "stun" or state == "sleep" or state == "rest" then
				if name == "HeadJoint" then
					angle = 0.45
				end
			elseif state == "death" or state == "dead" then
				if name == "TorsoJoint" then
					angle = math.min(elapsed / 1.5, 1) * math.pi / 2
				end
			end
			child.Transform = CFrame.Angles(angle, 0, 0)
		end
	end
end
return M
