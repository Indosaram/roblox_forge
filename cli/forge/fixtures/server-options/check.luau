--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local Session = require("../../../../core/infra/genre/Session")
local Options = require("../../../../core/infra/genre/Options")
local Clock = require("../../../../core/infra/genre/Clock")
local Memory = require("../../../../core/infra/data/MemoryBackend")
local Arena = require("../../../../genres/pvp-arena/module/Contract")
local Fixture = require("../../../../genres/pvp-arena/module/Adapter.fixture")
local Transport = require("../../../../core/infra/genre/CommandTransport")
local Shared = require("../../../../core/domain/genre/Contract")
local function options(): any
	return {
		packConfig = { api = 1, order = { Arena.id }, configs = { [Arena.id] = Fixture } },
		contracts = { Arena },
		controls = {},
		storeName = "ServerOptions",
		backend = Memory.new(),
	}
end
local invalidWorlds: { any } = { 0, "false", {} }
for _, value in invalidWorlds do
	local input = options()
	input.starterWorld = value
	assert(not pcall(Options.validate, input), "invalid starterWorld boundary rejected")
end
local invalidClocks: { any } = { false, 1, {}, {
	now = function()
		return 1
	end,
} }
for _, value in invalidClocks do
	local input = options()
	input.clock = value
	assert(not pcall(Options.validate, input), "invalid clock boundary rejected")
end
local invalid = options()
invalid.clock = Clock.new(function()
	return 1
end)
invalid.clock.extra = true
assert(not pcall(Options.validate, invalid), "unknown clock field rejected")

