--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local Budget = require("../../core/infra/data/EnvelopeBudget")
local BuildIdentity = require("../forge/lib/buildidentity")
local roblox = require("@lune/roblox")
local Capacity = luau.load(fs.readFile("cli/release/capacity.luau"), {
	environment = {
		require = function(path: string): any
			if path == "../../core/infra/data/EnvelopeBudget" then
				return Budget
			elseif path == "../forge/lib/buildidentity" then
				return BuildIdentity
			end
			return (require :: any)(path)
		end,
	},
})("module")

-- Synthetic intake only: never actual clients or capacity proof.
local function fixture()
	local run = {
		runId = "fixture",
		pack = "primal-isles",
		revision = string.rep("a", 40),
		buildSha256 = string.rep("b", 64),
		configSha256 = string.rep("c", 64),
		serverSessionId = "server",
		hardware = "fixture-host",
		robloxVersion = "fixture-version",
		startedAtMs = 1000,
		endedAtMs = 2000,
		npcCount = 4,
		configuredNpcCount = 4,
		payloadMaxBytes = Budget.DEFAULT_MAX_BYTES,
	}
	local clients = {}
	for i = 1, 8 do
		table.insert(clients, {
			actorId = tostring(i),
			sessionId = "client-" .. i,
			loadedRevision = run.revision,
			loadedBuildSha256 = run.buildSha256,
			serverSessionId = run.serverSessionId,
			runId = run.runId,
			hardware = run.hardware,
			robloxVersion = run.robloxVersion,
			startedAtMs = 1000,
			endedAtMs = 2000,
			frameMs = { 10, 20, 33.3 },
			memoryMb = { 100, 120 },
		})
	end
	return {
		schema = "capacity/v1",
		admitted = false,
		noStateLoss = false,
		cleanup = false,
		run = run,
		clients = clients,
		server = {
			runId = run.runId,
			serverSessionId = run.serverSessionId,
			startedAtMs = 1000,
			endedAtMs = 2000,
			memoryMb = { 200 },
			backendBudget = { 0, 10 },
			commitLatencyMs = { 5, 10 },
			throttleCount = 1,
			handledThrottleCount = 1,
			serializedValues = { serde.encode("json", { version = 1, data = {}, generation = 1 }) },
		},
	}
end

