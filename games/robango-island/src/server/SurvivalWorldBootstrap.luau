--!strict
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local CollectionService = game:GetService("CollectionService")
local World = require(Forge.genres["survival-coop"].module.SurvivalWorld)
local Rng = require(Forge.core.domain.random.Rng)
local IslandTerrain = require(Forge.games["robango-island"].src.shared.IslandTerrain)
local Dressing = require("./WorldDressing")

-- Tool names in the engine Backpack hotbar follow the owner's locale (locale/strings.csv,
-- shipped as the Strings LocalizationTable); rows are read once, on first use.
local packRows: any = nil
local function itemNames(locale: string): { [string]: string }
	local PackText = require(Forge.games["robango-island"].src.shared.PackText)
	packRows = packRows or PackText.fromEntries(Forge.games["robango-island"].Strings:GetEntries())
	return PackText.names(packRows)(locale)
end

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

local function setupAtmosphere()
	pcall(function()
		local lighting = game:GetService("Lighting")
		lighting.ClockTime = 9.5
		lighting.Brightness = 2.3
		lighting.Ambient = rgb(72, 86, 82)
		lighting.OutdoorAmbient = rgb(112, 132, 122)
		lighting.ColorShift_Top = rgb(255, 236, 200)
		lighting.ColorShift_Bottom = rgb(68, 92, 88)
		lighting.GeographicLatitude = 18
		lighting.ShadowSoftness = 0.25

		local atmo = lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
		atmo.Density = 0.26
		atmo.Offset = 0.15
		atmo.Color = rgb(198, 226, 234)
		atmo.Decay = rgb(138, 176, 192)
		atmo.Glare = 0.15
		atmo.Haze = 1.2
		atmo.Parent = lighting

		local bloom = lighting:FindFirstChildOfClass("BloomEffect") or Instance.new("BloomEffect")
		bloom.Intensity = 0.35
		bloom.Size = 24
		bloom.Threshold = 1.8
		bloom.Parent = lighting

		local cc = lighting:FindFirstChildOfClass("ColorCorrectionEffect") or Instance.new("ColorCorrectionEffect")
		cc.Brightness = 0.02
		cc.Contrast = 0.08
		cc.Saturation = 0.14
		cc.TintColor = rgb(255, 250, 242)
		cc.Parent = lighting

		local terrain = workspace.Terrain
		terrain.WaterColor = rgb(36, 118, 134)
		terrain.WaterTransparency = 0.35
		terrain.WaterReflectance = 0.65
		terrain.WaterWaveSize = 0.12
		terrain.WaterWaveSpeed = 10
	end)
end

