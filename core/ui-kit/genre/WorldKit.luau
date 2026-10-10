--!strict
-- WorldKit: the parametric world the declarative spec declares.
--
-- One mapping, three readers:
--
--   * `plan` turns `spec.world` into pure data — every part the world is made
--     of, with its size, CFrame position/rotation and role. No Roblox global is
--     named anywhere in this module, so the same plan renders the world offline
--     (the CLI bakes it into the place, which is what makes the built place
--     carry real parts) and at runtime (a pack whose place was not baked still
--     gets its world).
--   * `build` instantiates that plan, so the baked world and the runtime world
--     can never drift apart.
--   * `minimumParts` and the plan's own zone/role tallies are what `forge
--     sweep`'s world column measures against the built place: a world that is
--     too sparse, has no ground under the spawn, or has an empty zone is a
--     failure rather than a matter of taste.
--
-- Geometry is set with `CFrame`, never with `Position`/`Rotation`: Lune's
-- Roblox library serializes a part's CFrame and silently drops a Position write,
-- which is exactly how every baked world once collapsed onto the origin.
--
-- Instance identity is what gameplay reads back: every zone, spawn and node is
-- named and attributed, and a node that declares a control carries the
-- ProximityPrompt the server binder wires. `countParts` and the theme's part
-- budget are what the sweep's world column measures.

local HudText = require("./HudText")

local M = {}

--- A readable object name for a node id (`fallen-tree` -> `Fallen tree`). The prompt's object text
--- is what a player reads, so it is a name rather than the raw id the spec keys the node by.
local function humanize(id: any): string
	local text = string.gsub(tostring(id), "[-_]", " ")
	if #text == 0 then
		return text
	end
	return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

-- Default theme for a fresh pack: a bright, low-poly daylight look with the
-- shared part budget.
M.DEFAULT_THEME = {
	ground = { r = 104, g = 158, b = 92 },
	base = { r = 96, g = 108, b = 140 },
	arena = { r = 132, g = 118, b = 96 },
	accent = { r = 220, g = 196, b = 120 },
	rock = { r = 132, g = 132, b = 128 },
	foliage = { r = 66, g = 124, b = 72 },
	trunk = { r = 122, g = 90, b = 60 },
	team = {
		red = { r = 196, g = 84, b = 84 },
		blue = { r = 84, g = 120, b = 196 },
		traders = { r = 200, g = 168, b = 88 },
		house = { r = 168, g = 132, b = 196 },
	},
	material = "Grass",
	floorMaterial = "Slate",
	arenaMaterial = "Cobblestone",
	budget = { worldPartsMax = 5000 },
}

-- The environment every generated place carries, so a fresh pack is not a bare
-- grey void. `genreproject` bakes these into the place's project file and
-- `applyEnvironment` sets them at runtime for a pack whose place was not baked;
-- one table, so the two can never disagree.
M.ENVIRONMENT = {
	clockTime = 14.5,
	geographicLatitude = 41.7,
	brightness = 2.4,
	exposureCompensation = 0.2,
	environmentDiffuseScale = 0.35,
	environmentSpecularScale = 0.35,
	ambient = { r = 90, g = 96, b = 108 },
	outdoorAmbient = { r = 128, g = 136, b = 148 },
	atmosphere = {
		density = 0.32,
		offset = 0.1,
		color = { r = 199, g = 215, b = 235 },
		decay = { r = 96, g = 118, b = 150 },
		glare = 0.2,
		haze = 1.2,
	},
	sky = {
		-- Roblox Sky property names, so the same table serves the Rojo bake and the
		-- runtime assignment.
		SkyboxBk = "rbxasset://textures/sky/sky512_bk.tex",
		SkyboxDn = "rbxasset://textures/sky/sky512_dn.tex",
		SkyboxFt = "rbxasset://textures/sky/sky512_ft.tex",
		SkyboxLf = "rbxasset://textures/sky/sky512_lf.tex",
		SkyboxRt = "rbxasset://textures/sky/sky512_rt.tex",
		SkyboxUp = "rbxasset://textures/sky/sky512_up.tex",
	},
}

--- Converts a 0..255 `{ r, g, b }` environment colour into the 0..1 component
--- triple a Rojo project file's `Color3` property expects. This is the one
--- place the two encodings meet, and getting it wrong is catastrophic rather
--- than cosmetic: Rojo writes the three numbers straight into a `Color3` whose
--- components are clamped to 0..1, so a 0..255 triple becomes pure white (an
--- ambient of `(90, 96, 108)` renders as `(1, 1, 1)`). That is exactly how a
--- baked `Ambient`/`OutdoorAmbient`/`Atmosphere` once washed every generated
--- place into a flat white screen while the runtime `Color3.fromRGB` path - which
--- does take 0..255 - stayed correct.
function M.rojoColor3(color: any): { number }
	local function axis(value: any): number
		return math.clamp((tonumber(value) or 0) / 255, 0, 1)
	end
	return { axis(color.r), axis(color.g), axis(color.b) }
end

-- Structure constants, in studs. Named so the plan and the gates agree.
M.RIM_HEIGHT = 3
M.RIM_THICKNESS = 1.5
M.PILLAR_HEIGHT = 9
-- The beacon stands off the zone centre: the spec's spawn offset is usually the centre
-- itself, and a mast through the spawn pad would spawn every player inside a pillar.
M.BEACON_OFFSET_FRACTION = 0.45
M.BEACON_OFFSET_MIN = 8
M.BEACON_CLEARANCE = 8
M.RING_SEGMENTS = 16
M.SPAWN_PAD_SIZE = 10
-- The tallest a part may stand inside the spawn clearance and still be read as
-- ground rather than an occluder: anything whose top surface is at or below this
-- many studs above the pad is a floor, a step or a marker. The pad, its neon mark
-- and its bollards all qualify; so does a floor a genre's own world builder
-- placed, whether or not it carries the kit's role attribute.
M.SPAWN_LOW_MAX = 1
-- The spawn's corner markers are bollards, not the 7-stud posts that once framed
-- the pad: those posts stood in the default camera's own line and filled the
-- first frame of every capture.
M.SPAWN_POST_HEIGHT = 0.8
-- The horizontal axis a spawn faces when its zone offers no other play area.
M.SPAWN_FACING_FALLBACK = { 0, -1 }
-- The volume the default third-person camera and the character occupy at spawn,
-- in studs. Anything solid inside it is drawn across the first frame a player
-- ever sees: a live capture had a tan station block and two spawn posts covering
-- a third of the pvp-arena, grow-harvest and social-rp-fashion spawn views.
--
--   * `radius`/`height` — the cylinder around the spawn pad that stays clear.
--   * `backDepth`/`backWidth`/`backLow`/`backHigh` — the camera corridor behind
--     the spawn, along the axis the spawn faces away from. Its floor sits above
--     a zone rim wall (3 studs), so a rim at a small zone's edge is not a
--     violation while a 3.5-stud station block is.
--
-- One definition, three readers: `plan` keeps geometry out of it, `worldbake`
-- refuses a plan that still intersects it, and `forge sweep` measures the built
-- place against the same numbers.
M.SPAWN_CLEARANCE = {
	radius = 12,
	height = 12,
	backDepth = 20,
	backWidth = 12,
	-- Above a 3-stud zone rim wall, which stands on the ground at the zone edge:
	-- the boundary of the play space is not an occluder, a station block behind the
	-- spawn is.
	backLow = 4,
	backHigh = 12,
}
-- The volume a player and the third-person camera behind them occupy while they
-- walk up to an interactive node. The node's own prop is what they walk to, so it
-- belongs there; anything else solid in the volume stands between the camera and
-- the node - and hides the character, the prompt and the reaction the capture
-- exists to show. One live capture had a zone's own scatter plant a tree through
-- the social-rp-fashion mirror, which hid the prompt behind its trunk.
--
--   * `radius` — the cylinder around the node that stays clear of decor.
--   * `depth`/`width` — the corridor from the node back toward the spawn: the side
--     the player approaches from and the camera sits on.
--   * `low`/`high` — the height band above the node's own level: ground-level
--     markers (a pad, a bollard, a flower) are not occluders; a tree trunk, a rock
--     or a beacon mast is.
--
-- One definition, three readers: `plan` keeps decor out of it, `worldbake` refuses
-- a plan that still intersects it, and `forge sweep` measures the built place
-- against the same volumes.
M.NODE_APPROACH = {
	radius = 6,
	depth = 20,
	width = 14,
	low = 1,
	high = 12,
}
-- The roles the approach corridor never counts as occluders: the node's own prop,
-- the ground it stands on, the spawn furniture and the zone boundary are what a
-- player walks to or along, not decor standing in the camera's line.
M.APPROACH_OCCLUDER_ROLES = { decor = true, landmark = true }
M.MIN_DECOR = 8
M.MAX_DECOR = 56
-- Studs of zone area per decorative prop: a 60x60 zone gets 24, a 70x70 gets 32.
M.DECOR_AREA_PER_PART = 150
-- Parts per zone a built place must still carry, as a fraction of the plan. The
-- plan is deterministic, so a shortfall means the world did not bake.
M.PLAN_TOLERANCE = 0.85

export type Datatypes = {
	instance: (string) -> any,
	vector3: (number, number, number) -> any,
	color3: (number, number, number) -> any,
	cframe: (number, number, number, number?, number?, number?) -> any,
	enum: any,
}

export type BuildOptions = {
	spec: any,
	theme: any?,
	parent: any,
	types: Datatypes,
}

export type Part = {
	name: string,
	className: string?,
	role: string,
	zone: string?,
	node: string?,
	size: { number },
	position: { number },
	rotation: { number }?,
	color: any,
	material: string,
	shape: string?,
	transparency: number?,
	canCollide: boolean?,
	prompt: { control: string, action: string, object: string }?,
}

local function vec(types: Datatypes, point: any): any
	return types.vector3(tonumber(point[1]) or 0, tonumber(point[2]) or 0, tonumber(point[3]) or 0)
end

local function rgb(types: Datatypes, color: any): any
	return types.color3(tonumber(color.r) or 200, tonumber(color.g) or 200, tonumber(color.b) or 200)
end

local function scaleColor(color: any, factor: number): any
	local function axis(value: any): number
		return math.clamp((tonumber(value) or 200) * factor, 0, 255)
	end
	return { r = axis(color.r), g = axis(color.g), b = axis(color.b) }
end

--- Deterministic 32-bit FNV-1a: identical spec text always scatters identically,
--- so a rebuild is byte-identical and a diff of the place means a diff of the
--- spec.
local function hash(text: string): number
	local value = 2166136261
	for index = 1, #text do
		value = bit32.bxor(value, string.byte(text, index) :: number)
		value = (value * 16777619) % 4294967296
	end
	return value
end

local function unit(seed: string, index: number): number
	return (hash(seed .. ":" .. tostring(index)) % 10000) / 10000
end

local function zoneColor(types: Datatypes, zone: any, theme: any): any
	if zone.kind == "base" then
		local team = theme.team[zone.team]
		return rgb(types, team or theme.base)
	elseif zone.kind == "arena" then
		return rgb(types, theme.arena)
	end
	return rgb(types, theme.ground)
end

local function zoneArea(zone: any): number
	if type(zone.radius) == "number" then
		return math.pi * zone.radius * zone.radius
	end
	local size = zone.size
	return (tonumber(size[1]) or 0) * (tonumber(size[3]) or 0)
end

local function zoneExtent(zone: any): { number }
	if type(zone.radius) == "number" then
		return { zone.radius * 2, 0, zone.radius * 2 }
	end
	local size = zone.size
	return { tonumber(size[1]) or 0, tonumber(size[3]) or 0 }
end

local function add(parts: { Part }, part: Part): Part
	table.insert(parts, part)
	return part
end

--- The distance from the zone centre at which the zone's beacon stands: far enough
--- that its plinth clears the spawn pad the spec's offset usually places there, and
--- clamped so it stays inside a small zone.
function M.beaconOffset(zone: any): number
	local half = if type(zone.radius) == "number"
		then zone.radius
		else math.min(tonumber(zone.size[1]) or 0, tonumber(zone.size[3]) or 0) / 2
	return math.clamp(half * M.BEACON_OFFSET_FRACTION, M.BEACON_OFFSET_MIN, math.max(M.BEACON_OFFSET_MIN, half - 4))
end

--- The horizontal unit vector the spawn faces: from the spawn toward the play
--- area, which is the centroid of every other zone, or -Z when the spawn stands
--- at the centre of the only zone (nothing else to face).
function M.spawnFacing(spec: any): { number }
	local spawn = M.spawnPoint(spec)
	if spawn == nil then
		return { M.SPAWN_FACING_FALLBACK[1], M.SPAWN_FACING_FALLBACK[2] }
	end
	local spawnZone = if type(spec) == "table" and type(spec.spawn) == "table" then spec.spawn.zone else nil
	local fx, fz, count = 0, 0, 0
	for _, zone in (if type(spec) == "table" and type(spec.zones) == "table" then spec.zones else {}) do
		if type(zone) == "table" and tostring(zone.id) ~= tostring(spawnZone) and type(zone.center) == "table" then
			fx += tonumber(zone.center[1]) or 0
			fz += tonumber(zone.center[3]) or 0
			count += 1
		end
	end
	local dx, dz = 0, 0
	if count > 0 then
		dx, dz = fx / count - spawn[1], fz / count - spawn[3]
	end
	local length = math.sqrt(dx * dx + dz * dz)
	if length < 1e-4 then
		return { M.SPAWN_FACING_FALLBACK[1], M.SPAWN_FACING_FALLBACK[2] }
	end
	return { dx / length, dz / length }
end

export type Clearance = {
	x: number,
	y: number,
	z: number,
	fx: number,
	fz: number,
	radius: number,
	height: number,
	backDepth: number,
	backWidth: number,
	backLow: number,
	backHigh: number,
}

--- The spawn clearance volume for a world spec, or nil when the spec places no
--- spawn. Pure data: `build`, the bake and the gates all measure the same volume.
function M.clearanceVolume(spec: any): Clearance?
	local spawn = M.spawnPoint(spec)
	if spawn == nil then
		return nil
	end
	local facing = M.spawnFacing(spec)
	local bounds = M.SPAWN_CLEARANCE
	return {
		x = spawn[1],
		y = spawn[2],
		z = spawn[3],
		fx = facing[1],
		fz = facing[2],
		radius = bounds.radius,
		height = bounds.height,
		backDepth = bounds.backDepth,
		backWidth = bounds.backWidth,
		backLow = bounds.backLow,
		backHigh = bounds.backHigh,
	}
end

--- True when a plan part (or a live part reduced to size/position/role) stands
--- inside the clearance volume. A floor never does; a low marker - the pad, its
--- mark, a bollard, or any small low prop - never does; everything else must
--- stay outside both the spawn cylinder and the camera corridor.
function M.partInClearance(part: any, volume: any): boolean
	if volume == nil or type(part) ~= "table" then
		return false
	end
	local size, position = part.size, part.position
	if type(size) ~= "table" or type(position) ~= "table" then
		return false
	end
	local role = part.role
	local height = tonumber(size[2]) or 0
	local halfX = (tonumber(size[1]) or 0) / 2
	local halfZ = (tonumber(size[3]) or 0) / 2
	local px, py, pz = tonumber(position[1]) or 0, tonumber(position[2]) or 0, tonumber(position[3]) or 0
	local bottom, top = py - height / 2, py + height / 2
	-- Ground is not an occluder: a floor part, or any part whose top surface is at
	-- or below a stud above the pad (the pad, its mark, its bollards, a step).
	if role == "floor" or top <= volume.y + M.SPAWN_LOW_MAX then
		return false
	end
	-- The footprint is an axis-aligned rectangle (rotation is ignored, which
	-- over-estimates a rotated prop and never misses one). The cylinder test uses the
	-- rectangle's closest point to the spawn axis, so a 60-stud zone rim wall is not
	-- mistaken for a 30-stud block standing on the spawn.
	local minX, maxX = px - halfX, px + halfX
	local minZ, maxZ = pz - halfZ, pz + halfZ
	local nearX = math.clamp(volume.x, minX, maxX)
	local nearZ = math.clamp(volume.z, minZ, maxZ)
	local dx, dz = nearX - volume.x, nearZ - volume.z
	if math.sqrt(dx * dx + dz * dz) < volume.radius then
		if top > volume.y - 1 and bottom < volume.y + volume.height then
			return true
		end
	end
	-- The camera corridor: the same rectangle projected into the spawn frame, where
	-- `along` runs behind the spawn and `lateral` across the camera's own axis.
	local alongMin, alongMax = math.huge, -math.huge
	local lateralMin, lateralMax = math.huge, -math.huge
	for _, corner in { { minX, minZ }, { maxX, minZ }, { minX, maxZ }, { maxX, maxZ } } do
		local ex, ez = corner[1] - volume.x, corner[2] - volume.z
		local along = ex * volume.fx + ez * volume.fz
		local lateral = ex * -volume.fz + ez * volume.fx
		alongMin, alongMax = math.min(alongMin, along), math.max(alongMax, along)
		lateralMin, lateralMax = math.min(lateralMin, lateral), math.max(lateralMax, lateral)
	end
	if
		alongMin < volume.backDepth
		and alongMax > 0
		and lateralMin < volume.backWidth / 2
		and lateralMax > -volume.backWidth / 2
	then
		if top > volume.y + volume.backLow and bottom < volume.y + volume.backHigh then
			return true
		end
	end
	return false
end

--- Every part of a spec's plan that stands inside the clearance volume, sorted
--- by name. Empty means the spawn view is open.
function M.clearanceViolations(spec: any): { { name: string, role: string } }
	local out: { { name: string, role: string } } = {}
	local volume = M.clearanceVolume(spec)
	if volume == nil then
		return out
	end
	for _, part in M.plan(spec) do
		if M.partInClearance(part, volume) then
			table.insert(out, { name = tostring(part.name), role = tostring(part.role) })
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

--- The approach volume of one node, or nil when the spec places no spawn to
--- derive the approach direction from. The corridor runs from the node toward the
--- spawn, which is the side a player walks in from and the camera sits on; the
--- reference level is the node's own zone floor, so the low/high band is measured
--- from the ground rather than from the node's prop.
function M.approachVolume(spec: any, node: any, floorY: number?): any?
	if type(node) ~= "table" or type(node.position) ~= "table" then
		return nil
	end
	local spawn = M.spawnPoint(spec)
	if spawn == nil then
		return nil
	end
	local nx, nz = tonumber(node.position[1]) or 0, tonumber(node.position[3]) or 0
	local dx, dz = spawn[1] - nx, spawn[3] - nz
	local length = math.sqrt(dx * dx + dz * dz)
	local fx, fz = 0, 0
	if length > 1e-4 then
		fx, fz = dx / length, dz / length
	end
	local bounds = M.NODE_APPROACH
	return {
		x = nx,
		y = if floorY ~= nil then floorY else (tonumber(node.position[2]) or 0),
		z = nz,
		fx = fx,
		fz = fz,
		radius = bounds.radius,
		height = bounds.high,
		backDepth = bounds.depth,
		backWidth = bounds.width,
		backLow = bounds.low,
		backHigh = bounds.high,
	}
end

--- Every interactive node's approach volume, paired with the node id it belongs
--- to, in declaration order. A spec with no spawn and a spec with no nodes both
--- yield an empty list.
function M.approachVolumes(spec: any): { { node: string, volume: any } }
	local out: { { node: string, volume: any } } = {}
	if type(spec) ~= "table" or type(spec.nodes) ~= "table" then
		return out
	end
	local zonesById: { [string]: any } = {}
	for _, zone in spec.zones or {} do
		zonesById[tostring(zone.id)] = zone
	end
	-- The resolved nodes, not the declared ones: the corridor must cover where the
	-- plan actually stands the node a player walks to.
	for _, node in M.resolvedNodes(spec) do
		if type(node) == "table" and type(node.position) == "table" then
			-- The node's zone floor, not the node's own y: a node prop stands on the
			-- floor, and the corridor's height band is measured from that floor.
			local zone = if node.zone ~= nil then zonesById[tostring(node.zone)] else nil
			local floorY = if type(zone) == "table" and type(zone.center) == "table"
				then tonumber(zone.center[2]) or 0
				else (tonumber(node.position[2]) or 0) - 1
			local volume = M.approachVolume(spec, node, floorY)
			if volume ~= nil then
				table.insert(out, { node = tostring(node.id), volume = volume })
			end
		end
	end
	return out
end

--- True when a part stands in a node's approach volume. Only decorative and
--- landmark roles count: the node's own prop, the floor, the spawn furniture and
--- the zone boundary are what a player walks to or along.
function M.partInApproach(part: any, volume: any): boolean
	if volume == nil or type(part) ~= "table" then
		return false
	end
	if not M.APPROACH_OCCLUDER_ROLES[tostring(part.role)] then
		return false
	end
	return M.partInClearance(part, volume)
end

--- Every planned part that stands in some node's approach volume, sorted by name.
--- Empty means every interactive node is approached over open ground.
function M.approachViolations(spec: any): { { name: string, role: string, node: string } }
	local out: { { name: string, role: string, node: string } } = {}
	local volumes = M.approachVolumes(spec)
	if #volumes == 0 then
		return out
	end
	for _, part in M.plan(spec) do
		for _, entry in volumes do
			if M.partInApproach(part, entry.volume) then
				table.insert(out, {
					name = tostring(part.name),
					role = tostring(part.role),
					node = entry.node,
				})
				break
			end
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

--- The smallest displacement that moves a footprint of `half` by `height` out of
--- the clearance volume, searched over 16 rays in half-stud steps and bounded by
--- the zone's own floor so a pushed prop still stands on ground. Deterministic:
--- the same spec always resolves to the same position, so a rebuild is
--- byte-identical.
function M.clearanceResolve(x: number, z: number, half: number, height: number, volume: any, bounds: any): { number }
	local function clearAt(cx: number, cz: number): boolean
		if bounds ~= nil then
			if math.abs(cx - bounds.x) > bounds.halfX or math.abs(cz - bounds.z) > bounds.halfZ then
				return false
			end
			-- A zone's own beacon is not free ground: a node resolved onto it stands its
			-- prop through the beacon's mast.
			for _, point in bounds.avoid or {} do
				if math.abs(cx - point.x) <= point.half + half and math.abs(cz - point.z) <= point.half + half then
					return false
				end
			end
		end
		return not M.partInClearance({
			size = { half * 2, height, half * 2 },
			position = { cx, volume.y + height / 2, cz },
			role = "prop",
		}, volume)
	end
	if clearAt(x, z) then
		return { x, z }
	end
	local best, bestDistance = { x, z }, math.huge
	for ray = 0, 15 do
		local angle = ray * (math.pi * 2 / 16)
		local ux, uz = math.cos(angle), math.sin(angle)
		for step = 1, 120 do
			local distance = step * 0.5
			if distance >= bestDistance then
				break
			end
			local cx, cz = x + ux * distance, z + uz * distance
			if clearAt(cx, cz) then
				if distance < bestDistance then
					best, bestDistance = { cx, cz }, distance
				end
				break
			end
		end
	end
	return best
end

--- The zone a spec places its spawn in, as the { center, halfX, halfZ } a
--- resolved prop must stay inside, plus the beacon footprint a resolved node must
--- not land on: a node resolved onto the beacon once stood a mast through the
--- node's prop.
local function zoneBounds(spec: any, zoneId: any): any
	for _, zone in (if type(spec) == "table" and type(spec.zones) == "table" then spec.zones else {}) do
		if type(zone) == "table" and tostring(zone.id) == tostring(zoneId) then
			local extent = zoneExtent(zone)
			local center = if type(zone.center) == "table" then zone.center else {}
			local spawnZoneId = if type(spec.spawn) == "table" then spec.spawn.zone else nil
			local avoid: { { x: number, z: number, half: number } } = {}
			-- The beacon, not the corner pillars: a node resolved out of the spawn
			-- clearance escaped along the zone diagonal and stood its prop through the
			-- beacon mast. The pillars stand where the resolve's own zone bounds
			-- already keep a node's centre out of the way.
			local beacon = M.beaconPoint(zone, spawnZoneId)
			table.insert(avoid, {
				x = (tonumber(center[1]) or 0) + beacon.x,
				z = (tonumber(center[3]) or 0) + beacon.z,
				half = M.BEACON_CLEARANCE / 2,
			})
			return {
				x = tonumber(center[1]) or 0,
				z = tonumber(center[3]) or 0,
				halfX = extent[1] / 2 - 4,
				halfZ = extent[2] / 2 - 4,
				avoid = avoid,
			}
		end
	end
	return nil
end

--- The node the plan actually places: a node declared inside the spawn clearance is
--- moved to the nearest place that keeps the spawn view open and still stands on its
--- own zone's floor. The node keeps its id, kind and control, so prompts and QA
--- targets are unchanged. One definition, so the plan, the bake and the corridor
--- gate all read the same position.
local function resolveNode(spec: any, node: any, volume: any): any
	local position = node.position
	local nx, nz = tonumber(position[1]) or 0, tonumber(position[3]) or 0
	if volume ~= nil then
		-- The resolve box covers the widest node prop (a depot's roof is 9 studs
		-- across and its board reaches 6.4 studs up), so a resolved node is clear
		-- for its whole footprint, not only for its centre.
		local resolvedPoint = M.clearanceResolve(nx, nz, 5, 8, volume, zoneBounds(spec, node.zone))
		nx, nz = resolvedPoint[1], resolvedPoint[2]
	end
	local placed = table.clone(node)
	placed.position = { nx, tonumber(position[2]) or 0, nz }
	return placed
end

--- Every declared node at the position the plan places it, in declaration order. A
--- gate that measured the declared position instead would report a corridor the plan
--- never builds - and miss the one it does.
function M.resolvedNodes(spec: any): { any }
	local out: { any } = {}
	if type(spec) ~= "table" or type(spec.nodes) ~= "table" then
		return out
	end
	local volume = M.clearanceVolume(spec)
	for _, node in spec.nodes do
		if type(node) == "table" and type(node.position) == "table" then
			table.insert(out, resolveNode(spec, node, volume))
		end
	end
	return out
end

--- A flat floor slab or disc for one zone, plus its rim.
local function zoneFloor(types: Datatypes, theme: any, zone: any, parts: { Part }): ()
	local center = vec(types, zone.center)
	local color = zoneColor(types, zone, theme)
	local floorMaterial = if zone.kind == "arena" then theme.arenaMaterial else theme.floorMaterial
	if type(zone.radius) == "number" then
		-- A Part cylinder's length runs along its local X axis, so the disc is thin
		-- along X and rotated upright: a flat arena floor of the zone's radius.
		add(parts, {
			name = tostring(zone.id),
			role = "floor",
			zone = tostring(zone.id),
			size = { 1, zone.radius * 2, zone.radius * 2 },
			position = { center.X, center.Y, center.Z },
			rotation = { 0, 0, 90 },
			color = color,
			material = floorMaterial,
			shape = "Cylinder",
		})
		-- The ring wall marks the arena edge: without it an arena reads as an
		-- endless plain rather than a bounded place.
		for index = 1, M.RING_SEGMENTS do
			local angle = (index - 1) / M.RING_SEGMENTS * math.pi * 2
			local tangent = zone.radius * 2 * math.pi / M.RING_SEGMENTS
			add(parts, {
				name = string.format("%sRim%d", zone.id, index),
				role = "rim",
				zone = tostring(zone.id),
				size = { tangent * 1.05, M.RIM_HEIGHT, M.RIM_THICKNESS },
				position = {
					center.X + math.cos(angle) * zone.radius,
					center.Y + M.RIM_HEIGHT / 2,
					center.Z + math.sin(angle) * zone.radius,
				},
				rotation = { 0, math.deg(angle) + 90, 0 },
				color = scaleColor(theme.arena, 0.72),
				material = "Slate",
			})
		end
		return
	end
	local size = zone.size
	add(parts, {
		name = tostring(zone.id),
		role = "floor",
		zone = tostring(zone.id),
		size = { size[1], size[2], size[3] },
		position = { center.X, center.Y, center.Z },
		color = color,
		material = floorMaterial,
	})
	-- Four rim walls: the zone boundary a player can see and walk into.
	local halfX, halfZ = size[1] / 2, size[3] / 2
	local rimColor = scaleColor(color, 0.72)
	local walls = {
		{ name = "North", size = { size[1], M.RIM_HEIGHT, M.RIM_THICKNESS }, at = { 0, -halfZ } },
		{ name = "South", size = { size[1], M.RIM_HEIGHT, M.RIM_THICKNESS }, at = { 0, halfZ } },
		{ name = "West", size = { M.RIM_THICKNESS, M.RIM_HEIGHT, size[3] }, at = { -halfX, 0 } },
		{ name = "East", size = { M.RIM_THICKNESS, M.RIM_HEIGHT, size[3] }, at = { halfX, 0 } },
	}
	for _, wall in walls do
		add(parts, {
			name = zone.id .. "Rim" .. wall.name,
			role = "rim",
			zone = tostring(zone.id),
			size = wall.size,
			position = {
				center.X + wall.at[1],
				center.Y + M.RIM_HEIGHT / 2,
				center.Z + wall.at[2],
			},
			color = rimColor,
			material = "Slate",
		})
	end
end

--- The zone-local points of a zone's four landmark pillars, in the order
--- `zoneLandmarks` names them. One definition, so the landmark props and the node
--- resolve's avoidance agree on where a zone's pillars stand.
function M.pillarPoints(zone: any): { { x: number, z: number } }
	local extent = zoneExtent(zone)
	local points: { { x: number, z: number } } = {}
	if type(zone.radius) == "number" then
		for index = 1, 4 do
			local angle = (index - 1) / 4 * math.pi * 2 + math.pi / 4
			table.insert(points, {
				x = math.cos(angle) * (zone.radius - 3),
				z = math.sin(angle) * (zone.radius - 3),
			})
		end
		return points
	end
	local halfX, halfZ = extent[1] / 2 - 2, extent[2] / 2 - 2
	return { { x = -halfX, z = -halfZ }, { x = halfX, z = -halfZ }, { x = -halfX, z = halfZ }, { x = halfX, z = halfZ } }
end

--- The zone-local point of a zone's beacon, standing off the centre so it never
--- occupies the spawn pad (see M.beaconOffset), and outside the spawn clearance when
--- this is the spawn's own zone: a mast through the camera line fills the first
--- frame just as surely as a wall does. The landmark props and the node resolve's
--- avoidance both read it, so a node can never resolve onto the beacon.
function M.beaconPoint(zone: any, spawnZoneId: any): { x: number, z: number }
	local offset = M.beaconOffset(zone)
	if spawnZoneId ~= nil and tostring(zone.id) == tostring(spawnZoneId) then
		local zoneSize = zoneExtent(zone)
		local half = math.min(zoneSize[1], zoneSize[2]) / 2
		offset = math.max(offset, M.SPAWN_CLEARANCE.radius + 2)
		offset = math.min(offset, math.max(M.BEACON_OFFSET_MIN, half - 4))
	end
	return { x = offset, z = offset }
end

--- The zone's landmark set: four corner pillars and a centre beacon, so a zone
--- is legible from the spawn and from across the map.
local function zoneLandmarks(types: Datatypes, theme: any, zone: any, parts: { Part }, spawnZoneId: any): ()
	local center = vec(types, zone.center)
	local color = scaleColor(zoneColor(types, zone, theme), 1.12)
	local accent = rgb(types, theme.accent)
	for index, point in M.pillarPoints(zone) do
		add(parts, {
			name = string.format("%sPillar%d", zone.id, index),
			role = "landmark",
			zone = tostring(zone.id),
			size = { 2, M.PILLAR_HEIGHT, 2 },
			position = { center.X + point.x, center.Y + M.PILLAR_HEIGHT / 2, center.Z + point.z },
			color = color,
			material = "Concrete",
		})
	end
	-- Beacon: a plinth, a mast and a lit cap, standing off the centre so it never
	-- occupies the spawn pad (see M.beaconOffset), and outside the spawn clearance
	-- when this is the spawn's own zone: a mast through the camera line fills the
	-- first frame just as surely as a wall does.
	local beacon = M.beaconPoint(zone, spawnZoneId)
	local beaconX, beaconZ = center.X + beacon.x, center.Z + beacon.z
	add(parts, {
		name = zone.id .. "BeaconBase",
		role = "landmark",
		zone = tostring(zone.id),
		size = { 6, 1, 6 },
		position = { beaconX, center.Y + 0.5, beaconZ },
		color = color,
		material = "Concrete",
	})
	add(parts, {
		name = zone.id .. "BeaconMast",
		role = "landmark",
		zone = tostring(zone.id),
		size = { 1.5, 12, 1.5 },
		position = { beaconX, center.Y + 6.5, beaconZ },
		color = accent,
		material = "Metal",
	})
	add(parts, {
		name = zone.id .. "BeaconLight",
		role = "landmark",
		zone = tostring(zone.id),
		size = { 4, 4, 4 },
		position = { beaconX, center.Y + 14, beaconZ },
		color = accent,
		material = "Neon",
		shape = "Ball",
	})
end

--- Deterministic scatter of rocks and trees inside the zone, kept clear of the
--- nodes, the spawn and the beacon.
local function zoneDecor(
	types: Datatypes,
	theme: any,
	zone: any,
	parts: { Part },
	reserved: { any },
	volume: any,
	approach: { { node: string, volume: any } }
): ()
	local center = vec(types, zone.center)
	local area = zoneArea(zone)
	local count = math.clamp(math.floor(area / M.DECOR_AREA_PER_PART), M.MIN_DECOR, M.MAX_DECOR)
	local extent = zoneExtent(zone)
	local halfX, halfZ = extent[1] / 2 - 6, extent[2] / 2 - 6
	local function clear(x: number, z: number): boolean
		for _, point in reserved do
			local dx, dz = x - point[1], z - point[2]
			if dx * dx + dz * dz < point[3] * point[3] then
				return false
			end
		end
		return true
	end
	local placed = 0
	local attempt = 0
	while placed < count and attempt < count * 8 do
		attempt += 1
		local rx = unit(zone.id .. ":x", attempt)
		local rz = unit(zone.id .. ":z", attempt)
		local x, z
		if type(zone.radius) == "number" then
			local radius = math.sqrt(rx) * (zone.radius - 5)
			local angle = rz * math.pi * 2
			x, z = math.cos(angle) * radius, math.sin(angle) * radius
		else
			x, z = (rx * 2 - 1) * halfX, (rz * 2 - 1) * halfZ
		end
		if not clear(x, z) then
			continue
		end
		local roll = unit(zone.id .. ":kind", attempt)
		-- Both clearances are world-space volumes, so a candidate is tested at its
		-- world position: a zone whose centre is not the origin (an arena disc, a
		-- camp) would otherwise be measured against the wrong place.
		local worldX, worldZ = center.X + x, center.Z + z
		-- The spawn clearance is a volume, not a circle: a tree planted behind the
		-- spawn at the corridor's own width would still stand in the camera's line.
		-- The test uses this candidate's own footprint and height, so a low rock may
		-- stand nearer the spawn than a canopy may.
		local trunkHeight = 5 + unit(zone.id .. ":h", attempt) * 3
		local isTree = roll < 0.35
		local propHeight = if isTree then trunkHeight + 4.5 else 2.8
		local propHalf = if isTree then 3 else 2.25
		if
			volume ~= nil
			and M.partInClearance({
				size = { propHalf * 2, propHeight, propHalf * 2 },
				position = { worldX, volume.y + propHeight / 2, worldZ },
				role = "decor",
			}, volume)
		then
			continue
		end
		-- A node's approach corridor is the same kind of contract as the spawn's: a
		-- prop planted in it hides the node a player walked to (and, once, hid the
		-- node's prompt outright). Every zone's scatter answers to every node's
		-- corridor, not only the nodes of its own zone: an arena disc overlapping a
		-- plaza once planted a tree through a plaza node.
		local inApproach = false
		for _, entry in approach do
			local candidate = entry.volume
			local floorY = candidate.y
			if
				M.partInApproach({
					size = { propHalf * 2, propHeight, propHalf * 2 },
					position = { worldX, floorY + propHeight / 2, worldZ },
					role = "decor",
				}, candidate)
			then
				inApproach = true
				break
			end
			if isTree then
				-- A canopy overhangs its trunk, so the whole prop is tested, not only
				-- the footprint the trunk occupies.
				if
					M.partInApproach({
						size = { 6, 5, 6 },
						position = { worldX, floorY + trunkHeight + 2, worldZ },
						role = "decor",
					}, candidate)
				then
					inApproach = true
					break
				end
			end
		end
		if inApproach then
			continue
		end
		placed += 1
		if isTree then
			-- A tree: trunk plus canopy, so the zone has vertical silhouette.
			local height = trunkHeight
			add(parts, {
				name = string.format("%sTree%d", zone.id, placed),
				role = "decor",
				zone = tostring(zone.id),
				size = { 1.4, height, 1.4 },
				position = { center.X + x, center.Y + height / 2, center.Z + z },
				color = rgb(types, theme.trunk),
				material = "Wood",
			})
			add(parts, {
				name = string.format("%sTree%dCanopy", zone.id, placed),
				role = "decor",
				zone = tostring(zone.id),
				size = { 6, 5, 6 },
				position = { center.X + x, center.Y + height + 2, center.Z + z },
				color = rgb(types, theme.foliage),
				material = "Grass",
				shape = "Ball",
			})
		else
			local rock = 2 + unit(zone.id .. ":s", attempt) * 2.5
			add(parts, {
				name = string.format("%sRock%d", zone.id, placed),
				role = "decor",
				zone = tostring(zone.id),
				size = { rock, rock * 0.8, rock },
				position = { center.X + x, center.Y + rock * 0.4, center.Z + z },
				rotation = { 0, unit(zone.id .. ":r", attempt) * 360, 0 },
				color = rgb(types, theme.rock),
				material = "Rock",
			})
		end
	end
end

--- A node's prop, distinct per declared node kind, so every interactable is a
--- visible object rather than an invisible trigger volume.
local function nodeParts(types: Datatypes, theme: any, node: any, parts: { Part }): ()
	local at = vec(types, node.position)
	local function part(
		suffix: string,
		role: string,
		size: { number },
		position: { number },
		color: any,
		material: string,
		shape: string?,
		rotation: { number }?
	)
		return add(parts, {
			name = "Node-" .. tostring(node.id) .. suffix,
			role = role,
			zone = if type(node.zone) == "string" then node.zone else nil,
			node = tostring(node.id),
			size = size,
			position = position,
			rotation = rotation,
			color = color,
			material = material,
			shape = shape,
		})
	end
	local accent = rgb(types, theme.accent)
	if node.kind == "station" then
		part("", "node", { 6, 3.5, 4 }, { at.X, at.Y + 1.75, at.Z }, accent, "Wood")
		part("Sign", "node", { 0.6, 6, 0.6 }, { at.X + 2.6, at.Y + 3, at.Z }, rgb(types, theme.trunk), "Wood")
		part("Board", "node", { 4, 2, 0.4 }, { at.X + 2.6, at.Y + 5.4, at.Z }, accent, "SmoothPlastic")
	elseif node.kind == "incubator" then
		part("", "node", { 7, 1, 7 }, { at.X, at.Y + 0.5, at.Z }, accent, "Metal", "Cylinder", { 0, 0, 90 })
		part("Dome", "node", { 6, 5, 6 }, { at.X, at.Y + 3, at.Z }, accent, "SmoothPlastic", "Ball")
		part(
			"Ring",
			"node",
			{ 8, 0.5, 8 },
			{ at.X, at.Y + 0.25, at.Z },
			rgb(types, theme.rock),
			"Metal",
			"Cylinder",
			{ 0, 0, 90 }
		)
	elseif node.kind == "depot" then
		part("", "node", { 8, 3, 5 }, { at.X, at.Y + 1.5, at.Z }, rgb(types, theme.team.traders), "Wood")
		part("Roof", "node", { 9, 0.6, 6 }, { at.X, at.Y + 5.4, at.Z }, accent, "Wood")
		part("Post1", "node", { 0.6, 4, 0.6 }, { at.X - 3.6, at.Y + 3.6, at.Z - 2.2 }, rgb(types, theme.trunk), "Wood")
		part("Post2", "node", { 0.6, 4, 0.6 }, { at.X + 3.6, at.Y + 3.6, at.Z + 2.2 }, rgb(types, theme.trunk), "Wood")
	else
		-- A plain node: a low crate cluster a player reads as "harvest here".
		part("", "node", { 4, 3, 4 }, { at.X, at.Y + 1.5, at.Z }, rgb(types, theme.foliage), "Grass")
		part("Top", "node", { 2.6, 1.4, 2.6 }, { at.X, at.Y + 3.7, at.Z }, accent, "SmoothPlastic")
		part("Base", "node", { 5.4, 0.6, 5.4 }, { at.X, at.Y + 0.3, at.Z }, rgb(types, theme.rock), "Rock")
	end
end

--- The spawn layout: a pad, a lit marker and four posts, so the camera's first
--- frame shows a place to stand rather than an empty horizon.
local function spawnParts(types: Datatypes, theme: any, spec: any, zonesById: any, parts: { Part }): any
	local spawn: any = spec.spawn
	if type(spawn) ~= "table" then
		return nil
	end
	local zone = zonesById[spawn.zone]
	local center = if type(zone) == "table" then vec(types, zone.center) else types.vector3(0, 0, 0)
	local offset = vec(types, spawn.offset)
	local x, y, z = center.X + offset.X, center.Y + offset.Y, center.Z + offset.Z
	local pad = M.SPAWN_PAD_SIZE
	local accent = rgb(types, theme.accent)
	-- The pad's corner markers are bollards: a 7-stud post at each corner framed the
	-- pad and stood in the default camera's line, which is the occlusion this kit
	-- now keeps out of the spawn clearance.
	local post = M.SPAWN_POST_HEIGHT
	add(parts, {
		name = "SpawnPad",
		role = "spawn",
		zone = if type(spawn.zone) == "string" then spawn.zone else nil,
		size = { pad, 1, pad },
		position = { x, y - 0.5, z },
		color = scaleColor(theme.accent, 0.9),
		material = "Concrete",
	})
	for index = 1, 4 do
		local sx = if index % 2 == 1 then -1 else 1
		local sz = if index <= 2 then -1 else 1
		add(parts, {
			name = string.format("SpawnPost%d", index),
			role = "spawn",
			zone = if type(spawn.zone) == "string" then spawn.zone else nil,
			size = { 1, post, 1 },
			position = { x + sx * (pad / 2 - 0.5), y + post / 2 - 0.5, z + sz * (pad / 2 - 0.5) },
			color = accent,
			material = "Metal",
		})
	end
	add(parts, {
		name = "SpawnMark",
		role = "spawn",
		zone = if type(spawn.zone) == "string" then spawn.zone else nil,
		-- Wider than the SpawnLocation that sits on it, so the glowing square reads as a
		-- landing pad instead of being hidden under the spawn itself.
		size = { pad - 1, 0.2, pad - 1 },
		position = { x, y + 0.1, z },
		color = accent,
		material = "Neon",
	})
	return { x = x, y = y, z = z }
end

--- The complete part plan for a world spec: pure data, deterministic, and the
--- single source both `build` and the world gates read.
function M.plan(spec: any, theme: any?): { Part }
	local resolved = theme or M.DEFAULT_THEME
	local types: Datatypes = {
		instance = function(_class: string): any
			return nil
		end,
		vector3 = function(x: number, y: number, z: number): any
			return { X = x, Y = y, Z = z, __vector3 = true }
		end,
		color3 = function(r: number, g: number, b: number): any
			return { r = r, g = g, b = b }
		end,
		cframe = function(): any
			return nil
		end,
		enum = {},
	}
	local parts: { Part } = {}
	local volume = M.clearanceVolume(spec)
	local spawnZoneId = if type(spec.spawn) == "table" then spec.spawn.zone else nil
	local zonesById: { [string]: any } = {}
	for _, zone in spec.zones or {} do
		zonesById[zone.id] = zone
	end
	for _, zone in spec.zones or {} do
		zoneFloor(types, resolved, zone, parts)
		zoneLandmarks(types, resolved, zone, parts, spawnZoneId)
	end
	local reserved: { [string]: { any } } = {}
	local function reserve(zoneId: any, x: number, z: number, radius: number)
		local key = tostring(zoneId)
		reserved[key] = reserved[key] or {}
		table.insert(reserved[key], { x, z, radius })
	end
	local resolvedNodes = M.resolvedNodes(spec)
	for _, placed in resolvedNodes do
		local nx, nz = placed.position[1], placed.position[3]
		reserve(placed.zone, nx, nz, 12)
		nodeParts(types, resolved, placed, parts)
	end
	local spawnPoint = spawnParts(types, resolved, spec, zonesById, parts)
	if spawnPoint ~= nil then
		reserve(spec.spawn.zone, spawnPoint.x, spawnPoint.z, M.SPAWN_CLEARANCE.radius)
	end
	-- Every interactive node's approach corridor, derived from the node positions a
	-- player actually walks to (the resolved ones), so the scatter keeps the node's
	-- own approach clear in every zone.
	local approach = M.approachVolumes({ spawn = spec.spawn, zones = spec.zones, nodes = resolvedNodes })
	for _, zone in spec.zones or {} do
		local center = vec(types, zone.center)
		reserve(zone.id, center.X, center.Z, 10)
		-- The beacon stands off the centre; keep decor out of its footprint too.
		local beacon = M.beaconOffset(zone)
		reserve(zone.id, center.X + beacon, center.Z + beacon, M.BEACON_CLEARANCE)
		zoneDecor(types, resolved, zone, parts, reserved[tostring(zone.id)] or {}, volume, approach)
	end
	return parts
end

--- The part floor a built place must still carry for a spec: a fraction of the
--- plan, so a dropped decorative part is tolerated and an unbaked world is not.
function M.minimumParts(spec: any): number
	local planned = #M.plan(spec)
	return math.max(24, math.floor(planned * M.PLAN_TOLERANCE))
end

--- The part floor for one zone id.
function M.minimumZoneParts(spec: any, zoneId: string): number
	local count = 0
	for _, part in M.plan(spec) do
		if part.zone == zoneId then
			count += 1
		end
	end
	return math.max(6, math.floor(count * M.PLAN_TOLERANCE))
end

--- The spawn point the world places, in world coordinates.
function M.spawnPoint(spec: any): { number }?
	local zonesById: { [string]: any } = {}
	for _, zone in spec.zones or {} do
		zonesById[zone.id] = zone
	end
	local spawn = spec.spawn
	if type(spawn) ~= "table" then
		return nil
	end
	local zone = zonesById[spawn.zone]
	if type(zone) ~= "table" then
		return nil
	end
	local center, offset = zone.center, spawn.offset
	return {
		(tonumber(center[1]) or 0) + (tonumber(offset[1]) or 0),
		(tonumber(center[2]) or 0) + (tonumber(offset[2]) or 0),
		(tonumber(center[3]) or 0) + (tonumber(offset[3]) or 0),
	}
end

--- True when a floor part covers `spawn`: its horizontal footprint contains the
--- spawn and its top surface is at the spawn's own level, so a player stands on
--- ground rather than in the sky. `part` is either a plan entry or a live part
--- reduced to `{ size, position, rotation, role }`.
function M.coversGround(part: any, spawn: { number }): boolean
	if type(part) ~= "table" or type(spawn) ~= "table" then
		return false
	end
	if part.role ~= "floor" then
		return false
	end
	local size, position = part.size, part.position
	if type(size) ~= "table" or type(position) ~= "table" then
		return false
	end
	local halfX, halfZ = (tonumber(size[1]) or 0) / 2, (tonumber(size[3]) or 0) / 2
	-- A cylinder floor rotated 90 degrees about Z is a disc lying flat, so its
	-- footprint is the diameter in both horizontal axes.
	if type(part.rotation) == "table" and tonumber(part.rotation[3]) == 90 then
		halfX, halfZ = (tonumber(size[2]) or 0) / 2, (tonumber(size[2]) or 0) / 2
	end
	local dx, dz = spawn[1] - (tonumber(position[1]) or 0), spawn[3] - (tonumber(position[3]) or 0)
	if math.abs(dx) > halfX or math.abs(dz) > halfZ then
		return false
	end
	local top = (tonumber(position[2]) or 0) + (tonumber(size[2]) or 0) / 2
	return math.abs(top - spawn[2]) <= 3
end

--- True when the plan puts a floor part under the spawn point.
function M.coversSpawn(spec: any): boolean
	local spawn = M.spawnPoint(spec)
	if spawn == nil then
		return false
	end
	for _, part in M.plan(spec) do
		if M.coversGround(part, spawn) then
			return true
		end
	end
	return false
end

--- Counts every BasePart under `root`. The budget is a world contract, so the
--- same count is what the sweep's world column reports.
function M.countParts(root: any): number
	local count = 0
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

--- Applies the shared environment to a Lighting service. Takes the service as
--- an argument so this module still names no Roblox global: the generated world
--- server passes `game:GetService("Lighting")`, and the offline bake writes the
--- same numbers into the place's project file instead.
local function applyEnvironment(lighting: any, types: Datatypes): ()
	if lighting == nil then
		return
	end
	local environment = M.ENVIRONMENT
	lighting.ClockTime = environment.clockTime
	lighting.GeographicLatitude = environment.geographicLatitude
	lighting.Brightness = environment.brightness
	lighting.ExposureCompensation = environment.exposureCompensation
	lighting.EnvironmentDiffuseScale = environment.environmentDiffuseScale
	lighting.EnvironmentSpecularScale = environment.environmentSpecularScale
	lighting.Ambient = rgb(types, environment.ambient)
	lighting.OutdoorAmbient = rgb(types, environment.outdoorAmbient)
	if lighting:FindFirstChild("ForgeAtmosphere") == nil then
		local atmosphere = types.instance("Atmosphere")
		atmosphere.Name = "ForgeAtmosphere"
		atmosphere.Density, atmosphere.Offset = environment.atmosphere.density, environment.atmosphere.offset
		atmosphere.Color = rgb(types, environment.atmosphere.color)
		atmosphere.Decay = rgb(types, environment.atmosphere.decay)
		atmosphere.Glare, atmosphere.Haze = environment.atmosphere.glare, environment.atmosphere.haze
		atmosphere.Parent = lighting
	end
	if lighting:FindFirstChild("ForgeSky") == nil then
		local sky = types.instance("Sky")
		sky.Name = "ForgeSky"
		for key, value in environment.sky do
			sky[key] = value
		end
		sky.Parent = lighting
	end
end

M.applyEnvironment = applyEnvironment

--- Builds the world root (a Folder named `spec.name`, default "World") under
--- `options.parent`. Any previous root of the same name is removed first, so a
--- rebuild is idempotent.
function M.build(options: BuildOptions): any
	local spec: any = options.spec or {}
	local theme: any = options.theme or M.DEFAULT_THEME
	local types = options.types
	local host = options.parent
	local name = if type(spec.name) == "string" and #spec.name > 0 then spec.name else "World"
	local existing = host:FindFirstChild(name)
	if existing ~= nil then
		existing:Destroy()
	end
	local world = types.instance("Folder")
	world.Name = name

	-- The declared control labels, resolved through the pack's locale table, so a world prompt
	-- shows the same copy its HUD control does rather than the node's kind.
	local locale = if type(spec.locale) == "table" and type(spec.locale.default) == "string"
		then spec.locale.default
		else nil
	local strings: any = if type(spec.locale) == "table" then spec.locale.strings else nil
	local controlLabels: { [string]: string } = {}
	for _, row in (if type(spec.actions) == "table" then spec.actions else {}) do
		if type(row) == "table" and type(row.control) == "table" and type(row.control.id) == "string" then
			local label = HudText.localized(strings, locale, row.control.labelKey, tostring(row.control.label or ""))
			if #label > 0 then
				controlLabels[row.control.id] = label
			end
		end
	end

	local parts = M.plan(spec, theme)
	local nodesById: { [string]: any } = {}
	for _, node in spec.nodes or {} do
		nodesById[tostring(node.id)] = node
	end
	-- One prompt per node, on the node's own prop: a station is a base, a sign and a
	-- board, and a prompt on each of the three would put two unwired triggers in
	-- front of a player who walked up to the node they are bound to.
	local prompted: { [string]: boolean } = {}
	for _, plan in parts do
		local part = types.instance(plan.className or "Part")
		part.Name, part.Anchored = plan.name, true
		part.Size = types.vector3(plan.size[1], plan.size[2], plan.size[3])
		local rotation = plan.rotation
		part.CFrame = types.cframe(
			plan.position[1],
			plan.position[2],
			plan.position[3],
			if rotation ~= nil then rotation[1] else 0,
			if rotation ~= nil then rotation[2] else 0,
			if rotation ~= nil then rotation[3] else 0
		)
		part.Color = rgb(types, plan.color)
		part.Material = types.enum.Material[plan.material]
		if plan.shape ~= nil then
			part.Shape = types.enum.PartType[plan.shape]
		end
		if plan.transparency ~= nil then
			part.Transparency = plan.transparency
		end
		if plan.canCollide ~= nil then
			part.CanCollide = plan.canCollide
		end
		if part:IsA("BasePart") then
			part.TopSurface, part.BottomSurface = types.enum.SurfaceType.Smooth, types.enum.SurfaceType.Smooth
		end
		part:SetAttribute("ForgePartRole", plan.role)
		if plan.zone ~= nil then
			part:SetAttribute("ForgeZoneId", plan.zone)
			local zone = nil
			for _, candidate in spec.zones or {} do
				if tostring(candidate.id) == plan.zone then
					zone = candidate
				end
			end
			if type(zone) == "table" then
				part:SetAttribute("ForgeZoneKind", zone.kind)
				if type(zone.team) == "string" then
					part:SetAttribute("ForgeTeam", zone.team)
				end
			end
		end
		if plan.node ~= nil then
			local node = nodesById[plan.node]
			part:SetAttribute("ForgeNodeId", plan.node)
			part:SetAttribute("ForgeNodeKind", if type(node) == "table" then node.kind else nil)
			part:SetAttribute(
				"ForgeNodeVersion",
				if type(node) == "table" and type(node.version) == "number" then node.version else nil
			)
		end
		part.Parent = world
		if plan.node ~= nil then
			local node = nodesById[plan.node]
			if type(node) == "table" and node.control ~= nil and plan.role == "node" and not prompted[plan.node] then
				prompted[plan.node] = true
				-- The prompt carries the control id as its Name: the client dispatches
				-- a prompt control by matching `prompt.Name` against the declared control.
				local prompt = types.instance("ProximityPrompt")
				prompt.Name = node.control
				-- The two lines a player reads are declared copy, not identifiers: the action is the
				-- control's own label resolved through the pack's locale table, and the object is the
				-- node's id as a name.
				prompt.ActionText = controlLabels[node.control] or humanize(node.kind)
				prompt.ObjectText = humanize(node.id)
				prompt.KeyboardKeyCode = types.enum.KeyCode.E
				-- The engine's relevance test is a line-of-sight ray from the camera, and a station is
				-- built from several solid parts: a player standing at the node had its own prop between
				-- the camera and the prompt, so the prompt was never shown and E activated nothing. The
				-- proximity radius is the reach rule instead - which is also what the collect-raid
				-- scaffold's incubators do - and one prompt per key keeps a neighbour from stealing the
				-- press while the closest node still wins.
				prompt.RequiresLineOfSight = false
				prompt.MaxActivationDistance = 12
				prompt.Exclusivity = types.enum.ProximityPromptExclusivity.OnePerButton
				prompt.Parent = part
			end
		end
	end

	local spawn: any = spec.spawn
	if type(spawn) == "table" then
		local point = M.spawnPoint(spec)
		local facing = M.spawnFacing(spec)
		-- The spawn faces the play area, so the default third-person camera starts
		-- behind the character looking at the world rather than at a wall.
		local yaw = math.deg(math.atan2(-facing[1], -facing[2]))
		local pad = types.instance("SpawnLocation")
		pad.Name, pad.Anchored = "Spawn", true
		pad.Size = types.vector3(6, 1, 6)
		pad.CFrame = types.cframe(
			if point ~= nil then point[1] else 0,
			if point ~= nil then point[2] else 1,
			if point ~= nil then point[3] else 0,
			0,
			yaw,
			0
		)
		pad:SetAttribute("ForgePartRole", "spawn")
		pad:SetAttribute("ForgeZoneId", spawn.zone)
		pad.Parent = world
	end

	world.Parent = host
	local count = M.countParts(world)
	local budget = if type(theme.budget) == "table" then theme.budget.worldPartsMax else nil
	world:SetAttribute("ForgeWorldParts", count)
	if type(budget) == "number" and count > budget then
		world:SetAttribute("ForgeWorldOverBudget", true)
	end
	return world
end

--- The world root a pack already carries, or nil.
function M.find(spec: any, parent: any): any
	local name = if type(spec) == "table" and type(spec.name) == "string" and #spec.name > 0 then spec.name else "World"
	return parent:FindFirstChild(name)
end

--- A node instance by id, wherever the world came from.
function M.node(spec: any, nodeId: string, parent: any): any
	local world = M.find(spec, parent)
	if world == nil then
		return nil
	end
	return world:FindFirstChild("Node-" .. nodeId)
end

export type StartOptions = {
	spec: any,
	theme: any?,
	parent: any,
	types: Datatypes,
	onPrompt: ((player: any, control: string, args: { any }) -> ())?,
}

--- Runtime entry: uses the world the place already carries, builds one when it
--- does not, then wires every node's prompt to `onPrompt`.
function M.start(options: StartOptions): any
	local spec: any = options.spec or {}
	local world = M.find(spec, options.parent)
	if world == nil then
		world = M.build({ spec = spec, theme = options.theme, parent = options.parent, types = options.types })
	end
	local connections: { any } = {}
	local wired = 0
	for _, node in spec.nodes or {} do
		if node.control == nil then
			continue
		end
		local part = world:FindFirstChild("Node-" .. node.id)
		local prompt = if part ~= nil then part:FindFirstChild(node.control) else nil
		if prompt ~= nil and options.onPrompt ~= nil then
			wired += 1
			table.insert(
				connections,
				prompt.Triggered:Connect(function(player)
					options.onPrompt(player, node.control, {})
				end)
			)
		end
	end
	return {
		world = world,
		parts = M.countParts(world),
		prompts = wired,
		destroy = function(): ()
			for _, connection in connections do
				connection:Disconnect()
			end
			table.clear(connections)
		end,
	}
end

return M
