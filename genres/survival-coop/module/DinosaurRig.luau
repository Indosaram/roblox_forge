--!strict
local M = {}
type Shape = { family: string, feature: string, size: Vector3, attack: string }
local function shape(family: string, feature: string, w: number, h: number, l: number, attack: string): Shape
	return { family = family, feature = feature, size = Vector3.new(w, h, l), attack = attack }
end
local silhouettes = {
	compsognathus = shape("theropod", "scuttle", 1, 1.5, 3, "bite"),
	oviraptor = shape("theropod", "feathers", 1.5, 3, 3, "jab"),
	protoceratops = shape("ceratopsian", "frill", 2.5, 3, 4, "charge"),
	gallimimus = shape("theropod", "longlegs", 2, 6, 5, "kick"),
	parasaurolophus = shape("hadrosaur", "backcrest", 3, 7, 7, "kick"),
	stegosaurus = shape("armored", "plates", 5, 6, 9, "tail"),
	ankylosaurus = shape("armored", "club", 4, 4, 7, "tail"),
	triceratops = shape("ceratopsian", "horns", 5, 5, 8, "charge"),
	brachiosaurus = shape("sauropod", "highneck", 8, 24, 18, "stomp"),
	utahraptor = shape("theropod", "sickle", 3, 6, 6, "pounce"),
	velociraptor = shape("theropod", "slender", 2, 4, 4, "slash"),
	dilophosaurus = shape("theropod", "twincrest", 3, 6, 6, "bite"),
	allosaurus = shape("theropod", "brow", 5, 9, 12, "bite"),
	tyrannosaurus = shape("theropod", "heavyjaw", 7, 12, 16, "bite"),
	smilodon = shape("mammal", "saber", 3, 4, 5, "pounce"),
	tropicalSmilodon = shape("mammal", "cat", 2.5, 3.5, 5, "pounce"),
	direWolf = shape("mammal", "muzzle", 2.5, 3.5, 5, "bite"),
	mammoth = shape("elephant", "wool", 7, 10, 12, "tusk"),
	boar = shape("mammal", "bristles", 2.5, 3, 4, "charge"),
	deer = shape("mammal", "antlers", 2, 5, 4, "kick"),
	elephant = shape("elephant", "trunk", 6, 9, 10, "tusk"),
	crocodile = shape("crocodilian", "flatjaw", 3, 2, 7, "lunge"),
	turtle = shape("turtle", "shell", 1.5, 1, 2, "withdraw"),
	dodo = shape("bird", "roundbeak", 1.5, 2, 2, "flutter"),
}

export type Rgb = { r: number, g: number, b: number }
--- Authored per-species look (content wildlifeDetails[].visual). Without it the built-in
--- silhouette and pigment tables below stay the defaults.
export type Visual = {
	plan: string,
	feature: string,
	skin: string?,
	body: Rgb,
	accent: Rgb?,
	belly: Rgb?,
	marking: Rgb?,
	parts: { string }?,
	-- Paid cosmetic skins only (CosmeticVisual.mount): reflectance of the body-coloured parts.
	sheen: number?,
}
local SKINS: { [string]: Enum.Material } = {
	leather = Enum.Material.Leather,
	plates = Enum.Material.Slate,
	-- Fabric renders near black on creature-sized parts; fur and feathers use plastic.
	fur = Enum.Material.Plastic,
	feathers = Enum.Material.SmoothPlastic,
}
local function rgb(c: Rgb): Color3
	return Color3.fromRGB(c.r, c.g, c.b)
end

local pigments: { [string]: { number } } = {
	compsognathus = { 129, 145, 66 },
	oviraptor = { 139, 86, 67 },
	protoceratops = { 178, 142, 86 },
	gallimimus = { 172, 124, 72 },
	parasaurolophus = { 64, 124, 123 },
	stegosaurus = { 118, 130, 88 },
	ankylosaurus = { 122, 110, 82 },
	triceratops = { 145, 99, 73 },
	brachiosaurus = { 115, 120, 83 },
	utahraptor = { 142, 90, 60 },
	velociraptor = { 171, 145, 88 },
	dilophosaurus = { 77, 127, 114 },
	allosaurus = { 126, 115, 80 },
	tyrannosaurus = { 99, 113, 83 },
	smilodon = { 183, 143, 84 },
	tropicalSmilodon = { 149, 116, 66 },
	direWolf = { 114, 119, 117 },
	mammoth = { 106, 76, 56 },
	boar = { 109, 91, 74 },
	deer = { 165, 121, 79 },
	elephant = { 131, 125, 113 },
	crocodile = { 91, 112, 74 },
	turtle = { 103, 132, 86 },
	dodo = { 122, 141, 151 },
}

