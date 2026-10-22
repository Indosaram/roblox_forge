--!strict
-- Pure visual plan; gameplay positions, hazards and stock come only from content.
-- Budget: at most 96 scattered props and 768 authored kit parts per loaded role.
local M = {}
local runtime: any, load: any = getfenv(), require
-- Roblox resolves the shared module through ReplicatedStorage; Lune resolves the file.
local Rng = load(
	if runtime.game
		then runtime.game:GetService("ReplicatedStorage"):WaitForChild("Forge").core.domain.random.Rng
		else "../../../../core/domain/random/Rng"
)
local palettes: any = {
	grassland = { ground = "Grass", leaf = { 82, 114, 71 }, rock = { 110, 117, 103 }, fog = { 192, 215, 205 } },
	forest = { ground = "LeafyGrass", leaf = { 61, 100, 62 }, rock = { 97, 110, 101 }, fog = { 175, 202, 185 } },
	tropical = { ground = "LeafyGrass", leaf = { 44, 111, 76 }, rock = { 90, 110, 100 }, fog = { 170, 209, 197 } },
	swamp = { ground = "Mud", leaf = { 104, 124, 69 }, rock = { 82, 98, 89 }, fog = { 180, 194, 153 } },
	desert = { ground = "Sand", leaf = { 135, 141, 77 }, rock = { 174, 115, 75 }, fog = { 230, 207, 165 } },
	snow = { ground = "Snow", leaf = { 196, 222, 223 }, rock = { 112, 149, 170 }, fog = { 202, 225, 240 } },
	volcano = { ground = "Basalt", leaf = { 80, 91, 65 }, rock = { 58, 62, 65 }, fog = { 184, 161, 148 } },
}

local function add(
	parts: { any },
	id: string,
	position: any,
	size: any,
	material: string,
	color: any,
	shape: string?
): any
	local value = {
		id = id,
		position = position,
		size = size,
		material = material,
		color = color,
		shape = shape,
		decorative = true,
	}
	table.insert(parts, value)
	return value
end

