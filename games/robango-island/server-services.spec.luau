--!strict
-- Server.start validates the bootstrap's published services through Options.validate. This boots the
-- pack's real SurvivalFactory with its real WildlifePolicy and TamingConfig (the shape Studio starts)
-- and runs that same validation, so a port that grows an unvalidated field fails here, not in Studio.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Bootstrap = require("../../genres/survival-coop/module/SurvivalBootstrap")
local Gathering = require("../../genres/survival-coop/module/Gathering")
local Wildlife = require("../../genres/survival-coop/module/Wildlife")
local Extensions = require("../../genres/survival-coop/module/Extensions")
local HomeExtension = require("../../genres/survival-coop/module/HomeExtension")
local ArchipelagoExtension = require("../../genres/survival-coop/module/ArchipelagoExtension")
local ActorDocumentStore = require("../../core/infra/data/ActorDocumentStore")
local Archipelago = require("../../core/domain/island/Archipelago")
local Session = require("../../core/infra/genre/Session")
local LateEquipmentPorts = require("./src/server/LateEquipmentPorts")
local TamingExtension = require("../../genres/survival-coop/module/TamingExtension")
local Contract = require("../../genres/survival-coop/module/Contract")
local Settlement = require("../../core/domain/settlement/Settlement")
local Inventory = require("../../core/domain/inventory/Inventory")
local Job = require("../../core/domain/crafting/Job")
local Journal = require("../../core/domain/command/Journal")
local Clock = require("../../core/infra/genre/Clock")
local Options = require("../../core/infra/genre/Options")
local Memory = require("../../core/infra/data/MemoryBackend")
local content = require("./src/shared/SurvivalContent")
local source = require("./src/shared/SurvivalWorldConfig")
local wildlifePolicy = require("./src/shared/WildlifePolicy")
local tamingPolicy = require("./src/shared/TamingConfig")

local PACK = "games/robango-island"
local forge = {
	genres = {
		["survival-coop"] = {
			module = {
				SurvivalBootstrap = Bootstrap,
				Gathering = Gathering,
				Wildlife = Wildlife,
				Extensions = Extensions,
				HomeExtension = HomeExtension,
				ArchipelagoExtension = ArchipelagoExtension,
				JournalPorts = require("../../genres/survival-coop/module/JournalPorts"),
				JournalObjectiveFeed = require("../../genres/survival-coop/module/JournalObjectiveFeed"),
				JournalExtension = require("../../genres/survival-coop/module/JournalExtension"),
				ProgressionExtension = require("../../genres/survival-coop/module/ProgressionExtension"),
				ToolTiers = require("../../genres/survival-coop/module/ToolTiers"),
				ExpeditionExtension = require("../../genres/survival-coop/module/ExpeditionExtension"),
				ProgressionPorts = require("../../genres/survival-coop/module/ProgressionPorts"),
			},
		},
	},
	core = {
		domain = {
			home = { HomeContent = require("../../core/domain/home/HomeContent") },
			island = { Archipelago = Archipelago },
			settlement = { Settlement = Settlement },
			inventory = { Inventory = Inventory },
			crafting = { Job = Job },
			command = { Journal = Journal },
		},
		infra = { genre = { Clock = Clock, Session = Session }, data = { ActorDocumentStore = ActorDocumentStore } },
	},
}
local environment: any = {
	script = { Parent = { LateEquipmentPorts = LateEquipmentPorts } },
	game = {
		GetService = function()
			return {
				WaitForChild = function()
					return forge
				end,
			}
		end,
	},
	task = task,
	Vector3 = {
		new = function(x, y, z)
			return { X = x, Y = y, Z = z }
		end,
	},
	require = function(value)
		return value
	end,
}
local function module(name: string): any
	return luau.load(fs.readFile(PACK .. "/src/server/" .. name .. ".luau"), { environment = environment })()
end