function M.new(
	kind: string,
	id: string,
	position: Vector3,
	parent: Instance,
	envelope: Vector3?,
	visual: Visual?
): Model
	local species = if kind == "grazer" then "brachiosaurus" elseif kind == "hunter" then "allosaurus" else kind
	local spec: Shape? = (silhouettes :: { [string]: Shape })[species]
	assert(spec or visual, "UNKNOWN_DINOSAUR")
	local dims = envelope or (if spec then spec.size else nil)
	assert(dims and dims.X > 0 and dims.Y > 0 and dims.Z > 0, "INVALID_RIG_ENVELOPE")
	local model = Instance.new("Model")
	model.Name = id
	local root = Instance.new("Part")
	root.Name, root.Transparency, root.CanCollide = "HumanoidRootPart", 1, true
	root.Size, root.CFrame, root.Parent = dims, CFrame.new(position), model
	local w, h, l = dims.X, dims.Y, dims.Z
	local family = if visual then visual.plan else (spec :: Shape).family
	local feature = if visual then visual.feature else (spec :: Shape).feature
	local attackStyle = if spec then spec.attack else "bite"
	local mammal = family == "mammal" or family == "elephant"
	local pigment = if visual
		then { visual.body.r, visual.body.g, visual.body.b }
		else assert(pigments[species], "MISSING_SPECIES_PIGMENT")
	local bodyColor = Color3.fromRGB(table.unpack(pigment))
	local p1, p2, p3 = pigment[1], pigment[2], pigment[3]
	local accent = if visual and visual.accent
		then rgb(visual.accent)
		else Color3.fromRGB(math.max(90, p1 * 0.78), math.max(90, p2 * 0.78), math.max(90, p3 * 0.78))
	local underside = if visual and visual.belly
		then rgb(visual.belly)
		else Color3.fromRGB(math.min(225, p1 + 49), math.min(219, p2 + 43), math.min(189, p3 + 38))
	local marking = if visual and visual.marking then rgb(visual.marking) else accent
	local ivory = Color3.fromRGB(225, 216, 177)
	local skin = if visual and visual.skin
		then assert(SKINS[visual.skin], "UNKNOWN_CREATURE_SKIN")
		elseif mammal then SKINS.fur
		elseif family == "bird" then SKINS.feathers
		elseif family == "turtle" or family == "armored" then SKINS.plates
		else SKINS.leather
	local extras: { [string]: boolean } = {}
	local tokens: { string } = if visual and visual.parts then visual.parts else {}
	for _, token in tokens do
		extras[token] = true
	end
	local parts: { [string]: BasePart } = { HumanoidRootPart = root }
	local count = 1
	local function part(
		name: string,
		size: Vector3,
		at: Vector3,
		parentName: string,
		form: string?,
		color: Color3?,
		pivot: Vector3?
	): BasePart
		local limb = string.match(name, "^Thigh") or string.match(name, "^Fore[lS]") or string.match(name, "^Arm")
		-- A Ball part always renders as a sphere of its smallest axis, so rounded anatomy is a
		-- block carrying a Sphere SpecialMesh: a true ellipsoid filling Size.
		local round = form == nil or limb ~= nil
		local p: BasePart = if form == "wedge" then Instance.new("WedgePart") else Instance.new("Part")
		if p:IsA("Part") then
			p.Shape = if form == "cylinder" and not round then Enum.PartType.Cylinder else Enum.PartType.Block
		end
		local localAt = Vector3.new(at.X * w, at.Y * h, at.Z * l)
		p.Name, p.Size = name, Vector3.new(size.X * w, size.Y * h, size.Z * l)
		if round and name ~= "Head" and name ~= "Shell" then
			p.Size = p.Size:Min(Vector3.one * l * 0.39)
		end
		p.CFrame, p.Color = root.CFrame * CFrame.new(localAt), color or bodyColor
		if limb then
			p.Size = Vector3.new(size.Y * h, size.X * w, size.Z * l)
			p.CFrame *= CFrame.Angles(0, 0, math.pi / 2)
		end
		if round then
			local mesh = Instance.new("SpecialMesh")
			mesh.Name, mesh.MeshType = "Ellipsoid", Enum.MeshType.Sphere
			mesh.Parent = p
		end
		p.Material = if color
				and color ~= accent
				and color ~= underside
				and color ~= bodyColor
			then Enum.Material.SmoothPlastic
			else skin
		p.CanCollide, p.Massless = false, true
		p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		p.Parent = model
		local parentPart = assert(parts[parentName], "MISSING_ANATOMICAL_PARENT")
		local joint = Instance.new("Motor6D")
		local v = pivot or at
		local frame = root.CFrame * CFrame.new(v.X * w, v.Y * h, v.Z * l)
		joint.Name, joint.Part0, joint.Part1 = name .. "Joint", parentPart, p
		joint.C0, joint.C1 = parentPart.CFrame:ToObjectSpace(frame), p.CFrame:ToObjectSpace(frame)
		joint.Parent = root
		parts[name] = p
		count += 1
		return p
	end
	local function add(
		name: string,
		x: number,
		y: number,
		z: number,
		sx: number,
		sy: number,
		sz: number,
		parentName: string,
		form: string?,
		color: Color3?
	)
		return part(name, Vector3.new(sx, sy, sz), Vector3.new(x, y, z), parentName, form, color)
	end
	local function segment(name: string, a: Vector3, b: Vector3, radius: number, parentName: string)
		local scale = Vector3.new(w, h, l)
		local from, to = a * scale, b * scale
		local delta = to - from
		local p = part(name, Vector3.new(1, 1, 1), (a + b) / 2, parentName)
		p.Size = Vector3.new(delta.Magnitude * 1.85 + 0.18, radius * w, radius * w)
		p.CFrame = root.CFrame * CFrame.lookAt((from + to) / 2, to) * CFrame.Angles(0, math.pi / 2, 0)
		local joint = root:FindFirstChild(name .. "Joint") :: Motor6D
		local frame = root.CFrame * CFrame.new(from)
		joint.C0, joint.C1 =
			assert(joint.Part0, "MISSING_SEGMENT_PARENT").CFrame:ToObjectSpace(frame), p.CFrame:ToObjectSpace(frame)
		return p
	end
	-- Re-orients an attached part about its own centre and keeps its joint at rest.
	local function tilt(p: BasePart, rotation: CFrame)
		p.CFrame *= rotation
		local joint = root:FindFirstChild(p.Name .. "Joint") :: Motor6D
		joint.C1 = p.CFrame:ToObjectSpace(assert(joint.Part0).CFrame * joint.C0)
	end
	local biped = family == "theropod" or family == "bird"
	local low = family == "crocodilian" or family == "turtle"
	local torsoY = if family == "sauropod" then -0.2 elseif low then -0.05 elseif biped then -0.02 else 0
	local torsoH = if family == "sauropod"
		then 0.28
		elseif family == "bird" then 0.48
		elseif family == "elephant" then 0.44
		elseif low then 0.38
		else 0.36
	add("Torso", 0, torsoY, 0.05, if biped then 0.58 else 0.52, torsoH, 0.39, "HumanoidRootPart")
	add(
		"Shoulders",
		0,
		torsoY + torsoH * 0.12,
		-0.1,
		if family == "theropod" then 0.48 else 0.49,
		torsoH * 0.9,
		0.32,
		"Torso"
	)
	add("Haunches", 0, torsoY, 0.19, 0.5, torsoH * 0.92, 0.34, "Torso")
	add("Countershade", 0, torsoY - torsoH * 0.38, 0.04, 0.42, torsoH * 0.28, 0.38, "Torso", nil, underside)
	for side = -1, 1, 2 do
		local stripe = add(
			"FlankPattern" .. side,
			side * (if family == "theropod" then 0.24 else 0.29),
			torsoY + 0.03,
			0.08,
			0.015,
			torsoH * 0.1,
			0.12,
			"Torso",
			"block",
			accent
		)
		stripe.CFrame *= CFrame.Angles(0, 0, math.rad(side * 18))
		local joint = root:FindFirstChild(stripe.Name .. "Joint") :: Motor6D
		joint.C1 = stripe.CFrame:ToObjectSpace(assert(joint.Part0).CFrame * joint.C0)
	end
	local hy, hz, headW, headH, headL = 0.14, -0.34, 0.37, 0.23, 0.23
	if family == "sauropod" then
		local curve = { -0.16, -0.185, -0.19, -0.22, -0.28, -0.35, -0.39 }
		for i = 1, 6 do
			segment(
				"Neck" .. i,
				Vector3.new(0, -0.16 + (i - 1) * 0.095, curve[i]),
				Vector3.new(0, -0.16 + i * 0.095, curve[i + 1]),
				0.26 - i * 0.02,
				if i == 1 then "Torso" else "Neck" .. (i - 1)
			)
		end
		hy, hz, headW, headH, headL = 0.43, -0.39, 0.17, 0.09, 0.14
		add("NostrilCrest", 0, hy + 0.045, hz + 0.015, 0.12, 0.07, 0.09, "Neck6", nil, underside)
	elseif family == "theropod" then
		-- Raised head on an S-neck over the hips: reads as a biped, not a four-legged body.
		hy = if feature == "longlegs" or feature == "scuttle" then 0.4 elseif feature == "heavyjaw" then 0.3 else 0.32
		hz, headL = -0.42, 0.3
		headW = if feature == "heavyjaw" then 0.42 else 0.28
		headH = if feature == "heavyjaw" then 0.25 else 0.2
		add("NeckBase", 0, (hy + torsoY) / 2 - 0.04, -0.22, 0.29, hy - torsoY, 0.22, "Torso")
		add("Neck", 0, hy - 0.06, -0.3, 0.22, 0.23, 0.2, "NeckBase")
	elseif family == "crocodilian" then
		hy, hz, headW, headH, headL = -0.06, -0.32, 0.47, 0.19, 0.38
	elseif family == "elephant" then
		hy, hz, headW, headH, headL = 0.1, -0.28, 0.48, 0.43, 0.23
	elseif family == "turtle" then
		hy, hz, headW, headH, headL = -0.14, -0.37, 0.24, 0.24, 0.2
	elseif family == "bird" then
		hy, hz, headW, headH, headL = 0.28, -0.25, 0.33, 0.27, 0.22
		add("Neck", 0, 0.17, -0.16, 0.26, 0.28, 0.19, "Torso", nil, underside)
	elseif family == "hadrosaur" then
		hy = 0.28
		headW, headH, headL = 0.29, 0.2, 0.27
		add("Neck", 0, 0.15, -0.22, 0.29, 0.32, 0.2, "Torso")
	elseif family == "ceratopsian" then
		hy, hz, headW, headH, headL = 0.09, -0.33, 0.38, 0.26, 0.25
	elseif feature == "bristles" then
		hy, hz, headW, headH, headL = -0.02, -0.38, 0.33, 0.29, 0.28
	elseif family == "mammal" then
		-- Head carried level and forward of the shoulders, ears up: a quadruped hunter's profile.
		hy, hz, headW, headH, headL = 0.12, -0.42, 0.3, 0.24, 0.26
		add("Neck", 0, 0.08, -0.3, 0.26, 0.26, 0.2, "Torso")
	end
	local neckParent = if family == "sauropod" then "Neck6" elseif parts.Neck then "Neck" else "Torso"
	part(
		"Head",
		Vector3.new(headW, headH, headL),
		Vector3.new(0, hy, hz),
		neckParent,
		nil,
		nil,
		Vector3.new(0, hy, hz + headL * 0.4)
	)
	add("Jaw", 0, hy - headH * 0.42, hz - headL * 0.12, headW * 0.85, headH * 0.22, headL * 1.2, "Head", nil, underside)
	local jj, f =
		root:FindFirstChild("JawJoint") :: Motor6D, CFrame.new(0, 0, l * headL * 0.52) * CFrame.Angles(0, math.pi, 0)
	jj.C0, jj.C1 = jj.C0 * f, jj.C1 * f
	add("Snout", 0, hy - headH * 0.1, hz - headL * 0.4, headW * 0.8, headH * 0.62, headL * 0.7, "Head", nil)
	if family == "theropod" then
		for side = -1, 1, 2 do
			add(
				"TeethRow" .. side,
				side * headW * 0.4,
				hy - headH * 0.34,
				hz - headL * 0.17,
				0.025,
				headH * 0.09,
				headL,
				"Jaw",
				"wedge",
				ivory
			)
		end
	end
	for side = -1, 1, 2 do
		local ey, ez = hy + headH * 0.13, hz - headL * 0.2
		add("Eye" .. side, side * headW * 0.46, ey, ez, 0.035, 0.033, 0.025, "Head", nil, Color3.fromRGB(238, 192, 61))
		add(
			"Pupil" .. side,
			side * headW * 0.477,
			ey,
			ez - headL * 0.005,
			0.014,
			0.024,
			0.015,
			"Head",
			nil,
			Color3.fromRGB(24, 29, 26)
		)
		-- Low sprawlers and the club-tailed tank stand on splayed legs.
		local lx = if low or feature == "club" then 0.4 else 0.28
		local tall = feature == "antlers" or feature == "longlegs"
		local legH, legW = if low then 0.18 elseif tall then 0.49 else 0.36, if tall then 0.1 else 0.18
		part(
			"Thigh" .. side,
			Vector3.new(legW * 1.2, legH * 0.85, 0.19),
			Vector3.new(side * lx, -0.19, 0.19),
			"Torso",
			nil,
			nil,
			Vector3.new(side * lx, -0.05, 0.19)
		)
		local shin = add("Shin" .. side, side * lx, -0.34, 0.19, legW * 0.72, 0.25, 0.1, "Thigh" .. side)
		shin.CFrame *= CFrame.Angles(0, 0, math.pi / 2)
		shin.Size = Vector3.new(h * 0.18, w * legW * 0.72, l * 0.1)
		local shinJoint = root:FindFirstChild(shin.Name .. "Joint") :: Motor6D
		shinJoint.C1 = shin.CFrame:ToObjectSpace(assert(shinJoint.Part0).CFrame * shinJoint.C0)
		add("Foot" .. side, side * lx, -0.465, 0.15, legW * 1.15, 0.07, 0.18, "Shin" .. side)
		add("ToeClaw" .. side, side * lx, -0.475, 0.065, legW * 0.65, 0.035, 0.06, "Foot" .. side, "wedge", ivory)
		if not biped then
			part(
				"Foreleg" .. side,
				Vector3.new(legW, 0.22, 0.13),
				Vector3.new(side * lx, -0.16, -0.15),
				"Torso",
				nil,
				nil,
				Vector3.new(side * lx, -0.04, -0.15)
			)
			add("ForeShin" .. side, side * lx, -0.34, -0.15, legW * 0.8, 0.18, 0.1, "Foreleg" .. side)
			add("Forefoot" .. side, side * lx, -0.465, -0.17, legW * 1.15, 0.07, 0.16, "ForeShin" .. side)
			add(
				"Foreclaw" .. side,
				side * lx,
				-0.475,
				-0.25,
				legW * 0.65,
				0.035,
				0.06,
				"Forefoot" .. side,
				"wedge",
				ivory
			)
		else
			local armSize = if feature == "heavyjaw" then 0.08 else 0.16
			add("Arm" .. side, side * 0.24, -0.07, -0.2, 0.07, armSize, 0.09, "Torso")
			if feature == "feathers" or feature == "sickle" or family == "bird" then
				add(
					"Wing" .. side,
					side * 0.26,
					0.02,
					0.05,
					0.16,
					0.22,
					0.31,
					"Arm" .. side,
					if family == "bird" then nil else "wedge",
					accent
				)
			end
		end
		if mammal then
			add(
				"Ear" .. side,
				side * headW * 0.38,
				hy + headH * 0.55,
				hz + 0.04,
				if family == "elephant" then 0.33 else 0.13,
				if family == "elephant" then 0.43 else 0.18,
				0.055,
				"Head",
				nil,
				accent
			)
		end
	end
	local dinosaurTail = not mammal and family ~= "bird" and family ~= "turtle"
	local tailStep = if family == "theropod" or family == "sauropod" then 0.16 else 0.13
	if dinosaurTail then
		for i = 1, 4 do
			segment(
				"Tail" .. i,
				Vector3.new(
					0,
					torsoY + (if family == "theropod" then 0.05 - (i - 1) * 0.03 else 0),
					0.22 + (i - 1) * tailStep
				),
				Vector3.new(0, torsoY + (if family == "theropod" then 0.05 - i * 0.03 else -0.015), 0.22 + i * tailStep),
				(if family == "theropod" then 0.38 else 0.28) - i * (if family == "theropod" then 0.077 else 0.055),
				if i == 1 then "Torso" else "Tail" .. (i - 1)
			)
		end
	elseif family == "mammal" and extras.bushyTail then
		-- Long low brush carried behind the haunches (wolf), not a stub.
		local brush = add("MammalTail", 0, torsoY - 0.16, 0.4, 0.15, 0.3, 0.16, "Torso", nil, accent)
		brush:SetAttribute("VisualPart", "bushyTail")
		tilt(brush, CFrame.Angles(math.rad(-25), 0, 0))
	elseif family == "mammal" then
		add(
			"MammalTail",
			0,
			0.02,
			0.36,
			0.07,
			0.07,
			if feature == "saber" or feature == "bristles" then 0.12 else 0.26,
			"Torso",
			nil,
			accent
		)
	end
	if feature == "frill" or feature == "horns" then
		for i = -1, 1 do
			local x, y = i * 0.21, hy + (if i == 0 then 0.16 else 0.09)
			local name = if i == 0 then "Frill" else "FrillLobe" .. i
			add(name, x, y, hz + 0.08, 0.4, 0.36, 0.09, "Head", nil, accent)
			add("FrillFace" .. i, x, y, hz + 0.045, 0.35, 0.31, 0.055, name, nil, underside)
		end
	end
	if
		feature == "horns"
		or feature == "antlers"
		or feature == "saber"
		or feature == "cat"
		or feature == "bristles"
		or family == "elephant"
	then
		for side = -1, 1, 2 do
			local name = if family == "elephant" or feature == "bristles"
				then "Tusk"
				elseif feature == "saber" or feature == "cat" then "Saber"
				elseif feature == "antlers" then "Antler"
				else "Horn"
			local down = name == "Saber"
			add(
				name .. side,
				side * headW * 0.35,
				hy + (if down then -0.18 elseif name == "Tusk" then -0.07 else 0.12),
				hz - headL * (if name == "Antler" then 0 else 0.5),
				0.065,
				if name == "Antler" then 0.18 elseif down then 0.2 elseif feature == "bristles" then 0.12 else 0.16,
				if family == "elephant" then 0.35 elseif feature == "horns" then 0.24 else 0.12,
				"Head",
				if feature == "bristles" then nil else "wedge",
				ivory
			)
			if name == "Antler" or (name == "Tusk" and family == "elephant") then
				add(
					name .. "Tip" .. side,
					side * (if name == "Antler" then 0.19 else 0.17),
					hy + (if name == "Antler" then 0.2 else -0.06),
					hz + (if name == "Antler" then 0.06 else -0.245),
					0.06,
					0.18,
					0.09,
					name .. side,
					"wedge",
					ivory
				)
			end
		end
		if feature == "horns" then
			add("NoseHorn", 0, hy + 0.09, hz - 0.17, 0.08, 0.18, 0.12, "Head", "wedge", ivory)
		end
	end
	if family == "ceratopsian" then
		add("Beak", 0, hy - 0.035, hz - 0.18, 0.22, 0.14, 0.14, "Head", "wedge", ivory)
		add("BeakHook", 0, hy - 0.085, hz - 0.23, 0.13, 0.13, 0.06, "Beak", nil, ivory)
	end
	if family == "elephant" then
		for i = 1, 3 do
			add(
				"Trunk" .. i,
				0,
				hy - i * 0.14,
				hz - 0.17 - i * 0.015,
				0.15 - i * 0.025,
				0.2,
				0.12,
				if i == 1 then "Head" else "Trunk" .. (i - 1)
			)
		end
		if feature == "wool" then
			add("WoolDome", 0, 0.25, 0.01, 0.65, 0.38, 0.38, "Torso", nil, accent)
		end
	elseif family == "turtle" or feature == "club" then
		local a = if family == "turtle" then 1 else 0.6
		local shell = add("Shell", 0, 0.12, 0.04, 0.86 * a, 0.68 * a * a, 0.62 * a, "Torso", nil, accent)
		if family ~= "turtle" then
			-- Ankylosaur armour is a broad low dome that overhangs the legs.
			shell.Size = Vector3.new(w * 0.98, h * 0.32, l * 0.44)
		end
		if family == "turtle" then
			for i = -1, 1 do
				add(
					"Scute" .. i,
					0,
					0.43 - math.abs(i) * 0.06,
					0.04 + i * 0.17,
					0.32,
					0.08,
					0.2,
					"Shell",
					nil,
					bodyColor
				)
			end
			for side = -1, 1, 2 do
				add("SideScute" .. side, side * 0.27, 0.34, 0.04, 0.22, 0.09, 0.28, "Shell", nil, bodyColor)
			end
		end
		if feature == "club" then
			add("TailClub", 0, -0.01, 0.74, 0.4, 0.24, 0.19, "Tail4", nil, ivory)
		end
	end
	if feature == "plates" or feature == "bristles" or family == "crocodilian" or feature == "club" then
		for i = 1, 5 do
			add(
				"Dorsal" .. i,
				if feature == "plates" then (if i % 2 == 0 then 0.09 else -0.09) else 0,
				if feature == "plates" then 0.3 else 0.21,
				-0.22 + i * 0.09,
				if feature == "plates" then 0.1 else 0.18,
				if feature == "plates" then 0.36 else 0.12,
				if feature == "bristles" then 0.18 else 0.11,
				"Torso",
				if feature == "bristles" then nil else "wedge",
				accent
			)
		end
		if feature == "plates" then
			for side = -1, 1, 2 do
				add("TailSpike" .. side, side * 0.12, 0, 0.7, 0.08, 0.2, 0.18, "Tail4", "wedge", ivory)
			end
		end
	end
	if feature == "feathers" then
		add("Crest", 0, hy + 0.15, hz, 0.1, 0.24, 0.16, "Head", "wedge", accent)
	elseif feature == "backcrest" then
		-- The long tube crest sweeps up and back well past the skull.
		local crest = add("BackwardCrest", 0, hy + 0.13, hz + 0.16, 0.12, 0.12, 0.42, "Head", nil, accent)
		-- Negative pitch lifts the +Z (rear) end: the crest rises behind the skull into CrestTip.
		tilt(crest, CFrame.Angles(math.rad(-28), 0, 0))
		add("CrestTip", 0, hy + 0.22, hz + 0.33, 0.13, 0.13, 0.13, "BackwardCrest", nil, accent)
		add("DuckBill", 0, hy - 0.04, hz - 0.18, 0.34, 0.065, 0.16, "Head", nil, underside)
	elseif feature == "twincrest" or feature == "brow" then
		for side = -1, 1, 2 do
			add(
				"Brow" .. side,
				side * 0.11,
				hy + 0.14,
				hz,
				0.06,
				if feature == "twincrest" then 0.22 else 0.08,
				0.22,
				"Head",
				"wedge",
				accent
			)
		end
	elseif feature == "sickle" or feature == "slender" then
		for side = -1, 1, 2 do
			add("Sickle" .. side, side * 0.28, -0.42, 0.03, 0.05, 0.14, 0.12, "Foot" .. side, "wedge", ivory)
		end
	elseif family == "bird" then
		add("HookBeak", 0, hy - 0.025, hz - 0.16, 0.23, 0.15, 0.22, "Head", nil, ivory)
		add("BeakHook", 0, hy - 0.095, hz - 0.245, 0.16, 0.17, 0.08, "HookBeak", nil, accent)
		add("TailFan", 0, 0.1, 0.29, 0.35, 0.22, 0.2, "Torso", "wedge", underside)
	end
	-- Authored silhouette parts (content visual.parts), each tagged with its token.
	local function extra(token: string, p: BasePart): BasePart
		p:SetAttribute("VisualPart", token)
		return p
	end
	if extras.stripes then
		-- Bands that wrap the torso: an ellipsoid slice a little larger than the body there.
		local torso = parts.Torso
		for i = 1, 3 do
			local z = -0.06 + i * 0.07
			local girth = math.sqrt(math.max(0, 1 - ((z - 0.05) / 0.195) ^ 2)) * 1.05
			local band = extra("stripes", add("Stripe" .. i, 0, torsoY, z, 0.5, torsoH, 0.035, "Torso", nil, marking))
			band.Size = Vector3.new(torso.Size.X * girth, torso.Size.Y * girth, l * 0.035)
		end
	end
	if extras.mane then
		extra("mane", add("Mane", 0, torsoY + torsoH * 0.12, -0.17, 0.5, torsoH * 1.15, 0.2, "Torso", nil, accent))
	end
	if extras.hump then
		extra("hump", add("Hump", 0, torsoY + torsoH * 0.5, -0.1, 0.34, torsoH * 0.55, 0.24, "Torso", nil, accent))
	end
	if extras.sideSpikes then
		for side = -1, 1, 2 do
			for i = 1, 2 do
				local spike = extra(
					"sideSpikes",
					add(
						"SideSpike" .. side .. "_" .. i,
						side * 0.33,
						torsoY + 0.04,
						-0.06 + i * 0.12,
						0.1,
						0.13,
						0.1,
						"Torso",
						"wedge",
						ivory
					)
				)
				tilt(spike, CFrame.Angles(0, 0, -side * math.pi / 2))
			end
		end
	end
	if extras.saddle then
		-- Paid-skin trim: a saddle pad and seat on the back, in the skin's accent and marking.
		extra(
			"saddle",
			add("SaddlePad", 0, torsoY + torsoH * 0.42, 0.03, 0.46, torsoH * 0.16, 0.2, "Torso", nil, accent)
		)
		extra(
			"saddle",
			add("SaddleSeat", 0, torsoY + torsoH * 0.55, 0.03, 0.3, torsoH * 0.14, 0.13, "Torso", nil, marking)
		)
	end
	if visual and visual.sheen then
		for _, p in model:GetChildren() do
			if p:IsA("BasePart") and p.Color == bodyColor then
				p.Reflectance = visual.sheen
			end
		end
	end
	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck, humanoid.HipHeight = false, 0
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.Parent = model
	model:SetAttribute("Species", species)
	model:SetAttribute("Silhouette", feature)
	model:SetAttribute("BodyPlan", family)
	model:SetAttribute("AttackStyle", attackStyle)
	model:SetAttribute("PartCount", count)
	model:SetAttribute("PartBudget", 48)
	model.PrimaryPart, model.Parent = root, parent
	return model
