--!strict
-- Robango Island world: a deterministic terrain island (landing plateau, temperate forest to the
-- west, coastal marsh to the east) with every content node kind placed once and wildlife homes in
-- each biome. Geometry is built at runtime so the static place budget (QA-PERF-01) is unaffected;
-- every height comes from IslandTerrain and every scatter from a fixed-seed Rng.
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local CollectionService = game:GetService("CollectionService")
local World = require(Forge.genres["survival-coop"].module.SurvivalWorld)
local Rng = require(Forge.core.domain.random.Rng)
local IslandTerrain = require(Forge.games["robango-island"].src.shared.IslandTerrain)

local DECOR_SEED = 20261018
type Sign = { text: string, x: number, z: number }
local SIGNS: { Sign } = {
	-- Server-built world text cannot follow each viewer's locale, so signs carry both rows of
	-- locale/strings.csv (biome_temperate_forest, biome_coastal_marsh).
	{ text = "온대 숲\nTemperate Forest", x = -46, z = 8 },
	{ text = "해안 습지\nCoastal Marsh", x = 46, z = 8 },
}
type Mark = { name: string, position: Vector3 }

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Side of the level clearing cut around every gather node (reach is 8 studs).
local CLEARING_STUDS = 16

local function buildTerrain()
	local terrain = workspace.Terrain
	local cell = IslandTerrain.CELL
	local bottom = IslandTerrain.BOTTOM
	local sea = IslandTerrain.SEA_LEVEL
	local slice = os.clock()
	-- Water reaches past the island so the shoreline reads from every camera angle.
	for x = -IslandTerrain.HALF_X - 40, IslandTerrain.HALF_X + 40 - cell, cell do
		for z = -IslandTerrain.HALF_Z - 40, IslandTerrain.HALF_Z + 40 - cell, cell do
			local cx, cz = x + cell / 2, z + cell / 2
			local sample = IslandTerrain.sample(cx, cz)
			local material = (Enum.Material :: any)[sample.material]
			terrain:FillBlock(
				CFrame.new(cx, (bottom + sample.top) / 2, cz),
				Vector3.new(cell, sample.top - bottom, cell),
				material
			)
			if sample.top < sea then
				terrain:FillBlock(
					CFrame.new(cx, (sample.top + sea) / 2, cz),
					Vector3.new(cell, sea - sample.top, cell),
					Enum.Material.Water
				)
			end
		end
		-- About six thousand FillBlock calls exceed the script execution budget in one
		-- resumption, but yielding every column cost ~85 frames (4 s to first interaction).
		-- Yield only once the slice has run 50 ms.
		if os.clock() - slice > 0.05 then
			task.wait()
			slice = os.clock()
		end
	end
end