return function(content: any, source: any, wildlifePolicy, epochMillis, role: string, studioSingle: boolean)
	local kits = Instance.new("Folder")
	kits.Name, kits.Parent = "ForgeStructureKits", game:GetService("ReplicatedStorage")
	for _, definition in content.structures do
		Dressing.structure(kits, definition, source.tribe.config.cellStuds)
	end
	if not studioSingle then
		local configured = table.clone(source)
		configured.seed = source.seed or DECOR_SEED
		configured.renderRole = require(script.Parent.RoleWorld).build
		configured.roleBuilders = table.clone(source.roleBuilders or {})
		configured.roleBuilders.home = require(script.Parent.HomeWorld).live
		configured.roleBuilders.brawl = require(script.Parent.BrawlWorld).live
		configured.roleBuilders.archipelago = function(c, s, w, now)
			local state: any = assert(s.expedition, "PERSISTED_EXPEDITION_REQUIRED")
			assert(state.status == "active", "EXPEDITION_INACTIVE")
			return configured.renderRole(c, s, w, now, state.templateId .. ".s" .. tostring(state.stage), state.seed)
		end
		for _, region in content.supportRegions or {} do
			if region.role ~= "home" and configured.roleBuilders[region.role] == nil then
				configured.roleBuilders[region.role] = function(c, s, w, now)
					return require(script.Parent.RoleWorld).build(c, s, w, now, region.layout, configured.seed)
				end
			end
		end
		source = configured
	end
	-- World geometry is supplied by the pack's role builders. The legacy island
	-- remains an explicitly labeled Studio preview, never a live-role fallback.
	if not studioSingle then
		local builders = source.roleBuilders
		local builder = if builders then builders[role] else nil
		assert(type(builder) == "function", "missing_world_builder:" .. tostring(role))
		local world = builder(content, source, wildlifePolicy, epochMillis)
		world.structureKits = kits
		return world
	end
	assert(role == "onboarding", "studio_preview_requires_onboarding")
	if wildlifePolicy then
		wildlifePolicy = table.clone(wildlifePolicy)
		wildlifePolicy.sourceKey = "w-preview-v3"
		wildlifePolicy.spawns = {}
		for _, layout in content.layouts do
			if layout.id == "rw.onboarding" then
				for _, spawn in layout.spawns do
					local p = spawn.position
					local x, z = (p.x - 12) * 0.7, (p.z - 62) * 0.55
					local floor = if math.abs(x) <= 32
							and z >= -16
							and z <= 32
						then 0
						else IslandTerrain.sample(x, z).top
					local height = 2
					for _, detail in content.wildlifeDetails do
						if detail.id == spawn.speciesId then
							height = detail.renderEnvelope.y
						end
					end
					table.insert(wildlifePolicy.spawns, {
						id = spawn.id,
						catalogId = spawn.speciesId,
						position = { x = x, y = floor + height / 2, z = z },
					})
				end
			end
		end
	end
	setupAtmosphere()
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
	local function kit(id: string, at: Vector3, kind: string)
		local definitions = {}
		Dressing.kit(
			definitions,
			id,
			{ x = at.X, y = at.Y, z = at.Z },
			kind,
			Dressing.palette({ biomes = { "grassland" } })
		)
		for _, d in definitions do
			local value = part(
				d.id,
				Vector3.new(d.size.x, d.size.y, d.size.z),
				Vector3.new(d.position.x, d.position.y, d.position.z),
				rgb(table.unpack(d.color)),
				if d.shape == "Wedge" then "WedgePart" else nil
			)
			value.Material = (Enum.Material :: any)[d.material]
			value.CFrame *= CFrame.Angles(0, math.rad(d.yaw or 0), math.rad(d.roll or 0))
			if value:IsA("Part") and d.shape and d.shape ~= "Wedge" then
				value.Shape = (Enum.PartType :: any)[d.shape]
			end
			if d.ellipsoid then
				local mesh = Instance.new("SpecialMesh")
				mesh.MeshType, mesh.Parent = Enum.MeshType.Sphere, value
			end
			value.CanCollide, value.CanQuery, value.CanTouch = false, false, false
			if d.effect == "fire" then
				local fire, light = Instance.new("Fire"), Instance.new("PointLight")
				fire.Size, fire.Heat, fire.Parent = 2, 4, value
				light.Color, light.Range, light.Brightness, light.Parent = value.Color, 10, 0.8, value
			end
		end
	end

	local islandFloor = part("IslandFloor", Vector3.new(64, 2, 48), Vector3.new(0, -1, 8), rgb(82, 118, 64))
	islandFloor.Material = Enum.Material.LeafyGrass
	islandFloor.Transparency, islandFloor.CanCollide = 1, false
	local warehouse: { x: number, y: number, z: number } = source.tribe.warehousePosition
	local warehouseFloor = part(
		"WarehouseApproach",
		Vector3.new(12, 2, 16),
		Vector3.new(warehouse.x, -1, warehouse.z + 4),
		rgb(86, 114, 68)
	)
	warehouseFloor.Material = Enum.Material.LeafyGrass
	warehouseFloor.Transparency, warehouseFloor.CanCollide = 1, false
	for x = -32, 32, 4 do
		for z = -16, 32, 4 do
			local edge = math.max(math.abs(x) / 32, math.abs(z - 8) / 24)
			local top = if edge < 0.65 then 0 else math.sin(x * 0.18) * math.cos(z * 0.15) * 1.4
			local material = if ((x + 12) / 21) ^ 2 + (z / 14) ^ 2 < 1
				then Enum.Material.Ground
				elseif (x + z) % 20 < 5 then Enum.Material.LeafyGrass
				elseif x % 28 == 0 then Enum.Material.Mud
				else Enum.Material.Grass
			workspace.Terrain:FillBlock(CFrame.new(x, top / 2 - 2, z), Vector3.new(4, top + 4, 4), material)
		end
	end
	for step = -8, 8 do
		workspace.Terrain:FillBall(Vector3.new(step * 4, -2.8, 8 + math.sin(step * 0.4)), 3.2, Enum.Material.Ground)
		local x, z = step * 3, -12 + (step % 3) * 3
		decor(
			"CampScatter" .. step,
			Vector3.new(0.6, 0.25, 0.45),
			CFrame.new(x, 0.08, z) * CFrame.Angles(0, step, 0),
			rgb(94, 89, 70),
			nil,
			Enum.Material.Slate
		)
		decor(
			"CampTwig" .. step,
			Vector3.new(1.1, 0.12, 0.12),
			CFrame.new(x + 1, 0.12, z + 0.7) * CFrame.Angles(0, step * 2, 0),
			rgb(95, 65, 41),
			Enum.PartType.Cylinder,
			Enum.Material.Wood
		)
		if step % 3 == 0 then
			decor(
				"CampFlower" .. step,
				Vector3.new(0.45, 0.3, 0.45),
				CFrame.new(x, 0.3, z - 1),
				rgb(203, 172, 86),
				Enum.PartType.Ball,
				Enum.Material.Grass
			)
		end
	end
	local wx, wz = warehouse.x + 3, warehouse.z
	local marker = part("Warehouse", Vector3.new(3, 2, 2), Vector3.new(wx, 1, wz), rgb(124, 84, 50))
	marker.Material = Enum.Material.WoodPlanks
	marker.Transparency = 1
	kit("WarehouseBaskets", Vector3.new(wx, 0, wz), "chest")
	-- The depot is a visual marker, not a wall between the player and the server reach target.
	marker.CanCollide, marker.CanQuery, marker.CanTouch = false, false, false
	marker:SetAttribute("ForgeWarehouseTribe", source.tribe.config.tribeId)
	local warehousePrompt = Instance.new("ProximityPrompt")
	warehousePrompt.Name = "ForgeWarehouse"
	require(Forge.games["robango-island"].src.shared.WorldText).bind(warehousePrompt, "warehouse_open", "warehouse")
	warehousePrompt.KeyboardKeyCode = Enum.KeyCode.E
	warehousePrompt.MaxActivationDistance, warehousePrompt.HoldDuration = 8, 0
	warehousePrompt.RequiresLineOfSight, warehousePrompt.Enabled = false, true
	warehousePrompt:SetAttribute("ForgeWarehouse", true)
	warehousePrompt.Parent = marker
	local spawn = Instance.new("SpawnLocation")
	spawn.Name, spawn.Anchored, spawn.Position, spawn.Size =
		"SurvivalSpawn", true, Vector3.new(0, 0.5, 0), Vector3.new(4, 1, 4)
	spawn.Material, spawn.Color, spawn.Transparency = Enum.Material.Cobblestone, rgb(164, 156, 138), 0
	spawn.Neutral, spawn.Duration, spawn.Parent = true, 0, geometry
	decor(
		"SpawnCompassRing",
		Vector3.new(0.25, 6.5, 6.5),
		CFrame.new(0, 0.08, 0) * CFrame.Angles(0, 0, math.rad(90)),
		rgb(132, 124, 108),
		Enum.PartType.Cylinder,
		Enum.Material.Cobblestone
	)
	local world: any = World.new({
		content = content,
		worldRevision = source.worldRevision,
		spawn = spawn,
		carriedContainer = "bag",
		reachStuds = 8,
		baseWalkSpeed = 16,
		cosmetics = require(Forge.games["robango-island"].src.shared.CosmeticConfig),
		itemNames = itemNames,
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
	world.roleWildlife = wildlifePolicy
	local campfire = part("campfire", Vector3.new(3, 1, 3), Vector3.new(-6, 0.5, 0), rgb(96, 92, 86))
	campfire.Material = Enum.Material.Cobblestone
	campfire.Transparency = 1
	kit("Campfire", Vector3.new(-6, 0, 0), "campfire")

	local bench = part("workbench", Vector3.new(4, 2, 2), Vector3.new(6, 1, 0), rgb(134, 92, 54))
	bench.Material = Enum.Material.WoodPlanks
	bench.Transparency = 1
	kit("WorkbenchFrame", Vector3.new(6, 0, 0), "workbench")
	decor(
		"WorkbenchAnvil",
		Vector3.new(1.1, 0.65, 0.8),
		CFrame.new(4.8, 3.75, -0.2),
		rgb(92, 98, 106),
		nil,
		Enum.Material.Metal
	)
	decor(
		"WorkbenchMalletHead",
		Vector3.new(0.7, 0.4, 0.4),
		CFrame.new(6.8, 3.65, 0.3) * CFrame.Angles(0, math.rad(28), 0),
		rgb(108, 112, 118),
		nil,
		Enum.Material.Slate
	)
	decor(
		"WorkbenchMalletHandle",
		Vector3.new(0.18, 0.9, 0.18),
		CFrame.new(6.5, 3.55, 0.5) * CFrame.Angles(math.rad(82), math.rad(20), 0),
		rgb(168, 126, 78),
		nil,
		Enum.Material.Wood
	)
	decor(
		"WorkbenchRack",
		Vector3.new(4.2, 1.8, 0.22),
		CFrame.new(6, 4.3, -1.7),
		rgb(112, 76, 44),
		nil,
		Enum.Material.WoodPlanks
	)
	world.registerStation(campfire, "campfire", "campfire")
	world.registerStation(bench, "workbench", "workbench")
	world.musicVenues = function()
		return { { enabled = true, part = campfire } }
	end

	-- One builder per node kind: the returned part is the registered gather target (anchored,
	-- collidable, short enough that its prompt sits within reach); the rest is silhouette decor.
	type Builder = (id: string, p: Vector3, h: number) -> BasePart
	local builders: { [string]: Builder } = {
		["fallen-tree"] = function(id, p)
			local log = part(id, Vector3.new(6, 2, 2), p, rgb(105, 70, 42)) :: Part
			log.Shape, log.Material = Enum.PartType.Cylinder, Enum.Material.Wood
			decor(
				id .. "-heartL",
				Vector3.new(0.15, 1.55, 1.55),
				CFrame.new(p + Vector3.new(-2.98, 0, 0)),
				rgb(186, 144, 96),
				Enum.PartType.Cylinder,
				Enum.Material.Wood
			)
			decor(
				id .. "-heartR",
				Vector3.new(0.15, 1.55, 1.55),
				CFrame.new(p + Vector3.new(2.98, 0, 0)),
				rgb(186, 144, 96),
				Enum.PartType.Cylinder,
				Enum.Material.Wood
			)
			decor(
				id .. "-moss1",
				Vector3.new(2.4, 0.35, 1.4),
				CFrame.new(p + Vector3.new(-0.8, 0.95, 0)),
				rgb(76, 126, 54),
				Enum.PartType.Ball,
				Enum.Material.Grass
			)
			decor(
				id .. "-moss2",
				Vector3.new(1.8, 0.3, 1.2),
				CFrame.new(p + Vector3.new(1.3, 0.92, 0.15)),
				rgb(88, 138, 62),
				Enum.PartType.Ball,
				Enum.Material.Grass
			)
			decor(
				id .. "-branch",
				Vector3.new(2.2, 0.55, 0.55),
				CFrame.new(p + Vector3.new(0.6, 1.35, -0.4)) * CFrame.Angles(0, math.rad(25), math.rad(48)),
				rgb(96, 64, 38),
				Enum.PartType.Cylinder,
				Enum.Material.Wood
			)
			decor(
				id .. "-leaves",
				Vector3.new(1.8, 1.4, 1.8),
				CFrame.new(p + Vector3.new(1.1, 2.0, -0.6)),
				rgb(68, 118, 48),
				Enum.PartType.Ball,
				Enum.Material.Grass
			)
			return log
		end,
		["flint-outcrop"] = function(id, p)
			local rock = part(id, Vector3.new(4, 4, 3), p, rgb(92, 100, 114), "WedgePart")
			rock.Material = Enum.Material.Slate
			rock.Transparency = 1
			kit(id .. ".cluster", p - Vector3.new(0, 2, 0), "rock")
			decor(
				id .. "-spire1",
				Vector3.new(2.2, 3.2, 2.0),
				CFrame.new(p + Vector3.new(-1.4, -0.4, 0.4)) * CFrame.Angles(0, math.rad(35), 0),
				rgb(72, 78, 92),
				nil,
				Enum.Material.Slate
			)
			decor(
				id .. "-spire2",
				Vector3.new(1.8, 2.6, 1.8),
				CFrame.new(p + Vector3.new(1.5, -0.7, -0.3)) * CFrame.Angles(0, math.rad(-28), math.rad(12)),
				rgb(110, 116, 128),
				nil,
				Enum.Material.Rock
			)
			decor(
				id .. "-vein1",
				Vector3.new(0.45, 1.8, 0.85),
				CFrame.new(p + Vector3.new(0.2, 0.4, -1.1)) * CFrame.Angles(math.rad(18), math.rad(12), 0),
				rgb(44, 52, 64),
				nil,
				Enum.Material.Glass
			)
			decor(
				id .. "-vein2",
				Vector3.new(0.35, 1.3, 0.65),
				CFrame.new(p + Vector3.new(-0.7, 0.1, -1.1)) * CFrame.Angles(math.rad(14), math.rad(-20), 0),
				rgb(52, 62, 78),
				nil,
				Enum.Material.Glass
			)
			return rock
		end,
		["fiber-bush"] = function(id, p)
			local shape = part(id, Vector3.new(1, 4, 2), p, rgb(122, 152, 64))
			shape.Material = Enum.Material.Grass
			shape.Transparency = 1
			kit(id .. ".fern", p - Vector3.new(0, 2, 0), "fern")
			-- Accent parts never collide or answer queries: a colliding blade blocked the reach ray.
			local blade = part(id .. "-blade", Vector3.new(3, 3, 0.5), p, rgb(104, 138, 54))
			blade.Material = Enum.Material.Grass
			blade.CanCollide, blade.CanQuery = false, false
			blade.Transparency = 1
			return shape
		end,
		["berry-bush"] = function(id, p)
			local bush = part(id, Vector3.new(4, 4, 4), p, rgb(49, 112, 59)) :: Part
			bush.Shape, bush.Material = Enum.PartType.Ball, Enum.Material.Grass
			bush.Transparency = 1
			kit(id .. ".foliage", p - Vector3.new(0, 2, 0), "bush")
			decor(
				id .. "-lobe1",
				Vector3.new(3.1, 2.8, 3.1),
				CFrame.new(p + Vector3.new(-1.1, -0.4, 0.6)),
				rgb(42, 98, 52),
				Enum.PartType.Ball,
				Enum.Material.Grass
			)
			decor(
				id .. "-lobe2",
				Vector3.new(2.9, 2.7, 2.9),
				CFrame.new(p + Vector3.new(1.1, -0.3, -0.5)),
				rgb(58, 124, 66),
				Enum.PartType.Ball,
				Enum.Material.Grass
			)
			local berries =
				part(id .. "-berries", Vector3.new(1.5, 1.5, 1.5), p + Vector3.new(0, 1, -1.5), rgb(185, 42, 78))
			local fruit = berries :: Part
			fruit.Shape, fruit.CanCollide, fruit.CanQuery = Enum.PartType.Ball, false, false
			for idx, offset in
				{
					Vector3.new(0.9, 0.8, -1.3),
					Vector3.new(-0.9, 0.7, -1.2),
					Vector3.new(1.3, 0.3, 0.8),
					Vector3.new(-1.2, 0.5, 0.9),
					Vector3.new(0, 1.4, 0.7),
				}
			do
				decor(
					id .. "-berry" .. idx,
					Vector3.new(0.65, 0.65, 0.65),
					CFrame.new(p + offset),
					rgb(212, 48, 86),
					Enum.PartType.Ball
				)
			end
			return bush
		end,
		["meat-cache"] = function(id, p)
			local shape = part(id, Vector3.new(3, 2, 3), p, rgb(138, 86, 52))
			shape.Material = Enum.Material.WoodPlanks
			local bone = part(id .. "-bone", Vector3.new(4, 0.5, 0.5), p + Vector3.new(0, 1.25, 0), rgb(232, 222, 194))
			bone.CanCollide, bone.CanQuery = false, false
			decor(
				id .. "-rackL",
				Vector3.new(0.28, 3.2, 0.28),
				CFrame.new(p + Vector3.new(-1.3, 1.2, 0)) * CFrame.Angles(math.rad(12), 0, 0),
				rgb(96, 64, 38),
				nil,
				Enum.Material.Wood
			)
			decor(
				id .. "-rackR",
				Vector3.new(0.28, 3.2, 0.28),
				CFrame.new(p + Vector3.new(1.3, 1.2, 0)) * CFrame.Angles(math.rad(-12), 0, 0),
				rgb(96, 64, 38),
				nil,
				Enum.Material.Wood
			)
			decor(
				id .. "-bar",
				Vector3.new(3.2, 0.24, 0.24),
				CFrame.new(p + Vector3.new(0, 2.5, 0)),
				rgb(112, 76, 46),
				nil,
				Enum.Material.Wood
			)
			decor(
				id .. "-haunch1",
				Vector3.new(0.85, 1.3, 0.65),
				CFrame.new(p + Vector3.new(-0.55, 1.7, 0)),
				rgb(168, 64, 52),
				Enum.PartType.Ball
			)
			decor(
				id .. "-haunch2",
				Vector3.new(0.75, 1.15, 0.6),
				CFrame.new(p + Vector3.new(0.55, 1.75, 0)),
				rgb(154, 58, 48),
				Enum.PartType.Ball
			)
			return shape
		end,
		["branch-pile"] = function(id, p)
			local pile = part(id, Vector3.new(3, 1, 2), p, rgb(120, 86, 52))
			pile.Material = Enum.Material.Wood
			for index = 1, 3 do
				decor(
					id .. "-stick" .. index,
					Vector3.new(3.4, 0.3, 0.3),
					CFrame.new(p + Vector3.new(0, 0.6, (index - 2) * 0.5)) * CFrame.Angles(0, math.rad(index * 25), 0),
					rgb(104, 72, 44),
					nil,
					Enum.Material.Wood
				)
			end
			return pile
		end,
		["stone-pile"] = function(id, p)
			local pile = part(id, Vector3.new(3, 1.5, 3), p, rgb(128, 128, 122))
			pile.Material = Enum.Material.Slate
			decor(
				id .. "-top",
				Vector3.new(1.4, 1, 1.2),
				CFrame.new(p + Vector3.new(0.4, 1, 0.2)),
				rgb(146, 144, 136),
				Enum.PartType.Ball,
				Enum.Material.Slate
			)
			return pile
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
		local base = position.Y - height / 2
		-- Worn approaches follow the heightfield, rather than disappearing under grass.
		for step = 0, 8 do
			local x, z = position.X * step / 8, 8 + (position.Z - 8) * step / 8
			local y = if step == 8 then base else ground(x, z)
			workspace.Terrain:FillBlock(CFrame.new(x, y - 1.8, z), Vector3.new(4, 4, 4), Enum.Material.Ground)
		end
		local shape = build(node.id, position, height)
		world.registerNode(shape, node.id, node.catalogId, 0, source.worldRevision)
	end
	-- FillBlock rasterizes on four-stud voxels. Fractional clearing planes left occupied
	-- voxels above the canonical gather target; later nodes' paths also refilled earlier
	-- clearings. Cut aligned clearings LAST, with their ground plane below each target.
	for _, node in source.nodes do
		local p = node.position
		local height = IslandTerrain.NODE_HEIGHT[node.catalogId] or 2
		-- Terrain's smoothed collision surface extends above the filled voxel plane.
		-- Keep one empty voxel below the node as well, not merely below its centre.
		local base = math.floor((p.y - height / 2) / 4) * 4 - 4
		local x, z = math.floor(p.x / 4) * 4, math.floor(p.z / 4) * 4
		workspace.Terrain:FillBlock(
			CFrame.new(x, base + 8, z),
			Vector3.new(CLEARING_STUDS, 16, CLEARING_STUDS),
			Enum.Material.Air
		)
		workspace.Terrain:FillBlock(
			CFrame.new(x, base - 2, z),
			Vector3.new(CLEARING_STUDS, 4, CLEARING_STUDS),
			Enum.Material.Ground
		)
	end
	-- Approach the nodes from z=8 for clear reach; the wall blocks the berry lane.
	local losWall = part("GatherLOSWall", Vector3.new(6, 7, 1), Vector3.new(10, 3.5, 10), rgb(118, 120, 112))
	losWall.Material = Enum.Material.Cobblestone
	decor(
		"GatherWallCap",
		Vector3.new(6.4, 0.45, 1.35),
		CFrame.new(10, 7.1, 10),
		rgb(98, 102, 94),
		nil,
		Enum.Material.Slate
	)
	decor(
		"GatherWallMoss",
		Vector3.new(3.2, 0.35, 1.2),
		CFrame.new(9.2, 7.25, 10),
		rgb(74, 118, 56),
		nil,
		Enum.Material.Grass
	)
	local roof = part("CameraTestRoof", Vector3.new(12, 1, 8), Vector3.new(-16, 9, 0), rgb(134, 92, 54))
	roof.Material = Enum.Material.WoodPlanks
	roof.Transparency = 1
	-- Invisible camera-fade marker over the shelter (camera-occlusion QA name). p68: as a collidable,
	-- queryable part it was the support hit for camp cells and the dodo, so the build ghost and the
	-- server verify read "no flat ground" there. Like decor and QA marks, it never collides or answers
	-- queries (placement, ground and reach rays all skip it).
	roof.CanCollide, roof.CanQuery, roof.CanTouch = false, false, false
	CollectionService:AddTag(roof, "ForgeCameraOccluder")
	kit("Shelter", Vector3.new(-16, 0, 0), "shelter")
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
		local kind = if math.abs(z) > 55 then "palm" elseif math.floor(x) % 2 == 0 then "conifer" else "tree"
		kit("Forest" .. x .. "." .. z, Vector3.new(x, y, z), kind)
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
	world.structureKits = kits
	return world
end
