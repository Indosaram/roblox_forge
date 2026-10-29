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
	grassland = { ground = "Grass", leaf = { 82, 114, 71 }, rock = { 110, 117, 103 }, fog = { 206, 208, 188 } },
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
		-- Kit identity: RoleWorld swaps a whole kit for its B3 mesh row (StructureMeshes.DRESSING).
		value.kit, value.kitKind = id, kind
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
		-- Chain each segment from the previous end along its own leaning axis.
		local tx, ty = 0, 0
		for i = 1, 4 do
			local r = math.rad(90 - i * 4.5)
			local trunk = piece(
				"trunk" .. i,
				tx + math.cos(r) * 2,
				ty + math.sin(r) * 2,
				0,
				4,
				1.8 - i * 0.15,
				1.8 - i * 0.15,
				"Wood",
				wood,
				"Cylinder"
			)
			trunk.roll = 90 - i * 4.5
			tx, ty = tx + math.cos(r) * 4, ty + math.sin(r) * 4
		end
		piece("crown", tx, ty + 0.6, 0, 1.6, 1.6, 1.6, "Wood", { 92, 70, 42 }, "Ball")
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
						tx + math.cos(angle) * cx + side * sx * w / 2,
						ty + 0.6 + cy,
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
	elseif kind == "house" then
		-- Saltmeadow cottage (front = local -Z): plank walls on a stone footing, steep thatch,
		-- a lit door lantern and warm windows so the town reads at night.
		piece("footing", 0, 0.4, 0, 11, 0.8, 9, "Slate", palette.rock)
		piece("walls", 0, 3.8, 0, 10, 6, 8, "WoodPlanks", { 150, 110, 70 })
		piece("gable", 0, 7.9, 0, 9, 2.2, 7.6, "WoodPlanks", { 138, 100, 62 })
		for _, side in { -1, 1 } do
			piece("thatch" .. side, side * 2.95, 8.85, 0, 7.2, 0.6, 10.4, "Grass", { 176, 146, 94 }).roll = side * -35
			piece("window" .. side, side * 3, 4.2, -4.05, 1.6, 1.4, 0.2, "Neon", { 214, 170, 104 })
		end
		piece("ridge", 0, 11, 0, 0.6, 0.6, 10.6, "Wood", wood)
		piece("door", 0, 2.8, -4.05, 2.2, 4, 0.3, "Wood", wood)
		piece("chimney", 3, 10, 2, 1.2, 3, 1.2, "Slate", palette.rock)
		piece("lantern", 1.8, 4.6, -4.5, 0.6, 0.8, 0.6, "Neon", { 255, 150, 70 }).effect = "lamp"
	elseif kind == "workshop" then
		-- Open timber shed: workbench, anvil, forge coals and a log pile under a pent roof.
		for _, x in { -5, 5 } do
			for _, z in { -4, 4 } do
				piece("post" .. x .. "." .. z, x, 3, z, 0.8, 6, 0.8, "Wood", wood)
			end
		end
		piece("roof", 0, 6.4, 0, 11.5, 0.5, 9.5, "WoodPlanks", sand).roll = 8
		piece("bench", 0, 1.6, 1.5, 6, 0.6, 2.2, "WoodPlanks", { 150, 110, 70 })
		piece("benchbase", 0, 0.7, 1.5, 5.4, 1.2, 1.8, "Wood", wood)
		piece("anvil", -3, 1, -1.5, 1.6, 1.2, 1, "Slate", { 70, 70, 72 })
		piece("forge", -3.5, 1.2, 2.5, 2, 1.4, 2, "Slate", palette.rock)
		piece("coals", -3.5, 2, 2.5, 1.4, 0.3, 1.4, "Neon", { 255, 106, 24 }).effect = "fire"
		for i = 1, 3 do
			piece("log" .. i, 3.5, 0.5 + (i - 1) * 0.85, -2 + (i % 2) * 0.4, 4, 0.9, 0.9, "Wood", wood, "Cylinder")
		end
		piece("lantern", 4.6, 4.5, -3.6, 0.6, 0.8, 0.6, "Neon", { 255, 150, 70 }).effect = "lamp"
	elseif kind == "market" then
		-- Market stall (B3 town.market-stall when loaded): counter, striped awning, crates.
		piece("counter", 0, 1.2, -1.4, 6, 2.4, 1.6, "WoodPlanks", { 150, 110, 70 })
		for _, x in { -3, 3 } do
			for _, z in { -2, 2 } do
				piece("post" .. x .. "." .. z, x, 2.6, z, 0.4, 5.2, 0.4, "Wood", wood)
			end
		end
		for i = 1, 4 do
			piece(
				"awning" .. i,
				(i - 2.5) * 1.6,
				5.4,
				0,
				1.6,
				0.3,
				5.2,
				"Fabric",
				if i % 2 == 0 then { 222, 214, 190 } else { 58, 112, 128 }
			)
		end
		piece("crate1", -1.6, 2.9, -1.4, 1.4, 1, 1.2, "WoodPlanks", sand)
		piece("crate2", 1.4, 0.8, 1.2, 1.6, 1.6, 1.6, "WoodPlanks", sand)
		piece("lantern", 3, 4.4, -2.4, 0.6, 0.8, 0.6, "Neon", { 255, 150, 70 }).effect = "lamp"
	elseif kind == "quest-board" then
		-- Notice board (B3 town.notice-board when loaded) with pinned quest notes.
		for _, x in { -2.4, 2.4 } do
			piece("post" .. x, x, 3.1, 0, 0.4, 6.2, 0.4, "Wood", wood)
		end
		piece("board", 0, 3.6, 0, 4.6, 3, 0.3, "WoodPlanks", { 150, 110, 70 })
		for i = 1, 3 do
			piece("note" .. i, (i - 2) * 1.4, 3.4 + (i % 2) * 0.6, -0.2, 0.9, 1.1, 0.05, "Fabric", sand)
		end
		for _, side in { -1, 1 } do
			piece("hood" .. side, side * 1.4, 6.5, 0, 3.2, 0.25, 1.6, "WoodPlanks", wood).roll = side * -25
		end
	elseif kind == "torch" then
		piece("pole", 0, 2.5, 0, 0.5, 5, 0.5, "Wood", { 96, 66, 40 })
		piece("head", 0, 5.3, 0, 0.9, 0.7, 0.9, "Neon", { 255, 132, 40 }).effect = "fire"
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
		["workbench-t2"] = "workbench",
		["workbench-t3"] = "workbench",
		["kiln-t2"] = "kiln",
		["kiln-t3"] = "kiln",
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

