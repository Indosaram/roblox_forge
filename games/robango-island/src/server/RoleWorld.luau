--!strict
-- Catalog projection shared by the pack's live role builders. The factory consumes
-- exactly the node and wildlife lists rendered here, not the legacy preview lists.
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local World = require(Forge.genres["survival-coop"].module.SurvivalWorld)
local Terrain = require(Forge.core.domain.island.ArchipelagoTerrain)
local Journal = require(Forge.core.domain.command.Journal)
local Dressing = require("./WorldDressing")
local materials: any = Enum.Material
local shapes: any = Enum.PartType
local M = {}

function M.build(content: any, source: any, policy: any, nowMillis: any, layoutId: string, seed: number): any
	local layout: any = nil
	for _, candidate in content.layouts do
		if candidate.id == layoutId then
			layout = candidate
		end
	end
	assert(layout, "UNKNOWN_ROLE_LAYOUT:" .. layoutId)
	local root = Instance.new("Folder")
	root.Name, root.Parent = "ForgeRoleWorld", workspace
	local function part(id: string, position: any, size: any): any
		local value = Instance.new("Part")
		value.Name, value.Anchored = id, true
		value.Size = Vector3.new(size.x, size.y, size.z)
		value.Position = Vector3.new(position.x, position.y, position.z)
		value.Material = Enum.Material.Grass
		value.Parent = root
		return value
	end
	local columns: { any } = if layoutId == "rw.home"
		then {}
		else Terrain.columns(layout, seed, if layoutId == "rw.onboarding" then 16 else 32)
	local dressing = Dressing.plan(layout, columns, Terrain)
	workspace:SetAttribute("ForgeWorldBiome", layout.biomes[1])
	local function style(value: any, definition: any)
		value.Material = materials[definition.material or dressing.palette.ground]
		if definition.color then
			value.Color = Color3.fromRGB(table.unpack(definition.color))
		end
		if definition.shape then
			value.Shape = shapes[definition.shape]
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
				light.Color, light.Brightness, light.Range, light.Parent = Color3.fromRGB(255, 112, 26), 2, 28, value
			end
			if definition.effect == "fire" then
				local fire = Instance.new("Fire")
				fire.Size, fire.Heat, fire.Parent = 5, 7, value
			end
			if definition.effect ~= "lava" then
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
	for _, definition in dressing.parts do
		style(part(definition.id, definition.position, definition.size), definition)
	end
	local Proc = require(Forge.core.infra.render.ProcAssets)
	local specs = require(Forge.games["robango-island"].src.shared.ProcAssets)
	-- One cached mesh key is reserved for nearby mineral outcrops, not one mesh per node.
	for index, prop in dressing.props do
		if prop.kind == "rock" and index <= 24 then
			local model = assert(Proc.build(specs, "survival-coop-starter-prop", "ShoreOutcrop"))
			model:ScaleTo(2)
			model:PivotTo(CFrame.new(prop.position.x, prop.position.y + 1, prop.position.z))
			model.Parent = root
		end
	end
	local lighting = game:GetService("Lighting")
	lighting.ClockTime, lighting.Brightness = 9.5, 2
	lighting.Ambient = Color3.fromRGB(111, 123, 127)
	lighting.OutdoorAmbient = Color3.fromRGB(148, 157, 150)
	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Name = "ForgeBiomeAtmosphere"
	atmosphere.Color = Color3.fromRGB(table.unpack(dressing.palette.fog))
	atmosphere.Density, atmosphere.Haze, atmosphere.Parent = 0.12, 0.5, lighting
	workspace.Terrain.WaterColor = Color3.fromRGB(69, 139, 153)
	workspace.Terrain.WaterTransparency = 0.35
	workspace.Terrain:FillBlock(CFrame.new(0, -10, 0), Vector3.new(1400, 12, 1400), Enum.Material.Water)
	for _, column in columns do
		workspace.Terrain:FillBlock(
			CFrame.new(column.x, (column.top - 16) / 2, column.z),
			Vector3.new(column.cell, column.top + 16, column.cell),
			materials[column.material]
		)
	end
	-- The coarse seeded columns are scenery. Authored navigation is a continuous
	-- dry ribbon with the catalog's slope, including each node's approach branch.
	local paths: { any } = if layoutId == "rw.home" then {} else layout.paths
	for _, path in paths do
		for index = 2, #path.points do
			local a, b = path.points[index - 1], path.points[index]
			local from, to = Vector3.new(a.x, a.y, a.z), Vector3.new(b.x, b.y, b.z)
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
	spawn.Parent = root
	local runtimeContent: any = table.clone(content)
	runtimeContent.nodes = table.clone(content.nodes)
	local nodes, spawns = {}, {}
	local nodeItems: any = {}
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
			local catalogId = string.gsub(node.id, "[._]", "-")
			table.insert(runtimeContent.nodes, {
				id = catalogId,
				harvest = { { item = node.item, quantity = node.yield } },
				respawnMillis = node.respawnSeconds * 1000,
			})
			table.insert(nodes, {
				id = node.id,
				catalogId = catalogId,
				position = node.position,
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
	if layoutId == "rw.onboarding" then
		-- Distant, noninteractive silhouettes establish the era without adding
		-- predators or changing the tutorial's authored wildlife encounters.
		local rig = require(Forge.genres["survival-coop"].module.DinosaurRig)
		for index, offset in { -36, 32 } do
			local position = Vector3.new(entry.x + offset, entry.y, entry.z - 58 - index * 12)
			workspace.Terrain:FillBall(position - Vector3.new(0, 6, 0), 12, Enum.Material.Sand)
			local animal = rig.new("triceratops", "ArrivalGrazer" .. index, position, root)
			animal:ScaleTo(1.4)
			animal:PivotTo(CFrame.new(position) * CFrame.Angles(0, math.rad(60 + index * 50), 0))
			for _, piece in animal:GetDescendants() do
				if piece:IsA("BasePart") then
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
	})
	for _, node in nodes do
		if layoutId ~= "rw.home" then
			workspace.Terrain:FillBlock(
				CFrame.new(node.position.x, node.position.y + 8, node.position.z),
				Vector3.new(16, 16, 16),
				Enum.Material.Air
			)
		end
		part(
			node.id .. ".ground",
			{ x = node.position.x, y = node.position.y - 2, z = node.position.z },
			{ x = 16, y = 1, z = 16 }
		)
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
	end
	local musicVenues = {}
	for _, anchor in layout.anchors do
		local station = string.match(anchor.id, "^station%.(.+)%.t%d+$")
		if station then
			local target = part(anchor.id, anchor.position, { x = 4, y = 2, z = 3 })
			world.registerStation(target, anchor.id, station)
			if station == "campfire" or station == "fireplace" then
				table.insert(musicVenues, { enabled = true, part = target })
			end
		end
	end
	world.musicVenues = function()
		return musicVenues
	end
	if layoutId == "rw.harbor" then
		local Harbor = require(Forge.genres["survival-coop"].module.HarborFacilities)
		world.harborFacilities = Harbor.describe(content)
		for _, facility in world.harborFacilities do
			if facility.kind == "npc" or facility.kind == "market" or facility.kind == "interaction" then
				local target = part(facility.id, facility.position, { x = 2, y = 4, z = 2 })
				target:SetAttribute("ForgeHarborFacility", facility.anchor)
				local prompt = Instance.new("ProximityPrompt")
				prompt.ActionText = if facility.kind == "market" then "Market" else "Interact"
				prompt.ObjectText, prompt.MaxActivationDistance, prompt.Parent = facility.anchor, 8, target
				prompt:SetAttribute("ForgeMarket", facility.kind == "market" or facility.anchor == "npc.sella")
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
		local target = part(id, position, { x = 10, y = 1, z = 8 })
		target.Material = Enum.Material.WoodPlanks
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name, prompt.ActionText, prompt.ObjectText = "ForgeDock", "Travel", destination
		prompt.MaxActivationDistance, prompt.RequiresLineOfSight, prompt.Parent = 8, true, target
		prompt.Triggered:Connect(function(player)
			local actor = tostring(player.UserId)
			local reach = world.services.survivalDeath
			if bound and reach.reachable(actor, position) and world.travel then
				world.travel(player, destination)
			end
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
	world.roleSource = table.clone(source)
	world.roleSource.resourceNodes = layout.resourceNodes
	world.roleSource.nodes, world.roleSource.worldRevision = nodes, revision
	world.roleSource.persistencePrefix = "s:" .. Journal.fnv1a64(source.persistencePrefix .. ":" .. revision)
	world.roleSource.sourceKey = "n"
	world.roleContent, world.roleWildlife, world.layout = runtimeContent, wildlife, layout
	world.surveyMarkers = {}
	for _, stage in content.stages do
		if stage.layout == layoutId then
			for _, objective in stage.objectives do
				if objective.action == "survey" then
					local origin: any = nil
					for _, anchor in layout.anchors do
						if anchor.id == "objective" then
							origin = anchor.position
						end
					end
					for index = 1, objective.quantity do
						local position = { x = origin.x + (index - 1) * 12 - 12, y = origin.y, z = origin.z - 12 }
						if index > 3 then
							position.x, position.z = origin.x + (index - 4) * 12 - 6, origin.z - 24
						end
						local id = objective.id .. "." .. tostring(index)
						world.surveyMarkers[id] = { position = position, objective = objective.id, layout = layoutId }
						local target = part(id, position, { x = 2, y = 3, z = 2 })
						local prompt = Instance.new("ProximityPrompt")
						prompt.ActionText, prompt.MaxActivationDistance, prompt.Parent =
							"Survey", content.missionPolicy.interactionStuds, target
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
	world.publishEscort = function(actor, state)
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
		prompt.ActionText, prompt.MaxActivationDistance, prompt.Parent =
			operation, content.missionPolicy.interactionStuds, target
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
				value = part(definition.id, definition.position, definition.size)
				value.Parent = folder
				homeParts[definition.id] = value
				if stationKinds[definition.kind] then
					world.registerStation(value, "home:" .. Journal.fnv1a64(definition.id), definition.kind)
				end
			end
			value.Size = Vector3.new(definition.size.x, definition.size.y, definition.size.z)
			style(value, definition)
			if definition.kind == "land" then
				value.Transparency, value.CanCollide = 1, false
				local half = definition.size.x / 2
				workspace.Terrain:FillBall(Vector3.new(0, -half - 2, 0), half + 7, Enum.Material.Sand)
				workspace.Terrain:FillBlock(
					CFrame.new(0, -3, 0),
					Vector3.new(half * 2, 8, half * 2),
					Enum.Material.Grass
				)
				for i = 1, 8 do
					local angle = i * math.pi / 4
					workspace.Terrain:FillBall(
						Vector3.new(math.cos(angle) * half * 0.8, -half * 0.45, math.sin(angle) * half * 0.8),
						half * 0.55,
						Enum.Material.Sand
					)
				end
			end
		end
		for id, value in homeParts do
			if not present[id] then
				world.unregisterStation(value)
				value:Destroy()
				homeParts[id] = nil
			end
		end
	end
	local destroy = world.destroy
	world.destroy = function()
		destroy()
		atmosphere:Destroy()
		root:Destroy()
	end
	return world
end
return M