function M.kit(parts: { any }, id: string, p: any, kind: string, palette: any)
	local function piece(
		suffix: string,
		x: number,
		y: number,
		z: number,
		sx: number,
		sy: number,
		sz: number,
		material: string,
		color: any,
		shape: string?
	): any
		local value = add(
			parts,
			id .. "." .. suffix,
			{ x = p.x + x, y = p.y + y, z = p.z + z },
			{ x = sx, y = sy, z = sz },
			material,
			color,
			shape
		)
		value.ground = { x = p.x, y = p.y, z = p.z }
		return value
	end
	local wood, sand = { 112, 78, 48 }, { 217, 189, 131 }
	-- Seeded per kit id: identical layouts dress identically on every server.
	local seed = 0
	for i = 1, #id do
		seed = (seed * 31 + string.byte(id, i)) % 2147483647
	end
	local rng = Rng.new(seed)
	local function leaf(lift: number): any
		local tone = rng:nextInteger(-16, 20) + lift
		return {
			math.clamp(palette.leaf[1] + tone, 0, 235),
			math.clamp(palette.leaf[2] + tone + rng:nextInteger(0, 12), 0, 235),
			math.clamp(palette.leaf[3] + tone // 2, 0, 235),
		}
	end
	if kind == "tree" or kind == "conifer" then
		for i = 1, 3 do
			local trunk = piece(
				"trunk" .. i,
				math.sin(i * 0.6) * 1.4,
				i * 3.9 - 1.9,
				0,
				4.6,
				2.5 - i * 0.35,
				2.5 - i * 0.35,
				"Wood",
				wood,
				"Cylinder"
			)
			trunk.roll = 84 + i * 3
		end
		-- Flattened ellipsoid lobes in three tiers: dark wide base, lighter small top, plus one
		-- offset side cluster that breaks the round silhouette.
		for i = 1, if kind == "conifer" then 4 else 9 do
			local tier = if i <= 4 then 1 elseif i <= 7 then 2 else 3
			local a, s = i * 2.4 + rng:nextNumber() * 0.6, (9 - tier * 1.8) * (0.75 + rng:nextNumber() * 0.4)
			local r = if i == 4 then 6 else ({ 3.8, 2.6, 1.2 })[tier]
			local crown = piece(
				"canopy" .. i,
				if kind == "conifer" then 0 else 1.3 + math.cos(a) * r,
				if kind == "conifer"
					then 10 + i * 2.4
					else 9.5 + tier * 2.3 + rng:nextNumber() - (if i == 4 then 2 else 0),
				if kind == "conifer" then 0 else math.sin(a) * r,
				if kind == "conifer" then 19 - i * 3 else s,
				if kind == "conifer" then 5 else s * (0.55 + rng:nextNumber() * 0.2),
				if kind == "conifer" then 17 - i * 2.5 else s * (0.8 + rng:nextNumber() * 0.2),
				if i % 3 == 0 then "LeafyGrass" else "Grass",
				leaf(tier * 16 - 24),
				if kind == "conifer" then "Wedge" else nil
			)
			-- Tree lobes are blocks rendered through a sphere mesh, so they keep flattened sizes.
			crown.yaw, crown.ellipsoid = i * 37 + rng:nextInteger(-15, 15), kind == "tree" or nil
		end
		for i = 1, 2 do
			local root =
				piece("root" .. i, math.cos(i * 2) * 1.5, 0.7, math.sin(i * 2) * 1.5, 4, 1.4, 1.2, "Wood", wood)
			root.yaw, root.roll = math.deg(i * 2), 12
		end
	elseif kind == "palm" then
		for i = 1, 4 do
			local trunk = piece(
				"trunk" .. i,
				(i / 4) ^ 2 * 3,
				i * 3.75 - 1.9,
				0,
				4.3,
				1.8 - i * 0.15,
				1.8 - i * 0.15,
				"Wood",
				wood,
				"Cylinder"
			)
			trunk.roll = 90 - i * 4.5
		end
		piece("crown", 3, 15.4, 0, 1.6, 1.6, 1.6, "Wood", { 92, 70, 42 }, "Ball")
		-- Each frond is two drooping, narrowing segments; each segment is a pair of mirrored
		-- wedges whose slopes fall away from the midrib, so leaflets hang in a shallow tent.
		for i = 0, 6 do
			local angle = i * math.pi * 2 / 7 + rng:nextNumber() * 0.4
			local x, y, droop = 0, 0, rng:nextInteger(0, 10)
			local sx, sz = -math.sin(angle), math.cos(angle)
			for tier = 1, 2 do
				local length, pitch, w = 4 - tier * 0.6, math.rad(8 - droop - tier * 26), 1.3 - tier * 0.45
				local cx, cy = x + math.cos(pitch) * length / 2, y + math.sin(pitch) * length / 2
				for side = -1, 1, 2 do
					local frond = piece(
						"frond" .. i .. "." .. tier .. side,
						3 + math.cos(angle) * cx + side * sx * w / 2,
						15.6 + cy,
						math.sin(angle) * cx + side * sz * w / 2,
						length,
						0.55 - tier * 0.15,
						w,
						if side > 0 then "LeafyGrass" else "Grass",
						leaf(tier * 10 + side * 6),
						"Wedge"
					)
					-- A wedge is tallest at local +Z; the mirrored half turns 180 degrees.
					frond.yaw, frond.roll = -math.deg(angle) + (if side < 0 then 0 else 180), side * -math.deg(pitch)
				end
				x, y = x + math.cos(pitch) * length, y + math.sin(pitch) * length
			end
		end
	elseif kind == "fern" or kind == "cycad" or kind == "grass" or kind == "horsetail" or kind == "bush" then
		local tall = kind == "cycad" or kind == "horsetail"
		if tall then
			piece("stem", 0, 1.5, 0, 3, 0.8, 0.8, "Wood", wood, "Cylinder").roll = 90
		end
		for i = 0, 5 do
			local s = 2.3 + rng:nextNumber() * 1.3
			local value = piece(
				"leaf" .. i,
				math.cos(i * math.pi / 3) * 1.5,
				if tall then 3 elseif kind == "bush" then s / 2 - 0.3 else 0.2,
				math.sin(i * math.pi / 3) * 1.5,
				if kind == "bush" then s else 0.3,
				if kind == "bush" then s else 0.35,
				if kind == "bush" then s else 3.6 + rng:nextNumber(),
				if i % 2 == 0 then "Grass" else "LeafyGrass",
				leaf(8),
				if kind == "bush" then "Ball" else "Wedge"
			)
			value.yaw, value.roll =
				i * 60 + rng:nextInteger(-14, 14),
				if kind == "bush" then 0 elseif kind == "grass" or kind == "horsetail" then 65 else 24
		end
	elseif kind == "rock" then
		-- A tilted core block hidden behind outward-sloping wedge bevels, so no flat cube face
		-- meets the eye; the exposed core top carries a muted moss tone. Bases sink below grade.
		local stone = {
			(palette.rock[1] + 118) // 2,
			(palette.rock[2] + 114) // 2,
			(palette.rock[3] + 104) // 2,
		}
		local turn = rng:nextNumber() * math.pi * 2
		for i = 1, 5 do
			local tone, a = rng:nextInteger(-12, 12), turn + i * 1.57
			local sx, sy = if i == 1 then 4.2 else 2.8, if i == 1 then 3.4 else 2.2 + rng:nextNumber()
			local roll = if i == 1 then rng:nextInteger(-14, 14) else 0
			local height = math.abs(math.sin(math.rad(roll))) * sx + math.abs(math.cos(math.rad(roll))) * sy
			local rock = piece(
				"rock" .. i,
				if i == 1 then 0 else math.cos(a) * 2.2,
				height / 2 - 0.5,
				if i == 1 then 0 else math.sin(a) * 2.2,
				sx,
				sy,
				if i == 1 then 3.6 else 2 + rng:nextNumber(),
				if i % 2 == 0 then "Slate" else "Rock",
				if i == 1
					then { stone[1] - 4 + tone, stone[2] + 6 + tone, stone[3] - 14 + tone }
					else { stone[1] + tone, stone[2] + tone, stone[3] + tone },
				if i == 1 then nil else "Wedge"
			)
			-- A wedge's tall face is local +Z: turn it to the core so the slope faces outward.
			rock.yaw, rock.roll =
				if i == 1 then math.deg(turn) + 45 else math.deg(math.atan2(-math.cos(a), -math.sin(a))), roll
		end
	elseif kind == "campfire" then
		for i = 1, 8 do
			local angle = i * math.pi / 4
			piece(
				"ring" .. i,
				math.cos(angle) * 2.6,
				0.5,
				math.sin(angle) * 2.6,
				1.5,
				1.1,
				1.3,
				"Slate",
				palette.rock,
				"Ball"
			)
		end
		for i = 1, 2 do
			local log = piece("log" .. i, 0, 0.5, 0, 5, 1, 1, "Wood", wood, "Cylinder")
			log.yaw = i * 90
		end
		local ember = piece("embers", 0, 1, 0, 2.5, 0.5, 2.5, "Neon", { 255, 106, 24 })
		ember.effect = "fire"
	elseif kind == "chest" then
		for level = 0, 1 do
			local x = level * 1.3
			piece("basket" .. level, x, 1.2 + level * 2.5, 0, 3.5, 2.4, 2.8, "Fabric", wood)
			piece("lid" .. level, x, 2.5 + level * 2.5, 0, 3.8, 0.25, 3, "WoodPlanks", sand)
			for band = 1, 3 do
				piece("weave" .. level .. band, x, level * 2.5 + band * 0.65, 0, 3.65, 0.15, 2.95, "Fabric", sand)
			end
			for _, side in { -1, 1 } do
				piece("rope" .. level .. side, x + side, 1.3 + level * 2.5, 0, 0.15, 2.7, 3.05, "Fabric", sand)
			end
		end
	elseif kind == "farm" then
		piece("soil", 0, 0.2, 0, 12, 0.5, 10, "Ground", { 76, 54, 34 })
		for i = 1, 3 do
			piece("row" .. i, (i - 2) * 3, 0.5, 0, 1, 0.5, 9, "Ground", wood)
			for j = 1, 3 do
				local shoot =
					piece("shoot" .. i .. j, (i - 2) * 3, 1.3, (j - 2) * 3, 2, 1.7, 0.5, "Grass", palette.leaf)
				shoot.roll = 25
			end
		end
	elseif kind == "dock" then
		for i = 1, 7 do
			piece("plank" .. i, 0, 0, (i - 4) * 2, 12, 0.4, 1.8, "WoodPlanks", wood)
		end
		for _, x in { -5, 5 } do
			for _, z in { -6, 6 } do
				piece("post" .. x .. "." .. z, x, 1, z, 0.8, 7, 0.8, "Wood", wood)
			end
		end
		piece("mast", 7, 6, 0, 0.7, 12, 0.7, "Wood", wood)
		piece("sail", 7, 9, 0, 0.3, 4, 5, "Fabric", sand)
	elseif kind == "shelter" then
		for _, x in { -4, 4 } do
			for _, z in { -3, 3 } do
				piece("post" .. x .. "." .. z, x, 1.5, z, 3.2, 0.85, 0.85, "Wood", wood, "Cylinder").roll = 90
				local rafter =
					piece("rafter" .. x .. "." .. z, x / 2, 4.8, z, 6.4, 0.45, 0.45, "Wood", wood, "Cylinder")
				rafter.roll = if x < 0 then 51 else -51
				for band = 1, 3 do
					piece(
						"lash" .. x .. "." .. z .. "." .. band,
						x,
						2.5 + band * 0.16,
						z,
						1.03,
						0.12,
						1.03,
						"Fabric",
						sand
					)
				end
			end
		end
		for _, side in { -1, 1 } do
			for course = 1, 4 do
				for strip = 1, 5 do
					local x = course * 0.95 - 0.45
					local roof = piece(
						"roof" .. side .. "." .. course .. "." .. strip,
						side * x,
						7.2 - x * 1.22,
						(strip - 3) * 1.5,
						1.7,
						0.28,
						1.75,
						"Grass",
						{ 143 + strip * 8, 116 + course * 8, 63 + strip * 4 },
						"Wedge"
					)
					roof.roll = side * -51
				end
			end
			piece("skirt" .. side, side * 4, 0.3, 0, 0.5, 0.5, 8, "Grass", sand)
		end
		piece("ridge", 0, 7.3, 0, 8.8, 0.55, 0.55, "Wood", wood, "Cylinder").yaw = 90
		piece("hide.back", 0, 1.6, 3, 7.8, 3.2, 0.2, "Fabric", { 150, 116, 75 })
		piece("hide.side", -3.9, 1.5, 0, 0.2, 3, 5, "Fabric", { 169, 137, 91 })
		piece("bedroll", 2, 0.3, 0, 3, 0.6, 6, "Fabric", palette.leaf)
	elseif kind == "workbench" or kind == "drying-rack" then
		for _, x in { -3, 3 } do
			piece("leg" .. x, x, 2.5, 0, 5, 0.7, 0.7, "Wood", wood, "Cylinder").roll = 90
			for band = 1, 3 do
				piece("lash" .. x .. "." .. band, x, 2.7 + band * 0.16, 0, 0.92, 0.13, 0.92, "Fabric", sand)
			end
			if kind == "workbench" then
				piece("foot" .. x, x, 0.35, 0, 4, 0.7, 0.7, "Wood", wood, "Cylinder").yaw = 90
			end
		end
		piece("beam", 0, if kind == "drying-rack" then 5 else 2.85, 0, 8, 0.8, 0.8, "Wood", wood, "Cylinder")
		if kind == "drying-rack" then
			for i = 1, 3 do
				piece("hide" .. i, (i - 2) * 2, 3.7, 0, 1.7, 2.6, 0.2, "Fabric", { 151, 107 + i * 8, 71 }, "Ball")
			end
		else
			for i = 1, 4 do
				piece("plank" .. i, 0, 3.2, (i - 2.5) * 0.9, 7.5, 0.5, 0.85, "WoodPlanks", wood)
			end
			piece("tool", 1, 3.7, 0, 1.2, 0.6, 2, "Slate", palette.rock, "Wedge")
		end
	elseif kind == "beacon" then
		-- Wayfinding signpost on a small stone cairn.
		for i = 1, 3 do
			piece(
				"foot" .. i,
				math.cos(i * 2.1) * 0.9,
				0.5,
				math.sin(i * 2.1) * 0.9,
				1.8,
				1.3,
				1.6,
				"Rock",
				palette.rock
			).yaw = i
				* 50
		end
		piece("shaft", 0, 3.5, 0, 7, 0.6, 0.6, "Wood", wood, "Cylinder").roll = 90
		piece("sign", 1.4, 5.6, 0, 3.4, 1.2, 0.25, "WoodPlanks", { 196, 158, 102 }).yaw = 8
		piece("sign2", -1.1, 4.4, 0, 2.8, 1, 0.25, "WoodPlanks", { 178, 140, 90 }).yaw = -20
		piece("flag", 0.8, 6.9, 0, 1.4, 0.9, 0.12, "Fabric", { 235, 193, 106 })
	elseif kind == "fence" then
		for x = -3, 3, 2 do
			piece("post" .. x, x, 2.2, 0, 4.5, 0.8, 0.8, "Wood", wood, "Cylinder").roll = 90
			piece("tip" .. x, x, 4.7, 0, 0.8, 0.8, 0.8, "Wood", sand, "Wedge")
		end
		for _, y in { 1.2, 2.8 } do
			piece("rail" .. y, 0, y, 0, 8, 0.4, 0.4, "Wood", wood)
		end
	elseif string.find(kind, "floor", 1, true) then
		for i = 1, 6 do
			piece("board" .. i, (i - 3.5) * 1.3, 0.3, 0, 1.2, 0.6, 8, "WoodPlanks", wood)
		end
		for _, z in { -3, 3 } do
			piece("joist" .. z, 0, 0.7, z, 8, 0.4, 0.6, "Wood", wood)
		end
	elseif string.find(kind, "wall", 1, true) or kind == "door" then
		for i = 1, 6 do
			if kind ~= "door" or i == 1 or i == 6 then
				piece("board" .. i, (i - 3.5) * 1.3, 3, 0, 1.2, 6, 0.5, "WoodPlanks", wood)
			end
		end
		piece("lintel", 0, 6, 0, 8, 0.6, 0.8, "Wood", wood)
	elseif string.find(kind, "roof", 1, true) then
		for _, side in { -1, 1 } do
			piece("slope" .. side, side * 2, 2, 0, 5.6, 0.5, 8, "Grass", sand).roll = side * -45
		end
		piece("ridge", 0, 4, 0, 0.5, 0.5, 8, "Wood", wood)
	elseif kind == "stairs" then
		for i = 1, 6 do
			piece("step" .. i, 0, i * 0.7, (i - 3.5) * 1.3, 6, 0.7, 1.3, "WoodPlanks", wood)
		end
	elseif kind == "pillar" then
		piece("post", 0, 3, 0, 1, 6, 1, "Wood", wood)
		piece("cap", 0, 6, 0, 2, 0.5, 2, "Wood", sand)
	elseif kind == "well" or kind == "kiln" or kind == "mud-kiln" then
		for i = 1, 10 do
			local angle = i * math.pi / 5
			piece(
				"stone" .. i,
				math.cos(angle) * 2,
				1.5,
				math.sin(angle) * 2,
				1.5,
				3,
				1.5,
				"Slate",
				palette.rock,
				"Ball"
			)
		end
		if kind ~= "well" then
			piece("coals", 0, 0.6, 0, 2, 0.4, 2, "Neon", { 255, 106, 24 }).effect = "fire"
		end
	elseif kind == "bed" then
		piece("frame", 0, 0.5, 0, 4, 1, 7, "Wood", wood)
		piece("blanket", 0, 1.2, 0, 3.7, 0.5, 6.5, "Fabric", palette.leaf)
		piece("pillow", 0, 1.6, -2, 3, 0.5, 1.5, "Fabric", sand)
	end
end

-- The same kit is cloned for authored structures, committed builds and ghosts.
function M.structure(parent: any, definition: any, cellStuds: number): any
	local env: any = getfenv()
	local Instance, Vector3, CFrame, Color3, Enum = env.Instance, env.Vector3, env.CFrame, env.Color3, env.Enum
	local kind = definition.id
	local aliases = {
		storage = "chest",
		tent = "shelter",
		["clan-hall"] = "shelter",
		["joiner-bench"] = "workbench",
		["mason-bench"] = "workbench",
		laboratory = "workbench",
		["tanning-frame"] = "drying-rack",
		["animal-pen"] = "fence",
		["signal-relay"] = "beacon",
		refrigerator = "chest",
	}
	local parts = {}
	M.kit(parts, kind, { x = 0, y = 0, z = 0 }, aliases[kind] or kind, palettes.grassland)
	assert(#parts > 1, "STRUCTURE_KIT_MISSING:" .. kind)
	local halfX, halfZ = 0, 0
	for _, d in parts do
		local yaw, roll = math.rad(d.yaw or 0), math.rad(d.roll or 0)
		local sx = math.abs(math.cos(roll)) * d.size.x + math.abs(math.sin(roll)) * d.size.y
		halfX = math.max(
			halfX,
			math.abs(d.position.x) + (math.abs(math.cos(yaw)) * sx + math.abs(math.sin(yaw)) * d.size.z) / 2
		)
		halfZ = math.max(
			halfZ,
			math.abs(d.position.z) + (math.abs(math.sin(yaw)) * sx + math.abs(math.cos(yaw)) * d.size.z) / 2
		)
	end
	local sx, sz = definition.footprintX * cellStuds / (2 * halfX), definition.footprintZ * cellStuds / (2 * halfZ)
	local sy = math.min(sx, sz)
	local model = Instance.new("Model")
	model.Name = kind
	for _, d in parts do
		local value = Instance.new(if d.shape == "Wedge" then "WedgePart" else "Part")
		value.Name, value.Anchored = d.id, true
		value.Size = Vector3.new(d.size.x * sx, d.size.y * sy, d.size.z * sz)
		value.CFrame = CFrame.new(d.position.x * sx, d.position.y * sy, d.position.z * sz)
			* CFrame.Angles(0, math.rad(d.yaw or 0), math.rad(d.roll or 0))
		value.Color, value.Material = Color3.fromRGB(table.unpack(d.color)), Enum.Material[d.material]
		if d.shape and d.shape ~= "Wedge" then
			value.Shape = Enum.PartType[d.shape]
		end
		value.CanTouch, value.Parent = false, model
		if d.effect == "fire" then
			local fire, light = Instance.new("Fire"), Instance.new("PointLight")
			fire.Size, fire.Heat, fire.Parent = 2, 4, value
			light.Color, light.Range, light.Brightness, light.Parent = value.Color, 10, 0.8, value
		end
	end
	model.WorldPivot = CFrame.new()
	model.Parent = parent
	return model
end

function M.palette(layout: any): any
	return if table.find(layout.biomes, "volcano")
		then palettes.volcano
		else palettes[layout.biomes[1]] or palettes.grassland
end

function M.plan(layout: any, columns: { any }, terrain: any): any
	local palette = M.palette(layout)
	local parts: { any } = {}
	local props: { any } = {}
	local stride = math.max(1, math.ceil(#columns / 120))
	for index, column in columns do
		if
			index % stride == 0
			and #props < 16
			and column.top > 0
			and not terrain.protected(layout, column.x, column.z, 16)
		then
			local kind = if #props % 3 == 0
				then "rock"
				elseif table.find(layout.biomes, "volcano") or layout.biomes[1] == "desert" then "rock"
				elseif
					layout.id == "rw.onboarding"
					or layout.biomes[1] == "tropical"
					or layout.biomes[1] == "swamp"
				then "palm"
				elseif layout.biomes[1] == "snow" then "conifer"
				else "tree"
			local p = { x = column.x, y = column.top, z = column.z }
			local spaced = true
			for _, other in props do
				if (p.x - other.position.x) ^ 2 + (p.z - other.position.z) ^ 2 < 22 ^ 2 then
					spaced = false
				end
			end
			if not spaced then
				continue
			end
			table.insert(props, { position = p, kind = kind })
			local start = #parts + 1
			M.kit(parts, "biome." .. #props, p, kind, palette)
			for n = start, #parts do
				local value = parts[n]
				local angle = index * 2.399963
				local dx, dz = value.position.x - p.x, value.position.z - p.z
				local scale = 0.75 + (index % 5) * 0.1
				value.position.x = p.x + (dx * math.cos(angle) - dz * math.sin(angle)) * scale
				value.position.z = p.z + (dx * math.sin(angle) + dz * math.cos(angle)) * scale
				value.position.y = p.y + (value.position.y - p.y) * scale
				value.size = { x = value.size.x * scale, y = value.size.y * scale, z = value.size.z * scale }
				value.yaw = (value.yaw or 0) + math.deg(angle)
				value.color = {
					math.clamp(value.color[1] + index % 13 - 6, 0, 255),
					math.clamp(value.color[2] + index % 17 - 8, 0, 255),
					value.color[3],
				}
			end
			if kind ~= "rock" then
				local understory = ({ "fern", "cycad", "grass", "horsetail", "bush" })[#props % 5 + 1]
				if not terrain.protected(layout, p.x + 8, p.z + 5, 6) then
					M.kit(parts, "understory." .. #props, { x = p.x + 8, y = p.y, z = p.z + 5 }, understory, palette)
				end
			end
		end
	end
	for _, anchor in layout.anchors do
		local p = anchor.position
		if anchor.id == "entry" or anchor.id == "exit" then
			M.kit(parts, anchor.id, p, "dock", palette)
			M.kit(parts, anchor.id .. ".return", { x = p.x + 12, y = p.y, z = p.z }, "beacon", palette)
		elseif anchor.id == "objective" then
			M.kit(parts, "objective", { x = p.x + 18, y = p.y, z = p.z }, "beacon", palette)
		elseif string.find(anchor.id, "refuge", 1, true) then
			M.kit(parts, anchor.id, p, "shelter", palette)
		end
	end
	if layout.id == "rw.onboarding" then
		for _, anchor in layout.anchors do
			if anchor.id == "entry" then
				M.kit(
					parts,
					"arrival.camp",
					{ x = anchor.position.x + 20, y = anchor.position.y, z = anchor.position.z - 12 },
					"shelter",
					palette
				)
				M.kit(
					parts,
					"arrival.fire",
					{ x = anchor.position.x + 12, y = anchor.position.y, z = anchor.position.z - 10 },
					"campfire",
					palette
				)
			end
		end
	end
	-- Optional authored art metadata is projected by content codegen, like anchors.
	-- Never re-transform its positions here.
	if layout.art then
		local art = layout.art
		local p = art.landmark.position
		local size = art.landmark.size
		local base = add(
			parts,
			art.landmark.id .. ".base",
			{ x = p.x, y = p.y + size.y / 2, z = p.z },
			size,
			"Rock",
			palette.rock
		)
		base.shape = "Ball"
		base.ground = p
		M.kit(
			parts,
			art.landmark.id .. ".crown",
			{ x = p.x + size.x * 0.7 + 6, y = p.y, z = p.z },
			if art.landmark.kind == "tree" then "tree" else "beacon",
			palette
		)
	end
	for _, refuge in layout.refuges do
		local a, b = refuge.bounds.min, refuge.bounds.max
		M.kit(parts, refuge.id, { x = (a.x + b.x) / 2, y = a.y, z = (a.z + b.z) / 2 }, "shelter", palette)
	end
	for _, hazard in layout.hazards do
		if hazard.kind == "lava" or hazard.kind == "hot-spring" then
			local surface = add(
				parts,
				hazard.id .. ".surface",
				{ x = hazard.position.x, y = hazard.position.y + 0.1, z = hazard.position.z },
				{ x = hazard.radius * 2, y = 0.4, z = hazard.radius * 2 },
				if hazard.kind == "lava" then "Neon" else "Glass",
				if hazard.kind == "lava" then { 232, 112, 41 } else { 108, 192, 191 },
				"Ball"
			)
			surface.effect = if hazard.kind == "lava" then "lava" else "steam"
			for i = 1, 8 do
				local angle = i * math.pi / 4
				M.kit(parts, hazard.id .. ".rim" .. i, {
					x = hazard.position.x + math.cos(angle) * hazard.radius,
					y = hazard.position.y - 1,
					z = hazard.position.z + math.sin(angle) * hazard.radius,
				}, "rock", palette)
			end
		end
	end
	if table.find(layout.biomes, "volcano") then
		local center = layout.anchors[1].position
		for i = 1, 4 do
			local flow = add(
				parts,
				"lava.flow" .. i,
				{ x = center.x - 36 - i * 4, y = center.y + 1, z = center.z - i * 24 },
				{ x = 7, y = 1, z = 32 },
				"Neon",
				{ 255, 102, 18 }
			)
			flow.yaw, flow.effect = -12, "lava"
			M.kit(
				parts,
				"basalt." .. i,
				{ x = center.x - 52, y = center.y, z = center.z - i * 26 },
				"rock",
				palettes.volcano
			)
		end
		local vent = add(
			parts,
			"ash.vent",
			{ x = center.x - 58, y = center.y + 12, z = center.z - 100 },
			{ x = 8, y = 24, z = 8 },
			"Basalt",
			palettes.volcano.rock
		)
		vent.effect = "ash"
		-- Distant offshore lava is scenery only; damaging lava stays at catalog volumes.
		local x = layout.bounds.min.x - 48
		for i = 1, 5 do
			add(
				parts,
				"offshore.ash" .. i,
				{ x = x, y = 3 + i * 3, z = (i - 3) * 36 },
				{ x = 72 - i * 8, y = 12 + i * 6, z = 50 },
				"Basalt",
				{ 58, 62, 65 },
				"Ball"
			)
			add(
				parts,
				"offshore.lava" .. i,
				{ x = x + 12, y = 10 + i * 3, z = (i - 3) * 36 },
				{ x = 3, y = 0.8, z = 42 },
				"Neon",
				{ 232, 112, 41 }
			)
		end
	end
	assert(#parts <= 768, "WORLD_DRESSING_PART_BUDGET")
	return { parts = parts, props = props, palette = palette }
end

function M.resource(item: any): string
	local id = item.id
	if id == "water" then
		return "water"
	elseif string.find(id, "wood", 1, true) or id == "branch" or id == "bark" or id == "twig" then
		return "wood"
	elseif id == "fiber" or id == "leaf" or id == "grass" or id == "reed" or string.find(id, "seed", 1, true) then
		return "plant"
	elseif item.category == "food" then
		return "food"
	else
		return "mineral"
	end
end

function M.home(parts: { any }, home: any, rules: any)
	local palette = palettes.grassland
	local half = rules.landSizes[home.landRank] / 2
	for _, z in { -half + 3, half - 3 } do
		for x = -half + 8, half - 8, 8 do
			-- Leave a wide entrance in both fences, never seal the travel dock.
			if math.abs(x) > 12 then
				M.kit(parts, "home.fence." .. x .. "." .. z, { x = x, y = 1, z = z }, "fence", palette)
			end
		end
	end
	M.kit(parts, "home.shelter", { x = -half + 12, y = 1, z = -half + 12 }, "shelter", palette)
	M.kit(parts, "home.dock", home.dock, "dock", palette)
	M.kit(parts, "home.fire", { x = -8, y = 1, z = 4 }, "campfire", palette)
	M.kit(parts, "home.workbench", { x = -14, y = 1, z = 10 }, "workbench", palette)
	M.kit(parts, "home.rack", { x = -20, y = 1, z = 4 }, "drying-rack", palette)
	M.kit(parts, "home.storage", { x = -half + 17, y = 1, z = -half + 19 }, "chest", palette)
	M.kit(parts, "home.farm", { x = half - 12, y = 1, z = -half + 14 }, "farm", palette)
	add(parts, "home.path", { x = 0, y = 1.05, z = 0 }, { x = 7, y = 0.2, z = half * 2 }, "Ground", { 167, 142, 98 })
	-- Palms stay on the east coast, clear of the camp.
	for i = 1, 4 do
		local a = math.rad(i * 20 - 40)
		M.kit(parts, "home.tree" .. i, { x = math.cos(a) * half, y = 0, z = math.sin(a) * half }, "palm", palette)
	end
end

return M