-- Archipelago arrival point: on the main trail 32 studs short of the resource yard.
-- `forward` is the unit XZ direction from that point toward the yard.
function M.trailhead(layout: any): any?
	if not string.match(layout.id, "^rw%.a%d+%.s%d+$") then
		return nil
	end
	for _, path in layout.paths do
		if string.sub(path.id, -5) == ".main" then
			local yard, before = path.points[3], path.points[2]
			local dx, dz = before.x - yard.x, before.z - yard.z
			local length = math.sqrt(dx * dx + dz * dz)
			return {
				position = { x = yard.x + dx / length * 32, y = yard.y, z = yard.z + dz / length * 32 },
				forward = { x = -dx / length, z = -dz / length },
			}
		end
	end
	return nil
end

-- C7 drift-isle camp beside the arrival trail: { along, side } from the trailhead. The three
-- spots stay clear of trails, gather nodes and the arrival dressing on every archipelago stage
-- (sea-chart.spec). RoleWorld builds them as single parts outside the dressing part budget.
M.DRIFT_CAMP = table.freeze({ fire = { 28, 28 }, tent = { 28, 40 }, rift = { 16, 44 } } :: { [string]: { number } })

function M.driftCamp(layout: any): any?
	local head = M.trailhead(layout)
	if not head then
		return nil
	end
	local s, f = head.position, head.forward
	local camp: any = { yaw = math.deg(math.atan2(-f.x, -f.z)) }
	for key, spot in M.DRIFT_CAMP do
		camp[key] = { x = s.x + f.x * spot[1] - f.z * spot[2], y = s.y, z = s.z + f.z * spot[1] + f.x * spot[2] }
	end
	return camp
end

-- Passive, biome-plausible silhouettes for the arrival view; never interactive wildlife.
local fauna: any = {
	grassland = "dodo",
	forest = "deer",
	tropical = "turtle",
	swamp = "turtle",
	desert = "gallimimus",
	snow = "mammoth",
	volcano = "turtle",
}

