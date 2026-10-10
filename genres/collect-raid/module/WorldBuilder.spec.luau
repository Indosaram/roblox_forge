--!strict
-- Specs for the pure WorldBuilder geometry helpers. No Roblox APIs: WorldBuilder
-- itself touches Instances, so only WorldBuilderMath is exercised here.

local Math = require("./WorldBuilderMath")

local GROUND: Math.Ground = { cells = 16, cellSize = 25, originX = -200, originZ = -200 }

return {
	["ground cells tile the grid from the origin corner"] = function()
		local first = Math.groundCellPosition(GROUND, 0, 0)
		assert(first.x == -187.5, "first cell x is half a cell past the origin")
		assert(first.z == -187.5, "first cell z is half a cell past the origin")

		local last = Math.groundCellPosition(GROUND, 15, 15)
		assert(last.x == 187.5, "last cell x closes the 400-stud grid")
		assert(last.z == 187.5, "last cell z closes the 400-stud grid")
	end,

	["ground cells alternate in a checkerboard"] = function()
		assert(Math.groundCellVariant(0, 0) == 1, "even sum is variant 1")
		assert(Math.groundCellVariant(1, 0) == 2, "odd sum is variant 2")
		assert(Math.groundCellVariant(0, 1) == 2, "odd sum is variant 2")
		assert(Math.groundCellVariant(1, 1) == 1, "even sum is variant 1")
	end,

	["platform trims ring the base edges"] = function()
		local trims = Math.platformTrims({ x = -140, y = 0, z = 0 }, 45)
		assert(#trims == 4, "four trim strips")

		local expected = {
			{ size = { x = 90, y = 0.4, z = 1 }, position = { x = -140, y = 1.3, z = -45 } },
			{ size = { x = 90, y = 0.4, z = 1 }, position = { x = -140, y = 1.3, z = 45 } },
			{ size = { x = 1, y = 0.4, z = 90 }, position = { x = -185, y = 1.3, z = 0 } },
			{ size = { x = 1, y = 0.4, z = 90 }, position = { x = -95, y = 1.3, z = 0 } },
		}
		for i, want in expected do
			assert(trims[i].size.x == want.size.x, "trim " .. i .. " size x")
			assert(trims[i].size.y == want.size.y, "trim " .. i .. " size y")
			assert(trims[i].size.z == want.size.z, "trim " .. i .. " size z")
			assert(trims[i].position.x == want.position.x, "trim " .. i .. " position x")
			assert(trims[i].position.y == want.position.y, "trim " .. i .. " position y")
			assert(trims[i].position.z == want.position.z, "trim " .. i .. " position z")
		end
	end,

	["radial paths end at the near rim and axis-aligned platform edge"] = function()
		local cases = {
			{ x = 140, z = 0, ax = 50, az = 0, bx = 95, bz = 0 },
			{ x = -140, z = 0, ax = -50, az = 0, bx = -95, bz = 0 },
			{ x = 0, z = 140, ax = 0, az = 50, bx = 0, bz = 95 },
			{ x = 0, z = -140, ax = 0, az = -50, bx = 0, bz = -95 },
			-- Three-team ring: square platforms exit through Z, not half studs along the ray.
			{
				x = -52.5,
				z = 105 * math.sqrt(3) / 2,
				ax = -25,
				az = 25 * math.sqrt(3),
				bx = -52.5 + 45 / math.sqrt(3),
				bz = 105 * math.sqrt(3) / 2 - 45,
			},
			{
				x = -52.5,
				z = -105 * math.sqrt(3) / 2,
				ax = -25,
				az = -25 * math.sqrt(3),
				bx = -52.5 + 45 / math.sqrt(3),
				bz = -105 * math.sqrt(3) / 2 + 45,
			},
		}
		for _, case in cases do
			local path = Math.pathBetween({ x = case.x, y = 0, z = case.z }, 45, 50)
			assert(path ~= nil, "separated footprints need a path")
			local ux, uz = math.cos(path.yaw), -math.sin(path.yaw)
			local ax, az = path.position.x - ux * path.size.x / 2, path.position.z - uz * path.size.x / 2
			local bx, bz = path.position.x + ux * path.size.x / 2, path.position.z + uz * path.size.x / 2
			assert(math.abs(ax - case.ax) < 1e-8 and math.abs(az - case.az) < 1e-8, "near arena endpoint")
			assert(math.abs(bx - case.bx) < 1e-8 and math.abs(bz - case.bz) < 1e-8, "square platform endpoint")
			assert(path.size.y == 0.2 and path.size.z == 12 and path.position.y == 0.1, "slab contract")
		end
	end,

	["paths support translated arenas and omit touching or overlapping bridges"] = function()
		local translated = Math.pathBetween({ x = 150, y = 0, z = 20 }, 45, 50, { x = 10, y = 0, z = 20 })
		assert(
			translated ~= nil and translated.position.x == 82.5 and translated.position.z == 20,
			"translated radial path"
		)
		for _, x in { 0, 40, 94, 95 } do
			assert(Math.pathBetween({ x = x, y = 0, z = 0 }, 45, 50) == nil, "no gap means no slab")
		end
		local smallGap = Math.pathBetween({ x = 70, y = 0, z = 0 }, 28, 40)
		assert(
			smallGap ~= nil and smallGap.size.x == 2 and smallGap.position.x == 41,
			"original positive-X near-edge case"
		)
	end,

	["arena floor spans the arena diameter"] = function()
		assert(Math.arenaFloorSize(50) == 100, "radius 50 gives a 100-stud floor")
	end,

	["value noise is deterministic and stays in range"] = function()
		local a = Math.valueNoise2D(3.7, -2.1, 1337)
		local b = Math.valueNoise2D(3.7, -2.1, 1337)
		assert(a == b, "the same input gives the same value")
		assert(a >= 0 and a < 1, "value noise stays in [0, 1)")
		assert(a ~= Math.valueNoise2D(3.7, -2.1, 1338), "the seed changes the field")
	end,

	["smoothstep clamps and eases"] = function()
		assert(Math.smoothstep(0, 10, -5) == 0, "below the edge is 0")
		assert(Math.smoothstep(0, 10, 15) == 1, "above the edge is 1")
		assert(Math.smoothstep(0, 10, 5) == 0.5, "the midpoint is 0.5")
	end,

	["terrain keeps the play plateau flat"] = function()
		local spec: Math.TerrainSpec = {
			half = 360,
			flatHalf = 210,
			cellSize = 16,
			baseY = 0,
			hillHeight = 26,
			waterLevel = -4,
			waterDepth = 14,
			columnDepth = 40,
			noiseScale = 0.021,
			seed = 1337,
		}
		assert(Math.terrainSurfaceY(0, 0, spec) == 0, "the arena center is flat")
		assert(Math.terrainSurfaceY(209, -209, spec) == 0, "the whole plateau is flat")
		assert(Math.terrainSurfaceY(211, 0, spec) ~= 0, "hills start past the plateau")
	end,

	["terrain columns tile the area and flood the rim"] = function()
		local spec: Math.TerrainSpec = {
			half = 40,
			flatHalf = 16,
			cellSize = 8,
			baseY = 0,
			hillHeight = 26,
			waterLevel = -4,
			waterDepth = 14,
			columnDepth = 40,
			noiseScale = 0.05,
			seed = 7,
		}
		local cols = Math.terrainColumns(spec)
		assert(#cols == 100, "10x10 columns tile an 80-stud square")
		local corner = cols[1]
		assert(corner.x == -36 and corner.z == -36, "the first column sits at the origin corner")
		assert(corner.waterTop == spec.waterLevel, "the far corner floods to the water level")
		for _, col in cols do
			assert(col.bottom == col.top - spec.columnDepth, "every column has a solid depth")
		end
	end,

	["fences ring three sides and leave the gate open"] = function()
		local segs = Math.fenceSegments({ x = 0, y = 0, z = 0 }, 45, 5, 15, { x = 1, y = 0, z = 0 })
		local posts, railsAcrossX, railsAcrossZ = 0, 0, 0
		for _, seg in segs do
			if seg.size.y == 5 then
				posts += 1
			elseif seg.size.x == 90 then
				railsAcrossX += 1
			elseif seg.size.z == 90 then
				railsAcrossZ += 1
			end
		end
		assert(posts == 21, "three fenced sides with seven posts each")
		assert(railsAcrossZ == 2, "the back edge gets two rails")
		assert(railsAcrossX == 4, "both side edges get two rails each")

		for _, seg in segs do
			assert(not (seg.size.y == 5 and seg.position.x == 45 and seg.position.z == 0), "the gate stays open")
		end
	end,

	["arena stands avoid the base-to-arena lanes"] = function()
		local stands = Math.standPlacements({ x = 0, y = 0, z = 0 }, 60, 6)
		assert(#stands == 6, "six stands ring the arena")
		for _, stand in stands do
			assert(math.abs(stand.z) > 1, "no stand sits on the z=0 lane")
		end
	end,
}
