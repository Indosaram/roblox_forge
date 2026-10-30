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
				CarcassExtension = require("../../genres/survival-coop/module/CarcassExtension"),
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
local online: { [string]: boolean } = {}
local environment: any = {
	script = { Parent = { LateEquipmentPorts = LateEquipmentPorts } },
	game = {
		GetService = function()
			return {
				WaitForChild = function()
					return forge
				end,
				-- Players: only actors a case marks online have a Player stub (route-share invites).
				GetPlayerByUserId = function(_, id)
					return if online[tostring(id)] then { SetAttribute = function() end } else nil
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
	layoutId: string?,
	clan: boolean?
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
	if clan then
		world.clanDirectory = require("../../core/infra/data/ClanStore").new({
			dataStore = {
				UpdateAsync = function(_, key, transform)
					local ok, result = backend.update("clan-directory:" .. key, transform)
					assert(ok, result)
					return result
				end,
			},
			rules = content.clanPolicy,
			maxBytes = 3900000,
			encode = function(value)
				return serde.encode("json", value)
			end,
			fence = {
				sessionId = "guide-clan",
				leaseSeconds = 120,
				now = function()
					return math.floor(clockAt.value)
				end,
			},
		})
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
local LENDER = "2001"
local sequence = 0
local function send(server: any, action: string, args: { any }, actor: string?): any
	local who = actor or ACTOR
	if action == "gather" then
		args = { args[1], server.factory.services.survivalGathering.snapshot(who).version }
	end
	sequence += 1
	server.at.value += 3
	server.session.advance(server.at.value)
	local session = server.session
	local request = {
		requestId = "guide-" .. sequence,
		sessionEpoch = session.commandEpoch(who, "survival-coop:" .. action) or 0,
		action = "survival-coop:" .. action,
		args = args,
	}
	local result = session.command(who, request)
	for _ = 1, 4 do
		if result.ok or action ~= "gather" then
			break
		end
		assert(session.recoverTransfers(who, 16).ok, "transfer recovery")
		result = session.command(who, request)
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

local function give(server: any, id: string, catalogId: string, quantity: number, attributes: any?, actor: string?)
	server.session.personalTransaction(actor or ACTOR, function(raw)
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

-- p103 loans: a camp member escrows gear in the camp; the guide player borrows and returns it.
local loans: { [string]: string } = {}
local function lend(server: any, item: string)
	assert(server.session.join(LENDER).ok, "lender joins")
	give(server, "lend-" .. item, item, 1, nil, LENDER)
	local offered = send(server, "camp-loan", { "offer", "lend-" .. item }, LENDER)
	loans[item] = offered.data.loanId
	send(server, "camp-loan", { "take", loans[item] })
	assert(server.session.snapshot(ACTOR)["survival-coop"].inventory.bag.items["loan-" .. loans[item]], "borrowed")
end
local function giveBack(server: any, item: string)
	send(server, "camp-loan", { "return", loans[item] })
	assert(server.session.snapshot(ACTOR)["survival-coop"].inventory.bag.items["loan-" .. loans[item]] == nil, "gone")
	send(server, "camp-loan", { "recall", loans[item] }, LENDER)
	local back = server.session.snapshot(LENDER)["survival-coop"].inventory.bag.items["lend-" .. item]
	assert(back and back.catalogId == item, "the lender has the gear back")
	assert(server.session.close(LENDER).ok, "lender leaves")
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
	-- Tame lane (R09): weaken an onboarding dodo with the bone knife, then the starter bola captures it.
	["rw.g31.first-capture.1"] = function(server)
		local dodo = "rw.onboarding.dodo.01.1"
		local wild = server.factory.services.survivalWildlife
		give(server, "guide-knife", "bone-knife", 1)
		server.session.personalTransaction(ACTOR, function(raw)
			raw.envelope.genres["survival-coop"].data.inventory.bag.items["guide-knife"].durabilityMilli = 60000
			return raw
		end)
		give(server, "guide-bola", "capture-bola", 1)
		server.session.personalTransaction(ACTOR, function(raw)
			raw.envelope.genres["survival-coop"].data.inventory.bag.items["guide-bola"].durabilityMilli = 100000
			return raw
		end)
		server.equip(ACTOR, "guide-knife")
		local full = 0
		for _, row in content.wildlifeDetails do
			full = if row.id == "dodo" then row.health * 1000 else full
		end
		local function command(action: string, args: { any }): any
			sequence += 1
			server.at.value += 1
			server.session.advance(server.at.value)
			return server.session.command(ACTOR, {
				requestId = "guide-" .. sequence,
				sessionEpoch = server.session.commandEpoch(ACTOR, "survival-coop:" .. action) or 0,
				action = "survival-coop:" .. action,
				args = args,
			})
		end
		for _ = 1, 40 do
			local npc = wild.snapshot(ACTOR)[dodo]
			if npc.healthMilli <= full // 4 then
				break
			end
			local home = npc.home
			server.move(ACTOR, { x = home.x + 2, y = home.y + 1, z = home.z })
			command("attack", { dodo })
		end
		local health = wild.snapshot(ACTOR)[dodo].healthMilli
		assert(health > 0 and health <= full // 4, "weakened to the capture threshold: " .. health)
		for _ = 1, 4 do
			server.at.value += 9
			assert(command("tame-hit", { dodo }).ok, "bola stun")
			local caught = command("tame-capture", { dodo })
			assert(caught.ok, "capture: " .. tostring(caught.reason))
			if caught.data.captured then
				return
			end
		end
		error("four bola throws all missed")
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
	-- p103: route sharing is real: the invite and revoke land in the owner's route record.
	["rw.g12.route-share.1"] = function(server)
		online[LENDER] = true
		assert(server.session.join(LENDER).ok, "recipient joins")
		local invited = send(server, "party-action", { "route-invite", LENDER })
		assert(invited.data.route == 1, "the owner's unlocked route is shared")
		local share = server.factory.expeditionStore.snapshot(ACTOR).routeShare
		assert(share.members[LENDER] == "invited", "invite persisted in route state")
	end,
	["rw.g12.route-share.2"] = function(server)
		send(server, "party-action", { "route-revoke", LENDER })
		assert(server.factory.expeditionStore.snapshot(ACTOR).routeShare.members[LENDER] == nil, "revoked")
		assert(server.session.close(LENDER).ok, "recipient leaves")
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
	-- p103: the clan steps read and write the real clan record.
	["rw.g15.clan.1"] = function(server)
		assert(server.session.join(LENDER).ok, "leader joins")
		send(server, "clan-create", { "guide-clan" }, LENDER)
		local preview = send(server, "clan-preview", { "guide-clan", { role = "member" } })
		assert(preview.data.grants.build and not preview.data.grants.govern, "member grants previewed")
	end,
	["rw.g15.clan.2"] = function(server)
		send(server, "clan-draft", { "guide-clan", { role = "member" } })
		local clan = server.session.snapshot(LENDER).survivalExtensions.clan
		assert(clan.drafts[ACTOR].role == "member" and not clan.members[ACTOR], "draft recorded, not a member")
	end,
	["rw.g15.clan.3"] = function(server)
		send(server, "clan-draft-cancel", { "guide-clan", {} })
		assert(server.session.snapshot(LENDER).survivalExtensions.clan.drafts[ACTOR] == nil, "draft cancelled")
		assert(server.session.close(LENDER).ok, "leader leaves")
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
		lend(server, "cold-head")
	end,
	["rw.g17.snow-preparation.2"] = function(server)
		act(server, "inspect", "cold-head")
	end,
	["rw.g17.snow-preparation.3"] = function(server)
		giveBack(server, "cold-head")
	end,
	-- p103: the support quote is the real tier row; the acknowledgement lands in late-equipment state.
	["rw.g18.technical-support.1"] = function(server)
		local quote = send(server, "equipment-quote", { "support-tier-1", "preview" })
		assert(quote.data.level == 60 and quote.data.cost == 500 and not quote.data.levelMet, "tier 1 quote")
	end,
	["rw.g18.technical-support.2"] = function(server)
		send(server, "equipment-quote", { "support-tier-1", "acknowledge" })
		local late = server.session.snapshot(ACTOR).survivalExtensions["late-equipment"]
		assert(late.acknowledged["support-tier-1"] == 60, "level gate acknowledged in late-equipment state")
	end,
	["rw.g19.volcano-preparation.1"] = function(server)
		lend(server, "lava-protection-boots")
	end,
	["rw.g19.volcano-preparation.2"] = function(server)
		act(server, "inspect", "lava-protection-boots")
	end,
	["rw.g19.volcano-preparation.3"] = function(server)
		giveBack(server, "lava-protection-boots")
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
	local clan = guide.id == "rw.g15.clan"
	-- The starter capture needs the onboarding island's real wildlife and taming wiring.
	local wilds = guide.id == "rw.g31.first-capture"
	local server =
		boot(Memory.new(), "job:guide-" .. guide.id, at, wilds or nil, nil, wilds or nil, PLACE[guide.id], clan)
	server.at = at
	assert(server.session.join(ACTOR).ok, "join")
	-- The player taps Start: the ADR-13 join hold ends and hunger runs (TitleFlow.bindWake).
	assert(server.session.dispatch(ACTOR, "survival-coop:vitals-wake", {}).ok, "Start")
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
	if not wilds then
		send(server, "gather", { "fiber-bush-01", 0 })
	end
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
			local award = guide.rewards.development or 0
			assert(development.points >= (guide.gates.developmentRank or 0) * 100 + award, "development awarded")
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
	refused("inspect-rate", "refrigerator", "GUIDE_NOT_OPEN")
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
		-- Development-paying start guides (the starter capture pays none and needs live wildlife).
		if (guide.gates.developmentRank or 0) == 0 and (guide.rewards.development or 0) > 0 then
			for _, objective in guide.objectives do
				DRIVE[objective.id](server, at)
			end
		end
	end
	local points = server.factory.expeditionStore.snapshot(ACTOR).development.points
	assert(points >= 200, "grade 2 needs 200 development, got " .. points)
	assert(server.session.close(ACTOR).ok and server.factory.close().ok, "release")
end

cases["p103 camp equipment loans escrow the item and refuse out-of-turn takes, returns and recalls"] = function()
	local guide: any = nil
	for _, row in content.guides do
		guide = if row.id == "rw.g17.snow-preparation" then row else guide
	end
	local server = fresh(guide)
	assert(server.session.join(LENDER).ok, "lender joins")
	give(server, "lend-hat", "cold-head", 1, nil, LENDER)
	local loanId = send(server, "camp-loan", { "offer", "lend-hat" }, LENDER).data.loanId
	assert(server.session.snapshot(LENDER)["survival-coop"].inventory.bag.items["lend-hat"] == nil, "escrowed")
	local camp = server.session.snapshot(LENDER).survivalExtensions.camp
	assert(camp.loans[loanId].catalogId == "cold-head" and camp.loans[loanId].lender == LENDER, "in the camp")
	local function refused(actor: string, args: { any }, reason: string)
		sequence += 1
		server.at.value += 3
		server.session.advance(server.at.value)
		local result = server.session.command(actor, {
			requestId = "loan-refuse-" .. sequence,
			sessionEpoch = server.session.commandEpoch(actor, "survival-coop:camp-loan") or 0,
			action = "survival-coop:camp-loan",
			args = args,
		})
		assert(not result.ok and result.reason == reason, args[1] .. ": " .. tostring(result.reason))
	end
	refused(LENDER, { "take", loanId }, "OWN_LOAN")
	refused(ACTOR, { "return", loanId }, "NOT_BORROWER")
	refused(ACTOR, { "take", "missing" }, "NO_LOAN")
	send(server, "camp-loan", { "take", loanId })
	refused(LENDER, { "recall", loanId }, "LOAN_OUT")
	refused(ACTOR, { "recall", loanId }, "NOT_LENDER")
	send(server, "camp-loan", { "return", loanId })
	refused(ACTOR, { "return", loanId }, "NOT_BORROWER")
	send(server, "camp-loan", { "recall", loanId }, LENDER)
	assert(server.session.snapshot(LENDER)["survival-coop"].inventory.bag.items["lend-hat"], "recalled")
	refused(LENDER, { "recall", loanId }, "NO_LOAN")
	local progress = server.factory.expeditionStore.snapshot(ACTOR).development.progress
	assert(progress["rw.g17.snow-preparation.1"] == 1, "the real take counts as the guide's loan step")
	assert(server.session.close(LENDER).ok and server.session.close(ACTOR).ok, "close")
	assert(server.factory.close().ok, "release")
end

cases["p103 support quote refuses a non-support row and a closed guide still accepts the real quote"] = function()
	local server = fresh(content.guides[1])
	local result = server.session.command(ACTOR, {
		requestId = "quote-bad",
		sessionEpoch = server.session.commandEpoch(ACTOR, "survival-coop:equipment-quote") or 0,
		action = "survival-coop:equipment-quote",
		args = { "modify-hardness", "preview" },
	})
	assert(not result.ok and result.reason == "UNKNOWN_OPERATION", tostring(result.reason))
	local quote = send(server, "equipment-quote", { "support-tier-2", "preview" })
	assert(quote.data.level == 60 and quote.data.tier == 2, "tier 2 quote")
	assert(server.session.close(ACTOR).ok and server.factory.close().ok, "release")
end

-- p120 D3: guide-act at a world anchor uses the real harbor geometry (RoleWorld parts, generated
-- terrain, SurvivalWorld raycast). Standing at the visitor portal or the rescue beacon reaches it;
-- standing 30 studs away does not. (Studio p115: the ray to the buried anchor point hit Terrain or the
-- portal part itself, so every visit refused OUT_OF_RANGE.)
cases["guide-act reaches harbor anchors through real terrain and facility parts"] = function()
	local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
	local engine = Engine.new(nil, true)
	local world = engine.role.build(content, defaultSource, wildlifePolicy, function()
		return 0
	end, "rw.harbor", 1776)
	engine.game:GetService("RunService").Heartbeat:Wait()
	local portal = world.anchorParts["visitor-portal"]
	local beacon = world.anchorParts["rescue-beacon"]
	assert(portal and beacon, "harbor facility parts are registered by anchor id")
	for _, case in { { "visit", "rw.home-demo", portal }, { "activate", "rw.harbor.rescue-beacon", beacon } } do
		local p = case[3].Position
		-- On the facility (as in Studio) and one step beside it.
		for _, offset in { { 0, 3.5, 0 }, { 5.5, 3, 0 } } do
			engine.move(FIRST, { x = p.X + offset[1], y = p.Y + offset[2], z = p.Z + offset[3] })
			assert(
				GuideEvents.atAnchor(content, world, FIRST, case[1], case[2]),
				case[1] .. " " .. case[2] .. " reachable at offset " .. offset[1]
			)
		end
		engine.move(FIRST, { x = p.X + 30, y = p.Y + 3, z = p.Z })
		assert(not GuideEvents.atAnchor(content, world, FIRST, case[1], case[2]), case[1] .. " refused far away")
	end
	assert(GuideEvents.atAnchor(content, world, FIRST, "inspect", "cold-head"), "no anchor: no reach check")
	world.destroy()
end

-- p126: home expand's atDock uses the station reach rule on the home dock part (world.nearPart), as
-- every other dock does since p123. Real rw.home geometry, generated terrain, SurvivalWorld raycast;
-- the dock part is solid to rays that do not exclude it, as in Studio.
cases["home expand atDock reaches the home dock part through real terrain"] = function()
	local roblox = require("@lune/roblox")
	local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
	local engine = Engine.new(nil, true)
	local workspace = engine.game:GetService("Workspace")
	local world = engine.role.build(content, defaultSource, wildlifePolicy, function()
		return 0
	end, "rw.home", 1776)
	local at = { value = 1000 }
	local provision = Provision(PUBLIC, defaultSource.tribe.config.tribeId, { studio = false, server = "job:p126" })
	local factory = assert(Factory(
		content,
		world.roleSource,
		world,
		Memory.new(),
		Clock.new(function()
			return at.value
		end),
		{
			sessionId = "server-p126",
			leaseSeconds = 120,
			now = function()
				return math.floor(at.value)
			end,
			budget = {
				encode = function(value)
					return serde.encode("json", value)
				end,
			},
		},
		provision,
		nil
	))
	local dock = workspace:FindFirstChild("ForgeRoleWorld"):FindFirstChild("entry")
	assert(dock and dock:FindFirstChild("ForgeDock"), "home dock part")
	local raycast = workspace.Raycast
	local function solid(origin: any, direction: any, params: any): number?
		for _, ignored in if params then params.FilterDescendantsInstances or {} else {} do
			if ignored == dock or dock:IsDescendantOf(ignored) then
				return nil
			end
		end
		local low, high = 0, 1
		for _, axis in { "X", "Y", "Z" } do
			local minimum = dock.Position[axis] - dock.Size[axis] / 2
			local maximum = dock.Position[axis] + dock.Size[axis] / 2
			if direction[axis] == 0 then
				if origin[axis] < minimum or origin[axis] > maximum then
					return nil
				end
			else
				local a = (minimum - origin[axis]) / direction[axis]
				local b = (maximum - origin[axis]) / direction[axis]
				low, high = math.max(low, math.min(a, b)), math.min(high, math.max(a, b))
			end
		end
		return if low <= high then low else nil
	end
	workspace.Raycast = function(self, origin, direction, params)
		local hit = raycast(self, origin, direction, params)
		local t = solid(origin, direction, params)
		if t and (not hit or (hit.Position - origin).Magnitude > direction.Magnitude * t) then
			return { Instance = dock, Position = origin + direction * t }
		end
		return hit
	end
	local function atDock(x: number, z: number): boolean
		local ground =
			raycast(workspace, roblox.Vector3.new(x, 512, z), roblox.Vector3.new(0, -1024, 0), { IgnoreWater = true })
		local top = dock.Position.Y + dock.Size.Y / 2
		engine.move(FIRST, { x = x, y = math.max(if ground then ground.Position.Y else top, top) + 3, z = z })
		return world.home.facts(FIRST, FIRST, "expand", {}).atDock
	end
	local p = dock.Position
	assert(atDock(p.X, p.Z), "standing on the home dock reaches it")
	for _, offset in { { 5, 0 }, { -5, 0 }, { 0, -5 } } do
		assert(atDock(p.X + offset[1], p.Z + offset[2]), "beside the home dock at " .. offset[1] .. "," .. offset[2])
	end
	assert(not atDock(p.X + 30, p.Z), "30 studs away is not at the dock")
	workspace.Raycast = raycast
	-- Without a placed dock part the fixed dock point is the fallback.
	local death, aimed = world.services.survivalDeath, nil
	local reachable = death.reachable
	death.reachable = function(_, position)
		aimed = position
		return true
	end
	dock.Parent = nil
	assert(world.home.facts(FIRST, FIRST, "expand", {}).atDock, "fallback reach")
	assert(aimed == world.home.rules.dock, "fallback aims at the fixed dock point")
	death.reachable = reachable
	assert(factory.close().ok, "release")
	world.destroy()
end

return cases
