--!strict
-- Rendered-nonce registration evidence. This gate re-decodes every nonce from
-- the raw BGRA frame bytes; producer-supplied coordinates are never trusted.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Validation = require("../../../core/domain/genre/Validation")

local M = {}

M.SCHEMA_VERSION = 1
M.PROTOCOL = "forge-rendered-nonce-v1"
M.MAX_FRAME_BYTES = 64 * 1024 * 1024
M.INVENTORY_LIMIT = 32
-- The authored lattice is an 8-pixel cell, but the captured window is not 1:1
-- with the client's GUI space: a measured desktop capture rendered one authored
-- cell as 11.44 physical pixels (a 1.43x window scale), so a fixed-pitch decoder
-- can never read it. The cell size is therefore measured from the rendered
-- magenta ring inside the explicit contract below. A capture outside the contract
-- is refused rather than guessed, and an occluded or partial ring is refused
-- rather than decoded from its remaining pixels.
M.CELL_PIXELS = 8
M.MARKER_COLUMNS = 18
M.MARKER_ROWS = 10
M.INTERIOR_COLUMNS = 16
M.INTERIOR_ROWS = 8
M.MARKER_WIDTH = M.MARKER_COLUMNS * M.CELL_PIXELS
M.MARKER_HEIGHT = M.MARKER_ROWS * M.CELL_PIXELS
M.MIN_CELL_PIXELS = M.CELL_PIXELS
M.MAX_CELL_PIXELS = 4 * M.CELL_PIXELS

export type Match = { x: number, y: number, nonce: string }
export type Context = {
	root: string,
	evidenceDir: string,
	artifacts: { string },
	scenario: any,
	source: any,
	buildIdentity: string,
	digest: (any) -> string,
}

local DARK, BRIGHT = 8, 247
local DIGITS = "0123456789abcdef"

local function text(value: any): boolean
	return type(value) == "string" and string.find(value, "%S") ~= nil
end

local function relative(path: string): boolean
	return path ~= ""
		and not string.find(path, "\\", 1, true)
		and not string.match(path, "^/")
		and not string.find(path, ":", 1, true)
		and not string.match("/" .. path .. "/", "/%.%.?/")
end

