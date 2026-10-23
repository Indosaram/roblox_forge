--!strict
-- MeshAdapter: Roblox-side bridge that turns pure-Luau mesh data into a Model.
--
-- Primary path builds an EditableMesh and converts it with CreateMeshPartAsync.
-- Every engine call is wrapped in pcall, so if the editable APIs are missing at
-- runtime the adapter falls back to approximating the recorded primitives with
-- anchored Ball/Cylinder/Block Parts, which always works.
--
-- Lifetime: a MeshPart made by CreateMeshPartAsync only renders while its source
-- EditableMesh is alive. Destroying that EditableMesh (measured in Studio) makes
-- the MeshPart and every :Clone() of it invisible, so a cached mesh's
-- EditableMesh is retained, never destroyed, for the whole client session and
-- every instance handed out is a Clone that shares it.
--
-- Budget: the engine keeps at most 7 EditableMeshes alive at once. Only the
-- count matters - triangle count is irrelevant. MAX_LIVE_MESHES holds one of
-- those back, so once 6 live meshes exist any new unique key takes the Part
-- fallback instead of failing. Callers should route the few hero assets
-- (creatures) through the mesh path and force everything else (eggs, decor) onto
-- the primitive Part path so the budget is never contended.
--
-- On a client, toInstance may yield. Builds are serialized through a
-- module-level mutex and concurrent builds of the same cache key are coalesced;
-- on top of that CreateMeshPartAsync itself yields. Callers must run in their
-- own thread and must not assume a synchronous return.

local MeshAdapter = {}

export type Vec3 = { x: number, y: number, z: number }
export type Color = { r: number, g: number, b: number }

export type Primitive = {
	kind: string,
	color: Color,
	center: Vec3?,
	radii: Vec3?,
	size: Vec3?,
	a: Vec3?,
	b: Vec3?,
	radius: number?,
	base: Vec3?,
	tip: Vec3?,
}

export type MeshData = {
	vertices: { Vec3 },
	normals: { Vec3 },
	colors: { Color },
	triangles: { { number } },
	triangleCount: number,
	bounds: { min: Vec3, max: Vec3 },
	primitives: { Primitive },
}

-- The engine allows 7 live EditableMeshes; stop one short so a build never runs
-- right up against the hard cap.
local MAX_LIVE_MESHES = 6

-- Roblox has no cone PartType, so a cone is approximated by this many stacked
-- cylinders when the mesh path is unavailable.
local CONE_SEGMENTS = 3

local function toVector(v: Vec3): Vector3
	return Vector3.new(v.x, v.y, v.z)
end

local function toColor(c: Color): Color3
	return Color3.new(c.r, c.g, c.b)
end

local function finish(part: BasePart, color: Color3): BasePart
	part.Anchored = true
	part.CanCollide = false
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.CastShadow = true
	return part
end

-- Cylinder Parts run along their local X axis, so a segment between two points
-- is centered on them with its X axis on the segment. An explicit basis keeps a
-- vertical segment (a tree trunk) upright: CFrame.lookAt is degenerate when the
-- direction is parallel to its up vector and laid trunks flat along world X.
local function segmentCFrame(a: Vector3, b: Vector3): CFrame
	local axis = b - a
	if axis.Magnitude < 1e-6 then
		return CFrame.new(a)
	end
	local x = axis.Unit
	local reference = if math.abs(x.Y) < 0.99 then Vector3.new(0, 1, 0) else Vector3.new(1, 0, 0)
	local z = x:Cross(reference).Unit
	return CFrame.fromMatrix((a + b) / 2, x, z:Cross(x), z)
end

local function cylinderBetween(a: Vector3, b: Vector3, radius: number, color: Color3): BasePart
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new((b - a).Magnitude, radius * 2, radius * 2)
	part.CFrame = segmentCFrame(a, b)
	return finish(part, color)
end

