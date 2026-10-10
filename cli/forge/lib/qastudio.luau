--!strict
-- qastudio: the `--studio` driver for `lune run cli/forge qa run`.
--
-- The real Studio channel is Studio MCP against a connected Studio instance,
-- driving the generic ForgeQA folder the genre Server binds in Studio
-- (BindableFunctions: dispatch/snapshot/advanceTo/beginClock/advanceElapsed/
-- save/restore, plus the StateChanged BindableEvent for revision signals).
--
-- Until that channel is connected AND its exact MCP tool schema has been
-- discovered and recorded, this driver FAILS CLOSED. It has no native
-- fallback: a `--studio` run that cannot reach a real client is a blocker, not
-- a pass and not a skip. Discovery only gates the local transport; live schema,
-- ownership, input, assertions and image bytes are checked by the runner.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local lifecycle = require("./opencloud-process")
local buildidentity = require("./buildidentity")
local qascenario = require("./qascenario")
local Validation = require("../../../core/domain/genre/Validation")

local M = {}

-- Version 2 never uses device pixels as camera units or encoded image pixels.
M.CAPTURE_SCHEMA_VERSION = 2

local function positive(value: any): boolean
	return Validation.finite(value) and value > 0
end

local function size(value: any): boolean
	return type(value) == "table" and positive(value.width) and positive(value.height)
end

local function rect(value: any): boolean
	return size(value) and Validation.finite(value.x) and Validation.finite(value.y)
end

local function inside(inner: any, outer: any): boolean
	return inner.x >= outer.x
		and inner.y >= outer.y
		and inner.x + inner.width <= outer.x + outer.width
		and inner.y + inner.height <= outer.y + outer.height
end

