--!strict
-- Specs for the pure Luau PNG image diff (lib/imagediff) and its command
-- module (commands/imagediff, driven through M.run).

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Png = require("./png")
local imagediff = require("./imagediff")
local command = require("../commands/imagediff")
local Pixels = require("../../../core/domain/procgen/Pixels")

local TEMP = process.env["TEMP"] or process.env["TMPDIR"] or "/tmp"

-- Canvas with distinct, exactly representable byte values per pixel.
local function canvas(width: number, height: number): any
	local c = Pixels.new(width, height)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			c:set(x, y, { r = (x * 40) / 255, g = (y * 50) / 255, b = ((x + y) * 17) / 255, a = 1 })
		end
	end
	return c
end

local function pixel(image: any, x: number, y: number): (number, number, number, number)
	local i = (y * image.width + x) * 4
	return buffer.readu8(image.rgba, i),
		buffer.readu8(image.rgba, i + 1),
		buffer.readu8(image.rgba, i + 2),
		buffer.readu8(image.rgba, i + 3)
end

local function decodeCanvas(c: any): any
	local image, err = imagediff.decode(Png.encode(c))
	assert(image ~= nil, "decode failed: " .. tostring(err))
	return image
end

-- Hand-built PNG chunk writer, independent of png.luau, so filtered scanlines
-- and colour type 2 are exercised through a real zlib stream.
local CRC: { number } = table.create(256, 0)
for n = 0, 255 do
	local c = n
	for _ = 1, 8 do
		c = if bit32.band(c, 1) == 1 then bit32.bxor(0xEDB88320, bit32.rshift(c, 1)) else bit32.rshift(c, 1)
	end
	CRC[n] = c
end

local function u32(value: number): string
	return string.char(
		math.floor(value / 16777216) % 256,
		math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256,
		value % 256
	)
end

