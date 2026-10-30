--!strict
-- Catalog projection shared by the pack's live role builders. The factory consumes
-- exactly the node and wildlife lists rendered here, not the legacy preview lists.
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local World = require(Forge.genres["survival-coop"].module.SurvivalWorld)
local Terrain = require(Forge.core.domain.island.ArchipelagoTerrain)
local Journal = require(Forge.core.domain.command.Journal)
local Rng = require(Forge.core.domain.random.Rng)
local Herd = require(Forge.genres["survival-coop"].module.Herd)
local Dressing = require("./WorldDressing")
local Meshes = require("./StructureMeshes")
local WorldText = require(Forge.games["robango-island"].src.shared.WorldText)
local RenderBudget = require(Forge.games["robango-island"].src.shared.RenderBudget)
local BiomeKits = require(Forge.games["robango-island"].src.shared.BiomeKits)
local Assets = require(Forge.games["robango-island"].src.shared.Assets)
local NodeMeshes = require(Forge.games["robango-island"].src.shared.NodeMeshes)
local MeshTexture = require(Forge.games["robango-island"].src.shared.MeshTexture)
local CharacterRules = require(Forge.genres["survival-coop"].module.CharacterRules)
local SkyCycle = require(Forge.games["robango-island"].src.shared.SkyCycle)
local TownLife = require("./TownLife")
local BiomeLook = require(Forge.games["robango-island"].src.shared.BiomeLook)
-- L7: tools and worn gear render the mesh-tools package (ToolVisuals) through the genre hooks.
-- The package loads off the build path; tools projected before it lands keep the genre default.
local function toolVisuals(): any
	local ToolVisuals = require(Forge.games["robango-island"].src.shared.ToolVisuals)
	task.spawn(ToolVisuals.load, Assets)
	return ToolVisuals.hooks()
end
-- Tool names in the engine Backpack hotbar follow the owner's locale (locale/strings.csv,
-- shipped as the Strings LocalizationTable); rows are read once, on first use.
local packRows: any = nil
local function itemNames(locale: string): { [string]: string }
	local PackText = require(Forge.games["robango-island"].src.shared.PackText)
	packRows = packRows or PackText.fromEntries(Forge.games["robango-island"].Strings:GetEntries())
	return PackText.names(packRows)(locale)
end
local materials: any = Enum.Material
local shapes: any = Enum.PartType
local M = {}

-- B2a/B2b skinned templates (manifest creature-<lowercased species>), all 24 content species; a
-- species whose template fails to load keeps the part rig.
M.MESH_SPECIES = table.freeze({
	"compsognathus",
	"oviraptor",
	"gallimimus",
	"utahraptor",
	"velociraptor",
	"dilophosaurus",
	"allosaurus",
	"tyrannosaurus",
	"protoceratops",
	"triceratops",
	"brachiosaurus",
	"stegosaurus",
	"ankylosaurus",
	"parasaurolophus",
	"smilodon",
	"tropicalSmilodon",
	"direWolf",
	"boar",
	"deer",
	"mammoth",
	"elephant",
	"crocodile",
	"turtle",
	"dodo",
})
-- D1 (G21): the role world waits at most this long for its own species' templates; a slower
-- InsertService leaves those rigs as part rigs instead of holding the world.
M.MESH_WAIT_SECONDS = 8

--- Skinned species a role renders while it is built and bound: authored spawns (a species with no
--- mesh of its own renders as the grazer/hunter stand-in, brachiosaurus/allosaurus), the arrival
--- fauna, the onboarding grazers and the explore sauropod. Every other species (pets and mounts
--- a player brings) loads in the background after these.
function M.roleSpecies(content: any, layout: any, fauna: { any }): { string }
	local wanted: { [string]: boolean } = {}
	local function add(species: string)
		if table.find(M.MESH_SPECIES, species) then
			wanted[species] = true
			return
		end
		local engine = "hunter"
		for _, entry in content.wildlife or {} do
			if entry.id == species and (entry.behavior == "grazer" or entry.behavior == "herd-grazer") then
				engine = "grazer"
			end
		end
		wanted[if engine == "grazer" then "brachiosaurus" else "allosaurus"] = true
	end
	for _, spawn in layout.spawns do
		add(spawn.speciesId)
	end
	for _, creature in fauna do
		add(creature.species)
	end
	if layout.id == "rw.onboarding" then
		add("triceratops")
	elseif string.match(layout.id, "^rw%.explore%d+$") then
		add("brachiosaurus")
	end
	local result = {}
	for _, species in M.MESH_SPECIES do
		if wanted[species] then
			table.insert(result, species)
		end
	end
	return result
end

local meshFolder: Instance? = nil
local meshTemplates: { [string]: Instance } = {}
local meshLoading: { [string]: boolean } = {}
local function loadSpecies(load: (number) -> Instance, ids: { [string]: string }, species: string)
	if meshTemplates[species] or meshLoading[species] then
		return
	end
	local id = tonumber(string.match(ids["creature-" .. string.lower(species)] or "", "^rbxassetid://(%d+)$"))
	if not id then
		return
	end
	meshLoading[species] = true
	-- One thread per package: the loads overlap instead of queueing (24 sequential LoadAssets held
	-- every role world for ~10-20 s on staging v36).
	task.spawn(function()
		local ok, loaded = pcall(load, id)
		local mesh = if ok and loaded then loaded:FindFirstChildWhichIsA("MeshPart", true) else nil
		if mesh then
			MeshTexture.bake(mesh)
			mesh.Name, mesh.Parent = species, meshFolder
			meshTemplates[species] = mesh
		else
			warn("CREATURE_TEMPLATE_UNAVAILABLE:" .. species)
		end
		if ok and loaded then
			loaded:Destroy()
		end
		meshLoading[species] = nil
	end)
end

--- Blocks until none of `species` is still loading, or MESH_WAIT_SECONDS pass.
function M.awaitMeshes(species: { string })
	local started = os.clock()
	for _, name in species do
		while meshLoading[name] and os.clock() - started < M.MESH_WAIT_SECONDS do
			task.wait()
		end
	end
end

--- Starts the role's species loads at once (in parallel) and returns without waiting; the rest of
--- MESH_SPECIES load afterwards on a deferred thread. Pair with awaitMeshes before building rigs.
function M.startMeshes(load: (number) -> Instance, storage: Instance, ids: { [string]: string }, first: { string }?)
	if not meshFolder then
		local folder = Instance.new("Folder")
		folder.Name = "ForgeCreatureTemplates"
		folder.Parent = storage
		meshFolder = folder
		require(Forge.genres["survival-coop"].module.DinosaurRig).configureMeshes({
			source = function(species: string): Instance?
				return meshTemplates[species]
			end,
		})
	end
	local wanted: { string } = first or M.MESH_SPECIES :: any
	for _, species in wanted do
		loadSpecies(load, ids, species)
	end
	task.defer(function()
		M.awaitMeshes(wanted)
		for _, species in M.MESH_SPECIES do
			loadSpecies(load, ids, species)
		end
	end)
end

M.travelSerial = 0
--- Publishes a dock travel result to the player as "<outcome>|<serial>"; the HUD
--- tracker shows each new value for a few seconds. Also logged for Studio QA.
function M.publishTravel(player: any, outcome: string)
	M.travelSerial += 1
	print("ForgeTravel " .. tostring(player.UserId) .. " " .. outcome)
	player:SetAttribute("ForgeTravelResult", outcome .. "|" .. tostring(M.travelSerial))
end

