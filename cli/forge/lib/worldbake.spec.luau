--!strict
-- Specs for the offline world bake: geometry, determinism, the part budget and
-- the playability gates (ground under the spawn, a part floor per zone). No
-- Roblox Studio, no network, no sleeps.

local worldbake = require("./worldbake")
local WorldKit = require("../../../core/ui-kit/genre/WorldKit")

local function spec(): any
	return {
		name = "World",
		spawn = { zone = "hub", offset = { 0, 1, 0 } },
		zones = {
			-- Wide enough that the spawn clearance, the nodes and their approach
			-- corridors all fit: a cramped hub resolves its nodes into the corners,
			-- where the zone's own pillars then stand in the corridor.
			{ id = "hub", kind = "plaza", center = { 0, 0, 0 }, size = { 64, 1, 64 } },
			{ id = "red", kind = "base", center = { -40, 0, 0 }, size = { 20, 1, 20 }, team = "red" },
		},
		nodes = {
			-- The array is cast per element: Luau unifies a table literal's array
			-- elements, and a node with a control and one without differ.
			{
				id = "shop",
				zone = "hub",
				kind = "station",
				position = { 0, 1, 6 },
				control = "counter:increment",
			} :: any,
			{ id = "pad", zone = "hub", kind = "node", position = { 8, 1, 0 }, version = 1 } :: any,
		},
	}
end
local function theme(budget: number): any
	local resolved = table.clone(WorldKit.DEFAULT_THEME)
	resolved.budget = { worldPartsMax = budget }
	return resolved