end

-- Voxel writes become raycastable only after engine steps, and a large world build can take more
-- than one. A miss retries on Heartbeat for up to this many steps before it is reported.
M.GROUND_RETRY_STEPS = 600

local function settle(model: Model): boolean
	local root = assert(model.PrimaryPart, "CREATURE_ROOT_REQUIRED")
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	params.IgnoreWater = true
	local hit = workspace:Raycast(Vector3.new(root.Position.X, 512, root.Position.Z), Vector3.new(0, -1024, 0), params)
	if not hit then
		return false
	end
	local lowest = math.huge
	for _, piece in model:GetDescendants() do
		if piece:IsA("BasePart") then
			local cf, size = piece.CFrame, piece.Size
			local half = (
				math.abs(cf.RightVector.Y) * size.X
				+ math.abs(cf.UpVector.Y) * size.Y
				+ math.abs(cf.LookVector.Y) * size.Z
			) / 2
			lowest = math.min(lowest, cf.Position.Y - half)
		end
	end
	model:PivotTo(model:GetPivot() + Vector3.new(0, hit.Position.Y - lowest, 0))
	return true
end

--- Seats the rig on the terrain below it. When the terrain is not raycastable yet (fresh voxel
--- writes), it retries each Heartbeat and warns only if no terrain appears within the retry window.
function M.ground(model: Model)
	if settle(model) then
		return
	end
	local steps = 0
	local done = false
	local connection: RBXScriptConnection? = nil
	connection = game:GetService("RunService").Heartbeat:Connect(function()
		if done then
			return
		end
		steps += 1
		if not model.Parent or settle(model) then
			done = true
		elseif steps >= M.GROUND_RETRY_STEPS then
			done = true
			warn("CREATURE_SPAWN_WITHOUT_TERRAIN:" .. model.Name)
		end
		if done then
			(connection :: RBXScriptConnection):Disconnect()
		end
	end)
