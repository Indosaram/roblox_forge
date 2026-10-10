--!strict
-- UNIT ONLY: deterministic original-buffer fixtures, never production evidence.
local registration = require("../lib/qualityregistration")
local M = {
	SCHEMA_VERSION = registration.SCHEMA_VERSION,
	PROTOCOL = registration.PROTOCOL,
	MARKER_WIDTH = registration.MARKER_WIDTH,
	MARKER_HEIGHT = registration.MARKER_HEIGHT,
	MARKER_ROWS = registration.MARKER_ROWS,
	MARKER_COLUMNS = registration.MARKER_COLUMNS,
	INTERIOR_COLUMNS = registration.INTERIOR_COLUMNS,
	CELL_PIXELS = registration.CELL_PIXELS,
	MIN_CELL_PIXELS = registration.MIN_CELL_PIXELS,
	MAX_CELL_PIXELS = registration.MAX_CELL_PIXELS,
}
local function hexToBits(nonce: string): { boolean }
	local bits: { boolean } = {}
	for index = 1, 32 do
		local digit: any = tonumber(string.sub(nonce, index, index), 16)
		local base = (index - 1) * 4
		bits[base + 1] = digit >= 8
		bits[base + 2] = math.floor(digit / 4) % 2 == 1
		bits[base + 3] = math.floor(digit / 2) % 2 == 1
		bits[base + 4] = digit % 2 == 1
	end
	return bits
end

-- Synthetic publisher for unit fixtures only; the gate never calls it. The cell
-- size is a parameter so a fixture can render the lattice at the scale a real
-- capture produces (one authored cell measured 11.44 physical pixels) and at
-- sizes outside the decoder's supported contract.
function M.paint(
	data: buffer,
	width: number,
	height: number,
	stride: number,
	x0: number,
	y0: number,
	nonce: string,
	cell: number?
)
	assert(#nonce == 32 and string.match(nonce, "^[0-9a-f]+$") ~= nil, "INVALID_NONCE")
	local size = cell or M.CELL_PIXELS
	assert(size > 0 and size <= 64, "INVALID_CELL")
	local across, down = math.floor(M.MARKER_COLUMNS * size), math.floor(M.MARKER_ROWS * size)
	assert(x0 >= 0 and y0 >= 0 and x0 + across <= width and y0 + down <= height, "MARKER_OUTSIDE")
	local bits = hexToBits(nonce)
	local function fill(x: number, y: number, blue: number, green: number, red: number)
		local offset = y * stride + x * 4
		buffer.writeu8(data, offset, blue)
		buffer.writeu8(data, offset + 1, green)
		buffer.writeu8(data, offset + 2, red)
		buffer.writeu8(data, offset + 3, 255)
	end
	for row = 0, M.MARKER_ROWS - 1 do
		local top, bottom = math.floor(row * size), math.floor((row + 1) * size) - 1
		for column = 0, M.MARKER_COLUMNS - 1 do
			local left, right = math.floor(column * size), math.floor((column + 1) * size) - 1
			local border = row == 0 or row == M.MARKER_ROWS - 1 or column == 0 or column == M.MARKER_COLUMNS - 1
			local lit = not border and bits[(row - 1) * M.INTERIOR_COLUMNS + column]
			for py = top, bottom do
				for px = left, right do
					local x, y = x0 + px, y0 + py
					if border then
						fill(x, y, 255, 0, 255)
					elseif lit then
						fill(x, y, 255, 255, 255)
					else
						fill(x, y, 0, 0, 0)
					end
				end
			end
		end
	end
end

local function opaque(width: number, height: number): buffer
	local data = buffer.create(width * 4 * height)
	for index = 0, width * height - 1 do
		buffer.writeu8(data, index * 4 + 3, 255)
	end
	return data
end

function M.blankFrame(width: number, height: number): string
	return buffer.tostring(opaque(width, height))
end

function M.markerFrame(width: number, height: number, x0: number, y0: number, nonce: string, cell: number?): string
	local data = opaque(width, height)
	M.paint(data, width, height, width * 4, x0, y0, nonce, cell)
	return buffer.tostring(data)
end

return M