end
return {
	["a baked world carries its zones, spawn and nodes"] = function()
		local bytes, parts, errors = worldbake.render(spec(), theme(5000))
		assert(bytes ~= nil and #errors == 0, table.concat(errors, "; "))
		-- Every planned part plus the SpawnLocation, and the plan is a world a player
		-- can stand in: floors, rims, landmarks, decor and node props per zone.
		assert(parts == #WorldKit.plan(spec()) + 1, "unexpected part count " .. tostring(parts))
		assert(parts >= 40, "a two-zone world must be denser than a floor plate: " .. tostring(parts))
		assert(worldbake.path("Grow") == "src/world/GrowWorld.rbxm", "the baked model is a binary model file")
	end,

	["the plan puts ground under the spawn and geometry in every zone"] = function()
		local spawn = WorldKit.spawnPoint(spec())
		assert(spawn ~= nil and spawn[1] == 0 and spawn[2] == 1 and spawn[3] == 0, "spawn point")
		assert(WorldKit.coversSpawn(spec()), "the plan must cover the spawn")
		assert(WorldKit.minimumZoneParts(spec(), "red") >= 6, "a base zone carries more than its floor")
		assert(WorldKit.minimumParts(spec()) > 24, "a two-zone world has a real part floor")
	end,

	["a spawn with no floor under it is refused"] = function()
		local floating: any = {
			name = "World",
			spawn = { zone = "hub", offset = { 0, 1, 40 } },
			zones = { { id = "hub", kind = "plaza", center = { 0, 0, 0 }, size = { 40, 1, 40 } } },
			nodes = {},
		}
		local bytes, _, errors = worldbake.render(floating, theme(5000))
		assert(bytes == nil, "a spawn over nothing must not bake")
		local found = false
		for _, err in errors do
			if string.find(err, "covers the spawn", 1, true) ~= nil then
				found = true
			end
		end
		assert(found, table.concat(errors, "; "))
	end,

	["a baked world is byte deterministic"] = function()
		local first = worldbake.render(spec(), theme(5000))
		local second = worldbake.render(spec(), theme(5000))
		assert(first == second, "identical specs must render identical bytes")
	end,

	["a world over its part budget is refused"] = function()
		local bytes, parts, errors = worldbake.render(spec(), theme(2))
		assert(bytes == nil and parts >= 40, "the budget must gate the bake")
		assert(string.find(errors[1], "budget", 1, true) ~= nil, table.concat(errors, "; "))
	end,

	["an empty world is refused"] = function()
		local empty: any = { name = "World", zones = {}, nodes = {} }
		local bytes, parts, errors = worldbake.render(empty, theme(5000))
		assert(bytes == nil and parts == 0, "an empty world must not bake")
		local found = false
		for _, err in errors do
			if string.find(err, "geometry", 1, true) ~= nil then
				found = true
			end
		end
		assert(found, table.concat(errors, "; "))
	end,

	["the spawn pad carries bollards, not posts in the camera line"] = function()
		-- The 7-stud posts that once framed the pad stood in the default camera's own
		-- line and filled the first frame of every capture. Every spawn-owned part is
		-- now low enough that the clearance gate tolerates it.
		local posts = 0
		for _, part in WorldKit.plan(spec()) do
			if part.role == "spawn" and string.match(part.name, "^SpawnPost") ~= nil then
				posts += 1
				assert(part.size[2] <= WorldKit.SPAWN_LOW_MAX, "a spawn marker stands in the camera line")
			end
		end
		assert(posts == 4, "the pad keeps its four corner markers")
	end,

	["the spawn faces the play area"] = function()
		-- The hub spawn's only other zone is `red`, 40 studs along -X, so the spawn
		-- faces -X: the camera starts behind the character looking at the world.
		local facing = WorldKit.spawnFacing(spec())
		assert(math.abs(facing[1] + 1) < 1e-9 and math.abs(facing[2]) < 1e-9, "spawn faces the play area")
	end,

	["a node declared inside the spawn clearance is moved out of it"] = function()
		local raw = spec()
		raw.nodes = {
			{ id = "desk", zone = "hub", kind = "station", position = { 0, 1, 5 } } :: any,
		}
		local moved = nil
		for _, part in WorldKit.plan(raw) do
			if part.name == "Node-desk" then
				moved = part
			end
		end
		assert(moved ~= nil, "the node keeps its parts")
		assert(moved.position[3] > 12 or math.abs(moved.position[1]) > 12, "the node left the clearance volume")
		assert(#WorldKit.clearanceViolations(raw) == 0, "the plan keeps the spawn view clear")
	end,

	["a spawn zone whose rim stands in the clearance is refused"] = function()
		-- A 20x20 spawn zone puts its rim wall 10 studs from the spawn, inside the
		-- volume the camera occupies. The gate refuses the bake instead of shipping a
		-- first frame the player cannot see past.
		local cramped: any = {
			name = "World",
			spawn = { zone = "hub", offset = { 0, 1, 0 } },
			zones = { { id = "hub", kind = "plaza", center = { 0, 0, 0 }, size = { 20, 1, 20 } } },
			nodes = {},
		}
		local bytes, _, errors = worldbake.render(cramped, theme(5000))
		assert(bytes == nil, "an occluded spawn view must not bake")
		local found = false
		for _, err in errors do
			if string.find(err, "occluded", 1, true) ~= nil then
				found = true
			end
		end
		assert(found, table.concat(errors, "; "))
	end,

	["the baked environment colours are 0..1 for the project file"] = function()
		-- Rojo writes a project file's `Color3` components straight into the
		-- instance, and a component above 1 clamps to white. A 0..255 triple passed
		-- through unchanged therefore bakes `Ambient` to pure white and washes the
		-- whole place out - which is exactly what happened once. The conversion is
		-- asserted here so the two encodings cannot silently meet again.
		local converted = WorldKit.rojoColor3({ r = 90, g = 96, b = 108 })
		for index, value in converted do
			assert(value >= 0 and value <= 1, "component " .. tostring(index) .. " is outside 0..1")
		end
		assert(math.abs(converted[1] - 90 / 255) < 1e-9, "the red channel is value/255")
		assert(converted[1] < 1, "an ambient channel must not clamp to white")
		local environment = WorldKit.ENVIRONMENT
		for _, colour in
			{
				environment.ambient,
				environment.outdoorAmbient,
				environment.atmosphere.color,
				environment.atmosphere.decay,
			}
		do
			for _, value in WorldKit.rojoColor3(colour) do
				assert(value >= 0 and value <= 1, "an environment colour component left 0..1")
			end
		end
		assert(
			WorldKit.rojoColor3(environment.atmosphere.color)[3] < 1,
			"the baked atmosphere colour must not be pure white"
		)
	end,
}
