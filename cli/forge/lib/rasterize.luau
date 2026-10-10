--!strict
-- rasterize: pure-Luau software renderer for framework self-review of the
-- procedural meshes. An orthographic camera at a yaw/pitch projects the mesh,
-- a z-buffer resolves visibility per pixel, and a Lambert + ambient term shades
-- interpolated vertex normals against interpolated vertex colors. Output is a
-- core/domain/procgen/Pixels canvas, so the CLI dumps PPM previews under Lune
-- and the same code can preview on the client. No Roblox APIs, no math.random.

local Pixels = require("../../../core/domain/procgen/Pixels")

local M = {}

export type Vec3 = { x: number, y: number, z: number }

export type Options = {
	width: number?,
	height: number?,
	-- Radians. yaw = 0 faces the +z side (the front of every creature).
	yaw: number?,
	-- Radians. Positive pitch looks down from above.
	pitch: number?,
	-- Screen pixels per world unit; auto-fits the mesh when omitted.
	zoom: number?,
	-- Fraction of the frame kept clear when auto-fitting (default 0.12).
	margin: number?,
	background: any?,
	ambient: number?,
	light: Vec3?,
	-- Optional second Lambert term (rim/fill light) blended in at `intensity`,
	-- e.g. a cool light from behind/opposite the key light so a silhouette's
	-- unlit edge still reads instead of falling to pure ambient.
	fillLight: { direction: Vec3, intensity: number }?,
}

export type SheetOptions = {
	columns: number?,
	gap: number?,
	background: any?,
}

local DEFAULT_WIDTH = 256
local DEFAULT_HEIGHT = 256
local DEFAULT_BACKGROUND = { r = 0.1, g = 0.11, b = 0.14, a = 1 }
local DEFAULT_AMBIENT = 0.32
local DEFAULT_LIGHT: Vec3 = { x = -0.38, y = 0.62, z = 0.69 }

local function clamp01(value: number): number
	if value < 0 then
		return 0
	elseif value > 1 then
		return 1
	end
	return value
end

local function normalize(v: Vec3): Vec3
	local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if len < 1e-12 then
		return { x = 0, y = 1, z = 0 }
	end
	return { x = v.x / len, y = v.y / len, z = v.z / len }
end