return {
	["unpublished Studio boot constructs cloud-backed stores before publishing gameplay remotes"] = function()
		local function signal(): any
			return {
				Connect = function()
					return { Disconnect = function() end }
				end,
			}
		end
		local function folder(): any
			return {
				children = {},
				FindFirstChild = function(self, name)
					return self.children[name]
				end,
			}
		end
		local replicated, storage = folder(), folder()
		local players = {
			PlayerAdded = signal(),
			PlayerRemoving = signal(),
			GetPlayers = function()
				return {}
			end,
		}
		local run = {
			IsStudio = function()
				return true
			end,
			Heartbeat = signal(),
		}
		local http = {
			GenerateGUID = function()
				return "boot-session"
			end,
			JSONEncode = function(_, value)
				return serde.encode("json", value)
			end,
			JSONDecode = function(_, value)
				return serde.decode("json", value)
			end,
		}
		local services = {
			ReplicatedStorage = replicated,
			ServerStorage = storage,
			Players = players,
			RunService = run,
			HttpService = http,
			MarketplaceService = {},
			PolicyService = {},
			TeleportService = {},
		}
		local bootForge = table.clone(forge)
		bootForge.core = table.clone(forge.core)
		bootForge.core.infra = table.clone(forge.core.infra)
		bootForge.core.infra.data = table.clone(forge.core.infra.data)
		bootForge.core.infra.genre = table.clone(forge.core.infra.genre)
		bootForge.genres = { ["survival-coop"] = { module = table.clone(forge.genres["survival-coop"].module) } }
		local modules = bootForge.genres["survival-coop"].module
		local shared: any = {}
		for _, name in
			{
				"SurvivalContent",
				"SurvivalWorldConfig",
				"WildlifePolicy",
				"TamingConfig",
				"MonetizationCatalog",
				"MarketPorts",
				"GenreDurable",
				"GenreConfig",
				"GenreSpec",
				"GenreUI",
			}
		do
			shared[name] = require("./src/shared/" .. name)
		end
		bootForge.games = { ["robango-island"] = { src = { shared = shared } } }
		function replicated:WaitForChild(name)
			assert(name == "Forge", "replicated module root")
			return bootForge
		end
		local bootEnv: any = table.clone(environment)
		bootEnv.game = {
			GameId = 0,
			PlaceId = 0,
			JobId = "",
			PrivateServerId = "",
			GetService = function(_, name)
				assert(services[name], "unpublished Studio attempted cloud service: " .. name)
				return services[name]
			end,
			BindToClose = function() end,
		}
		bootEnv.DateTime = {
			now = function()
				return { UnixTimestampMillis = 1000000 }
			end,
		}
		bootEnv.Enum = { ProductPurchaseDecision = {}, SortDirection = { Ascending = "asc", Descending = "desc" } }
		bootEnv.workspace = {
			GetAttribute = function()
				return nil
			end,
			SetAttribute = function() end,
			GetAttributeChangedSignal = signal,
		}
		bootEnv.Instance = {
			new = function(class)
				return setmetatable({ ClassName = class, children = {} }, {
					__newindex = function(self, key, value)
						rawset(self, key, value)
						if key == "Parent" then
							value.children[self.Name] = self
						end
					end,
				})
			end,
		}
		local function load(path: string): any
			return luau.load(fs.readFile(path), { environment = bootEnv })()
		end
		modules.Contract = Contract
		shared.GenreRuntime = load(PACK .. "/src/shared/GenreRuntime.luau")
		bootForge.core.infra.data.RuntimeServices = load("core/infra/data/RuntimeServices.luau")
		local backendEnv = table.clone(bootEnv)
		backendEnv.require = function(name)
			if name == "./DataStoreBackend" then
				return {
					new = function()
						error("unpublished Studio requested production backend")
					end,
				}
			end
			return require("../../core/infra/data/" .. name)
		end
		bootForge.core.infra.data.RuntimeBackend =
			luau.load(fs.readFile("core/infra/data/RuntimeBackend.luau"), { environment = backendEnv })()
		for _, name in { "CrossServerMarketStore", "ClanStore" } do
			bootForge.core.infra.data[name] = require("../../core/infra/data/" .. name)
		end
		bootForge.core.infra.island = {
			HomeReservation = require("../../core/infra/island/HomeReservation"),
			Friends = require("../../core/infra/island/Friends"),
		}
		bootForge.core.infra.monetization = {
			MarketplacePort = require("../../core/infra/monetization/MarketplacePort"),
			PolicyPort = require("../../core/infra/monetization/PolicyPort"),
		}
		modules.IslandBootstrap = {
			select = function()
				return "onboarding", false
			end,
			start = function()
				return {}
			end,
		}
		for _, name in { "MonetizationExtension", "MarketExtension", "TamingExtension" } do
			modules[name] = require("../../genres/survival-coop/module/" .. name)
		end
		modules.ScoreLibraryStore = require("../../genres/survival-coop/module/ScoreLibraryStore")
		for _, name in { "EnsembleRange", "EnsembleExtension", "ScoreTransport", "CrossServerMarketExtension" } do
			modules[name] = require("../../genres/survival-coop/module/" .. name)
		end
		bootForge.core.infra.data.ClanStoreWallet = require("../../core/infra/data/ClanStoreWallet")
		bootForge.core.infra.data.CrossServerMarketPersonal = require("../../core/infra/data/CrossServerMarketPersonal")
		bootForge.core.domain.settlement = table.clone(forge.core.domain.settlement)
		bootForge.core.domain.settlement.Clan = require("../../core/domain/settlement/Clan")
		bootForge.core.domain.command = table.clone(forge.core.domain.command)
		bootForge.core.domain.command.Ledger = require("../../core/domain/command/Ledger")
		local world: any = {
			services = {
				survivalSpatial = {
					campfire = function()
						return nil
					end,
					station = function()
						return nil
					end,
				},
			},
			settlementPorts = function()
				return {
					warehouse = function()
						return true
					end,
					verify = function()
						return true
					end,
					publish = function() end,
				}
			end,
			gatheringAccess = function()
				return function()
					return nil
				end
			end,
			wildlifeAccess = function()
				return nil
			end,
			publishWildlife = function() end,
			bind = function() end,
			destroy = function() end,
		}
		local parent: any = {
			PersistenceConfig = { mode = "memory" },
			LateEquipmentPorts = LateEquipmentPorts,
			SurvivalProvisionConfig = require("./src/server/SurvivalProvisionConfig"),
			GenreHooks = require("./src/server/GenreHooks"),
			SurvivalWorldBootstrap = function()
				return world
			end,
		}
		bootEnv.script = { Parent = parent, Destroying = signal() }
		parent.SurvivalProvision = load(PACK .. "/src/server/SurvivalProvision.luau")
		parent.SurvivalFactory = load(PACK .. "/src/server/SurvivalFactory.luau")
		local serverEnv = table.clone(bootEnv)
		serverEnv.require = function(name)
			if name == "../data/DataStoreBackend" then
				return {
					new = function()
						error("unpublished Studio requested production backend")
					end,
				}
			end
			return require("../../core/infra/genre/" .. name)
		end
		bootForge.core.infra.genre.Server =
			luau.load(fs.readFile("core/infra/genre/Server.luau"), { environment = serverEnv })()
		load(PACK .. "/src/server/RobangoIslandServer.server.luau")
		assert(replicated:FindFirstChild("ForgeState").ClassName == "RemoteEvent", "state remote published")
		assert(replicated:FindFirstChild("ForgeAction").ClassName == "RemoteFunction", "action remote published")
		assert(world.musicRepository and world.marketStore and world.clanDirectory, "real stores constructed")
		modules.BrawlController = require("../../genres/survival-coop/module/BrawlController")
		modules.Combat = require("../../genres/survival-coop/module/Combat")
		bootForge.core.domain.brawl = { Match = require("../../core/domain/brawl/Match") }
		local brawl = load(PACK .. "/src/server/BrawlRuntime.luau").new(content, world, {
			sessionId = "boot-brawl",
			leaseSeconds = 120,
			now = function()
				return 1000
			end,
		}, {}, function()
			return 1000
		end, wildlifePolicy)
		assert(brawl.snapshot(), "brawl acquires unpublished Studio services")
		local transport = assert(
			modules.ScoreTransport.factory({
				content = content,
				now = function()
					return 1000
				end,
			}),
			"score transport configured"
		)
		Options.validateExtensions({ transport })
		assert(Session.lifecycle(transport).releaseActor("123").ok, "score upload lifecycle cleanup")
		for _, name in
			{ "MonetizationExtension", "MarketExtension", "TamingExtension", "EnsembleExtension", "ScoreTransport" }
		do
			modules[name].configure(nil)
		end
	end,
	["the real factory with wildlife and taming publishes services Options.validate accepts"] = function()
		local Provision = module("SurvivalProvision")
		local Factory = module("SurvivalFactory")
		local provision = Provision(
			{ provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} },
			source.tribe.config.tribeId,
			{ studio = false, server = "job:services" }
		)
		local world: any = {
			services = {
				survivalSpatial = {
					campfire = function()
						return nil
					end,
					station = function()
						return nil
					end,
				},
			},
			settlementPorts = function()
				return {
					warehouse = function()
						return true
					end,
					verify = function()
						return true
					end,
					publish = function() end,
				}
			end,
			gatheringAccess = function()
				return function()
					return nil
				end
			end,
			wildlifeAccess = function()
				return nil
			end,
			publishWildlife = function() end,
			bind = function() end,
			destroy = function() end,
		}
		local at = { value = 1000 }
		local clock = Clock.new(function()
			return at.value
		end)
		TamingExtension.configure(tamingPolicy :: any)
		local factory = assert(Factory(content, source, world, Memory.new(), clock, {
			sessionId = "services",
			leaseSeconds = 120,
			now = function()
				return math.floor(at.value)
			end,
			budget = {
				encode = function(value)
					return serde.encode("json", value)
				end,
			},
		}, provision, wildlifePolicy))
		TamingExtension.configure(nil)
		local services = factory.services
		assert(services.survivalGathering.receipt, "trusted gather receipt port is published")
		assert((factory :: any).gatherReceipt("123", 0, "missing") == nil, "unbound factory cannot invent receipt")
		local expedition = (factory :: any).expeditionStore
		local saved = expedition.transaction("123", function(document)
			document.archipelago = { stage = 1, status = "active" }
			return { ok = true }
		end)
		assert(saved.ok, "production factory owns a durable expedition document")
		local expeditionExtension = nil
		for _, extension in services.survivalExtensions or {} do
			if extension.id == "archipelago" then
				expeditionExtension = extension
			end
		end
		assert(expeditionExtension, "expedition snapshot and lifecycle are registered")
		local lifecycle = Session.lifecycle(expeditionExtension)
		assert(lifecycle.releaseActor and lifecycle.resumeActor, "serialized extension preserves handoff lifecycle")
		assert(lifecycle.releaseActor("123").ok, "handoff releases expedition lease")
		assert(not expedition.snapshot("123"), "released actor cannot retain expedition authority")
		assert(lifecycle.resumeActor("123").ok, "failed teleport resumes expedition lease")
		assert(expedition.snapshot("123").archipelago.stage == 1, "handoff resume conserves expedition state")
		assert(services.survivalWildlife, "wildlife port is published")
		local taming = false
		for _, extension in services.survivalExtensions or {} do
			taming = taming or extension.id == "taming"
		end
		assert(taming, "taming extension is built")
		local ok, err = pcall(
			Options.validate,
			{
				packConfig = { api = 1, order = { "survival-coop" }, configs = {} },
				contracts = { Contract },
				controls = {},
				storeName = "services",
				services = services,
			} :: any
		)
		assert(ok, "Options.validate rejected the real services: " .. tostring(err))
		assert(factory.close().ok, "release")
	end,
}
