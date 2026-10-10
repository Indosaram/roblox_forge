--!strict
-- Specs for Creature: per-archetype validity, budgets, and seed determinism.

local Creature = require("./Creature")

local BODY = { r = 0.4, g = 0.5, b = 0.3 }
local ACCENT = { r = 0.85, g = 0.35, b = 0.2 }
local EYE = { r = 0.1, g = 0.9, b = 0.15 }

local ARCHETYPES: { Creature.Archetype } = { "quad", "serpent", "titan", "biped" }

local function spec(archetype: string, budget: number): Creature.Spec
	return {
		archetype = archetype :: Creature.Archetype,
		scale = 1,
		body = BODY,
		accent = ACCENT,
		eye = EYE,
		polyBudget = budget,
	}
end

local function assertValid(mesh: any): ()
	local function magnitude(v: any): number
		return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	end
	assert(#mesh.vertices > 0, "mesh has vertices")
	assert(mesh.triangleCount == #mesh.triangles, "triangleCount matches #triangles")
	for _, triangle in mesh.triangles do
		for _, index in triangle do
			assert(index >= 1 and index <= #mesh.vertices, "triangle index in range")
		end
	end
	for _, normal in mesh.normals do
		assert(math.abs(magnitude(normal) - 1) < 1e-6, "normal is unit length")
	end
end

local function sameMesh(a: any, b: any): boolean
	if a.triangleCount ~= b.triangleCount or #a.vertices ~= #b.vertices then
		return false
	end
	for i = 1, #a.vertices do
		local p, q = a.vertices[i], b.vertices[i]
		if p.x ~= q.x or p.y ~= q.y or p.z ~= q.z then
			return false
		end
	end
	return true
end

return {
	["every archetype fits a 600 triangle budget"] = function()
		for _, archetype in ARCHETYPES do
			local mesh = Creature.generate(spec(archetype, 600), 1)
			assert(mesh.triangleCount > 0, archetype .. " produced triangles")
			assert(mesh.triangleCount <= 600, archetype .. " over 600: " .. tostring(mesh.triangleCount))
			assertValid(mesh)
		end
	end,

	["every archetype fits a 3000 triangle budget"] = function()
		for _, archetype in ARCHETYPES do
			local mesh = Creature.generate(spec(archetype, 3000), 1)
			assert(mesh.triangleCount > 0, archetype .. " produced triangles")
			assert(mesh.triangleCount <= 3000, archetype .. " over 3000: " .. tostring(mesh.triangleCount))
			assertValid(mesh)
		end
	end,

	["a budget too small for even the minimum resolution is flagged overBudget, not silently exceeded"] = function()
		local mesh = Creature.generate(spec("quad", 1), 1)
		assert(mesh.triangleCount > 1, "minimum resolution still produces geometry over the tiny budget")
		assert(mesh.overBudget == true, "a mesh that cannot fit its budget must report overBudget")
	end,

	["a fitting budget never sets overBudget"] = function()
		for _, archetype in ARCHETYPES do
			local mesh = Creature.generate(spec(archetype, 3000), 1)
			assert(mesh.overBudget == false, archetype .. " fits its budget and must not report overBudget")
		end
	end,

	["generate is deterministic for the same seed"] = function()
		for _, archetype in ARCHETYPES do
			local a = Creature.generate(spec(archetype, 3000), 42)
			local b = Creature.generate(spec(archetype, 3000), 42)
			assert(sameMesh(a, b), archetype .. " is deterministic")
		end
	end,

	["different seeds produce different geometry"] = function()
		for _, archetype in ARCHETYPES do
			local a = Creature.generate(spec(archetype, 3000), 1)
			local b = Creature.generate(spec(archetype, 3000), 2)
			assert(not sameMesh(a, b), archetype .. " varies with the seed")
		end
	end,

	["every archetype keeps white eyes and dark pupils"] = function()
		for _, archetype in ARCHETYPES do
			local mesh = Creature.generate(spec(archetype, 3000), 3)
			local hasWhite = false
			local hasPupil = false
			for _, color in mesh.colors do
				if color.r > 0.95 and color.g > 0.95 and color.b > 0.95 then
					hasWhite = true
				elseif color.r < 0.12 and color.g < 0.12 and color.b < 0.12 then
					hasPupil = true
				end
			end
			assert(hasWhite, archetype .. " has white sclera geometry")
			assert(hasPupil, archetype .. " has dark pupil geometry")
		end
	end,

	["every pupil is a round lens proud of its sclera"] = function()
		for _, archetype in ARCHETYPES do
			local mesh = Creature.generate(spec(archetype, 3000), 3)
			local checked = 0
			for _, prim in mesh.primitives do
				local isPupil = prim.kind == "ellipsoid"
					and prim.center ~= nil
					and prim.radii ~= nil
					and prim.color.r < 0.12
					and prim.color.g < 0.12
					and prim.color.b < 0.12
				if not isPupil then
					continue
				end
				local pupil = prim :: any
				-- The sclera is the larger white ellipsoid sharing the pupil's centre.
				local sclera = nil
				for _, other in mesh.primitives do
					local isWhite = other.kind == "ellipsoid"
						and other.center ~= nil
						and other.radii ~= nil
						and other.color.r > 0.95
						and other.color.g > 0.95
						and other.color.b > 0.95
						and other.radii.x > pupil.radii.x
					if isWhite then
						local candidate = other :: any
						if
							math.abs(candidate.center.x - pupil.center.x) < 0.01
							and math.abs(candidate.center.y - pupil.center.y) < 0.01
						then
							sclera = candidate
						end
					end
				end
				if sclera ~= nil then
					checked += 1
					assert(
						pupil.center.z + pupil.radii.z > sclera.center.z + sclera.radii.z,
						archetype .. " pupil sits proud of the sclera"
					)
				end
			end
			assert(checked == 2, archetype .. " has two pupils on scleras, got " .. tostring(checked))
		end
	end,

	["unknown archetype errors"] = function()
		local ok = pcall(function()
			Creature.generate(
				{ archetype = "dragon" :: any, scale = 1, body = BODY, accent = ACCENT, eye = EYE, polyBudget = 600 },
				1
			)
		end)
		assert(not ok, "unknown archetype rejected")
	end,

	["non-positive budget errors"] = function()
		local ok = pcall(function()
			Creature.generate(spec("quad", 0), 1)
		end)
		assert(not ok, "zero budget rejected")
	end,
}