return function(content, source, wildlifePolicy, epochMillis)
	buildTerrain()
	local geometry = Instance.new("Folder")
	geometry.Name, geometry.Parent = "DevelopmentIsland", workspace
	local scenery = Instance.new("Folder")
	scenery.Name, scenery.Parent = "IslandScenery", workspace
	local function part(name: string, size: Vector3, position: Vector3, color: Color3, className: string?): BasePart
		local value: BasePart = if className == "WedgePart" then Instance.new("WedgePart") else Instance.new("Part")
		value.Name, value.Anchored, value.Size, value.Position = name, true, size, position
		value.Color, value.TopSurface, value.BottomSurface = color, Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		value.Parent = geometry
		return value
	end
	-- Decoration never collides or answers queries, so it cannot block gather/attack line of sight.
	local function decor(
		name: string,
		size: Vector3,
		cframe: CFrame,
		color: Color3,
		shape: Enum.PartType?,
		material: Enum.Material?
	): Part
		local value = Instance.new("Part")
		value.Name, value.Anchored, value.Size, value.CFrame = name, true, size, cframe
		value.Color, value.Material = color, material or Enum.Material.SmoothPlastic
		value.CanCollide, value.CanQuery, value.CanTouch, value.CastShadow = false, false, false, true
		value.TopSurface, value.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		if shape then
			value.Shape = shape
		end
		value.Parent = scenery
		return value
	end
	local function ground(x: number, z: number): number
		return IslandTerrain.sample(x, z).top
	end

	part("IslandFloor", Vector3.new(64, 2, 48), Vector3.new(0, -1, 8), rgb(90, 112, 72))
	local warehouse: { x: number, y: number, z: number } = source.tribe.warehousePosition
	part("WarehouseApproach", Vector3.new(12, 2, 16), Vector3.new(warehouse.x, -1, warehouse.z + 4), rgb(90, 112, 72))
	-- Voxels round a fractional surface up to whole cells, so the plateau reached y = 0 and
	-- z-fought with these floor tops. Clear the voxel layer the authored floors occupy.
	workspace.Terrain:FillBlock(CFrame.new(0, -1, 8), Vector3.new(64, 4, 48), Enum.Material.Air)
	workspace.Terrain:FillBlock(CFrame.new(warehouse.x, -1, warehouse.z + 4), Vector3.new(12, 4, 16), Enum.Material.Air)
	local marker =
		part("Warehouse", Vector3.new(3, 2, 2), Vector3.new(warehouse.x + 3, 1, warehouse.z), rgb(116, 77, 45))
	marker:SetAttribute("ForgeWarehouseTribe", source.tribe.config.tribeId)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name, spawn.Anchored, spawn.Position, spawn.Size =
		"SurvivalSpawn", true, Vector3.new(0, 0.5, 0), Vector3.new(4, 1, 4)
	spawn.Neutral, spawn.Duration, spawn.Parent = true, 0, geometry
	local world = World.new({
		content = content,
		worldRevision = source.worldRevision,
		spawn = spawn,
		carriedContainer = "bag",
		reachStuds = 8,
		baseWalkSpeed = 16,
		wildlife = if wildlifePolicy
			then {
				catalog = wildlifePolicy.catalog,
				spawns = wildlifePolicy.spawns,
				maximum = wildlifePolicy.maximum,
				nowMillis = assert(epochMillis, "WILDLIFE_CLOCK_REQUIRED"),
			}
			else nil,
		respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
	})
	local campfire = part("campfire", Vector3.new(3, 1, 3), Vector3.new(-6, 0.5, 0), rgb(185, 89, 39))
	local bench = part("workbench", Vector3.new(4, 2, 2), Vector3.new(6, 1, 0), rgb(116, 77, 45))
	world.registerStation(campfire, "campfire", "campfire")
	world.registerStation(bench, "workbench", "workbench")

	-- One builder per node kind: the returned part is the registered gather target (anchored,
	-- collidable, short enough that its prompt sits within reach); the rest is silhouette decor.
	type Builder = (id: string, p: Vector3, h: number) -> BasePart
	local builders: { [string]: Builder } = {
		["fallen-tree"] = function(id, p)
			local log = part(id, Vector3.new(6, 2, 2), p, rgb(105, 70, 42)) :: Part
			log.Shape = Enum.PartType.Cylinder
			return log
		end,
		["flint-outcrop"] = function(id, p)
			return part(id, Vector3.new(4, 4, 3), p, rgb(88, 96, 110), "WedgePart")
		end,
		["fiber-bush"] = function(id, p)
			local shape = part(id, Vector3.new(1, 4, 2), p, rgb(154, 163, 80))
			-- Accent parts never collide or answer queries: a colliding blade blocked the reach ray.
			local blade = part(id .. "-blade", Vector3.new(3, 3, 0.5), p, rgb(130, 147, 63))
			blade.CanCollide, blade.CanQuery = false, false
			return shape
		end,
		["berry-bush"] = function(id, p)
			local bush = part(id, Vector3.new(4, 4, 4), p, rgb(49, 112, 59)) :: Part
			bush.Shape = Enum.PartType.Ball
			local berries =
				part(id .. "-berries", Vector3.new(1.5, 1.5, 1.5), p + Vector3.new(0, 1, -1.5), rgb(145, 45, 81))
			local fruit = berries :: Part
			fruit.Shape, fruit.CanCollide, fruit.CanQuery = Enum.PartType.Ball, false, false
			return bush
		end,
		["meat-cache"] = function(id, p)
			local shape = part(id, Vector3.new(3, 2, 3), p, rgb(155, 75, 62))
			local bone = part(id .. "-bone", Vector3.new(4, 0.5, 0.5), p + Vector3.new(0, 1.25, 0), rgb(229, 219, 185))
			bone.CanCollide, bone.CanQuery = false, false
			return shape
		end,
		["forest-oak-windfall"] = function(id, p, h)
			local log = part(id, Vector3.new(9, h, h), p, rgb(92, 64, 40)) :: Part
			log.Shape, log.Material = Enum.PartType.Cylinder, Enum.Material.Wood
			decor(
				id .. "-roots",
				Vector3.new(1.5, 5, 5),
				CFrame.new(p + Vector3.new(4.6, 0.8, 0)),
				rgb(74, 52, 33),
				Enum.PartType.Cylinder,
				Enum.Material.Wood
			)
			return log
		end,
		["forest-birch-stand"] = function(id, p, h)
			local base = part(id, Vector3.new(3, h, 3), p, rgb(232, 230, 220)) :: Part
			base.Shape, base.Material = Enum.PartType.Cylinder, Enum.Material.Wood
			base.CFrame = CFrame.new(p) * CFrame.Angles(0, 0, math.rad(90))
			for index, offset in { Vector3.new(0, 0, 0), Vector3.new(3, 0, 2), Vector3.new(-2.5, 0, 2.5) } do
				local top = p + offset + Vector3.new(0, h / 2 + 5, 0)
				decor(
					id .. "-trunk" .. index,
					Vector3.new(1, 10, 1),
					CFrame.new(top),
					rgb(238, 236, 226),
					nil,
					Enum.Material.Wood
				)
				decor(
					id .. "-crown" .. index,
					Vector3.new(5, 5, 5),
					CFrame.new(top + Vector3.new(0, 5, 0)),
					rgb(146, 181, 76),
					Enum.PartType.Ball,
					Enum.Material.Grass
				)
			end
			return base
		end,
		["forest-hazel-thicket"] = function(id, p, h)
			local bush = part(id, Vector3.new(h, h, h), p, rgb(84, 120, 52)) :: Part
			bush.Shape, bush.Material = Enum.PartType.Ball, Enum.Material.Grass
			for index, offset in { Vector3.new(1.2, 1, -1.4), Vector3.new(-1.2, 1.4, -1) } do
				decor(
					id .. "-nut" .. index,
					Vector3.new(0.9, 0.9, 0.9),
					CFrame.new(p + offset),
					rgb(176, 124, 66),
					Enum.PartType.Ball
				)
			end
			return bush
		end,
		["forest-bramble-patch"] = function(id, p, h)
			local patch = part(id, Vector3.new(5, h, 4), p, rgb(56, 86, 44)) :: Part
			patch.Material = Enum.Material.Grass
			for index, offset in
				{ Vector3.new(1.6, h / 2, -2), Vector3.new(-1.4, h / 2, -2), Vector3.new(0, h / 2 + 0.3, 1.6) }
			do
				decor(
					id .. "-berry" .. index,
					Vector3.new(0.8, 0.8, 0.8),
					CFrame.new(p + offset),
					rgb(82, 26, 74),
					Enum.PartType.Ball
				)
			end
			return patch
		end,
		["forest-bracken-bed"] = function(id, p, h)
			local bed = part(id, Vector3.new(6, h, 5), p, rgb(120, 150, 54)) :: Part
			bed.Material = Enum.Material.Grass
			for index = 1, 3 do
				local angle = math.rad(index * 60)
				decor(
					id .. "-frond" .. index,
					Vector3.new(0.3, 3, 4),
					CFrame.new(p + Vector3.new(0, h / 2 + 1.2, 0)) * CFrame.Angles(0, angle, math.rad(25)),
					rgb(138, 170, 62),
					nil,
					Enum.Material.Grass
				)
			end
			return bed
		end,
		["forest-chanterelle-log"] = function(id, p, h)
			local log = part(id, Vector3.new(7, h, h), p, rgb(84, 104, 54)) :: Part
			log.Shape, log.Material = Enum.PartType.Cylinder, Enum.Material.Grass
			for index, offset in { Vector3.new(-1.5, 1.1, -1), Vector3.new(1.4, 1.1, -0.8) } do
				decor(
					id .. "-cap" .. index,
					Vector3.new(0.6, 1.2, 1.2),
					CFrame.new(p + offset) * CFrame.Angles(0, 0, math.rad(90)),
					rgb(238, 168, 40),
					Enum.PartType.Cylinder
				)
			end
			return log
		end,
		["forest-flint-scree"] = function(id, p, h)
			local scree = part(id, Vector3.new(5, h, 4), p, rgb(150, 150, 146), "WedgePart")
			scree.Material = Enum.Material.Slate
			decor(
				id .. "-ivy",
				Vector3.new(0.2, 2, 3),
				CFrame.new(p + Vector3.new(2.6, 0, 0)),
				rgb(40, 92, 48),
				nil,
				Enum.Material.Grass
			)
			return scree
		end,
		["forest-boulder-field"] = function(id, p, h)
			local boulder = part(id, Vector3.new(h + 1, h, h + 1), p, rgb(118, 120, 112)) :: Part
			boulder.Shape, boulder.Material = Enum.PartType.Ball, Enum.Material.Rock
			for index, offset in { Vector3.new(3.5, -0.8, 1), Vector3.new(-3, -1, -1.5) } do
				decor(
					id .. "-stone" .. index,
					Vector3.new(2.5, 2.5, 2.5),
					CFrame.new(p + offset),
					rgb(132, 134, 124),
					Enum.PartType.Ball,
					Enum.Material.Rock
				)
			end
			return boulder
		end,
		["marsh-reed-bed"] = function(id, p, h)
			local bed = part(id, Vector3.new(5, h, 5), p, rgb(170, 160, 92)) :: Part
			bed.Material = Enum.Material.Grass
			for index, offset in { Vector3.new(-1.5, 0, -1.5), Vector3.new(1.5, 0, -1), Vector3.new(0, 0, 1.5) } do
				decor(
					id .. "-stalk" .. index,
					Vector3.new(0.4, 5, 0.4),
					CFrame.new(p + offset + Vector3.new(0, h / 2 + 2.5, 0)),
					rgb(196, 182, 112)
				)
			end
			return bed
		end,
		["marsh-cattail-stand"] = function(id, p, h)
			local stand = part(id, Vector3.new(4, h, 4), p, rgb(92, 128, 70)) :: Part
			stand.Material = Enum.Material.Grass
			for index, offset in { Vector3.new(-1, 0, -1), Vector3.new(1.2, 0, 0.6) } do
				local top = p + offset + Vector3.new(0, h / 2 + 2, 0)
				decor(id .. "-stem" .. index, Vector3.new(0.3, 4, 0.3), CFrame.new(top), rgb(96, 132, 72))
				decor(
					id .. "-head" .. index,
					Vector3.new(0.7, 1.6, 0.7),
					CFrame.new(top + Vector3.new(0, 1.6, 0)),
					rgb(104, 64, 36)
				)
			end
			return stand
		end,
		["marsh-cordgrass-tussock"] = function(id, p, h)
			local tussock = part(id, Vector3.new(4, h, 4), p, rgb(128, 166, 96)) :: Part
			tussock.Shape, tussock.Material = Enum.PartType.Ball, Enum.Material.Grass
			return tussock
		end,
		["marsh-samphire-flat"] = function(id, p, h)
			local flat = part(id, Vector3.new(6, h, 5), p, rgb(122, 168, 74)) :: Part
			flat.Material = Enum.Material.Grass
			for index, offset in { Vector3.new(-1.5, 0.9, 0), Vector3.new(1.5, 0.9, 1) } do
				decor(id .. "-sprig" .. index, Vector3.new(0.5, 1.2, 0.5), CFrame.new(p + offset), rgb(150, 70, 80))
			end
			return flat
		end,
		["marsh-clay-bank"] = function(id, p, h)
			local bank = part(id, Vector3.new(6, h, 4), p, rgb(150, 104, 78), "WedgePart")
			bank.Material = Enum.Material.Mud
			decor(
				id .. "-lavender",
				Vector3.new(1.2, 1.2, 1.2),
				CFrame.new(p + Vector3.new(2.4, h / 2 + 0.4, 1)),
				rgb(150, 120, 196),
				Enum.PartType.Ball
			)
			return bank
		end,
		["marsh-clam-bed"] = function(id, p, h)
			local bed = part(id, Vector3.new(5, h, 5), p, rgb(212, 204, 186)) :: Part
			bed.Material = Enum.Material.Sand
			for index, offset in { Vector3.new(-1.2, 0.6, 1), Vector3.new(1, 0.6, -1), Vector3.new(1.6, 0.6, 1.4) } do
				decor(
					id .. "-clam" .. index,
					Vector3.new(0.9, 0.5, 0.9),
					CFrame.new(p + offset),
					rgb(236, 230, 214),
					Enum.PartType.Ball
				)
			end
			return bed
		end,
		["marsh-driftwood-line"] = function(id, p, h)
			local drift = part(id, Vector3.new(8, h, h), p, rgb(176, 162, 140)) :: Part
			drift.Shape, drift.Material = Enum.PartType.Cylinder, Enum.Material.Wood
			drift.CFrame = CFrame.new(p) * CFrame.Angles(0, math.rad(20), 0)
			decor(
				id .. "-branch",
				Vector3.new(4, 0.8, 0.8),
				CFrame.new(p + Vector3.new(1, 0.6, 1.5)) * CFrame.Angles(0, math.rad(-35), 0),
				rgb(160, 146, 124),
				Enum.PartType.Cylinder,
				Enum.Material.Wood
			)
			return drift
		end,
	}
	for _, node in source.nodes do
		local position = Vector3.new(node.position.x, node.position.y, node.position.z)
		local build = assert(builders[node.catalogId], "NODE_VISUAL_MISSING")
		local height = IslandTerrain.NODE_HEIGHT[node.catalogId] or 2
		-- Hill and bank voxels rose over node parts set on a slope, so the server's reach ray
		-- hit Terrain from every side (Studio, 2026-10-18: 19 of 20 nodes unreachable from at
		-- least one side, forest-oak-windfall from all four). Level a clearing around each
		-- node at its base so the ray from a player standing beside it is clear.
		local base = position.Y - height / 2
		workspace.Terrain:FillBlock(
			CFrame.new(position.X, base + 8, position.Z),
			Vector3.new(CLEARING_STUDS, 16, CLEARING_STUDS),
			Enum.Material.Air
		)
		local shape = build(node.id, position, height)
		world.registerNode(shape, node.id, node.catalogId, 0, source.worldRevision)
	end
	-- Approach the nodes from z=8 for clear reach; the wall blocks the berry lane.
	part("GatherLOSWall", Vector3.new(6, 7, 1), Vector3.new(10, 3.5, 10), rgb(111, 112, 105))
	local roof = part("CameraTestRoof", Vector3.new(12, 1, 8), Vector3.new(-16, 9, 0), rgb(116, 77, 45))
	CollectionService:AddTag(roof, "ForgeCameraOccluder")
	-- QA standing marks: non-colliding, flat. wildlife-approach-01 sits in the lane between
	-- fallen-tree-01 and flint-outcrop-01, inside grazer-01's 12-stud sense radius (its home is
	-- -20,4,24). BuildApproach stands on the entry cell of the release-first-play floor preview
	-- (settlement cell 6,1 from origin -32,-16 with 4-stud cells -> world -6,-10).
	local marks: { Mark } = {
		{ name = "wildlife-approach-01", position = Vector3.new(-19, 0.1, 19) },
		{ name = "WildlifeApproach", position = Vector3.new(-19, 0.1, 19) },
		{ name = "BuildApproach", position = Vector3.new(-6, 0.1, -10) },
	}
	for _, entry in marks do
		local mark = part(entry.name, Vector3.new(2, 0.2, 2), entry.position, rgb(204, 190, 120))
		mark.CanCollide, mark.CanQuery, mark.CanTouch, mark.Transparency = false, false, false, 0.5
	end

	-- Trail stones from the landing plateau to each biome and a signpost at each biome edge.
	for _, side in { -1, 1 } do
		for step = 0, 6 do
			local x, z = side * (36 + step * 5), 8 + math.sin(step) * 2
			decor(
				"Trail",
				Vector3.new(2.4, 0.3, 1.8),
				CFrame.new(x, ground(x, z) + 0.1, z),
				rgb(196, 182, 150),
				nil,
				Enum.Material.Cobblestone
			)
		end
	end
	for _, sign in SIGNS do
		local y = ground(sign.x, sign.z)
		decor(
			"SignPost",
			Vector3.new(0.6, 6, 0.6),
			CFrame.new(sign.x, y + 3, sign.z - 3),
			rgb(110, 78, 50),
			nil,
			Enum.Material.Wood
		)
		local board = decor(
			"SignBoard",
			Vector3.new(6, 2, 0.4),
			CFrame.new(sign.x, y + 5.2, sign.z - 3),
			rgb(152, 112, 70),
			nil,
			Enum.Material.WoodPlanks
		)
		local gui = Instance.new("BillboardGui")
		gui.Size, gui.StudsOffset, gui.MaxDistance = UDim2.fromOffset(180, 56), Vector3.new(0, 2.2, 0), 140
		gui.Parent = board
		local label = Instance.new("TextLabel")
		label.Size, label.BackgroundTransparency, label.TextScaled = UDim2.fromScale(1, 1), 1, true
		label.TextColor3, label.TextStrokeTransparency, label.Font = rgb(255, 248, 228), 0.4, Enum.Font.GothamBold
		label.Text = sign.text
		label.Parent = gui
	end

	-- Scenery scatter (fixed seed): forest trees and marsh reed clumps, kept clear of nodes,
	-- wildlife homes, trails and the shoreline.
	local blocked: { Vector3 } = {}
	for _, node in source.nodes do
		table.insert(blocked, Vector3.new(node.position.x, 0, node.position.z))
	end
	if wildlifePolicy then
		for _, home in wildlifePolicy.spawns do
			table.insert(blocked, Vector3.new(home.position.x, 0, home.position.z))
		end
	end
	local rng = Rng.new(DECOR_SEED)
	local function scatter(
		label: string,
		count: number,
		minX: number,
		maxX: number,
		build: (number, number, number) -> ()
	)
		local stream = rng:fork(label)
		local placed = 0
		for _ = 1, count * 8 do
			if placed >= count then
				break
			end
			local x = minX + stream:nextNumber() * (maxX - minX)
			local z = -80 + stream:nextNumber() * 160
			local sample = IslandTerrain.sample(x, z)
			local clear = math.abs(z - 8) > 5 and sample.top > IslandTerrain.SEA_LEVEL + 1
			local here = Vector3.new(x, 0, z)
			for _, other in blocked do
				if (other - here).Magnitude < 9 then
					clear = false
					break
				end
			end
			if clear and math.sqrt((x / IslandTerrain.HALF_X) ^ 2 + (z / IslandTerrain.HALF_Z) ^ 2) < 0.86 then
				table.insert(blocked, here)
				placed += 1
				build(x, z, sample.top)
			end
		end
	end
	scatter("forest-trees", 26, -118, -50, function(x, z, y)
		local tall = 9 + (x * 7 + z * 3) % 5
		local trunk = decor(
			"OakTrunk",
			Vector3.new(1.6, tall, 1.6),
			CFrame.new(x, y + tall / 2, z),
			rgb(88, 62, 40),
			nil,
			Enum.Material.Wood
		)
		trunk.CanCollide, trunk.CanQuery = true, true
		decor(
			"OakCrown",
			Vector3.new(8, 7, 8),
			CFrame.new(x, y + tall + 2, z),
			rgb(62, 108, 48),
			Enum.PartType.Ball,
			Enum.Material.Grass
		)
	end)
	scatter("marsh-reeds", 18, 56, 112, function(x, z, y)
		decor(
			"ReedClump",
			Vector3.new(2.5, 3, 2.5),
			CFrame.new(x, y + 1.5, z),
			rgb(176, 168, 104),
			nil,
			Enum.Material.Grass
		)
		decor("ReedTip", Vector3.new(0.4, 2, 0.4), CFrame.new(x + 0.6, y + 4, z), rgb(120, 86, 52))
	end)
	return world
end
