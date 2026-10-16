--!strict
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local CollectionService = game:GetService("CollectionService")
local World = require(Forge.genres["survival-coop"].module.SurvivalWorld)
return function(content, source, wildlifePolicy, epochMillis)
	local geometry = Instance.new("Folder")
	geometry.Name, geometry.Parent = "DevelopmentIsland", workspace
	local function part(name: string, size: Vector3, position: Vector3, color: Color3, className: string?): BasePart
		local value: BasePart = if className == "WedgePart" then Instance.new("WedgePart") else Instance.new("Part")
		value.Name, value.Anchored, value.Size, value.Position = name, true, size, position
		value.Color, value.TopSurface, value.BottomSurface = color, Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		value.Parent = geometry
		return value
	end
	part("IslandFloor", Vector3.new(64, 2, 48), Vector3.new(0, -1, 8), Color3.fromRGB(90, 112, 72))
	local warehouse: { x: number, y: number, z: number } = source.tribe.warehousePosition
	part(
		"WarehouseApproach",
		Vector3.new(12, 2, 16),
		Vector3.new(warehouse.x, -1, warehouse.z + 4),
		Color3.fromRGB(90, 112, 72)
	)
	local marker = part(
		"Warehouse",
		Vector3.new(3, 2, 2),
		Vector3.new(warehouse.x + 3, 1, warehouse.z),
		Color3.fromRGB(116, 77, 45)
	)
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
	local campfire = part("campfire", Vector3.new(3, 1, 3), Vector3.new(-6, 0.5, 0), Color3.fromRGB(185, 89, 39))
	local bench = part("workbench", Vector3.new(4, 2, 2), Vector3.new(6, 1, 0), Color3.fromRGB(116, 77, 45))
	world.registerStation(campfire, "campfire", "campfire")
	world.registerStation(bench, "workbench", "workbench")
	for _, node in source.nodes do
		local position = Vector3.new(node.position.x, node.position.y, node.position.z)
		local shape
		if node.catalogId == "fallen-tree" then
			shape = part(node.id, Vector3.new(6, 2, 2), position, Color3.fromRGB(105, 70, 42))
			local log = shape :: Part
			log.Shape = Enum.PartType.Cylinder
		elseif node.catalogId == "flint-outcrop" then
			shape = part(node.id, Vector3.new(4, 4, 3), position, Color3.fromRGB(88, 96, 110), "WedgePart")
		elseif node.catalogId == "fiber-bush" then
			shape = part(node.id, Vector3.new(1, 4, 2), position, Color3.fromRGB(154, 163, 80))
			part(node.id .. "-blade", Vector3.new(3, 3, 0.5), position, Color3.fromRGB(130, 147, 63))
		elseif node.catalogId == "berry-bush" then
			shape = part(node.id, Vector3.new(4, 4, 4), position, Color3.fromRGB(49, 112, 59))
			local bush = shape :: Part
			bush.Shape = Enum.PartType.Ball
			local berries = part(
				node.id .. "-berries",
				Vector3.new(1.5, 1.5, 1.5),
				position + Vector3.new(0, 1, -1.5),
				Color3.fromRGB(145, 45, 81)
			)
			local fruit = berries :: Part
			fruit.Shape, fruit.CanCollide, fruit.CanQuery = Enum.PartType.Ball, false, false
		else
			shape = part(node.id, Vector3.new(3, 2, 3), position, Color3.fromRGB(155, 75, 62))
			part(
				node.id .. "-bone",
				Vector3.new(4, 0.5, 0.5),
				position + Vector3.new(0, 1.25, 0),
				Color3.fromRGB(229, 219, 185)
			)
		end
		world.registerNode(shape, node.id, node.catalogId, 0, source.worldRevision)
	end
	-- Approach the nodes from z=8 for clear reach; the wall blocks the berry lane.
	part("GatherLOSWall", Vector3.new(6, 7, 1), Vector3.new(10, 3.5, 10), Color3.fromRGB(111, 112, 105))
	local roof = part("CameraTestRoof", Vector3.new(12, 1, 8), Vector3.new(-16, 9, 0), Color3.fromRGB(116, 77, 45))
	CollectionService:AddTag(roof, "ForgeCameraOccluder")
	return world
end
