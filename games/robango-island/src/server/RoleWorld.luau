--!strict
-- Catalog projection shared by the pack's live role builders. The factory consumes
-- exactly the node and wildlife lists rendered here, not the legacy preview lists.
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local World = require(Forge.genres["survival-coop"].module.SurvivalWorld)
local Terrain = require(Forge.core.domain.island.ArchipelagoTerrain)
local Journal = require(Forge.core.domain.command.Journal)
local Rng = require(Forge.core.domain.random.Rng)
local Dressing = require("./WorldDressing")
local WorldText = require(Forge.games["robango-island"].src.shared.WorldText)
local RenderBudget = require(Forge.games["robango-island"].src.shared.RenderBudget)
local CharacterRules = require(Forge.genres["survival-coop"].module.CharacterRules)
local materials: any = Enum.Material
local shapes: any = Enum.PartType
local M = {}

M.travelSerial = 0
--- Publishes a dock travel result to the player as "<outcome>|<serial>"; the HUD
--- tracker shows each new value for a few seconds. Also logged for Studio QA.
function M.publishTravel(player: any, outcome: string)
	M.travelSerial += 1
	print("ForgeTravel " .. tostring(player.UserId) .. " " .. outcome)
	player:SetAttribute("ForgeTravelResult", outcome .. "|" .. tostring(M.travelSerial))
end