--- Renders `mesh` (MeshBuilder.MeshData: vertices, normals, colors, triangles)
--- into a fresh Pixels canvas of `width` x `height`.
function M.render(mesh: any, opts: Options?): Pixels.Canvas
	local options: Options = opts or {}
	local width = options.width or DEFAULT_WIDTH
	local height = options.height or DEFAULT_HEIGHT
	local yaw = options.yaw or 0
	local pitch = options.pitch or 0
	local ambient = options.ambient or DEFAULT_AMBIENT
	local light = normalize(options.light or DEFAULT_LIGHT)
	local background = options.background or DEFAULT_BACKGROUND
	local fillLight = options.fillLight
	local fillDir = if fillLight ~= nil then normalize(fillLight.direction) else nil
	local fillIntensity = if fillLight ~= nil then fillLight.intensity else 0

	local count = #mesh.vertices
	local canvas = Pixels.new(width, height)
	canvas:fill(background)
	if count == 0 then
		return canvas
	end

	-- Object space -> camera space: yaw about Y, then pitch about X. The camera
	-- sits at +z looking toward -z, so depth = -z (smaller is nearer) and screen
	-- y is flipped for the top-left canvas origin.
	local cy, sy = math.cos(yaw), math.sin(yaw)
	local cp, sp = math.cos(pitch), math.sin(pitch)
	local posX = table.create(count, 0)
	local posY = table.create(count, 0)
	local posZ = table.create(count, 0)
	local nrmX = table.create(count, 0)
	local nrmY = table.create(count, 0)
	local nrmZ = table.create(count, 0)
	local minX, maxX = math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge
	for i = 1, count do
		local p = mesh.vertices[i]
		local x1 = p.x * cy + p.z * sy
		local z1 = -p.x * sy + p.z * cy
		local y2 = p.y * cp - z1 * sp
		local z2 = p.y * sp + z1 * cp
		posX[i] = x1
		posY[i] = y2
		posZ[i] = -z2
		if x1 < minX then
			minX = x1
		end
		if x1 > maxX then
			maxX = x1
		end
		if y2 < minY then
			minY = y2
		end
		if y2 > maxY then
			maxY = y2
		end

		local n = mesh.normals[i]
		local nx1 = n.x * cy + n.z * sy
		local nz1 = -n.x * sy + n.z * cy
		local ny2 = n.y * cp - nz1 * sp
		local nz2 = n.y * sp + nz1 * cp
		nrmX[i] = nx1
		nrmY[i] = ny2
		nrmZ[i] = -nz2
	end

	local extentX = math.max(maxX - minX, 1e-6)
	local extentY = math.max(maxY - minY, 1e-6)
	local margin = options.margin or 0.12
	local autoZoom = math.min(width * (1 - margin) / extentX, height * (1 - margin) / extentY)
	local zoom = options.zoom or autoZoom
	local centerX = (minX + maxX) / 2
	local centerY = (minY + maxY) / 2
	local halfWidth = width / 2
	local halfHeight = height / 2

	local depth = table.create(width * height, math.huge)
	local data = canvas.data

	for _, triangle in mesh.triangles do
		local i0, i1, i2 = triangle[1], triangle[2], triangle[3]
		local x0 = halfWidth + (posX[i0] - centerX) * zoom
		local y0 = halfHeight - (posY[i0] - centerY) * zoom
		local x1 = halfWidth + (posX[i1] - centerX) * zoom
		local y1 = halfHeight - (posY[i1] - centerY) * zoom
		local x2 = halfWidth + (posX[i2] - centerX) * zoom
		local y2 = halfHeight - (posY[i2] - centerY) * zoom
		local area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
		if math.abs(area) < 1e-9 then
			continue
		end
		if area < 0 then
			i1, i2 = i2, i1
			x1, x2 = x2, x1
			y1, y2 = y2, y1
			area = -area
		end
		local invArea = 1 / area

		local minPX = math.max(0, math.floor(math.min(x0, math.min(x1, x2))))
		local maxPX = math.min(width - 1, math.ceil(math.max(x0, math.max(x1, x2))))
		local minPY = math.max(0, math.floor(math.min(y0, math.min(y1, y2))))
		local maxPY = math.min(height - 1, math.ceil(math.max(y0, math.max(y1, y2))))

		local d0, d1, d2 = posZ[i0], posZ[i1], posZ[i2]
		local c0, c1, c2 = mesh.colors[i0], mesh.colors[i1], mesh.colors[i2]
		local ax, ay, az = nrmX[i0], nrmY[i0], nrmZ[i0]
		local bx, by, bz = nrmX[i1], nrmY[i1], nrmZ[i1]
		local cx, cyv, cz = nrmX[i2], nrmY[i2], nrmZ[i2]

		for py = minPY, maxPY do
			local sampleY = py + 0.5
			for px = minPX, maxPX do
				local sampleX = px + 0.5
				local w0 = ((x1 - sampleX) * (y2 - sampleY) - (x2 - sampleX) * (y1 - sampleY)) * invArea
				if w0 < 0 then
					continue
				end
				local w1 = ((x2 - sampleX) * (y0 - sampleY) - (x0 - sampleX) * (y2 - sampleY)) * invArea
				if w1 < 0 then
					continue
				end
				local w2 = 1 - w0 - w1
				if w2 < 0 then
					continue
				end
				local z = w0 * d0 + w1 * d1 + w2 * d2
				local pixel = py * width + px + 1
				if z < depth[pixel] then
					depth[pixel] = z
					local nx = w0 * ax + w1 * bx + w2 * cx
					local ny = w0 * ay + w1 * by + w2 * cyv
					local nz = w0 * az + w1 * bz + w2 * cz
					local len = math.sqrt(nx * nx + ny * ny + nz * nz)
					local ndl = 0
					if len > 1e-9 then
						ndl = (nx * light.x + ny * light.y + nz * light.z) / len
					end
					if ndl < 0 then
						ndl = 0
					end
					local k = ambient + (1 - ambient) * ndl
					if fillDir ~= nil and len > 1e-9 then
						local ndf = (nx * fillDir.x + ny * fillDir.y + nz * fillDir.z) / len
						if ndf > 0 then
							k += ndf * fillIntensity
						end
					end
					local base = (py * width + px) * 4
					data[base + 1] = clamp01((w0 * c0.r + w1 * c1.r + w2 * c2.r) * k)
					data[base + 2] = clamp01((w0 * c0.g + w1 * c1.g + w2 * c2.g) * k)
					data[base + 3] = clamp01((w0 * c0.b + w1 * c1.b + w2 * c2.b) * k)
					data[base + 4] = 1
				end
			end
		end
	end

	return canvas
end

--- Tiles equal-sized canvases into one contact sheet, row-major.
function M.sheet(tiles: { Pixels.Canvas }, opts: SheetOptions?): Pixels.Canvas
	local options: SheetOptions = opts or {}
	local columns = options.columns or math.ceil(math.sqrt(#tiles))
	if columns < 1 then
		columns = 1
	end
	local gap = options.gap or 8
	local background = options.background or DEFAULT_BACKGROUND
	local tileW = tiles[1].width
	local tileH = tiles[1].height
	local rows = math.ceil(#tiles / columns)
	local canvas = Pixels.new(columns * tileW + (columns + 1) * gap, rows * tileH + (rows + 1) * gap)
	canvas:fill(background)
	for index, tile in tiles do
		local column = (index - 1) % columns
		local row = (index - 1) // columns
		canvas:blit(tile, gap + column * (tileW + gap), gap + row * (tileH + gap))
	end
	return canvas
end

return M