-- A Ball Part is always spherical - it collapses to its smallest axis - so a
-- tall egg would render as a squashed ball. A built-in SpecialMesh Sphere is a
-- unit sphere stretched by the Part's non-uniform Size, giving a true ellipsoid.
local function ellipsoidAt(center: Vector3, radii: Vector3, color: Color3): BasePart
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Block
	part.Size = radii * 2
	part.CFrame = CFrame.new(center)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Scale = Vector3.one
	mesh.Parent = part
	return finish(part, color)
end

local function sphereAt(center: Vector3, radius: number, color: Color3): BasePart
	return ellipsoidAt(center, Vector3.new(radius, radius, radius), color)
end

local function capsuleParts(a: Vec3, b: Vec3, radius: number, color: Color3): { BasePart }
	local pa = toVector(a)
	local pb = toVector(b)
	return {
		cylinderBetween(pa, pb, radius, color),
		sphereAt(pa, radius, color),
		sphereAt(pb, radius, color),
	}
end

-- A cone reads best as a short stack of cylinders tapering from the base radius
-- to a narrow tip.
local function coneParts(base: Vec3, tip: Vec3, radius: number, color: Color3): { BasePart }
	local pb = toVector(base)
	local pt = toVector(tip)
	local tipRadius = radius * 0.12
	local parts: { BasePart } = {}
	for i = 1, CONE_SEGMENTS do
		local t0 = (i - 1) / CONE_SEGMENTS
		local t1 = i / CONE_SEGMENTS
		local r0 = radius + (tipRadius - radius) * t0
		local r1 = radius + (tipRadius - radius) * t1
		table.insert(parts, cylinderBetween(pb:Lerp(pt, t0), pb:Lerp(pt, t1), (r0 + r1) / 2, color))
	end
	return parts
end

-- Accent spots are recorded as small ellipsoids whose centers sit exactly on a
-- larger ellipsoid's surface. A sphere centered on the surface shows only half
-- its radius, so nudge it 30% of its radius outward along that surface normal
-- to keep the dot's authored size. Returns the center unchanged for anything
-- that is not a surface spot.
local function spotCenter(center: Vector3, radii: Vector3, primitives: { Primitive }): Vector3
	local spotRadius = math.min(radii.X, math.min(radii.Y, radii.Z))
	local spotMax = math.max(radii.X, math.max(radii.Y, radii.Z))
	local bestNormal: Vector3? = nil
	local bestGap = math.huge
	for _, other in primitives do
		local otherCenter = other.center
		local otherRadii = other.radii
		if other.kind == "ellipsoid" and otherCenter ~= nil and otherRadii ~= nil then
			local oc = toVector(otherCenter)
			local orad = toVector(otherRadii)
			-- Only a clearly bigger body is a candidate host, so one rock lump is
			-- never nudged to "sit" on a neighbour of similar size.
			if math.max(orad.X, math.max(orad.Y, orad.Z)) >= spotMax * 2 then
				local dx = (center.X - oc.X) / orad.X
				local dy = (center.Y - oc.Y) / orad.Y
				local dz = (center.Z - oc.Z) / orad.Z
				local gap = math.abs(math.sqrt(dx * dx + dy * dy + dz * dz) - 1)
				local normal = Vector3.new(dx / orad.X, dy / orad.Y, dz / orad.Z)
				if gap <= 0.05 and gap < bestGap and normal.Magnitude > 1e-6 then
					bestGap = gap
					bestNormal = normal.Unit
				end
			end
		end
	end
	if bestNormal == nil then
		return center
	end
	return center + bestNormal * (0.3 * spotRadius)
end

