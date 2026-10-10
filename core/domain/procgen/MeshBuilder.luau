--!strict
-- MeshBuilder: pure-Luau triangle-mesh accumulator. No Roblox APIs, so it runs
-- under Lune and can be unit tested without an engine. Geometry is stored
-- unindexed (three vertices per triangle) so mirrored copies keep correct
-- winding and flat faces keep exact normals. Every recorded primitive is kept
-- in `primitives` so core/infra/render/MeshAdapter can fall back to Parts when
-- EditableMesh is unavailable.

export type Vec3 = { x: number, y: number, z: number }
export type Color = { r: number, g: number, b: number }

export type Primitive = {
	kind: string,
	center: Vec3?,
	radii: Vec3?,
	size: Vec3?,
	a: Vec3?,
	b: Vec3?,
	radius: number?,
	base: Vec3?,
	tip: Vec3?,
	color: Color,
}

export type MeshData = {
	vertices: { Vec3 },
	normals: { Vec3 },
	colors: { Color },
	triangles: { { number } },
	triangleCount: number,
	bounds: { min: Vec3, max: Vec3 },
	primitives: { Primitive },
	-- Set by a caller (e.g. Creature.generate, Prop.generate) that reduced
	-- tessellation to fit a polyBudget but still exceeds it even at the
	-- coarsest resolution. MeshBuilder itself never sets this; build() always
	-- leaves it false since a builder has no budget to compare against.
	overBudget: boolean,
}

export type Builder = {
	vertices: { Vec3 },
	normals: { Vec3 },
	colors: { Color },
	triangles: { { number } },
	primitives: { Primitive },
	addEllipsoid: (self: Builder, center: Vec3, radii: Vec3, color: Color, segments: number) -> (),
	addCapsule: (self: Builder, a: Vec3, b: Vec3, radius: number, color: Color, segments: number) -> (),
	addBox: (self: Builder, center: Vec3, size: Vec3, color: Color) -> (),
	addCone: (self: Builder, base: Vec3, tip: Vec3, radius: number, color: Color, segments: number) -> (),
	addMesh: (self: Builder, mesh: MeshData) -> (),
	mirrorX: (self: Builder) -> (),
	build: (self: Builder) -> MeshData,
}

export type SkinOptions = {
	-- Smooth-min blend width in grid cells. Larger blends merge parts more
	-- aggressively; 1.25 keeps toy-like fillets without swallowing detail.
	blend: number?,
	-- Colour the downward-facing surface with this (lightened accent) to give a
	-- distinct belly, matching the crisp belly primitives added by Creature.
	bellyColor: Color?,
}

local MeshBuilder = {}