end

function M.pose(model: Model, state: string, elapsed: number, speed: number)
	local root = model.PrimaryPart
	if not root then
		return
	end
	local stride = math.sin(elapsed * (if state == "run" then 9 else 5))
	local moving = state == "walk" or state == "run" or state == "ridden"
	local attacking = state == "attack" or state == "strike"
	local preparing = state == "windup" or state == "telegraph" or state == "warning"
	local pulse = if attacking then math.sin(math.clamp(elapsed / 0.5, 0, 1) * math.pi) else 0
	local style = model:GetAttribute("AttackStyle")
	-- Decorative grazers: slow head sway plus one nose-down dip per seeded period (peak at 75%).
	local grazing = state == "graze"
	local authored = model:GetAttribute("ForgeGrazePeriod")
	local period = if type(authored) == "number" and authored > 0 then authored else 10
	local cycle = (elapsed % period) / period
	local dip = if grazing and cycle > 0.6 and cycle < 0.9 then math.sin((cycle - 0.6) / 0.3 * math.pi) else 0
	for _, joint in root:GetChildren() do
		if not joint:IsA("Motor6D") or not joint.Part1 then
			continue
		end
		local name = joint.Part1.Name
		local x, y, z, forward, lift = 0, 0, 0, 0, 0
		if name == "Torso" then
			lift = math.sin(elapsed * 2) * 0.008 * root.Size.Y
		elseif string.find(name, "Neck") then
			x = math.sin(elapsed * 1.5) * 0.025
		elseif string.find(name, "Tail") then
			y = math.sin(elapsed * 2) * 0.06
		end
		if grazing then
			if name == "Head" then
				x = math.sin(elapsed * 1.1) * 0.04 - dip * 0.45
				y = math.sin(elapsed * 0.7) * 0.12
			elseif string.find(name, "Neck") then
				x -= dip * 0.2
			elseif name == "Jaw" then
				x = dip * 0.12 * math.abs(math.sin(elapsed * 6))
			end
		end
		if moving then
			local side = if string.find(name, "-1", 1, true) then -1 else 1
			if string.find(name, "Thigh") or string.find(name, "Foreleg") then
				x = stride * math.min(speed / 20, 0.8) * side * (if string.find(name, "Foreleg") then -1 else 1)
			elseif name == "Torso" then
				lift = math.abs(stride) * root.Size.Y * (if state == "run" then 0.055 else 0.02)
				z = stride * (if state == "ridden" then 0.015 else 0.04)
				if state == "run" and model:GetAttribute("BodyPlan") == "hadrosaur" then
					x = -0.28
				end
			end
		end
		if preparing and name == "Head" then
			x = -0.35
		elseif attacking then
			if name == "Torso" then
				forward = -pulse * root.Size.Z * (if style == "tail" then 0.03 else 0.18)
				x = pulse * (if style == "pounce" then -0.35 elseif style == "charge" then 0.2 else 0.08)
				lift = if style == "pounce" then pulse * root.Size.Y * 0.2 else 0
				y = if style == "tail" or style == "tusk" then pulse * 0.65 else 0
			elseif name == "Head" then
				x = pulse * (if style == "charge" then 0.65 else 0.3)
				forward = if style == "withdraw" then pulse * root.Size.Z * 0.15 else 0
			elseif name == "Jaw" then
				x = pulse * (if style == "bite" or style == "lunge" then 0.7 else 0.25)
			elseif string.find(name, "Tail") and style == "tail" then
				y = pulse * 0.65
			elseif string.find(name, "Thigh") and (style == "kick" or style == "stomp") then
				x = -pulse * 1.1
			elseif string.find(name, "Arm") and (style == "slash" or style == "flutter" or style == "jab") then
				z = pulse * 1.0
			end
		elseif state == "hurt" or state == "hit" then
			if name == "Torso" then
				z = math.sin(math.clamp(elapsed / 0.2, 0, 1) * math.pi) * 0.3
			end
		elseif state == "stun" or state == "sleep" or state == "rest" then
			if name == "Head" then
				x = 0.45
			elseif name == "Torso" then
				lift = -root.Size.Y * 0.16
			end
		elseif state == "death" or state == "dead" then
			if name == "Torso" then
				z = math.clamp(elapsed / 1.5, 0, 1) * math.pi / 2
				lift = -root.Size.Y * 0.25
			end
		end
		joint.Transform = CFrame.new(0, lift, forward) * CFrame.Angles(x, y, z)
	end
end
return M