-- Arrival dressing: a landmark, rock outcrops, tree clusters and one grazing creature
-- framed around the trail, so the spawn camera never faces an empty field.
function M.arrival(parts: { any }, layout: any, palette: any): { any }
	local head = M.trailhead(layout)
	if not head then
		return {}
	end
	local s, f = head.position, head.forward
	local function at(along: number, side: number): any
		return { x = s.x + f.x * along - f.z * side, y = s.y, z = s.z + f.z * along + f.x * side }
	end
	-- The wayfinding sign is the arrival landmark; vegetation around it is the B1 scatter plus the
	-- mesh grove (plan), never primitive outcrops or tree clusters.
	M.kit(parts, "trailhead.landmark", at(14, 15), "beacon", palette)
	local species = if table.find(layout.biomes, "volcano") then fauna.volcano else fauna[layout.biomes[1]]
	return { { id = "trailhead.grazer", species = species or "dodo", position = at(22, -34) } }
end

-- D2 (R13, Durango town): Saltmeadow buildings around the road cross, clear of the roads, the
-- plaza anchors, the plots and the B3 set pieces. `yaw` turns the kit front (local -Z) to face its
-- road. Every kind has a B3/L5 row (StructureMeshes.DRESSING); RoleWorld picks the house variant
-- per seed (StructureMeshes.house): `lot = "large"` lots take the longhouse, the rest a cottage.
-- The composed parts are the load-failure fallback only.
M.TOWN = table.freeze({
	{ id = "town.house.1", kind = "house", x = -44, z = -40, yaw = 90 },
	{ id = "town.house.2", kind = "house", x = 44, z = -40, yaw = -90 },
	{ id = "town.house.3", kind = "house", x = -44, z = -160, yaw = 90 },
	{ id = "town.house.4", kind = "house", x = 44, z = -160, yaw = -90 },
	{ id = "town.house.5", kind = "house", x = -44, z = -280, yaw = 90 },
	{ id = "town.house.6", kind = "house", x = 44, z = -280, yaw = -90 },
	{ id = "town.house.7", kind = "house", x = -44, z = 400, yaw = 90 },
	{ id = "town.house.8", kind = "house", x = 44, z = 460, yaw = -90 },
	{ id = "town.house.9", kind = "house", x = -44, z = 520, yaw = 90 },
	{ id = "town.house.10", kind = "house", x = 44, z = 520, yaw = -90 },
	{ id = "town.house.11", kind = "house", x = -140, z = 72, yaw = 0 },
	{ id = "town.house.12", kind = "house", x = 140, z = 72, yaw = 0 },
	-- South-lane row (z = 32): longhouses on the two big lots north of the lane, cottages facing
	-- them across it.
	{ id = "town.house.13", kind = "house", x = -216, z = 76, yaw = 0, lot = "large" },
	{ id = "town.house.14", kind = "house", x = 216, z = 76, yaw = 0, lot = "large" },
	{ id = "town.house.15", kind = "house", x = -140, z = -12, yaw = 180 },
	{ id = "town.house.16", kind = "house", x = 140, z = -12, yaw = 180 },
	{ id = "town.market.1", kind = "market", x = -90, z = 170, yaw = 90 },
	{ id = "town.market.2", kind = "market", x = 90, z = 170, yaw = -90 },
	{ id = "town.workshop", kind = "workshop", x = 220, z = 380, yaw = -90 },
	{ id = "town.quest-board", kind = "quest-board", x = 30, z = 150, yaw = -90 },
	{ id = "town.dock", kind = "dock", x = -112, z = 700, yaw = 0 },
})

--- The town's buildings (`M.TOWN`) on rw.town, else none.
function M.town(layout: any): { any }
	return if layout.id == "rw.town" then M.TOWN :: any else {}
end

