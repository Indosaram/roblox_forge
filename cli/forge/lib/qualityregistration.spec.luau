--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local receipt = require("./qualityreceipt")
local registration = require("./qualityregistration")
local fixture = require("../fixtures/quality-registration")
local pixels = require("../fixtures/registration-pixels")

return {
	["rendered nonce decoding searches the actual raster"] = function()
		local nonce = string.rep("5a", 16)
		local frame = pixels.markerFrame(320, 240, 40, 30, nonce)
		assert(#frame == 320 * 240 * 4, "frame byte count")
		local found = registration.search(frame, 320, 240, 320 * 4)
		assert(#found == 1, "one decoded match")
		assert(found[1].x == 40 and found[1].y == 30 and found[1].nonce == nonce, "origin and nonce decode")
		local shifted = registration.search(pixels.markerFrame(320, 240, 11, 7, nonce), 320, 240, 320 * 4)
		assert(#shifted == 1 and shifted[1].x == 11 and shifted[1].y == 7, "coordinates are re-derived, never trusted")
		assert(#registration.search(pixels.blankFrame(320, 240), 320, 240, 320 * 4) == 0, "blank raster")
		local data = buffer.fromstring(frame)
		buffer.writeu8(data, (30 + 10) * 320 * 4 + (40 + 10) * 4, 128)
		assert(#registration.search(buffer.tostring(data), 320, 240, 320 * 4) == 0, "mid-tone sample is not a bit")
	end,
	-- The captured window is not 1:1 with the client's GUI space. A measured desktop
	-- capture rendered one authored 8-pixel cell as 11.44 physical pixels, which the
	-- fixed-pitch decoder could never read. The lattice is measured from the rendered
	-- ring instead, inside an explicit contract.
	["rendered nonce decodes at the captured window scale"] = function()
		local nonce = string.rep("3c", 16)
		for _, cell in { 11, 12, 16 } do
			local frame = pixels.markerFrame(640, 480, 40, 30, nonce, cell)
			local found = registration.search(frame, 640, 480, 640 * 4)
			assert(#found == 1, "one decoded match at cell " .. tostring(cell))
			assert(found[1].x == 40 and found[1].y == 30 and found[1].nonce == nonce, "scaled origin and nonce")
		end
	end,
	["rendered nonce refuses a nonce that was never rendered"] = function()
		local rendered, other = string.rep("a5", 16), string.rep("5a", 16)
		local found = registration.search(pixels.markerFrame(320, 240, 40, 30, rendered), 320, 240, 320 * 4)
		assert(#found == 1 and found[1].nonce == rendered, "the rendered nonce decodes")
		assert(found[1].nonce ~= other, "a nonce that was never rendered is never returned")
	end,
	["rendered nonce refuses an occluded or partial ring"] = function()
		local nonce = string.rep("7e", 16)
		local frame = pixels.markerFrame(320, 240, 40, 30, nonce)
		-- A client overlay across the ring's top border, as a topbar covering the
		-- panel's first rows would, leaves a partial marker.
		local covered = buffer.fromstring(frame)
		for y = 30, 45 do
			for x = 40, 40 + registration.MARKER_WIDTH - 1 do
				local offset = y * 320 * 4 + x * 4
				buffer.writeu8(covered, offset, 128)
				buffer.writeu8(covered, offset + 1, 128)
				buffer.writeu8(covered, offset + 2, 128)
			end
		end
		assert(#registration.search(buffer.tostring(covered), 320, 240, 320 * 4) == 0, "partial ring")
		-- An overlay covering a whole interior cell leaves mid-tone samples where a
		-- rendered bit must be exact black or white.
		local obscured = buffer.fromstring(frame)
		for y = 38, 45 do
			for x = 48, 55 do
				local offset = y * 320 * 4 + x * 4
				buffer.writeu8(obscured, offset, 128)
				buffer.writeu8(obscured, offset + 1, 128)
				buffer.writeu8(obscured, offset + 2, 128)
			end
		end
		assert(#registration.search(buffer.tostring(obscured), 320, 240, 320 * 4) == 0, "occluded bits")
	end,
	["rendered nonce refuses a cell size outside the supported contract"] = function()
		local nonce = string.rep("11", 16)
		local small = pixels.markerFrame(320, 240, 40, 30, nonce, registration.MIN_CELL_PIXELS - 1)
		assert(#registration.search(small, 320, 240, 320 * 4) == 0, "below the contract")
		local large = pixels.markerFrame(1400, 800, 40, 30, nonce, registration.MAX_CELL_PIXELS + 1)
		assert(#registration.search(large, 1400, 800, 1400 * 4) == 0, "above the contract")
	end,
	["rendered nonce registration refuses missing boolean duplicated stale replayed and unbound evidence"] = function()
		local root = ".omo/fixtures/quality-registration-gate"
		assert(not fs.isDir(root), "fixture already exists")
		fs.writeDir(root)
		local ok, reason = xpcall(function()
			fs.writeDir(root .. "/e")
			local input: any = { root = root, evidenceDir = "e", evidence = { avArtifacts = {} } }
			local outcome: any = {
				runtime = {
					server = { sessionId = "synthetic-session" },
					clients = { { actorId = "synthetic-actor", studio_id = "synthetic-studio" } },
				},
				registrations = {},
			}
			local identity = {
				actorId = "synthetic-actor",
				studioId = "synthetic-studio",
				buildIdentity = "synthetic-build",
			}
			local record = fixture(input, outcome, identity)
			local source: any = {
				sessionId = outcome.runtime.server.sessionId,
				buildIdentity = identity.buildIdentity,
				actorId = identity.actorId,
				studioId = identity.studioId,
				processIdentity = record.processIdentity,
				videoSource = record.videoSource,
				registrationEvidence = { path = record.path, sha256 = record.sha256 },
				registrationCompletedQpc = record.completedQpc,
				captureStartQpc = record.captureStartQpc,
			}
			local artifacts: { string } = input.evidence.avArtifacts
			local function context(): any
				return {
					root = root,
					evidenceDir = "e",
					artifacts = artifacts,
					scenario = outcome,
					source = source,
					buildIdentity = identity.buildIdentity,
					digest = receipt.digest,
				}
			end
			assert(registration.validate(context()), "canonical synthetic registration must admit")
			local function refuse(code: string)
				local refused, detail = pcall(registration.validate, context())
				assert(not refused, "mutation must refuse: " .. code)
				assert(string.find(tostring(detail), code, 1, true) ~= nil, tostring(detail) .. " expected " .. code)
			end
			local canonical = fs.readFile(root .. "/" .. record.path)
			local base = serde.decode("json", canonical)
			local function reset()
				fs.writeFile(root .. "/" .. record.path, canonical)
				source.registrationEvidence.sha256 = record.sha256
				outcome.registrations[identity.studioId] = receipt.digest(base)
			end
			local function expect(code: string, mutate: any)
				local value = serde.decode("json", serde.encode("json", base))
				mutate(value)
				local bytes = serde.encode("json", value)
				fs.writeFile(root .. "/" .. record.path, bytes)
				source.registrationEvidence.sha256 = serde.hash("sha256", bytes)
				outcome.registrations[identity.studioId] = receipt.digest(value)
				refuse(code)
				reset()
			end
			local bound = source.registrationEvidence
			source.registrationEvidence = true
			refuse("REGISTRATION_EVIDENCE_REQUIRED")
			source.registrationEvidence = record.path
			refuse("REGISTRATION_EVIDENCE_REQUIRED")
			source.registrationEvidence = nil
			refuse("REGISTRATION_EVIDENCE_REQUIRED")
			source.registrationEvidence = bound
			outcome.registrations[identity.studioId] = "sha256:" .. string.rep("0", 64)
			refuse("REGISTRATION_SCENARIO_BINDING")
			outcome.registrations[identity.studioId] = receipt.digest(base)
			source.registrationCompletedQpc = "1"
			refuse("REGISTRATION_COMPLETED_MISMATCH")
			source.registrationCompletedQpc = record.completedQpc
			source.captureStartQpc = record.completedQpc
			refuse("REGISTRATION_START_ORDER")
			source.captureStartQpc = record.captureStartQpc
			source.videoSource = "windows-graphics-capture:hwnd=0x00000000000000b2:size=320x240"
			refuse("REGISTRATION_VIDEO_SOURCE")
			source.videoSource = "windows-graphics-capture:hwnd=0x00000000000000a1:size=321x240"
			refuse("REGISTRATION_VIDEO_GEOMETRY")
			source.videoSource = record.videoSource
			expect("REGISTRATION_SCHEMA", function(value)
				value.protocol = "other-protocol"
			end)
			expect("REGISTRATION_INVENTORY_DUPLICATE", function(value)
				value.inventory[2] = table.clone(value.inventory[1])
			end)
			expect("REGISTRATION_OBSERVATION_INVENTORY", function(value)
				value.rounds[1].observations[2].pid = 99
			end)
			expect("REGISTRATION_MATCH_MISMATCH", function(value)
				value.rounds[1].observations[1].matches[1].x = 41
			end)
			expect("REGISTRATION_MATCH_MISMATCH", function(value)
				value.rounds[1].observations[1].matches = {}
			end)
			expect("REGISTRATION_FRAME_TIME", function(value)
				value.rounds[1].observations[1].frameQpc = value.rounds[1].barrierQpc
			end)
			expect("REGISTRATION_FRAME_TIME", function(value)
				value.rounds[1].observations[1].systemRelative100ns = "1"
			end)
			expect("REGISTRATION_FREQUENCY", function(value)
				value.rounds[2].frequency = "4000000"
			end)
			expect("REGISTRATION_ROUND_ORDER", function(value)
				value.rounds[2].armedQpc = "1"
			end)
			expect("REGISTRATION_LOGICAL_MISMATCH", function(value)
				value.cleanup.logical.actorId = "other"
			end)
			expect("REGISTRATION_CLEANUP", function(value)
				value.cleanup.nativeClosed = false
			end)
			expect("REGISTRATION_CLEANUP", function(value)
				value.cleanup.absent = false
			end)
			expect("REGISTRATION_CLEANUP_NONCE", function(value)
				value.cleanup.nonce = value.rounds[1].nonce
			end)
			expect("REGISTRATION_FRAME_UNBOUND", function(value)
				value.rounds[2].observations[1].path = "e/synthetic-registration-absent.bgra"
			end)
			expect("REGISTRATION_FRAME_REUSED", function(value)
				value.rounds[2].observations[1].path = value.rounds[1].observations[1].path
				value.rounds[2].observations[1].sha256 = value.rounds[1].observations[1].sha256
			end)

			expect("REGISTRATION_OBSERVATIONS_REQUIRED", function(value)
				table.remove(value.rounds[1].observations)
			end)
			expect("REGISTRATION_SELECTED_IDENTITY", function(value)
				local other: { hwnd: string, pid: number, processIdentity: string } = value.inventory[2]
				value.hwnd, value.pid, value.processIdentity = other.hwnd, other.pid, other.processIdentity
				source.processIdentity = other.processIdentity
				source.videoSource = "windows-graphics-capture:hwnd=" .. other.hwnd .. ":size=320x240"
			end)
			source.processIdentity, source.videoSource = record.processIdentity, record.videoSource
			source.sessionId = "wrong-session"
			refuse("REGISTRATION_SOURCE_IDENTITY")
			source.sessionId = outcome.runtime.server.sessionId
			-- Rehashing a duplicated actual nonce must not hide a second match.
			local otherPath = base.rounds[1].observations[2].path
			local otherBytes = fs.readFile(root .. "/" .. otherPath)
			local targetBytes = fs.readFile(root .. "/" .. base.rounds[1].observations[1].path)
			fs.writeFile(root .. "/" .. otherPath, targetBytes)
			expect("REGISTRATION_MATCH_DUPLICATE", function(value)
				value.rounds[1].observations[2].sha256 = serde.hash("sha256", targetBytes)
				value.rounds[1].observations[2].matches = table.clone(value.rounds[1].observations[1].matches)
			end)
			fs.writeFile(root .. "/" .. otherPath, otherBytes)
			-- Nonselected windows may have their own dimensions.
			local smaller = pixels.blankFrame(160, 96)
			fs.writeFile(root .. "/" .. otherPath, smaller)
			local sized = serde.decode("json", canonical)
			local row = sized.rounds[1].observations[2]
			row.width, row.height, row.stride = 160, 96, 640
			row.sha256 = serde.hash("sha256", smaller)
			local sizedBytes = serde.encode("json", sized)
			fs.writeFile(root .. "/" .. record.path, sizedBytes)
			source.registrationEvidence.sha256 = serde.hash("sha256", sizedBytes)
			outcome.registrations[identity.studioId] = receipt.digest(sized)
			assert(registration.validate(context()), "nonselected candidate dimensions are independent")
			fs.writeFile(root .. "/" .. otherPath, otherBytes)
			reset()
			-- Cleanup frame bytes no longer match their recorded digest.
			local cleanupPath = base.cleanup.observations[1].path
			local cleanupBytes = fs.readFile(root .. "/" .. cleanupPath)
			fs.writeFile(root .. "/" .. cleanupPath, cleanupBytes .. "x")
			refuse("REGISTRATION_FRAME_MISMATCH")
			fs.writeFile(root .. "/" .. cleanupPath, cleanupBytes)
			-- A replayed round one frame and nonce cannot register round two.
			local replayPath = base.rounds[2].observations[1].path
			local replayBytes = fs.readFile(root .. "/" .. replayPath)
			local markerBytes = fs.readFile(root .. "/" .. base.rounds[1].observations[1].path)
			fs.writeFile(root .. "/" .. replayPath, markerBytes)
			local replayed = serde.decode("json", serde.encode("json", base))
			replayed.rounds[2].observations[1].sha256 = serde.hash("sha256", markerBytes)
			replayed.rounds[2].nonce = replayed.rounds[1].nonce
			replayed.rounds[2].observations[1].matches[1].nonce = replayed.rounds[1].nonce
			local replayedBytes = serde.encode("json", replayed)
			fs.writeFile(root .. "/" .. record.path, replayedBytes)
			source.registrationEvidence.sha256 = serde.hash("sha256", replayedBytes)
			outcome.registrations[identity.studioId] = receipt.digest(replayed)
			refuse("REGISTRATION_NONCE_REUSE")
			fs.writeFile(root .. "/" .. replayPath, replayBytes)
			reset()
			-- A cleanup candidate frame may not carry an actually rendered marker.
			local pollutedPath = base.cleanup.observations[1].path
			local pollutedBytes = fs.readFile(root .. "/" .. pollutedPath)
			fs.writeFile(root .. "/" .. pollutedPath, markerBytes)
			local polluted = serde.decode("json", serde.encode("json", base))
			polluted.cleanup.observations[1].sha256 = serde.hash("sha256", markerBytes)
			polluted.cleanup.observations[1].matches = { { x = 40, y = 30, nonce = polluted.rounds[1].nonce } }
			local pollutedEncoded = serde.encode("json", polluted)
			fs.writeFile(root .. "/" .. record.path, pollutedEncoded)
			source.registrationEvidence.sha256 = serde.hash("sha256", pollutedEncoded)
			outcome.registrations[identity.studioId] = receipt.digest(polluted)
			refuse("REGISTRATION_CLEANUP_PRESENT")
			fs.writeFile(root .. "/" .. pollutedPath, pollutedBytes)
			reset()
			assert(registration.validate(context()), "pristine evidence must still admit after every refusal")
		end, debug.traceback)
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
}