-- Skinned surfaces (rock lumps, tree canopy) re-record their source ellipsoids
-- in `primitives`, so the Part fallback recovers those shapes exactly.
local function partsForPrimitive(prim: Primitive, primitives: { Primitive }): { BasePart }
	local color = toColor(prim.color)
	if prim.kind == "ellipsoid" then
		local center = prim.center
		local radii = prim.radii
		if center == nil or radii == nil then
			return {}
		end
		local centerV = toVector(center)
		local radiiV = toVector(radii)
		return { ellipsoidAt(spotCenter(centerV, radiiV, primitives), radiiV, color) }
	elseif prim.kind == "box" then
		local center = prim.center
		local size = prim.size
		if center == nil or size == nil then
			return {}
		end
		local part = Instance.new("Part")
		part.Shape = Enum.PartType.Block
		part.Size = toVector(size)
		part.CFrame = CFrame.new(toVector(center))
		return { finish(part, color) }
	elseif prim.kind == "capsule" then
		local a = prim.a
		local b = prim.b
		local radius = prim.radius
		if a == nil or b == nil or radius == nil then
			return {}
		end
		return capsuleParts(a, b, radius, color)
	elseif prim.kind == "cone" then
		local base = prim.base
		local tip = prim.tip
		local radius = prim.radius
		if base == nil or tip == nil or radius == nil then
			return {}
		end
		return coneParts(base, tip, radius, color)
	end
	return {}
end

local function buildFallback(meshData: MeshData, name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	local primary: BasePart? = nil
	for index, prim in meshData.primitives do
		for _, part in partsForPrimitive(prim, meshData.primitives) do
			part.Name = string.format("%s_%03d", prim.kind, index)
			part.Parent = model
			if primary == nil then
				primary = part
			end
		end
	end
	if primary == nil then
		local part = Instance.new("Part")
		part.Name = "Fallback"
		part.Size = Vector3.new(1, 1, 1)
		part.CFrame = CFrame.new(0, 0, 0)
		finish(part, Color3.new(1, 1, 1))
		part.Parent = model
		primary = part
	end
	-- Part fallbacks build in mesh space (Y up). A segment part's own CFrame is rotated along its
	-- axis, and with a PrimaryPart set Studio's pivot is PrimaryPart.CFrame * PivotOffset (it
	-- ignores Model.WorldPivot), so offset the pivot back to an axis-aligned frame at the
	-- primary's position or PivotTo would tip the whole prop over.
	local root = primary :: BasePart
	root.PivotOffset = root.CFrame:Inverse() * CFrame.new(root.CFrame.Position)
	model.PrimaryPart = root
	return model
end

-- CreateEditableMesh returns nil (not an error) once the instance memory
-- budget is exhausted, which the old code surfaced as "attempt to index nil
-- with AddVertex". Prefer the fixed-size form when the engine supports it and
-- report the budget as an explicit failure message otherwise.
local function createEditableMesh(): (any?, string?)
	local AssetService = game:GetService("AssetService")
	local fixedOk, fixed = pcall(function(): any
		return AssetService:CreateEditableMesh({ FixedSize = true })
	end)
	if fixedOk and fixed ~= nil then
		return fixed, nil
	end
	local plainOk, plain = pcall(function(): any
		return AssetService:CreateEditableMesh()
	end)
	if plainOk and plain ~= nil then
		return plain, nil
	end
	if fixedOk or plainOk then
		return nil, "EditableMesh budget"
	end
	local cause = if fixedOk then plain else fixed
	return nil, "CreateEditableMesh failed: " .. tostring(cause)
end