local function v(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

local function add(a: Vec3, b: Vec3): Vec3
	return v(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function sub(a: Vec3, b: Vec3): Vec3
	return v(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function scale(a: Vec3, s: number): Vec3
	return v(a.x * s, a.y * s, a.z * s)
end

local function cross(a: Vec3, b: Vec3): Vec3
	return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end

local function dot(a: Vec3, b: Vec3): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end

local function length(a: Vec3): number
	return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
end

local function normalize(a: Vec3): Vec3
	local l = length(a)
	if l < 1e-12 then
		return v(0, 1, 0)
	end
	return v(a.x / l, a.y / l, a.z / l)
end

-- Two unit vectors spanning the plane perpendicular to `axis`.
local function basis(axis: Vec3): (Vec3, Vec3)
	local up = v(0, 1, 0)
	if math.abs(axis.y) > 0.99 then
		up = v(1, 0, 0)
	end
	local u = normalize(cross(up, axis))
	local w = normalize(cross(axis, u))
	return u, w
end

local function checkSegments(segments: number): number
	if type(segments) ~= "number" or segments ~= segments or segments < 3 then
		error("invalid segments")
	end
	return math.floor(segments)
end

-- Appends one triangle, flipping the winding if the supplied ideal normals say
-- it faces inward. Vertices and normals are appended in lockstep.
local function pushTriangle(b: Builder, p0: Vec3, p1: Vec3, p2: Vec3, n0: Vec3, n1: Vec3, n2: Vec3, color: Color): ()
	local cr = cross(sub(p1, p0), sub(p2, p0))
	local reference = add(add(n0, n1), n2)
	if dot(cr, reference) < 0 then
		p1, p2 = p2, p1
		n1, n2 = n2, n1
	end
	local i = #b.vertices
	table.insert(b.vertices, p0)
	table.insert(b.normals, n0)
	table.insert(b.colors, color)
	table.insert(b.vertices, p1)
	table.insert(b.normals, n1)
	table.insert(b.colors, color)
	table.insert(b.vertices, p2)
	table.insert(b.normals, n2)
	table.insert(b.colors, color)
	table.insert(b.triangles, { i + 1, i + 2, i + 3 })
end

local function mirrorPrimitive(p: Primitive): Primitive
	local result: Primitive = {
		kind = p.kind,
		radii = p.radii,
		size = p.size,
		radius = p.radius,
		color = p.color,
	}
	if p.center ~= nil then
		result.center = v(-p.center.x, p.center.y, p.center.z)
	end
	if p.a ~= nil then
		result.a = v(-p.a.x, p.a.y, p.a.z)
	end
	if p.b ~= nil then
		result.b = v(-p.b.x, p.b.y, p.b.z)
	end
	if p.base ~= nil then
		result.base = v(-p.base.x, p.base.y, p.base.z)
	end
	if p.tip ~= nil then
		result.tip = v(-p.tip.x, p.tip.y, p.tip.z)
	end
	return result
end

function MeshBuilder.new(): Builder
	local builder = setmetatable({
		vertices = {},
		normals = {},
		colors = {},
		triangles = {},
		primitives = {},
	}, { __index = MeshBuilder })
	return (builder :: any) :: Builder
end

function MeshBuilder.addEllipsoid(self: Builder, center: Vec3, radii: Vec3, color: Color, segments: number): ()
	local lon = checkSegments(segments)
	local lat = math.max(2, math.floor(lon / 2))

	local function surface(theta: number, phi: number): (Vec3, Vec3)
		local sphi = math.sin(phi)
		local p = v(
			center.x + radii.x * math.cos(theta) * sphi,
			center.y + radii.y * math.cos(phi),
			center.z + radii.z * math.sin(theta) * sphi
		)
		-- The surface gradient divides center-relative positions by radii squared;
		-- these unit-sphere coordinates have not yet been scaled by the radii.
		local n = v(math.cos(theta) * sphi / radii.x, math.cos(phi) / radii.y, math.sin(theta) * sphi / radii.z)
		return p, normalize(n)
	end

	local northP = v(center.x, center.y + radii.y, center.z)
	local southP = v(center.x, center.y - radii.y, center.z)
	local northN = v(0, 1, 0)
	local southN = v(0, -1, 0)

	local rings: { { { p: Vec3, n: Vec3 } } } = {}
	for j = 1, lat - 1 do
		local phi = math.pi * j / lat
		local ring: { { p: Vec3, n: Vec3 } } = {}
		for i = 1, lon do
			local theta = 2 * math.pi * (i - 1) / lon
			local p, n = surface(theta, phi)
			ring[i] = { p = p, n = n }
		end
		rings[j] = ring
	end

	for i = 1, lon do
		local i2 = i % lon + 1
		pushTriangle(self, northP, rings[1][i2].p, rings[1][i].p, northN, rings[1][i2].n, rings[1][i].n, color)
	end
	for j = 1, lat - 2 do
		for i = 1, lon do
			local i2 = i % lon + 1
			pushTriangle(
				self,
				rings[j][i].p,
				rings[j + 1][i].p,
				rings[j + 1][i2].p,
				rings[j][i].n,
				rings[j + 1][i].n,
				rings[j + 1][i2].n,
				color
			)
			pushTriangle(
				self,
				rings[j][i].p,
				rings[j + 1][i2].p,
				rings[j][i2].p,
				rings[j][i].n,
				rings[j + 1][i2].n,
				rings[j][i2].n,
				color
			)
		end
	end
	for i = 1, lon do
		local i2 = i % lon + 1
		pushTriangle(
			self,
			southP,
			rings[lat - 1][i].p,
			rings[lat - 1][i2].p,
			southN,
			rings[lat - 1][i].n,
			rings[lat - 1][i2].n,
			color
		)
	end

	table.insert(self.primitives, { kind = "ellipsoid", center = center, radii = radii, color = color })
end

function MeshBuilder.addCapsule(self: Builder, a: Vec3, b: Vec3, radius: number, color: Color, segments: number): ()
	local lon = checkSegments(segments)
	local cap = math.max(2, math.floor(lon / 2))
	local axis = normalize(sub(b, a))
	local u, w = basis(axis)

	local function ringVertex(center: Vec3, dir: Vec3, phi: number, i: number): (Vec3, Vec3)
		local theta = 2 * math.pi * (i - 1) / lon
		local radial = add(scale(u, math.cos(theta)), scale(w, math.sin(theta)))
		local cp = math.cos(phi)
		local sp = math.sin(phi)
		local p = add(add(center, scale(dir, radius * cp)), scale(radial, radius * sp))
		local n = normalize(add(scale(dir, cp), scale(radial, sp)))
		return p, n
	end

	-- Builds a hemisphere whose pole points along `dir` and returns its equator ring.
	local function hemisphere(center: Vec3, dir: Vec3): { { p: Vec3, n: Vec3 } }
		local poleP = add(center, scale(dir, radius))
		local rings: { { { p: Vec3, n: Vec3 } } } = {}
		for k = 1, cap do
			local phi = (math.pi / 2) * k / cap
			local ring: { { p: Vec3, n: Vec3 } } = {}
			for i = 1, lon do
				local p, n = ringVertex(center, dir, phi, i)
				ring[i] = { p = p, n = n }
			end
			rings[k] = ring
		end
		for i = 1, lon do
			local i2 = i % lon + 1
			pushTriangle(self, poleP, rings[1][i2].p, rings[1][i].p, dir, rings[1][i2].n, rings[1][i].n, color)
		end
		for k = 1, cap - 1 do
			for i = 1, lon do
				local i2 = i % lon + 1
				pushTriangle(
					self,
					rings[k][i].p,
					rings[k + 1][i].p,
					rings[k + 1][i2].p,
					rings[k][i].n,
					rings[k + 1][i].n,
					rings[k + 1][i2].n,
					color
				)
				pushTriangle(
					self,
					rings[k][i].p,
					rings[k + 1][i2].p,
					rings[k][i2].p,
					rings[k][i].n,
					rings[k + 1][i2].n,
					rings[k][i2].n,
					color
				)
			end
		end
		return rings[cap]
	end

	local ringA = hemisphere(a, scale(axis, -1))
	local ringB = hemisphere(b, axis)
	for i = 1, lon do
		local i2 = i % lon + 1
		pushTriangle(self, ringA[i].p, ringB[i].p, ringB[i2].p, ringA[i].n, ringB[i].n, ringB[i2].n, color)
		pushTriangle(self, ringA[i].p, ringB[i2].p, ringA[i2].p, ringA[i].n, ringB[i2].n, ringA[i2].n, color)
	end

	table.insert(self.primitives, { kind = "capsule", a = a, b = b, radius = radius, color = color })
end

function MeshBuilder.addBox(self: Builder, center: Vec3, size: Vec3, color: Color): ()
	local hx, hy, hz = size.x / 2, size.y / 2, size.z / 2
	local function corner(sx: number, sy: number, sz: number): Vec3
		return v(center.x + sx * hx, center.y + sy * hy, center.z + sz * hz)
	end

	local faces: { { normal: Vec3, corners: { Vec3 } } } = {
		{ normal = v(1, 0, 0), corners = { corner(1, -1, -1), corner(1, -1, 1), corner(1, 1, 1), corner(1, 1, -1) } },
		{
			normal = v(-1, 0, 0),
			corners = { corner(-1, -1, 1), corner(-1, -1, -1), corner(-1, 1, -1), corner(-1, 1, 1) },
		},
		{ normal = v(0, 1, 0), corners = { corner(-1, 1, -1), corner(1, 1, -1), corner(1, 1, 1), corner(-1, 1, 1) } },
		{
			normal = v(0, -1, 0),
			corners = { corner(-1, -1, 1), corner(1, -1, 1), corner(1, -1, -1), corner(-1, -1, -1) },
		},
		{ normal = v(0, 0, 1), corners = { corner(-1, -1, 1), corner(-1, 1, 1), corner(1, 1, 1), corner(1, -1, 1) } },
		{
			normal = v(0, 0, -1),
			corners = { corner(1, -1, -1), corner(1, 1, -1), corner(-1, 1, -1), corner(-1, -1, -1) },
		},
	}
	for _, face in faces do
		local c = face.corners
		pushTriangle(self, c[1], c[2], c[3], face.normal, face.normal, face.normal, color)
		pushTriangle(self, c[1], c[3], c[4], face.normal, face.normal, face.normal, color)
	end

	table.insert(self.primitives, { kind = "box", center = center, size = size, color = color })
end

function MeshBuilder.addCone(self: Builder, base: Vec3, tip: Vec3, radius: number, color: Color, segments: number): ()
	local lon = checkSegments(segments)
	local axis = normalize(sub(tip, base))
	local height = length(sub(tip, base))
	local u, w = basis(axis)

	local ring: { { p: Vec3, n: Vec3 } } = {}
	for i = 1, lon do
		local theta = 2 * math.pi * (i - 1) / lon
		local radial = add(scale(u, math.cos(theta)), scale(w, math.sin(theta)))
		ring[i] = {
			p = add(base, scale(radial, radius)),
			n = normalize(add(scale(radial, height), scale(axis, radius))),
		}
	end

	local capNormal = scale(axis, -1)
	for i = 1, lon do
		local i2 = i % lon + 1
		pushTriangle(self, base, ring[i].p, ring[i2].p, capNormal, capNormal, capNormal, color)
	end
	for i = 1, lon do
		local i2 = i % lon + 1
		local tipN = normalize(add(ring[i].n, ring[i2].n))
		pushTriangle(self, ring[i].p, tip, ring[i2].p, ring[i].n, tipN, ring[i2].n, color)
	end

	table.insert(self.primitives, { kind = "cone", base = base, tip = tip, radius = radius, color = color })
end

local DEFAULT_BLEND_CELLS = 1.25
local CONE_TIP_RATIO = 0.35

-- Cube corners are encoded as dx + 2*dy + 4*dz. Freudenthal splits each cube
-- into six tetrahedra sharing the main diagonal 0-7; the split is conforming
-- across neighbouring cells, so marching-tetrahedra vertices weld into a closed
-- manifold without the ambiguous cases that crack surface nets.
local TETS = {
	{ 0, 1, 3, 7 },
	{ 0, 3, 2, 7 },
	{ 0, 2, 6, 7 },
	{ 0, 6, 4, 7 },
	{ 0, 4, 5, 7 },
	{ 0, 5, 1, 7 },
}

-- The six edges of a tetrahedron as indices into its four corners.
local TET_EDGES = {
	{ 0, 1 },
	{ 1, 2 },
	{ 2, 0 },
	{ 0, 3 },
	{ 1, 3 },
	{ 2, 3 },
}

local function clampValue(value: number, lo: number, hi: number): number
	if value < lo then
		return lo
	elseif value > hi then
		return hi
	end
	return value
end

local function signOf(value: number): number
	if value < 0 then
		return -1
	elseif value > 0 then
		return 1
	end
	return 0
end

-- Quadratic smooth minimum (iq): <= min(a, b), blending where |a - b| < k.
local function smoothMin(a: number, b: number, k: number): number
	local h = clampValue(0.5 + 0.5 * (b - a) / k, 0, 1)
	return b * (1 - h) + a * h - k * h * (1 - h)
end

-- Inigo Quilez's scaled-space ellipsoid distance approximation. Monotonic in
-- the ellipsoid radius, so the isosurface stays a clean ellipsoid.
local function sdEllipsoid(p: Vec3, center: Vec3, radii: Vec3): number
	local dx = (p.x - center.x) / radii.x
	local dy = (p.y - center.y) / radii.y
	local dz = (p.z - center.z) / radii.z
	local k0 = math.sqrt(dx * dx + dy * dy + dz * dz)
	local ex = dx / radii.x
	local ey = dy / radii.y
	local ez = dz / radii.z
	local k1 = math.sqrt(ex * ex + ey * ey + ez * ez)
	if k0 < 1e-9 then
		return -math.min(radii.x, math.min(radii.y, radii.z))
	end
	if k1 < 1e-12 then
		return -math.min(radii.x, math.min(radii.y, radii.z))
	end
	return k0 * (k0 - 1) / k1
end

local function sdSegment(p: Vec3, a: Vec3, b: Vec3): number
	local pax, pay, paz = p.x - a.x, p.y - a.y, p.z - a.z
	local bax, bay, baz = b.x - a.x, b.y - a.y, b.z - a.z
	local l2 = bax * bax + bay * bay + baz * baz
	local h = 0
	if l2 > 1e-12 then
		h = clampValue((pax * bax + pay * bay + paz * baz) / l2, 0, 1)
	end
	local dx = pax - bax * h
	local dy = pay - bay * h
	local dz = paz - baz * h
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Inigo Quilez's exact rounded cone distance: r1 at `a`, r2 at `b`.
local function sdRoundCone(p: Vec3, a: Vec3, b: Vec3, r1: number, r2: number): number
	local bax, bay, baz = b.x - a.x, b.y - a.y, b.z - a.z
	local l2 = bax * bax + bay * bay + baz * baz
	if l2 < 1e-12 then
		return sdSegment(p, a, a) - math.max(r1, r2)
	end
	local rr = r1 - r2
	local a2 = l2 - rr * rr
	local il2 = 1 / l2
	local pax, pay, paz = p.x - a.x, p.y - a.y, p.z - a.z
	local y = pax * bax + pay * bay + paz * baz
	local z = y - l2
	local qx = pax * l2 - bax * y
	local qy = pay * l2 - bay * y
	local qz = paz * l2 - baz * y
	local x2 = qx * qx + qy * qy + qz * qz
	local y2 = y * y * l2
	local z2 = z * z * l2
	local k = signOf(rr) * rr * rr * x2
	if signOf(z) * a2 * z2 > k then
		return math.sqrt(x2 + z2) * il2 - r2
	end
	if signOf(y) * a2 * y2 < k then
		return math.sqrt(x2 + y2) * il2 - r1
	end
	return (math.sqrt(x2 * a2 * il2) + y * rr) * il2 - r1
end

local function sdBox(p: Vec3, center: Vec3, size: Vec3): number
	local dx = math.abs(p.x - center.x) - size.x / 2
	local dy = math.abs(p.y - center.y) - size.y / 2
	local dz = math.abs(p.z - center.z) - size.z / 2
	local ox, oy, oz = math.max(dx, 0), math.max(dy, 0), math.max(dz, 0)
	local outside = math.sqrt(ox * ox + oy * oy + oz * oz)
	local inside = math.min(math.max(dx, math.max(dy, dz)), 0)
	return outside + inside
end

local function primitiveDistance(prim: Primitive, p: Vec3): number
	if prim.kind == "ellipsoid" then
		local center, radii = prim.center, prim.radii
		if center == nil or radii == nil then
			return math.huge
		end
		return sdEllipsoid(p, center, radii)
	elseif prim.kind == "capsule" then
		local a, b, radius = prim.a, prim.b, prim.radius
		if a == nil or b == nil or radius == nil then
			return math.huge
		end
		return sdSegment(p, a, b) - radius
	elseif prim.kind == "cone" then
		local base, tip, radius = prim.base, prim.tip, prim.radius
		if base == nil or tip == nil or radius == nil then
			return math.huge
		end
		return sdRoundCone(p, base, tip, radius, radius * CONE_TIP_RATIO)
	elseif prim.kind == "box" then
		local center, size = prim.center, prim.size
		if center == nil or size == nil then
			return math.huge
		end
		return sdBox(p, center, size)
	end
	return math.huge
end

local function primitiveExtent(prim: Primitive, minv: Vec3, maxv: Vec3): (Vec3, Vec3)
	local function expand(lo: Vec3, hi: Vec3, center: Vec3, half: Vec3): (Vec3, Vec3)
		return v(
			math.min(lo.x, center.x - half.x),
			math.min(lo.y, center.y - half.y),
			math.min(lo.z, center.z - half.z)
		),
			v(math.max(hi.x, center.x + half.x), math.max(hi.y, center.y + half.y), math.max(hi.z, center.z + half.z))
	end
	if prim.kind == "ellipsoid" then
		local center, radii = prim.center, prim.radii
		if center ~= nil and radii ~= nil then
			return expand(minv, maxv, center, radii)
		end
	elseif prim.kind == "box" then
		local center, size = prim.center, prim.size
		if center ~= nil and size ~= nil then
			return expand(minv, maxv, center, scale(size, 0.5))
		end
	elseif prim.kind == "capsule" then
		local a, b, radius = prim.a, prim.b, prim.radius
		if a ~= nil and b ~= nil and radius ~= nil then
			local half = v(radius, radius, radius)
			minv, maxv = expand(minv, maxv, a, half)
			return expand(minv, maxv, b, half)
		end
	elseif prim.kind == "cone" then
		local base, tip, radius = prim.base, prim.tip, prim.radius
		if base ~= nil and tip ~= nil and radius ~= nil then
			local half = v(radius, radius, radius)
			minv, maxv = expand(minv, maxv, base, half)
			return expand(minv, maxv, tip, half)
		end
	end
	return minv, maxv
end

-- Blends a base colour with the top-lit vertical gradient, the belly tint and
-- the smooth-min crease occlusion into a clamped vertex colour.
local function shadeVertex(
	pos: Vec3,
	normal: Vec3,
	base: Color,
	crease: number,
	minY: number,
	maxY: number,
	belly: Color?
): Color
	local t = 0
	local span = maxY - minY
	if span > 1e-9 then
		t = clampValue((pos.y - minY) / span, 0, 1)
	end
	-- Chibi toy shading: the back/top reads darker and more saturated while the
	-- bottom stays bright, so a light accent-tinted belly pops against a darker
	-- spine gradient. `t` is 1 at the top of the model.
	local light = (1.06 - 0.32 * t) * (1 - 0.28 * crease)
	local r, g, b = base.r * light, base.g * light, base.b * light
	if belly ~= nil and normal.y < -0.35 then
		local w = clampValue((-normal.y - 0.35) / 0.5, 0, 1) * 0.7
		r = r * (1 - w) + belly.r * w
		g = g * (1 - w) + belly.g * w
		b = b * (1 - w) + belly.b * w
	end
	return { r = clampValue(r, 0, 1), g = clampValue(g, 0, 1), b = clampValue(b, 0, 1) }
end

--- Builds one watertight smooth surface from ellipsoid/capsule/cone/box
--- primitives by sampling a smooth-min union SDF on a grid and running marching
--- tetrahedra over a conforming Freudenthal split of every cell. Positions come
--- from linear interpolation along crossed tet edges, normals from the SDF
--- gradient, and colours from the nearest primitive plus a lit-top / belly /
--- crease-occlusion tint. `resolution` is the number of cells along the longest
--- bounding axis.
function MeshBuilder.skinned(primitives: { Primitive }, resolution: number, options: SkinOptions?): MeshData
	if #primitives == 0 then
		error("skinned needs at least one primitive")
	end
	if type(resolution) ~= "number" or resolution ~= resolution or resolution < 2 or resolution == math.huge then
		error("invalid resolution")
	end
	local res = math.floor(resolution)

	local minv = v(math.huge, math.huge, math.huge)
	local maxv = v(-math.huge, -math.huge, -math.huge)
	for _, prim in primitives do
		minv, maxv = primitiveExtent(prim, minv, maxv)
	end
	local extentX = maxv.x - minv.x
	local extentY = maxv.y - minv.y
	local extentZ = maxv.z - minv.z
	local maxExtent = math.max(extentX, math.max(extentY, extentZ))
	if maxExtent <= 0 then
		error("degenerate primitives")
	end

	local cell = maxExtent / res
	local blendCells = if options ~= nil and options.blend ~= nil then options.blend else DEFAULT_BLEND_CELLS
	local k = blendCells * cell
	local pad = k + 2 * cell
	local origin = v(minv.x - pad, minv.y - pad, minv.z - pad)
	local nx = math.max(3, math.ceil((extentX + 2 * pad) / cell) + 1)
	local ny = math.max(3, math.ceil((extentY + 2 * pad) / cell) + 1)
	local nz = math.max(3, math.ceil((extentZ + 2 * pad) / cell) + 1)
	if nx * ny * nz > 4000000 then
		error("skinned grid too large")
	end

	local function unionDistance(p: Vec3): number
		local acc = primitiveDistance(primitives[1], p)
		for index = 2, #primitives do
			acc = smoothMin(acc, primitiveDistance(primitives[index], p), k)
		end
		return acc
	end

	local function distanceInfo(p: Vec3): (number, number, number)
		local first = primitiveDistance(primitives[1], p)
		local second = math.huge
		local nearest = 1
		local acc = first
		for index = 2, #primitives do
			local d = primitiveDistance(primitives[index], p)
			if d < first then
				second = first
				first = d
				nearest = index
			elseif d < second then
				second = d
			end
			acc = smoothMin(acc, d, k)
		end
		local crease = 0
		if second < math.huge then
			crease = clampValue(1 - (second - first) / k, 0, 1)
		end
		return acc, nearest, crease
	end

	local function gradientAt(p: Vec3): Vec3
		local e = cell * 0.5
		local dx = unionDistance(v(p.x + e, p.y, p.z)) - unionDistance(v(p.x - e, p.y, p.z))
		local dy = unionDistance(v(p.x, p.y + e, p.z)) - unionDistance(v(p.x, p.y - e, p.z))
		local dz = unionDistance(v(p.x, p.y, p.z + e)) - unionDistance(v(p.x, p.y, p.z - e))
		return normalize(v(dx, dy, dz))
	end

	local values = table.create(nx * ny * nz, 0)
	for kk = 0, nz - 1 do
		local pz = origin.z + kk * cell
		for jj = 0, ny - 1 do
			local py = origin.y + jj * cell
			local row = (kk * ny + jj) * nx
			for ii = 0, nx - 1 do
				values[row + ii + 1] = unionDistance(v(origin.x + ii * cell, py, pz))
			end
		end
	end

	local vertices: { Vec3 } = {}
	local normals: { Vec3 } = {}
	local colors: { Color } = {}
	local belly = if options ~= nil then options.bellyColor else nil
	local totalCorners = nx * ny * nz
	local edgeVertex: { [number]: number } = {}

	local function cornerPosition(corner: number): Vec3
		local ii = corner % nx
		local jj = (corner // nx) % ny
		local kk = corner // (nx * ny)
		return v(origin.x + ii * cell, origin.y + jj * cell, origin.z + kk * cell)
	end

	-- One shared vertex per crossed grid edge, so the surfaces of neighbouring
	-- tetrahedra weld exactly and every edge ends up in two triangles.
	local function crossingVertex(a: number, b: number, va: number, vb: number): number
		local key = math.min(a, b) * totalCorners + math.max(a, b)
		local existing = edgeVertex[key]
		if existing ~= nil then
			return existing
		end
		local t = va / (va - vb)
		local pa = cornerPosition(a)
		local pb = cornerPosition(b)
		local pos = v(pa.x + (pb.x - pa.x) * t, pa.y + (pb.y - pa.y) * t, pa.z + (pb.z - pa.z) * t)
		local normal = gradientAt(pos)
		local _, nearest, crease = distanceInfo(pos)
		table.insert(vertices, pos)
		table.insert(normals, normal)
		table.insert(colors, shadeVertex(pos, normal, primitives[nearest].color, crease, minv.y, maxv.y, belly))
		local id = #vertices
		edgeVertex[key] = id
		return id
	end

	local triangles: { { number } } = {}
	local function emitTriangle(a: number, b: number, c: number): ()
		local pa, pb, pc = vertices[a], vertices[b], vertices[c]
		local center = scale(add(add(pa, pb), pc), 1 / 3)
		if dot(cross(sub(pb, pa), sub(pc, pa)), gradientAt(center)) < 0 then
			b, c = c, b
		end
		table.insert(triangles, { a, b, c })
	end

	local function emitPolygon(ids: { number }): ()
		if #ids == 3 then
			emitTriangle(ids[1], ids[2], ids[3])
			return
		end
		-- Four crossings form a planar quad; sort them around the centroid in the
		-- surface plane so the fan stays convex instead of bow-tied.
		local sx, sy, sz = 0, 0, 0
		for _, id in ids do
			local p = vertices[id]
			sx += p.x
			sy += p.y
			sz += p.z
		end
		local center = v(sx / 4, sy / 4, sz / 4)
		local u, w = basis(gradientAt(center))
		local function angleOf(id: number): number
			local d = sub(vertices[id], center)
			return math.atan2(dot(d, w), dot(d, u))
		end
		local sorted = table.clone(ids)
		table.sort(sorted, function(x, y)
			return angleOf(x) < angleOf(y)
		end)
		emitTriangle(sorted[1], sorted[2], sorted[3])
		emitTriangle(sorted[1], sorted[3], sorted[4])
	end

	local cellCornerIds = table.create(8, 0)
	local cellCornerValues = table.create(8, 0)
	for cz = 0, nz - 2 do
		for cy = 0, ny - 2 do
			for cx = 0, nx - 2 do
				for ci = 0, 7 do
					local dx = ci % 2
					local dy = (ci // 2) % 2
					local dz = ci // 4
					local corner = ((cz + dz) * ny + (cy + dy)) * nx + (cx + dx)
					cellCornerIds[ci + 1] = corner
					cellCornerValues[ci + 1] = values[corner + 1]
				end
				for _, tet in TETS do
					local ids = {
						cellCornerIds[tet[1] + 1],
						cellCornerIds[tet[2] + 1],
						cellCornerIds[tet[3] + 1],
						cellCornerIds[tet[4] + 1],
					}
					local vals = {
						cellCornerValues[tet[1] + 1],
						cellCornerValues[tet[2] + 1],
						cellCornerValues[tet[3] + 1],
						cellCornerValues[tet[4] + 1],
					}
					local crossings: { number } = {}
					for _, edge in TET_EDGES do
						local ia = edge[1] + 1
						local ib = edge[2] + 1
						local va, vb = vals[ia], vals[ib]
						if (va < 0) ~= (vb < 0) then
							table.insert(crossings, crossingVertex(ids[ia], ids[ib], va, vb))
						end
					end
					if #crossings == 3 or #crossings == 4 then
						emitPolygon(crossings)
					end
				end
			end
		end
	end

	local primList: { Primitive } = {}
	for _, prim in primitives do
		table.insert(primList, prim)
	end

	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, p in vertices do
		minX = math.min(minX, p.x)
		minY = math.min(minY, p.y)
		minZ = math.min(minZ, p.z)
		maxX = math.max(maxX, p.x)
		maxY = math.max(maxY, p.y)
		maxZ = math.max(maxZ, p.z)
	end
	if #vertices == 0 then
		minX, minY, minZ, maxX, maxY, maxZ = 0, 0, 0, 0, 0, 0
	end

	return {
		vertices = vertices,
		normals = normals,
		colors = colors,
		triangles = triangles,
		triangleCount = #triangles,
		bounds = { min = v(minX, minY, minZ), max = v(maxX, maxY, maxZ) },
		primitives = primList,
		overBudget = false,
	}
end

--- Appends another mesh's vertices, normals, colours, triangles and primitives,
--- offsetting the triangle indices. Used to combine one skinned surface with
--- crisp accent primitives in a single MeshData.
function MeshBuilder.addMesh(self: Builder, mesh: MeshData): ()
	local vertexCount = #mesh.vertices
	local offset = #self.vertices
	for index = 1, vertexCount do
		table.insert(self.vertices, mesh.vertices[index])
		table.insert(self.normals, mesh.normals[index])
		table.insert(self.colors, mesh.colors[index])
	end
	local triangleCount = #mesh.triangles
	for index = 1, triangleCount do
		local tri = mesh.triangles[index]
		table.insert(self.triangles, { tri[1] + offset, tri[2] + offset, tri[3] + offset })
	end
	local primitiveCount = #mesh.primitives
	for index = 1, primitiveCount do
		table.insert(self.primitives, mesh.primitives[index])
	end
end

function MeshBuilder.mirrorX(self: Builder): ()
	local vertexCount = #self.vertices
	for i = 1, vertexCount do
		local p = self.vertices[i]
		local n = self.normals[i]
		table.insert(self.vertices, v(-p.x, p.y, p.z))
		table.insert(self.normals, v(-n.x, n.y, n.z))
		table.insert(self.colors, self.colors[i])
	end
	local triangleCount = #self.triangles
	for i = 1, triangleCount do
		local t = self.triangles[i]
		table.insert(self.triangles, { t[1] + vertexCount, t[3] + vertexCount, t[2] + vertexCount })
	end
	local primitiveCount = #self.primitives
	for i = 1, primitiveCount do
		table.insert(self.primitives, mirrorPrimitive(self.primitives[i]))
	end
end

function MeshBuilder.build(self: Builder): MeshData
	local minX, minY, minZ, maxX, maxY, maxZ
	if #self.vertices == 0 then
		minX, minY, minZ = 0, 0, 0
		maxX, maxY, maxZ = 0, 0, 0
	else
		local first = self.vertices[1]
		minX, minY, minZ = first.x, first.y, first.z
		maxX, maxY, maxZ = first.x, first.y, first.z
		for i = 2, #self.vertices do
			local p = self.vertices[i]
			minX = math.min(minX, p.x)
			minY = math.min(minY, p.y)
			minZ = math.min(minZ, p.z)
			maxX = math.max(maxX, p.x)
			maxY = math.max(maxY, p.y)
			maxZ = math.max(maxZ, p.z)
		end
	end
	-- Snapshot every array: the builder is a live, mutable accumulator, so a
	-- later add*/mirrorX on self must not change a MeshData already handed
	-- out, and must not make its cached triangleCount stale.
	local triangles: { { number } } = table.create(#self.triangles)
	for i, tri in self.triangles do
		triangles[i] = table.clone(tri)
	end
	local primitives: { Primitive } = table.create(#self.primitives)
	for i, prim in self.primitives do
		primitives[i] = prim
	end
	return {
		vertices = table.clone(self.vertices),
		normals = table.clone(self.normals),
		colors = table.clone(self.colors),
		triangles = triangles,
		triangleCount = #self.triangles,
		bounds = { min = v(minX, minY, minZ), max = v(maxX, maxY, maxZ) },
		primitives = primitives,
		overBudget = false,
	}
end

-- Deterministic MINSTD linear congruential generator. The multiplier keeps every
-- intermediate product below 2^53 so results are exact across Luau runtimes.
function MeshBuilder.rng(seed: number): () -> number
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	return function(): number
		state = (48271 * state) % 2147483647
		return state / 2147483647
	end
end

return MeshBuilder