function M.build(content: any, source: any, policy: any, nowMillis: any, layoutId: string, seed: number): any
	local layout: any = nil
	for _, candidate in content.layouts do
		if candidate.id == layoutId then
			layout = candidate
		end
	end
	assert(layout, "UNKNOWN_ROLE_LAYOUT:" .. layoutId)
	local root = Instance.new("Folder")
	root.Name = "ForgeRoleWorld"
	-- Clients re-derive the ProcProps decor plan from these before it replicates.
	root:SetAttribute("ForgeLayoutId", layoutId)
	root:SetAttribute("ForgeWorldSeed", seed)
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
	local columns: { any } = if layoutId == "rw.home"
		then {}
		else Terrain.columns(layout, seed, if layoutId == "rw.onboarding" then 16 else 32)
	local dressing = Dressing.plan(layout, columns, Terrain)
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
		if definition.effect and not value:FindFirstChild("ForgeEffect") then
			local effect = Instance.new("Folder")
			effect.Name, effect.Parent = "ForgeEffect", value
			if definition.effect == "lava" or definition.effect == "fire" then
				local light = Instance.new("PointLight")
				light.Color, light.Brightness, light.Range, light.Parent = Color3.fromRGB(255, 112, 26), 0.8, 10, value
			end
			if definition.effect == "fire" then
				local fire = Instance.new("Fire")
				fire.Size, fire.Heat, fire.Parent = 2, 4, value
			elseif definition.effect ~= "lava" then
				local smoke = Instance.new("Smoke")
				smoke.Color = if definition.effect == "steam"
					then Color3.fromRGB(224, 234, 230)
					else Color3.fromRGB(95, 91, 85)
				smoke.Size, smoke.RiseVelocity, smoke.Opacity, smoke.Parent =
					if definition.effect == "ash" then 22 else 7, 9, 0.35, value
			end
			if definition.effect == "ash" then
				local ash = Instance.new("ParticleEmitter")
				ash.Texture, ash.Rate = "rbxasset://textures/particles/smoke_main.dds", 12
				ash.Lifetime, ash.Speed = NumberRange.new(3, 5), NumberRange.new(7, 12)
				ash.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 12) })
				ash.Transparency =
					NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
				ash.Color, ash.Parent = ColorSequence.new(Color3.fromRGB(87, 81, 74)), value
			end
		end
	end
	-- Include only Terrain: another prop, path or canopy can never become ground.
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Include
	groundParams.FilterDescendantsInstances = { workspace.Terrain }
	groundParams.IgnoreWater = true
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
		local hit = workspace:Raycast(Vector3.new(ground.x, 512, ground.z), Vector3.new(0, -1024, 0), groundParams)
		if not hit then
			return nil
		end
		local result = table.clone(definition)
		result.position = {
			x = definition.position.x,
			y = definition.position.y + hit.Position.Y - ground.y - 0.15,
			z = definition.position.z,
		}
		return result
	end
	local lighting = game:GetService("Lighting")
	local initialAtmosphere = lighting:FindFirstChild("ForgeAtmosphere")
	if initialAtmosphere then
		initialAtmosphere:Destroy()
	end
	lighting.ClockTime, lighting.Brightness = 16.2, 2.3
	lighting.Ambient = Color3.fromRGB(108, 113, 119)
	lighting.OutdoorAmbient = Color3.fromRGB(151, 151, 137)
	-- Atmosphere supplies depth haze (Fog* is ignored with it). No DepthOfField: a full-screen
	-- blur costs low-end mobile fill rate and would smear distant nodes under the aerial camera.
	local rays = lighting:FindFirstChild("ForgeSunRays") or Instance.new("SunRaysEffect")
	rays.Name, rays.Intensity, rays.Spread, rays.Parent = "ForgeSunRays", 0.04, 0.5, lighting
	local correction = Instance.new("ColorCorrectionEffect")
	correction.Name, correction.Brightness, correction.Contrast = "ForgeWarmGrade", 0.02, 0.13
	correction.Saturation, correction.TintColor, correction.Parent = 0.12, Color3.fromRGB(255, 246, 228), lighting
	local bloom = Instance.new("BloomEffect")
	bloom.Name, bloom.Intensity, bloom.Size, bloom.Threshold, bloom.Parent = "ForgeEmberBloom", 0.08, 14, 1.8, lighting
	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Name = "ForgeBiomeAtmosphere"
	atmosphere.Color = Color3.fromRGB(table.unpack(dressing.palette.fog))
	atmosphere.Decay = Color3.fromRGB(120, 140, 160)
	atmosphere.Density, atmosphere.Offset, atmosphere.Haze, atmosphere.Glare = 0.26, 0.12, 1.1, 0.25
	atmosphere.Parent = lighting
	workspace.Terrain.WaterColor = Color3.fromRGB(69, 139, 153)
	workspace.Terrain.WaterTransparency = 0.35
	workspace.Terrain:FillBlock(CFrame.new(0, -10, 0), Vector3.new(1400, 12, 1400), Enum.Material.Water)
	local coastline = if Terrain.organic(layout) then Terrain.coast(layout, seed) else nil
	if coastline then
		-- Organic islands keep only land columns; a single sand floor stands in for the seabed.
		workspace.Terrain:FillBlock(CFrame.new(0, -14, 0), Vector3.new(1400, 4, 1400), Enum.Material.Sand)
	end
	-- Mossy trampled earth and sparse light stone sit close to the grass value, never dark stains.
	workspace.Terrain:SetMaterialColor(Enum.Material.Ground, Color3.fromRGB(98, 116, 60))
	workspace.Terrain:SetMaterialColor(Enum.Material.Limestone, Color3.fromRGB(122, 126, 92))
	local tops, blobs, blobRng = {}, {}, Rng.new(seed):fork(layoutId .. ":ground")
	for _, column in columns do
		tops[column.x .. "," .. column.z] = column.top
	end
	for _, column in columns do
		local protected = Terrain.protected(layout, column.x, column.z, column.cell)
		local material = column.material
		if
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
			if not coastline and river < column.cell * 0.55 and column.z > layout.bounds.min.z + 64 then
				top, material = -5, "Sand"
			elseif if column.beach == nil then top < 8 else column.beach then
				material = "Sand"
			elseif table.find(layout.biomes, "volcano") and column.x < -32 then
				material = if column.x % 96 < 32 then "CrackedLava" else "Basalt"
			elseif layout.biomes[1] == "snow" and column.x % 96 < 32 then
				material = "Ice"
			end
		end
		local floor = top
		for dx = -1, 1 do
			for dz = -1, 1 do
				floor = math.min(floor, tops[column.x + dx * column.cell .. "," .. column.z + dz * column.cell] or top)
			end
		end
		-- Organic islands: a step above the lowest neighbour is a round cap (radius covers the
		-- cell's corners), so authored height changes read as rounded rises, not square terraces.
		local cap = coastline ~= nil and top > 0 and top - math.max(floor, 0) > 1
		local base = if cap then math.max(floor, 0) else top
		workspace.Terrain:FillBlock(
			CFrame.new(column.x, (base - 16) / 2, column.z),
			Vector3.new(column.cell, base + 16, column.cell),
			materials[material]
		)
		if cap then
			if top - base > 4 then
				-- A wider half-height skirt splits a tall rise into two rounded shoulders.
				local mid = (base + top) / 2
				workspace.Terrain:FillCylinder(
					CFrame.new(column.x, (base + mid) / 2 - 2, column.z),
					mid - base + 4,
					column.cell * 0.95,
					materials[material]
				)
			end
			workspace.Terrain:FillCylinder(
				CFrame.new(column.x, (base + top) / 2 - 2, column.z),
				top - base + 4,
				column.cell * 0.72,
				materials[material]
			)
		end
		if top > 0 then
			-- Seeded discs spill each column's surface into its neighbours below their own
			-- surface height, so material borders are round and never a square tile grid.
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
		-- Square land columns stop inside the coast; two rings of low sand domes walked along the
		-- seeded lobed coastline draw a round beach that slopes under the water line.
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
		-- Sand discs cover the band from the coast to M.band, hiding the square column edges;
		-- grass discs then repaint GRASS_EDGE..band, so the grass edge is the inset coast curve.
		-- Columns in the band sit at BEACH_TOP, so the discs only change surface material.
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
	-- The coarse seeded columns are scenery. Authored navigation is a continuous
	-- dry ribbon with the catalog's slope, including each node's approach branch.
	local paths: { any } = if layoutId == "rw.home" then {} else layout.paths
	local low, high = layout.bounds.min, layout.bounds.max
	local function inside(p: any): boolean
		return p.x >= low.x and p.x <= high.x and p.z >= low.z and p.z <= high.z
	end
	for _, path in paths do
		for index = 2, #path.points do
			local a, b = path.points[index - 1], path.points[index]
			-- Habitat approaches start offshore; a ribbon there read as a concrete frame in the sea.
			if not inside(a) and not inside(b) then
				continue
			end
			local from = Vector3.new(math.clamp(a.x, low.x, high.x), a.y, math.clamp(a.z, low.z, high.z))
			local to = Vector3.new(math.clamp(b.x, low.x, high.x), b.y, math.clamp(b.z, low.z, high.z))
			local delta = to - from
			if delta.Magnitude > 0 then
				local ribbon =
					part(path.id .. "." .. tostring(index), a, { x = path.width, y = 1, z = delta.Magnitude + 1 })
				ribbon.CFrame = CFrame.lookAt((from + to) / 2 - Vector3.new(0, 0.5, 0), to - Vector3.new(0, 0.5, 0))
				ribbon.Material = Enum.Material.Ground
				ribbon.Color = Color3.fromRGB(169, 145, 102)
			end
		end
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
	local runtimeContent: any = table.clone(content)
	runtimeContent.nodes = table.clone(content.nodes)
	if layoutId == "rw.home" then
		-- Home land is published after role construction. Sample its starting surface
		-- now as well, so gather authority is grounded before the factory copies it.
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
	-- Voxel writes are not raycastable until the engine steps; without this the
	-- node rays below miss and nodes stay at their authored, buried height.
	game:GetService("RunService").Heartbeat:Wait()
	for _, path in layout.paths do
		if string.match(layoutId, "^rw%.a%d+%.s%d+$") and string.sub(path.id, -5) == ".main" then
			-- Spawn on the trail 32 studs short of the resource yard, not at the far dock.
			local y, q = path.points[3], path.points[2]
			local at = Vector3.new(y.x, 512, y.z) + (Vector3.new(q.x, 512, q.z) - Vector3.new(y.x, 512, y.z)).Unit * 32
			local hit = workspace:Raycast(at, Vector3.new(0, -1024, 0), groundParams)
			spawn.Position = Vector3.new(at.X, if hit then hit.Position.Y + 0.5 else y.y + 1, at.Z)
		end
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
	for _, authored in layout.spawns do
		for index = 1, authored.count do
			table.insert(spawns, {
				id = authored.id .. "." .. tostring(index),
				catalogId = authored.speciesId,
				position = authored.position,
			})
		end
	end
	local arrivalGrazers = {}
	if #dressing.fauna > 0 then
		-- Arrival-view creature: decorative and anchored, never an interactive wildlife spawn.
		local rig = require(Forge.genres["survival-coop"].module.DinosaurRig)
		for _, creature in dressing.fauna do
			local p = creature.position
			local hit = workspace:Raycast(Vector3.new(p.x, 512, p.z), Vector3.new(0, -1024, 0), groundParams)
			local position = Vector3.new(p.x, if hit then hit.Position.Y + 2 else p.y + 2, p.z)
			local animal = rig.new(creature.species, "ArrivalFauna", position, root)
			table.insert(arrivalGrazers, animal)
			animal:PivotTo(CFrame.new(position) * CFrame.Angles(0, math.rad(140), 0))
			for _, piece in animal:GetDescendants() do
				if piece:IsA("BasePart") then
					piece.Anchored = true
					piece.CanCollide, piece.CanTouch, piece.CanQuery = false, false, false
				end
			end
		end
	end
	if layoutId == "rw.onboarding" then
		-- Distant, noninteractive silhouettes establish the era without adding
		-- predators or changing the tutorial's authored wildlife encounters.
		local rig = require(Forge.genres["survival-coop"].module.DinosaurRig)
		for index, offset in { -36, 32 } do
			local position = Vector3.new(entry.x + offset, entry.y, entry.z - 58 - index * 12)
			workspace.Terrain:FillBall(position - Vector3.new(0, 6, 0), 12, Enum.Material.Sand)
			game:GetService("RunService").Heartbeat:Wait()
			local animal = rig.new("triceratops", "ArrivalGrazer" .. index, position, root)
			table.insert(arrivalGrazers, animal)
			animal:ScaleTo(1.4)
			animal:PivotTo(CFrame.new(position) * CFrame.Angles(0, math.rad(60 + index * 50), 0))
			rig.ground(animal)
			for _, piece in animal:GetDescendants() do
				if piece:IsA("BasePart") then
					piece.Anchored = true
					piece.CanCollide, piece.CanTouch, piece.CanQuery = false, false, false
				end
			end
		end
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
			local drops = {}
			for _, drop in definition.dropReservoirs do
				table.insert(drops, { item = drop.item, quantity = drop.quantity })
			end
			wildlife.catalog.species[definition.id] =
				{ healthMilli = definition.health * 1000, damageMilli = definition.damage * 1000, drops = drops }
		end
	end
	wildlife.spawns = spawns
	if content.missionPolicy then
		local combat = content.missionPolicy
		wildlife.catalog.weapons = table.clone(wildlife.catalog.weapons)
		wildlife.catalog.weapons[combat.starterWeapon] = {
			damageMilli = combat.weaponDamageMilli,
			wearMilli = combat.weaponWearMilli,
			rangeStuds = combat.weaponRangeStuds,
			cooldownMillis = combat.weaponCooldownMillis,
			facingDot = 0,
		}
	end
	wildlife.maximum = math.max(policy.maximum, #spawns)
	wildlife.sourceKey = "w"
	local revision = layoutId .. ":" .. tostring(seed)
	local world: any = World.new({
		content = runtimeContent,
		worldRevision = revision,
		spawn = spawn,
		carriedContainer = "bag",
		reachStuds = 8,
		baseWalkSpeed = 16,
		wildlife = { catalog = wildlife.catalog, spawns = spawns, maximum = wildlife.maximum, nowMillis = nowMillis },
		respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		-- Archipelago stages tick their authored hazard zones (CharacterRules.hazardExposure).
		hazards = if string.match(layoutId, "^rw%.a%d+%.s%d+$") then { layout = layout } else nil,
	})
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
		-- Decorative family kit beside the target; rendered with the dressing pass below.
		local p: any = node.position
		Dressing.kit(
			dressing.parts,
			node.id .. ".kit",
			{ x = p.x + 8, y = p.y, z = p.z + 6 },
			if family == "wood" and layoutId ~= "rw.home"
				then "tree"
				elseif family == "water" then "grass"
				elseif family == "mineral" then "rock"
				else "bush",
			dressing.palette
		)
		world.registerNode(target, node.id, node.catalogId, 0, revision)
		-- Attributes cannot hold tables; the HUD tracker resolves the item id to a localized name.
		target:SetAttribute("ForgeNodeItem", nodeItems[node.id].id)
	end
	-- Station panels: a tier-2+ workbench opens ui.modify, a signal relay opens ui.technical-support.
	-- The server still gates every command on station kind, tier and reach.
	world.tieredStations = {}
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
			stationPanel(target, station, tonumber(string.match(anchor.id, "%.t(%d+)$")) or 1)
			if station == "campfire" or station == "fireplace" then
				table.insert(musicVenues, { enabled = true, part = target })
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
	if layoutId == "rw.harbor" then
		local Harbor = require(Forge.genres["survival-coop"].module.HarborFacilities)
		world.harborFacilities = Harbor.describe(content)
		for _, facility in world.harborFacilities do
			if facility.kind == "npc" or facility.kind == "market" or facility.kind == "interaction" then
				facility.position = interactionPosition(facility.position, 4)
				local target = part(facility.id, facility.position, { x = 2, y = 4, z = 2 })
				target:SetAttribute("ForgeHarborFacility", facility.anchor)
				local prompt = Instance.new("ProximityPrompt")
				WorldText.bind(prompt, if facility.kind == "market" then "market" else "interact", facility.anchor)
				prompt.MaxActivationDistance, prompt.Parent = 8, target
				-- The market board talks first; its Market choice opens the market panel.
				prompt:SetAttribute("ForgeMarket", facility.anchor == "npc.sella")
				prompt:SetAttribute("ForgePanel", facility.panel)
				prompt:SetAttribute("ForgeDialogue", facility.talk)
				prompt.Triggered:Connect(function(player)
					if
						facility.destination
						and world.travel
						and world.services.survivalDeath.reachable(tostring(player.UserId), facility.position)
					then
						world.travel(player, facility.destination)
					end
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
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ForgeDock"
		WorldText.bind(prompt, "travel", destination)
		prompt:SetAttribute("ForgeDestination", destination)
		prompt.MaxActivationDistance, prompt.RequiresLineOfSight, prompt.Parent = 8, true, target
		prompt.Triggered:Connect(function(player)
			local actor = tostring(player.UserId)
			local reach = world.services.survivalDeath
			local approach = { x = position.x, y = position.y + 2, z = position.z }
			local outcome: string
			if not (bound and world.travel) then
				outcome = "expedition_inactive"
			elseif not reach.reachable(actor, approach) then
				outcome = "dock_unreachable"
			else
				local ok, reason = world.travel(player, destination)
				outcome = if ok then "travelling" else tostring(reason or "travel_refused")
			end
			-- The server's result is always shown: refusal reason or the travelling notice.
			M.publishTravel(player, outcome)
		end)
	end
	for _, anchor in layout.anchors do
		if anchor.id == "entry" or anchor.id == "exit" then
			dock(
				anchor.id,
				if layoutId == "rw.home" then content.homePolicy.dock else anchor.position,
				if layoutId == "rw.onboarding"
					then "home"
					elseif layoutId == "rw.home" then "archipelago"
					elseif string.match(layoutId, "^rw%.a%d+%.s%d+$") and anchor.id == "exit" then "next-island"
					else "home"
			)
		end
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
		world.roleSource.tribe.origin = { x = -32, y = 4, z = -16 }
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
					world.journalTargets[id] = { position = position, objective = objective.id, marker = id }
					local target = part(id, position, { x = 2, y = 3, z = 2 })
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
			escorts[actor] = npc
		end
		npc.Position = Vector3.new(position.x, position.y, position.z)
		npc:SetAttribute("Treated", state.treated)
	end
	local function missionPrompt(operation, position)
		local target = part(operation, position, { x = 2, y = 3, z = 2 })
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
	world.renderHome = function(parts)
		local present = {}
		for _, definition in parts do
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
					-- A placed tier-N bench serves its base station kind; the first one in this
					-- world takes the anchor id the progression owner resolves (station.<kind>.tN).
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
				-- The durable rectangular land envelope remains a hidden capability;
				-- visible terrain is an asymmetric overlapping set of low islands.
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
		for _, definition in parts do
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
	end
	-- Render after terrain, ribbons and catalog clearings have reached final shape.
	-- Ranks from the spawn let each client's render profile drop far decor and effects.
	local origin = { x = spawn.Position.X, z = spawn.Position.Z }
	local decorRanks = RenderBudget.rank(dressing.parts, origin)
	local effectRanks = RenderBudget.rank(dressing.parts, origin, function(definition: any): boolean
		return definition.effect ~= nil
	end)
	for _, definition in dressing.parts do
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
	local destroy = world.destroy
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
