--!strict
-- Specs for rasterize: a cube fills pixels, and the z-buffer keeps the nearer
-- surface regardless of triangle submission order.

local MeshBuilder = require("../../../core/domain/procgen/MeshBuilder")
local Rasterize = require("./rasterize")

local BACKGROUND = { r = 0, g = 0, b = 0, a = 1 }

local function boxBuilder(
	center: MeshBuilder.Vec3,
	size: MeshBuilder.Vec3,
	color: MeshBuilder.Color
): MeshBuilder.Builder
	local b = MeshBuilder.new()
	b:addBox(center, size, color)
	return b
end

local function filledPixels(canvas: any): number
	local filled = 0
	for y = 0, canvas.height - 1 do
		for x = 0, canvas.width - 1 do
			local r, g, b = canvas:get(x, y)
			if r + g + b > 0.02 then
				filled += 1
			end
		end
	end
	return filled
end

return {
	["a cube covers a chunk of the frame"] = function()
		local mesh = boxBuilder({ x = 0, y = 0, z = 0 }, { x = 2, y = 2, z = 2 }, { r = 1, g = 0.6, b = 0.2 }):build()
		local canvas =
			Rasterize.render(mesh, { width = 64, height = 64, yaw = 0.6, pitch = 0.4, background = BACKGROUND })
		local filled = filledPixels(canvas)
		assert(filled > 400, "cube fills pixels, got " .. tostring(filled))
		local r, g, b = canvas:get(32, 32)
		assert(r + g + b > 0.02, "the center of the cube is painted")
	end,

	["an empty mesh renders only the background"] = function()
		local canvas = Rasterize.render(MeshBuilder.new():build(), { width = 16, height = 16, background = BACKGROUND })
		assert(filledPixels(canvas) == 0, "no geometry paints nothing")
	end,

	["the z-buffer keeps the nearer surface in either order"] = function()
		local near = boxBuilder({ x = 0, y = 0, z = 1 }, { x = 2, y = 2, z = 2 }, { r = 1, g = 0, b = 0 })
		local far = boxBuilder({ x = 0, y = 0, z = -1 }, { x = 2, y = 2, z = 2 }, { r = 0, g = 0, b = 1 })
		local forward = MeshBuilder.new()
		forward:addMesh(far:build())
		forward:addMesh(near:build())
		local reverse = MeshBuilder.new()
		reverse:addMesh(near:build())
		reverse:addMesh(far:build())

		local opts = { width = 32, height = 32, yaw = 0, pitch = 0, background = BACKGROUND, ambient = 1 }
		local r1, _, b1 = Rasterize.render(forward:build(), opts):get(16, 16)
		assert(r1 > b1, "the nearer red box wins")
		local r2, _, b2 = Rasterize.render(reverse:build(), opts):get(16, 16)
		assert(r2 > b2, "depth test is independent of triangle order")
		assert(r1 == r2 and b1 == b2, "both orders give the same pixel")
	end,

	["the contact sheet tiles every canvas"] = function()
		local mesh = boxBuilder({ x = 0, y = 0, z = 0 }, { x = 2, y = 2, z = 2 }, { r = 0.4, g = 0.8, b = 0.4 }):build()
		local a = Rasterize.render(mesh, { width = 16, height = 16, background = BACKGROUND })
		local b = Rasterize.render(mesh, { width = 16, height = 16, yaw = math.pi / 2, background = BACKGROUND })
		local sheet = Rasterize.sheet({ a, b }, { columns = 2, gap = 2, background = BACKGROUND })
		assert(sheet.width == 2 * 16 + 3 * 2, "sheet width fits two tiles and the gaps")
		assert(sheet.height == 16 + 2 * 2, "sheet height fits one row and the gaps")
		local r, g, bl = sheet:get(2 + 8, 2 + 8)
		assert(r + g + bl > 0.02, "the first tile is blitted into the sheet")
	end,
}