-- Returns the MeshPart and the EditableMesh it renders from. The caller keeps
-- that EditableMesh alive; destroying it would blank the MeshPart and all its
-- clones. A conversion that fails has no live instance, so its EditableMesh is
-- released to give the budget back.
local function buildEditableMesh(meshData: MeshData): (MeshPart?, any, string?)
	local editable, createFailure = createEditableMesh()
	if editable == nil then
		return nil, nil, createFailure
	end
	local ok, result = pcall(function(): any
		local AssetService = game:GetService("AssetService")
		local vertexIds: { number } = {}
		for i, p in meshData.vertices do
			vertexIds[i] = editable:AddVertex(toVector(p))
		end
		local normalIds: { number } = {}
		for i, n in meshData.normals do
			normalIds[i] = editable:AddNormal(toVector(n))
		end
		local colorIds: { number } = {}
		for i, c in meshData.colors do
			colorIds[i] = editable:AddColor(toColor(c), 1)
		end
		for _, tri in meshData.triangles do
			local faceId = editable:AddTriangle(vertexIds[tri[1]], vertexIds[tri[2]], vertexIds[tri[3]])
			editable:SetFaceNormals(faceId, { normalIds[tri[1]], normalIds[tri[2]], normalIds[tri[3]] })
			editable:SetFaceColors(faceId, { colorIds[tri[1]], colorIds[tri[2]], colorIds[tri[3]] })
		end
		return AssetService:CreateMeshPartAsync(Content.fromObject(editable))
	end)
	if ok and result ~= nil then
		return result :: MeshPart, editable, nil
	end
	pcall(function()
		editable:Destroy()
	end)
	local message = if ok then "CreateMeshPartAsync returned nil" else tostring(result)
	return nil, nil, message
end

-- EditableMesh content does not replicate, and creating one per instance is
-- expensive enough to fail on tight memory budgets. Cache one MeshPart per
-- cache key on the client and Clone it for every later instance. The entry also
-- owns the source EditableMesh, which must outlive every clone.
type MeshCacheEntry = {
	part: MeshPart,
	editable: any,
}

local meshCache: { [string]: MeshCacheEntry } = {}
local warned: { [string]: boolean } = {}

-- EditableMeshes for uncached builds are retained here so none is collected
-- while a MeshPart built from it is still in the world.
local retainedEditableMeshes: { any } = {}

-- Total EditableMeshes kept alive: one per cache entry plus one per retained
-- uncached build. The engine's ceiling is 7; MAX_LIVE_MESHES holds one back.
local function liveMeshCount(): number
	local cached = 0
	for _ in meshCache do
		cached += 1
	end
	return cached + #retainedEditableMeshes
end

local RunService = game:GetService("RunService")

-- The engine caps how many EditableMeshes can be alive at once, so creation is
-- serialized through a module-level FIFO mutex: at most one is being built at
-- any moment. Successfully converted meshes are then retained rather than
-- destroyed. Waiters park on their own thread and are resumed one at a time by
-- whoever releases the lock, with no polling.
local mutexHeld = false
local mutexQueue: { thread } = {}

local function acquireMutex(): ()
	if mutexHeld then
		table.insert(mutexQueue, coroutine.running())
		coroutine.yield()
	else
		mutexHeld = true
	end
end

local function releaseMutex(): ()
	local nextThread = table.remove(mutexQueue, 1)
	if nextThread ~= nil then
		-- Hand the lock straight to the next waiter rather than reopening it.
		task.spawn(nextThread)
	else
		mutexHeld = false
	end
end

-- A build that returns nil is a transient budget failure: hand the mutex on,
-- wait for the next release, and retry a bounded number of times before the
-- caller falls back to Parts. Hitting the live cap is not transient, so it
-- returns immediately.
local MAX_BUILD_RETRIES = 3

local function buildSerialized(cacheKey: string?, meshData: MeshData): (MeshPart?, string?)
	local failure: string? = nil
	local capped = false
	for _ = 0, MAX_BUILD_RETRIES do
		acquireMutex()
		local built: MeshPart? = nil
		local editable: any = nil
		if liveMeshCount() < MAX_LIVE_MESHES then
			local buildFailure: string? = nil
			built, editable, buildFailure = buildEditableMesh(meshData)
			failure = buildFailure
			if built ~= nil then
				if cacheKey ~= nil then
					meshCache[cacheKey] = { part = built, editable = editable }
				else
					table.insert(retainedEditableMeshes, editable)
				end
			end
		else
			capped = true
		end
		releaseMutex()
		if built ~= nil then
			return built, nil
		end
		if capped then
			break
		end
	end
	if capped then
		failure = string.format("live EditableMesh cap reached (%d); using Part fallback", MAX_LIVE_MESHES)
	end
	return nil, failure
