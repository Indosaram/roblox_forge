--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local Budget = require("../../core/infra/data/EnvelopeBudget")
local BuildIdentity = require("../forge/lib/buildidentity")

local M = {}

local function text(value: any): boolean
	return type(value) == "string" and #value > 0 and not string.find(value, "%c")
end

local function number(value: any, minimum: number): boolean
	return type(value) == "number" and value == value and value >= minimum and value < math.huge
end

local function integer(value: any, minimum: number): boolean
	return number(value, minimum) and value % 1 == 0 and value <= 2 ^ 53 - 1
end

local function array(value: any): boolean
	if type(value) ~= "table" or #value == 0 then
		return false
	end
	local count = 0
	for key in value do
		if not integer(key, 1) or key > #value then
			return false
		end
		count += 1
	end
	return count == #value
end

local function hash(value: any, length: number): boolean
	return type(value) == "string" and #value == length and string.match(value, "^[0-9a-f]+$") ~= nil
end

-- Nearest-rank quantiles. Never average client quantiles into a server claim.
function M.samples(values: any, minimum: number): any
	assert(array(values), "SAMPLES_REQUIRED")
	local sorted: { number } = {}
	for _, value in values do
		assert(number(value, minimum), "INVALID_SAMPLE")
		table.insert(sorted, value)
	end
	table.sort(sorted)
	return {
		count = #sorted,
		p50 = sorted[math.ceil(#sorted * 0.5)],
		p95 = sorted[math.ceil(#sorted * 0.95)],
		maximum = sorted[#sorted],
	}
end

local function candidate(value: any, pack: string, players: number): any
	assert(type(value) == "table" and value.schema == "capacity/v1", "INVALID_SCHEMA")
	local run = value.run
	assert(type(run) == "table" and run.pack == pack, "PACK_MISMATCH")
	for _, key in { "runId", "serverSessionId", "hardware", "robloxVersion" } do
		assert(text(run[key]), "RUN_IDENTITY_REQUIRED:" .. key)
	end
	assert(
		hash(run.revision, 40) and hash(run.buildSha256, 64) and hash(run.configSha256, 64),
		"INVALID_BUILD_IDENTITY"
	)
	assert(
		integer(run.startedAtMs, 0) and integer(run.endedAtMs, 1) and run.endedAtMs > run.startedAtMs,
		"INVALID_WINDOW"
	)
	assert(integer(run.npcCount, 0) and run.npcCount == run.configuredNpcCount, "NPC_WORKLOAD_MISMATCH")
	assert(integer(run.payloadMaxBytes, 1) and run.payloadMaxBytes <= Budget.MAX_BYTES, "INVALID_BYTE_BUDGET")
	assert(array(value.clients) and #value.clients == players, "ACTUAL_CLIENT_COUNT_MISMATCH")
	local actors: { [string]: boolean } = {}
	local sessions: { [string]: boolean } = { [run.serverSessionId] = true }
	local clients = {}
	local violations = {}
	local function window(row: any)
		assert(row.runId == run.runId and row.serverSessionId == run.serverSessionId, "RUN_MISMATCH")
		assert(row.startedAtMs == run.startedAtMs and row.endedAtMs == run.endedAtMs, "WINDOW_MISMATCH")
	end
	for _, client in value.clients do
		assert(type(client) == "table" and text(client.actorId) and text(client.sessionId), "CLIENT_IDENTITY_REQUIRED")
		assert(not actors[client.actorId] and not sessions[client.sessionId], "DUPLICATE_CLIENT")
		actors[client.actorId], sessions[client.sessionId] = true, true
		assert(
			client.loadedRevision == run.revision and client.loadedBuildSha256 == run.buildSha256,
			"LOADED_BUILD_MISMATCH"
		)
		assert(text(client.hardware) and client.robloxVersion == run.robloxVersion, "CLIENT_ENVIRONMENT_REQUIRED")
		window(client)
		local frames = M.samples(client.frameMs, 0)
		for _, frame in client.frameMs do
			assert(frame > 0, "INVALID_FRAME_TIME")
		end
		local memory = M.samples(client.memoryMb, 0)
		if frames.p95 > 33.3 then
			table.insert(violations, "FRAME_P95:" .. client.actorId)
		end
		table.insert(
			clients,
			{ actorId = client.actorId, sessionId = client.sessionId, frameMs = frames, memoryMb = memory }
		)
	end
	local server = value.server
	assert(type(server) == "table", "SERVER_METRICS_REQUIRED")
	window(server)
	local memory = M.samples(server.memoryMb, 0)
	local budget = M.samples(server.backendBudget, 0)
	local latency = M.samples(server.commitLatencyMs, 0)
	assert(
		integer(server.throttleCount, 0)
			and integer(server.handledThrottleCount, 0)
			and server.handledThrottleCount <= server.throttleCount,
		"INVALID_THROTTLE_COUNTS"
	)
	if server.handledThrottleCount ~= server.throttleCount then
		table.insert(violations, "UNHANDLED_THROTTLE")
	end
	assert(array(server.serializedValues), "PERSISTED_BYTES_REQUIRED")
	local sizes = {}
	for _, bytes in server.serializedValues do
		assert(type(bytes) == "string", "PERSISTED_BYTES_REQUIRED")
		local decoded = serde.decode("json", bytes)
		assert(
			type(decoded) == "table" and type(decoded.data) == "table" and decoded.version ~= nil,
			"FULL_PERSISTED_WRAPPER_REQUIRED"
		)
		local measured = Budget.check(decoded, function(_value)
			return bytes
		end, run.payloadMaxBytes)
		table.insert(sizes, measured.byteCount)
		if not measured.accepted then
			table.insert(violations, "PERSISTED_VALUE_TOO_LARGE")
		end
	end
	return {
		clients = clients,
		server = {
			memoryMb = memory,
			backendBudget = budget,
			commitLatencyMs = latency,
			serializedBytes = M.samples(sizes, 1),
			throttleCount = server.throttleCount,
			handledThrottleCount = server.handledThrottleCount,
		},
		violations = violations,
		run = run,
	}
end

-- A file is untrusted candidate telemetry, not an actual owned-client receipt.
-- No boolean in that file can supply missing maintained-runner admission.
function M.report(pack: string, players: number, evidence: any?): any
	assert(text(pack) and integer(players, 1), "INVALID_REQUEST")
	local report: any = {
		schema = "capacity-report/v1",
		status = "BLOCKED",
		ok = false,
		pack = pack,
		requestedPlayers = players,
		admittedPlayers = 0,
		supportedEnvelope = { measured = false, crossServer = false },
		blockers = {
			"CURRENT_OWNED_CLIENT_COLLECTOR_UNAVAILABLE",
			"CURRENT_BUILD_ADMISSION_UNAVAILABLE",
			"LIVE_PERSISTENT_CONSERVATION_PROOF_REQUIRED",
			"LIVE_TRANSFER_LEASE_CRASH_PROOF_REQUIRED",
			"CAP_SATURATION_PROOF_REQUIRED",
			"OWNED_CLEANUP_PROOF_REQUIRED",
		},
		candidate = { supplied = evidence ~= nil, valid = false, authority = "untrusted-intake" },
	}
	if evidence ~= nil then
		local ok, result = pcall(candidate, evidence, pack, players)
		if ok then
			report.candidate.valid = true
			report.candidate.metrics = result
		else
			report.candidate.error = tostring(result)
			table.insert(report.blockers, "CANDIDATE_INVALID")
		end
	else
		table.insert(report.blockers, "METRICS_NOT_COLLECTED")
	end
	return report
end

function M.arguments(args: { string }): any
	local options: any = {}
	assert(#args % 2 == 0, "CAPACITY_USAGE")
	for i = 1, #args, 2 do
		local key = args[i]
		assert(
			key == "--pack" or key == "--players" or key == "--out" or key == "--evidence" or key == "--recovery",
			"CAPACITY_USAGE"
		)
		assert(options[key] == nil and text(args[i + 1]), "CAPACITY_USAGE")
		options[key] = args[i + 1]
	end
	assert(type(options["--pack"]) == "string" and string.match(options["--pack"], "^[%w_-]+$"), "CAPACITY_USAGE")
	local players = tonumber(options["--players"] or "")
	assert(integer(players, 1) and text(options["--out"]), "CAPACITY_USAGE")
	assert(options["--recovery"] == nil or options["--recovery"] == "transfer", "CAPACITY_USAGE")
	return {
		pack = options["--pack"],
		players = players,
		out = options["--out"],
		evidence = options["--evidence"],
		recovery = options["--recovery"],
	}
end

function M.admitArtifact(driver: any, sidecar: any, bytes: string, identity: any)
	local token = driver.ownershipToken
	assert(
		type(token) == "string"
			and #token >= 16
			and #token <= 128
			and string.match(token, "^[A-Za-z0-9%-]+$") ~= nil
			and type(sidecar) == "table"
			and sidecar.schemaVersion == 1
			and sidecar.ownedQaToken == token,
		"OWNED_ARTIFACT_MARKER_MISMATCH"
	)
	assert(
		type(sidecar.identity) == "table"
			and sidecar.identity.id == identity.id
			and sidecar.build == "sha256:" .. serde.hash("sha256", bytes),
		"STALE_BUILD"
	)
	assert(BuildIdentity.inspectArtifact(bytes, identity, token), "EMBEDDED_IDENTITY_MISMATCH")
end

-- Lune's JSON encoder cannot represent an empty JSON array: an empty Luau table
-- encodes as {} (observed: the collector's "residuals":[] decoded and re-encoded to
-- "residuals":{}), so re-encoding a decoded payload rewrites every empty array at
-- this evidence boundary. The collector is a JS producer, so its canonical bytes are
-- spliced verbatim. For the wrapper's own fields only these list paths are emitted
-- explicitly, and each is an array in the producer, not a map:
--   blockers                  capacity-admission.mjs:217 (blockers:[])
--   recovery.checkpoints      capacity-admission.mjs:219 (checkpoints:[]), :278 (push)
--   recovery.blockers         capacity-admission.mjs:219 (blockers:[]),   :279 (push)
--   candidate.metrics.violations  capacity.luau violations table (table.insert)
-- Every other field is serde-exact, so an empty object keeps {} and is never
-- promoted to a list.
local LIST_PATHS: { string } = {
	"blockers",
	"recovery.checkpoints",
	"recovery.blockers",
	"candidate.metrics.violations",
}

local function pathKind(path: string): string
	for _, declared in LIST_PATHS do
		if declared == path then
			return "list"
		elseif string.sub(declared, 1, #path + 1) == path .. "." then
			return "branch"
		end
	end
	return "leaf"
end

-- Descend only along declared list paths; serde is exact everywhere else.
local function encodeField(value: any, path: string): string
	local kind = pathKind(path)
	if kind == "list" then
		return if type(value) == "table" and next(value) == nil then "[]" else serde.encode("json", value)
	elseif kind == "branch" and type(value) == "table" then
		local parts = {}
		for key, child in value do
			table.insert(parts, serde.encode("json", key) .. ":" .. encodeField(child, path .. "." .. key))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return serde.encode("json", value)
end

-- Add one authoritative top-level field to a raw JSON object string. Only the
-- outermost braces are touched, so no nested value is rewritten or re-typed; the
-- already decoded payload is inspected solely to refuse a duplicate key. A body that
-- is whitespace-only inside the braces is treated as empty, never as a separator.
local function addField(object: string, key: string, encoded: string, inspected: any): string
	local trimmed = string.match(object, "^%s*(.-)%s*$") or ""
	assert(string.sub(trimmed, 1, 1) == "{" and string.sub(trimmed, -1) == "}", "JSON_OBJECT_REQUIRED")
	assert(type(inspected) == "table" and inspected[key] == nil, "JSON_FIELD_COLLISION:" .. key)
	local body = string.sub(trimmed, 2, -2)
	local separator = if string.match(body, "^%s*$") == nil then "," else ""
	return "{" .. body .. separator .. serde.encode("json", key) .. ":" .. encoded .. "}"
end

--- The persisted evidence document. `raw` is the collector's own canonical payload
--- (nil when no collector ran); `inspected` is that payload already decoded, used only
--- to refuse a duplicate key; `exitCode` is the authoritative process exit status,
--- which the collector's own stdout cannot carry.
function M.evidenceDocument(wrapper: any, raw: string?, inspected: any, exitCode: number?): string
	assert(type(wrapper) == "table", "EVIDENCE_DOCUMENT_REQUIRED")
	local splicing = raw ~= nil
	local parts = {}
	for key, value in wrapper do
		if not (splicing and key == "collector") then
			table.insert(parts, serde.encode("json", key) .. ":" .. encodeField(value, key))
		end
	end
	if splicing then
		-- Luau does not narrow through the runtime `integer` predicate, so the type is
		-- asserted here, at the point of use; the integer bounds contract is kept.
		assert(type(exitCode) == "number", "COLLECTOR_EXIT_CODE_REQUIRED")
		assert(integer(exitCode, 0), "COLLECTOR_EXIT_CODE_REQUIRED")
		table.insert(
			parts,
			serde.encode("json", "collector")
				.. ":"
				.. addField(raw :: string, "exitCode", string.format("%d", exitCode), inspected)
		)
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

function M.run(args: { string }): boolean
	local ok, result = pcall(function()
		local options = M.arguments(args)
		assert(not fs.isFile(options.out) and not fs.isDir(options.out), "CAPACITY_OUTPUT_EXISTS")
		local report = M.report(options.pack, options.players)
		-- Explicit execution authorization is separate from an evidence file.
		-- After the implementation barrier, the operator supplies the maintained
		-- transport configuration through this environment path.
		local driverPath = process.env.FORGE_CAPACITY_DRIVER
		local collectorPayload: string? = nil
		local collectorExitCode: number? = nil
		if driverPath and not options.evidence then
			local collected, collectedReport, rawPayload, rawExitCode = pcall(function()
				local driver = serde.decode("json", fs.readFile(driverPath))
				local packDir = "games/" .. options.pack
				assert(type(driver.buildPath) == "string", "BUILD_IDENTITY_INPUT_REQUIRED")
				local function current(): any
					local identity =
						BuildIdentity.snapshot(packDir .. "/default.project.json", packDir, driver.buildPath)
					local bytes = fs.readFile(driver.buildPath)
					local sidecar = serde.decode("json", fs.readFile(driver.buildPath .. ".identity.json"))
					M.admitArtifact(driver, sidecar, bytes, identity)
					identity.artifactSha256 = serde.hash("sha256", bytes)
					return identity
				end
				local function collectorIdentity(): string
					local entries = {}
					local function walk(path: string)
						for _, name in fs.readDir(path) do
							local child = path .. "/" .. name
							if fs.isDir(child) then
								walk(child)
							elseif string.match(name, "%.mjs$") or string.match(name, "%.luau$") then
								table.insert(entries, child .. ":" .. serde.hash("sha256", fs.readFile(child)))
							end
						end
					end
					walk("cli/release")
					walk("cli/forge/qa")
					table.sort(entries)
					return serde.hash("sha256", table.concat(entries, "\n"))
				end
				local binding = current()
				local collectorBinding = collectorIdentity()
				driver.buildIdentity = binding
				-- Lune's process.exec stdin pipe truncates in some sessions
				-- (observed as collector-side "JSON Parse error: Unexpected EOF"),
				-- so deliver the request as a file argument instead.
				local stdinPath = options.out .. ".collector-stdin"
				fs.writeFile(
					stdinPath,
					serde.encode("json", {
						pack = options.pack,
						players = options.players,
						driver = driver,
						buildIdentity = binding,
						recovery = options.recovery,
						artifactDirectory = options.out .. ".artifacts",
						collectorIdentity = collectorBinding,
					})
				)
				local run = process.exec("bun", { "cli/release/capacity-collector.mjs", stdinPath }, {})
				local decoded = serde.decode("json", run.stdout)
				local contractOk = type(decoded) == "table"
					and decoded.schema == "capacity-admission/v1"
					and (decoded.status == "BLOCKED" or decoded.status == "PASS")
					and decoded.ok == (decoded.status == "PASS")
					and ((run.code == 0) == decoded.ok)
					and type(decoded.blockers) == "table"
					and type(decoded.matrix) == "table"
					and type(decoded.supportedEnvelope) == "table"
					and type(decoded.recovery) == "table"
					and (
						not decoded.ok
						or (
							decoded.supportedEnvelope.measured == true
							and decoded.recovery.status == "PASS"
							and #decoded.blockers == 0
						)
					)
				if not contractOk then
					-- The rejected output itself is the evidence; a bare contract
					-- marker hides which field failed (same class as collectorError).
					error("COLLECTOR_CONTRACT_INVALID:" .. string.sub(run.stdout, 1, 2000))
				end
				local stable, after = pcall(current)
				if
					not stable
					or after.id ~= binding.id
					or after.artifactSha256 ~= binding.artifactSha256
					or collectorIdentity() ~= collectorBinding
					or decoded.matrix.collectorIdentity ~= collectorBinding
				then
					table.insert(decoded.blockers, "BUILD_CHANGED_DURING_COLLECTION")
					decoded.ok, decoded.status = false, "BLOCKED"
					decoded.supportedEnvelope = { measured = false, crossServer = false }
				end
				-- The collector's own stdout cannot carry the authoritative process exit
				-- status, so it is composed into the persisted collector below; a raw
				-- payload that already declared it would become a duplicate key.
				assert(decoded.exitCode == nil, "COLLECTOR_EXIT_CODE_COLLISION")
				return decoded, run.stdout, run.code
			end)
			if collected then
				collectorPayload, collectorExitCode = rawPayload, rawExitCode
				report.collector = collectedReport
				report.ok, report.status = collectedReport.ok, collectedReport.status
				report.blockers = collectedReport.blockers
				report.supportedEnvelope = collectedReport.supportedEnvelope
				report.recovery = collectedReport.recovery
				report.admittedPlayers = if collectedReport.supportedEnvelope.measured then options.players else 0
			else
				-- The discarded pcall value is the real failure; CAPACITY blockers
				-- without it are unevidenceable (same class as collectorError).
				report.collectorError = string.sub(tostring(collectedReport), 1, 2000)
				table.insert(report.blockers, "COLLECTOR_FAILED")
			end
		else
			table.insert(report.blockers, "EXECUTABLE_COLLECTOR_NOT_REQUESTED")
		end
		if options.evidence then
			local loaded, bytes = pcall(fs.readFile, options.evidence)
			if loaded then
				local decoded, value = pcall(function()
					return serde.decode("json", bytes)
				end)
				if decoded then
					report = M.report(options.pack, options.players, value)
					table.insert(report.blockers, "EXECUTABLE_COLLECTOR_NOT_REQUESTED")
				else
					table.insert(report.blockers, "EVIDENCE_JSON_INVALID")
				end
				report.evidenceSha256 = serde.hash("sha256", bytes)
			else
				table.insert(report.blockers, "EVIDENCE_UNREADABLE")
			end
		end
		local parent = string.match(options.out, "^(.*)[/\\][^/\\]+$")
		if parent and not fs.isDir(parent) then
			fs.writeDir(parent)
		end
		-- Lune's JSON encoder cannot represent an empty array, so re-encoding the
		-- decoded collector rewrote every empty JSON array at this boundary. Preserve
		-- the collector's own canonical bytes and emit the wrapper's declared list
		-- fields explicitly; the decoded collector is the duplicate-key reference only.
		fs.writeFile(options.out, M.evidenceDocument(report, collectorPayload, report.collector, collectorExitCode))
		return report
	end)
	if ok then
		stdio.write(serde.encode("json", result) .. "\n")
	else
		stdio.ewrite(serde.encode("json", { ok = false, status = "BLOCKED", error = tostring(result) }) .. "\n")
	end
	return ok and result.ok == true
end

if ... ~= "module" then
	if not M.run(process.args) then
		process.exit(1)
	end
end

return M
