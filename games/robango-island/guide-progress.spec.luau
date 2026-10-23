--!strict
-- G3 guide progress: every one of the 20 guides is driven through the real factory's session.command
-- wrapper with the command that satisfies each objective. Guides whose objectives have a game
-- command must complete (development.definitions); guides that need an action the game does not
-- have must stay open and every such action must be listed in GuideEvents.UNSUPPORTED.

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
local LateEquipmentPorts = require("./src/server/LateEquipmentPorts")
local Contract = require("../../genres/survival-coop/module/Contract")
local Settlement = require("../../core/domain/settlement/Settlement")
local Inventory = require("../../core/domain/inventory/Inventory")
local Job = require("../../core/domain/crafting/Job")
local Journal = require("../../core/domain/command/Journal")
local Clock = require("../../core/infra/genre/Clock")
local Session = require("../../core/infra/genre/Session")
local Memory = require("../../core/infra/data/MemoryBackend")
local TamingExtension = require("../../genres/survival-coop/module/TamingExtension")
local MonetizationExtension = require("../../genres/survival-coop/module/MonetizationExtension")
local MarketExtension = require("../../genres/survival-coop/module/MarketExtension")
local MarketplacePort = require("../../core/infra/monetization/MarketplacePort")
local PolicyPort = require("../../core/infra/monetization/PolicyPort")
local MarketPorts = require("./src/shared/MarketPorts")
local wildlifePolicy = require("./src/shared/WildlifePolicy")
local tamingPolicy = require("./src/shared/TamingConfig")
local monetizationCatalog = require("./src/shared/MonetizationCatalog")
local content = require("./src/shared/SurvivalContent")
local defaultSource = require("./src/shared/SurvivalWorldConfig")
local pack = require("./src/shared/GenreConfig")
local policy = require("./src/shared/GenreDurable")

local PACK = "games/robango-island"
local PUBLIC = { provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} }
local FIRST = "11734795308"

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
				GuideEvents = require("../../genres/survival-coop/module/GuideEvents"),
				ExpeditionExtension = require("../../genres/survival-coop/module/ExpeditionExtension"),
				ProgressionPorts = require("../../genres/survival-coop/module/ProgressionPorts"),
				RecipeMarks = require("../../genres/survival-coop/module/RecipeMarks"),
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
local manualScheduling = false
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
	task = setmetatable({
		-- A spec that drives coroutines by hand resumes waiters itself (their wait loops re-check).
		defer = function(thread, ...)
			if manualScheduling then
				return thread
			end
			return task.defer(thread, ...)
		end,
	}, { __index = task }),
	Vector3 = require("@lune/roblox").Vector3,
	require = function(value)
		return value
	end,
}
local function module(name: string): any
	return luau.load(fs.readFile(PACK .. "/src/server/" .. name .. ".luau"), { environment = environment })()
end
local GuideEvents = require("../../genres/survival-coop/module/GuideEvents")
local Provision = module("SurvivalProvision")
local Factory = module("SurvivalFactory")
local STUBBED = {
	["contract-deliver"] = true,
	["camp-contribute"] = true,
	["home-expand"] = true,
	["market-list"] = true,
	["market-claim"] = true,
}

