--!strict
-- Public per-server camp admission (P0): a real player who is in no pre-provisioned record joins
-- a fresh server, is admitted to that server's camp through the server-origin settlement invite,
-- sees a settlement snapshot and reserves a campfire. A player past the member limit is a visitor
-- and is refused cleanly, and two servers never share (or contend for) the camp's persisted keys.
-- Runs the pack's real SurvivalProvision + SurvivalFactory over the genre bootstrap and Session.

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
local CampPanelModel = require("../../genres/survival-coop/module/CampPanelModel")
local MarketPanel = require("../../genres/survival-coop/module/CrossServerMarketPanel")
local wildlifePolicy = require("./src/shared/WildlifePolicy")
local tamingPolicy = require("./src/shared/TamingConfig")
local monetizationCatalog = require("./src/shared/MonetizationCatalog")
local content = require("./src/shared/SurvivalContent")
local defaultSource = require("./src/shared/SurvivalWorldConfig")
local pack = require("./src/shared/GenreConfig")
local policy = require("./src/shared/GenreDurable")

local PACK = "games/robango-island"
local PUBLIC = { provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} }
-- Real-looking user ids that appear in no provisioning record.
local FIRST, SECOND, THIRD, FOURTH, EXTRA = "11734795308", "2001", "2002", "2003", "2004"

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
				RecipeMarks = require("../../genres/survival-coop/module/RecipeMarks"),
				ProgressionExtension = require("../../genres/survival-coop/module/ProgressionExtension"),
				ToolTiers = require("../../genres/survival-coop/module/ToolTiers"),
				GuideEvents = require("../../genres/survival-coop/module/GuideEvents"),
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
local Provision = module("SurvivalProvision")
local Factory = module("SurvivalFactory")

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
				station = function()
					return nil
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
	factory.bind(session)
	return { session = session, factory = factory, provision = provision, now = now, move = move, equip = equip }
end

local function command(session: any, actor: string, id: string, action: string, args: { any }): any
	local request = {
		requestId = id,
		sessionEpoch = session.commandEpoch(actor, "survival-coop:" .. action) or 0,
		action = "survival-coop:" .. action,
		args = args,
	}
	local result = session.command(actor, request)
	-- Gathers are two-phase escrows: settle them, then replay the same request. Warehouse transfers
	-- must confirm in their own command, so they are never retried through recovery here.
	for _ = 1, 4 do
		if result.ok or action ~= "gather" then
			break
		end
		assert(session.recoverTransfers(actor, 16).ok, "transfer recovery")
		result = session.command(actor, request)
	end
	return result
end

local function woodStacks(session: any, actor: string): { string }
	local ids = {}
	for id, item in session.snapshot(actor)["survival-coop"].inventory.bag.items do
		if item.catalogId == "wood" then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

