--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Session = require("../../../core/infra/genre/Session")
local Options = require("../../../core/infra/genre/Options")
local MemoryBackend = require("../../../core/infra/data/MemoryBackend")
local Arena = require("../../../genres/pvp-arena/module/Contract")
local Fixture = require("../../../genres/pvp-arena/module/Adapter.fixture")
local Clock = require("../../../core/infra/genre/Clock")
local Contract = require("../../../core/domain/genre/Contract")

return {
	["actual RemoteFunction authenticates durable command and rejects legacy bypass"] = function()
		local Survival = require("../../../genres/survival-coop/module/Contract")
		local config = table.clone(require("../../../genres/survival-coop/module/Adapter.fixture").config)
		config.startingBalance = 100
		local remote: any
		local actual: Session.Session? = nil
		local player = { UserId = 1, DisplayName = "Actor" }
		local players = {
			GetPlayers = function()
				return { player }
			end,
			GetPlayerByUserId = function()
				return player
			end,
		}
		local dependencies = {
			["./Options"] = Options,
			["../data/MemoryBackend"] = MemoryBackend,
			["../data/DataStoreBackend"] = {},
			["../../domain/genre/Contract"] = Contract,
			["./Clock"] = Clock,
			["../../domain/random/Rng"] = require("../../../core/domain/random/Rng"),
			["./CommandTransport"] = require("../../../core/infra/genre/CommandTransport"),
			["./OutfitPresenter"] = {
				bindings = function()
					return {}
				end,
				apply = function() end,
			},
		}
		local server = luau.load(fs.readFile("core/infra/genre/Server.luau"), {
			environment = {
				game = {
					JobId = "remote-proof",
					GetService = function(_self: any, name: string): any
						if name == "Players" then
							return players
						end
						if name == "HttpService" then
							return {
								GenerateGUID = function()
									return "guid"
								end,
							}
						end
						return {
							FindFirstChild = function()
								return nil
							end,
						}
					end,
				},
				DateTime = {
					now = function()
						return { UnixTimestampMillis = 100000 }
					end,
				},
				Instance = {
					new = function(kind: string): any
						if kind == "Folder" then
							error("remote bound")
						end
						local object = { FireClient = function() end }
						if kind == "RemoteFunction" then
							remote = object
						end
						return object
					end,
				},
				require = function(path: string): any
					if path == "./Session" then
						return {
							new = function(input: any, backend: any, opts: any, services: any, policy: any)
								actual = Session.new(input, backend, opts, services, policy)
								assert(actual ~= nil and actual.join("1").ok, "real session joined")
								return actual
							end,
						}
					end
					return dependencies[path]
				end,
			},
		})()
		local ok, err = pcall(server.start, {
			packConfig = { api = 1, order = { Survival.id }, configs = { [Survival.id] = config } },
			contracts = { Survival },
			controls = {},
			storeName = "RemoteProof",
			backend = MemoryBackend.new(),
			durable = { actions = { "survival-coop:buy-defense" } },
		})
		assert(not ok and string.find(tostring(err), "remote bound", 1, true), "stop after actual remote binding")
		local handshake = remote.OnServerInvoke(player)
		assert(handshake.ok and handshake.durable.sessionEpoch == 0, "server issued handshake")
		assert(
			remote.OnServerInvoke(player, "survival-coop:buy-defense", {}).reason == "DURABLE_COMMAND_REQUIRED",
			"legacy bypass denied"
		)
		local request: any = {
			requestId = "remote-one",
			sessionEpoch = 0,
			action = "survival-coop:buy-defense",
			args = {},
			actorId = "2",
		}
		assert(not remote.OnServerInvoke(player, "command", request).ok, "payload actor cannot impersonate")
		request.actorId = nil
		assert(remote.OnServerInvoke(player, "command", request).stateVersion == 1, "actual durable remote commits")
		assert(remote.OnServerInvoke(player, "command", request).stateVersion == 1, "actual remote retry replays")
		assert(actual ~= nil and actual.snapshot("1")[Survival.id].balance == 90, "single native debit")
		assert(actual.close("1").ok, "release")
	end,
	["actual durable runtime scripts compile"] = function()
		for _, path in { "core/infra/genre/Server.luau", "core/infra/genre/Client.luau" } do
			assert(#luau.compile(fs.readFile(path)) > 0, "runtime compiles to bytecode")
		end
	end,
	["actual generic server wires production persistence backoff"] = function()
		local delays: { number } = {}
		local backend = MemoryBackend.new()
		backend.failNext(3)
		local joined = false
		local server = luau.load(fs.readFile("core/infra/genre/Server.luau"), {
			environment = {
				game = {
					JobId = "proof",
					GetService = function(_self: any, name: string): any
						if name == "HttpService" then
							return {
								GenerateGUID = function()
									return "guid"
								end,
							}
						end
						return {}
					end,
				},
				DateTime = {
					now = function()
						return { UnixTimestampMillis = 100000 }
					end,
				},
				task = {
					wait = function(duration: number)
						table.insert(delays, duration)
					end,
				},
				require = function(path: string): any
					if path == "./Session" then
						return {
							new = function(options: any, actualBackend: any, storeOptions: any, services: any)
								local session = Session.new(options, actualBackend, storeOptions, services)
								assert(session.join("1").ok, "real ProfileStore succeeds after throttled attempts")
								joined = true
								error("persistence boundary reached")
							end,
						}
					end
					local dependencies = {
						["./Options"] = Options,
						["../data/MemoryBackend"] = MemoryBackend,
						["../data/DataStoreBackend"] = {},
						["../../domain/genre/Contract"] = Contract,
						["./Clock"] = Clock,
						["../../domain/random/Rng"] = require("../../../core/domain/random/Rng"),
						["./CommandTransport"] = require("../../../core/infra/genre/CommandTransport"),
						["./OutfitPresenter"] = {
							bindings = function()
								return {}
							end,
							apply = function() end,
						},
					}
					assert(dependencies[path] ~= nil, "unexpected dependency")
					return dependencies[path]
				end,
			},
		})()
		local ok, err = pcall(server.start, {
			packConfig = { api = 1, order = { "pvp-arena" }, configs = { ["pvp-arena"] = Fixture } },
			contracts = { Arena },
			controls = {},
			storeName = "test",
			backend = backend,
		})
		assert(
			not ok and string.find(tostring(err), "persistence boundary reached", 1, true),
			"stops before world setup"
		)
		assert(joined, "actual Server.start passes options to real Session and ProfileStore")
		assert(#delays == 3 and delays[1] == 1 and delays[2] == 2 and delays[3] == 4, "production retry durations")
	end,
	["actual join retries transient transport failures before kicking"] = function()
		local attributes: { [string]: string } = {}
		local delays: { number } = {}
		local joinCallback: ((any) -> ())? = nil
		local kicked: any = nil
		local players = {
			GetPlayers = function()
				return {}
			end,
			GetPlayerByUserId = function()
				return nil
			end,
			PlayerAdded = {
				Connect = function(_self: any, callback: (any) -> ())
					joinCallback = callback
				end,
			},
			PlayerRemoving = { Connect = function() end },
		}
		local outcomes: { any } = {
			{ ok = false, reason = "LOCAL_TRANSPORT_UNAVAILABLE" },
			{ ok = false, reason = "LOCAL_TRANSPORT_UNAVAILABLE" },
			{ ok = true },
			{ ok = false, reason = "BAD_SAVE" },
		}
		local attempts = 0
		local dependencies: { [string]: any } = {
			["./Options"] = Options,
			["../data/MemoryBackend"] = MemoryBackend,
			["../data/DataStoreBackend"] = {},
			["../../domain/genre/Contract"] = Contract,
			["./Clock"] = Clock,
			["../../domain/random/Rng"] = require("../../../core/domain/random/Rng"),
			["./CommandTransport"] = require("../../../core/infra/genre/CommandTransport"),
			["./OutfitPresenter"] = {
				bindings = function()
					return {}
				end,
				apply = function() end,
			},
		}
		local server = luau.load(fs.readFile("core/infra/genre/Server.luau"), {
			environment = {
				game = {
					JobId = "join-retry-proof",
					GetService = function(_self: any, name: string): any
						if name == "Players" then
							return players
						end
						if name == "HttpService" then
							return {
								GenerateGUID = function()
									return "guid"
								end,
								JSONEncode = function()
									return "{}"
								end,
							}
						end
						if name == "RunService" then
							return {
								IsStudio = function()
									return false
								end,
								Heartbeat = { Connect = function() end },
							}
						end
						if name == "ServerStorage" then
							return {
								FindFirstChild = function()
									return nil
								end,
								SetAttribute = function(_service: any, key: string, value: any)
									attributes[key] = value
								end,
							}
						end
						return {
							FindFirstChild = function()
								return nil
							end,
						}
					end,
					BindToClose = function() end,
				},
				DateTime = {
					now = function()
						return { UnixTimestampMillis = 100000 }
					end,
				},
				Instance = {
					new = function()
						return { FireClient = function() end }
					end,
				},
				task = {
					wait = function(duration: number)
						table.insert(delays, duration)
					end,
					spawn = function() end,
				},
				require = function(path: string): any
					if path == "./Session" then
						return {
							new = function()
								return {
									members = function()
										return {}
									end,
									join = function(_id: string): any
										attempts += 1
										return table.remove(outcomes, 1) or { ok = true }
									end,
									close = function()
										return { ok = true }
									end,
								}
							end,
						}
					end
					return dependencies[path]
				end,
			},
		})()
		local session = server.start({
			packConfig = { api = 1, order = { "pvp-arena" }, configs = { ["pvp-arena"] = Fixture } },
			contracts = { Arena },
			controls = {},
			storeName = "JoinRetryProof",
			backend = MemoryBackend.new(),
			starterWorld = false,
		})
		assert(session ~= nil and joinCallback ~= nil, "server binds PlayerAdded after startup")
		local recovered: any = {
			UserId = 1,
			Kick = function(_self: any, message: any)
				error("recovered player kicked: " .. tostring(message))
			end,
		}
		local fireJoin = joinCallback :: any
		recovered.Parent = players
		fireJoin(recovered)
		assert(attempts == 3, "transient transport failures retry until the profile loads")
		local expected = require("../../../core/domain/random/Rng").new(100000):fork("join-retry")
		assert(session.seed == 100000, "session exposes the time-derived seed")
		assert(
			#delays == 2
				and delays[1] == 1 + expected:nextNumber() * 3
				and delays[2] == 1 + expected:nextNumber() * 3
				and delays[1] ~= delays[2],
			"retry delays are jittered from the forked seeded stream"
		)
		assert(attributes.ForgeLastKick == nil, "recovery records no kick")
		local terminal: any = {
			UserId = 2,
			Kick = function(_self: any, message: any)
				kicked = message
			end,
		}
		terminal.Parent = players
		fireJoin(terminal)
		assert(attempts == 4 and kicked == "Profile unavailable: BAD_SAVE", "non-transient failure still kicks")
		assert(attributes.ForgeLastKick == "2 BAD_SAVE", "kick reason readback")
	end,
}
