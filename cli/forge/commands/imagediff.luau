--!strict
-- `forge imagediff <base.png> <compare.png> [--diff <out.png>] [--threshold n]
--   [--ignore x1:y1-x2:y2[,..]] [--crop x:y:w:h] [--json]`
--
-- Compares two PNG screenshots pixel by pixel through ../lib/imagediff and
-- prints "imagediff: identical" or "imagediff: N different pixels (P%)
-- bbox=x1,y1,x2,y2"; with --json it prints one JSON object (schemaVersion 1).
-- M.run returns an exit code: 0 identical, 1 different, 2 usage or decode
-- error. Dispatch and process.exit are wired by the CLI entry point.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local imagediff = require("../lib/imagediff")

local M = {}

M.SCHEMA_VERSION = 1

export type Output = { write: (string) -> (), ewrite: (string) -> () }

export type Options = {
	base: string,
	compare: string,
	diff: string?,
	threshold: number?,
	ignore: { imagediff.Rect }?,
	crop: imagediff.Crop?,
	json: boolean,
}

local USAGE = "Usage: lune run cli/forge imagediff <base.png> <compare.png> [--diff <out.png>] [--threshold n]"
	.. " [--ignore x1:y1-x2:y2[,..]] [--crop x:y:w:h] [--json]\n"

local function integer(text: string): number?
	if not string.match(text, "^%d+$") then
		return nil
	end
	return tonumber(text)
end

local function parseIgnore(value: string): ({ imagediff.Rect }?, string?)
	local rects: { imagediff.Rect } = {}
	for part in string.gmatch(value, "[^,]+") do
		local a, b, c, d = string.match(part, "^(%d+):(%d+)%-(%d+):(%d+)$")
		if a == nil or b == nil or c == nil or d == nil then
			return nil, "invalid --ignore region '" .. part .. "' (expected x1:y1-x2:y2)"
		end
		local rect = {
			x1 = integer(a) :: number,
			y1 = integer(b) :: number,
			x2 = integer(c) :: number,
			y2 = integer(d) :: number,
		}
		if rect.x2 < rect.x1 or rect.y2 < rect.y1 then
			return nil, "invalid --ignore region '" .. part .. "' (x2/y2 must not be below x1/y1)"
		end
		table.insert(rects, rect)
	end
	if #rects == 0 then
		return nil, "--ignore requires at least one region"
	end
	return rects, nil
end

--- Parses the command arguments (args[1] = "imagediff"). Returns (options, nil)
--- or (nil, reason).
function M.parseArgs(args: { string }): (Options?, string?)
	local positional: { string } = {}
	local options = { json = false } :: any
	local index = 2
	while index <= #args do
		local flag = args[index]
		if flag == "--json" then
			if options.json then
				return nil, "--json given twice"
			end
			options.json = true
			index += 1
		elseif flag == "--diff" or flag == "--threshold" or flag == "--ignore" or flag == "--crop" then
			local value = args[index + 1]
			if value == nil or value == "" then
				return nil, flag .. " requires a value"
			end
			local key = string.sub(flag, 3)
			if options[key] ~= nil then
				return nil, flag .. " given twice"
			end
			if flag == "--diff" then
				options.diff = value
			elseif flag == "--threshold" then
				local n = tonumber(value)
				if n == nil or n ~= n or n < 0 or n > 1 then
					return nil, "--threshold must be a number between 0 and 1"
				end
				options.threshold = n
			elseif flag == "--ignore" then
				local rects, err = parseIgnore(value)
				if rects == nil then
					return nil, err
				end
				options.ignore = rects
			else
				local x, y, w, h = string.match(value, "^(%d+):(%d+):(%d+):(%d+)$")
				if
					x == nil
					or y == nil
					or w == nil
					or h == nil
					or (integer(w) :: number) < 1
					or (integer(h) :: number) < 1
				then
					return nil, "invalid --crop '" .. value .. "' (expected x:y:w:h with w,h >= 1)"
				end
				options.crop = {
					x = integer(x) :: number,
					y = integer(y) :: number,
					w = integer(w) :: number,
					h = integer(h) :: number,
				}
			end
			index += 2
		elseif string.sub(flag, 1, 2) == "--" then
			return nil, "unknown argument '" .. flag .. "' for forge imagediff"
		else
			table.insert(positional, flag)
			index += 1
		end
	end
	if #positional ~= 2 then
		return nil, "forge imagediff requires exactly two images: <base.png> <compare.png>"
	end
	options.base = positional[1]
	options.compare = positional[2]
	return options :: Options, nil
end

local function load(path: string): (imagediff.Image?, string?)
	local ok, bytes = pcall(fs.readFile, path)
	if not ok then
		return nil, path .. ": cannot read file"
	end
	local image, err = imagediff.decode(bytes)
	if image == nil then
		return nil, path .. ": " .. tostring(err)
	end
	return image, nil
end

--- Runs the command. `out` defaults to stdio and exists so specs can capture
--- what is printed. Returns 0 identical, 1 different, 2 usage/decode error.
function M.run(args: { string }, out: Output?): number
	local io: Output = out or { write = stdio.write, ewrite = stdio.ewrite }
	local options, parseErr = M.parseArgs(args)
	if options == nil then
		io.ewrite("Error: " .. tostring(parseErr) .. "\n" .. USAGE)
		return 2
	end
	local base, baseErr = load(options.base)
	if base == nil then
		io.ewrite("imagediff: error: " .. tostring(baseErr) .. "\n")
		return 2
	end
	local compare, compareErr = load(options.compare)
	if compare == nil then
		io.ewrite("imagediff: error: " .. tostring(compareErr) .. "\n")
		return 2
	end

	local result = imagediff.compare(base, compare, {
		threshold = options.threshold,
		ignore = options.ignore,
		crop = options.crop,
	})
	if options.diff ~= nil then
		local writeDiff: (imagediff.Image, imagediff.Image, imagediff.Result, string) -> ...any = imagediff.writeDiff
		local ok, err = pcall(writeDiff, base, compare, result, options.diff)
		if not ok then
			io.ewrite("imagediff: error: cannot write diff " .. options.diff .. ": " .. tostring(err) .. "\n")
			return 2
		end
	end

	local bbox = result.bbox
	if options.json then
		io.write(serde.encode("json", {
			schemaVersion = M.SCHEMA_VERSION,
			identical = result.identical,
			sameSize = result.sameSize,
			differing = result.differing,
			total = result.total,
			percent = result.percent,
			bbox = bbox,
			base = { path = options.base, width = base.width, height = base.height },
			compare = { path = options.compare, width = compare.width, height = compare.height },
			diff = options.diff,
		}) .. "\n")
	elseif result.identical then
		io.write("imagediff: identical\n")
	else
		local line = string.format("imagediff: %d different pixels (%.2f%%)", result.differing, result.percent)
		if bbox then
			line ..= string.format(" bbox=%d,%d,%d,%d", bbox.x1, bbox.y1, bbox.x2, bbox.y2)
		end
		if not result.sameSize then
			line ..= string.format(" size %dx%d vs %dx%d", base.width, base.height, compare.width, compare.height)
		end
		io.write(line .. "\n")
	end
	return if result.identical then 0 else 1
end

return M