-- Turns kit parts [start, #parts] by `yaw` degrees about (x, z), like the scatter turn in plan.
local function turn(parts: { any }, start: number, x: number, z: number, yaw: number)
	local angle = math.rad(yaw)
	for n = start, #parts do
		local value = parts[n]
		local dx, dz = value.position.x - x, value.position.z - z
		value.position.x = x + dx * math.cos(angle) - dz * math.sin(angle)
		value.position.z = z + dx * math.sin(angle) + dz * math.cos(angle)
		value.yaw = (value.yaw or 0) - yaw
		-- A kit rendered as one B3 mesh row turns as a whole (RoleWorld dressing pass).
		value.kitYaw = -yaw
	end
end

-- B1 biome kits (BiomeKits.luau, shared). Resolved on first use: the production-worlds fixture
-- loads this module before it wires the shared BiomeKits table.
local biomeKits: any = nil
local function kits(): any
	if not biomeKits then
		biomeKits = load(
			if runtime.game
				then runtime.game
					:GetService("ReplicatedStorage")
					:WaitForChild("Forge").games["robango-island"].src.shared.BiomeKits
				else "../shared/BiomeKits"
		)
	end
	return biomeKits
end

-- Hero B1 rows per biome kit for authored landmarks, hazard rims and volcanic outcrops.
M.HERO_TREE = table.freeze({
	beach = "veg.beach.palm-tall",
	jungle = "veg.jungle.strangler",
	grassland = "veg.grassland.oak",
	savanna = "veg.savanna.flat-top",
	lake = "veg.lake.willow",
	swamp = "veg.swamp.cypress",
	desert = "veg.desert.dead-snag",
	tundra = "veg.tundra.snow-pine",
	volcano = "veg.volcano.charred",
} :: { [string]: string })
M.HERO_ROCK = table.freeze({
	beach = "rock.beach.tide-boulder",
	jungle = "rock.jungle.mossy-boulder",
	grassland = "rock.grassland.boulder-cluster",
	savanna = "rock.savanna.kopje-slab",
	lake = "rock.lake.river-stones",
	swamp = "rock.swamp.mud-stone",
	desert = "rock.desert.wind-boulder",
	tundra = "rock.tundra.ice-shard",
	volcano = "rock.volcano.obsidian-boulder",
} :: { [string]: string })
-- Mesh understory per arrival point (shrub, fern and grass rows of the local kit), so a spawn
-- screen keeps vegetation where the B1 scatter is thin (harbor streets, small brawl islands).
-- L10 (R03-3: 8-15 shrubs plus grass tufts, stones and litter around the arrival): 40 pieces over
-- seven rings, mixing low ground clutter (gravel, leaf litter) and small rocks into the plants.
M.GROVE = 40
M.GROVE_RINGS = { 14, 19, 24, 30, 36, 42, 50 }
M.GROVE_SPACING = 4.5

local function familyOf(kit: string, key: string): string
	for _, row in kits().kits[kit] do
		if row.key == key then
			return row.family
		end
	end
	error("WORLD_DRESSING_UNKNOWN_KIT_ROW:" .. key)
end

-- One B1 placement (BiomeKits.Placement plus an id); RoleWorld seats it on the rendered surface.
local function placement(id: string, kit: string, key: string, p: any, yaw: number, scale: number): any
	return {
		id = id,
		kit = kit,
		key = key,
		family = familyOf(kit, key),
		x = p.x,
		y = p.y,
		z = p.z,
		yaw = yaw,
		scale = scale,
	}
end

-- True when (x, z) is clear of every authored path ribbon by `margin` studs.
local function offPath(layout: any, terrain: any, x: number, z: number, margin: number): boolean
	for _, path in layout.paths do
		for j = 2, #path.points do
			if terrain.distance(x, z, path.points[j - 1], path.points[j]) <= path.width / 2 + margin then
				return false
			end
		end
	end
	return true
end

--- Terrain strokes: authored paths as dry trampled earth instead of Part ribbons, clamped to the
--- island bounds (habitat approaches start offshore, where nothing is painted).
local function paths(paint: { any }, layout: any)
	local low, high = layout.bounds.min, layout.bounds.max
	local function inside(p: any): boolean
		return p.x >= low.x and p.x <= high.x and p.z >= low.z and p.z <= high.z
	end
	for _, path in layout.paths do
		for index = 2, #path.points do
			local a, b = path.points[index - 1], path.points[index]
			if not inside(a) and not inside(b) then
				continue
			end
			local from = { x = math.clamp(a.x, low.x, high.x), y = a.y, z = math.clamp(a.z, low.z, high.z) }
			local to = { x = math.clamp(b.x, low.x, high.x), y = b.y, z = math.clamp(b.z, low.z, high.z) }
			if from.x ~= to.x or from.z ~= to.z then
				table.insert(paint, {
					id = path.id .. "." .. index,
					shape = "segment",
					from = from,
					to = to,
					width = path.width,
					material = "Ground",
				})
			end
		end
	end
end

--- Mesh understory around each arrival point: ring candidates nearest first, kept where a B1 kit
--- may stand (BiomeKits.allowed) and clear of the drift camp.
local function grove(out: { any }, layout: any, columns: { any }, terrain: any)
	local B1 = kits()
	local list = B1.kitsFor(layout)
	local ground = B1.ground(columns, list[1] == "desert")
	local cell = if columns[1] then columns[1].cell else 32
	-- Slope against existing neighbours only: BiomeKits reads a missing column as a -12 cliff, which
	-- marks every column of a platform island (the harbor) as a cliff face.
	local grade = {
		top = ground.top,
		beach = ground.beach,
		slope = function(x: number, z: number): number
			local top = ground.top(x, z)
			if top == nil then
				return math.huge
			end
			local worst = 0
			for dx = -1, 1 do
				for dz = -1, 1 do
					local other = ground.top(x + dx * cell, z + dz * cell)
					if other and (dx ~= 0 or dz ~= 0) then
						worst = math.max(worst, math.abs(other - top) / (cell * math.sqrt(dx * dx + dz * dz)))
					end
				end
			end
			return worst
		end,
	}
	local camp = M.driftCamp(layout)
	local rows: { [string]: { string } } = {}
	for _, kit in list do
		rows[kit] = {}
		for _, row in B1.kits[kit] do
			-- Gravel cards read as dark puddles at the play camera; leaf litter reads as ground texture.
			if
				row.family == "shrub"
				or row.family == "fern"
				or row.family == "grass"
				or (row.family == "clutter" and not row.key:find("gravel"))
			then
				table.insert(rows[kit], row.key)
			end
		end
	end
	local placed: { any } = {}
	-- Seeded jitter so the rings never read as a pattern (same layout -> same grove).
	local jitter = Rng.new(#columns):fork(layout.id .. ":grove")
	for arrival, at in B1.arrivals(layout) do
		local count = 0
		for ring, radius in M.GROVE_RINGS do
			for step = 0, 15 do
				if count >= M.GROVE then
					break
				end
				local angle = (step + ring * 0.5 + (jitter:nextNumber() - 0.5) * 0.8) * math.pi / 8
				local reach = radius + (jitter:nextNumber() - 0.5) * 4
				local x, z = at.x + math.cos(angle) * reach, at.z + math.sin(angle) * reach
				if not B1.allowed(layout, terrain, grade, x, z, 2) then
					continue
				end
				local clear = true
				for _, other in placed do
					clear = clear and (x - other.x) ^ 2 + (z - other.z) ^ 2 >= M.GROVE_SPACING ^ 2
				end
				if camp then
					for _, key in { "fire", "tent", "rift" } do
						clear = clear and (x - camp[key].x) ^ 2 + (z - camp[key].z) ^ 2 >= 12 ^ 2
					end
				end
				if not clear then
					continue
				end
				local kit = if #list > 1 and ground.beach(x, z) then "beach" else list[1]
				local keys = rows[kit] or rows[list[1]]
				count += 1
				local value = placement(
					"grove." .. arrival .. "." .. count,
					kit,
					keys[(count - 1) % #keys + 1],
					{ x = x, y = ground.top(x, z) :: number, z = z },
					(count * 137.5) % 360,
					0.9 + (count % 4) * 0.1
				)
				table.insert(placed, value)
				table.insert(out, value)
			end
		end
	end
end

--- Ground variety (L10, R03-3 / R05-1): seeded discs of moss, bare earth and scree around each
--- arrival point, painted into the terrain like paths, so the spawn screen is not one flat green.
--- Patches stay off paths, nodes and the drift camp; they never change heights (strokes write
--- only the top two studs at the probed surface).
type PatchRule = {
	count: number,
	radius: { number },
	size: { number },
	slope: number,
	mix: { { material: string, upTo: number } },
}
M.PATCH = table.freeze({
	count = 64,
	radius = { 14, 108 },
	size = { 4, 11 },
	-- Flat ground only, so the patch reads as one surface.
	slope = 0.12,
	-- Material share in order (cumulative): moss, bare earth, scree.
	mix = {
		{ material = "LeafyGrass", upTo = 0.5 },
		{ material = "Ground", upTo = 0.82 },
		{ material = "Pavement", upTo = 1 },
	},
} :: PatchRule)
local function patches(paint: { any }, layout: any, terrain: any, columns: { any })
	if #columns == 0 or layout.id == "rw.home" or layout.id == "rw.town" then
		return
	end
	local B1 = kits()
	local ground = B1.ground(columns, false)
	local rng = Rng.new(#columns):fork(layout.id .. ":patch")
	for arrival, at in B1.arrivals(layout) do
		local made = 0
		for _ = 1, M.PATCH.count * 3 do
			if made >= M.PATCH.count then
				break
			end
			local angle = rng:nextNumber() * math.pi * 2
			local distance = M.PATCH.radius[1] + rng:nextNumber() * (M.PATCH.radius[2] - M.PATCH.radius[1])
			local size = M.PATCH.size[1] + rng:nextNumber() * (M.PATCH.size[2] - M.PATCH.size[1])
			local roll = rng:nextNumber()
			local x, z = at.x + math.cos(angle) * distance * 1.25, at.z + math.sin(angle) * distance
			local top = ground.top(x, z)
			if
				top == nil
				or top <= B1.LAND_TOP
				or ground.beach(x, z)
				or ground.slope(x, z) > M.PATCH.slope
				or not offPath(layout, terrain, x, z, size)
			then
				continue
			end
			local near = false
			for _, node in layout.resourceNodes do
				near = near or (x - node.position.x) ^ 2 + (z - node.position.z) ^ 2 < (size + 3) ^ 2
			end
			if near then
				continue
			end
			local material = M.PATCH.mix[#M.PATCH.mix].material
			for _, entry in M.PATCH.mix do
				if roll <= entry.upTo then
					material = entry.material
					break
				end
			end
			made += 1
			table.insert(paint, {
				id = "patch." .. arrival .. "." .. made,
				shape = "disc",
				patch = true,
				position = { x = x, y = top, z = z },
				radius = if material == "Pavement" then size * 0.55 else size,
				material = material,
			})
		end
	end
end

--- The role's visual plan. `parts` holds only kits with a B3 mesh row (StructureMeshes.DRESSING;
--- their composed parts are the load-failure fallback). Vegetation and rocks are B1 kit rows in
--- `kits` (BiomeKits.Placement + id), paths and hazard pools are terrain strokes in `paint`, and
--- lava glow, steam and ash are emitter points in `effects`. No primitive scatter is emitted.
function M.plan(layout: any, columns: { any }, terrain: any): any
	local palette = M.palette(layout)
	local parts: { any } = {}
	local placements: { any } = {}
	local paint: { any } = {}
	local effects: { any } = {}
	local buildings = M.town(layout)
	for _, building in buildings do
		local start = #parts + 1
		M.kit(parts, building.id, { x = building.x, y = 4, z = building.z }, building.kind, palette)
		turn(parts, start, building.x, building.z, building.yaw)
	end
	local primary = if #columns > 0 then kits().kitsFor(layout)[1] else nil
	if layout.id ~= "rw.home" then
		paths(paint, layout)
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
	-- Never re-transform its positions here. The landmark is a hero B1 row sized to the authored
	-- footprint: a tree, or a three-boulder outcrop.
	if layout.art and primary then
		local landmark = layout.art.landmark
		local p, size = landmark.position, landmark.size
		if landmark.kind == "tree" then
			table.insert(placements, placement(landmark.id, primary, M.HERO_TREE[primary], p, 0, 1.1))
		else
			-- Three boulders inside the footprint; one that would land on a trail stays out.
			local scale = math.clamp(math.max(size.x, size.z) / 16, 1, 2.5)
			for i = 1, 3 do
				local angle = i * math.pi * 2 / 3
				local at = {
					x = p.x + math.cos(angle) * size.x / 4,
					y = p.y,
					z = p.z + math.sin(angle) * size.z / 4,
				}
				if offPath(layout, terrain, at.x, at.z, 4) then
					local key = M.HERO_ROCK[primary]
					table.insert(
						placements,
						placement(landmark.id .. "." .. i, primary, key, at, i * 97 % 360, scale * (1.15 - i * 0.1))
					)
				end
			end
		end
	end
	for _, refuge in layout.refuges do
		local a, b = refuge.bounds.min, refuge.bounds.max
		M.kit(parts, refuge.id, { x = (a.x + b.x) / 2, y = a.y, z = (a.z + b.z) / 2 }, "shelter", palette)
	end
	for _, hazard in layout.hazards do
		if hazard.kind == "lava" or hazard.kind == "hot-spring" then
			local lava = hazard.kind == "lava"
			table.insert(paint, {
				id = hazard.id .. ".surface",
				shape = "disc",
				position = hazard.position,
				radius = hazard.radius,
				material = if lava then "CrackedLava" else "Water",
			})
			table.insert(effects, {
				id = hazard.id .. ".surface",
				effect = if lava then "lava" else "steam",
				position = hazard.position,
			})
			if primary then
				for i = 1, 8 do
					local angle = i * math.pi / 4
					local at = {
						x = hazard.position.x + math.cos(angle) * hazard.radius,
						y = hazard.position.y,
						z = hazard.position.z + math.sin(angle) * hazard.radius,
					}
					-- Springs sit on their link trail: rim stones stay off the walkable ribbon.
					if offPath(layout, terrain, at.x, at.z, 3) then
						local key = M.HERO_ROCK[primary]
						table.insert(
							placements,
							placement(hazard.id .. ".rim" .. i, primary, key, at, i * 45, 0.8 + i % 3 * 0.1)
						)
					end
				end
			end
		end
	end
	if table.find(layout.biomes, "volcano") then
		local center = layout.anchors[1].position
		for i = 1, 4 do
			-- A cooled flow tongue painted into the ground, its glow an emitter at the head.
			local head = { x = center.x - 36 - i * 4, y = center.y, z = center.z - i * 24 }
			local tail = { x = head.x + math.sin(math.rad(-12)) * 16, y = head.y, z = head.z - 16 }
			table.insert(paint, {
				id = "lava.flow" .. i,
				shape = "segment",
				from = { x = 2 * head.x - tail.x, y = head.y, z = 2 * head.z - tail.z },
				to = tail,
				width = 7,
				material = "CrackedLava",
			})
			table.insert(effects, { id = "lava.flow" .. i, effect = "lava", position = head })
			local at = { x = center.x - 52, y = center.y, z = center.z - i * 26 }
			if primary and offPath(layout, terrain, at.x, at.z, 4) then
				table.insert(placements, placement("basalt." .. i, primary, M.HERO_ROCK[primary], at, i * 61, 1.2))
			end
		end
		local vent = { x = center.x - 58, y = center.y, z = center.z - 100 }
		if primary and offPath(layout, terrain, vent.x, vent.z, 8) then
			table.insert(placements, placement("ash.vent", primary, M.HERO_ROCK[primary], vent, 0, 2.4))
		end
		table.insert(
			effects,
			{ id = "ash.vent", effect = "ash", position = { x = vent.x, y = vent.y + 12, z = vent.z } }
		)
		-- Distant offshore ash plumes are scenery only; damaging lava stays at catalog volumes.
		local x = layout.bounds.min.x - 48
		for i = 1, 5 do
			table.insert(
				effects,
				{ id = "offshore.ash" .. i, effect = "ash", position = { x = x, y = 3 + i * 3, z = (i - 3) * 36 } }
			)
		end
	end
	local arrival = M.arrival(parts, layout, palette)
	if primary then
		grove(placements, layout, columns, terrain)
		patches(paint, layout, terrain, columns)
	end
	assert(#parts <= 768, "WORLD_DRESSING_PART_BUDGET")
	return {
		parts = parts,
		kits = placements,
		paint = paint,
		effects = effects,
		palette = palette,
		fauna = arrival,
		buildings = buildings,
	}
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
	-- Palms stay on the east coast, clear of the camp: B1 beach kit rows (RoleWorld renderHome
	-- places kind "biome-kit" through BiomeKits.place), never primitive palm kits.
	for i = 1, 4 do
		local a = math.rad(i * 20 - 40)
		table.insert(parts, {
			id = "home.tree" .. i,
			kind = "biome-kit",
			kit = "beach",
			key = if i % 2 == 0 then "veg.beach.palm-lean" else "veg.beach.palm-tall",
			family = "tree",
			position = { x = math.cos(a) * half, y = 0, z = math.sin(a) * half },
			yaw = i * 83 % 360,
			scale = 0.9 + i % 3 * 0.1,
			decorative = true,
		})
	end
end

return M
