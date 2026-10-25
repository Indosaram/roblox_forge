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
				MultistoreyCommands = require("../../genres/survival-coop/module/MultistoreyCommands"),
			},
		},
	},
	core = {
		domain = {
			home = { HomeContent = require("../../core/domain/home/HomeContent") },
			island = { Archipelago = Archipelago },
			settlement = { Settlement = Settlement },
			inventory = { Inventory = Inventory, ItemCatalog = require("../../core/domain/inventory/ItemCatalog") },
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
local Companion = require("../../genres/survival-coop/module/CombatCompanion")
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
	realRole: boolean?,
	layoutId: string?
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
					local kind = string.match(id, "^station%.(%a+)%.t1$")
					return if kind == "campfire" or kind == "workbench" then { kind = kind, reachable = true } else nil
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
	if layoutId then
		-- Spatial facts for the guide's place: the actor stands inside it and reaches its anchors.
		for _, layout in content.layouts do
			world.layout = if layout.id == layoutId then layout else world.layout
		end
		world.services.survivalDeath = {
			position = function()
				return { x = 0, y = 2, z = 0 }
			end,
			reachable = function()
				return true
			end,
			equipment = function()
				return {}
			end,
		}
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

local function give(server: any, id: string, catalogId: string, quantity: number, attributes: any?)
	server.session.personalTransaction(ACTOR, function(raw)
		raw.envelope.genres["survival-coop"].data.inventory.bag.items[id] = {
			itemId = id,
			catalogId = catalogId,
			quantity = quantity,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = attributes or {},
		}
		return raw
	end)
end

local function stored(server: any, catalogId: string): string
	for id, item in server.factory.homeOwner().snapshot(ACTOR).storage.items do
		if item.catalogId == catalogId then
			return id
		end
	end
	error("no " .. catalogId .. " in home storage")
end

-- Advances time in lease-renewing steps (the personal lease is 120 s).
local function wait(server: any, at: any, seconds: number)
	for _ = 1, math.ceil(seconds / 30) do
		at.value += 30
		server.session.advance(at.value)
		-- Production heartbeats read these every frame; the reads keep each fenced lease alive.
		server.factory.expeditionStore.snapshot(ACTOR)
		server.factory.services.survivalGathering.snapshot(ACTOR)
		if server.factory.homeOwner() then
			server.factory.homeOwner().snapshot(ACTOR)
		end
		for _, extension in server.factory.services.survivalExtensions or {} do
			if extension.snapshot then
				extension.snapshot(ACTOR)
			end
		end
	end
end

local function act(server: any, verb: string, target: string)
	send(server, "guide-act", { verb, target })
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
	-- Clothing bootstrap: the practice stitch earns tailoring proficiency for tailoring_1.
	["rw.g10.clothing.1"] = function(server)
		send(server, "operation-run", { "practice-fiber-stitch", "hand" })
	end,
	["rw.g10.clothing.2"] = function(server)
		send(server, "skill-learn", { "tailoring_1" })
	end,
	["rw.g10.clothing.3"] = function(server, at)
		server.session.personalTransaction(ACTOR, function(raw)
			local items = raw.envelope.genres["survival-coop"].data.inventory.bag.items
			for id, entry in { ["guide-leather"] = { "leather", 2 }, ["guide-dried-fiber"] = { "dried-fiber", 1 } } do
				items[id] = {
					itemId = id,
					catalogId = entry[1],
					quantity = entry[2],
					qualityMilli = 1000,
					durabilityMilli = 0,
					attributes = {},
				}
			end
			return raw
		end)
		craft(server, at, "temperate-gloves", "station.workbench.t1")
	end,
	-- p100: the twelve guides whose actions previously had no command.
	["rw.g06.visit.1"] = function(server)
		act(server, "visit", "rw.home-demo")
	end,
	["rw.g09.farming.1"] = function(server)
		give(server, "guide-water", "water", 3)
		send(server, "operation-run", { "practice-seedbed", "hand" })
	end,
	["rw.g09.farming.2"] = function(server)
		send(server, "skill-learn", { "farming_1" })
	end,
	["rw.g09.farming.3"] = function(server)
		give(server, "guide-seed", "corn-seed", 1, { level = 1 })
		give(server, "guide-fertilizer", "liquid-fertilizer", 1)
		give(server, "guide-sprinkler", "sprinkler", 1)
		for _, id in { "guide-seed", "guide-water", "guide-fertilizer", "guide-sprinkler" } do
			local quantity = server.session.snapshot(ACTOR)["survival-coop"].inventory.bag.items[id].quantity
			send(server, "home-deposit", { "home:" .. ACTOR, { itemId = id, quantity = quantity } })
		end
		send(
			server,
			"home-plant",
			{ "home:" .. ACTOR, { plot = "starter-farm", crop = "corn", seedItem = stored(server, "corn-seed") } }
		)
	end,
	["rw.g09.farming.4"] = function(server)
		send(
			server,
			"home-area",
			{ "home:" .. ACTOR, { plot = "starter-farm", plots = "starter-farm", fertilizer = "liquid-fertilizer" } }
		)
	end,
	["rw.g09.farming.5"] = function(server, at)
		wait(server, at, 900)
		send(server, "home-harvest", { "home:" .. ACTOR, { plot = "starter-farm" } })
	end,
	["rw.g11.skill-reclaim.1"] = function(server)
		act(server, "preview-refund", "skills")
	end,
	["rw.g11.skill-reclaim.2"] = function(server)
		act(server, "cancel-preview", "skills")
	end,
	["rw.g12.route-share.1"] = function(server)
		act(server, "invite-training", "rw.training-recipient")
	end,
	["rw.g12.route-share.2"] = function(server)
		act(server, "revoke", "rw.training-recipient")
	end,
	["rw.g13.lab.1"] = function(server)
		act(server, "inspect", "laboratory")
	end,
	["rw.g14.taming.1"] = function(server)
		-- The guide supplies one owned, captured dodo (quests spec g14).
		server.session.personalTransaction(ACTOR, function(raw)
			local rules = content.progressionPolicy.companion
			local state = assert(Companion.capture(Companion.new({}, 0), "guide-dodo", "dodo", rules :: any))
			raw.envelope.genres["survival-coop"].data.companions = state
			return raw
		end)
		give(server, "guide-feed", "herbivore-feed", 3)
		send(server, "companion-action", { "place", "guide-dodo" })
	end,
	["rw.g14.taming.2"] = function(server)
		send(server, "companion-action", { "train", "guide-dodo" })
		for _ = 1, 3 do
			send(server, "companion-action", { "feed", "guide-dodo" })
		end
	end,
	["rw.g14.taming.3"] = function(server, at)
		wait(server, at, 301)
		send(server, "companion-action", { "claim", "guide-dodo" })
	end,
	["rw.g15.clan.1"] = function(server)
		act(server, "preview-role", "clan")
	end,
	["rw.g15.clan.2"] = function(server)
		act(server, "draft-membership", "clan")
	end,
	["rw.g15.clan.3"] = function(server)
		act(server, "cancel-draft", "clan")
	end,
	["rw.g16.refrigeration.1"] = function(server)
		send(server, "home-deposit", { "home:" .. ACTOR, { itemId = bagItem(server, "berry"), quantity = 1 } })
	end,
	["rw.g16.refrigeration.2"] = function(server)
		act(server, "inspect-rate", "refrigerator")
	end,
	["rw.g16.refrigeration.3"] = function(server)
		send(server, "home-withdraw", { "home:" .. ACTOR, { itemId = stored(server, "berry"), quantity = 1 } })
	end,
	["rw.g17.snow-preparation.1"] = function(server)
		act(server, "equip-loan", "cold-head")
	end,
	["rw.g17.snow-preparation.2"] = function(server)
		act(server, "inspect", "cold-head")
	end,
	["rw.g17.snow-preparation.3"] = function(server)
		act(server, "return-loan", "cold-head")
	end,
	["rw.g18.technical-support.1"] = function(server)
		act(server, "preview", "support-tier-1")
	end,
	["rw.g18.technical-support.2"] = function(server)
		act(server, "acknowledge-level-gate", "support-tier-1")
	end,
	["rw.g19.volcano-preparation.1"] = function(server)
		act(server, "equip-loan", "lava-protection-boots")
	end,
	["rw.g19.volcano-preparation.2"] = function(server)
		act(server, "inspect", "lava-protection-boots")
	end,
	["rw.g19.volcano-preparation.3"] = function(server)
		act(server, "return-loan", "lava-protection-boots")
	end,
	["rw.g20.rescue-preparation.1"] = function(server)
		give(server, "guide-fiber", "fiber", 4)
		for _ = 1, 2 do
			send(server, "operation-run", { "assemble-bandage", "hand" })
		end
	end,
	["rw.g20.rescue-preparation.2"] = function(server)
		act(server, "activate", "rw.harbor.rescue-beacon")
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

-- Guides acted out at a place: home commands need the home role, facility anchors the harbor.
local PLACE: { [string]: string } = {
	["rw.g06.visit"] = "rw.harbor",
	["rw.g09.farming"] = "rw.home",
	["rw.g13.lab"] = "rw.harbor",
	["rw.g16.refrigeration"] = "rw.home",
	["rw.g18.technical-support"] = "rw.harbor",
	["rw.g20.rescue-preparation"] = "rw.harbor",
}

local function fresh(guide: any): (any, any)
	local at = { value = 1000 }
	local server = boot(Memory.new(), "job:guide-" .. guide.id, at, nil, nil, nil, PLACE[guide.id])
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

for _, id in
	{
		"rw.g06.visit",
		"rw.g09.farming",
		"rw.g11.skill-reclaim",
		"rw.g12.route-share",
		"rw.g13.lab",
		"rw.g14.taming",
		"rw.g15.clan",
		"rw.g16.refrigeration",
		"rw.g17.snow-preparation",
		"rw.g18.technical-support",
		"rw.g19.volcano-preparation",
		"rw.g20.rescue-preparation",
	}
do
	cases["p100 guide " .. id .. " completes end to end through real commands"] = function()
		local guide: any = nil
		for _, row in content.guides do
			guide = if row.id == id then row else guide
		end
		local server, at = fresh(guide)
		for _, objective in guide.objectives do
			assert(DRIVE[objective.id], objective.id .. " has no command")(server, at)
		end
		local development = server.factory.expeditionStore.snapshot(ACTOR).development
		for _, objective in guide.objectives do
			assert(
				(development.progress[objective.id] or 0) >= objective.quantity,
				objective.id .. " progress " .. tostring(development.progress[objective.id])
			)
		end
		assert(development.definitions[id], id .. " completed")
		local closed, released = server.session.close(ACTOR), server.factory.close()
		assert(closed.ok and released.ok, "release " .. tostring(closed.reason) .. " " .. tostring(released.reason))
	end
end

cases["guide-act rank constants match CharacterRules"] = function()
	local Rules = require("../../genres/survival-coop/module/CharacterRules")
	local guide = { gates = { characterLevel = 1, developmentRank = Rules.MAX_RANK } }
	local development = { points = Rules.RANK_POINTS * Rules.MAX_RANK, definitions = {}, progress = {} }
	local fixture = {
		guides = {
			{
				id = "g",
				gates = guide.gates,
				objectives = { { id = "o", action = "inspect", target = "t", quantity = 1 } },
			},
		},
	}
	assert(GuideEvents.nextStep(fixture, development, 1, "inspect", "t"), "max rank opens")
	development.points -= 1
	assert(not GuideEvents.nextStep(fixture, development, 1, "inspect", "t"), "one point short stays closed")
end

cases["guide-act refuses an objective of a guide that is not open or out of order"] = function()
	local guide: any = nil
	for _, row in content.guides do
		guide = if row.id == "rw.g11.skill-reclaim" then row else guide
	end
	local server = fresh(guide)
	local function refused(verb: string, target: string, reason: string)
		local session = server.session
		local result = session.command(ACTOR, {
			requestId = "refuse-" .. verb .. target,
			sessionEpoch = session.commandEpoch(ACTOR, "survival-coop:guide-act") or 0,
			action = "survival-coop:guide-act",
			args = { verb, target },
		})
		assert(not result.ok and result.reason == reason, verb .. ": " .. tostring(result.reason))
	end
	refused("cancel-preview", "skills", "GUIDE_STEP_ORDER")
	refused("acknowledge-level-gate", "support-tier-1", "GUIDE_NOT_OPEN")
	refused("visit", "nowhere", "GUIDE_NOT_OPEN")
	local development = server.factory.expeditionStore.snapshot(ACTOR).development
	assert(next(development.progress) == nil or development.progress["rw.g11.skill-reclaim.2"] == nil, "no progress")
	assert(server.session.close(ACTOR).ok and server.factory.close().ok, "release")
end

cases["the clothing guide completes through the practice stitch operation"] = function()
	local guide: any = nil
	for _, row in content.guides do
		guide = if row.id == "rw.g10.clothing" then row else guide
	end
	local server, at = fresh(guide)
	for _, objective in guide.objectives do
		DRIVE[objective.id](server, at)
	end
	local development = server.factory.expeditionStore.snapshot(ACTOR).development
	assert(development.progress["rw.g10.clothing.1"] == 1, "practice stitch counted")
	assert(development.definitions["rw.g10.clothing"], "clothing guide completed")
	assert(server.session.close(ACTOR).ok and server.factory.close().ok, "release")
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