local function chunk(kind: string, data: string): string
	local body = kind .. data
	local crc = 0xFFFFFFFF
	for i = 1, #body do
		crc = bit32.bxor(CRC[bit32.band(bit32.bxor(crc, string.byte(body, i)), 0xFF)], bit32.rshift(crc, 8))
	end
	return u32(#data) .. body .. u32(bit32.bxor(crc, 0xFFFFFFFF))
end

local function paeth(a: number, b: number, c: number): number
	local p = a + b - c
	local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
	if pa <= pb and pa <= pc then
		return a
	elseif pb <= pc then
		return b
	end
	return c
end

-- rows[y][i] are raw bytes (channels per pixel); filters[y] is the filter type.
local function handBuiltPng(width: number, channels: number, rows: { { number } }, filters: { number }): string
	local out: { string } = {}
	for y, row in rows do
		local prev = rows[y - 1]
		local bytes = { filters[y] }
		for i, value in row do
			local left = if i > channels then row[i - channels] else 0
			local up = if prev then prev[i] else 0
			local upLeft = if prev and i > channels then prev[i - channels] else 0
			local predictor = 0
			local f = filters[y]
			if f == 1 then
				predictor = left
			elseif f == 2 then
				predictor = up
			elseif f == 3 then
				predictor = math.floor((left + up) / 2)
			elseif f == 4 then
				predictor = paeth(left, up, upLeft)
			end
			table.insert(bytes, (value - predictor) % 256)
		end
		table.insert(out, string.char(table.unpack(bytes)))
	end
	local colourType = if channels == 3 then 2 else 6
	local ihdr = u32(width) .. u32(#rows) .. string.char(8, colourType, 0, 0, 0)
	return "\137PNG\r\n\26\n"
		.. chunk("IHDR", ihdr)
		.. chunk("IDAT", serde.compress("zlib", table.concat(out)))
		.. chunk("IEND", "")
end

local function captured(): (any, { string }, { string })
	local stdout: { string } = {}
	local stderr: { string } = {}
	return {
		write = function(text: string)
			table.insert(stdout, text)
		end,
		ewrite = function(text: string)
			table.insert(stderr, text)
		end,
	},
		stdout,
		stderr
end

local function tempPath(name: string): string
	return TEMP .. "/forge-imagediff-spec-" .. name
end

return {
	["decodes a png.luau RGBA image back to its exact pixels"] = function()
		local image = decodeCanvas(canvas(4, 3))
		assert(image.width == 4 and image.height == 3, "size round-trips")
		local r, g, b, a = pixel(image, 3, 2)
		assert(r == 120 and g == 100 and b == 85 and a == 255, "pixel (3,2) round-trips")
		r, g, b, a = pixel(image, 0, 0)
		assert(r == 0 and g == 0 and b == 0 and a == 255, "pixel (0,0) round-trips")
	end,

	["undoes Sub, Up, Average and Paeth filters on an RGB image"] = function()
		local rows: { { number } } = {}
		for y = 0, 4 do
			local row = {}
			for x = 0, 3 do
				table.insert(row, (x * 61 + y * 37) % 256)
				table.insert(row, (x * 13 + y * 101 + 200) % 256)
				table.insert(row, (x * y * 29 + 7) % 256)
			end
			rows[y + 1] = row
		end
		local bytes = handBuiltPng(4, 3, rows, { 1, 2, 3, 4, 0 })
		local image, err = imagediff.decode(bytes)
		assert(image ~= nil, "decode failed: " .. tostring(err))
		assert(image.width == 4 and image.height == 5, "hand-built size")
		for y = 0, 4 do
			for x = 0, 3 do
				local r, g, b, a = pixel(image, x, y)
				local row = rows[y + 1]
				assert(
					r == row[x * 3 + 1] and g == row[x * 3 + 2] and b == row[x * 3 + 3] and a == 255,
					string.format("pixel (%d,%d) after filter %d", x, y, y + 1)
				)
			end
		end
	end,

	["undoes Paeth and Average on an RGBA image with a second row"] = function()
		local rows = {
			{ 10, 20, 30, 255, 250, 5, 128, 0, 1, 2, 3, 4 },
			{ 200, 100, 50, 25, 0, 255, 0, 255, 99, 98, 97, 96 },
			{ 7, 7, 7, 7, 8, 8, 8, 8, 255, 0, 255, 0 },
		}
		local image = imagediff.decode(handBuiltPng(3, 4, rows, { 4, 3, 4 }))
		assert(image ~= nil, "decode succeeds")
		for y = 0, 2 do
			for x = 0, 2 do
				local r, g, b, a = pixel(image, x, y)
				local row = rows[y + 1]
				assert(
					r == row[x * 4 + 1] and g == row[x * 4 + 2] and b == row[x * 4 + 3] and a == row[x * 4 + 4],
					string.format("RGBA pixel (%d,%d)", x, y)
				)
			end
		end
	end,

	["refuses corrupt and unsupported bytes with a reason"] = function()
		local image, err = imagediff.decode("not a png at all")
		assert(image == nil and err == "PNG_SIGNATURE", "bad signature: " .. tostring(err))
		local good = buffer.tostring(Png.encode(canvas(2, 2)))
		local flipped = string.sub(good, 1, 40)
			.. string.char((string.byte(good, 41) + 1) % 256)
			.. string.sub(good, 42)
		image, err = imagediff.decode(flipped)
		assert(image == nil and string.find(tostring(err), "PNG_CRC", 1, true), "crc mismatch: " .. tostring(err))
		local truncated, truncatedErr = imagediff.decode(string.sub(good, 1, 50))
		assert(truncated == nil and truncatedErr == "PNG_TRUNCATED", "truncated: " .. tostring(truncatedErr))
		local ihdr16 = u32(1) .. u32(1) .. string.char(16, 6, 0, 0, 0)
		local deep = "\137PNG\r\n\26\n" .. chunk("IHDR", ihdr16) .. chunk("IEND", "")
		image, err = imagediff.decode(deep)
		assert(image == nil and string.find(tostring(err), "PNG_MODE", 1, true), "16-bit refused: " .. tostring(err))
	end,

	["identical images have zero differing pixels"] = function()
		local a = decodeCanvas(canvas(5, 4))
		local b = decodeCanvas(canvas(5, 4))
		local result = imagediff.compare(a, b)
		assert(result.identical and result.sameSize, "identical")
		assert(result.differing == 0 and result.total == 20 and result.percent == 0, "zero differing")
		assert(result.bbox == nil, "no bbox when identical")
	end,

	["one changed pixel is counted with its bbox, and an ignore region suppresses it"] = function()
		local base = canvas(5, 4)
		local changed = canvas(5, 4)
		changed:set(3, 1, { r = 1, g = 1, b = 1, a = 1 })
		local a, b = decodeCanvas(base), decodeCanvas(changed)
		local result = imagediff.compare(a, b)
		assert(not result.identical and result.differing == 1, "one differing pixel")
		assert(result.percent == 5, "1 of 20 is 5%")
		local bbox = result.bbox :: any
		assert(bbox.x1 == 3 and bbox.y1 == 1 and bbox.x2 == 3 and bbox.y2 == 1, "bbox at the pixel")

		local ignored = imagediff.compare(a, b, { ignore = { { x1 = 2, y1 = 0, x2 = 4, y2 = 1 } } })
		assert(ignored.differing == 0 and ignored.identical, "ignore region suppresses the change")
		assert(ignored.total == 14, "ignored pixels leave the total")

		local cropped = imagediff.compare(a, b, { crop = { x = 0, y = 2, w = 5, h = 2 } })
		assert(cropped.differing == 0 and cropped.total == 10, "crop outside the change sees none")
	end,

	["threshold tolerates small channel deltas"] = function()
		local base = Pixels.new(2, 1)
		base:fill({ r = 100 / 255, g = 100 / 255, b = 100 / 255, a = 1 })
		local near = Pixels.new(2, 1)
		near:fill({ r = 110 / 255, g = 100 / 255, b = 100 / 255, a = 1 })
		local a, b = decodeCanvas(base), decodeCanvas(near)
		assert(imagediff.compare(a, b).differing == 0, "delta 10/255 is within the default 0.1")
		assert(imagediff.compare(a, b, { threshold = 0 }).differing == 2, "threshold 0 flags any change")
	end,

	["a size mismatch is reported and never identical"] = function()
		local a = decodeCanvas(canvas(4, 3))
		local b = decodeCanvas(canvas(5, 3))
		local result = imagediff.compare(a, b)
		assert(not result.sameSize and not result.identical, "size mismatch")
		assert(result.differing == 3 and result.total == 15, "extra column differs")
		local bbox = result.bbox :: any
		assert(bbox.x1 == 4 and bbox.y1 == 0 and bbox.x2 == 4 and bbox.y2 == 2, "bbox is the extra column")
	end,

	["writeDiff paints differing pixels red over a dimmed base"] = function()
		local changed = canvas(3, 2)
		changed:set(1, 1, { r = 1, g = 1, b = 1, a = 1 })
		local a, b = decodeCanvas(canvas(3, 2)), decodeCanvas(changed)
		local result = imagediff.compare(a, b)
		local path = tempPath("writediff.png")
		imagediff.writeDiff(a, b, result, path)
		local diff = imagediff.decode(fs.readFile(path))
		fs.removeFile(path)
		assert(diff ~= nil and diff.width == 3 and diff.height == 2, "diff decodes at the union size")
		local r, g, bl = pixel(diff, 1, 1)
		assert(r == 255 and g == 0 and bl == 0, "differing pixel is red")
		r, g, bl = pixel(diff, 0, 0)
		assert(r == g and g == bl and r >= 150, "unchanged pixel is dimmed grey")
	end,

	["command returns 0 for identical images"] = function()
		local pathA, pathB = tempPath("same-a.png"), tempPath("same-b.png")
		fs.writeFile(pathA, Png.encode(canvas(4, 4)))
		fs.writeFile(pathB, Png.encode(canvas(4, 4)))
		local out, stdout = captured()
		local code = command.run({ "imagediff", pathA, pathB }, out)
		fs.removeFile(pathA)
		fs.removeFile(pathB)
		assert(code == 0, "identical exits 0, got " .. tostring(code))
		assert(table.concat(stdout) == "imagediff: identical\n", "identical line: " .. table.concat(stdout))
	end,

	["command returns 1 with the exact count, bbox, JSON and a diff file"] = function()
		local changed = canvas(4, 5)
		changed:set(2, 3, { r = 1, g = 1, b = 1, a = 1 })
		changed:set(0, 1, { r = 1, g = 1, b = 1, a = 1 })
		local pathA, pathB, pathDiff = tempPath("diff-a.png"), tempPath("diff-b.png"), tempPath("diff-out.png")
		fs.writeFile(pathA, Png.encode(canvas(4, 5)))
		fs.writeFile(pathB, Png.encode(changed))

		local out, stdout = captured()
		local code = command.run({ "imagediff", pathA, pathB, "--diff", pathDiff }, out)
		assert(code == 1, "different exits 1, got " .. tostring(code))
		assert(
			table.concat(stdout) == "imagediff: 2 different pixels (10.00%) bbox=0,1,2,3\n",
			"human line: " .. table.concat(stdout)
		)
		assert(fs.isFile(pathDiff), "--diff wrote a PNG")

		local jsonOut, jsonStdout = captured()
		local jsonCode =
			command.run({ "imagediff", pathA, pathB, "--json", "--ignore", "0:0-1:1", "--threshold", "0.2" }, jsonOut)
		local doc = serde.decode("json", table.concat(jsonStdout))
		assert(jsonCode == 1 and doc.schemaVersion == 1, "JSON carries schemaVersion 1")
		assert(doc.differing == 1 and doc.total == 16 and doc.identical == false, "JSON counts after ignore")
		assert(doc.bbox.x1 == 2 and doc.bbox.y1 == 3, "JSON bbox")

		fs.removeFile(pathA)
		fs.removeFile(pathB)
		fs.removeFile(pathDiff)
	end,

	["command returns 2 for corrupt bytes and bad usage"] = function()
		local pathA, pathBad = tempPath("ok.png"), tempPath("corrupt.png")
		fs.writeFile(pathA, Png.encode(canvas(2, 2)))
		fs.writeFile(pathBad, "\137PNG\r\n\26\ngarbage")
		local out, _, stderr = captured()
		local code = command.run({ "imagediff", pathA, pathBad }, out)
		fs.removeFile(pathA)
		fs.removeFile(pathBad)
		assert(code == 2, "corrupt exits 2, got " .. tostring(code))
		assert(string.find(table.concat(stderr), "imagediff: error:", 1, true), "decode error reported")

		local usageOut = captured()
		assert(command.run({ "imagediff", "only-one.png" }, usageOut) == 2, "one image is a usage error")
		assert(command.run({ "imagediff", "a.png", "b.png", "--bogus" }, usageOut) == 2, "unknown flag")
		assert(command.run({ "imagediff", "a.png", "b.png", "--ignore", "1:2" }, usageOut) == 2, "bad ignore")
		assert(command.run({ "imagediff", "a.png", "b.png", "--crop", "0:0:0:1" }, usageOut) == 2, "bad crop")
		assert(command.run({ "imagediff", "a.png", "b.png", "--threshold", "2" }, usageOut) == 2, "bad threshold")
		assert(command.run({ "imagediff", "missing-a.png", "missing-b.png" }, usageOut) == 2, "missing file")
	end,

	["parseArgs reads every flag"] = function()
		local options = command.parseArgs({
			"imagediff",
			"a.png",
			"b.png",
			"--diff",
			"d.png",
			"--threshold",
			"0.25",
			"--ignore",
			"1:2-3:4,5:6-7:8",
			"--crop",
			"1:1:10:20",
			"--json",
		}) :: any
		assert(options.base == "a.png" and options.compare == "b.png" and options.diff == "d.png", "paths")
		assert(options.threshold == 0.25 and options.json == true, "threshold and json")
		assert(#options.ignore == 2 and options.ignore[2].x1 == 5 and options.ignore[2].y2 == 8, "ignore list")
		assert(options.crop.x == 1 and options.crop.w == 10 and options.crop.h == 20, "crop")
	end,
}
