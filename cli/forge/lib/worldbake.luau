--!strict
-- worldbake: renders `spec.world` into a place-ready model at build time.
--
-- The world has to exist in the place file, not only in a server script that
-- runs later: that is what makes `placeParts` meaningful, what a shipped place
-- shows in Studio without running the server, and what the part budget gates.
-- The mapping itself lives in core/ui-kit/genre/WorldKit, which names no Roblox
-- global and takes its datatypes injected, so the same code renders the world
-- offline here and at runtime for a pack whose place was not baked.

-- `@lune/roblox` is typed without the datatype tables it actually exposes, so
-- the library is read through an `any` alias rather than narrowed to its
-- declared shape.
local roblox = require("@lune/roblox") :: any

local WorldKit = require("../../../core/ui-kit/genre/WorldKit")

local M = {}

M.DIRECTORY = "src/world"

local TYPES = {
	instance = function(class: string): any
		return roblox.Instance.new(class)
	end,
	vector3 = function(x: number, y: number, z: number): any
		return roblox.Vector3.new(x, y, z)
	end,
	color3 = function(r: number, g: number, b: number): any
		return roblox.Color3.fromRGB(r, g, b)
	end,
	-- Geometry is placed with a CFrame, never with `Position`/`Rotation`: Lune's
	-- serializer keeps a part's CFrame and silently drops a Position write, which
	-- is how every baked world once collapsed onto the origin.
	cframe = function(x: number, y: number, z: number, rx: number?, ry: number?, rz: number?): any
		return roblox.CFrame.new(x, y, z)
			* roblox.CFrame.Angles(math.rad(rx or 0), math.rad(ry or 0), math.rad(rz or 0))
	end,
	enum = roblox.Enum,
}

--- The pack-relative path of a pack's baked world model.
function M.path(pascal: string): string
	-- Lune serializes the binary `.rbxm` form (it starts with `<roblox!`), so the
	-- file must carry that extension for rojo to read it.
	return string.format("%s/%sWorld.rbxm", M.DIRECTORY, pascal)
end

--- Renders the world model. Returns (bytes?, partCount, errors). A world that is
--- too sparse to play, has an empty zone, or leaves the spawn standing in the sky
--- is an error, not a warning: those are the world contract the sweep's world
--- column measures against the built place.
function M.render(spec: any, theme: any?): (any?, number, { string })
	local errors: { string } = {}
	local resolved = theme or WorldKit.DEFAULT_THEME
	local host = roblox.Instance.new("Folder")
	host.Name = "WorldHost"
	local world = WorldKit.build({ spec = spec, theme = resolved, parent = host, types = TYPES })
	local parts = WorldKit.countParts(world)
	local budget = if type(resolved.budget) == "table" then resolved.budget.worldPartsMax else nil
	if type(budget) == "number" and parts > budget then
		table.insert(errors, string.format("world exceeds its %d part budget with %d parts", budget, parts))
	end
	local minimum = WorldKit.minimumParts(spec)
	if parts < minimum then
		table.insert(
			errors,
			string.format("world carries %d parts, below the %d this spec's world needs to be playable", parts, minimum)
		)
	end
	if parts < 1 then
		table.insert(errors, "world declares no geometry")
	end
	for _, zone in spec.zones or {} do
		local zoneId = tostring(zone.id)
		local zoneMinimum = WorldKit.minimumZoneParts(spec, zoneId)
		local count = 0
		for _, descendant in world:GetDescendants() do
			if descendant:IsA("BasePart") and descendant:GetAttribute("ForgeZoneId") == zoneId then
				count += 1
			end
		end
		if count < zoneMinimum then
			table.insert(
				errors,
				string.format("zone %s carries %d parts, below its %d part floor", zoneId, count, zoneMinimum)
			)
		end
	end
	if not WorldKit.coversSpawn(spec) then
		table.insert(errors, "no floor part covers the spawn: a player would spawn above nothing")
	end
	-- The spawn clearance is a world contract too: a plan that still stands a block or
	-- a mast in the default camera's volume renders a first frame the player cannot see
	-- past, which no part floor and no environment check can catch.
	local occluders: { string } = {}
	for _, entry in WorldKit.clearanceViolations(spec) do
		table.insert(occluders, entry.name)
	end
	if #occluders > 0 then
		table.insert(errors, "the spawn view is occluded by " .. table.concat(occluders, ", "))
	end
	-- A node's approach corridor is the same contract for every interactive node: a
	-- decor prop or a landmark standing in it hides the node (and the character)
	-- from the camera that walks up to it, which no part floor and no clearance check
	-- can see. One live capture had a zone's own scatter plant a tree through the
	-- social-rp-fashion mirror, hiding its prompt behind the trunk.
	local inApproach: { string } = {}
	for _, entry in WorldKit.approachViolations(spec) do
		table.insert(inApproach, string.format("%s (%s at node %s)", entry.name, entry.role, entry.node))
	end
	if #inApproach > 0 then
		table.insert(errors, "a node approach corridor is blocked by " .. table.concat(inApproach, ", "))
	end
	if #errors > 0 then
		return nil, parts, errors
	end
	local ok, bytes = pcall(function(): any
		return roblox.serializeModel({ world })
	end)
	if not ok then
		return nil, parts, { "serializeModel: " .. tostring(bytes) }
	end
	return bytes, parts, {}
end

return M
