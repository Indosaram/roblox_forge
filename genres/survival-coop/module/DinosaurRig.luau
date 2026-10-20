--!strict
-- Original procedural silhouettes: long-neck quadruped and biped theropod.
-- Articulated low-poly anatomy is a rig mechanism, not a rendered quality verdict.
local M = {}
function M.new(kind: string, id: string, position: Vector3, parent: Instance): Model
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
	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight, humanoid.WalkSpeed, humanoid.RequiresNeck = 2, if kind == "grazer" then 12 else 14, false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = parent
	return model
end
return M