type Server = { session: any, factory: any, provision: any, now: () -> number, move: any, equip: any }
local reach = { warehouse = true }
-- live = true wires what RobangoIslandServer configures: wildlife, taming, shop and market (whose
-- tutorial gate reads the contracts snapshot, as the server script does).
local function boot(
	backend: any,
	server: string,
	clockAt: { value: number },
	live: boolean?,
	preview: boolean?,
	realRole: boolean?
): Server
	local source = defaultSource
	local move: any = nil
	local equip: any = nil
	local bound: any = nil
	local contracts: any = nil
	if live then
		TamingExtension.configure(tamingPolicy :: any)
		MonetizationExtension.configure({
			catalog = monetizationCatalog :: any,
			marketplace = MarketplacePort.fake().port,
			policy = PolicyPort.fake({}),
		})
		MarketExtension.configure(MarketPorts.config({
			personalTransfer = function(actor)
				return if bound then bound.personalTransfer(actor) else nil
			end,
			accountAgeDays = function()
				return 30
			end,
			sessionSeconds = function()
				return 0
			end,
			tutorialComplete = function(actor)
				local data = if contracts then contracts.snapshot(actor) else nil
				return type(data) == "table" and type(data.tutorial) == "table" and data.tutorial.complete == true
			end,
		}))
	end
	local provision = Provision(PUBLIC, source.tribe.config.tribeId, { studio = false, server = server })
	local active: any = nil
	local world: any = {
		services = {
			survivalSpatial = {
				campfire = function()
					return nil
				end,
				station = function(_actor, id)
					return if id == "station.campfire.t1" then { kind = "campfire", reachable = true } else nil
				end,
			},
		},
		settlementPorts = function()
			return {
				warehouse = function()
					return reach.warehouse
				end,
				verify = function()
					return true
				end,
				publish = function() end,
			}
		end,
		gatheringAccess = function(authorize)
			return function(request, bag)
				if not authorize(active, request, bag) then
					return nil
				end
				return {
					actorId = request.actorId,
					carriedContainer = bag.id,
					worldRevision = source.worldRevision,
					equipment = function()
						return {}
					end,
					reachable = function()
						return true
					end,
				}
			end
		end,
		bind = function(value)
			active = value
		end,
		destroy = function() end,
		wildlifeAccess = function()
			return nil
		end,
		publishWildlife = function() end,
	}
	if preview or realRole then
		local engine = require("../../cli/forge/fixtures/production-worlds/engine").new(true)
		move = engine.move
		equip = function(actor, itemId)
			engine.equip(world, actor, itemId)
		end
		if realRole then
			world = engine.role.build(content, source, wildlifePolicy, function()
				return clockAt.value
			end, "rw.onboarding", 1776)
			source = world.roleSource
			engine.move(FIRST, { x = -16, y = 7, z = -4 })
		else
			world = engine.preview(content, source, nil, nil, "onboarding", true)
			engine.move(FIRST, { x = 6, y = 2, z = -22 })
		end
		-- Keep gathering deterministic; transfers still use the real character/raycast ports.
		world.gatheringAccess = function(authorize)
			return function(request, bag)
				if not authorize(active, request, bag) then
					return nil
				end
				return {
					actorId = request.actorId,
					carriedContainer = bag.id,
					worldRevision = source.worldRevision,
					equipment = function()
						return {}
					end,
					reachable = function()
						return true
					end,
				}
			end
		end
		local bind = world.bind
		world.bind = function(value)
			active = value
			bind(value)
		end
	end
	local clock = Clock.new(function()
		return clockAt.value
	end)
	local now = function()
		return math.floor(clockAt.value)
	end
	local factory = assert(Factory(content, source, world, backend, clock, {
		sessionId = "server-" .. server,
		leaseSeconds = 120,
		now = now,
		budget = {
			encode = function(value)
				return serde.encode("json", value)
			end,
		},
	}, provision, if live then wildlifePolicy else nil))
	if live then
		TamingExtension.configure(nil)
		MonetizationExtension.configure(nil)
		MarketExtension.configure(nil)
		for _, extension in factory.services.survivalExtensions or {} do
			if extension.id == "contracts" then
				contracts = extension
			end
		end
	end
	-- Native run: no character Instances, so engine death stays off as in the pack smoke.
	local native = serde.decode("json", serde.encode("json", pack))
	native.configs["survival-coop"].survivalDeath = false
	local services = table.clone(factory.services)
	services.now = clock.now
	services.roll = function()
		return 0
	end
	services.emit = function() end
	services.encode = function(value)
		return serde.encode("json", value)
	end
	local session = Session.new(
		{ packConfig = native, contracts = { Contract }, controls = {}, storeName = "camp-admission", durable = policy },
		backend,
		{ sessionId = "personal-" .. server, lockTimeout = 120, retries = 0, now = now },
		services,
		policy
	)
	bound = session
	-- Extension actions whose real handler needs a world this harness does not build (home dock,
	-- market book, camp ladder, contract board) answer ok here; the factory wrapper still maps the
	-- request and the pre-command personal facts to the guide event exactly as in production.
	local realCommand = session.command
	session.command = function(actor: string, request: any)
		local action = string.gsub(request.action, "^survival%-coop:", "")
		if STUBBED[action] then
			return { ok = true, data = {} }
		end
		return realCommand(actor, request)
	end
	factory.bind(session)
	return { session = session, factory = factory, provision = provision, now = now, move = move, equip = equip }