-- Idle load as Studio produces it: a loopback transport that parks every durable call for a couple
-- of frames, a 1 Hz heartbeat (advance + state push of snapshot and every action epoch per player),
-- and per-frame world readers (mount sync, walk speed) snapshotting every member. Each frame
-- starts its own thread, exactly like engine events, so calls overlap while the transport is slow.
-- Returns per-key write counts and the final generation of every record.
local function idleRun(ids: { string }, heartbeats: number): ({ [string]: number }, { [string]: number })
	local inner = Memory.new()
	local writes: { [string]: number } = {}
	local generations: { [string]: number } = {}
	local last: { [string]: any } = {}
	local slow = false
	local backend: any = {
		update = function(key, transform)
			if slow and coroutine.isyieldable() then
				coroutine.yield()
				coroutine.yield()
			end
			local ok, value = inner.update(key, transform)
			if ok and value and value.revision ~= last[key] then
				last[key] = value.revision
				writes[key] = (writes[key] or 0) + 1
				generations[key] = value.generation
			end
			return ok, value
		end,
	}
	local clockAt = { value = 1000 }
	local server = boot(backend, "job:idle-" .. #ids, clockAt, true)
	local session = server.session
	for _, id in ids do
		assert(session.join(id).ok, "join " .. id)
	end
	slow, manualScheduling = true, true
	local threads: { thread } = {}
	local ok, err = pcall(function()
		for frame = 1, heartbeats * 10 do
			if frame % 10 == 0 then
				clockAt.value += 1
				table.insert(
					threads,
					coroutine.create(function()
						session.advance(clockAt.value)
						for _, id in ids do
							session.snapshot(id)
							for _, action in policy.actions do
								session.commandEpoch(id, action)
							end
						end
					end)
				)
			end
			table.insert(
				threads,
				coroutine.create(function()
					for _, id in session.members() do
						session.snapshot(id)
					end
				end)
			)
			local live = {}
			for _, thread in threads do
				if coroutine.status(thread) == "suspended" then
					local resumed, reason = coroutine.resume(thread)
					if not resumed then
						error(reason, 0)
					end
				end
				if coroutine.status(thread) == "suspended" then
					table.insert(live, thread)
				end
			end
			threads = live
		end
		-- Let in-flight calls settle before release.
		while #threads > 0 do
			local live = {}
			for _, thread in threads do
				assert(coroutine.resume(thread))
				if coroutine.status(thread) == "suspended" then
					table.insert(live, thread)
				end
			end
			threads = live
		end
	end)
	slow, manualScheduling = false, false
	assert(ok, err)
	return writes, generations
end

-- Seeds the bag like the p43 Studio journey (fiber, fallen logs x3); fiber x50 so an
-- over-delivery is reachable without first running short.
local function seedBag(session: any, actor: string)
	local catalog = Job.catalog(content)
	local ok, why = session.personalTransaction(actor, function(raw)
		local data = raw.envelope.genres["survival-coop"].data
		local bag = Inventory.fromSave(data.inventory.bag, catalog)
		for _, seed in { { "fiber-stack", "fiber", 50 }, { "wood-stack", "wood", 3 } } do
			bag = assert(Inventory.add(bag, catalog, {
				itemId = seed[1],
				catalogId = seed[2],
				quantity = seed[3],
				qualityMilli = 1000,
				durabilityMilli = 0,
				attributes = {},
			}, bag.version))
		end
		data.inventory.bag = Inventory.save(bag)
		return raw
	end)
	assert(ok, tostring(why))
end

return {

	["p45 camp Give sends the panel's args and every refusal it can hit has its own KO/EN line"] = function()
		local clockAt = { value = 1000 }
		local server = boot(Memory.new(), "job:p45-camp", clockAt, true)
		local session = server.session
		assert(session.join(FIRST).ok, "join")
		seedBag(session, FIRST)
		local camp = session.snapshot(FIRST).survivalExtensions.camp
		assert(camp and camp.role == "member", "the first player is a camp member")
		-- CampPanel: act("survival-coop:camp-contribute", { row.id, current.itemId, quantity, model.version })
		local given =
			command(session, FIRST, "give", "camp-contribute", { "windbreak", "fiber-stack", 1, camp.version })
		assert(given.ok, "donation accepted: " .. serde.encode("json", given))
		camp = session.snapshot(FIRST).survivalExtensions.camp
		assert(camp.active.windbreak.delivered.fiber == 1, "1/40 fern fiber delivered")
		-- The donation completes guide g04, whose reward (fiber x3) tops this stack back up, so ask
		-- for one more than the stack now holds to hit the bag's own shortage refusal.
		local held = session.snapshot(FIRST)["survival-coop"].inventory.bag.items["fiber-stack"].quantity
		local refusals = {
			{ "stale", { "windbreak", "fiber-stack", 1, camp.version - 1 } },
			{ "over", { "windbreak", "fiber-stack", 40, camp.version } },
			{ "short", { "windbreak", "fiber-stack", held + 1, camp.version } },
			{ "missing", { "windbreak", "gone-stack", 1, camp.version } },
			{ "locked", { "drying-rack", "fiber-stack", 1, camp.version } },
			{ "unknown", { "no-such-project", "fiber-stack", 1, camp.version } },
		}
		local seen: { [string]: boolean } = {}
		for _, case in refusals do
			clockAt.value += 3 -- refill the command rate limiter, which is not what this case tests
			local refused = command(session, FIRST, "r-" .. case[1], "camp-contribute", case[2])
			assert(not refused.ok and type(refused.reason) == "string", case[1] .. " refused")
			seen[refused.reason] = true
			for _, locale in { "en-us", "ko-kr" } do
				local line = CampPanelModel.refusal(locale, refused.reason)
				assert(
					line ~= CampPanelModel.text(locale, "camp_refused"),
					case[1] .. " " .. refused.reason .. " has its own " .. locale .. " line"
				)
			end
		end
		local codes = {}
		for code in seen do
			table.insert(codes, code)
		end
		table.sort(codes)
		assert(
			seen.OVER_DELIVERY and seen.STALE_VERSION and seen.UNAVAILABLE,
			"domain codes: " .. table.concat(codes, ",")
		)
		assert(
			session.snapshot(FIRST).survivalExtensions.camp.active.windbreak.delivered.fiber == 1,
			"refusals move nothing"
		)
		assert(session.close(FIRST).ok and server.factory.close().ok, "release")
	end,
	["p45 harbor market List sends the panel's args; the eligibility refusal names its gate in KO/EN"] = function()
		local server = boot(Memory.new(), "job:p45-market", { value = 1000 }, true)
		local session = server.session
		assert(session.join(FIRST).ok, "join")
		seedBag(session, FIRST)
		local market = session.snapshot(FIRST).survivalExtensions.market
		assert(market and market.eligible == false, "a fresh session is not yet eligible to list")
		-- CrossServerMarketPanel: ctx.send("survival-coop:market-list", { id, draft.quantity, draft.price })
		local listed = command(session, FIRST, "list", "market-list", { "wood-stack", 1, 10 })
		assert(not listed.ok and listed.reason == market.ineligibleReason, "refusal code: " .. tostring(listed.reason))
		assert(listed.reason == "INELIGIBLE_PLAYTIME", "the 2h play gate refuses: " .. tostring(listed.reason))
		local en, ko = MarketPanel.listRefusal("en-us", listed.reason), MarketPanel.listRefusal("ko-kr", listed.reason)
		assert(string.find(en, "2 hours", 1, true) and string.find(ko, "2시간", 1, true), "names the play-time gate")
		assert(en ~= MarketPanel.listRefusal("en-us", "SOMETHING_NEW"), "not the fallback line")
		assert(session.close(FIRST).ok and server.factory.close().ok, "release")
	end,
	["p45 a fresh onboarding player unlocks route 1 through guides using only player commands"] = function()
		local at = { value = 1000 }
		local server = boot(Memory.new(), "job:p45-route", at, nil, nil, true)
		local session = server.session
		assert(session.join(FIRST).ok, "fresh admission")
		local sequence = 0
		local function act(action: string, args: { any }): any
			sequence += 1
			at.value += 3
			session.advance(at.value)
			local result = command(session, FIRST, "p45-" .. sequence, action, args)
			assert(result.ok, action .. ": " .. serde.encode("json", result))
			return result
		end
		local Models = require("../../genres/survival-coop/module/ExpeditionModels")
		local function card(): (any, any)
			local state = session.snapshot(FIRST).survivalExtensions.expedition
			local opened = false
			local _, items = Models.routes("ko-kr", state, {}, function() end, function()
				opened = true
			end)
			local gate, guides
			for _, item in items do
				gate = gate or (if item.name == "RouteGate-1" then item.text else nil)
				guides = guides or (if item.name == "RouteGuides-1" then item else nil)
			end
			if guides then
				guides.onClick()
			end
			return state, { gate = gate, guides = guides ~= nil and opened }
		end
		local fresh, view = card()
		assert(fresh.routes[1].ok == false, "route 1 starts locked")
		assert(view.gate and view.guides, "the locked card names its gate and opens the guides")
		local function gather(node: string)
			act("gather", { node, server.factory.services.survivalGathering.snapshot(FIRST).version })
		end
		local function craft(recipe: string, station: string?)
			local reserved = act("craft-reserve", { recipe, station or "hand" })
			act("craft-start", { reserved.data.jobId })
			at.value += 30
			act("craft-complete", { reserved.data.jobId })
		end
		act("tutorial-skip-arrival", {})
		-- g01 first-gather: fiber x3 (one gather yields 3).
		gather("rw.onboarding.fiber")
		-- g02 first-axe: any axe. On rw.onboarding flint needs a pickaxe and gathering_1, so the
		-- first axe here is the starter axe (branch 3 + stone 2) at the workbench; it also chops the
		-- contract's wood.
		gather("rw.onboarding.branch")
		gather("rw.onboarding.stone")
		server.move(FIRST, { x = -32, y = 5, z = -2 })
		craft("starter-axe", "station.workbench.t1")
		local axe
		for id, item in session.snapshot(FIRST)["survival-coop"].inventory.bag.items do
			axe = if item.catalogId == "starter-axe" then id else axe
		end
		server.equip(FIRST, assert(axe, "starter axe crafted"))
		-- g03 first-contract: survey-driftwood delivers wood x3.
		server.move(FIRST, { x = -54, y = 5, z = 22 })
		gather("rw.onboarding.extra-0")
		act("contract-accept", { "survey-driftwood" })
		act("contract-deliver", { "survey-driftwood" })
		-- g04 camp-donation: one fiber to the windbreak, as the camp panel sends it.
		local fiber
		for id, item in session.snapshot(FIRST)["survival-coop"].inventory.bag.items do
			fiber = if item.catalogId == "fiber" then id else fiber
		end
		local camp = session.snapshot(FIRST).survivalExtensions.camp
		act("camp-contribute", { "windbreak", assert(fiber, "gathered fiber"), 1, camp.version })
		local document = server.factory.expeditionStore.snapshot(FIRST)
		for _, guide in { "rw.g01.first-gather", "rw.g02.first-axe", "rw.g03.first-contract", "rw.g04.camp-donation" } do
			assert(document.development.definitions[guide], guide .. " completed")
		end
		-- Grade 2 meets route 1's development gate; its level gate (30) still holds a fresh player.
		local unlocked = session.snapshot(FIRST).survivalExtensions.expedition
		assert(unlocked.facts.developmentRank >= 2, "grade " .. tostring(unlocked.facts.developmentRank))
		assert(unlocked.facts.developmentRank >= unlocked.routes[1].rank, "route 1 grade met")
		assert(unlocked.routes[1].reason == "level_gate", "route 1 reason: " .. tostring(unlocked.routes[1].reason))
		local _, after = card()
		local prefix = string.format("레벨 %d/30", unlocked.facts.level)
		assert(after.gate and string.sub(after.gate, 1, #prefix) == prefix, "level gate line: " .. tostring(after.gate))
		assert(session.close(FIRST).ok and server.factory.close().ok, "release")
	end,
	["p45 the default Studio preview island lets a fresh player finish g01-g04 and unlock route 1"] = function()
		local at = { value = 1000 }
		local server = boot(Memory.new(), "job:p45-preview", at, nil, true)
		local session = server.session
		assert(session.join(FIRST).ok, "fresh admission")
		local sequence = 0
		local function act(action: string, args: { any }): any
			sequence += 1
			at.value += 3
			session.advance(at.value)
			local result = command(session, FIRST, "p45p-" .. sequence, action, args)
			assert(result.ok, action .. ": " .. serde.encode("json", result))
			return result
		end
		local version = 0 -- the gather source version advances once per accepted gather
		local function gather(node: string, times: number)
			for _ = 1, times do
				act("gather", { node, version })
				version += 1
			end
		end
		local function craft(recipe: string, station: string)
			local reserved = act("craft-reserve", { recipe, station })
			act("craft-start", { reserved.data.jobId })
			at.value += 30
			act("craft-complete", { reserved.data.jobId })
		end
		act("tutorial-skip-arrival", {})
		-- g01 first-gather: fiber x3.
		gather("fiber-bush-01", 1)
		-- g02 first-axe: the Flint Hatchet (flint x2, by hand).
		gather("flint-outcrop-01", 1)
		craft("stone-axe", "hand")
		-- g03 first-contract: survey-driftwood delivers wood x3 from the fallen tree.
		gather("fallen-tree-01", 1)
		act("contract-accept", { "survey-driftwood" })
		act("contract-deliver", { "survey-driftwood" })
		-- g04 camp-donation: one fiber to the windbreak.
		local fiber
		for id, item in session.snapshot(FIRST)["survival-coop"].inventory.bag.items do
			fiber = if item.catalogId == "fiber" then id else fiber
		end
		local camp = session.snapshot(FIRST).survivalExtensions.camp
		act("camp-contribute", { "windbreak", assert(fiber, "gathered fiber"), 1, camp.version })
		local done = server.factory.expeditionStore.snapshot(FIRST).development.definitions
		for _, guide in { "rw.g01.first-gather", "rw.g02.first-axe", "rw.g03.first-contract", "rw.g04.camp-donation" } do
			assert(done[guide], guide .. " completed on the preview island")
		end
		local unlocked = session.snapshot(FIRST).survivalExtensions.expedition
		assert(unlocked.facts.developmentRank >= 2, "grade " .. tostring(unlocked.facts.developmentRank))
		assert(unlocked.routes[1].reason ~= "development_gate", "route 1 grade gate met")
		assert(unlocked.routes[1].reason == "level_gate", "route 1 reason: " .. tostring(unlocked.routes[1].reason))
		assert(session.close(FIRST).ok and server.factory.close().ok, "release")
	end,
	["p45 a deposit out of warehouse reach names the reach, not a generic refusal"] = function()
		local server = boot(Memory.new(), "job:p45-reach", { value = 1000 }, nil, true)
		local session = server.session
		assert(session.join(FIRST).ok, "fresh admission")
		assert(command(session, FIRST, "g1", "gather", { "fallen-tree-01", 0 }).ok, "gather")
		server.move(FIRST, { x = 60, y = 2, z = 40 })
		local refused = command(session, FIRST, "d1", "transfer-deposit", { woodStacks(session, FIRST)[1], 1 })
		assert(not refused.ok and refused.reason == "WAREHOUSE_UNREACHABLE", "reason: " .. tostring(refused.reason))
		local HudLocale = require("../../genres/survival-coop/module/SurvivalHUDLocale")
		for _, locale in { "en-us", "ko-kr" } do
			assert(
				HudLocale.refusal(locale, refused.reason) ~= HudLocale.text(locale, "unknown"),
				locale .. " names the warehouse"
			)
		end
		server.move(FIRST, { x = 6, y = 2, z = -22 })
		assert(command(session, FIRST, "d2", "transfer-deposit", { woodStacks(session, FIRST)[1], 1 }).ok, "in reach")
		assert(session.close(FIRST).ok and server.factory.close().ok, "release")
	end,
	["real onboarding owner crafts the starter axe, chops wood and deposits through the elevated depot"] = function()
		local at = { value = 1000 }
		local server = boot(Memory.new(), "job:real-role", at, nil, nil, true)
		local session = server.session
		assert(session.join(FIRST).ok, "real role admission")
		local sequence = {}
		local function tutorial(expected: string)
			local step = session.snapshot(FIRST).survivalExtensions.contracts.tutorial.step
			assert(step == expected, "tutorial expected " .. expected .. ", got " .. tostring(step))
			table.insert(sequence, step)
		end
		tutorial("arrive")
		assert(command(session, FIRST, "real-arrive", "tutorial-skip-arrival", {}).ok, "finish arrival")
		tutorial("gather")
		assert(command(session, FIRST, "real-branch", "gather", { "rw.onboarding.branch", 0 }).ok, "real branch gather")
		tutorial("craft-stone-axe")
		at.value += 1
		local stone = command(session, FIRST, "real-stone", "gather", { "rw.onboarding.stone", 1 })
		assert(stone.ok, "real stone gather: " .. serde.encode("json", stone))
		server.move(FIRST, { x = -32, y = 5, z = -2 })
		local craft = command(session, FIRST, "real-axe", "craft-reserve", { "starter-axe", "station.workbench.t1" })
		assert(craft.ok, "real axe reserve: " .. serde.encode("json", craft))
		assert(command(session, FIRST, "real-start", "craft-start", { craft.data.jobId }).ok, "start axe")
		at.value += 4
		session.advance(at.value)
		local complete = command(session, FIRST, "real-complete", "craft-complete", { craft.data.jobId })
		assert(complete.ok, "complete axe: " .. serde.encode("json", complete))
		tutorial("declare-settlement")
		local axe
		for id, item in session.snapshot(FIRST)["survival-coop"].inventory.bag.items do
			if item.catalogId == "starter-axe" then
				axe = id
			end
		end
		assert(axe, "crafted starter axe in bag")
		server.equip(FIRST, axe)
		server.move(FIRST, { x = -54, y = 5, z = 22 })
		local wood = command(session, FIRST, "real-wood", "gather", { "rw.onboarding.extra-0", 2 })
		assert(wood.ok, "axe-gated wood: " .. serde.encode("json", wood))
		assert(command(session, FIRST, "real-wood2", "gather", { "rw.onboarding.extra-0", 3 }).ok, "more wood")
		server.move(FIRST, { x = -16, y = 7, z = -4 })
		local stacks = woodStacks(session, FIRST)
		assert(#stacks > 0, "canonical wood available to recipes")
		for index, id in stacks do
			local item = session.snapshot(FIRST)["survival-coop"].inventory.bag.items[id]
			assert(
				command(session, FIRST, "real-deposit" .. index, "transfer-deposit", { id, item.quantity }).ok,
				"real depot transfer"
			)
		end
		local camp = session.snapshot(FIRST).survivalSettlement
		local reserved = command(session, FIRST, "real-build", "settlement-reserve", {
			"campfire",
			4,
			4,
			0,
			camp.settlement.version,
			camp.warehouse.version,
			camp.settlement.membershipRevision,
		})
		assert(reserved.ok, "real campfire reserve: " .. serde.encode("json", reserved))
		camp = session.snapshot(FIRST).survivalSettlement
		assert(
			command(
				session,
				FIRST,
				"real-place",
				"settlement-place",
				{ reserved.data.reservationId, camp.settlement.version, camp.warehouse.version }
			).ok,
			"real place"
		)
		tutorial("accept-contract")
		print("real onboarding tutorial: " .. table.concat(sequence, " -> "))
		server.move(FIRST, { x = -48, y = 5, z = -4 })
		local rest = command(session, FIRST, "real-rest", "rest", { "station.campfire.t1" })
		assert(rest.ok, "real rest: " .. serde.encode("json", rest))
		assert(session.close(FIRST).ok and server.factory.close().ok, "release real role")
	end,
	["fresh preview owner deposits immediately through physical warehouse reach"] = function()
		local server = boot(Memory.new(), "job:preview", { value = 1000 }, nil, true)
		local session = server.session
		assert(session.join(FIRST).ok, "fresh admission")
		assert(session.snapshot(FIRST).survivalSettlement.settlement.roles[FIRST] == "owner", "owner")
		assert(command(session, FIRST, "g1", "gather", { "fallen-tree-01", 0 }).ok, "gather")
		local result = command(session, FIRST, "d1", "transfer-deposit", { woodStacks(session, FIRST)[1], 1 })
		assert(result.ok, "physical warehouse deposit: " .. serde.encode("json", result))
		assert(session.close(FIRST).ok and server.factory.close().ok, "release")
	end,
	["idle players on a slow transport never re-acquire or rewrite their extension records"] = function()
		-- One player alone, then four seated members plus a visitor.
		for _, ids in { { FIRST }, { FIRST, SECOND, THIRD, FOURTH, EXTRA } } do
			local heartbeats = 120
			local writes, generations = idleRun(ids, heartbeats)
			for key, count in writes do
				-- No record may be re-acquired while its owner is idle: a generation bump is a lease
				-- stolen from this same server (live: contracts:-1 reached generation 57).
				assert(generations[key] == 1, key .. " re-acquired: generation " .. generations[key])
				local extensionRecord = string.find(key, "^contracts:")
					or string.find(key, "^mkt:")
					or string.find(key, "^mon:")
					or string.find(key, "^taming%-v1:")
					or string.find(key, "^camp:")
				if extensionRecord then
					-- acquire + release, the first renew, and one renew per 60 s of a 120 s lease.
					local allowed = 3 + math.ceil(heartbeats / 60)
					assert(count <= allowed, key .. " idle writes " .. count .. " > " .. allowed)
				end
			end
			for _, id in ids do
				assert(writes["contracts:" .. id], "contracts loaded for " .. id)
			end
		end
	end,
	["an idle admitted owner and an idle visitor never rewrite the camp record beyond lease renewals"] = function()
		local inner = Memory.new()
		local campWrites = 0
		local lastRevision: any = nil
		local backend: any = {
			update = function(key, transform)
				local ok, value = inner.update(key, transform)
				if ok and value and string.find(key, ":camp-v1", 1, true) and value.revision ~= lastRevision then
					lastRevision = value.revision
					campWrites += 1
				end
				return ok, value
			end,
		}
		local clockAt = { value = 1000 }
		local server = boot(backend, "job:idle", clockAt)
		local session = server.session
		-- One admitted owner plus one visitor (the camp is already full of seats for everyone else).
		assert(session.join(FIRST).ok, "owner joins")
		for _, actor in { SECOND, THIRD, FOURTH } do
			assert(session.join(actor).ok, actor)
		end
		assert(session.join(EXTRA).ok, "visitor joins")
		assert(session.snapshot(EXTRA).survivalSettlement == nil, "EXTRA is a visitor")
		-- Each heartbeat mirrors Server: advance, then a state push per member (snapshot plus the
		-- command epoch of every durable action).
		local function heartbeat()
			clockAt.value += 1
			session.advance(clockAt.value)
			for _, actor in { FIRST, SECOND, THIRD, FOURTH, EXTRA } do
				session.snapshot(actor)
				session.commandEpoch(actor)
				for _, action in policy.actions do
					session.commandEpoch(actor, action)
				end
			end
		end
		-- The first push issues each member's command epoch ledger once: a real change.
		heartbeat()
		local before = campWrites
		local ticks = 120
		for _ = 1, ticks do
			heartbeat()
		end
		-- Leases (120 s) renew once they are half spent: one renew per 60 s of idle time. Anything
		-- more is a write of an unchanged camp (before the fix: ~1700 here, from the visitor).
		local allowed = math.ceil(ticks / 60)
		assert(
			campWrites - before <= allowed,
			"idle camp writes " .. (campWrites - before) .. " > " .. allowed .. " (lease renewals only)"
		)
		-- The visitor is still refused, and a member still gets an epoch.
		assert(session.commandEpoch(EXTRA, "survival-coop:settlement-reserve") == nil, "visitor refused")
		assert(session.commandEpoch(FIRST, "survival-coop:settlement-reserve") ~= nil, "member epoch")
		for _, actor in { FIRST, SECOND, THIRD, FOURTH, EXTRA } do
			assert(session.close(actor).ok, "close " .. actor)
		end
		assert(server.factory.close().ok, "release")
	end,
	["a fresh-server player in no record gets a camp and reserves a campfire; extras are visitors"] = function()
		local backend = Memory.new()
		local clockAt = { value = 1000 }
		local server = boot(backend, "job:server-a", clockAt)
		local session = server.session
		local joined = session.join(FIRST)
		assert(joined.ok and joined.notificationError == nil, tostring(joined.notificationError or joined.reason))
		local camp = session.snapshot(FIRST).survivalSettlement
		assert(camp ~= nil, "a joining player sees the settlement (was SETTLEMENT_UNAVAILABLE)")
		assert(camp.settlement.ownerId == FIRST and camp.settlement.roles[FIRST] == "owner", "first player owns")
		assert(camp.settlement.roles.steward == nil, "the server steward left once a player owned the camp")
		-- Gather six wood, store it in the camp warehouse, and reserve the campfire (wood x4).
		local g1 = command(session, FIRST, "g1", "gather", { "fallen-tree-01", 0 })
		assert(g1.ok, "gather 1 " .. tostring(g1.reason))
		assert(command(session, FIRST, "g2", "gather", { "fallen-tree-01", 1 }).ok, "gather 2")
		for index, itemId in woodStacks(session, FIRST) do
			local deposited = command(session, FIRST, "d" .. index, "transfer-deposit", { itemId, 3 })
			assert(deposited.ok, "deposit " .. tostring(deposited.reason))
		end
		camp = session.snapshot(FIRST).survivalSettlement
		local reserved = command(session, FIRST, "build", "settlement-reserve", {
			"campfire",
			4,
			4,
			0,
			camp.settlement.version,
			camp.warehouse.version,
			camp.settlement.membershipRevision,
		})
		assert(reserved.ok, "campfire reserve " .. tostring(reserved.reason))
		assert(
			session.snapshot(FIRST).survivalSettlement.settlement.reservations[reserved.data.reservationId],
			"the reservation is in the camp"
		)
		-- Three more players fill the four seats; each is a member with its own snapshot.
		for _, actor in { SECOND, THIRD, FOURTH } do
			local result = session.join(actor)
			assert(result.ok and result.notificationError == nil, actor .. " admission")
			local view = session.snapshot(actor).survivalSettlement
			assert(view and view.settlement.roles[actor] == "member", actor .. " is a member")
		end
		-- The fifth player loads normally but holds no seat: no camp snapshot, settlement refused.
		local extra = session.join(EXTRA)
		assert(extra.ok and extra.notificationError == nil, "a visitor joins cleanly, not kicked")
		assert(session.snapshot(EXTRA).survivalSettlement == nil, "a visitor has no camp snapshot")
		assert(session.snapshot(EXTRA)["survival-coop"] ~= nil, "a visitor still plays personally")
		local refused = command(session, EXTRA, "sneak", "settlement-reserve", { "campfire", 8, 8, 0, 0, 0, 0 })
		assert(not refused.ok and refused.reason == "FORBIDDEN", "visitor build refused: " .. tostring(refused.reason))
		local roles = session.snapshot(FIRST).survivalSettlement.settlement.roles
		assert(roles[EXTRA] == nil, "no fifth seat")
		-- Invites stay server-only and consent stays per-admission: no lingering consent record.
		assert(
			not server.provision.authorize(FIRST, "survival-coop:settlement-invite", {}, "client").ok,
			"client invite"
		)
		assert(not server.provision.consent(FIRST, EXTRA), "no standing consent for a refused visitor")
		for _, actor in { FIRST, SECOND, THIRD, FOURTH, EXTRA } do
			assert(session.close(actor).ok, "close " .. actor)
		end
		assert(server.factory.close().ok, "factory release")
	end,
	["the admitted first player deposits into the warehouse and builds a campfire paid from it"] = function()
		local backend = Memory.new()
		local server = boot(backend, "job:server-deposit", { value = 1000 })
		local session = server.session
		assert(session.join(FIRST).ok, "join")
		local camp = session.snapshot(FIRST).survivalSettlement
		assert(camp.settlement.ownerId == FIRST and camp.settlement.membershipRevision > 0, "admitted via handover")
		assert(command(session, FIRST, "g1", "gather", { "fallen-tree-01", 0 }).ok, "gather 1")
		assert(command(session, FIRST, "g2", "gather", { "fallen-tree-01", 1 }).ok, "gather 2")
		local stack = woodStacks(session, FIRST)[1]
		-- Out of warehouse reach the grant is refused (the spatial proof), and nothing moves.
		reach.warehouse = false
		local far = session.command(FIRST, {
			requestId = "far",
			sessionEpoch = assert(session.commandEpoch(FIRST, "survival-coop:transfer-deposit")),
			action = "survival-coop:transfer-deposit",
			args = { stack, 1 },
		})
		reach.warehouse = true
		-- p45: the refusal names the reach (it was the generic UNAUTHORIZED the HUD could not explain).
		assert(not far.ok and far.reason == "WAREHOUSE_UNREACHABLE" and far.data.phase == "GRANT", "reach gate")
		-- The HUD deposits one at a time: four single deposits pay for the campfire (wood x4).
		local count = 0
		for _, itemId in woodStacks(session, FIRST) do
			for unit = 1, 3 do
				if count < 4 then
					count += 1
					local deposited = command(session, FIRST, "d" .. itemId .. unit, "transfer-deposit", { itemId, 1 })
					assert(deposited.ok, "deposit " .. count .. " " .. tostring(deposited.reason))
				end
			end
		end
		local function warehouseWood(): number
			local total = 0
			for _, item in session.snapshot(FIRST).survivalSettlement.warehouse.items do
				if item.catalogId == "wood" then
					total += item.quantity
				end
			end
			return total
		end
		assert(warehouseWood() == 4, "four wood in the warehouse, got " .. warehouseWood())
		camp = session.snapshot(FIRST).survivalSettlement
		local reserved = command(session, FIRST, "build", "settlement-reserve", {
			"campfire",
			4,
			4,
			0,
			camp.settlement.version,
			camp.warehouse.version,
			camp.settlement.membershipRevision,
		})
		assert(reserved.ok, "reserve " .. tostring(reserved.reason))
		camp = session.snapshot(FIRST).survivalSettlement
		local placed = command(
			session,
			FIRST,
			"place",
			"settlement-place",
			{ reserved.data.reservationId, camp.settlement.version, camp.warehouse.version }
		)
		assert(placed.ok, "place " .. tostring(placed.reason))
		assert(warehouseWood() == 0, "the campfire was paid from the warehouse")
		assert(session.close(FIRST).ok and server.factory.close().ok, "release")
	end,
	["a warehouse deposit and withdraw each confirm in their own command and a resent request replays confirmed"] = function()
		local backend = Memory.new()
		local server = boot(backend, "job:server-confirm", { value = 1000 })
		local session = server.session
		assert(session.join(FIRST).ok, "join")
		assert(command(session, FIRST, "g1", "gather", { "fallen-tree-01", 0 }).ok, "gather")
		local function bagWood(): number
			local total = 0
			for _, item in session.snapshot(FIRST)["survival-coop"].inventory.bag.items do
				if item.catalogId == "wood" then
					total += item.quantity
				end
			end
			return total
		end
		local function warehouseWood(): (number, string?)
			local total, id = 0, nil
			for itemId, item in session.snapshot(FIRST).survivalSettlement.warehouse.items do
				if item.catalogId == "wood" then
					total += item.quantity
					id = itemId
				end
			end
			return total, id
		end
		-- The HUD freezes one request and re-sends that exact table on Retry; no recovery runs in between.
		local function frozen(id: string, action: string, args: { any }): any
			return {
				requestId = id,
				sessionEpoch = assert(session.commandEpoch(FIRST, "survival-coop:" .. action)),
				action = "survival-coop:" .. action,
				args = args,
			}
		end
		local function confirmed(result: any, label: string)
			assert(
				result.ok
					and result.reason == nil
					and result.data.status == "confirmed"
					and result.data.phase == "FINALIZED",
				label .. " confirms in one command, got " .. serde.encode("json", result)
			)
		end
		local bag = bagWood()
		local deposit = frozen("hud-deposit", "transfer-deposit", { woodStacks(session, FIRST)[1], 1 })
		local deposited = session.command(FIRST, deposit)
		confirmed(deposited, "deposit")
		assert(bagWood() == bag - 1 and warehouseWood() == 1, "one wood moved")
		local again = session.command(FIRST, deposit)
		confirmed(again, "resent deposit")
		assert(again.stateVersion == deposited.stateVersion, "the replay is the original terminal result")
		assert(bagWood() == bag - 1 and warehouseWood() == 1, "a resent deposit never moves a second wood")
		local _, stored = warehouseWood()
		local withdraw = frozen("hud-withdraw", "transfer-withdraw", { assert(stored, "warehouse wood"), 1 })
		local withdrawn = session.command(FIRST, withdraw)
		confirmed(withdrawn, "withdraw")
		assert(bagWood() == bag and warehouseWood() == 0, "the wood came back")
		confirmed(session.command(FIRST, withdraw), "resent withdraw")
		assert(bagWood() == bag and warehouseWood() == 0, "a resent withdraw never moves a second wood")
		assert(session.close(FIRST).ok and server.factory.close().ok, "release")
	end,
	["each server owns distinct camp keys and never contends with another server"] = function()
		local a = Provision(PUBLIC, "camp", { studio = false, server = "job:server-a" })
		local b = Provision(PUBLIC, "camp", { studio = false, server = "job:server-b" })
		assert(a.id ~= b.id and a.tribeId ~= b.tribeId, "distinct persistence scope per server")
		local again = Provision(PUBLIC, "camp", { studio = false, server = "private:island-7" })
		assert(
			again.id == Provision(PUBLIC, "camp", { studio = false, server = "private:island-7" }).id,
			"a reserved server keeps its camp scope across restarts"
		)
		local prefix = defaultSource.persistencePrefix .. ":" .. a.id .. ":" .. defaultSource.tribe.key
		assert(#prefix <= 50 and #("camp:" .. a.tribeId) <= 50, "scoped keys fit the leased key limit")
		assert(not pcall(Provision, PUBLIC, "camp", { studio = false }), "a public server needs a scope")
		local seeded = table.clone(PUBLIC)
		seeded.acceptedInvitations = { ["5"] = true }
		assert(not pcall(Provision, seeded, "camp", { server = "job:x" }), "public ignores no static record")
		-- Both servers run at once on one backend: a shared key would refuse the second as `locked`.
		local backend = Memory.new()
		local clockAt = { value = 1000 }
		local first = boot(backend, "job:server-a", clockAt)
		local second = boot(backend, "job:server-b", clockAt)
		assert(first.session.join("3001").ok and second.session.join("3002").ok, "two servers, two players")
		local campA = first.session.snapshot("3001").survivalSettlement
		local campB = second.session.snapshot("3002").survivalSettlement
		assert(campA and campB, "each server's first player has a camp")
		assert(campA.settlement.config.tribeId ~= campB.settlement.config.tribeId, "distinct camps")
		assert(campA.settlement.roles["3002"] == nil and campB.settlement.roles["3001"] == nil, "no cross-server seats")
		assert(first.session.close("3001").ok and second.session.close("3002").ok, "close")
		assert(first.factory.close().ok and second.factory.close().ok, "release")
	end,
}