end

-- Concurrent builds of the same cache key are coalesced: the first caller
-- builds under the mutex and the rest park on `waiters`, then Clone the result
-- once it is ready.
type InFlightBuild = {
	waiters: { thread },
	result: MeshPart?,
	failure: string?,
}
local inFlight: { [string]: InFlightBuild } = {}

local function buildOrJoin(cacheKey: string, meshData: MeshData): (MeshPart?, string?)
	local existing = inFlight[cacheKey]
	if existing ~= nil then
		table.insert(existing.waiters, coroutine.running())
		coroutine.yield()
		return existing.result, existing.failure
	end

	local job: InFlightBuild = { waiters = {}, result = nil, failure = nil }
	inFlight[cacheKey] = job
	local built, failure = buildSerialized(cacheKey, meshData)
	job.result = built
	job.failure = failure
	inFlight[cacheKey] = nil
	for _, waiter in job.waiters do
		task.spawn(waiter)
	end
	return built, failure
end

-- forceParts skips the EditableMesh path entirely: eggs and decor always take
-- it so the client's ~7-mesh budget stays reserved for creatures. There is no
-- priority flag - callers route by asset class, which is enough.
export type ToInstanceOpts = {
	forceParts: boolean?,
	cacheKey: string?,
}

-- May yield on the client: builds are serialized through the EditableMesh mutex
-- and CreateMeshPartAsync yields. Callers already run in their own threads.
function MeshAdapter.toInstance(meshData: MeshData, name: string, opts: ToInstanceOpts?): Model
	local model = Instance.new("Model")
	model.Name = name

	-- EditableMesh content does not replicate to clients, so a server-built
	-- model would be invisible in Studio play/real clients. Only take the
	-- EditableMesh path on a client, where the mesh is created locally; on the
	-- server go straight to the Part fallback so the model replicates.
	if (opts == nil or not opts.forceParts) and RunService:IsClient() then
		local cacheKey = if opts then opts.cacheKey else nil
		local meshPart: MeshPart? = nil
		local failure: string? = nil
		if cacheKey ~= nil then
			local cached = meshCache[cacheKey]
			if cached ~= nil then
				meshPart = cached.part
			else
				meshPart, failure = buildOrJoin(cacheKey, meshData)
			end
		else
			meshPart, failure = buildSerialized(nil, meshData)
		end
		if meshPart ~= nil then
			local instance: MeshPart = meshPart
			if cacheKey ~= nil then
				-- Clones share the cached mesh; the original is never parented.
				instance = meshPart:Clone() :: MeshPart
			end
			-- Measured in Studio (p42): the MeshPart's CFrame sits at the EditableMesh origin and
			-- its Size spans the vertex bounds, so the rendered geometry is NOT centred in the
			-- Size box. Record the mesh-space bounds so callers can find the visible extent
			-- (Size / (max - min) is the current scale, which ScaleTo keeps up to date).
			local bounds = meshData.bounds
			instance:SetAttribute("ForgeMeshMin", toVector(bounds.min))
			instance:SetAttribute("ForgeMeshMax", toVector(bounds.max))
			instance.Name = name .. "_Mesh"
			instance.Anchored = true
			instance.CanCollide = false
			instance.Parent = model
			model.PrimaryPart = instance
			return model
		end
		local logKey = cacheKey or name
		if not warned[logKey] then
			warned[logKey] = true
			warn(
				string.format(
					"MeshAdapter: EditableMesh failed for %s: %s; using Part fallback",
					logKey,
					failure or "unknown error"
				)
			)
		end
	end

	return buildFallback(meshData, name)
end

return MeshAdapter