end

local ACTOR = FIRST
local sequence = 0
local function send(server: any, action: string, args: { any }): any
	if action == "gather" then
		args = { args[1], server.factory.services.survivalGathering.snapshot(ACTOR).version }
	end
	sequence += 1
	server.at.value += 3
	server.session.advance(server.at.value)
	local session = server.session
	local request = {
		requestId = "guide-" .. sequence,
		sessionEpoch = session.commandEpoch(ACTOR, "survival-coop:" .. action) or 0,
		action = "survival-coop:" .. action,
		args = args,
	}
	local result = session.command(ACTOR, request)
	for _ = 1, 4 do
		if result.ok or action ~= "gather" then
			break
		end
		assert(session.recoverTransfers(ACTOR, 16).ok, "transfer recovery")
		result = session.command(ACTOR, request)
	end
	assert(result.ok, action .. ": " .. serde.encode("json", result))
	return result
end

local function bagItem(server: any, catalogId: string): string
	for id, item in server.session.snapshot(ACTOR)["survival-coop"].inventory.bag.items do
		if item.catalogId == catalogId then
			return id
		end
	end
	error("no " .. catalogId .. " in bag")
end

local function craft(server: any, at: any, recipe: string, station: string)
	local reserved = send(server, "craft-reserve", { recipe, station })
	send(server, "craft-start", { reserved.data.jobId })
	at.value += 20
	server.session.advance(at.value)
	send(server, "craft-complete", { reserved.data.jobId })
end

-- The command(s) that satisfy each supported objective, keyed by objective id.
local DRIVE: { [string]: (any, any) -> () } = {
	["rw.g01.first-gather.1"] = function(server)
		send(server, "gather", { "fiber-bush-01", 0 })
	end,
	["rw.g02.first-axe.1"] = function(server, at)
		send(server, "gather", { "flint-outcrop-01", 0 })
		craft(server, at, "stone-axe", "hand")
	end,
	["rw.g03.first-contract.1"] = function(server)
		send(server, "contract-deliver", { "survey-driftwood" })
	end,
	["rw.g04.camp-donation.1"] = function(server)
		send(server, "camp-contribute", { "windbreak", bagItem(server, "fiber"), 1, 0 })
	end,
	["rw.g05.home-expansion.1"] = function(server)
		send(server, "home-expand", { "home:" .. ACTOR, {} })
	end,
	["rw.g07.food.1"] = function(server, at)
		send(server, "gather", { "berry-bush-01", 0 })
		craft(server, at, "berry-meal", "station.campfire.t1")
	end,
	["rw.g07.food.2"] = function(server)
		send(server, "food", { bagItem(server, "berry-meal") })
	end,
	["rw.g08.market.1"] = function(server)
		send(server, "market-list", { bagItem(server, "fiber"), 1, 5 })
	end,
	["rw.g08.market.2"] = function(server)
		-- A cancelled listing returns its fiber as a claim row (CrossServer RETURNING settlement).
		server.session.personalTransaction(ACTOR, function(raw)
			local d = raw.envelope.genres["survival-coop"].data
			local fiber = d.inventory.bag.items[bagItem(server, "fiber")]
			d.market = {
				markers = {},
				escrow = {},
				active = {},
				applied = {},
				pages = { { { id = "listing:1:return:0", value = { item = fiber } } } },
			}
			return raw
		end)
		send(server, "market-claim", { "listing:1:return:0" })
	end,
	-- p59 waypoint guides (levels 6-28, grade 2).
	["rw.g21.daily-board.1"] = function(server)
		send(server, "contract-deliver", { "survey-driftwood" })
		send(server, "contract-deliver", { "eco-fiber-sample" })
	end,
	["rw.g22.wilds-spear.1"] = function(server, at)
		send(server, "gather", { "fallen-tree-01", 0 })
		craft(server, at, "spear", "hand")
	end,
	["rw.g23.wilds-hazelnuts.1"] = function(server)
		send(server, "gather", { "forest-hazel-thicket-01", 0 })
	end,
	["rw.g24.roasted-hazelnuts.1"] = function(server, at)
		send(server, "gather", { "forest-hazel-thicket-01", 0 })
		send(server, "gather", { "forest-hazel-thicket-01", 0 })
		craft(server, at, "roasted-hazelnuts", "station.campfire.t1")
	end,
	["rw.g25.wilds-chanterelles.1"] = function(server)
		send(server, "gather", { "forest-chanterelle-log-01", 0 })
	end,
	["rw.g26.cattail-flatbread.1"] = function(server, at)
		send(server, "gather", { "marsh-cattail-stand-01", 0 })
		send(server, "gather", { "marsh-cattail-stand-01", 0 })
		craft(server, at, "cattail-flatbread", "station.campfire.t1")
	end,
	["rw.g27.deep-wilds-clams.1"] = function(server)
		send(server, "gather", { "marsh-clam-bed-01", 0 })
	end,
	["rw.g28.woodland-skewer.1"] = function(server, at)
		send(server, "gather", { "forest-chanterelle-log-01", 0 })
		send(server, "gather", { "meat-cache-01", 0 })
		craft(server, at, "woodland-skewer", "station.campfire.t1")
	end,
	["rw.g29.deep-wilds-haul.1"] = function(server)
		send(server, "gather", { "marsh-clam-bed-01", 0 })
	end,
	["rw.g30.route-supplies.1"] = function(server)
		for _, id in { "survey-driftwood", "guild-stone-axe", "eco-fiber-sample" } do
			send(server, "contract-deliver", { id })
		end
	end,
}

