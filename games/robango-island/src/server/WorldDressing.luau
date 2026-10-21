--!strict
-- Pure visual plan; gameplay positions, hazards and stock come only from content.
-- Budget: at most 96 scattered props and 768 authored kit parts per loaded role.
local M = {}
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
	if kind == "tree" or kind == "conifer" then
		for i = 1, 5 do
			local trunk = piece(
				"trunk" .. i,
				math.sin(i * 0.4) * 1.4,
				i * 2.6 - 1.3,
				0,
				3.3,
				2.6 - i * 0.25,
				2.6 - i * 0.25,
				"Wood",
				wood,
				"Cylinder"
			)
			trunk.roll = 84 + i * 2
		end
		for i = 1, 4 do
			local crown = piece(
				"canopy" .. i,
				if kind == "conifer" then 0 else math.cos(i * 2) * 4,
				10 + i * 2.4,
				if kind == "conifer" then 0 else math.sin(i * 2) * 4,
				19 - i * 3,
				5,
				17 - i * 2.5,
				"Grass",
				palette.leaf,
				if kind == "conifer" then "Wedge" else "Ball"
			)
			crown.yaw, crown.roll = i * 37, if kind == "conifer" then 0 else i * 3
		end
		for i = 1, 3 do
			local root =
				piece("root" .. i, math.cos(i * 2) * 1.5, 0.7, math.sin(i * 2) * 1.5, 4, 1.4, 1.2, "Wood", wood)
			root.yaw, root.roll = math.deg(i * 2), 12
		end
	elseif kind == "palm" then
		for i = 1, 6 do
			local trunk = piece(
				"trunk" .. i,
				(i / 6) ^ 2 * 3,
				i * 2.5 - 1.25,
				0,
				3,
				1.8 - i * 0.1,
				1.8 - i * 0.1,
				"Wood",
				wood,
				"Cylinder"
			)
			trunk.roll = 90 - i * 3
		end
		for i = 0, 5 do
			local angle = i * math.pi / 3
			for tier = 1, 2 do
				local leaf = piece(
					"frond" .. i .. "." .. tier,
					3 + math.cos(angle) * (tier * 3 - 1),
					16 - tier * 0.9,
					math.sin(angle) * (tier * 3 - 1),
					5.8,
					0.45,
					3.2 - tier * 0.8,
					"Grass",
					palette.leaf,
					"Wedge"
				)
				leaf.yaw, leaf.roll = -math.deg(angle), if tier == 1 then 16 else -23
			end
		end
	elseif kind == "fern" or kind == "cycad" or kind == "grass" or kind == "horsetail" or kind == "bush" then
		local tall = kind == "cycad" or kind == "horsetail"
		if tall then
			piece("stem", 0, 1.5, 0, 3, 0.8, 0.8, "Wood", wood, "Cylinder").roll = 90
		end
		for i = 0, 5 do
			local leaf = piece(
				"leaf" .. i,
				math.cos(i * 1.57) * 2,
				if tall then 3 else 1.4,
				math.sin(i * 1.57) * 2,
				6,
				if kind == "bush" then 2 else 0.35,
				if kind == "bush" then 3 else 1.5,
				"Grass",
				palette.leaf,
				if kind == "bush" then "Ball" else "Wedge"
			)
			leaf.yaw, leaf.roll = i * 60, if kind == "grass" or kind == "horsetail" then 65 else 24
		end
	elseif kind == "rock" then
		for i = 1, 3 do
			local rock = piece(
				"rock" .. i,
				(i - 2) * 2,
				1 + i * 0.4,
				(i % 2) * 2,
				7 - i,
				3 + i,
				6,
				"Slate",
				palette.rock,
				"Ball"
			)
			rock.yaw, rock.roll = i * 35, i * 9
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
		piece("body", 0, 1.5, 0, 5, 3, 3, "WoodPlanks", wood)
		piece("lid", 0, 3.2, 0, 5.3, 0.6, 3.3, "Wood", sand)
		piece("clasp", 0, 2.6, 1.6, 0.6, 1, 0.3, "Metal", { 87, 81, 66 })
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
		for _, x in { -5, 5 } do
			for _, z in { -4, 4 } do
				piece("post" .. x .. "." .. z, x, 4, z, 8, 0.85, 0.85, "Wood", wood, "Cylinder").roll = 90
				piece("lash" .. x .. "." .. z, x, 7.2, z, 1.05, 0.5, 1.05, "Fabric", sand, "Ball")
			end
		end
		for _, x in { -3, 3 } do
			for row = 1, 4 do
				local roof = piece(
					"roof" .. x .. "." .. row,
					x,
					9,
					(row - 2.5) * 2.8,
					7.8,
					0.65,
					3.4,
					"Grass",
					{ 166 + row * 5, 137 + row * 4, 79 },
					"Wedge"
				)
				roof.roll = if x < 0 then 32 else -32
			end
		end
		piece("ridge", 0, 11, 0, 0.9, 0.9, 12.5, "Wood", wood, "Ball")
		piece("hide.back", 0, 4, 3.9, 9.8, 6, 0.2, "Fabric", { 150, 116, 75 })
		piece("hide.side", -4.9, 3, 0, 0.2, 4, 7, "Fabric", { 169, 137, 91 })
		piece("bedroll", 2, 0.6, 0, 3, 0.6, 6, "Fabric", palette.leaf)
	elseif kind == "workbench" or kind == "drying-rack" then
		for _, x in { -3, 3 } do
			piece("leg" .. x, x, 2.5, 0, 5, 0.7, 0.7, "Wood", wood, "Cylinder").roll = 90
			piece("lash" .. x, x, 4.7, 0, 0.9, 0.5, 0.9, "Fabric", sand, "Ball")
		end
		piece("beam", 0, 5, 0, 8, 0.8, 0.8, "Wood", wood, "Cylinder")
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
		piece("foot", 0, 1, 0, 7, 2, 7, "Rock", palette.rock)
		piece("shaft", 0, 7, 0, 1, 12, 1, "Wood", wood)
		piece("flag", 2, 11, 0, 4, 3, 0.3, "Fabric", { 235, 193, 106 })
	elseif kind == "fence" then
		for x = -3, 3, 2 do
			piece("post" .. x, x, 2.2, 0, 4.5, 0.8, 0.8, "Wood", wood, "Cylinder").roll = 90
			piece("tip" .. x, x, 4.7, 0, 0.8, 0.8, 0.8, "Wood", sand, "Wedge")
		end
		for _, y in { 1.2, 2.8 } do
			piece("rail" .. y, 0, y, 0, 8, 0.4, 0.4, "Wood", wood)
		end
	end
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
			and #props < 30
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
	for i = 1, 4 do
		M.kit(parts, "home.tree" .. i, { x = -half + i * 8, y = 0, z = half - 5 }, "palm", palette)
	end
end

return M
