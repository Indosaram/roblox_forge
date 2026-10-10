--!strict
-- UNIT DATA ONLY. These painted BGRA frames are synthetic bytes that prove no
-- real window, capture or rendered nonce; they exercise the structural gate.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local registration = require("./registration-pixels")
local receipt = require("../lib/qualityreceipt")

local WIDTH, HEIGHT = 320, 240
local ORIGIN_X, ORIGIN_Y = 40, 30
local FREQUENCY = "3000000"
local NONCE_ONE = "0123456789abcdef0123456789abcdef"
local NONCE_TWO = "fedcba9876543210fedcba9876543210"
local TARGET_HWND = "0x00000000000000a1"
local OTHER_HWND = "0x00000000000000b2"
local TARGET_PID, OTHER_PID = 4242, 4343
local TARGET_PROCESS = "pid:4242:created:17171717171717171"
local OTHER_PROCESS = "pid:4343:created:17171717171717172"
local ROUNDS = {
	{ armed = "2900000", barrier = "2999990", timestamps = { 10000000, 10000100 } },
	{ armed = "3000100", barrier = "3000190", timestamps = { 10001000, 10001100 } },
}
local CLEANUP = { armed = "3000400", barrier = "3000490", timestamps = { 10002000, 10002100 } }

export type Record = {
	path: string,
	sha256: string,
	completedQpc: string,
	captureStartQpc: string,
	videoSource: string,
	processIdentity: string,
}

return function(input: any, outcome: any, identity: any): Record
	local artifacts = assert(input.evidence.avArtifacts, "registration fixture requires avArtifacts")
	local directory = input.evidenceDir
	local owned = input.root .. "/" .. directory
	assert(
		string.find(owned, ".omo/fixtures/", 1, true),
		"synthetic registration requires owned unit fixture directory"
	)
	local function write(name: string, bytes: string): string
		local path = directory .. "/synthetic-registration-" .. name
		fs.writeFile(input.root .. "/" .. path, bytes)
		table.insert(artifacts, path)
		return path
	end
	-- Mirrors the native conversion floor(SystemRelativeTime100ns * frequency / 1e7).
	local function frameQpc(timestamp: number): string
		return string.format("%d", math.floor(timestamp * 3000000 / 10000000))
	end
	local function observation(name: string, target: boolean, nonce: string, timestamp: number): any
		local bytes = registration.blankFrame(WIDTH, HEIGHT)
		if target and #nonce > 0 then
			bytes = registration.markerFrame(WIDTH, HEIGHT, ORIGIN_X, ORIGIN_Y, nonce)
		end
		local hwnd, pid, processIdentity = OTHER_HWND, OTHER_PID, OTHER_PROCESS
		if target then
			hwnd, pid, processIdentity = TARGET_HWND, TARGET_PID, TARGET_PROCESS
		end
		local matches: { any } = {}
		if target and #nonce > 0 then
			matches = { { x = ORIGIN_X, y = ORIGIN_Y, nonce = nonce } }
		end
		return {
			hwnd = hwnd,
			pid = pid,
			processIdentity = processIdentity,
			path = write(name, bytes),
			sha256 = serde.hash("sha256", bytes),
			width = WIDTH,
			height = HEIGHT,
			stride = WIDTH * 4,
			frameQpc = frameQpc(timestamp),
			systemRelative100ns = string.format("%d", timestamp),
			matches = matches,
		}
	end
	local logical = {
		sessionId = outcome.runtime.server.sessionId,
		buildIdentity = identity.buildIdentity,
		actorId = identity.actorId,
		studioId = identity.studioId,
	}
	local function round(index: number, definition: any, nonce: string): any
		return {
			round = index,
			nonce = nonce,
			armedQpc = definition.armed,
			barrierQpc = definition.barrier,
			frequency = FREQUENCY,
			logical = logical,
			renderFrames = 2,
			observations = {
				observation("round" .. index .. "-target.bgra", true, nonce, definition.timestamps[1]),
				observation("round" .. index .. "-other.bgra", false, "", definition.timestamps[2]),
			},
		}
	end
	local document: any = {
		schemaVersion = registration.SCHEMA_VERSION,
		protocol = registration.PROTOCOL,
		sessionId = logical.sessionId,
		buildIdentity = logical.buildIdentity,
		actorId = logical.actorId,
		studioId = logical.studioId,
		pid = TARGET_PID,
		processIdentity = TARGET_PROCESS,
		hwnd = TARGET_HWND,
		jobName = "synthetic-owned-job",
		desktopName = "synthetic-desktop",
		inventory = {
			{ hwnd = TARGET_HWND, pid = TARGET_PID, processIdentity = TARGET_PROCESS },
			{ hwnd = OTHER_HWND, pid = OTHER_PID, processIdentity = OTHER_PROCESS },
		},
		rounds = { round(1, ROUNDS[1], NONCE_ONE), round(2, ROUNDS[2], NONCE_TWO) },
		cleanup = {
			round = 3,
			armedQpc = CLEANUP.armed,
			barrierQpc = CLEANUP.barrier,
			frequency = FREQUENCY,
			logical = logical,
			renderFrames = 2,
			absent = true,
			nativeClosed = true,
			observations = {
				observation("round3-target.bgra", true, "", CLEANUP.timestamps[1]),
				observation("round3-other.bgra", false, "", CLEANUP.timestamps[2]),
			},
		},
	}
	for _, client in outcome.runtime.clients do
		if client.actorId == logical.actorId and client.studio_id == logical.studioId then
			client.sessionId, client.buildIdentity = logical.sessionId, logical.buildIdentity
		end
	end
	outcome.registrations = outcome.registrations or {}
	outcome.registrations[logical.studioId] = receipt.digest(document)
	local bytes = serde.encode("json", document)
	return {
		path = write("registration.json", bytes),
		sha256 = serde.hash("sha256", bytes),
		completedQpc = frameQpc(CLEANUP.timestamps[2]),
		captureStartQpc = "3000700",
		videoSource = "windows-graphics-capture:hwnd=" .. TARGET_HWND .. ":size=" .. WIDTH .. "x" .. HEIGHT,
		processIdentity = TARGET_PROCESS,
	}
end
