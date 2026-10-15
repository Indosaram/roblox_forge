--!strict
-- imagediff: pure Luau PNG decode and pixel compare, in the spirit of odiff.
--
--   * decode(bytes) reads 8-bit, non-interlaced PNGs of colour type 2 (RGB) or
--     6 (RGBA), checks every chunk CRC, inflates the IDAT stream through
--     serde.decompress("zlib") and undoes all five scanline filters (None,
--     Sub, Up, Average, Paeth). It returns (image, nil) or (nil, reason).
--   * compare(a, b, options) counts pixels whose largest per-channel delta,
--     normalised to 0..1, exceeds `threshold` (default 0.1, odiff's default).
--     Images of different sizes are compared on the union canvas: a pixel that
--     exists in only one image always differs. `ignore` rectangles are
--     inclusive x1,y1,x2,y2 pixel coordinates and are excluded from both the
--     differing count and the total; `crop` limits the compare to x,y,w,h.
--   * writeDiff(a, b, result, path) writes a PNG through ./png: the base image
--     dimmed to grey, with every differing pixel painted solid red.

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Png = require("./png")
local Pixels = require("../../../core/domain/procgen/Pixels")

local M = {}

M.DEFAULT_THRESHOLD = 0.1

local SIGNATURE = "\137PNG\r\n\26\n"
local MAX_PIXELS = 16777216

export type Image = { width: number, height: number, rgba: buffer }
export type Rect = { x1: number, y1: number, x2: number, y2: number }
export type Crop = { x: number, y: number, w: number, h: number }
export type Options = { threshold: number?, ignore: { Rect }?, crop: Crop? }
export type Result = {
	identical: boolean,
	sameSize: boolean,
	differing: number,
	total: number,
	percent: number,
	bbox: Rect?,
	width: number,
	height: number,
	-- One byte per union-canvas pixel: 1 differing, 0 otherwise.
	mask: buffer,
}

local CRC_TABLE: { number } = table.create(256, 0)
for n = 0, 255 do
	local c = n
	for _ = 1, 8 do
		if bit32.band(c, 1) == 1 then
			c = bit32.bxor(0xEDB88320, bit32.rshift(c, 1))
		else
			c = bit32.rshift(c, 1)
		end
	end
	CRC_TABLE[n] = c
end

local function crc32(data: buffer, offset: number, length: number): number
	local crc = 0xFFFFFFFF
	for i = offset, offset + length - 1 do
		local index = bit32.band(bit32.bxor(crc, buffer.readu8(data, i)), 0xFF)
		crc = bit32.bxor(CRC_TABLE[index], bit32.rshift(crc, 8))
	end
	return bit32.bxor(crc, 0xFFFFFFFF)
end

local function readU32BE(data: buffer, offset: number): number
	local high = buffer.readu8(data, offset) * 256 + buffer.readu8(data, offset + 1)
	local low = buffer.readu8(data, offset + 2) * 256 + buffer.readu8(data, offset + 3)
	return high * 65536 + low
end

local function paeth(a: number, b: number, c: number): number
	local p = a + b - c
	local pa = math.abs(p - a)
	local pb = math.abs(p - b)
	local pc = math.abs(p - c)
	if pa <= pb and pa <= pc then
		return a
	elseif pb <= pc then
		return b
	end
	return c
end

local function decodeOrError(bytes: string | buffer): Image
	local data: buffer = if type(bytes) == "string" then buffer.fromstring(bytes) else bytes
	local size = buffer.len(data)
	if size < 8 or buffer.readstring(data, 0, 8) ~= SIGNATURE then
		error("PNG_SIGNATURE", 0)
	end
	local offset = 8
	local width, height, channels = 0, 0, 0
	local compressed: { string } = {}
	local ended = false
	while offset < size do
		if offset + 12 > size then
			error("PNG_TRUNCATED", 0)
		end
		local length = readU32BE(data, offset)
		if length > size - offset - 12 then
			error("PNG_TRUNCATED", 0)
		end
		local kind = buffer.readstring(data, offset + 4, 4)
		if crc32(data, offset + 4, length + 4) ~= readU32BE(data, offset + 8 + length) then
			error("PNG_CRC " .. kind, 0)
		end
		if width == 0 and kind ~= "IHDR" then
			error("PNG_HEADER", 0)
		end
		if kind == "IHDR" then
			if length ~= 13 or width ~= 0 then
				error("PNG_HEADER", 0)
			end
			width = readU32BE(data, offset + 8)
			height = readU32BE(data, offset + 12)
			local depth = buffer.readu8(data, offset + 16)
			local color = buffer.readu8(data, offset + 17)
			local compression = buffer.readu8(data, offset + 18)
			local filter = buffer.readu8(data, offset + 19)
			local interlace = buffer.readu8(data, offset + 20)
			if width <= 0 or height <= 0 or width * height > MAX_PIXELS then
				error("PNG_SIZE", 0)
			end
			if depth ~= 8 or (color ~= 2 and color ~= 6) or compression ~= 0 or filter ~= 0 or interlace ~= 0 then
				error(
					string.format(
						"PNG_MODE unsupported (depth %d, colour type %d, interlace %d)",
						depth,
						color,
						interlace
					),
					0
				)
			end
			channels = if color == 2 then 3 else 4
		elseif kind == "IDAT" then
			table.insert(compressed, buffer.readstring(data, offset + 8, length))
		elseif kind == "IEND" then
			ended = true
			break
		elseif bit32.band(string.byte(kind, 1), 32) == 0 then
			error("PNG_CRITICAL_CHUNK " .. kind, 0)
		end
		offset += length + 12
	end
	if not ended then
		error("PNG_END", 0)
	end
	if #compressed == 0 then
		error("PNG_NO_DATA", 0)
	end
	local inflatedOk, inflated = pcall(function()
		return serde.decompress("zlib", table.concat(compressed))
	end)
	if not inflatedOk then
		error("PNG_INFLATE " .. tostring(inflated), 0)
	end
	local raw = buffer.fromstring(inflated)
	local rowBytes = width * channels
	local stride = rowBytes + 1
	if buffer.len(raw) ~= height * stride then
		error("PNG_SCANLINES", 0)
	end

	-- Unfilter in place into `pixels` (rowBytes per row, no filter byte).
	local pixels = buffer.create(height * rowBytes)
	for y = 0, height - 1 do
		local filterType = buffer.readu8(raw, y * stride)
		local src = y * stride + 1
		local dst = y * rowBytes
		local prev = dst - rowBytes
		for i = 0, rowBytes - 1 do
			local x = buffer.readu8(raw, src + i)
			local left = if i >= channels then buffer.readu8(pixels, dst + i - channels) else 0
			local up = if y > 0 then buffer.readu8(pixels, prev + i) else 0
			local value
			if filterType == 0 then
				value = x
			elseif filterType == 1 then
				value = x + left
			elseif filterType == 2 then
				value = x + up
			elseif filterType == 3 then
				value = x + math.floor((left + up) / 2)
			elseif filterType == 4 then
				local upLeft = if y > 0 and i >= channels then buffer.readu8(pixels, prev + i - channels) else 0
				value = x + paeth(left, up, upLeft)
			else
				error("PNG_FILTER " .. filterType, 0)
			end
			buffer.writeu8(pixels, dst + i, value % 256)
		end
	end

	if channels == 4 then
		return { width = width, height = height, rgba = pixels }
	end
	local rgba = buffer.create(width * height * 4)
	for p = 0, width * height - 1 do
		buffer.writeu8(rgba, p * 4, buffer.readu8(pixels, p * 3))
		buffer.writeu8(rgba, p * 4 + 1, buffer.readu8(pixels, p * 3 + 1))
		buffer.writeu8(rgba, p * 4 + 2, buffer.readu8(pixels, p * 3 + 2))
		buffer.writeu8(rgba, p * 4 + 3, 255)
	end
	return { width = width, height = height, rgba = rgba }
end

--- Decodes PNG bytes into { width, height, rgba } (rgba: 4 bytes per pixel,
--- row-major, top-to-bottom). Returns (nil, reason) for any malformed or
--- unsupported file instead of raising.
function M.decode(bytes: string | buffer): (Image?, string?)
	local ok, result = pcall(decodeOrError, bytes)
	if not ok then
		return nil, tostring(result)
	end
	return result, nil
end

local function inRects(x: number, y: number, rects: { Rect }): boolean
	for _, r in rects do
		if x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 then
			return true
		end
	end
	return false
end

--- Compares two decoded images. See the module header for the semantics.
function M.compare(a: Image, b: Image, options: Options?): Result
	local opts: Options = options or {}
	local threshold = opts.threshold or M.DEFAULT_THRESHOLD
	local limit = threshold * 255
	local ignore = opts.ignore or {}
	local width = math.max(a.width, b.width)
	local height = math.max(a.height, b.height)
	local sameSize = a.width == b.width and a.height == b.height

	local x0, y0, x1, y1 = 0, 0, width - 1, height - 1
	local crop = opts.crop
	if crop then
		x0 = math.max(x0, crop.x)
		y0 = math.max(y0, crop.y)
		x1 = math.min(x1, crop.x + crop.w - 1)
		y1 = math.min(y1, crop.y + crop.h - 1)
	end

	local mask = buffer.create(width * height)
	local differing, total = 0, 0
	local bx1, by1, bx2, by2 = math.huge, math.huge, -1, -1
	for y = y0, y1 do
		for x = x0, x1 do
			if not inRects(x, y, ignore) then
				total += 1
				local inA = x < a.width and y < a.height
				local inB = x < b.width and y < b.height
				local differs
				if inA and inB then
					local ia = (y * a.width + x) * 4
					local ib = (y * b.width + x) * 4
					differs = false
					for c = 0, 3 do
						if math.abs(buffer.readu8(a.rgba, ia + c) - buffer.readu8(b.rgba, ib + c)) > limit then
							differs = true
							break
						end
					end
				else
					differs = true
				end
				if differs then
					differing += 1
					buffer.writeu8(mask, y * width + x, 1)
					bx1 = math.min(bx1, x)
					by1 = math.min(by1, y)
					bx2 = math.max(bx2, x)
					by2 = math.max(by2, y)
				end
			end
		end
	end

	return {
		identical = sameSize and differing == 0,
		sameSize = sameSize,
		differing = differing,
		total = total,
		percent = if total > 0 then differing / total * 100 else 0,
		bbox = if differing > 0 then { x1 = bx1, y1 = by1, x2 = bx2, y2 = by2 } else nil,
		width = width,
		height = height,
		mask = mask,
	}
end

--- Writes the diff image for `result` (from compare(a, b)) to `path`: the base
--- image (or the compare image where the base has no pixel) as dimmed grey,
--- differing pixels solid red.
function M.writeDiff(a: Image, b: Image, result: Result, path: string): ()
	local width, height = result.width, result.height
	local canvas = Pixels.new(width, height)
	local d = canvas.data
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local i = (y * width + x) * 4 + 1
			if buffer.readu8(result.mask, y * width + x) == 1 then
				d[i], d[i + 1], d[i + 2], d[i + 3] = 1, 0, 0, 1
			else
				local source: Image? = if x < a.width and y < a.height
					then a
					elseif x < b.width and y < b.height then b
					else nil
				if source then
					local s = (y * source.width + x) * 4
					local luma = (
						0.299 * buffer.readu8(source.rgba, s)
						+ 0.587 * buffer.readu8(source.rgba, s + 1)
						+ 0.114 * buffer.readu8(source.rgba, s + 2)
					) / 255
					local grey = 0.6 + luma * 0.3
					d[i], d[i + 1], d[i + 2], d[i + 3] = grey, grey, grey, 1
				else
					d[i], d[i + 1], d[i + 2], d[i + 3] = 1, 1, 1, 1
				end
			end
		end
	end
	fs.writeFile(path, Png.encode(canvas))
end

return M