local function run(custom: boolean)
	local objects: { any } = {}
	local function event(): any
		local callbacks: { (...any) -> () } = {}
		return {
			Connect = function(_, callback)
				table.insert(callbacks, callback)
				return { Disconnect = function() end }
			end,
			Fire = function(_, ...)
				for _, callback in callbacks do
					callback(...)
				end
			end,
		}
	end
	local function instance(kind: string): any
		local object: any = { ClassName = kind, Name = kind, Triggered = event() }
		function object:FindFirstChild(name: string): any
			for _, child in objects do
				if child.Parent == self and child.Name == name then
					return child
				end
			end
			return nil
		end
		function object:FireClient() end
		function object:Fire() end
		table.insert(objects, object)
		return object
	end
	local workspace = instance("Workspace")
	local authored = instance("Folder")
	authored.Name, authored.Parent = "Authored", workspace
	local authoredSpawn = instance("SpawnLocation")
	authoredSpawn.Parent = authored
	local players: any = instance("Players")
	local player: any = {
		UserId = 1,
		DisplayName = "Actor",
		Parent = players,
		Kick = function()
			error("unexpected kick")
		end,
	}
	players.GetPlayers = function()
		return { player }
	end
	players.GetPlayerByUserId = function()
		return player
	end
	players.PlayerAdded, players.PlayerRemoving = event(), event()
	local runService = {
		IsStudio = function()
			return true
		end,
		Heartbeat = event(),
	}
	local storage, replicated = instance("ServerStorage"), instance("ReplicatedStorage")
	local dependencies: { [string]: any } = {
		["./Options"] = Options,
		["./Clock"] = Clock,
		["./CommandTransport"] = Transport,
		["../data/MemoryBackend"] = Memory,
		["../data/DataStoreBackend"] = {},
		["../../domain/genre/Contract"] = Shared,
	}
	local shutdown: (() -> ())? = nil
	local sharedClock = Clock.new(function()
		return 7
	end)
	local servicesNow: (() -> number)? = nil
	local leaseNow: (() -> number)? = nil
	local lastAdvance: number? = nil
	local bound = false
	local closed = false
	local serverCommandRequest: any = nil
	dependencies["./Session"] = {
		new = function(input, backend, storeOptions, services, policy)
			servicesNow, leaseNow = services.now, storeOptions.now
			local session = Session.new(input, backend, storeOptions, services, policy)
			session.commandServer = function(id, request)
				assert(id == "1", "server QA actor retained")
				serverCommandRequest = request
				return { ok = false, reason = "TEST_SERVER_REFUSAL" }
			end
			local join, advance = session.join, session.advance
			session.join = function(id)
				assert(bound, "lifecycle binds before existing-player join")
				return join(id)
			end
			session.advance = function(value)
				lastAdvance = value
				assert(
					assert(services.now, "gameplay clock provided")() == value,
					"Session shared services see the same advanced clock"
				)
				advance(value)
			end
			return session
		end,
	}
	local server = luau.load(fs.readFile("core/infra/genre/Server.luau"), {
		environment = {
			game = {
				JobId = "server-options",
				GetService = function(_, name)
					return ({
						Players = players,
						RunService = runService,
						ServerStorage = storage,
						ReplicatedStorage = replicated,
						HttpService = {
							GenerateGUID = function()
								return "guid"
							end,
							JSONEncode = function(_, value)
								return serde.encode("json", value)
							end,
						},
					})[name]
				end,
				BindToClose = function(_, callback)
					shutdown = callback
				end,
			},
			workspace = workspace,
			Instance = { new = instance },
			Vector3 = {
				new = function(x, y, z)
					return { X = x, Y = y, Z = z }
				end,
			},
			DateTime = {
				now = function()
					return { UnixTimestampMillis = 100000 }
				end,
			},
			Random = {
				new = function()
					return {
						NextNumber = function()
							return 0
						end,
					}
				end,
			},
			task = {
				spawn = function(callback, ...)
					callback(...)
				end,
				wait = function()
					error("unexpected retry")
				end,
			},
			require = function(path)
				return assert(dependencies[path], "unexpected dependency")
			end,
		},
	})()
	local input = options()
	input.lifecycle = {
		bind = function(session)
			assert(#session.members() == 0, "bind precedes all personal ownership")
			bound = true
		end,
		close = function()
			closed = true
			return { ok = true }
		end,
	}
	if custom then
		input.clock, input.starterWorld = sharedClock, false
	end
	input.controls =
		{ { id = "pvp-arena:queue", action = "pvp-arena:enqueue", args = {}, label = "Queue", kind = "prompt" } }
	local session = server.start(input)
	assert(#session.members() == 1 and bound, "actual Server.start joined existing player")
	local starter = workspace:FindFirstChild("ForgeStarter")
	local spawnCount = 0
	local promptCount = 0
	for _, object in objects do
		if object.ClassName == "SpawnLocation" then
			spawnCount += 1
		end
		if object.ClassName == "ProximityPrompt" then
			promptCount += 1
		end
	end
	assert(authored.Parent == workspace and authoredSpawn.Parent == authored, "authored world preserved")
	if custom then
		assert(starter == nil and spawnCount == 1 and promptCount == 0, "opt out prevents starter spawn and prompts")
	else
		assert(
			starter and starter:FindFirstChild("Floor") and spawnCount == 2 and promptCount == 1,
			"legacy default creates floor spawn and prompts"
		)
	end
	local qa = assert(storage:FindFirstChild("ForgeQA"), "actual ForgeQA exists")
	local serverCommand = assert(qa:FindFirstChild("commandServer"), "Studio-only server command exists")
	assert(
		serverCommand.OnInvoke("1", "undeclared", "pvp-arena:enqueue", {}).reason == "UNDECLARED_SERVER_COMMAND"
			and serverCommandRequest == nil,
		"undeclared server QA command never reaches Session"
	)
	input.durable = { actions = {}, serverActions = { "pvp-arena:server-test" } }
	assert(
		serverCommand.OnInvoke("1", "server-request", "pvp-arena:server-test", { "value" }).reason
			== "TEST_SERVER_REFUSAL",
		"actual Session result propagated"
	)
	assert(
		serverCommandRequest.requestId == "server-request"
			and serverCommandRequest.action == "pvp-arena:server-test"
			and serverCommandRequest.args[1] == "value",
		"server request identity and arguments retained"
	)
	local base = qa:FindFirstChild("beginClock").OnInvoke()
	assert(base == (if custom then 7 else 100), "QA starts selected clock")
	qa:FindFirstChild("advanceElapsed").OnInvoke(2)
	assert(
		lastAdvance == base + 2 and assert(servicesNow, "services clock captured")() == base + 2,
		"elapsed updates actual Session clock"
	)
	qa:FindFirstChild("advanceTo").OnInvoke(base + 5)
	assert(lastAdvance == base + 5, "absolute QA advance reaches Session")
	if custom then
		assert(sharedClock.now() == 12, "factory clock shares manual QA time")
	end
	runService.Heartbeat:Fire(1)
	assert(lastAdvance == base + 5, "heartbeat uses selected manual clock")
	assert(assert(leaseNow, "lease clock captured")() == 100, "leases retain real wall clock")
	assert(shutdown, "shutdown registered")()
	assert(closed and #session.members() == 0, "personal sessions close before lifecycle resources")
	print(
		"PASS actual Server.start " .. (if custom then "shared clock authored world" else "legacy clock starter world")
	)
end
run(false)
run(true)
local suites: { { [string]: () -> () } } =
	{ require("../../lib/command-transport.spec"), require("../../lib/genre-server.spec") }
for _, cases in suites do
	for name, check in cases do
		check()
		print("PASS " .. name)
	end
end