local function inside(path: string, dir: string): boolean
	return path == dir or string.sub(path, 1, #dir + 1) == dir .. "/"
end

-- Positive decimal strings compare exactly by length, then lexicographically.
function M.decimal(value: any): string?
	if type(value) ~= "string" or string.match(value, "^%d+$") == nil then
		return nil
	end
	if #value > 1 and string.sub(value, 1, 1) == "0" then
		return nil
	end
	return value
end

function M.less(left: string, right: string): boolean
	if #left ~= #right then
		return #left < #right
	end
	return left < right
end

local function requireDecimal(value: any, code: string): string
	local result: any = M.decimal(value)
	assert(result ~= nil, code)
	return result
end

-- Exact floor division by a bounded divisor; each step stays below 2^53.
function M.divide(dividend: string, divisor: number): string
	assert(divisor >= 1 and divisor % 1 == 0 and divisor <= 1000000000, "INVALID_DIVISOR")
	local remainder, quotient = 0, {}
	for index = 1, #dividend do
		local digit: any = tonumber(string.sub(dividend, index, index))
		local value = remainder * 10 + digit
		local out = math.floor(value / divisor)
		remainder = value - out * divisor
		table.insert(quotient, string.char(48 + out))
	end
	local result = string.gsub(table.concat(quotient), "^0+", "")
	return if result == "" then "0" else result
end

-- floor(barrierQpc * 1e7 / frequency): the 100ns-domain barrier value that the
-- native recorder discards at or below.
function M.barrier100ns(barrierQpc: string, frequency: string): string
	local value: any = tonumber(frequency)
	assert(type(value) == "number" and value >= 1 and value % 1 == 0 and value <= 1000000000, "INVALID_FREQUENCY")
	return M.divide(barrierQpc .. "0000000", value)
end

local function magenta(data: buffer, offset: number): boolean
	-- BGRA: magenta is blue 255, green 0, red 255.
	return buffer.readu8(data, offset) == 255
		and buffer.readu8(data, offset + 1) == 0
		and buffer.readu8(data, offset + 2) == 255
		and buffer.readu8(data, offset + 3) == 255
end

-- A sampled pixel is a rendered bit only when every colour channel is exact
-- black (<=8) or exact white (>=247) and alpha is 255.
local function sample(data: buffer, offset: number): boolean?
	if buffer.readu8(data, offset + 3) ~= 255 then
		return nil
	end
	local blue = buffer.readu8(data, offset)
	local green = buffer.readu8(data, offset + 1)
	local red = buffer.readu8(data, offset + 2)
	local dark = blue <= DARK and green <= DARK and red <= DARK
	local bright = blue >= BRIGHT and green >= BRIGHT and red >= BRIGHT
	if dark == bright then
		return nil
	end
	return bright
end

local function bitsToHex(bits: { boolean }): string
	local out = {}
	for index = 0, 31 do
		local value = 0
		for nibble = 0, 3 do
			value = value * 2 + (if bits[index * 4 + nibble + 1] then 1 else 0)
		end
		table.insert(out, string.sub(DIGITS, value + 1, value + 1))
	end
	return table.concat(out)
end

-- Decodes the rendered nonce whose magenta ring starts at (x0, y0), or nil when
-- the marker is absent, occluded, partial, outside the supported cell-size
-- contract, or its interior bits are not exact black/white.
function M.decode(data: buffer, width: number, height: number, stride: number, x0: number, y0: number): string?
	local function pixel(x: number, y: number): number
		return y * stride + x * 4
	end
	if x0 < 0 or y0 < 0 or x0 >= width or y0 >= height then
		return nil
	end
	-- The origin is the ring's top-left corner: magenta here, no magenta to the
	-- left or above it, so the marker is located by its own rendered geometry.
	if not magenta(data, pixel(x0, y0)) then
		return nil
	end
	if x0 > 0 and magenta(data, pixel(x0 - 1, y0)) then
		return nil
	end
	if y0 > 0 and magenta(data, pixel(x0, y0 - 1)) then
		return nil
	end
	-- Measure the lattice from the top and left borders. An occluded or truncated
	-- border measures short and is refused below instead of decoding a partial ring.
	local across = 0
	while x0 + across < width and magenta(data, pixel(x0 + across, y0)) do
		across += 1
	end
	local down = 0
	while y0 + down < height and magenta(data, pixel(x0, y0 + down)) do
		down += 1
	end
	local cell = across / M.MARKER_COLUMNS
	if cell < M.MIN_CELL_PIXELS or cell > M.MAX_CELL_PIXELS then
		return nil
	end
	if math.abs(down - M.MARKER_ROWS * cell) > 1 then
		return nil
	end
	-- Cell centre in the measured lattice, derived from the rendered span so a
	-- fractional cell size samples the middle of the cell it names.
	local function centre(column: number, row: number): number
		return pixel(
			x0 + math.floor((2 * column + 1) * across / (2 * M.MARKER_COLUMNS)),
			y0 + math.floor((2 * row + 1) * down / (2 * M.MARKER_ROWS))
		)
	end
	-- Every border cell must be magenta: a missing one is an occluded or partial
	-- marker and is refused rather than read as a bit.
	for row = 0, M.MARKER_ROWS - 1 do
		for column = 0, M.MARKER_COLUMNS - 1 do
			if row == 0 or row == M.MARKER_ROWS - 1 or column == 0 or column == M.MARKER_COLUMNS - 1 then
				if not magenta(data, centre(column, row)) then
					return nil
				end
			end
		end
	end
	local radius = math.max(1, math.floor(cell / 4))
	local bits: { boolean } = {}
	for row = 0, M.INTERIOR_ROWS - 1 do
		for column = 0, M.INTERIOR_COLUMNS - 1 do
			local value: boolean? = nil
			local origin = centre(column + 1, row + 1)
			for dy = -radius, radius do
				for dx = -radius, radius do
					local read = sample(data, origin + dy * stride + dx * 4)
					if read == nil or (value ~= nil and read ~= value) then
						return nil
					end
					value = read
				end
			end
			bits[row * M.INTERIOR_COLUMNS + column + 1] = value == true
		end
	end
	return bitsToHex(bits)
end

-- The entire raster is searched and matches are returned in (y, x) order so
-- callers compare canonical coordinates instead of producer ordering.
function M.search(bytes: string, width: number, height: number, stride: number): { Match }
	local found: { Match } = {}
	if width < M.MARKER_COLUMNS * M.MIN_CELL_PIXELS or height < M.MARKER_ROWS * M.MIN_CELL_PIXELS then
		return found
	end
	local data = buffer.fromstring(bytes)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local nonce = M.decode(data, width, height, stride, x, y)
			if nonce ~= nil then
				assert(#found < 64, "REGISTRATION_TOO_MANY_MARKERS")
				table.insert(found, { x = x, y = y, nonce = nonce })
			end
		end
	end
	table.sort(found, function(left, right)
		if left.y ~= right.y then
			return left.y < right.y
		end
		return left.x < right.x
	end)
	return found
end

-- The pinned Lune readFile/metadata API has no bounded read or file size.
-- The producer checks size before reading; this gate checks immediately after.
local function readFrame(root: string, path: string): string
	local full = root .. "/" .. path
	assert(fs.isFile(full), "REGISTRATION_FRAME_MISSING: " .. path)
	local bytes = fs.readFile(full)
	assert(#bytes <= M.MAX_FRAME_BYTES, "REGISTRATION_FRAME_TOO_LARGE: " .. path)
	return bytes
end

local function sorted(matches: any): { Match }
	local list: { Match } = {}
	for _, entry in matches do
		list[#list + 1] = { x = entry.x, y = entry.y, nonce = entry.nonce }
	end
	table.sort(list, function(left, right)
		if left.y ~= right.y then
			return left.y < right.y
		end
		return left.x < right.x
	end)
	return list
end

local function same(left: { Match }, right: { Match }): boolean
	if #left ~= #right then
		return false
	end
	for index = 1, #left do
		if
			left[index].x ~= right[index].x
			or left[index].y ~= right[index].y
			or left[index].nonce ~= right[index].nonce
		then
			return false
		end
	end
	return true
end

function M.validate(context: Context): boolean
	local root, evidenceDir, artifacts = context.root, context.evidenceDir, context.artifacts
	local scenario: any = context.scenario
	local source: any = context.source

	-- A boolean or bare filename is never a bound registration artifact.
	local bound: any = source.registrationEvidence
	assert(type(bound) == "table", "REGISTRATION_EVIDENCE_REQUIRED")
	local boundPath: any = bound.path
	local boundSha: any = bound.sha256
	assert(type(boundPath) == "string" and type(boundSha) == "string", "REGISTRATION_EVIDENCE_REQUIRED")
	assert(
		boundPath ~= ""
			and relative(boundPath)
			and inside(boundPath, evidenceDir)
			and table.find(artifacts, boundPath) ~= nil,
		"REGISTRATION_EVIDENCE_UNBOUND"
	)
	local bytes = readFrame(root, boundPath)
	assert(boundSha == serde.hash("sha256", bytes), "REGISTRATION_STALE_BYTES")
	local document: any = serde.decode("json", bytes)
	assert(
		type(document) == "table" and document.schemaVersion == M.SCHEMA_VERSION and document.protocol == M.PROTOCOL,
		"REGISTRATION_SCHEMA"
	)
	assert(
		type(scenario.registrations) == "table" and scenario.registrations[source.studioId] == context.digest(document),
		"REGISTRATION_SCENARIO_BINDING"
	)
	assert(
		text(document.sessionId)
			and document.sessionId == scenario.runtime.server.sessionId
			and document.buildIdentity == context.buildIdentity
			and document.actorId == source.actorId
			and document.studioId == source.studioId,
		"REGISTRATION_IDENTITY_MISMATCH"
	)
	assert(
		document.sessionId == source.sessionId and document.buildIdentity == source.buildIdentity,
		"REGISTRATION_SOURCE_IDENTITY"
	)
	local actor = false
	for _, client in scenario.runtime.clients do
		if
			client.actorId == document.actorId
			and client.studio_id == document.studioId
			and client.sessionId == document.sessionId
			and client.buildIdentity == document.buildIdentity
		then
			actor = true
		end
	end
	assert(actor, "REGISTRATION_LOGICAL_ACTOR")
	assert(document.processIdentity == source.processIdentity, "REGISTRATION_PROCESS_MISMATCH")
	assert(text(document.jobName) and text(document.desktopName), "REGISTRATION_CONTEXT_REQUIRED")
	assert(
		type(document.pid) == "number" and document.pid % 1 == 0 and document.pid > 0 and document.pid <= 4294967295,
		"REGISTRATION_PID"
	)
	assert(text(document.hwnd) and string.match(document.hwnd, "^0x[0-9a-f]+$") ~= nil, "REGISTRATION_HWND")

	-- The source must name the captured window, not merely a capture kind.
	local videoHwnd: any = nil
	local videoWidth: any = nil
	local videoHeight: any = nil
	if type(source.videoSource) == "string" then
		videoHwnd, videoWidth, videoHeight =
			string.match(source.videoSource, "^windows%-graphics%-capture:hwnd=(0x[0-9a-f]+):size=(%d+)x(%d+)$")
	end
	assert(videoHwnd == document.hwnd and videoWidth ~= nil, "REGISTRATION_VIDEO_SOURCE")

	assert(
		Validation.dense(document.inventory, M.INVENTORY_LIMIT) and #document.inventory > 0,
		"REGISTRATION_INVENTORY_REQUIRED"
	)
	local inventory: { [string]: any } = {}
	for _, entry in document.inventory do
		assert(
			type(entry) == "table"
				and text(entry.hwnd)
				and string.match(entry.hwnd, "^0x[0-9a-f]+$") ~= nil
				and type(entry.pid) == "number"
				and entry.pid % 1 == 0
				and entry.pid > 0
				and entry.pid <= 4294967295
				and text(entry.processIdentity),
			"REGISTRATION_INVENTORY_ENTRY"
		)
		assert(inventory[entry.hwnd] == nil, "REGISTRATION_INVENTORY_DUPLICATE")
		inventory[entry.hwnd] = entry
	end
	for _, entry in document.inventory do
		assert(
			#entry.hwnd == 18
				and string.match(entry.processIdentity, "^pid:" .. tostring(entry.pid) .. ":created:[1-9]%d*$"),
			"REGISTRATION_PROCESS_FORMAT"
		)
	end
	assert(inventory[document.hwnd] ~= nil, "REGISTRATION_INVENTORY_TARGET")
	assert(
		inventory[document.hwnd].pid == document.pid
			and inventory[document.hwnd].processIdentity == document.processIdentity,
		"REGISTRATION_INVENTORY_IDENTITY"
	)

	assert(
		Validation.dense(document.rounds, 2) and #document.rounds == 2 and type(document.cleanup) == "table",
		"REGISTRATION_ROUNDS_REQUIRED"
	)
	local logical = {
		sessionId = document.sessionId,
		buildIdentity = document.buildIdentity,
		actorId = document.actorId,
		studioId = document.studioId,
	}
	local rounds: { any } = { document.rounds[1], document.rounds[2], document.cleanup }
	local registry: { [string]: boolean } = { [boundPath] = true }
	local frequency: any = nil
	local matched: any = nil
	local priorMax: any = nil
	local completed: any = nil
	for index, round in rounds do
		local final = index == 3
		assert(
			type(round) == "table"
				and round.round == index
				and type(round.renderFrames) == "number"
				and round.renderFrames >= 2
				and round.renderFrames % 1 == 0,
			"REGISTRATION_ROUND_SHAPE"
		)
		local armed = requireDecimal(round.armedQpc, "REGISTRATION_QPC_REQUIRED")
		local barrier = requireDecimal(round.barrierQpc, "REGISTRATION_QPC_REQUIRED")
		local current = requireDecimal(round.frequency, "REGISTRATION_QPC_REQUIRED")
		assert(M.less(armed, barrier), "REGISTRATION_ARM_ORDER")
		local value: any = tonumber(current)
		assert(#current <= 10 and type(value) == "number" and value <= 1000000000, "REGISTRATION_FREQUENCY")
		if frequency == nil then
			frequency = current
		end
		assert(frequency == current, "REGISTRATION_FREQUENCY")
		assert(
			type(round.logical) == "table"
				and round.logical.sessionId == logical.sessionId
				and round.logical.buildIdentity == logical.buildIdentity
				and round.logical.actorId == logical.actorId
				and round.logical.studioId == logical.studioId,
			"REGISTRATION_LOGICAL_MISMATCH"
		)
		if final then
			assert(round.absent == true and round.nativeClosed == true, "REGISTRATION_CLEANUP")
			assert(round.nonce == nil, "REGISTRATION_CLEANUP_NONCE")
		else
			assert(
				type(round.nonce) == "string" and #round.nonce == 32 and string.match(round.nonce, "^[0-9a-f]+$") ~= nil,
				"REGISTRATION_NONCE"
			)
		end
		assert(
			Validation.dense(round.observations, M.INVENTORY_LIMIT) and #round.observations == #document.inventory,
			"REGISTRATION_OBSERVATIONS_REQUIRED"
		)
		local seen: { [string]: boolean } = {}
		local decoded: any = nil
		local maximum: any = nil
		for _, observation in round.observations do
			assert(type(observation) == "table", "REGISTRATION_OBSERVATION_INVENTORY")
			local entry = inventory[observation.hwnd]
			assert(
				type(observation) == "table"
					and entry ~= nil
					and observation.pid == entry.pid
					and observation.processIdentity == entry.processIdentity
					and not seen[observation.hwnd],
				"REGISTRATION_OBSERVATION_INVENTORY"
			)
			seen[observation.hwnd] = true
			local path: any = observation.path
			assert(
				type(path) == "string"
					and relative(path)
					and inside(path, evidenceDir)
					and table.find(artifacts, path) ~= nil,
				"REGISTRATION_FRAME_UNBOUND"
			)
			assert(registry[path] == nil, "REGISTRATION_FRAME_REUSED")
			registry[path] = true
			local frame = readFrame(root, path)
			assert(observation.sha256 == serde.hash("sha256", frame), "REGISTRATION_FRAME_MISMATCH")
			local width: any = observation.width
			local height: any = observation.height
			local stride: any = observation.stride
			assert(
				type(width) == "number"
					and width % 1 == 0
					and width > 0
					and type(height) == "number"
					and height % 1 == 0
					and height > 0
					and type(stride) == "number"
					and stride % 1 == 0
					and stride >= width * 4
					and stride * height == #frame,
				"REGISTRATION_FRAME_GEOMETRY"
			)
			if observation.hwnd == document.hwnd then
				assert(width == tonumber(videoWidth) and height == tonumber(videoHeight), "REGISTRATION_VIDEO_GEOMETRY")
			end
			local frameQpc = requireDecimal(observation.frameQpc, "REGISTRATION_FRAME_TIME")
			assert(M.less(barrier, frameQpc), "REGISTRATION_FRAME_TIME")
			local relative100ns = requireDecimal(observation.systemRelative100ns, "REGISTRATION_FRAME_TIME")
			assert(M.less(M.barrier100ns(barrier, current), relative100ns), "REGISTRATION_FRAME_TIME")
			if maximum == nil or M.less(maximum, frameQpc) then
				maximum = frameQpc
			end
			local raw: any = observation.matches
			assert(type(raw) == "table" and Validation.dense(raw, 64), "REGISTRATION_MATCH_SHAPE")
			for _, match in raw do
				assert(
					type(match) == "table"
						and type(match.x) == "number"
						and match.x % 1 == 0
						and match.x >= 0
						and type(match.y) == "number"
						and match.y % 1 == 0
						and match.y >= 0
						and type(match.nonce) == "string"
						and #match.nonce == 32
						and string.match(match.nonce, "^[0-9a-f]+$") ~= nil,
					"REGISTRATION_MATCH_SHAPE"
				)
			end
			local found = M.search(frame, width, height, stride)
			assert(same(found, sorted(raw)), "REGISTRATION_MATCH_MISMATCH")
			if #found > 0 then
				assert(not final, "REGISTRATION_CLEANUP_PRESENT")
				assert(#found == 1 and found[1].nonce == round.nonce, "REGISTRATION_ROUND_NONCE")
				assert(decoded == nil, "REGISTRATION_MATCH_DUPLICATE")
				decoded = {
					hwnd = observation.hwnd,
					pid = observation.pid,
					processIdentity = observation.processIdentity,
				}
			end
		end
		assert(priorMax == nil or M.less(priorMax, armed), "REGISTRATION_ROUND_ORDER")
		priorMax = maximum
		if final then
			completed = maximum
		else
			assert(decoded ~= nil, "REGISTRATION_MATCH_REQUIRED")
			if matched ~= nil then
				assert(
					matched.hwnd == decoded.hwnd
						and matched.pid == decoded.pid
						and matched.processIdentity == decoded.processIdentity,
					"REGISTRATION_MATCH_IDENTITY"
				)
			end
			matched = matched or decoded
		end
	end
	assert(
		matched
			and matched.hwnd == document.hwnd
			and matched.pid == document.pid
			and matched.processIdentity == document.processIdentity,
		"REGISTRATION_SELECTED_IDENTITY"
	)
	assert(document.rounds[1].nonce ~= document.rounds[2].nonce, "REGISTRATION_NONCE_REUSE")
	assert(completed ~= nil, "REGISTRATION_COMPLETED_REQUIRED")
	assert(source.registrationCompletedQpc == completed, "REGISTRATION_COMPLETED_MISMATCH")
	local start = requireDecimal(source.captureStartQpc, "REGISTRATION_START_REQUIRED")
	assert(M.less(completed, start), "REGISTRATION_START_ORDER")
	return true
end

function M.admit(context: Context): (boolean, string?)
	local ok, reason = pcall(M.validate, context)
	return ok, if ok then nil else tostring(reason)
end

return M