function M.build(content: any, source: any, policy: any, nowMillis: any, layoutId: string, seed: number): any
	local hasInsert, insert = pcall(function()
		return game:GetService("InsertService")
	end)
	local layout: any = nil
	for _, candidate in content.layouts do
		if candidate.id == layoutId then
			layout = candidate
		end
	end
	assert(layout, "UNKNOWN_ROLE_LAYOUT:" .. layoutId)
	-- B3 mesh rows (InsertService); an empty table keeps the primitive kits.
	local meshRows = Meshes.load()
	local root = Instance.new("Folder")
	root.Name = "ForgeRoleWorld"
	-- Clients re-derive the ProcProps decor plan from these before it replicates.
	root:SetAttribute("ForgeLayoutId", layoutId)
	root:SetAttribute("ForgeWorldSeed", seed)
	-- C1: the camp plot grid starts at the ridge camp plot anchor (opening-script.md section 1). Set
	-- before the root replicates: the client reads it once, right after ForgeRoleWorld arrives.
	local campPlot = { x = -32, z = -16 }
	for _, anchor in layout.anchors do
		campPlot = if anchor.id == "station.campfire.t1" then anchor.position else campPlot
	end
	if layoutId == "rw.onboarding" then
		root:SetAttribute("ForgeCampOrigin", Vector3.new(campPlot.x, 4, campPlot.z))
	end
	root.Parent = workspace
	local function part(id: string, position: any, size: any): any
		local value = Instance.new("Part")
		value.Name, value.Anchored = id, true
		value.Size = Vector3.new(size.x, size.y, size.z)
		value.Position = Vector3.new(position.x, position.y, position.z)
		-- Untinted markers (survey, journal, mission) read as crates, not grey plates.
		value.Material, value.Color = Enum.Material.WoodPlanks, Color3.fromRGB(150, 110, 70)
		value.Parent = root
		return value
	end
	-- L6: townspeople and castaways stand as survivor figures (SurvivorAvatar rigs, welded to the
	-- handle so moving it moves them) once the survivor package loads; until then, or when it
	-- fails or the engine is headless, the handle part stays the visible stand-in.
	local function survivorFigure(name: string, handle: BasePart, options: any?)
		-- Headless fixtures carry no SurvivorAvatar module (a plain table without the key).
		local module = (Forge.games["robango-island"].src.shared :: any).SurvivorAvatar
		if not module then
			return
		end
		local Survivor = require(module) :: any
		if type(Survivor) ~= "table" or not Survivor.onRigs then
			return
		end
		Survivor.onRigs(function()
			if handle.Parent and Survivor.figure(name, handle, options) then
				handle.Transparency = 1
			end
		end)
	end
	-- A mesh row stretched to a gameplay box (timber modules, pads): the row's parts are scaled per axis
	-- to the box and hung under it; the box keeps its collision and turns invisible. Returns false
	-- (the box stays a visible Part) when the row is missing.
	local function fitRow(target: BasePart, key: string): boolean
		-- Re-fitting replaces the visual: the box may have moved or resized since the last fit.
		local previous = target:FindFirstChild("ForgeMeshVisual")
		if previous then
			previous:Destroy()
		end
		local visual = Meshes.clone(key, { decor = true })
		if not visual then
			return false
		end
		local low, high = Vector3.one * math.huge, -Vector3.one * math.huge
		for _, item in visual:GetDescendants() do
			if item:IsA("BasePart") then
				low = low:Min(item.Position - item.Size / 2)
				high = high:Max(item.Position + item.Size / 2)
			end
		end
		local size, centre = high - low, (low + high) / 2
		local scale = Vector3.new(
			target.Size.X / math.max(size.X, 0.05),
			target.Size.Y / math.max(size.Y, 0.05),
			target.Size.Z / math.max(size.Z, 0.05)
		)
		for _, item in visual:GetDescendants() do
			if item:IsA("BasePart") then
				local offset = (item.Position - centre) * scale
				item.Size *= scale
				item.CFrame = target.CFrame * CFrame.new(offset) * item.CFrame.Rotation
				item.Position = item.CFrame.Position
			end
		end
		visual.Parent = target
		target.Transparency = 1
		return true
	end
	-- Survey markers take the B1 survey cairn once the node packages load (node mesh pass below).
	local surveyCairns: { BasePart } = {}
	local columns: { any } = if layoutId == "rw.home"
		then {}
		else Terrain.columns(layout, seed, if layoutId == "rw.onboarding" then 16 else 32)
	local dressing = Dressing.plan(layout, columns, Terrain)
	-- D1 (G21): package loads start now and overlap the terrain writes below. Only this role's
	-- creature species and biome kits load up front (not all 24 species and 9 kits).
	local roleSpecies = M.roleSpecies(content, layout, dressing.fauna)
	if hasInsert and insert then
		M.startMeshes(function(id: number): Instance
			return insert:LoadAsset(id)
		end, game:GetService("ServerStorage"), Assets :: any, roleSpecies)
	end
	if #columns > 0 then
		task.spawn(BiomeKits.load, BiomeKits.kitsFor(layout), Assets)
	end
	-- Roblox's animated grass is avatar-height. Keep interaction approaches clear.
	local function interactionGround(x: number, z: number, margin: number): boolean
		for _, node in layout.resourceNodes do
			if (x - node.position.x) ^ 2 + (z - node.position.z) ^ 2 <= (24 + margin) ^ 2 then
				return true
			end
		end
		for _, path in layout.paths do
			for index = 2, #path.points do
				if
					Terrain.distance(x, z, path.points[index - 1], path.points[index])
					<= path.width / 2 + 24 + margin
				then
					return true
				end
			end
		end
		for _, spawn in layout.spawns do
			if (x - spawn.position.x) ^ 2 + (z - spawn.position.z) ^ 2 <= (spawn.radius + 24 + margin) ^ 2 then
				return true
			end
		end
		for _, anchor in layout.anchors do
			if
				anchor.id == "entry" and (x - anchor.position.x) ^ 2 + (z - anchor.position.z) ^ 2 <= (24 + margin) ^ 2
			then
				return true
			end
		end
		return false
	end
	workspace:SetAttribute("ForgeWorldBiome", layout.biomes[1])
	-- Light, fire and smoke children for a dressing effect (lava, fire, lamp, steam, ash).
	local function addEffect(value: any, effect: string)
		if value:FindFirstChild("ForgeEffect") then
			return
		end
		local marker = Instance.new("Folder")
		marker.Name, marker.Parent = "ForgeEffect", value
		if effect == "lava" or effect == "fire" or effect == "lamp" then
			local light = Instance.new("PointLight")
			light.Color, light.Brightness, light.Range, light.Parent = Color3.fromRGB(255, 112, 26), 0.8, 10, value
		end
		if effect == "fire" then
			local fire = Instance.new("Fire")
			fire.Size, fire.Heat, fire.Parent = 2, 4, value
		elseif effect ~= "lava" and effect ~= "lamp" then
			local smoke = Instance.new("Smoke")
			smoke.Color = if effect == "steam" then Color3.fromRGB(224, 234, 230) else Color3.fromRGB(95, 91, 85)
			smoke.Size, smoke.RiseVelocity, smoke.Opacity, smoke.Parent =
				if effect == "ash" then 22 else 7, 9, 0.35, value
		end
		if effect == "ash" then
			local ash = Instance.new("ParticleEmitter")
			ash.Texture, ash.Rate = "rbxasset://textures/particles/smoke_main.dds", 12
			ash.Lifetime, ash.Speed = NumberRange.new(3, 5), NumberRange.new(7, 12)
			ash.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 12) })
			ash.Transparency =
				NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
			ash.Color, ash.Parent = ColorSequence.new(Color3.fromRGB(87, 81, 74)), value
		end
	end
	local function style(value: any, definition: any)
		value.Material = materials[definition.material or dressing.palette.ground]
		if definition.color then
			value.Color = Color3.fromRGB(table.unpack(definition.color))
		end
		if definition.shape and definition.shape ~= "Wedge" then
			value.Shape = shapes[definition.shape]
		end
		if definition.ellipsoid and not value:FindFirstChild("Ellipsoid") then
			local mesh = Instance.new("SpecialMesh")
			mesh.Name, mesh.MeshType, mesh.Parent = "Ellipsoid", Enum.MeshType.Sphere, value
		end
		value.CFrame = CFrame.new(definition.position.x, definition.position.y, definition.position.z)
			* CFrame.Angles(0, math.rad(definition.yaw or 0), math.rad(definition.roll or 0))
		if definition.decorative then
			value.CanCollide, value.CanTouch, value.CanQuery = false, false, false
		end
		if definition.effect then
			addEffect(value, definition.effect)
		end
	end
	-- Include only Terrain: another prop, path or canopy can never become ground.
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Include
	groundParams.FilterDescendantsInstances = { workspace.Terrain }
	groundParams.IgnoreWater = true
	-- Relief layouts write far chunks asynchronously; where a ray finds no voxels yet, the
	-- deterministic height field gives the ground (legacy layouts: nil, as before).
	local function probe(x: number, z: number): number?
		local hit = workspace:Raycast(Vector3.new(x, 512, z), Vector3.new(0, -1024, 0), groundParams)
		return if hit then hit.Position.Y else Terrain.surface(layout, seed, x, z)
	end
	local function grounded(definition: any): any
		local ground = definition.ground
			or {
				x = definition.position.x,
				y = definition.position.y - definition.size.y / 2,
				z = definition.position.z,
			}
		local roll = math.rad(definition.roll or 0)
		local bottom = definition.position.y
			- (math.abs(math.sin(roll)) * definition.size.x + math.abs(math.cos(roll)) * definition.size.y) / 2
		if bottom <= ground.y + 0.5 then
			ground = { x = definition.position.x, y = bottom, z = definition.position.z }
		end
		local hitY = probe(ground.x, ground.z)
		if not hitY then
			return nil
		end
		local result = table.clone(definition)
		result.position = {
			x = definition.position.x,
			y = definition.position.y + hitY - ground.y - 0.15,
			z = definition.position.z,
		}
		return result
	end
	local lighting = game:GetService("Lighting")
	local initialAtmosphere = lighting:FindFirstChild("ForgeAtmosphere")
	if initialAtmosphere then
		initialAtmosphere:Destroy()
	end
	-- G18: 24-minute day cycle and climate weather. The server publishes the seeded cycle origin
	-- (server-clock seconds); clients drive Lighting from workspace:GetServerTimeNow() through the
	-- same pure SkyCycle functions. This sets the build-time baseline. No DepthOfField.
	local skyOrigin = SkyCycle.origin(layoutId, seed, math.floor(nowMillis() / 1000))
	workspace:SetAttribute("ForgeSkyOrigin", skyOrigin)
	workspace:SetAttribute("ForgeSkyLayout", layoutId)
	workspace:SetAttribute("ForgeSkySeed", seed)
	workspace:SetAttribute("ForgeSkyFog", Color3.fromRGB(table.unpack(dressing.palette.fog)))
	SkyCycle.ensure(lighting)
	local buildSeconds = nowMillis() / 1000
	-- L12: biome islands carry their own day grade, water, material colours, grading and coast.
	local look = BiomeLook.of(layout)
	SkyCycle.apply(
		lighting,
		SkyCycle.state(buildSeconds, skyOrigin, dressing.palette.fog, look),
		SkyCycle.weatherAt(content, layout, seed, buildSeconds, buildSeconds, nil),
		true,
		workspace.Terrain
	)
	local correction: any = lighting:FindFirstChild(SkyCycle.GRADE)
	local bloom: any = lighting:FindFirstChild(SkyCycle.BLOOM)
	local atmosphere: any = lighting:FindFirstChild(SkyCycle.ATMOSPHERE)
	workspace.Terrain.WaterTransparency = if look then look.transparency else 0.35
	local field = if Terrain.relief(layout) then Terrain.field(layout, seed) else nil
	if not field then
		-- The sea covers the island plus a margin; the 1536-stud town (C5a) is wider than the 1400 default.
		local sea = math.max(1400, layout.bounds.max.x - layout.bounds.min.x + 256)
		workspace.Terrain:FillBlock(CFrame.new(0, -10, 0), Vector3.new(sea, 12, sea), Enum.Material.Water)
	end
	local coastline = if field then field.coast elseif Terrain.organic(layout) then Terrain.coast(layout, seed) else nil
	local gradedInland = coastline == nil and Terrain.graded(layout)
	local function nearPath(x: number, z: number, reach: number): boolean
		for _, path in layout.paths do
			for index = 2, #path.points do
				if Terrain.distance(x, z, path.points[index - 1], path.points[index]) <= path.width / 2 + reach then
					return true
				end
			end
		end
		return false
	end
	if coastline and not field then
		-- Organic islands keep only land columns; a single sand floor stands in for the seabed.
		workspace.Terrain:FillBlock(CFrame.new(0, -14, 0), Vector3.new(1400, 4, 1400), Enum.Material.Sand)
	end
	-- Ground reads as warm trampled earth, moss as a darker olive and scree (Pavement) as grey
	-- gravel (L10: next to R03-3 / R05-1 the old green Ground made spawn clearings one flat lawn).
	workspace.Terrain:SetMaterialColor(Enum.Material.Ground, Color3.fromRGB(112, 100, 66))
	workspace.Terrain:SetMaterialColor(Enum.Material.Limestone, Color3.fromRGB(122, 126, 92))
	workspace.Terrain:SetMaterialColor(Enum.Material.LeafyGrass, Color3.fromRGB(90, 108, 54))
	workspace.Terrain:SetMaterialColor(Enum.Material.Grass, Color3.fromRGB(102, 118, 62))
	workspace.Terrain:SetMaterialColor(Enum.Material.Pavement, Color3.fromRGB(122, 116, 102))
	if layoutId == "rw.town" then
		-- The town paints no moss patches; its Limestone is the still grass of the road approaches.
		workspace.Terrain:SetMaterialColor(Enum.Material.Limestone, Color3.fromRGB(100, 114, 60))
	end
	-- Biome islands: their own sand, rock, mud, snow, basalt, ... colours (BiomeLook never touches
	-- the five L10 spawn-screen materials above).
	local lookColours: { [string]: { number } } = if look then look.terrain else {}
	for name, colour in lookColours do
		workspace.Terrain:SetMaterialColor((Enum.Material :: any)[name], Color3.fromRGB(table.unpack(colour)))
	end
	-- Far ground grading (outside the arrival rings and away from authored ground): highland caps,
	-- noise patches of a second ground material and, on volcanoes, lava streaks.
	local arrivals = if look then BiomeKits.arrivals(layout) else {}
	-- Per 8-stud cell of a far column that may grade (terrace lane): the same rules on the cell centre
	-- and its smoothed height, so patches and caps get noise edges, never 32-stud squares. Wet cells
	-- (pond and stream beds) keep their material.
	local function gradeCell(column: any, material: string, x: number, z: number, y: number, wet: boolean): string
		if not look or wet then
			return material
		end
		return BiomeLook.grade(look, material, Terrain.ground(layout, column.x), x, z, y, true)
	end
	local tops, blobs, blobRng = {}, {}, Rng.new(seed):fork(layoutId .. ":ground")
	if field then
		-- Relief islands: per-island sea fill beyond the coast (no shared slab), then land in
		-- 256-stud chunks. Chunks around the authored camp (spawn, nodes, stations) are written now;
		-- the rest follow one chunk per engine step, nearest first, so the first interaction never
		-- waits for the far island.
		local coast, tile = field.coast, 128
		for x = -coast.hx - 256 + tile / 2, coast.hx + 256, tile do
			for z = -coast.hz - 256 + tile / 2, coast.hz + 256, tile do
				local h = tile / 2
				local inside = math.min(
					coast.depth(x - h, z - h),
					coast.depth(x + h, z - h),
					coast.depth(x - h, z + h),
					coast.depth(x + h, z + h)
				)
				if inside <= 0.02 then
					workspace.Terrain:FillBlock(CFrame.new(x, -14, z), Vector3.new(tile, 4, tile), Enum.Material.Sand)
					workspace.Terrain:FillBlock(
						CFrame.new(x, (Terrain.SEA - 12) / 2, z),
						Vector3.new(tile, Terrain.SEA + 12, tile),
						Enum.Material.Water
					)
				end
			end
		end
		local low = { x = math.huge, z = math.huge }
		local high = { x = -math.huge, z = -math.huge }
		for _, list in { layout.resourceNodes, layout.anchors, layout.spawns } do
			for _, item in list do
				low.x, low.z = math.min(low.x, item.position.x), math.min(low.z, item.position.z)
				high.x, high.z = math.max(high.x, item.position.x), math.max(high.z, item.position.z)
			end
		end
		local chunks: { [string]: any } = {}
		local order: { any } = {}
		for _, column in columns do
			local key = math.floor(column.x / 256) .. "," .. math.floor(column.z / 256)
			local chunk = chunks[key]
			if not chunk then
				local cx, cz = (math.floor(column.x / 256) + 0.5) * 256, (math.floor(column.z / 256) + 0.5) * 256
				chunk = {
					columns = {},
					camp = cx + 224 >= low.x and cx - 224 <= high.x and cz + 224 >= low.z and cz - 224 <= high.z,
					distance = math.sqrt(cx * cx + cz * cz),
					key = key,
				}
				chunks[key] = chunk
				table.insert(order, chunk)
			end
			table.insert(chunk.columns, column)
		end
		table.sort(order, function(a, b)
			return if a.distance ~= b.distance then a.distance < b.distance else a.key < b.key
		end)
		-- Far ground (terrace lane, R11-6/R11-7): column tops by cell, so a far column is written as
		-- 8-stud blocks on the bilinear surface through its neighbours' tops instead of one flat
		-- 32-stud block. Hills read as slopes, not stacked square terraces; a flat column stays one block.
		local cellTops: { [string]: number } = {}
		for _, column in columns do
			cellTops[column.x .. "," .. column.z] = column.top
		end
		local SUB = 8
		local CLIFF = 0.3
		local function surface(column: any, sx: number, sz: number): number
			local cell = column.cell
			local fx, fz = (sx - column.x) / cell, (sz - column.z) / cell
			local ix, iz = if fx < 0 then -1 else 1, if fz < 0 then -1 else 1
			local function at(dx: number, dz: number): number
				return cellTops[column.x + dx * cell .. "," .. column.z + dz * cell] or column.top
			end
			local ax, az = math.abs(fx), math.abs(fz)
			local near = column.top + (at(ix, 0) - column.top) * ax
			local far = at(0, iz) + (at(ix, iz) - at(0, iz)) * ax
			return near + (far - near) * az
		end
		local function write(chunk: any)
			for _, column in chunk.columns do
				local material = column.material
				if
					(material == "Grass" or material == "LeafyGrass")
					and interactionGround(column.x, column.z, column.cell)
				then
					material = "Ground"
				end
				local top = column.top
				if field.clear(column.x, column.z) < 96 then
					-- Near authored ground the column is written as 8-stud blocks sampled from the field,
					-- so paths and clearings keep their catalog slope instead of 32-stud steps (4-stud blocks
					-- right at authored ground, where a 2.5-stud step limit applies).
					local sub = if field.clear(column.x, column.z) < 48 then 4 else 8
					for sx = column.x - column.cell / 2 + sub / 2, column.x + column.cell / 2, sub do
						for sz = column.z - column.cell / 2 + sub / 2, column.z + column.cell / 2, sub do
							local y = field.height(sx, sz)
							workspace.Terrain:FillBlock(
								CFrame.new(sx, (y - 16) / 2, sz),
								Vector3.new(sub, y + 16, sub),
								materials[material]
							)
						end
					end
					continue
				end
				-- Ponds and stream channels keep the exact field (their beds are narrower than a cell).
				local wet = column.wet or field.water(column.x, column.z) ~= nil
				local heights, lowest, highest = table.create(16), math.huge, -math.huge
				for sx = column.x - column.cell / 2 + SUB / 2, column.x + column.cell / 2, SUB do
					for sz = column.z - column.cell / 2 + SUB / 2, column.z + column.cell / 2, SUB do
						local y = if wet then field.height(sx, sz) else surface(column, sx, sz)
						table.insert(heights, y)
						lowest, highest = math.min(lowest, y), math.max(highest, y)
					end
				end
				-- Far grading is per 8-stud cell (BiomeLook.grade on the cell centre), so patches and caps
				-- have noise edges instead of 32-stud squares; base-material cells are merged.
				-- Cliff faces are chosen per 8-stud cell from the smoothed slope (Rock where it is steeper
				-- than CLIFF), so cliffs follow the hill instead of painting 32-stud squares.
				local soil = Terrain.ground(layout, column.x)
				local slopeRock = not wet and not column.beach and (material == "Rock" or material == soil)
				local mayGrade = look ~= nil
					and not wet
					and (material == soil or slopeRock)
					and field.clear(column.x, column.z) >= BiomeLook.CLEAR
					and BiomeLook.away(layout, arrivals, column.x, column.z)
				local flat = highest - lowest < 0.5 and not mayGrade and material ~= "Rock"
				if flat then
					workspace.Terrain:FillBlock(
						CFrame.new(column.x, (top - 16) / 2, column.z),
						Vector3.new(column.cell, top + 16, column.cell),
						materials[material]
					)
				else
					local index = 0
					for sx = column.x - column.cell / 2 + SUB / 2, column.x + column.cell / 2, SUB do
						for sz = column.z - column.cell / 2 + SUB / 2, column.z + column.cell / 2, SUB do
							index += 1
							local y = heights[index]
							local cellMaterial = material
							if slopeRock then
								local gx = surface(column, sx + 2, sz) - surface(column, sx - 2, sz)
								local gz = surface(column, sx, sz + 2) - surface(column, sx, sz - 2)
								cellMaterial = if math.sqrt(gx * gx + gz * gz) / 4 > CLIFF then "Rock" else soil
							end
							if mayGrade and cellMaterial == soil then
								cellMaterial = gradeCell(column, soil, sx, sz, y, wet)
							end
							workspace.Terrain:FillBlock(
								CFrame.new(sx, (y - 16) / 2, sz),
								Vector3.new(SUB, y + 16, SUB),
								materials[cellMaterial]
							)
						end
					end
				end
				local water = field.water(column.x, column.z)
				if water and water > lowest then
					-- Water fills over each sub-cell bed below the surface (FillBlock replaces only air here).
					local index = 0
					for sx = column.x - column.cell / 2 + SUB / 2, column.x + column.cell / 2, SUB do
						for sz = column.z - column.cell / 2 + SUB / 2, column.z + column.cell / 2, SUB do
							index += 1
							local y = heights[index]
							if water > y then
								workspace.Terrain:FillBlock(
									CFrame.new(sx, (y + water) / 2, sz),
									Vector3.new(SUB, water - y, SUB),
									Enum.Material.Water
								)
							end
						end
					end
				end
			end
		end
		if look then
			-- Shallows and foam: a sand shelf steps down out of the beach under clear water, with a
			-- Salt foam line at the waterline and a broken surf line on the shelf.
			local coastLook = BiomeLook.coast(look, coast, Terrain.SEA)
			for _, ball in coastLook.shelf do
				workspace.Terrain:FillBall(Vector3.new(ball.x, ball.y, ball.z), ball.radius, Enum.Material.Sand)
			end
			for _, strip in coastLook.foam do
				workspace.Terrain:FillBlock(
					CFrame.new(strip.x, strip.top - 2, strip.z) * CFrame.Angles(0, strip.yaw, 0),
					Vector3.new(strip.width, 4, strip.length),
					Enum.Material.Salt
				)
			end
		end
		local later = {}
		for _, chunk in order do
			if chunk.camp then
				write(chunk)
			else
				table.insert(later, chunk)
			end
		end
		root:SetAttribute("ForgeTerrainChunks", #order)
		task.spawn(function()
			for _, chunk in later do
				if root.Parent == nil then
					return
				end
				write(chunk)
				game:GetService("RunService").Heartbeat:Wait()
			end
			root:SetAttribute("ForgeTerrainReady", true)
		end)
	else
		root:SetAttribute("ForgeTerrainReady", true)
	end
	for _, column in columns do
		tops[column.x .. "," .. column.z] = column.top
	end
	local legacy: { any } = if field then {} else columns
	for _, column in legacy do
		local protected = Terrain.protected(layout, column.x, column.z, column.cell)
		local material = column.material
		-- Town: the road approaches stay clear of avatar-height animated grass, but as Limestone tinted
		-- to the grass colour (still, short) instead of bare Ground: the old 68-stud Ground bands along
		-- every road read as dark rectangles beside R12. TownLife paints the narrow dirt foot paths.
		if
			layoutId == "rw.town"
			and (material == "Grass" or material == "LeafyGrass")
			and interactionGround(column.x, column.z, column.cell)
		then
			material = "Limestone"
		elseif
			(material == "Grass" or material == "LeafyGrass")
			and (layoutId == "rw.onboarding" or interactionGround(column.x, column.z, column.cell))
		then
			local n = math.noise(column.x / 70, column.z / 70, 0.5)
			material = if n < -0.45 then "Limestone" else "Ground"
		end
		local top = column.top
		if not protected and top > 0 then
			local river = math.abs(column.x - math.sin(column.z / 75 + seed) * 42)
			-- Organic islands skip the square river pits: they cut 90-degree notches into the grass.
			-- The town skips them too: D2 (R13) read them as rectangular ponds between the plots.
			if
				not coastline
				and layoutId ~= "rw.town"
				and river < column.cell * 0.55
				and column.z > layout.bounds.min.z + 64
			then
				top, material = -5, "Sand"
			elseif layoutId == "rw.town" then
				-- Sand only on the beach: a land column touching the sea, never the whole flat island.
				local shoreline = top < 1
				for dx = -1, 1 do
					for dz = -1, 1 do
						local near = tops[column.x + dx * column.cell .. "," .. column.z + dz * column.cell]
						shoreline = shoreline or (near ~= nil and near < 1)
					end
				end
				material = if shoreline then "Sand" else material
			elseif if column.beach == nil then top < 8 else column.beach then
				material = "Sand"
			elseif table.find(layout.biomes, "volcano") and column.x < -32 then
				material = if column.x % 96 < 32 then "CrackedLava" else "Basalt"
			elseif layout.biomes[1] == "snow" and column.x % 96 < 32 then
				material = "Ice"
			end
		end
		local floor = top
		-- Organic coast: a high coastal column gets a round cap.
		local outside = if coastline then Terrain.BEACH_TOP else top
		for dx = -1, 1 do
			for dz = -1, 1 do
				floor =
					math.min(floor, tops[column.x + dx * column.cell .. "," .. column.z + dz * column.cell] or outside)
			end
		end
		-- Organic islands: a step above the lowest neighbour gets a round cap.
		local cap = coastline ~= nil and top > 0 and top - math.max(floor, 0) > 1
			-- Graded frontiers round only a too-high inland rise a catalog path crosses.
			or gradedInland
				and top - floor > 2.5
				and floor >= 0
				and top - floor <= Terrain.GRADE * column.cell + 0.01
				and nearPath(column.x, column.z, column.cell * 0.95)
		local base = if cap then math.max(floor, 0) else top
		workspace.Terrain:FillBlock(
			CFrame.new(column.x, (base - 16) / 2, column.z),
			Vector3.new(column.cell, base + 16, column.cell),
			materials[material]
		)
		-- A walkable rise terraces down; a deeper drop keeps a half-height skirt.
		local graded = top - base <= Terrain.GRADE * column.cell + 0.01
		if cap then
			if top - base > 4 and not graded then
				local mid = (base + top) / 2
				workspace.Terrain:FillCylinder(
					CFrame.new(column.x, (base + mid) / 2 - 2, column.z),
					mid - base + 4,
					column.cell * 0.95,
					materials[material]
				)
			end
			-- Round top lobes; authored points and graded inland columns keep a full top.
			local pinned = Terrain.pinned(layout, column.x, column.z, column.cell) or gradedInland
			workspace.Terrain:FillCylinder(
				CFrame.new(column.x, (base + top) / 2 - 2, column.z),
				top - base + 4,
				column.cell * (if pinned then 0.72 else 0.62),
				materials[material]
			)
			workspace.Terrain:FillCylinder(
				CFrame.new(column.x, (base + top - 1) / 2 - 2, column.z),
				top - base + 3,
				column.cell * 0.72,
				materials[material]
			)
			if graded then
				-- Graded rises step down at most 2 studs, walkable without jumping.
				local upper = if pinned then top else top - 1
				local terraces = math.ceil((upper - base) / 2) - 1
				for index = 1, terraces do
					local height = upper - (upper - base) * index / (terraces + 1)
					workspace.Terrain:FillCylinder(
						CFrame.new(column.x, (base + height) / 2 - 2, column.z),
						height - base + 4,
						column.cell * (0.72 + 0.23 * index / terraces),
						materials[material]
					)
				end
			end
		end
		if top > 0 then
			-- Seeded discs round material borders.
			table.insert(blobs, { column, floor, material })
		end
		if not protected and top > 8 then
			-- Overlapping rounded shoulders soften the coarse column horizon.
			workspace.Terrain:FillBall(
				Vector3.new(column.x, top - 7, column.z),
				column.cell * 0.48,
				materials[material]
			)
		end
	end
	for _, blob in blobs do
		local column, floor = blob[1], blob[2]
		for _ = 1, 2 do
			workspace.Terrain:FillCylinder(
				CFrame.new(
					column.x + (blobRng:nextNumber() - 0.5) * column.cell * 0.6,
					floor - 2.5,
					column.z + (blobRng:nextNumber() - 0.5) * column.cell * 0.6
				),
				5,
				column.cell * (0.22 + blobRng:nextNumber() * 0.18),
				materials[blob[3]]
			)
		end
	end
	if coastline then
		-- Two rings of low sand domes along the seeded coastline draw a round beach.
		local ring: { { number } } = {}
		local px, pz = math.huge, math.huge
		for step = 0, 720 do
			local x, z = coastline.point(step * math.pi / 360)
			if math.sqrt((x - px) ^ 2 + (z - pz) ^ 2) >= 16 then
				px, pz = x, z
				table.insert(ring, { x, z })
			end
		end
		for _, at in ring do
			local distance = math.sqrt(at[1] * at[1] + at[2] * at[2])
			local ux, uz = at[1] / distance, at[2] / distance
			for _, band in { { 12, 22, -0.5 }, { 36, 26, 2 } } do
				workspace.Terrain:FillBall(
					Vector3.new(at[1] - ux * band[1], band[3] - band[2], at[2] - uz * band[1]),
					band[2],
					Enum.Material.Sand
				)
			end
		end
		-- Sand then grass discs hide square column edges; band columns sit at BEACH_TOP.
		local band = Terrain.band(coastline, 32)
		for _, pass in { { 0, band }, { Terrain.GRASS_EDGE, band } } do
			local last: { number }? = nil
			for step = 0, 720 do
				local angle = step * math.pi / 360
				local ox, oz = coastline.point(angle, pass[1])
				local ix, iz = coastline.point(angle, pass[2])
				local cx, cz = (ox + ix) / 2, (oz + iz) / 2
				local radius = math.sqrt((ox - ix) ^ 2 + (oz - iz) ^ 2) / 2 + 2
				if not last or math.sqrt((cx - last[1]) ^ 2 + (cz - last[2]) ^ 2) >= radius * 0.45 then
					last = { cx, cz }
					local material = if pass[1] == 0
						then "Sand"
						elseif interactionGround(cx, cz, radius) then "Ground"
						else Terrain.ground(layout, cx)
					workspace.Terrain:FillCylinder(
						CFrame.new(cx, Terrain.BEACH_TOP - 4, cz),
						8,
						radius,
						materials[material]
					)
				end
			end
		end
	end
	-- Authored navigation and hazard pools are painted into the terrain (WorldDressing plan.paint,
	-- asset-audit L2) instead of Part ribbons. A segment is a run of yawed Ground slabs, path.width
	-- wide and PAINT_STEP long, each topped at the catalog height of its midpoint (the old ribbon's
	-- surface, stepping at most slope x PAINT_STEP), with a round cap at every corner; a disc is a
	-- shallow pool. Relief islands write far chunks later, so the strokes are re-applied once
	-- every chunk is in.
	local PAINT_STEP = 2
	-- Inland ground a variety patch may recolour (never sand, water, rock or painted paths' mud).
	local PATCH_FROM = { Enum.Material.Ground, Enum.Material.Grass, Enum.Material.LeafyGrass, Enum.Material.Limestone }
	local function paintStrokes()
		for _, stroke in dressing.paint do
			local material = materials[stroke.material]
			if stroke.shape == "disc" then
				local p = stroke.position
				local water = stroke.material == "Water"
				if stroke.patch then
					-- Ground-variety patch: swap the material of the surface voxels in 4-stud cells inside the
					-- disc (ReplaceMaterial keeps occupancy, so the ground never rises; a fill re-applied after
					-- the far chunks would stack into mounds).
					local surface = probe(p.x, p.z) or p.y
					local r = stroke.radius
					for cx = math.floor((p.x - r) / 4) * 4, p.x + r, 4 do
						for cz = math.floor((p.z - r) / 4) * 4, p.z + r, 4 do
							if (cx + 2 - p.x) ^ 2 + (cz + 2 - p.z) ^ 2 <= r * r then
								local low = Vector3.new(cx, math.floor(surface / 4) * 4 - 4, cz)
								local region = Region3.new(low, low + Vector3.new(4, 12, 4))
								for _, from in PATCH_FROM do
									workspace.Terrain:ReplaceMaterial(region, 4, from, material)
								end
							end
						end
					end
					continue
				end
				local top = (probe(p.x, p.z) or p.y) + (if water then 0.2 else 0.1)
				local depth = if water then 1 else 2
				workspace.Terrain:FillCylinder(CFrame.new(p.x, top - depth / 2, p.z), depth, stroke.radius, material)
				continue
			end
			local a, b = stroke.from, stroke.to
			local length = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
			local yaw = math.atan2(b.x - a.x, b.z - a.z)
			local steps = math.max(1, math.ceil(length / PAINT_STEP))
			for index = 1, steps do
				local t = (index - 0.5) / steps
				local top = a.y + (b.y - a.y) * t
				workspace.Terrain:FillBlock(
					CFrame.new(a.x + (b.x - a.x) * t, top - 2, a.z + (b.z - a.z) * t) * CFrame.Angles(0, yaw, 0),
					Vector3.new(stroke.width, 4, length / steps + 0.5),
					material
				)
			end
			for _, cap in { a, b } do
				workspace.Terrain:FillCylinder(CFrame.new(cap.x, cap.y - 2, cap.z), 4, stroke.width / 2, material)
			end
		end
	end
	paintStrokes()
	if field then
		task.spawn(function()
			while not root:GetAttribute("ForgeTerrainReady") and (root :: any).Parent ~= nil do
				game:GetService("RunService").Heartbeat:Wait()
			end
			if (root :: any).Parent ~= nil then
				paintStrokes()
			end
		end)
	end
	local entry = layout.anchors[1].position
	for _, anchor in layout.anchors do
		if anchor.id == "entry" then
			entry = anchor.position
		end
	end
	if layoutId == "rw.home" then
		entry = content.homePolicy.dock
	end
	local spawn = Instance.new("SpawnLocation")
	spawn.Name, spawn.Anchored, spawn.Neutral, spawn.Duration = "SurvivalSpawn", true, true, 0
	spawn.Position, spawn.Size = Vector3.new(entry.x, entry.y + 1, entry.z), Vector3.new(4, 1, 4)
	-- The default studded white pad read as a stray plate beside the spawn rocks.
	spawn.Transparency = 1
	spawn.Parent = root
	-- Warm light posts: the town.lamp-post row with the torch light in its lantern (SkyCycle.torch);
	-- the primitive pole and burning head stay only when the row fails to load.
	local function torch(at: Vector3, yaw: number?): BasePart
		return SkyCycle.torch(root, at, yaw, function(frame: CFrame): Instance?
			return Meshes.place("town.lamp-post", frame, root, "ForgeTorchPost")
		end)
	end
	if layoutId ~= "rw.home" then
		-- D2 (R17): two torches frame every arrival so the spawn is a warm pool at night.
		for _, side in { -1, 1 } do
			local x, z = entry.x + side * 8, entry.z + 6
			local y = probe(x, z)
			if y then
				-- Lantern arms face the arrival.
				torch(Vector3.new(x, y, z), if side < 0 then 0 else 180)
			end
		end
	end
	local runtimeContent: any = table.clone(content)
	runtimeContent.nodes = table.clone(content.nodes)
	if layoutId == "rw.home" then
		-- Sample the home surface now so gather authority is grounded.
		local half = content.homePolicy.tiers[1].sideStuds / 2
		workspace.Terrain:FillBall(Vector3.new(0, -half - 8, 0), half + 7, Enum.Material.Sand)
		for index = 1, 7 do
			local angle = index * math.pi * 2 / 7
			local radius = half * (0.6 + (index % 3) * 0.055)
			workspace.Terrain:FillBall(
				Vector3.new(math.cos(angle) * half * 0.65, -radius + 0.5, math.sin(angle) * half * 0.65),
				radius + 3,
				Enum.Material.Sand
			)
		end
		for x = -half - 8, half + 8, 4 do
			for z = -half - 8, half + 8, 4 do
				local angle = math.atan2(z, x)
				local edge = math.sqrt(x * x + z * z) / half
				local coast = 1.12 + 0.08 * math.sin(angle * 3) + 0.045 * math.cos(angle * 7)
				if edge < coast then
					local top = 1 + math.sin(x / 13) * math.sin(z / 17) * math.clamp(edge - 0.55, 0, 0.6) * 3
					workspace.Terrain:FillBlock(
						CFrame.new(x, (top - 5) / 2, z),
						Vector3.new(4, top + 5, 4),
						Enum.Material.Ground
					)
				end
			end
		end
	end
	local nodes, spawns = {}, {}
	local nodeItems: any = {}
	-- Voxel writes are raycastable only after an engine step.
	game:GetService("RunService").Heartbeat:Wait()
	local yard = BiomeKits.yard(layout)
	if yard then
		-- Archipelago stages arrive beside the nearest yard gather node, inside its 8-stud prompt range
		-- (BiomeKits.yard keeps the kit arrival clearing on the same point).
		spawn.Position = Vector3.new(yard.x, yard.y + 1, yard.z)
	end
	-- D2 F2: the spawn stands on the written voxel surface under it (a 4-stud voxel can round the
	-- top above the authored height). ForgeSpawnReady says that ground exists: SpawnGate loads no
	-- character before it. Where no voxel is under it yet, the gate waits for the full terrain.
	local function seatSpawn(): boolean
		local at = spawn.Position
		local under = workspace:Raycast(Vector3.new(at.X, 512, at.Z), Vector3.new(0, -1024, 0), groundParams)
		if under then
			-- Never lowered: a dock entry over the sea floor keeps its authored height.
			spawn.Position = Vector3.new(at.X, math.max(at.Y, under.Position.Y + 0.5), at.Z)
		end
		return under ~= nil
	end
	if seatSpawn() then
		root:SetAttribute("ForgeSpawnReady", true)
	else
		task.spawn(function()
			while not root:GetAttribute("ForgeTerrainReady") and (root :: any).Parent ~= nil do
				game:GetService("RunService").Heartbeat:Wait()
			end
			game:GetService("RunService").Heartbeat:Wait()
			seatSpawn()
			root:SetAttribute("ForgeSpawnReady", true)
		end)
	end
	for _, node in layout.resourceNodes do
		-- Quest cargo is a mission ledger, never a generic inventory mint.
		local item: any = nil
		for _, definition in content.items do
			if definition.id == node.item then
				item = definition
			end
		end
		if item and not string.find(node.id, ".cargo.", 1, true) and not string.find(node.id, ".chapter.", 1, true) then
			nodeItems[node.id] = item
			local position = table.clone(node.position)
			local hit =
				workspace:Raycast(Vector3.new(position.x, 512, position.z), Vector3.new(0, -1024, 0), groundParams)
			if hit then
				local family = Dressing.resource(item)
				local height = if family == "water"
					then 0.5
					elseif family == "wood" then 1.5
					elseif family == "plant" or family == "food" then 2.5
					else 2
				position.y = hit.Position.Y + height / 2 + 0.25
			end
			local catalogId = string.gsub(node.id, "[._]", "-")
			table.insert(runtimeContent.nodes, {
				id = catalogId,
				harvest = { { item = node.item, quantity = node.yield } },
				respawnMillis = node.respawnSeconds * 1000,
			})
			table.insert(nodes, {
				id = node.id,
				catalogId = catalogId,
				position = position,
				charges = node.stock,
				qualityMilli = 1000,
				level = node.level,
			})
		end
	end
	-- count > 1 spawns a herd, laid out from the recorded seed.
	local herds = {}
	local herdStream = Rng.new(seed):fork("herd")
	for _, authored in layout.spawns do
		local stream = herdStream:fork(authored.id)
		local members = Herd.place(authored.id, authored.position, authored.count, authored.radius, function()
			return stream:nextNumber()
		end)
		for _, member in members do
			table.insert(spawns, { id = member.id, catalogId = authored.speciesId, position = member.position })
		end
		if #members > 1 then
			local followers = {}
			for index = 2, #members do
				table.insert(followers, members[index].id)
			end
			table.insert(
				herds,
				Herd.new(authored.id, members[1].id, followers, { alarmStuds = 24, maxJoin = 4, maxChain = 2 })
			)
		end
	end
	local arrivalGrazers = {}
	-- Decorative rigs below and the wildlife bind spawns clone the role's skinned templates.
	M.awaitMeshes(roleSpecies)
	-- Decorative rigs use the same authored species look as live wildlife.
	local function looks(species: string): any
		for _, detail in content.wildlifeDetails or {} do
			if detail.id == species then
				return detail.visual
			end
		end
		return nil
	end
	-- Decorative fauna is a ghost; only the root is anchored for client poses.
	local function decorate(animal: Model, id: string)
		for _, piece in animal:GetDescendants() do
			if piece:IsA("BasePart") then
				piece.Anchored = piece == animal.PrimaryPart
				piece.CanCollide, piece.CanTouch, piece.CanQuery = false, false, false
			end
		end
		local stream = Rng.new(seed):fork("decor-fauna:" .. layoutId .. ":" .. id)
		-- StreamingEnabled: the client poses root and limbs together, so the rig streams as one unit.
		animal.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		animal:SetAttribute("ForgeDecorFauna", true)
		animal:SetAttribute("ForgeGrazePhase", stream:nextNumber())
		animal:SetAttribute("ForgeGrazePeriod", 6 + stream:nextNumber() * 8)
	end
	if #dressing.fauna > 0 then
		-- Arrival-view creature: decorative and anchored, never an interactive wildlife spawn.
		local rig = require(Forge.genres["survival-coop"].module.DinosaurRig)
		for _, creature in dressing.fauna do
			local p = creature.position
			local hit = workspace:Raycast(Vector3.new(p.x, 512, p.z), Vector3.new(0, -1024, 0), groundParams)
			local position = Vector3.new(p.x, if hit then hit.Position.Y + 2 else p.y + 2, p.z)
			local animal = rig.new(creature.species, "ArrivalFauna", position, root, nil, looks(creature.species))
			table.insert(arrivalGrazers, animal)
			animal:PivotTo(CFrame.new(position) * CFrame.Angles(0, math.rad(140), 0))
			decorate(animal, creature.id)
		end
	end
	if layoutId == "rw.onboarding" then
		-- Distant noninteractive silhouettes set the era.
		local rig = require(Forge.genres["survival-coop"].module.DinosaurRig)
		for index, offset in { -36, 32 } do
			local position = Vector3.new(entry.x + offset, entry.y, entry.z - 58 - index * 12)
			workspace.Terrain:FillBall(position - Vector3.new(0, 6, 0), 12, Enum.Material.Sand)
			game:GetService("RunService").Heartbeat:Wait()
			local animal = rig.new("triceratops", "ArrivalGrazer" .. index, position, root, nil, looks("triceratops"))
			table.insert(arrivalGrazers, animal)
			-- ScaleTo breaks skinning.
			if animal:GetAttribute("ForgeSkinned") ~= true then
				animal:ScaleTo(1.4)
			end
			animal:PivotTo(CFrame.new(position) * CFrame.Angles(0, math.rad(60 + index * 50), 0))
			rig.ground(animal)
			decorate(animal, "ArrivalGrazer" .. index)
		end
	end
	if string.match(layoutId, "^rw%.explore%d+$") then
		-- Decorative arrival sauropod (G11, R03-3).
		local rig = require(Forge.genres["survival-coop"].module.DinosaurRig)
		local position = Vector3.new(entry.x + 64, entry.y, entry.z - 84)
		local animal = rig.new("brachiosaurus", "ArrivalSauropod", position, root, nil, looks("brachiosaurus"))
		table.insert(arrivalGrazers, animal)
		animal:PivotTo(CFrame.new(position) * CFrame.Angles(0, math.rad(115), 0))
		decorate(animal, "ArrivalSauropod")
	end
	local wildlife = table.clone(policy)
	wildlife.catalog = table.clone(policy.catalog)
	wildlife.catalog.species = table.clone(policy.catalog.species)
	runtimeContent.wildlife = table.clone(content.wildlife)
	for _, definition in content.wildlifeDetails do
		local exists = false
		for _, current in runtimeContent.wildlife do
			exists = exists or current.id == definition.id
		end
		if not exists then
			local behavior = if definition.behaviour == "flee" then "grazer" else "hunter"
			table.insert(runtimeContent.wildlife, {
				id = definition.id,
				name = definition.id,
				behavior = behavior,
				walkSpeed = definition.walkSpeed,
				runSpeed = definition.runSpeed,
				senseStuds = definition.sense,
				fleeStuds = definition.leash,
				warnStuds = definition.sense,
				attackStuds = 4,
				leashStuds = definition.leash,
				telegraphMillis = 1000,
				cooldownMillis = 2000,
			})
			-- dropReservoirs are offered by the carcass picker (CarcassExtension, C3), not dropped on the kill.
			wildlife.catalog.species[definition.id] =
				{ healthMilli = definition.health * 1000, damageMilli = definition.damage * 1000, drops = {} }
		end
	end
	wildlife.spawns = spawns
	wildlife.herds = herds
	require(Forge.games["robango-island"].src.shared.OnboardingWildlife).apply(
		content,
		layoutId,
		runtimeContent.wildlife,
		wildlife.catalog.species
	)
	if content.missionPolicy then
		local combat = content.missionPolicy
		wildlife.catalog.weapons = table.clone(wildlife.catalog.weapons)
		local starter = {
			damageMilli = combat.weaponDamageMilli,
			wearMilli = combat.weaponWearMilli,
			rangeStuds = combat.weaponRangeStuds,
			cooldownMillis = combat.weaponCooldownMillis,
			facingDot = 0,
		}
		wildlife.catalog.weapons[combat.starterWeapon] = starter
		-- Bare hands punch (Durango): a quarter of the starter club's strike, same reach and pace,
		-- no wear. Studio D2 / p134 v60: unarmed swings were refused and nothing happened.
		wildlife.catalog.unarmed = {
			damageMilli = math.max(1000, combat.weaponDamageMilli // 4),
			wearMilli = 1,
			rangeStuds = combat.weaponRangeStuds,
			cooldownMillis = combat.weaponCooldownMillis,
			facingDot = 0,
		}
		-- D2b R08: every melee weapon-tool strikes wildlife (the opening's bone knife was refused
		-- WEAPON_UNAVAILABLE, so no swing ever landed). An item without its own rule strikes like the
		-- starter club; worn performance still adds per tier. Bows and crossbows stay ranged-only.
		local ranged: { [string]: boolean } = {}
		for _, row in (content.brawlPolicy and content.brawlPolicy.weapons) or {} do
			ranged[row.item] = true
		end
		for _, item in content.items do
			if
				table.find(item.tags, "weapon-tool")
				and (item.maxDurabilityMilli or 0) > 0
				and not ranged[item.id]
				and not wildlife.catalog.weapons[item.id]
			then
				wildlife.catalog.weapons[item.id] = table.clone(starter)
			end
		end
	end
	wildlife.maximum = math.max(policy.maximum, #spawns)
	wildlife.sourceKey = "w"
	local revision = layoutId .. ":" .. tostring(seed)
	-- The live hazard storm timeline starts at World.new (SurvivalWorld hazardOrigin); ash visuals
	-- use the same instant on the server epoch clock.
	workspace:SetAttribute("ForgeStormOrigin", nowMillis() / 1000)
	local world: any = World.new({
		content = runtimeContent,
		worldRevision = revision,
		spawn = spawn,
		carriedContainer = "bag",
		reachStuds = 8,
		baseWalkSpeed = 16,
		cosmetics = require(Forge.games["robango-island"].src.shared.CosmeticConfig),
		itemNames = itemNames,
		visuals = toolVisuals(),
		wildlife = {
			catalog = wildlife.catalog,
			spawns = spawns,
			maximum = wildlife.maximum,
			nowMillis = nowMillis,
			herds = herds,
		},
		-- Full fullness on a respawn (p134 v43): 50 emptied in 15 min and the next death followed
		-- ~8 min later, so a player still looking for food starved every ~23 min (3 deaths/hour).
		-- Full = 30 min (hungerMillisPerUnit 18000), the same runway a new character gets.
		respawnValues = { healthMilli = 100000, hungerMilli = 100000, fatigueMilli = 0 },
		-- Archipelago stages tick their authored hazard zones (CharacterRules.hazardExposure).
		hazards = if string.match(layoutId, "^rw%.a%d+%.s%d+$") then { layout = layout } else nil,
	})
	-- L1: every node renders its B1 node mesh (NodeMeshes); the part below is the gameplay handle
	-- (tag, prompt, attributes, collision) and turns invisible once the mesh is hung under it.
	local nodeMeshes = {}
	for _, node in nodes do
		local target = part(node.id, node.position, { x = 3, y = 2, z = 3 })
		target.Material, target.Color = Enum.Material.Rock, Color3.fromRGB(117, 119, 112)
		local family = Dressing.resource(nodeItems[node.id])
		if family == "water" then
			target.Size, target.Material, target.Color =
				Vector3.new(5, 0.5, 5), Enum.Material.Glass, Color3.fromRGB(69, 139, 153)
		elseif family == "wood" then
			target.Size, target.Material, target.Color =
				Vector3.new(5, 1.5, 1.5), Enum.Material.Wood, Color3.fromRGB(112, 78, 48)
			target.Shape = Enum.PartType.Cylinder
		elseif family == "plant" or family == "food" then
			target.Size, target.Material, target.Color =
				Vector3.new(3, 2.5, 3), Enum.Material.Grass, Color3.fromRGB(82, 114, 71)
			target.Shape = Enum.PartType.Ball
		else
			target.Shape = Enum.PartType.Ball
		end
		world.registerNode(target, node.id, node.catalogId, 0, revision)
		-- Attributes cannot hold tables; the HUD tracker resolves the item id to a localized name.
		target:SetAttribute("ForgeNodeItem", nodeItems[node.id].id)
		local yaw = Rng.new(seed):fork("node-mesh:" .. node.id):nextNumber() * 360
		table.insert(nodeMeshes, { target = target, row = NodeMeshes.row(nodeItems[node.id].id), yaw = yaw })
	end
	-- Package loads run off the build path; until they land (or if one fails) the handle stays visible.
	task.spawn(function()
		local templates = NodeMeshes.load(BiomeKits, Assets)
		if (root :: any).Parent == nil then
			return
		end
		for _, dressed in nodeMeshes do
			NodeMeshes.dress(dressed.target, dressed.row, templates, dressed.yaw)
		end
	end)
	-- Station panels: a tier-2+ workbench opens ui.modify, a signal relay opens ui.technical-support.
	-- The server still gates every command on station kind, tier and reach.
	world.tieredStations = {}
	-- Placed parts of layout anchors (stations, harbor facilities): guide-act reach (GuideEvents)
	-- measures to the part a player sees, not the authored anchor point under the terrain.
	world.anchorParts = {}
	local function stationPanel(target: BasePart, kind: string, tier: number)
		local panel = if kind == "workbench" and tier >= 2
			then "modify"
			elseif kind == "signal-relay" then "technical-support"
			else nil
		if not panel then
			return
		end
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ForgeStationPanel"
		WorldText.bind(prompt, "open", panel)
		prompt.MaxActivationDistance, prompt.RequiresLineOfSight, prompt.Parent = 8, false, target
		prompt:SetAttribute("ForgePanel", panel)
		prompt:SetAttribute("ForgeStationPanel", panel)
	end
	local musicVenues = {}
	for _, anchor in layout.anchors do
		local station = string.match(anchor.id, "^station%.(.+)%.t%d+$")
		if station then
			local target = part(anchor.id, anchor.position, { x = 4, y = 2, z = 3 })
			local hit = workspace:Raycast(
				Vector3.new(anchor.position.x, 512, anchor.position.z),
				Vector3.new(0, -1024, 0),
				groundParams
			)
			if hit then
				target.Position = Vector3.new(anchor.position.x, hit.Position.Y + target.Size.Y / 2, anchor.position.z)
			end
			world.registerStation(target, anchor.id, station)
			world.tieredStations[anchor.id] = target
			world.anchorParts[anchor.id] = target
			stationPanel(target, station, tonumber(string.match(anchor.id, "%.t(%d+)$")) or 1)
			local tier = tonumber(string.match(anchor.id, "%.t(%d+)$")) or 1
			Meshes.dress(
				target,
				Meshes.STRUCTURES[if tier > 1 then station .. "-t" .. tier else station],
				CFrame.new(target.Position - Vector3.new(0, target.Size.Y / 2, 0))
			)
			if station == "campfire" or station == "fireplace" then
				table.insert(musicVenues, { enabled = true, part = target })
				-- Four torch posts ring each camp fire; SkyDriver strengthens their light at night.
				local base = target.Position - Vector3.new(0, target.Size.Y / 2, 0)
				for _, offset in { { 5, 3 }, { -5, 3 }, { 5, -4 }, { -5, -4 } } do
					-- Lantern arms lean toward the fire.
					torch(base + Vector3.new(offset[1], 0, offset[2]), if offset[1] > 0 then 180 else 0)
				end
			end
		end
	end
	world.musicVenues = function()
		return musicVenues
	end
	local function interactionPosition(position: any, height: number): any
		local result = table.clone(position)
		local hit = workspace:Raycast(Vector3.new(position.x, 512, position.z), Vector3.new(0, -1024, 0), groundParams)
		if hit then
			result.y = hit.Position.Y + height / 2 + 0.25
		end
		return result
	end
	-- guide-act reach (GuideEvents.atAnchor): to the anchor's placed part with the station reach rule,
	-- else to the anchor lifted onto the ground. The authored point lies under terrain (y=4), so a
	-- straight ray to it hit Terrain or the facility part itself and always refused (p115 D3).
	world.anchorReach = function(actor: string, anchor: any): boolean
		local target = world.anchorParts[anchor.id] or world.tieredStations[anchor.id]
		if target and target.Parent then
			return world.nearPart(actor, target)
		end
		return world.services.survivalDeath.reachable(actor, interactionPosition(anchor.position, 4))
	end
	if layoutId == "rw.harbor" then
		local Harbor = require(Forge.genres["survival-coop"].module.HarborFacilities)
		world.harborFacilities = Harbor.describe(content)
		for _, facility in world.harborFacilities do
			if facility.kind == "npc" or facility.kind == "market" or facility.kind == "interaction" then
				facility.position = interactionPosition(facility.position, 4)
				local target = part(facility.id, facility.position, { x = 2, y = 4, z = 2 })
				target:SetAttribute("ForgeHarborFacility", facility.anchor)
				world.anchorParts[facility.anchor] = target
				if facility.kind == "npc" then
					survivorFigure(facility.anchor, target)
				end
				-- Town-kit set piece beside the interaction part (rift, rescue bell, notice board).
				local set = Meshes.FACILITIES[facility.anchor]
				if set then
					local hit = workspace:Raycast(
						Vector3.new(facility.position.x + set.dx, 512, facility.position.z),
						Vector3.new(0, -1024, 0),
						groundParams
					)
					local placed = if hit
						then Meshes.place(set.row, CFrame.new(hit.Position), root, facility.anchor .. ".set")
						else nil
					-- The row is the visual; the part stays the invisible prompt and reach handle.
					if placed then
						target.Transparency = 1
					end
				end
				local prompt = Instance.new("ProximityPrompt")
				WorldText.bind(prompt, if facility.kind == "market" then "market" else "interact", facility.anchor)
				prompt.MaxActivationDistance, prompt.Parent = 8, target
				-- The market board talks first; its Market choice opens the market panel.
				prompt:SetAttribute("ForgeMarket", facility.anchor == "npc.sella")
				prompt:SetAttribute("ForgePanel", facility.panel)
				prompt:SetAttribute("ForgeDialogue", facility.talk)
				prompt:SetAttribute("ForgeOperation", facility.operation)
				-- Travel reach uses the station rule on this part (p123): a ray to its centre hit the part.
				-- Like dock(), the server result is always published, refusal or travelling (p125).
				prompt.Triggered:Connect(function(player)
					if not facility.destination then
						return
					end
					local outcome: string
					if not world.travel then
						outcome = "expedition_inactive"
					elseif not world.nearPart(tostring(player.UserId), target) then
						outcome = "portal_unreachable"
					else
						local ok, reason = world.travel(player, facility.destination)
						outcome = if ok then "travelling" else tostring(reason or "travel_refused")
					end
					M.publishTravel(player, outcome)
				end)
			elseif facility.talk then
				-- Station dialogue prompt on the registered station part.
				local station = root:FindFirstChild(facility.anchor)
				if station then
					local prompt = Instance.new("ProximityPrompt")
					WorldText.bind(prompt, "interact", facility.anchor)
					prompt.MaxActivationDistance, prompt.Parent = 8, station
					prompt:SetAttribute("ForgePanel", facility.panel)
					prompt:SetAttribute("ForgeDialogue", facility.talk)
				end
			end
		end
	end
	local bound: any = nil
	local bind = world.bind
	world.bind = function(session)
		bound = session
		bind(session)
	end
	local function dock(id: string, position: any, destination: string)
		position = interactionPosition(position, 1)
		local target = part(id, position, { x = 10, y = 1, z = 8 })
		-- The slab stays the collidable deck and prompt handle (hidden); a pier row renders it with its
		-- deck flush with the slab top and its land end on the slab, running out to sea (away from the
		-- island centre): town.dock (48-stud pier), the 16-stud walkway on the home isle.
		local home = layoutId == "rw.home"
		local top = target.Position.Y + target.Size.Y / 2
		local out = Vector3.new(target.Position.X, 0, target.Position.Z)
		out = if out.Magnitude > 0 then out.Unit else Vector3.new(0, 0, 1)
		local centre = target.Position + out * (if home then 4 else 19)
		Meshes.dress(
			target,
			if home then "town.drift-camp-walkway" else "town.dock",
			CFrame.new(centre.X, top - (if home then 1.2 else 0.3), centre.Z)
				* CFrame.Angles(0, math.atan2(out.X, out.Z), 0)
		)
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ForgeDock"
		WorldText.bind(prompt, "travel", destination)
		prompt:SetAttribute("ForgeDestination", destination)
		-- G22: the dock part names its destination so the HUD labels it with the live population.
		target:SetAttribute("ForgeDestination", destination)
		prompt.MaxActivationDistance, prompt.RequiresLineOfSight, prompt.Parent = 8, true, target
		prompt.Triggered:Connect(function(player)
			local actor = tostring(player.UserId)
			local outcome: string
			if not (bound and world.travel) then
				outcome = "expedition_inactive"
			elseif not world.nearPart(actor, target) then
				outcome = "dock_unreachable"
			else
				local ok, reason = world.travel(player, destination)
				outcome = if ok then "travelling" else tostring(reason or "travel_refused")
			end
			-- The server's result is always shown: refusal reason or the travelling notice.
			M.publishTravel(player, outcome)
		end)
		return target
	end
	for _, anchor in layout.anchors do
		-- Saltmeadow (rw.town): the south dock sails to the harbor, the north rift opens a route.
		if anchor.id == "entry" or (anchor.id == "exit" and layoutId ~= "rw.home") then
			-- The home dock part is also home expand's atDock reach target (SurvivalFactory, p126).
			local placed = dock(
				anchor.id,
				if layoutId == "rw.home" then content.homePolicy.dock else anchor.position,
				if layoutId == "rw.onboarding" or layoutId == "rw.harbor"
					then "home"
					elseif string.match(layoutId, "^rw%.a%d+%.s%d+$") then (if anchor.id == "exit"
						then "next-island"
						else "home") -- Saltmeadow: the south dock sails to the harbor, the north rift opens a route.

					elseif layoutId == "rw.town" then (if anchor.id == "exit" then "archipelago" else "harbor")
					else "harbor"
			)
			if layoutId == "rw.home" then
				world.homeDock = placed
			end
		end
	end
	-- Onboarding also sails straight to the shared town (C5a), beside its exit dock.
	if layoutId == "rw.onboarding" then
		for _, anchor in layout.anchors do
			if anchor.id == "exit" then
				dock("town-dock", { x = anchor.position.x + 16, y = anchor.position.y, z = anchor.position.z }, "town")
			end
		end
	end
	if layoutId == "rw.town" then
		-- Saltmeadow plots (C5a): one Atomic model per plot holding its stake, flag and built
		-- structures. The stake prompt claims; claimed plots fly the owner's seeded flag colour.
		local TownPlots = require(Forge.games["robango-island"].src.shared.TownPlots)
		local town = TownPlots.layout(seed)
		local folder = Instance.new("Folder")
		folder.Name, folder.Parent = "ForgeTownPlots", root
		world.townLayout = town
		world.townPlots = {}
		for _, plot in town.plots do
			local model = Instance.new("Model")
			model.Name, model.ModelStreamingMode, model.Parent = plot.id, Enum.ModelStreamingMode.Atomic, folder
			local corner = TownPlots.corner(plot, plot.stake)
			local at = interactionPosition({
				x = corner.x + (if corner.x == plot.min.x then 3 else -3),
				y = 4,
				z = corner.z + (if corner.z == plot.min.z then 3 else -3),
			}, 3)
			local stake = part("plot." .. plot.id, at, { x = 1, y = 3, z = 1 })
			stake.Color, stake.Parent = Color3.fromRGB(64, 200, 190), model
			stake:SetAttribute("ForgeTownPlot", plot.id)
			Meshes.dress(stake, "town.plot-marker", CFrame.new(stake.Position - Vector3.new(0, 1.5, 0)))
			local flag = part("flag." .. plot.id, { x = at.x, y = at.y + 3, z = at.z }, { x = 0.2, y = 1.6, z = 2.4 })
			flag.CanCollide, flag.CanQuery, flag.CanTouch, flag.Transparency = false, false, false, 1
			flag.Material, flag.Parent = Enum.Material.Fabric, model
			-- D2 (R12): a low two-rail timber fence on all four edges (one 12-stud gate on the max-z
			-- side, facing the plot's lane), corner and mid posts, and a claim sign by the gate. All
			-- visual: never collides or queries, so build cells and reach stay as before.
			local floor = at.y - 1.75
			local wood = Color3.fromRGB(122, 88, 56)
			local function fencePiece(name: string, x: number, y: number, z: number, size: any)
				local value = part(name, { x = x, y = floor + y, z = z }, size)
				value.Material, value.Color, value.Parent = Enum.Material.Wood, wood, model
				value.CanCollide, value.CanQuery, value.CanTouch = false, false, false
				return value
			end
			local gate = plot.centre.x
			if meshRows["town.plot-fence"] and meshRows["town.plot-fence-corner"] and meshRows["town.plot-gate"] then
				-- L5 rows: 8-stud fence segments (front, local -Z, into the plot), posts at the corners,
				-- edge middles and gate sides, and the 12-stud gateway with its claim board facing the lane.
				local function piece(row: string, name: string, x: number, z: number, yaw: number)
					Meshes.place(row, CFrame.new(x, floor, z) * CFrame.Angles(0, math.rad(yaw), 0), model, name)
				end
				for offset = -28, 28, 8 do
					piece("town.plot-fence", "border.n." .. offset, plot.centre.x + offset, plot.min.z, 180)
					piece("town.plot-fence", "border.w." .. offset, plot.min.x, plot.centre.z + offset, -90)
					piece("town.plot-fence", "border.e." .. offset, plot.max.x, plot.centre.z + offset, 90)
					if math.abs(offset) > 4 then
						piece("town.plot-fence", "border.s." .. offset, gate + offset, plot.max.z, 0)
					end
				end
				for _, post in
					{
						{ plot.min.x, plot.min.z },
						{ plot.max.x, plot.min.z },
						{ plot.max.x, plot.max.z },
						{ plot.min.x, plot.max.z },
						{ plot.centre.x, plot.min.z },
						{ plot.min.x, plot.centre.z },
						{ plot.max.x, plot.centre.z },
					}
				do
					piece("town.plot-fence-corner", "post." .. post[1] .. "." .. post[2], post[1], post[2], 0)
				end
				piece("town.plot-gate", "gate." .. plot.id, gate, plot.max.z, 0)
			else
				for _, height in { 1.2, 2.6 } do
					local tag = plot.id .. "." .. height
					fencePiece("border.n." .. tag, plot.centre.x, height, plot.min.z, { x = 64, y = 0.4, z = 0.4 })
					fencePiece("border.w." .. tag, plot.min.x, height, plot.centre.z, { x = 0.4, y = 0.4, z = 64 })
					fencePiece("border.e." .. tag, plot.max.x, height, plot.centre.z, { x = 0.4, y = 0.4, z = 64 })
					for _, side in { -1, 1 } do
						local length = 32 - 6
						fencePiece(
							"border.s" .. side .. "." .. tag,
							gate + side * (6 + length / 2),
							height,
							plot.max.z,
							{ x = length, y = 0.4, z = 0.4 }
						)
					end
				end
				for _, post in
					{
						{ plot.min.x, plot.min.z },
						{ plot.max.x, plot.min.z },
						{ plot.max.x, plot.max.z },
						{ plot.min.x, plot.max.z },
						{ plot.centre.x, plot.min.z },
						{ plot.min.x, plot.centre.z },
						{ plot.max.x, plot.centre.z },
						{ gate - 6, plot.max.z },
						{ gate + 6, plot.max.z },
					}
				do
					fencePiece(
						"post." .. post[1] .. "." .. post[2],
						post[1],
						1.75,
						post[2],
						{ x = 0.7, y = 3.5, z = 0.7 }
					)
				end
				local sign = fencePiece("sign." .. plot.id, gate - 9, 3.4, plot.max.z + 1.5, { x = 4, y = 2, z = 0.3 })
				sign.Material, sign.Color = Enum.Material.WoodPlanks, Color3.fromRGB(196, 158, 102)
				fencePiece("sign.post." .. plot.id, gate - 9, 1.2, plot.max.z + 1.5, { x = 0.4, y = 2.4, z = 0.4 })
				local label =
					fencePiece("sign.tag." .. plot.id, gate - 9, 3.4, plot.max.z + 1.7, { x = 2.6, y = 0.9, z = 0.1 })
				label.Material, label.Color = Enum.Material.Fabric, Color3.fromRGB(64, 200, 190)
			end
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = "ForgeTownClaim"
			WorldText.bind(prompt, "claim", "plot")
			prompt.MaxActivationDistance, prompt.RequiresLineOfSight, prompt.Parent = 10, false, stake
			prompt.Triggered:Connect(function(player)
				local result = if world.missionAction
					then world.missionAction(tostring(player.UserId), "town-claim", plot.id)
					else nil
				M.publishTravel(
					player,
					if result and result.ok
						then "town_claimed"
						else tostring(result and result.reason or "town_unavailable")
				)
			end)
			world.townPlots[plot.id] = {
				stake = stake,
				flag = flag,
				prompt = prompt,
				ports = world.settlementPorts(
					Vector3.new(plot.min.x, at.y - 1.75, plot.min.z),
					Vector3.new(plot.centre.x, at.y, plot.centre.z)
				),
			}
		end
		world.publishTownPlot = function(plotId: string, doc: any)
			local slot = world.townPlots[plotId]
			if not slot then
				return
			end
			slot.stake:SetAttribute("ForgeTownOwner", if doc then doc.ownerId else nil)
			slot.prompt.Enabled = doc == nil
			slot.flag.Transparency = if doc then 0 else 1
			if doc then
				slot.flag.Color = Color3.fromRGB(table.unpack(TownPlots.flagColour(seed, doc.ownerId)))
				slot.ports.publish(doc.settlement)
			end
		end
		-- Quest card at the trading post: "Saltmeadow: claim a free plot" opens the journal.
		for _, anchor in layout.anchors do
			if anchor.id == "trading-post" then
				local board = part("town-quest", interactionPosition(anchor.position, 3), { x = 3, y = 3, z = 1 })
				-- The town.trading-post set piece stands on this anchor; the card is its prompt handle.
				if meshRows["town.trading-post"] then
					board.Transparency = 1
				end
				local prompt = Instance.new("ProximityPrompt")
				WorldText.bind(prompt, "interact", "town-quest")
				prompt.MaxActivationDistance, prompt.Parent = 10, board
				prompt:SetAttribute("ForgePanel", "journal")
			end
		end
		-- L6: townsfolk beside the trading post, well, work yard and clan hall (decor only: no
		-- prompt, no collision; invisible handles until the survivor package loads).
		local townsfolk =
			{ ["trading-post"] = { 5, 3 }, well = { -4, 2 }, ["work-yard"] = { 4, -4 }, ["clan-hall"] = { -6, 6 } }
		for _, anchor in layout.anchors do
			local offset = townsfolk[anchor.id]
			if offset then
				local at =
					{ x = anchor.position.x + offset[1], y = anchor.position.y, z = anchor.position.z + offset[2] }
				local handle = part("townsfolk." .. anchor.id, interactionPosition(at, 5), { x = 2, y = 5, z = 2 })
				handle.Transparency, handle.CanCollide, handle.CanQuery, handle.CanTouch = 1, false, false, false
				-- Face the anchor they stand beside.
				handle.CFrame =
					CFrame.lookAt(handle.Position, Vector3.new(anchor.position.x, handle.Position.Y, anchor.position.z))
				survivorFigure("town:" .. anchor.id, handle, { scale = TownLife.FOLK_SCALE })
			end
		end
	end
	for _, facility in world.harborFacilities or {} do
		if facility.kind == "departure" then
			facility.position = interactionPosition(facility.position, 1)
			dock(facility.id, facility.position, facility.destination)
		end
	end
	-- C7 sail points (G20, G25): the harbor chart table opens the sea chart in dock mode and the
	-- rift opens it in rift mode; on a drift isle a small camp (fire, tent, rift) stands beside the
	-- arrival trail. The server reads world.sailPoint before any chart voyage leaves.
	local sailPoints: { { part: BasePart, kind: string } } = {}
	local function sailPoint(id: string, position: any, kind: string, size: any): BasePart
		local target = part(id, interactionPosition(position, size.y), size)
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ForgeSeaChart"
		WorldText.bind(prompt, if kind == "rift" then "step-through" else "set-sail", "sea-chart")
		prompt.MaxActivationDistance, prompt.RequiresLineOfSight, prompt.Parent = 8, false, target
		prompt:SetAttribute("ForgePanel", "sea-chart-" .. kind)
		target:SetAttribute("ForgeSailPoint", kind)
		table.insert(sailPoints, { part = target, kind = kind })
		-- The dock sail point is the prompt handle in front of the town.chart-table set piece.
		if kind == "dock" and meshRows["town.chart-table"] then
			target.Transparency = 1
		end
		return target
	end
	--- Our rift: the redesigned town.rift-ring (L5: stone lip, glowing cleft, monolith shards) at the
	--- sail point's ground, or an existing rift row `visual`. The sail point stays the invisible
	--- prompt handle inside the cleft; `facing` turns the cleft's front toward a neighbour. Only when
	--- the row is missing does the old lilac Neon fissure in a Slate ring stand in.
	local function rift(id: string, base: BasePart, visual: Instance?, facing: Vector3?)
		local ground = base.Position - Vector3.new(0, base.Size.Y / 2, 0)
		local frame = if facing
			then CFrame.lookAt(ground, Vector3.new(facing.X, ground.Y, facing.Z))
			else CFrame.new(ground)
		local placed = visual or Meshes.place("town.rift-ring", frame, root, id .. ".set")
		if placed then
			base.Transparency = 1
			return
		end
		local fissure = part(id .. ".fissure", { x = ground.X, y = ground.Y + 4.5, z = ground.Z }, {
			x = 1.2,
			y = 7,
			z = 4,
		})
		fissure.Material, fissure.Color = Enum.Material.Neon, Color3.fromRGB(154, 143, 181)
		fissure.CanCollide, fissure.CanQuery, fissure.Transparency = false, false, 0.15
		local ring = part(id .. ".ring", { x = ground.X, y = ground.Y + 4.5, z = ground.Z }, { x = 1, y = 10, z = 10 })
		ring.Shape, ring.Material = Enum.PartType.Cylinder, Enum.Material.Slate
		ring.Color, ring.Transparency = Color3.fromRGB(74, 61, 49), 0.6
		ring.CanCollide, ring.CanQuery = false, false
		ring.CFrame = CFrame.new(ring.Position) * CFrame.Angles(0, 0, math.rad(90))
	end
	if layoutId == "rw.harbor" then
		sailPoint("SeaChartTable", { x = 14, y = 2, z = 112 }, "dock", { x = 4, y = 3, z = 3 })
		for _, facility in world.harborFacilities or {} do
			if facility.anchor == "visitor-portal" then
				-- The step-through point sits in the cleft of the visitor-portal rift (FACILITIES dx), so
				-- the harbor shows one rift carrying both prompts.
				local set = Meshes.FACILITIES["visitor-portal"]
				local base = sailPoint(
					"HarborRift",
					{ x = facility.position.x + set.dx, y = 0, z = facility.position.z },
					"rift",
					{ x = 3, y = 1, z = 3 }
				)
				rift("HarborRift", base, root:FindFirstChild("visitor-portal.set"))
			end
		end
	end
	local camp = Dressing.driftCamp(layout)
	if camp then
		local fire = part("DriftCamp.fire", interactionPosition(camp.fire, 1), { x = 4, y = 1, z = 4 })
		fire.Material, fire.Color = Enum.Material.Slate, Color3.fromRGB(96, 92, 88)
		Meshes.dress(fire, Meshes.STRUCTURES.campfire, CFrame.new(fire.Position - Vector3.new(0, 0.5, 0)))
		torch(fire.Position + Vector3.new(4, -0.5, 0), 180)
		local tent = part("DriftCamp.tent", interactionPosition(camp.tent, 4), { x = 8, y = 4, z = 6 })
		tent.Material, tent.Color = Enum.Material.Fabric, Color3.fromRGB(185, 165, 140)
		tent.CFrame = CFrame.new(tent.Position) * CFrame.Angles(0, math.rad(camp.yaw), 0)
		Meshes.dress(
			tent,
			Meshes.STRUCTURES.tent,
			CFrame.new(tent.Position - Vector3.new(0, 2, 0)) * CFrame.Angles(0, math.rad(camp.yaw), 0)
		)
		-- The cleft faces the tent, so its 22-stud long side runs across the camp, not into it.
		rift(
			"DriftCamp.rift",
			sailPoint("DriftCamp.riftBase", camp.rift, "rift", { x = 3, y = 1, z = 3 }),
			nil,
			tent.Position
		)
	end
	--- The sail point ("dock" or "rift") the actor stands at, or nil. Dock prompts count as docks.
	world.sailPoint = function(actor: string): string?
		for _, point in sailPoints do
			if point.part.Parent and world.nearPart(actor, point.part) then
				return point.kind
			end
		end
		for _, item in root:GetChildren() do
			if item:FindFirstChild("ForgeDock") and world.nearPart(actor, item) then
				return "dock"
			end
		end
		return nil
	end
	-- Archipelago cells: a boundary marker at the island edge beside the entry dock opens
	-- ui.island-rank. Its cell bounds and required rank come from the layout data.
	for _, cell in CharacterRules.cells(content) do
		if cell.id ~= layoutId then
			continue
		end
		for _, anchor in layout.anchors do
			if anchor.id == "entry" then
				local b = cell.bounds
				local position = interactionPosition({
					x = math.clamp(anchor.position.x + 10, b.min.x + 2, b.max.x - 2),
					y = anchor.position.y,
					z = math.clamp(anchor.position.z, b.min.z + 2, b.max.z - 2),
				}, 6)
				local marker = part("IslandBoundary", position, { x = 1, y = 6, z = 1 })
				marker.Color = Color3.fromRGB(214, 170, 72)
				-- The signpost row is the visual; the post stays the invisible rank prompt handle.
				Meshes.dress(marker, "town.road-sign", CFrame.new(marker.Position - Vector3.new(0, 3, 0)))
				marker:SetAttribute("ForgeCell", cell.id)
				marker:SetAttribute("ForgeCellRank", cell.rank)
				marker:SetAttribute("ForgeCellMin", Vector3.new(b.min.x, b.min.y, b.min.z))
				marker:SetAttribute("ForgeCellMax", Vector3.new(b.max.x, b.max.y, b.max.z))
				local prompt = Instance.new("ProximityPrompt")
				prompt.Name = "ForgeIslandRank"
				WorldText.bind(prompt, "open", "island-rank")
				prompt.MaxActivationDistance, prompt.RequiresLineOfSight, prompt.Parent = 8, false, marker
				prompt:SetAttribute("ForgePanel", "island-rank")
				prompt:SetAttribute("ForgeStationPanel", "island-rank")
			end
		end
	end
	world.roleSource = table.clone(source)
	world.roleSource.tribe = table.clone(source.tribe)
	if layoutId == "rw.onboarding" then
		-- The live island is elevated; the preview's depot target is below its terrain.
		world.roleSource.tribe.warehousePosition = { x = -16, y = 5, z = -4 }
		world.roleSource.tribe.origin = { x = campPlot.x, y = 4, z = campPlot.z }
		-- C1 opening beats: stakes, beacon, Gannet and the server step owner (OpeningDirector).
		local Opening = require("./OpeningDirector")
		world.opening = Opening.new(layout, root, nowMillis)
		-- L5 opening.stake / opening.mirror rows; the peg and mirror Parts stay the prompt/glint handles.
		Opening.dressProps(world.opening, function(target: BasePart, key: string, ground: CFrame): Instance?
			return Meshes.dress(target, key, ground)
		end)
		-- D2 (R20): the composed beacon and Gannet take their B3 town-kit rows when those load; the
		-- parts stay (hidden) because the prompts and the client fly-in live on Pole and Hull.
		for _, model in { world.opening.beacon, world.opening.boat } do
			local primary = model.PrimaryPart
			local visual = Meshes.clone(model:GetAttribute("ForgeSetPieceId"), { decor = true })
			if visual and primary then
				local floor = primary.Position.Y - primary.Size.Y / 2
				visual:PivotTo(CFrame.new(primary.Position.X, floor, primary.Position.Z))
				visual.Parent = model
				for _, item in model:GetDescendants() do
					if item:IsA("BasePart") and not item:IsDescendantOf(visual) then
						item.Transparency = 1
					end
				end
			end
		end
		local depot = part("Warehouse", world.roleSource.tribe.warehousePosition, { x = 3, y = 2, z = 2 })
		depot.Transparency, depot.CanCollide, depot.CanQuery, depot.CanTouch = 1, false, false, false
		depot:SetAttribute("ForgeWarehouseTribe", source.tribe.config.tribeId)
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ForgeWarehouse"
		WorldText.bind(prompt, "warehouse_open", "warehouse")
		prompt.MaxActivationDistance, prompt.RequiresLineOfSight, prompt.Parent = 8, false, depot
		prompt:SetAttribute("ForgeWarehouse", true)
	end
	world.roleSource.resourceNodes = layout.resourceNodes
	world.roleSource.nodes, world.roleSource.worldRevision = nodes, revision
	world.roleSource.persistencePrefix = "s:" .. Journal.fnv1a64(source.persistencePrefix .. ":" .. revision)
	world.roleSource.sourceKey = "n"
	world.roleContent, world.roleWildlife, world.layout = runtimeContent, wildlife, layout
	if layoutId == "rw.team-outpost" then
		local center: any = nil
		for _, anchor in layout.anchors do
			if anchor.id == "objective" then
				center = anchor.position
			end
		end
		world.outpostOccupying = function(actor)
			local player = game:GetService("Players"):GetPlayerByUserId(tonumber(actor) or 0)
			local character = if player then player.Character else nil
			local rigRoot = if character then character:FindFirstChild("HumanoidRootPart") else nil
			local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
			return center ~= nil
				and rigRoot ~= nil
				and humanoid ~= nil
				and humanoid.Health > 0
				and (rigRoot.Position - Vector3.new(center.x, center.y, center.z)).Magnitude <= 12
		end
	end
	world.surveyMarkers = {}
	world.journalTargets = {}
	local physical = {
		survey = true,
		inspect = true,
		activate = true,
		speak = true,
		tune = true,
		assemble = true,
		deposit = true,
		administer = true,
		install = true,
		submit = true,
		deploy = true,
		eat = true,
		escort = true,
		["return"] = true,
	}
	for _, chapter in content.chapters do
		for _, objective in chapter.objectives do
			if not physical[objective.action] then
				continue
			end
			local anchorId: string? = nil
			if objective.action == "speak" then
				if layoutId == "rw.harbor" then
					anchorId = "npc." .. objective.target
				end
			elseif string.sub(objective.target, 1, #layoutId + 1) == layoutId .. "." then
				anchorId = string.sub(objective.target, #layoutId + 2)
				if anchorId == "survey" or anchorId == "wreck" or anchorId == "beacon" or anchorId == "survivor" then
					anchorId = "objective"
				end
				if anchorId == "relay" then
					anchorId = "station.signal-relay.t1"
				end
			elseif layoutId == "rw.home" and (objective.target == "signal-relay" or objective.action == "install") then
				anchorId = "objective"
			elseif layoutId == "rw.harbor" and objective.action == "assemble" then
				anchorId = "station.workbench.t1"
			elseif layoutId == "rw.harbor" and (objective.action == "administer" or objective.action == "eat") then
				anchorId = "npc.ines"
			elseif layoutId == "rw.harbor" and (objective.action == "deposit" or objective.action == "submit") then
				anchorId = "npc.bram"
			end
			for _, anchor in layout.anchors do
				if anchor.id ~= anchorId then
					continue
				end
				for index = 1, objective.quantity do
					local position =
						{ x = anchor.position.x + (index - 1) * 8, y = anchor.position.y, z = anchor.position.z }
					local id = objective.id .. ":" .. tostring(index)
					local target = part(id, position, { x = 2, y = 3, z = 2 })
					-- A notice board renders the checkpoint; the invisible part keeps the prompt.
					Meshes.dress(target, "town.notice-board", CFrame.new(target.Position - Vector3.new(0, 1.5, 0)))
					-- The marker part is the journal reach target (SurvivalFactory, station reach rule).
					world.journalTargets[id] =
						{ position = position, objective = objective.id, marker = id, part = target }
					local prompt = Instance.new("ProximityPrompt")
					WorldText.bind(prompt, "journal_checkpoint", "journal")
					prompt.MaxActivationDistance, prompt.Parent = 8, target
					prompt:SetAttribute("ForgeJournal", true)
					prompt.Triggered:Connect(function(player)
						if world.journalAction then
							world.journalAction(tostring(player.UserId), id)
						end
					end)
				end
			end
		end
	end
	for _, stage in content.stages do
		if stage.layout == layoutId then
			for _, objective in stage.objectives do
				if objective.action == "survey" then
					for index = 1, objective.quantity do
						local position = Terrain.survey(layout, index)
						local id = objective.id .. "." .. tostring(index)
						world.surveyMarkers[id] = { position = position, objective = objective.id, layout = layoutId }
						local target = part(id, interactionPosition(position, 3), { x = 2, y = 3, z = 2 })
						table.insert(surveyCairns, target)
						local gui = Instance.new("BillboardGui")
						gui.Size, gui.StudsOffset, gui.AlwaysOnTop =
							UDim2.fromOffset(120, 32), Vector3.new(0, 4, 0), true
						local label = Instance.new("TextLabel")
						label.Size, label.BackgroundTransparency, label.TextScaled = UDim2.fromScale(1, 1), 1, true
						label.Text, label.TextColor3, label.Parent =
							WorldText.text("en-us", "survey"), Color3.fromRGB(255, 220, 90), gui
						gui.Parent = target
						game:GetService("CollectionService"):AddTag(target, "ForgeSurvey")
						local prompt = Instance.new("ProximityPrompt")
						WorldText.bind(prompt, "survey", "survey-point")
						prompt.MaxActivationDistance, prompt.Parent = content.missionPolicy.interactionStuds, target
						prompt:SetAttribute("ForgeSurvey", true)
						prompt.Triggered:Connect(function(player)
							if world.missionAction then
								world.missionAction(tostring(player.UserId), "survey-start", id)
							end
						end)
					end
				end
			end
		end
	end
	if #surveyCairns > 0 then
		task.spawn(function()
			local templates = NodeMeshes.load(BiomeKits, Assets)
			for _, cairn in surveyCairns do
				if cairn.Parent then
					NodeMeshes.dress(cairn, NodeMeshes.ROWS["node.survey-cairn"], templates, 0)
				end
			end
		end)
	end
	local anchors = {}
	for _, anchor in layout.anchors do
		anchors[anchor.id] = anchor.position
	end
	local escorts: any = {}
	local journalEscorts: any = {}
	world.renderJournalEscort = function(actor, position)
		local npc = journalEscorts[actor]
		if not position then
			if npc then
				npc:Destroy()
				journalEscorts[actor] = nil
			end
			return
		end
		if not npc then
			npc = part("JournalCastaway-" .. actor, position, { x = 2, y = 5, z = 2 })
			npc.CanCollide = false
			survivorFigure("castaway:" .. actor, npc)
			journalEscorts[actor] = npc
		end
		npc.Position = Vector3.new(position.x, position.y, position.z)
	end
	world.publishEscort = function(actor, state: any)
		for id in world.surveyMarkers do
			local mark = state and root:FindFirstChild(id)
			if mark then
				mark:SetAttribute("ForgeSurveyed" .. actor, state.receipts[state.id .. ":survey:" .. id])
			end
		end
		local npc = escorts[actor]
		if not state or state.stage ~= tonumber(string.match(layoutId, "%.s(%d+)$")) or state.status ~= "active" then
			if npc then
				npc:Destroy()
				escorts[actor] = nil
			end
			return
		end
		local rescue = false
		for _, stage in content.stages do
			if stage.layout == layoutId then
				for _, objective in stage.objectives do
					rescue = rescue or (objective.action == "rescue" and not state.completed[objective.id])
				end
			end
		end
		if not rescue then
			if npc then
				npc:Destroy()
				escorts[actor] = nil
			end
			return
		end
		local position = if state.escort then state.escort.position else anchors.objective
		if not npc then
			npc = part("Castaway-" .. actor, position, { x = 2, y = 5, z = 2 })
			npc.CanCollide = false
			survivorFigure("castaway:" .. actor, npc)
			escorts[actor] = npc
		end
		npc.Position = Vector3.new(position.x, position.y, position.z)
		npc:SetAttribute("Treated", state.treated)
	end
	-- Mission prompt visuals: supply crates for claims and deliveries, a bedroll where the castaway
	-- is treated. The part stays the invisible prompt handle.
	local missionRows = {
		["bandage-claim"] = "town.crate-stack",
		["rescue-treat"] = "bld.bed",
		["cargo-claim"] = "town.crate-stack",
		["cargo-deliver"] = "town.crate-stack",
	}
	local function missionPrompt(operation, position)
		local target = part(operation, position, { x = 2, y = 3, z = 2 })
		Meshes.dress(target, missionRows[operation], CFrame.new(target.Position - Vector3.new(0, 1.5, 0)))
		local prompt = Instance.new("ProximityPrompt")
		WorldText.bind(prompt, operation)
		prompt.MaxActivationDistance, prompt.Parent = content.missionPolicy.interactionStuds, target
		prompt.Triggered:Connect(function(player)
			if world.missionAction then
				world.missionAction(tostring(player.UserId), operation, layoutId)
			end
		end)
	end
	for _, stage in content.stages do
		if stage.layout == layoutId then
			for _, objective in stage.objectives do
				if objective.action == "rescue" then
					local origin, offset = anchors.objective, content.missionPolicy.bandageOffset
					missionPrompt(
						"bandage-claim",
						{ x = origin.x + offset.x, y = origin.y + offset.y, z = origin.z + offset.z }
					)
					missionPrompt("rescue-treat", origin)
				elseif objective.action == "transport" then
					missionPrompt("cargo-claim", anchors.resources)
					missionPrompt("cargo-deliver", anchors.objective)
				end
			end
		end
	end
	local homeParts: any = {}
	local buildingParts: { Part } = {}
	local buildingHash: string? = nil
	world.publishBuilding = function(_actor, boxes)
		local hash = Journal.fnv1a64(require(Forge.core.domain.command.Ledger).canonical(boxes))
		if hash == buildingHash then
			return
		end
		buildingHash = hash
		for _, value in buildingParts do
			value:Destroy()
		end
		table.clear(buildingParts)
		for index, box in boxes do
			local value = part("Building:" .. index, { x = box.x, y = box.y, z = box.z }, {
				x = box.width,
				y = box.height,
				z = box.depth,
			})
			value.Material, value.CanCollide = Enum.Material.WoodPlanks, box.canCollide
			-- Timber module rows stretched to the collision box: posts, wall panels, floor decks and treads.
			local tall = box.height > math.max(box.width, box.depth)
			fitRow(
				value,
				if tall
						and box.width <= 1
						and box.depth <= 1
					then "bld.timber.pillar"
					elseif tall then "bld.timber.wall"
					else "bld.timber.floor"
			)
			table.insert(buildingParts, value)
		end
	end
	local stationKinds = {}
	for _, recipe in content.recipes do
		if recipe.station then
			stationKinds[recipe.station] = true
		end
	end
	local folder = Instance.new("Folder")
	folder.Name, folder.Parent = "HomeStructures", root
	local homeKits: any = nil
	world.renderHome = function(parts)
		local present = {}
		local kitRows = {}
		for _, definition in parts do
			if definition.kind == "biome-kit" then
				table.insert(kitRows, definition)
				continue
			end
			present[definition.id] = true
			local value = homeParts[definition.id]
			if not value then
				if definition.shape == "Wedge" then
					value = Instance.new("WedgePart")
					value.Name, value.Anchored = definition.id, true
				else
					value = part(definition.id, definition.position, definition.size)
				end
				value.Parent = folder
				homeParts[definition.id] = value
				local base, tier = string.match(definition.kind or "", "^(.+)%-t(%d)$")
				if base and stationKinds[base] then
					-- The first placed tier-N bench takes the anchor id station.<kind>.tN.
					local anchorId = "station." .. base .. ".t" .. tostring(tier)
					world.registerStation(
						value,
						if world.tieredStations[anchorId] then "home:" .. Journal.fnv1a64(definition.id) else anchorId,
						base
					)
					world.tieredStations[anchorId] = world.tieredStations[anchorId] or value
					stationPanel(value, base, tonumber(tier) or 1)
				elseif stationKinds[definition.kind] then
					world.registerStation(value, "home:" .. Journal.fnv1a64(definition.id), definition.kind)
				end
				if definition.kind == "farm-plot" then
					local prompt = Instance.new("ProximityPrompt")
					WorldText.bind(prompt, "farm", "farm-plot")
					prompt.MaxActivationDistance = 8
					prompt:SetAttribute("ForgePanel", "farm")
					prompt.Parent = value
				end
			end
			value.Size = Vector3.new(definition.size.x, definition.size.y, definition.size.z)
			style(value, definition)
			if definition.kind == "land" then
				value.Transparency, value.CanCollide = 1, false
				local half = definition.size.x / 2
				-- Terrain preset 1 is the original coast; presets 2-3 change the lobe count and tilt.
				local preset = definition.preset or 1
				workspace.Terrain:FillBall(Vector3.new(0, -half - 8, 0), half + 7, Enum.Material.Sand)
				-- The rectangular land envelope stays hidden behind organic low islands.
				for i = 1, 7 do
					local angle = i * math.pi * 2 / 7
					local radius = half * (0.6 + (i % 3) * 0.055)
					workspace.Terrain:FillBall(
						Vector3.new(math.cos(angle) * half * 0.65, -radius + 0.5, math.sin(angle) * half * 0.65),
						radius + 3,
						Enum.Material.Sand
					)
				end
				for x = -half - 8, half + 8, 4 do
					for z = -half - 8, half + 8, 4 do
						local angle = math.atan2(z, x)
						local edge = math.sqrt(x * x + z * z) / half
						local coast = 1.12
							+ 0.08 * math.sin(angle * (2 + preset) + (preset - 1) * 0.7)
							+ 0.045 * math.cos(angle * 7)
						if edge < coast then
							local top = 1 + math.sin(x / 13) * math.sin(z / 17) * math.clamp(edge - 0.55, 0, 0.6) * 3
							workspace.Terrain:FillBlock(
								CFrame.new(x, (top - 5) / 2, z),
								Vector3.new(4, top + 5, 4),
								if edge > coast - 0.17
									then Enum.Material.Sand
									elseif
										interactionGround(x, z, 4) or math.abs(x - math.sin(z / 16) * 2) < 3
									then Enum.Material.Ground
									else Enum.Material.Grass
							)
						end
					end
				end
			end
		end
		for id, value in homeParts do
			if not present[id] then
				for anchorId, held in world.tieredStations do
					if held == value then
						world.tieredStations[anchorId] = nil
					end
				end
				world.unregisterStation(value)
				value:Destroy()
				homeParts[id] = nil
			end
		end
		-- Land must exist before ray queries; home kits retain their authored offsets.
		local meshedKits = {}
		for _, definition in parts do
			local row = if definition.kit and definition.kitKind then Meshes.DRESSING[definition.kitKind] else nil
			if row and meshRows[row] then
				-- The kit's primitive parts stay as hidden handles; one mesh row renders the kit.
				local value = homeParts[definition.id]
				value.Transparency, value.CanCollide, value.CanQuery = 1, false, false
				if not meshedKits[definition.kit] then
					meshedKits[definition.kit] = true
					local visual = folder:FindFirstChild(definition.kit .. ".mesh") :: Model?
					local ground = definition.ground
					local hit =
						workspace:Raycast(Vector3.new(ground.x, 512, ground.z), Vector3.new(0, -1024, 0), groundParams)
					if hit and not visual then
						Meshes.place(row, CFrame.new(hit.Position), folder, definition.kit .. ".mesh")
					elseif hit and visual then
						(visual :: Model):PivotTo(CFrame.new(hit.Position))
					end
				end
			elseif definition.kind and Meshes.STRUCTURES[definition.kind] and not definition.decorative then
				-- A built home structure (HomeState record) keeps its station part; the mesh dresses it.
				local value = homeParts[definition.id]
				local hit = workspace:Raycast(
					Vector3.new(definition.position.x, 512, definition.position.z),
					Vector3.new(0, -1024, 0),
					groundParams
				)
				if hit then
					Meshes.dress(value, Meshes.STRUCTURES[definition.kind], CFrame.new(hit.Position))
				end
			end
		end
		for _, child in folder:GetChildren() do
			local kit = string.match(child.Name, "^(.+)%.mesh$")
			if kit and not meshedKits[kit] then
				child:Destroy()
			end
		end
		-- Shore palms and other home B1 rows: real kit meshes on the land surface (asset-audit L2).
		if #kitRows > 0 then
			local placements: { any } = {}
			for _, definition in kitRows do
				table.insert(placements, {
					key = definition.key,
					family = definition.family,
					x = definition.position.x,
					y = definition.position.y,
					z = definition.position.z,
					yaw = definition.yaw,
					scale = definition.scale,
				})
			end
			local loaded = BiomeKits.load({ "beach" }, Assets)
			if homeKits then
				homeKits:Destroy()
			end
			homeKits = Instance.new("Folder")
			homeKits.Name = "ForgeBiomeKits"
			BiomeKits.place(homeKits, placements, loaded, probe)
			homeKits.Parent = folder
		end
		for _, definition in parts do
			if (definition.kit and meshedKits[definition.kit]) or definition.kind == "biome-kit" then
				continue
			end
			if definition.kind == "farm-plot" then
				local position = interactionPosition(definition.position, definition.size.y)
				homeParts[definition.id].Position = Vector3.new(position.x, position.y, position.z)
			elseif definition.decorative then
				if definition.id == "home.path" then
					homeParts[definition.id].Transparency = 1
					continue
				end
				local placed = grounded(definition)
				local value = homeParts[definition.id]
				if placed then
					style(value, placed)
				else
					value.Transparency = 1
				end
			end
		end
		-- Starter pads and the home dock read as plank decks, farm plots as planted beds; the parts
		-- keep their collision and prompts (fitted after the farm plots are grounded above).
		for _, definition in parts do
			local value = homeParts[definition.id]
			if value and (definition.kind == "starter-pad" or definition.kind == "dock") then
				fitRow(value, "bld.timber.floor")
			elseif value and definition.kind == "farm-plot" then
				fitRow(value, "town.flower-bed")
			end
		end
	end
	-- Render after terrain is final; ranks from spawn drive client decor culling.
	local origin = { x = spawn.Position.X, z = spawn.Position.Z }
	local decorRanks = RenderBudget.rank(dressing.parts, origin)
	local effectRanks = RenderBudget.rank(dressing.parts, origin, function(definition: any): boolean
		return definition.effect ~= nil
	end)
	-- Town houses: a seeded cottage variant per house, the longhouse on large lots (L5 rows).
	local houseRows: { [string]: string } = {}
	for _, building in dressing.buildings do
		if building.kind == "house" then
			houseRows[building.id] =
				Meshes.house(building.lot, Rng.new(seed):fork("town-house:" .. building.id):nextNumber())
		end
	end
	for _, definition in dressing.parts do
		-- A kit with a B3 mesh row renders as one mesh model at its ground point instead of Parts.
		local row = if definition.kit then houseRows[definition.kit] or Meshes.DRESSING[definition.kitKind] else nil
		if row and meshRows[row] then
			if not root:FindFirstChild(definition.kit) then
				local ground = definition.ground
				local hit =
					workspace:Raycast(Vector3.new(ground.x, 512, ground.z), Vector3.new(0, -1024, 0), groundParams)
				if hit then
					local model = Meshes.place(
						row,
						CFrame.new(hit.Position) * CFrame.Angles(0, math.rad(definition.kitYaw or 0), 0),
						root,
						definition.kit
					)
					if model then
						model:SetAttribute("ForgeDecorRank", decorRanks[definition.id])
					end
				end
			end
			continue
		end
		local placed = grounded(definition)
		if placed then
			local value
			if placed.shape == "Wedge" then
				value = Instance.new("WedgePart")
				value.Name, value.Anchored, value.Parent = placed.id, true, root
				value.Size = Vector3.new(placed.size.x, placed.size.y, placed.size.z)
			else
				value = part(placed.id, placed.position, placed.size)
			end
			style(value, placed)
			value:SetAttribute("ForgeDecorRank", decorRanks[placed.id])
			value:SetAttribute("ForgeEffectRank", effectRanks[placed.id])
		end
	end
	-- Lava glow, hot-spring steam and ash plumes (plan.effects): an invisible, non-colliding emitter
	-- anchor per point on the ground, ranked like decor so the low profile caps them.
	local emitters = {}
	for _, point in dressing.effects do
		table.insert(emitters, { id = point.id, position = point.position, decorative = true })
	end
	local emitterRanks = RenderBudget.rank(emitters, origin)
	for _, point in dressing.effects do
		local p = point.position
		local y = if point.effect == "ash" and string.sub(point.id, 1, 8) == "offshore"
			then p.y
			else (probe(p.x, p.z) or p.y) + (if point.effect == "ash" then 12 else 0.5)
		local anchor = part(point.id .. ".effect", { x = p.x, y = y, z = p.z }, { x = 1, y = 1, z = 1 })
		anchor.Transparency, anchor.CastShadow = 1, false
		anchor.CanCollide, anchor.CanTouch, anchor.CanQuery = false, false, false
		addEffect(anchor, point.effect)
		anchor:SetAttribute("ForgeDecorRank", emitterRanks[point.id])
		anchor:SetAttribute("ForgeEffectRank", emitterRanks[point.id])
	end
	-- B1a mesh biome kits: seeded scatter on the shared terrain tops; package loads run off
	-- the build path so a slow InsertService never delays the world.
	if #columns > 0 then
		task.spawn(function()
			-- The seeded scatter plus the dressing plan's own rows (landmarks, hazard rims, arrival grove).
			local placements = BiomeKits.plan(layout, columns, seed, Terrain)
			for _, p in dressing.kits do
				table.insert(placements, p)
			end
			if layoutId == TownLife.LAYOUT then
				-- Ground cover between the core's yards and houses (TownLife.cover): grassland kit cards.
				for _, card in
					TownLife.cover(layout, TownLife.blockers(layout, Dressing.town(layout), Meshes.SET_PIECES))
				do
					table.insert(placements, {
						key = card.key,
						kit = "grassland",
						family = card.family,
						x = card.x,
						y = 4,
						z = card.z,
						yaw = card.yaw,
						scale = card.scale,
					})
				end
			end
			local loaded = BiomeKits.load(BiomeKits.kitsFor(layout), Assets)
			if root.Parent == nil then
				return
			end
			-- D1 (G21): nearest the spawn first. The first batch (within KIT_FIRST_RADIUS, inside the camp
			-- chunks written synchronously above) goes in at once; the rest follow KIT_BATCH per engine
			-- step once every chunk is written, so no frame places the whole island (20k on a 3072 island).
			local batches = BiomeKits.batches(placements, { x = entry.x, z = entry.z })
			local kitFolder = Instance.new("Folder")
			kitFolder.Name = "ForgeBiomeKits"
			-- Seat each kit on the rendered voxel surface, not the planned column top (see place):
			-- one engine step after a write the voxels are raycastable; probe falls back to the height
			-- field where a ray misses.
			local heartbeat = game:GetService("RunService").Heartbeat
			heartbeat:Wait()
			if (root :: any).Parent == nil then
				return
			end
			local count = BiomeKits.place(kitFolder, batches[1] or {}, loaded, probe, 0)
			kitFolder:SetAttribute("ForgeKitCount", count)
			kitFolder.Parent = root
			repeat
				heartbeat:Wait()
			until root:GetAttribute("ForgeTerrainReady") or (root :: any).Parent == nil
			local offset = #(batches[1] or {})
			for index = 2, #batches do
				if (root :: any).Parent == nil then
					return
				end
				count += BiomeKits.place(kitFolder, batches[index], loaded, probe, offset)
				offset += #batches[index]
				kitFolder:SetAttribute("ForgeKitCount", count)
				heartbeat:Wait()
			end
		end)
	end
	--- Saltmeadow town life (TownLife plan, R12/R13): the south bay shore, trampled squares and lanes,
	--- carts, laundry, fish racks, woodpiles, stalls and boats, campfire rings with seated folk, warm
	--- lamp posts, and posed survivor figures with a floating role label. All decor: no prompts, no
	--- collision; a missing row just leaves its spot empty.
	local function dressTownLife()
		local plan = TownLife.plan(layout)
		local life = Instance.new("Folder")
		life.Name, life.Parent = "ForgeTownLife", root
		-- South bay: grass south of the waterline becomes beach sloping into the sea, so the pier and the
		-- cutter stand in water and the hauled-up rowboats lie on sand.
		for x = -232, 232, 8 do
			if math.abs(x) <= TownLife.LANDING then
				continue -- the pier landing keeps its grass block
			end
			local shore = TownLife.shore(x)
			local from = shore - 24
			workspace.Terrain:FillBlock(
				CFrame.new(x, -4, (from + 680) / 2),
				Vector3.new(8, 24, 680 - from),
				Enum.Material.Air
			)
			-- Beach: 24 studs falling from the grass edge to the waterline, then a sand shelf under water.
			for step = 0, 2 do
				local top = 3.4 - step * 1.6
				workspace.Terrain:FillBlock(
					CFrame.new(x, (top - 16) / 2, from + 4 + step * 8),
					Vector3.new(8, top + 16, 8),
					Enum.Material.Sand
				)
			end
			workspace.Terrain:FillBlock(
				CFrame.new(x, -12, (shore + 680) / 2),
				Vector3.new(8, 8, 680 - shore),
				Enum.Material.Sand
			)
			workspace.Terrain:FillBlock(
				CFrame.new(x, -6, (shore + 680) / 2),
				Vector3.new(8, 4, 680 - shore),
				Enum.Material.Water
			)
		end
		-- Trampled earth: swap the surface material only (the ground height never changes).
		local function trample(cx: number, cz: number)
			-- ReplaceMaterial needs a region aligned to the 4-stud voxel grid.
			local low = Vector3.new(math.floor(cx / 4) * 4, -4, math.floor(cz / 4) * 4)
			local region = Region3.new(low, low + Vector3.new(4, 12, 4))
			for _, from in { Enum.Material.Grass, Enum.Material.LeafyGrass, Enum.Material.Limestone } do
				workspace.Terrain:ReplaceMaterial(region, 4, from, Enum.Material.Ground)
			end
		end
		-- Worn earth (TownLife.worn): narrow ragged foot paths and small patches, cell by cell.
		for _, cell in TownLife.worn() do
			trample(cell.x, cell.z)
		end
		-- Fenced yards (R12, TownLife.fences): town.plot-fence segments, a gate gap toward the street.
		for _, segment in TownLife.fences() do
			local y = probe(segment.x, segment.z)
			if y then
				local at = CFrame.new(segment.x, y - 0.1, segment.z) * CFrame.Angles(0, math.rad(segment.yaw), 0)
				Meshes.place("town.plot-fence", at, life, segment.id)
			end
		end
		local function frame(item: any): CFrame?
			local y = probe(item.x, item.z)
			if not y then
				return nil
			end
			local at = Vector3.new(item.x, y, item.z)
			if item.face then
				-- The row's front is local -Z: lookAt points -Z at the target.
				return CFrame.lookAt(at, Vector3.new(item.face.x, y, item.face.z))
			end
			return CFrame.new(at) * CFrame.Angles(0, math.rad(item.yaw or 0), 0)
		end
		for _, prop in plan.props do
			local at = frame(prop)
			if at then
				Meshes.place(prop.row, at, life, prop.id)
			end
		end
		for _, fire in plan.fires do
			local at = frame(fire)
			if at then
				local placed = Meshes.place(fire.row, at, life, fire.id)
				if placed then
					-- The row's __ember carries Fire + PointLight (a SkyDriver fire light); a town fire lights
					-- its whole bench ring.
					for _, item in placed:GetDescendants() do
						if item:IsA("PointLight") then
							item.Range = 16
							(item.Parent :: Instance):SetAttribute(SkyCycle.FIRE_SCALE, TownLife.FIRE_LIGHT)
							SkyCycle.glow(item.Parent :: Instance, 9)
						end
					end
				end
			end
		end
		for _, lamp in plan.lamps do
			local y = probe(lamp.x, lamp.z)
			if y then
				-- Lantern arms lean toward the main road; a dense town keeps each lamp a small warm spot.
				local head = torch(Vector3.new(lamp.x, y, lamp.z), if lamp.x > 0 then 180 else 0)
				head:SetAttribute(SkyCycle.FIRE_SCALE, TownLife.LAMP_LIGHT)
				SkyCycle.glow(head, 5)
			end
		end
		-- Folk: invisible handles carrying a posed survivor figure (1.35x, so they read at the play
		-- camera beside the 1x player) and a role label above the head.
		for _, folk in plan.folk do
			local y = probe(folk.x, folk.z)
			if not y then
				continue
			end
			local handle = Instance.new("Part")
			handle.Name, handle.Anchored, handle.Size = folk.id, true, Vector3.new(2, 1, 2)
			handle.Transparency, handle.CanCollide, handle.CanQuery, handle.CanTouch = 1, false, false, false
			handle.CFrame =
				CFrame.lookAt(Vector3.new(folk.x, y + 0.5, folk.z), Vector3.new(folk.face.x, y + 0.5, folk.face.z))
			handle:SetAttribute("ForgeTownFolk", folk.label)
			handle.Parent = life
			local label = Instance.new("BillboardGui")
			label.Name, label.Size = "ForgeFolkLabel", UDim2.fromOffset(96, 18)
			label.StudsOffsetWorldSpace = Vector3.new(0, if folk.pose == "sit" then 6.4 else 8.4, 0)
			-- Seated folk around one fire share a single label (the first sitter's).
			label.Enabled = folk.pose ~= "sit" or string.sub(folk.id, -2) == ".1"
			label.MaxDistance, label.LightInfluence = 220, 0
			local text = Instance.new("TextLabel")
			text.Size, text.BackgroundTransparency = UDim2.fromScale(1, 1), 1
			text.Font, text.TextSize = Enum.Font.BuilderSansBold, 13
			text.TextColor3, text.TextStrokeTransparency = Color3.fromRGB(240, 232, 214), 0.35
			text.Text = WorldText.text("en-us", folk.label)
			text:SetAttribute("ForgeTextKey", folk.label)
			text.Parent = label
			label.Parent = handle
			survivorFigure(
				"town:" .. folk.id,
				handle,
				{ pose = folk.pose, scale = TownLife.FOLK_SCALE, seat = folk.seat }
			)
		end
	end
	local destroy = world.destroy
	-- SpawnGate seats characters here (Players.CharacterAutoLoads is off in the place).
	world.spawnPart = spawn
	world.spawnReady = function(): boolean
		return root:GetAttribute("ForgeSpawnReady") == true
	end
	if layoutId == TownLife.LAYOUT then
		dressTownLife()
	end
	for _, piece in Meshes.SET_PIECES do
		if piece.layout == layoutId then
			local hit = workspace:Raycast(Vector3.new(piece.x, 512, piece.z), Vector3.new(0, -1024, 0), groundParams)
			local y = if hit then hit.Position.Y elseif piece.row == "town.boat" then 0 else nil
			if y and (piece.row == "town.boat" or piece.row == "town.dock") then
				-- The sea fill tops out at y=-4; the pier and moored cutter float on it, not the seabed.
				y = math.max(y, -3.6)
			end
			if y then
				Meshes.place(
					piece.row,
					CFrame.new(piece.x, y, piece.z) * CFrame.Angles(0, math.rad(piece.yaw), 0),
					root,
					"set." .. piece.row
				)
			end
		end
	end
	-- Terrain writes settle on the engine step before bind spawns and grounds wildlife.
	game:GetService("RunService").Heartbeat:Wait()
	if #arrivalGrazers > 0 then
		local rig = require(Forge.genres["survival-coop"].module.DinosaurRig)
		for _, animal in arrivalGrazers do
			rig.ground(animal)
		end
	end
	world.destroy = function()
		destroy()
		atmosphere:Destroy()
		correction:Destroy()
		bloom:Destroy()
		root:Destroy()
	end
	return world
end
return M
