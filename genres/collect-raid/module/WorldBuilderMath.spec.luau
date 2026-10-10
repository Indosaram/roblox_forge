--!strict
-- Specs for the pure WorldBuilderMath scatter and placement helpers.

local Math = require("./WorldBuilderMath")

local function makeSpec(): Math.ScatterSpec
	return {
		region = { minX = -100, maxX = 100, minZ = -100, maxZ = 100 },
		exclusions = {
			{ x = 0, z = 0, inner = 0, outer = 30 },
		},
		bands = {
			{ kind = "Tree", count = 20, minSpacing = 12, scaleMin = 8, scaleMax = 14, yFactor = 0.9 },
			{ kind = "Rock", count = 20, minSpacing = 8, scaleMin = 3, scaleMax = 7 },
		},
		maxAttempts = 2000,
	}
end

local function samePoint(a: Math.ScatterPoint, b: Math.ScatterPoint): boolean
	return a.kind == b.kind
		and a.position.x == b.position.x
		and a.position.y == b.position.y
		and a.position.z == b.position.z
		and a.scale.x == b.scale.x
		and a.scale.y == b.scale.y
		and a.scale.z == b.scale.z
		and a.seed == b.seed
end

return {
	["scatter is deterministic for a fixed seed"] = function()
		local a = Math.scatter(makeSpec(), 4242)
		local b = Math.scatter(makeSpec(), 4242)
		assert(#a == #b, "the same seed gives the same count")
		for i = 1, #a do
			assert(samePoint(a[i], b[i]), "point " .. i .. " must match")
		end
	end,

	["scatter changes with the seed"] = function()
		local a = Math.scatter(makeSpec(), 1)
		local b = Math.scatter(makeSpec(), 2)
		local differs = #a ~= #b
		if not differs then
			for i = 1, #a do
				if not samePoint(a[i], b[i]) then
					differs = true
					break
				end
			end
		end
		assert(differs, "a different seed must move at least one point")
	end,

	["scatter hits every band count within ten percent"] = function()
		local spec = makeSpec()
		local points = Math.scatter(spec, 99)
		for _, band in spec.bands do
			local count = 0
			for _, point in points do
				if point.kind == band.kind then
					count += 1
				end
			end
			local low = math.floor(band.count * 0.9)
			assert(count >= low, band.kind .. " placed " .. count .. ", expected at least " .. low)
		end
	end,

	["scatter respects min spacing"] = function()
		local spec = makeSpec()
		local spacing: { [string]: number } = {}
		for _, band in spec.bands do
			spacing[band.kind] = band.minSpacing
		end
		local points = Math.scatter(spec, 7)
		for i = 1, #points do
			for j = i + 1, #points do
				local dx = points[i].position.x - points[j].position.x
				local dz = points[i].position.z - points[j].position.z
				local need = math.max(spacing[points[i].kind], spacing[points[j].kind])
				assert(dx * dx + dz * dz >= need * need, "points " .. i .. " and " .. j .. " are too close")
			end
		end
	end,

	["scatter keeps props out of exclusion zones"] = function()
		local spec = makeSpec()
		for _, point in Math.scatter(spec, 5) do
			for _, zone in spec.exclusions do
				local dx = point.position.x - zone.x
				local dz = point.position.z - zone.z
				local d = math.sqrt(dx * dx + dz * dz)
				assert(d > zone.outer or d < zone.inner, "a point landed inside an exclusion zone")
			end
		end
	end,

	["scatter keeps scales in range and off the ground plane"] = function()
		local spec = makeSpec()
		local byKind: { [string]: Math.ScatterBand } = {}
		for _, band in spec.bands do
			byKind[band.kind] = band
		end
		for _, point in Math.scatter(spec, 11) do
			local band = byKind[point.kind]
			local size = math.max(point.scale.x, point.scale.y, point.scale.z)
			assert(size <= band.scaleMax + 1e-9, point.kind .. " scale above range")
			assert(size >= band.scaleMin - 1e-9, point.kind .. " scale below range")
			assert(point.position.y > 0, "props sit above the ground")
		end
	end,

	["bleacher pieces build three rising tiers"] = function()
		local steps = {}
		for _, piece in Math.bleacherPieces() do
			if piece.role == "step" then
				table.insert(steps, piece)
			end
		end
		assert(#steps == 3, "three steps")
		for i = 2, #steps do
			assert(steps[i].offset.y > steps[i - 1].offset.y, "each step rises above the last")
			assert(steps[i].offset.z < steps[i - 1].offset.z, "each step sits farther from the arena")
		end
	end,

	["flower patch rings three petals around its center"] = function()
		local petals = Math.flowerPatch({ x = 10, y = 0, z = -4 }, 2, 1.25)
		assert(#petals == 3, "three petals per patch")
		for i, petal in petals do
			local dx = petal.position.x - 10
			local dz = petal.position.z + 4
			local d = math.sqrt(dx * dx + dz * dz)
			assert(d > 0 and d <= 2, "petal " .. i .. " stays within the patch")
			assert(petal.size.x > 0, "petal has a size")
		end
	end,
}