return {
	["capacity admission binds QA sidecar token to actual artifact marker"] = function()
		local identity = { id = "sha256:" .. string.rep("a", 64) }
		local token = "capacity-owned-marker-123"
		local place = roblox.Instance.new("DataModel")
		local storage = roblox.Instance.new("ReplicatedStorage")
		storage.Parent = place
		local service = roblox.Instance.new("ServerScriptService")
		service.Parent = place
		local starter = roblox.Instance.new("StarterPlayer")
		starter.Parent = place
		local scripts = roblox.Instance.new("StarterPlayerScripts")
		scripts.Parent = starter
		local serverSource, clientSource = BuildIdentity.runtime(identity)
		local server, client = roblox.Instance.new("Script"), roblox.Instance.new("LocalScript")
		server.Name, server.Source, server.Parent = "ForgeBuildIdentity", serverSource, service
		client.Name, client.Source, client.Parent = "ForgeBuildIdentity", clientSource, scripts
		local function admit(configToken: any, sidecarToken: any)
			local bytes = roblox.serializePlace(place)
			Capacity.admitArtifact({ ownershipToken = configToken }, {
				schemaVersion = 1,
				identity = identity,
				ownedQaToken = sidecarToken,
				build = "sha256:" .. serde.hash("sha256", bytes),
			}, bytes, identity)
		end
		assert(not pcall(admit, token, token), "unmarked normal artifact cannot be adopted")
		assert(not pcall(admit, nil, nil), "ordinary sidecar cannot authorize capacity launch")
		storage:SetAttribute("ForgeQAOwner", token)
		admit(token, token)
		assert(not pcall(admit, "other-owned-marker-123", token), "configured token must match sidecar")
		assert(not pcall(admit, token, "other-owned-marker-123"), "sidecar token cannot be substituted")
		assert(not pcall(admit, "short", "short"), "invalid token rejects")
		storage:SetAttribute("ForgeQAOwner", "other-owned-marker-123")
		assert(not pcall(admit, token, token), "matching sidecar metadata cannot hide wrong actual marker")
		place:Destroy()
	end,
	["missing collector cannot infer capacity from requested count"] = function()
		local report = Capacity.report("primal-isles", 8)
		assert(
			not report.ok and report.status == "BLOCKED" and report.admittedPlayers == 0,
			'not report.ok and report.status == "BLOCKED" and report.admittedPlayers == 0'
		)
		assert(
			not report.supportedEnvelope.measured and not report.supportedEnvelope.crossServer,
			"not report.supportedEnvelope.measured and not report.supportedEnvelope.crossServer"
		)
	end,
	["valid synthetic intake never supplies live admission or invariant proof"] = function()
		local value = fixture()
		value.admitted, value.noStateLoss, value.cleanup = true, true, true
		local report = Capacity.report("primal-isles", 8, value)
		assert(
			report.candidate.valid and not report.ok and report.admittedPlayers == 0,
			"report.candidate.valid and not report.ok and report.admittedPlayers == 0"
		)
		assert(
			report.candidate.metrics.clients[1].frameMs.p95 == 33.3,
			"report.candidate.metrics.clients[1].frameMs.p95 == 33.3"
		)
		assert(
			#report.candidate.metrics.violations == 0 and #report.blockers > 0,
			"#report.candidate.metrics.violations == 0 and #report.blockers > 0"
		)
	end,
	["collector shaped candidate cannot cross the offline admission boundary"] = function()
		local value: any = fixture()
		value.ok, value.status, value.admittedPlayers = true, "PASS", 8
		value.supportedEnvelope = { measured = true, crossServer = false }
		value.lifecycle = { ok = true, resources = {}, residuals = {} }
		value.blockers = {}
		value.workloadConservation = { ok = true }
		value.recovery = { terminalReadback = { proven = true }, cleanup = { ok = true } }
		value.sha256 = serde.hash("sha256", serde.encode("json", value))
		local report = Capacity.report("primal-isles", 8, value)
		assert(report.candidate.valid, "valid metrics remain inspectable")
		assert(report.candidate.authority == "untrusted-intake", "self-hash cannot confer origin")
		assert(
			not report.ok and report.status == "BLOCKED" and report.admittedPlayers == 0,
			"self-hash cannot admit capacity"
		)
		assert(
			not report.supportedEnvelope.measured and #report.blockers > 0,
			"untrusted intake cannot measure a supported envelope"
		)
	end,
	["identity window environment and workload mismatches reject intake"] = function()
		local mutations: { (typeof(fixture())) -> () } = {
			function(v)
				v.clients[2].actorId = v.clients[1].actorId
			end,
			function(v)
				v.clients[2].sessionId = v.clients[1].sessionId
			end,
			function(v)
				v.clients[1].sessionId = v.run.serverSessionId
			end,
			function(v)
				v.clients[1].loadedRevision = string.rep("d", 40)
			end,
			function(v)
				v.clients[1].loadedBuildSha256 = string.rep("d", 64)
			end,
			function(v)
				v.clients[1].endedAtMs += 1
			end,
			function(v)
				v.server.runId = "other"
			end,
			function(v)
				v.clients[1].robloxVersion = "other"
			end,
			function(v)
				v.run.npcCount += 1
			end,
			function(v)
				table.remove(v.clients)
			end,
			function(v)
				v.clients[1].frameMs = { 0 }
			end,
			function(v)
				v.clients[1].frameMs = { 0 / 0 }
			end,
			function(v)
				v.server.commitLatencyMs = {}
			end,
			function(v)
				v.server.memoryMb = { math.huge }
			end,
			function(v)
				v.server.serializedValues = { "{}" }
			end,
		}
		for _, mutate in mutations do
			local value = fixture()
			mutate(value)
			assert(
				not Capacity.report("primal-isles", 8, value).candidate.valid,
				'not Capacity.report("primal-isles", 8, value).candidate.valid'
			)
		end
	end,
	["frame payload and throttle failures retain measurements without envelope"] = function()
		local value = fixture()
		value.clients[1].frameMs = { 34 }
		value.server.handledThrottleCount = 0
		value.run.payloadMaxBytes = #value.server.serializedValues[1] - 1
		local report = Capacity.report("primal-isles", 8, value)
		assert(
			report.candidate.valid and #report.candidate.metrics.violations == 3,
			"report.candidate.valid and #report.candidate.metrics.violations == 3"
		)
		assert(not report.supportedEnvelope.measured, "not report.supportedEnvelope.measured")
	end,
	["quantiles use nearest rank and retain input order"] = function()
		local values = { 30, 10, 20 }
		local measured = Capacity.samples(values, 0)
		assert(
			measured.p50 == 20 and measured.p95 == 30 and measured.count == 3,
			"measured.p50 == 20 and measured.p95 == 30 and measured.count == 3"
		)
		assert(values[1] == 30, "values[1] == 30")
	end,
	["exact command parses and ambiguous requests reject"] = function()
		local options = Capacity.arguments({ "--pack", "primal-isles", "--players", "8", "--out", "report.json" })
		assert(
			options.players == 8 and options.pack == "primal-isles",
			'options.players == 8 and options.pack == "primal-isles"'
		)
		for _, args in
			{ {}, { "--pack" }, { "--pack", "x", "--pack", "x" }, { "--pack", "x", "--players", "0", "--out", "x" } }
		do
			assert(not pcall(Capacity.arguments, args), "not pcall(Capacity.arguments, args)")
		end
	end,
	["persisted evidence keeps producer array types, exit code and raw strings"] = function()
		-- The collector is a JS producer, so its canonical text carries real []; a
		-- Luau-authored table cannot express an empty array. The persisted document must
		-- splice the collector's own bytes and emit the wrapper's own list fields
		-- explicitly, while an empty object stays {} and is never promoted to a list.
		local payload =
			[=[{"lifecycle":{"ok":true,"resources":[],"residuals":[]},"baseline":[],"matrix":{"stages":[{"phase":"MEASUREMENT","receipt":{},"runs":[]}]},"unknown":{},"note":"literal [ ] { } \"quoted\""}]=]
		local wrapper = {
			schema = "capacity-report/v1",
			status = "BLOCKED",
			ok = false,
			blockers = {},
			recovery = {
				status = "BLOCKED",
				checkpoints = { { phase = "ESCROWED", requestId = "req-1", stateVersion = 3 } },
				blockers = {},
			},
			candidate = { supplied = true, valid = true, authority = "untrusted-intake", metrics = { violations = {} } },
			collector = serde.decode("json", payload),
		}
		local document = Capacity.evidenceDocument(wrapper, payload, wrapper.collector, 7)
		local parsed = serde.decode("json", document)
		assert(
			parsed.schema == "capacity-report/v1" and parsed.status == "BLOCKED" and parsed.ok == false,
			"wrapper scalars survive"
		)
		assert(parsed.collector.exitCode == 7, "authoritative exit code is persisted in the collector")
		assert(parsed.collector.note == 'literal [ ] { } "quoted"', "raw string content is preserved verbatim")
		assert(
			#parsed.collector.matrix.stages == 1 and parsed.collector.matrix.stages[1].phase == "MEASUREMENT",
			"collector payload parses completely"
		)
		assert(#parsed.blockers == 0, "empty top-level blockers parse")
		assert(#parsed.recovery.blockers == 0, "empty recovery blockers parse")
		assert(#parsed.candidate.metrics.violations == 0, "empty candidate violations parse")
		-- A populated checkpoint proof keeps its array shape and every field.
		assert(#parsed.recovery.checkpoints == 1, "populated checkpoints parse as an array")
		assert(
			parsed.recovery.checkpoints[1].phase == "ESCROWED"
				and parsed.recovery.checkpoints[1].requestId == "req-1"
				and parsed.recovery.checkpoints[1].stateVersion == 3,
			"checkpoint proof fields survive"
		)
		-- Array-ness is only observable in the serialized text: decoding [] and {} both
		-- yield an empty table.
		for _, expected in
			{
				'"resources":[]',
				'"residuals":[]',
				'"baseline":[]',
				'"runs":[]',
				'"blockers":[]',
				'"violations":[]',
				'"checkpoints":[{',
			}
		do
			assert(string.find(document, expected, 1, true) ~= nil, "producer array preserved: " .. expected)
		end
		assert(string.find(document, '"exitCode":7', 1, true) ~= nil, "exit code present in the collector bytes")
		-- A genuinely empty object is never promoted to an array, top level or nested.
		assert(string.find(document, '"unknown":{}', 1, true) ~= nil, "empty object stays an object")
		assert(string.find(document, '"receipt":{}', 1, true) ~= nil, "nested empty object stays an object")
		assert(string.find(document, '"unknown":[]', 1, true) == nil, "empty object is not promoted to an array")
		-- A raw payload that already declares the authoritative field is refused, so the
		-- splice can never emit a duplicate top-level key.
		assert(
			not pcall(Capacity.evidenceDocument, wrapper, '{"exitCode":1}', { exitCode = 1 }, 7),
			"a duplicate exitCode key is refused"
		)
	end,
	["evidence document without a collector preserves wrapper list types"] = function()
		-- The --evidence intake path has no raw collector payload, so the document is
		-- composed entirely from the wrapper: its own declared lists must still be
		-- arrays, an empty object must stay an object, and no collector is invented.
		local wrapper = {
			schema = "capacity-report/v1",
			status = "BLOCKED",
			ok = false,
			blockers = {},
			recovery = { status = "BLOCKED", checkpoints = {}, blockers = {} },
			candidate = {
				supplied = true,
				valid = true,
				authority = "untrusted-intake",
				metrics = { violations = {} },
				unknown = {},
			},
		}
		local document = Capacity.evidenceDocument(wrapper, nil, nil, nil)
		local parsed = serde.decode("json", document)
		assert(parsed.collector == nil, "no collector member is invented")
		assert(string.find(document, '"collector"', 1, true) == nil, "no collector key is written")
		assert(#parsed.recovery.checkpoints == 0, "empty wrapper checkpoints parse")
		assert(#parsed.blockers == 0 and #parsed.recovery.blockers == 0, "empty wrapper blockers parse")
		assert(#parsed.candidate.metrics.violations == 0, "empty wrapper violations parse")
		for _, expected in { '"checkpoints":[]', '"blockers":[]', '"violations":[]' } do
			assert(string.find(document, expected, 1, true) ~= nil, "empty wrapper list preserved: " .. expected)
		end
		assert(string.find(document, '"unknown":{}', 1, true) ~= nil, "wrapper empty object stays an object")
		assert(string.find(document, '"unknown":[]', 1, true) == nil, "wrapper empty object is not promoted")
	end,
}
