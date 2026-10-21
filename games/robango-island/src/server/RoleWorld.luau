--!strict
-- Catalog projection shared by the pack's live role builders. The factory consumes
-- exactly the node and wildlife lists rendered here, not the legacy preview lists.
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local World = require(Forge.genres["survival-coop"].module.SurvivalWorld)
local Terrain = require(Forge.core.domain.island.ArchipelagoTerrain)
local Journal = require(Forge.core.domain.command.Journal)
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
	for _, column in Terrain.columns(layout, seed, 32) do
		workspace.Terrain:FillBlock(
			CFrame.new(column.x, (column.top - 16) / 2, column.z),
			Vector3.new(column.cell, column.top + 16, column.cell),
			Enum.Material.Grass
		)
	end
	-- The coarse seeded columns are scenery. Authored navigation is a continuous
	-- dry ribbon with the catalog's slope, including each node's approach branch.
	for _, path in layout.paths do
		for index = 2, #path.points do
			local a, b = path.points[index - 1], path.points[index]
			local from, to = Vector3.new(a.x, a.y, a.z), Vector3.new(b.x, b.y, b.z)
			local delta = to - from
			if delta.Magnitude > 0 then
				local ribbon =
					part(path.id .. "." .. tostring(index), a, { x = path.width, y = 1, z = delta.Magnitude + 1 })
				ribbon.CFrame = CFrame.lookAt((from + to) / 2 - Vector3.new(0, 0.5, 0), to - Vector3.new(0, 0.5, 0))
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
	for _, node in layout.resourceNodes do
		-- Quest cargo is a mission ledger, never a generic inventory mint.
		local item: any = nil
		for _, definition in content.items do
			if definition.id == node.item then
				item = definition
			end
		end
		if item then
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
		workspace.Terrain:FillBlock(
			CFrame.new(node.position.x, node.position.y + 8, node.position.z),
			Vector3.new(16, 16, 16),
			Enum.Material.Air
		)
		part(
			node.id .. ".ground",
			{ x = node.position.x, y = node.position.y - 2, z = node.position.z },
			{ x = 16, y = 1, z = 16 }
		)
		local target = part(node.id, node.position, { x = 3, y = 2, z = 3 })
		world.registerNode(target, node.id, node.catalogId, 0, revision)
	end
	for _, anchor in layout.anchors do
		local station = string.match(anchor.id, "^station%.(.+)%.t%d+$")
		if station then
			local target = part(anchor.id, anchor.position, { x = 4, y = 2, z = 3 })
			world.registerStation(target, anchor.id, station)
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
				if layoutId == "rw.onboarding" then "home" elseif layoutId == "rw.home" then "archipelago" else "home"
			)
		end
	end
	world.roleSource = table.clone(source)
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
						local id = objective.id .. "." .. tostring(index)
						world.surveyMarkers[id] = { position = position, objective = objective.id, layout = layoutId }
						local target = part(id, position, { x = 2, y = 3, z = 2 })
						local prompt = Instance.new("ProximityPrompt")
						prompt.ActionText, prompt.MaxActivationDistance, prompt.Parent = "Survey", 8, target
						prompt.Triggered:Connect(function(player)
							if world.surveyObjective then
								world.surveyObjective(tostring(player.UserId), objective.id, id)
							end
						end)
					end
				end
			end
		end
	end
	world.renderHome = function(parts)
		local previous = root:FindFirstChild("HomeStructures")
		if previous then
			previous:Destroy()
		end
		local folder = Instance.new("Folder")
		folder.Name, folder.Parent = "HomeStructures", root
		for _, definition in parts do
			local value = part(definition.id, definition.position, definition.size)
			value.Parent = folder
		end
	end
	local destroy = world.destroy
	world.destroy = function()
		destroy()
		root:Destroy()
	end
	return world
end
return M