-- Parse original PNG bytes, including every chunk CRC and the inflated scanlines.
-- Unsupported PNG modes fail closed rather than trusting an IHDR-only claim.
function M.pngRaster(bytes: string): any
	assert(string.sub(bytes, 1, 8) == "\137PNG\r\n\26\n", "PNG_SIGNATURE")
	local function u32(offset: number): number
		local a, b, c, d = string.byte(bytes, offset, offset + 3)
		assert(d, "PNG_TRUNCATED")
		return ((a * 256 + b) * 256 + c) * 256 + d
	end
	local offset, width, height, channels = 9, 0, 0, 0
	local compressed: { string } = {}
	local ended, dataEnded = false, false
	while offset <= #bytes do
		local length = u32(offset)
		assert(length <= #bytes - offset - 11, "PNG_TRUNCATED")
		local kind = string.sub(bytes, offset + 4, offset + 7)
		local crc = 0xFFFFFFFF
		for i = offset + 4, offset + 7 + length do
			crc = bit32.bxor(crc, string.byte(bytes, i))
			for _ = 1, 8 do
				crc = bit32.bxor(bit32.rshift(crc, 1), if bit32.band(crc, 1) == 1 then 0xEDB88320 else 0)
			end
		end
		assert(bit32.bxor(crc, 0xFFFFFFFF) == u32(offset + 8 + length), "PNG_CRC")
		assert(width > 0 or kind == "IHDR", "PNG_HEADER")
		if kind == "IHDR" then
			assert(offset == 9 and length == 13, "PNG_HEADER")
			width, height = u32(offset + 8), u32(offset + 12)
			local depth, color, compression, filter, interlace = string.byte(bytes, offset + 16, offset + 20)
			assert(width > 0 and height > 0 and width * height <= 16777216, "PNG_SIZE")
			assert(
				depth == 8 and (color == 2 or color == 6) and compression == 0 and filter == 0 and interlace == 0,
				"PNG_MODE"
			)
			channels = if color == 2 then 3 else 4
		elseif kind == "IDAT" then
			assert(not dataEnded, "PNG_DATA_ORDER")
			table.insert(compressed, string.sub(bytes, offset + 8, offset + 7 + length))
		elseif kind == "IEND" then
			assert(length == 0 and #compressed > 0 and offset + 11 == #bytes, "PNG_END")
			ended = true
		else
			assert(kind == "PLTE" or bit32.band(string.byte(kind, 1), 32) ~= 0, "PNG_CRITICAL_CHUNK")
			if #compressed > 0 then
				dataEnded = true
			end
		end
		offset += length + 12
	end
	assert(ended, "PNG_END")
	local raw = serde.decompress("zlib", table.concat(compressed))
	local stride = width * channels + 1
	assert(#raw == height * stride, "PNG_SCANLINES")
	for row = 0, height - 1 do
		assert(string.byte(raw, row * stride + 1) <= 4, "PNG_FILTER")
	end
	return { format = "png", width = width, height = height }
end

-- JPEG entropy validation is shared with the actual producer, including exact
-- block counts. No native decoder's truncated-image repair is accepted.
function M.imageRaster(bytes: string): any
	if string.sub(bytes, 1, 8) == "\137PNG\r\n\26\n" then
		return M.pngRaster(bytes)
	end
	assert(string.sub(bytes, 1, 2) == "\255\216", "IMAGE_FORMAT_UNSUPPORTED")
	local hex = string.gsub(bytes, ".", function(byte)
		return string.format("%02x", string.byte(byte))
	end)
	local request = serde.encode("json", { hex = hex })
	-- Lune 0.10.5 delivers an empty stdin from the third `process.exec` with
	-- `stdio.stdin` in one process, so the decode pipes are written and closed
	-- explicitly and both streams are drained before the status is observed.
	local child = process.create("bun", { "cli/forge/qa/studio-driver-surface.mjs", "--raster" })
	local state = lifecycle.exchange(child, request)
	assert(state.status ~= nil, "JPEG_DECODE: child status unobserved")
	assert(state.status.ok, "JPEG_DECODE: " .. tostring(state.stderr))
	return serde.decode("json", state.stdout)
end

-- Rectangles are in full-screen logical units. Camera origin is explicit because
-- ViewportSize can describe the safe viewport, not the full encoded screen.
function M.validateCapture(capture: any, bytes: string, surface: string): boolean
	local ok, valid = pcall(function(): boolean
		assert(
			type(capture) == "table" and capture.schemaVersion == M.CAPTURE_SCHEMA_VERSION,
			'type(capture) == "table" and capture.schemaVersion == M.CAPTURE_SCHEMA_VERSION'
		)
		local device, logical, raster = capture.device, capture.logical, capture.raster
		local expected = if surface == "desktop" then { 1280, 720 } elseif surface == "mobile" then { 390, 844 } else nil
		assert(
			expected and size(device) and device.width == expected[1] and device.height == expected[2],
			"expected and size(device) and device.width == expected[1] and device.height == expected[2]"
		)
		assert(
			type(device.id) == "string" and device.id ~= "" and device.surface == surface,
			'type(device.id) == "string" and device.id ~= "" and device.surface == surface'
		)
		assert(device.scaling == "ActualResolution", 'device.scaling == "ActualResolution"')
		assert(
			if surface == "mobile"
				then device.form == "Phone" and device.orientation == "Portrait"
				else device.form == "Desktop",
			'if surface == "mobile" then device.form == "Phone" and device.orientation == "Portrait" else device.form == "Desktop"'
		)
		assert(
			type(logical) == "table" and rect(logical.full) and rect(logical.viewport) and rect(logical.safeArea),
			'type(logical) == "table" and rect(logical.full) and rect(logical.viewport) and rect(logical.safeArea)'
		)
		assert(logical.full.x == 0 and logical.full.y == 0, "logical.full.x == 0 and logical.full.y == 0")
		assert(
			inside(logical.viewport, logical.full) and inside(logical.safeArea, logical.full),
			"inside(logical.viewport, logical.full) and inside(logical.safeArea, logical.full)"
		)
		local inset = logical.insets
		assert(type(inset) == "table", 'type(inset) == "table"')
		assert(
			inset.left == logical.safeArea.x and inset.top == logical.safeArea.y,
			"inset.left == logical.safeArea.x and inset.top == logical.safeArea.y"
		)
		assert(
			inset.right == logical.full.width - logical.safeArea.x - logical.safeArea.width,
			"inset.right == logical.full.width - logical.safeArea.x - logical.safeArea.width"
		)
		assert(
			inset.bottom == logical.full.height - logical.safeArea.y - logical.safeArea.height,
			"inset.bottom == logical.full.height - logical.safeArea.y - logical.safeArea.height"
		)
		local decoded = M.imageRaster(bytes)
		assert(
			size(raster)
				and raster.format == decoded.format
				and raster.width == decoded.width
				and raster.height == decoded.height,
			"size(raster) and raster.format == decoded.format and raster.width == decoded.width and raster.height == decoded.height"
		)
		local mapping = capture.logicalToRaster
		assert(
			type(mapping) == "table" and mapping.origin == "full-screen",
			'type(mapping) == "table" and mapping.origin == "full-screen"'
		)
		assert(
			mapping.scaleX == raster.width / logical.full.width
				and mapping.scaleY == raster.height / logical.full.height,
			"mapping.scaleX == raster.width / logical.full.width and mapping.scaleY == raster.height / logical.full.height"
		)
		assert(mapping.offsetX == 0 and mapping.offsetY == 0, "mapping.offsetX == 0 and mapping.offsetY == 0")
		assert(
			Validation.dense(capture.criticalUI, 4096) and #capture.criticalUI > 0,
			"Validation.dense(capture.criticalUI, 4096) and #capture.criticalUI > 0"
		)
		local seen: { [string]: boolean } = {}
		for index, bounds in capture.criticalUI do
			assert(
				rect(bounds) and type(bounds.id) == "string" and bounds.id ~= "" and not seen[bounds.id],
				'rect(bounds) and type(bounds.id) == "string" and bounds.id ~= "" and not seen[bounds.id]'
			)
			seen[bounds.id] = true
			assert(inside(bounds, logical.safeArea))
			for previous = 1, index - 1 do
				local other = capture.criticalUI[previous]
				assert(
					bounds.x >= other.x + other.width
						or other.x >= bounds.x + bounds.width
						or bounds.y >= other.y + other.height
						or other.y >= bounds.y + bounds.height,
					"bounds.x >= other.x + other.width or other.x >= bounds.x + bounds.width or bounds.y >= other.y + other.height or othe..."
				)
			end
		end
		-- The chat window owns the top-left corner: owned UI may not be laid over it.
		-- The driver measures the live chat frame into `capture.chat`; a capture that
		-- carries none is judged on the rectangles it does have.
		local chat = capture.chat
		if chat ~= nil then
			assert(
				rect(chat) and inside(chat, logical.safeArea),
				"chat rectangle must be a real rectangle inside the safe area"
			)
			for _, bounds in capture.criticalUI do
				assert(
					bounds.x >= chat.x + chat.width
						or chat.x >= bounds.x + bounds.width
						or bounds.y >= chat.y + chat.height
						or chat.y >= bounds.y + bounds.height,
					"owned UI overlaps the chat window: " .. tostring(bounds.id)
				)
			end
		end
		return true
	end)
	return ok and valid == true
end

--- The ForgeQA operations a Studio scenario drives, exactly as bound by
--- core/infra/genre/Server.luau in Studio. Recorded here so a scenario can be
--- checked against the real surface before any client exists.
M.FORGE_QA_OPERATIONS = {
	"dispatch",
	"snapshot",
	"advanceTo",
	"beginClock",
	"advanceElapsed",
	"save",
	"restore",
}

--- The revision signal a scenario subscribes to before acting, so it waits on
--- an exact state change instead of sleeping.
M.FORGE_QA_SIGNAL = "StateChanged"

--- Capabilities a Studio run requires. Each must be proven by the discovery
--- receipt; a missing one is reported by name.
M.REQUIRED_CAPABILITIES = {
	"studio_connected",
	"screen_capture",
	"input_injection",
	"second_client",
}

export type Prerequisite = { capability: string, available: boolean, detail: string? }
export type Readiness = { ok: boolean, blockers: { string }, prerequisites: { Prerequisite } }

local function blocked(capability: string, detail: string): Prerequisite
	return { capability = capability, available = false, detail = detail }
end

--- Reads a discovery receipt and reports whether a real Studio run can proceed.
--- Absent, unreadable or incomplete receipts all resolve to "not ready": there
--- is deliberately no default-true branch.
function M.readiness(receiptPath: string?): Readiness
	local prerequisites: { Prerequisite } = {}
	local blockers: { string } = {}
	local receipt: any = nil
	if receiptPath == nil then
		table.insert(blockers, "no Studio discovery receipt was provided (--studio-receipt <path>)")
	elseif not fs.isFile(receiptPath) then
		table.insert(blockers, "Studio discovery receipt not found: " .. receiptPath)
	else
		local ok, decoded = pcall(function()
			return serde.decode("json", fs.readFile(receiptPath :: string))
		end)
		if not ok or type(decoded) ~= "table" then
			table.insert(blockers, "Studio discovery receipt is unreadable: " .. receiptPath)
		else
			receipt = decoded
		end
	end
	for _, capability in M.REQUIRED_CAPABILITIES do
		if receipt == nil then
			table.insert(prerequisites, blocked(capability, "no receipt"))
			continue
		end
		local entry = (receipt.capabilities or {})[capability]
		if type(entry) ~= "table" or entry.available ~= true then
			local detail = if type(entry) == "table" and type(entry.blocker) == "string"
				then entry.blocker
				else "not proven available by the receipt"
			table.insert(prerequisites, blocked(capability, detail))
			table.insert(blockers, string.format("%s: %s", capability, detail))
		elseif type(entry.invocation) ~= "string" or entry.invocation == "" then
			table.insert(prerequisites, blocked(capability, "receipt records no literal MCP invocation"))
			table.insert(blockers, capability .. ": receipt records no literal MCP invocation to replay")
		else
			table.insert(prerequisites, { capability = capability, available = true, detail = entry.invocation })
		end
	end
	table.sort(blockers)
	return { ok = #blockers == 0, blockers = blockers, prerequisites = prerequisites }
end

export type Outcome = {
	ok: boolean,
	scenario: string,
	kind: string,
	blockers: { string },
	prerequisites: { Prerequisite },
	discovery: any?,
}

--- Runs a Studio scenario. While any prerequisite is missing this returns a
--- FAILED outcome naming every blocker. It never falls back to the native
--- harness: a headless run cannot stand in for rendered-client evidence.
local function run(scenario: any, receiptPath: string?, bootstrapOwned: boolean): Outcome
	local scenarioName = if type(scenario) == "table" then scenario.name else tostring(scenario)
	local readiness: Readiness = if bootstrapOwned
		then { ok = true, blockers = {}, prerequisites = {} }
		else M.readiness(receiptPath)
	if not readiness.ok then
		return {
			ok = false,
			scenario = scenarioName,
			kind = "studio",
			blockers = readiness.blockers,
			prerequisites = readiness.prerequisites,
		}
	end
	local outcome: any = {
		ok = false,
		scenario = scenarioName,
		kind = "studio",
		blockers = {},
		prerequisites = readiness.prerequisites,
	}
	local errors = qascenario.validate(scenario)
	if #errors > 0 or scenario.kind ~= "studio" then
		outcome.blockers = if #errors > 0 then errors else { "kind: studio required" }
		return outcome
	end
	local receiptOk, receipt = pcall(function()
		assert(receiptPath ~= nil and fs.isFile(receiptPath), "STUDIO_CONFIG_DOCUMENT_REQUIRED")
		return serde.decode("json", fs.readFile(receiptPath :: string))
	end)
	if not receiptOk or type(receipt) ~= "table" then
		outcome.blockers = { "STUDIO_CONFIG_DOCUMENT_REQUIRED" }
		return outcome
	end
	local config = receipt.driver
	if type(config) ~= "table" then
		outcome.blockers = { "owned Studio driver configuration missing" }
		return outcome
	end
	local bound, binding = pcall(function()
		assert(type(config.buildPath) == "string" and type(config.packDir) == "string", "BUILD_IDENTITY_INPUT_REQUIRED")
		local sidecar = serde.decode("json", fs.readFile(config.buildPath .. ".identity.json"))
		local token = config.ownershipToken
		assert(
			type(token) == "string"
				and #token >= 16
				and #token <= 128
				and string.match(token, "^[A-Za-z0-9%-]+$") ~= nil
				and sidecar.ownedQaToken == token,
			"OWNED_ARTIFACT_MARKER_MISMATCH"
		)
		local current =
			buildidentity.snapshot(config.packDir .. "/default.project.json", config.packDir, config.buildPath)
		assert(sidecar.schemaVersion == 1 and sidecar.identity.id == current.id, "STALE_BUILD_IDENTITY")
		assert(sidecar.build == "sha256:" .. serde.hash("sha256", fs.readFile(config.buildPath)), "STALE_BUILD")
		assert(
			buildidentity.inspectArtifact(fs.readFile(config.buildPath), current, token),
			"EMBEDDED_IDENTITY_MISMATCH"
		)
		return current
	end)
	if not bound then
		outcome.blockers = { tostring(binding) }
		return outcome
	end
	config.buildIdentity = binding
	if not fs.isFile("cli/forge/qa/studio-driver.mjs") then
		outcome.blockers = { "cli/forge/qa/studio-driver.mjs runner missing" }
		return outcome
	end
	local inputPath = ".omo/studio-input-"
		.. serde.hash("sha256", serde.encode("json", { scenario, config }))
		.. ".json"
	assert(not fs.isFile(inputPath), "Studio input already in use")
	fs.writeFile(inputPath, serde.encode("json", { scenario = scenario, config = config }))
	local ok, result = pcall(function()
		local driverProcess = process.exec("bun", { "cli/forge/qa/studio-driver.mjs", "--input", inputPath })
		local decoded = serde.decode("json", driverProcess.stdout)
		assert(type(decoded) == "table" and type(decoded.blockers) == "table", "invalid Studio driver response")
		if not driverProcess.ok then
			decoded.ok = false
			if #decoded.blockers == 0 then
				table.insert(decoded.blockers, "STUDIO_DRIVER_NONZERO_EXIT")
			end
		end
		if decoded.ok == false and driverProcess.stderr ~= nil and driverProcess.stderr ~= "" then
			table.insert(decoded.blockers, "driver-stderr: " .. driverProcess.stderr)
		end
		local stable, unchanged = pcall(function()
			local current =
				buildidentity.snapshot(config.packDir .. "/default.project.json", config.packDir, config.buildPath)
			local sidecar = serde.decode("json", fs.readFile(config.buildPath .. ".identity.json"))
			return current.id == binding.id
				and sidecar.identity.id == binding.id
				and sidecar.ownedQaToken == config.ownershipToken
				and sidecar.build == "sha256:" .. serde.hash("sha256", fs.readFile(config.buildPath))
		end)
		if not stable or not unchanged then
			decoded.ok = false
			table.insert(decoded.blockers, "BUILD_CHANGED_DURING_CAPTURE")
		end
		return decoded
	end)
	fs.removeFile(inputPath)
	if not ok then
		outcome.blockers = { "Studio transport failed: " .. tostring(result) }
		return outcome
	end
	result.prerequisites = readiness.prerequisites
	return result
end

function M.run(scenario: any, receiptPath: string?, bootstrapOwned: boolean?): Outcome
	local outcome = run(scenario, receiptPath, bootstrapOwned == true)
	if bootstrapOwned == true then
		if outcome.discovery == nil or not outcome.ok then
			local capabilities: { [string]: any } = {}
			for _, name in M.REQUIRED_CAPABILITIES do
				capabilities[name] = { available = false, blocker = "OWNED_BOOTSTRAP_NOT_PROVEN" }
			end
			local discovery = outcome.discovery or {}
			discovery.schemaVersion = 1
			discovery.status = "BLOCKED"
			discovery.capabilities = capabilities
			discovery.blockers = outcome.blockers
			discovery.cleanup = discovery.cleanup or { observed = false }
			outcome.discovery = discovery
		end
	end
	return outcome
end

return M
