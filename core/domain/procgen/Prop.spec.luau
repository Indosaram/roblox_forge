--!strict
-- Specs for Prop: per-kind validity, budgets, and seed determinism.

local Prop = require("./Prop")

local BODY = { r = 0.55, g = 0.45, b = 0.35 }
local ACCENT = { r = 0.9, g = 0.75, b = 0.2 }

local KINDS: { Prop.Kind } = { "egg", "crystal", "rock", "tree", "palm", "crate" }

local function spec(budget: number): Prop.Spec
	return { scale = 1, body = BODY, accent = ACCENT, polyBudget = budget }
end

local function generate(kind: string, propSpec: Prop.Spec, seed: number): any
	return Prop.generate(kind :: Prop.Kind, propSpec, seed)
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
	["every kind fits a 600 triangle budget"] = function()
		for _, kind in KINDS do
			local mesh = generate(kind, spec(600), 1)
			assert(mesh.triangleCount > 0, kind .. " produced triangles")
			assert(mesh.triangleCount <= 600, kind .. " over 600: " .. tostring(mesh.triangleCount))
			assertValid(mesh)
		end
	end,

	["every kind fits a 3000 triangle budget"] = function()
		for _, kind in KINDS do
			local mesh = generate(kind, spec(3000), 1)
			assert(mesh.triangleCount > 0, kind .. " produced triangles")
			assert(mesh.triangleCount <= 3000, kind .. " over 3000: " .. tostring(mesh.triangleCount))
			assertValid(mesh)
		end
	end,

	["a budget too small for even the minimum segment count is flagged overBudget, not silently exceeded"] = function()
		local mesh = generate("egg", spec(1), 1)
		assert(mesh.triangleCount > 1, "minimum segment count still produces geometry over the tiny budget")
		assert(mesh.overBudget == true, "a mesh that cannot fit its budget must report overBudget")
	end,

	["a fitting budget never sets overBudget"] = function()
		for _, kind in KINDS do
			local mesh = generate(kind, spec(3000), 1)
			assert(mesh.overBudget == false, kind .. " fits its budget and must not report overBudget")
		end
	end,

	["generate is deterministic for the same seed"] = function()
		for _, kind in KINDS do
			local a = generate(kind, spec(3000), 7)
			local b = generate(kind, spec(3000), 7)
			assert(sameMesh(a, b), kind .. " is deterministic")
		end
	end,

	["different seeds produce different geometry"] = function()
		for _, kind in KINDS do
			local a = generate(kind, spec(3000), 7)
			local b = generate(kind, spec(3000), 8)
			assert(not sameMesh(a, b), kind .. " varies with the seed")
		end
	end,

	["egg is taller than wide"] = function()
		local mesh = generate("egg", spec(600), 1)
		local width = mesh.bounds.max.x - mesh.bounds.min.x
		local height = mesh.bounds.max.y - mesh.bounds.min.y
		assert(height > width * 1.2, "egg is taller than wide: " .. tostring(height) .. " vs " .. tostring(width))
	end,

	["tree canopy uses the spec foliage colour, lighter at the top"] = function()
		local foliage = { r = 0.15, g = 0.85, b = 0.25 }
		local treeSpec: Prop.Spec = {
			scale = 1,
			body = { r = 0.4, g = 0.25, b = 0.12 },
			accent = { r = 0.9, g = 0.3, b = 0.2 },
			foliage = foliage,
			polyBudget = 3000,
		}
		local mesh = generate("tree", treeSpec, 302)
		local minY = mesh.bounds.min.y
		local span = mesh.bounds.max.y - minY
		local greens: { { t: number, g: number } } = {}
		for i, color in mesh.colors do
			if color.g > color.r and color.g > color.b then
				table.insert(greens, { t = (mesh.vertices[i].y - minY) / span, g = color.g })
			end
		end
		assert(#greens > 0, "tree canopy is green foliage")
		local loT, hiT = math.huge, -math.huge
		for _, v in greens do
			loT = math.min(loT, v.t)
			hiT = math.max(hiT, v.t)
		end
		local lowSum, lowN, highSum, highN = 0, 0, 0, 0
		for _, v in greens do
			if v.t < loT + (hiT - loT) * 0.25 then
				lowSum += v.g
				lowN += 1
			elseif v.t > loT + (hiT - loT) * 0.75 then
				highSum += v.g
				highN += 1
			end
		end
		assert(lowN > 0 and highN > 0, "canopy spans low and high vertices")
		assert(highSum / highN > lowSum / lowN, "canopy is lighter at the top")
	end,

	["tree foliage defaults to fresh green when the spec omits it"] = function()
		local mesh = generate("tree", spec(3000), 302)
		local hasGreen = false
		for _, color in mesh.colors do
			if color.g > color.r + 0.05 and color.g > color.b + 0.05 and color.g > 0.35 then
				hasGreen = true
				break
			end
		end
		assert(hasGreen, "default tree has green foliage")
	end,

	["crate is a closed box with proud panels on all four faces"] = function()
		local mesh = generate("crate", spec(3000), 7)
		local xPos, xNeg, zPos, zNeg = false, false, false, false
		for _, prim in mesh.primitives do
			if prim.kind == "box" and prim.center ~= nil and prim.size ~= nil and prim.size.y > 0.5 then
				if prim.center.x > 0.5 then
					xPos = true
				elseif prim.center.x < -0.5 then
					xNeg = true
				end
				if prim.center.z > 0.5 then
					zPos = true
				elseif prim.center.z < -0.5 then
					zNeg = true
				end
			end
		end
		assert(xPos and xNeg and zPos and zNeg, "panels sit proud on all four faces")
	end,

	["rock grows its accent moss on the upper half"] = function()
		local rockSpec: Prop.Spec = {
			scale = 1,
			body = { r = 0.45, g = 0.45, b = 0.44 },
			accent = { r = 0.2, g = 0.8, b = 0.25 },
			polyBudget = 3000,
		}
		local mesh = generate("rock", rockSpec, 301)
		local minY = mesh.bounds.min.y
		local span = mesh.bounds.max.y - minY
		local sum, count = 0, 0
		for i, color in mesh.colors do
			if color.g > color.r + 0.1 and color.g > color.b + 0.1 then
				sum += mesh.vertices[i].y
				count += 1
			end
		end
		assert(count > 0, "rock has moss geometry")
		assert(sum / count > minY + span * 0.5, "moss sits on the upper half")
	end,

	["unknown kind errors"] = function()
		local ok = pcall(function()
			Prop.generate("sword" :: any, spec(600), 1)
		end)
		assert(not ok, "unknown kind rejected")
	end,
}