local function fresh(guide: any): (any, any)
	local at = { value = 1000 }
	local server = boot(Memory.new(), "job:guide-" .. guide.id, at)
	server.at = at
	assert(server.session.join(ACTOR).ok, "join")
	-- Open the guide's band: level and development grade from its gates.
	assert(
		server.session.personalTransaction(ACTOR, function(raw)
			raw.envelope.genres["survival-coop"].data.progression.level = guide.gates.characterLevel
			return raw
		end),
		"level"
	)
	assert(
		server.factory.expeditionStore.transaction(ACTOR, function(document)
			document.development = {
				points = (guide.gates.developmentRank or 0) * 100,
				definitions = {},
				progress = {},
				events = {},
				instabilityAccess = 1,
			}
			return { ok = true }
		end).ok,
		"development"
	)
	send(server, "gather", { "fiber-bush-01", 0 })
	return server, at
end

local cases: { [string]: () -> () } = {}
for _, guide in content.guides do
	cases["guide " .. guide.id .. " completes from its mapped commands or names the missing action"] = function()
		local missing = {}
		for _, objective in guide.objectives do
			if GuideEvents.UNSUPPORTED[objective.action] then
				table.insert(missing, objective.action)
			end
		end
		for _, objective in guide.objectives do
			assert(
				#missing > 0 or DRIVE[objective.id],
				objective.id .. " (" .. objective.action .. ") has no mapped command"
			)
		end
		local server, at = fresh(guide)
		for _, objective in guide.objectives do
			local drive = DRIVE[objective.id]
			if drive then
				drive(server, at)
			end
		end
		local development = server.factory.expeditionStore.snapshot(ACTOR).development
		if #missing == 0 then
			assert(development.definitions[guide.id], guide.id .. " did not complete")
			assert(development.points >= (guide.gates.developmentRank or 0) * 100 + 50, "development awarded")
		else
			assert(not development.definitions[guide.id], guide.id .. " completed without " .. missing[1])
		end
		assert(server.session.close(ACTOR).ok and server.factory.close().ok, "release")
	end
end

cases["the first band alone lifts a fresh player to island grade 2 (route 1)"] = function()
	local server, at = fresh(content.guides[1])
	for _, guide in content.guides do
		if (guide.gates.developmentRank or 0) == 0 then
			for _, objective in guide.objectives do
				DRIVE[objective.id](server, at)
			end
		end
	end
	local points = server.factory.expeditionStore.snapshot(ACTOR).development.points
	assert(points >= 200, "grade 2 needs 200 development, got " .. points)
	assert(server.session.close(ACTOR).ok and server.factory.close().ok, "release")
end

return cases
