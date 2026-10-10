--!strict
-- Specs for MeshBuilder: primitive tessellation, mesh invariants, and mirrorX.

local MeshBuilder = require("./MeshBuilder")

local function magnitude(v: MeshBuilder.Vec3): number
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function assertValid(mesh: MeshBuilder.MeshData): ()
	assert(#mesh.vertices > 0, "mesh has vertices")
	assert(#mesh.normals == #mesh.vertices, "one normal per vertex")
	assert(#mesh.colors == #mesh.vertices, "one color per vertex")
	assert(mesh.triangleCount == #mesh.triangles, "triangleCount matches #triangles")
	assert(#mesh.primitives > 0, "mesh records its primitives")
	for _, triangle in mesh.triangles do
		assert(#triangle == 3, "each triangle has three indices")
		for _, index in triangle do
			assert(index >= 1 and index <= #mesh.vertices, "triangle index in range, got " .. tostring(index))
		end
	end
	for _, normal in mesh.normals do
		local len = magnitude(normal)
		assert(math.abs(len - 1) < 1e-6, "normal is unit length, got " .. tostring(len))
	end
	for _, color in mesh.colors do
		local inRange = color.r >= 0
			and color.r <= 1
			and color.g >= 0
			and color.g <= 1
			and color.b >= 0
			and color.b <= 1
		assert(inRange, "color components stay within zero and one")
	end
	for _, p in mesh.vertices do
		assert(p.x >= mesh.bounds.min.x - 1e-9 and p.x <= mesh.bounds.max.x + 1e-9, "x within bounds")
		assert(p.y >= mesh.bounds.min.y - 1e-9 and p.y <= mesh.bounds.max.y + 1e-9, "y within bounds")
		assert(p.z >= mesh.bounds.min.z - 1e-9 and p.z <= mesh.bounds.max.z + 1e-9, "z within bounds")
	end
end

-- Every triangle must wind outward from a box centered at +-`magnitude` on x.
local function assertOutward(mesh: MeshBuilder.MeshData, centerMagnitude: number): ()
	for _, triangle in mesh.triangles do
		local a = mesh.vertices[triangle[1]]
		local b = mesh.vertices[triangle[2]]
		local c = mesh.vertices[triangle[3]]
		local e1x, e1y, e1z = b.x - a.x, b.y - a.y, b.z - a.z
		local e2x, e2y, e2z = c.x - a.x, c.y - a.y, c.z - a.z
		local nx = e1y * e2z - e1z * e2y
		local ny = e1z * e2x - e1x * e2z
		local nz = e1x * e2y - e1y * e2x
		local gx = (a.x + b.x + c.x) / 3
		local centerX = if gx >= 0 then centerMagnitude else -centerMagnitude
		local dot = nx * (gx - centerX) + ny * ((a.y + b.y + c.y) / 3) + nz * ((a.z + b.z + c.z) / 3)
		assert(dot > 0, "triangle winds outward")
	end
end

local function assertEllipsoid(mesh: MeshBuilder.MeshData, center: MeshBuilder.Vec3, radii: MeshBuilder.Vec3): ()
	assertValid(mesh)
	for index, p in mesh.vertices do
		local dx, dy, dz = p.x - center.x, p.y - center.y, p.z - center.z
		local surface = (dx / radii.x) ^ 2 + (dy / radii.y) ^ 2 + (dz / radii.z) ^ 2
		assert(math.abs(surface - 1) < 1e-9, "vertex lies on ellipsoid")
		local gradient = { x = dx / radii.x ^ 2, y = dy / radii.y ^ 2, z = dz / radii.z ^ 2 }
		local len = magnitude(gradient)
		local n = mesh.normals[index]
		local error = magnitude({ x = n.x - gradient.x / len, y = n.y - gradient.y / len, z = n.z - gradient.z / len })
		assert(error < 1e-9, "normal matches analytic ellipsoid gradient, error " .. tostring(error))
	end
	for _, triangle in mesh.triangles do
		local a, b, c = mesh.vertices[triangle[1]], mesh.vertices[triangle[2]], mesh.vertices[triangle[3]]
		local ux, uy, uz = b.x - a.x, b.y - a.y, b.z - a.z
		local vx, vy, vz = c.x - a.x, c.y - a.y, c.z - a.z
		local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
		local gx = ((a.x + b.x + c.x) / 3 - center.x) / radii.x ^ 2
		local gy = ((a.y + b.y + c.y) / 3 - center.y) / radii.y ^ 2
		local gz = ((a.z + b.z + c.z) / 3 - center.z) / radii.z ^ 2
		assert(nx * gx + ny * gy + nz * gz > 0, "ellipsoid triangle winds outward and is nondegenerate")
	end
end

local BODY = { r = 0.4, g = 0.6, b = 0.3 }
local ACCENT = { r = 0.9, g = 0.3, b = 0.2 }

-- Returns the number of edges not shared by exactly two triangles. A closed
-- manifold (watertight) mesh has zero.
local function openEdges(mesh: MeshBuilder.MeshData): number
	local counts: { [number]: number } = {}
	for _, triangle in mesh.triangles do
		for i = 1, 3 do
			local a = triangle[i]
			local b = triangle[i % 3 + 1]
			local key = math.min(a, b) * 100000000 + math.max(a, b)
			counts[key] = (counts[key] or 0) + 1
		end
	end
	local open = 0
	for _, count in counts do
		if count ~= 2 then
			open += 1
		end
	end
	return open
end

local SKIN_PRIMS: { MeshBuilder.Primitive } = {
	{ kind = "ellipsoid", center = { x = 0, y = 0, z = 0 }, radii = { x = 1, y = 0.8, z = 1.3 }, color = BODY },
	{
		kind = "ellipsoid",
		center = { x = 0.7, y = 0.4, z = 0.9 },
		radii = { x = 0.5, y = 0.45, z = 0.5 },
		color = ACCENT,
	},
	{
		kind = "capsule",
		a = { x = 0, y = -0.4, z = -1 },
		b = { x = 0, y = -1.6, z = -1.6 },
		radius = 0.4,
		color = BODY,
	},
	{
		kind = "cone",
		base = { x = 0, y = 0.1, z = -1.3 },
		tip = { x = 0, y = 0.3, z = -2.3 },
		radius = 0.4,
		color = ACCENT,
	},
}

return {
	["new builder starts empty"] = function()
		local mesh = MeshBuilder.new():build()
		assert(mesh.triangleCount == 0, "no triangles")
		assert(#mesh.vertices == 0, "no vertices")
		assert(mesh.bounds.min.x == 0 and mesh.bounds.max.x == 0, "empty bounds at origin")
	end,

	["addBox emits twelve triangles"] = function()
		local b = MeshBuilder.new()
		b:addBox({ x = 0, y = 0, z = 0 }, { x = 2, y = 2, z = 2 }, BODY)
		local mesh = b:build()
		assert(mesh.triangleCount == 12, "box has 12 triangles, got " .. tostring(mesh.triangleCount))
		assertValid(mesh)
	end,

	["addEllipsoid emits a valid closed mesh"] = function()
		local b = MeshBuilder.new()
		b:addEllipsoid({ x = 1, y = 0, z = 0 }, { x = 2, y = 1, z = 1 }, BODY, 8)
		local mesh = b:build()
		assertValid(mesh)
		assert(math.abs(mesh.bounds.min.x - -1) < 1e-9, "min x")
		assert(math.abs(mesh.bounds.max.x - 3) < 1e-9, "max x")
	end,

	["ellipsoid normals match the analytic gradient for unequal translated radii"] = function()
		for _, center in { { x = 0, y = 0, z = 0 }, { x = 5, y = -3, z = 7 } } do
			for _, radii in { { x = 2, y = 1, z = 1 }, { x = 0.5, y = 3, z = 1.25 }, { x = 4, y = 0.75, z = 2 } } do
				for _, segments in { 3, 5, 8, 12 } do
					local b = MeshBuilder.new()
					b:addEllipsoid(center, radii, BODY, segments)
					local mesh = b:build()
					assertEllipsoid(mesh, center, radii)
					local lat = math.max(2, math.floor(segments / 2))
					assert(mesh.triangleCount == 2 * segments * (lat - 1), "ellipsoid tessellation unchanged")
				end
			end
		end
	end,

	["sphere normals stay radial at every vertex including poles and seam"] = function()
		local center = { x = -2, y = 3, z = -4 }
		for _, radius in { 0.5, 1, 3 } do
			local b = MeshBuilder.new()
			b:addEllipsoid(center, { x = radius, y = radius, z = radius }, BODY, 8)
			assertEllipsoid(b:build(), center, { x = radius, y = radius, z = radius })
		end
	end,

	["mirrorX preserves unequal ellipsoid normals and outward winding"] = function()
		local b = MeshBuilder.new()
		local center, radii = { x = 5, y = 0, z = 0 }, { x = 2, y = 0.75, z = 1.25 }
		b:addEllipsoid(center, radii, BODY, 12)
		local original = b:build()
		assertEllipsoid(original, center, radii)
		b:mirrorX()
		local mirrored = b:build()
		assertValid(mirrored)
		assertOutward(mirrored, center.x)
		assert(mirrored.triangleCount == 2 * original.triangleCount, "mirroring doubles triangles")
		for index, p in original.vertices do
			local q, n, m =
				mirrored.vertices[index + #original.vertices],
				original.normals[index],
				mirrored.normals[index + #original.vertices]
			assert(q.x == -p.x and q.y == p.y and q.z == p.z, "mirrored vertex is reflected")
			assert(m.x == -n.x and m.y == n.y and m.z == n.z, "analytic normal is reflected with its vertex")
		end
	end,

	["addCapsule emits a valid mesh"] = function()
		local b = MeshBuilder.new()
		b:addCapsule({ x = 0, y = 0, z = 0 }, { x = 0, y = 3, z = 0 }, 0.5, BODY, 8)
		assertValid(b:build())
	end,

	["addCone emits a valid mesh"] = function()
		local b = MeshBuilder.new()
		b:addCone({ x = 0, y = 0, z = 0 }, { x = 0, y = 2, z = 0 }, 1, ACCENT, 12)
		assertValid(b:build())
	end,

	["multiple primitives stay valid together"] = function()
		local b = MeshBuilder.new()
		b:addEllipsoid({ x = 0, y = 0, z = 0 }, { x = 1, y = 1, z = 1 }, BODY, 6)
		b:addBox({ x = 2, y = 0, z = 0 }, { x = 1, y = 1, z = 1 }, ACCENT)
		b:addCapsule({ x = -2, y = 0, z = 0 }, { x = -2, y = 2, z = 0 }, 0.3, BODY, 6)
		b:addCone({ x = 0, y = 2, z = 0 }, { x = 0, y = 3, z = 0 }, 0.4, ACCENT, 6)
		assertValid(b:build())
	end,

	["rejects segments below three"] = function()
		local b = MeshBuilder.new()
		assert(not pcall(function()
			b:addEllipsoid({ x = 0, y = 0, z = 0 }, { x = 1, y = 1, z = 1 }, BODY, 2)
		end), "ellipsoid segments below three rejected")
		assert(not pcall(function()
			b:addCone({ x = 0, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, 1, ACCENT, 0)
		end), "cone segments below three rejected")
	end,

	["mirrorX doubles triangles and vertices"] = function()
		local b = MeshBuilder.new()
		b:addBox({ x = 5, y = 0, z = 0 }, { x = 2, y = 2, z = 2 }, BODY)
		local beforeTriangles = b:build().triangleCount
		local beforeVertices = #b.vertices
		local beforePrimitives = #b.primitives
		b:mirrorX()
		local after = b:build()
		assert(after.triangleCount == beforeTriangles * 2, "triangles double")
		assert(#after.vertices == beforeVertices * 2, "vertices double")
		assert(#after.primitives == beforePrimitives * 2, "primitives double")
	end,

	["build returns a snapshot: later mutation on the builder does not change an already-returned mesh"] = function()
		local b = MeshBuilder.new()
		b:addBox({ x = 0, y = 0, z = 0 }, { x = 2, y = 2, z = 2 }, BODY)
		local mesh = b:build()
		assert(mesh.triangleCount == 12, "box has 12 triangles before mirroring")
		b:mirrorX()
		assert(mesh.triangleCount == 12, "a mesh already returned by build must not change after mirrorX")
		assert(#mesh.triangles == 12, "triangleCount must always equal #triangles, got " .. tostring(#mesh.triangles))
		assert(#mesh.vertices == 36, "vertex array must also stay a snapshot, got " .. tostring(#mesh.vertices))
	end,

	["build snapshots primitives too: a later addBox does not grow an already-returned mesh's primitive list"] = function()
		local b = MeshBuilder.new()
		b:addBox({ x = 0, y = 0, z = 0 }, { x = 1, y = 1, z = 1 }, BODY)
		local mesh = b:build()
		local before = #mesh.primitives
		b:addBox({ x = 5, y = 0, z = 0 }, { x = 1, y = 1, z = 1 }, ACCENT)
		assert(#mesh.primitives == before, "primitives list must stay a snapshot")
	end,

	["mirrorX mirrors bounds across x zero"] = function()
		local b = MeshBuilder.new()
		b:addEllipsoid({ x = 3, y = 0, z = 0 }, { x = 1, y = 1, z = 1 }, BODY, 8)
		b:mirrorX()
		local mesh = b:build()
		assert(math.abs(mesh.bounds.min.x - -4) < 1e-9, "min x mirrored")
		assert(math.abs(mesh.bounds.max.x - 4) < 1e-9, "max x mirrored")
	end,

	["mirrorX keeps winding outward"] = function()
		local b = MeshBuilder.new()
		b:addBox({ x = 5, y = 0, z = 0 }, { x = 2, y = 2, z = 2 }, BODY)
		assertOutward(b:build(), 5)
		b:mirrorX()
		assertOutward(b:build(), 5)
	end,

	["skinned builds a watertight smooth surface"] = function()
		local mesh = MeshBuilder.skinned(SKIN_PRIMS, 14, { bellyColor = { r = 0.95, g = 0.85, b = 0.6 } })
		assert(mesh.triangleCount > 0, "skinned produced triangles")
		assertValid(mesh)
		assert(
			openEdges(mesh) == 0,
			"every edge is shared by exactly two triangles, open edges: " .. tostring(openEdges(mesh))
		)
		assert(#mesh.primitives == #SKIN_PRIMS, "skinned records its source primitives for the Part fallback")
	end,

	["skinned normals follow the SDF gradient outward"] = function()
		local mesh = MeshBuilder.skinned({
			{
				kind = "ellipsoid",
				center = { x = 0, y = 0, z = 0 },
				radii = { x = 1, y = 1, z = 1 },
				color = BODY,
			},
		}, 12)
		for index, p in mesh.vertices do
			local n = mesh.normals[index]
			assert(p.x * n.x + p.y * n.y + p.z * n.z > 0, "normal points away from the sphere centre")
		end
	end,

	["skinned is deterministic"] = function()
		local a = MeshBuilder.skinned(SKIN_PRIMS, 12)
		local b = MeshBuilder.skinned(SKIN_PRIMS, 12)
		assert(a.triangleCount == b.triangleCount, "same triangle count")
		assert(#a.vertices == #b.vertices, "same vertex count")
		for i = 1, #a.vertices do
			local p, q = a.vertices[i], b.vertices[i]
			assert(p.x == q.x and p.y == q.y and p.z == q.z, "vertex " .. tostring(i) .. " is reproducible")
		end
	end,

	["skinned rejects empty input and tiny resolutions"] = function()
		assert(not pcall(function()
			MeshBuilder.skinned({}, 10)
		end), "empty primitive list rejected")
		assert(not pcall(function()
			MeshBuilder.skinned(SKIN_PRIMS, 1)
		end), "resolution below two rejected")
	end,

	["addMesh appends geometry and offsets indices"] = function()
		local b = MeshBuilder.new()
		b:addBox({ x = 0, y = 0, z = 0 }, { x = 1, y = 1, z = 1 }, BODY)
		local first = b:build()
		local firstVertices = #first.vertices
		local firstTriangles = first.triangleCount
		b:addMesh(first)
		local mesh = b:build()
		assert(mesh.triangleCount == firstTriangles * 2, "triangles double")
		assert(#mesh.vertices == firstVertices * 2, "vertices double")
		for _, triangle in mesh.triangles do
			for _, index in triangle do
				assert(index >= 1 and index <= #mesh.vertices, "offset indices stay in range")
			end
		end
	end,
}
