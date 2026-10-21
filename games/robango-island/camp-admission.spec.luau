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
local wildlifePolicy = require("./src/shared/WildlifePolicy")
local tamingPolicy = require("./src/shared/TamingConfig")
local monetizationCatalog = require("./src/shared/MonetizationCatalog")
local content = require("./src/shared/SurvivalContent")
local source = require("./src/shared/SurvivalWorldConfig")
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
local Provision = module("SurvivalProvision")
local Factory = module("SurvivalFactory")

type Server = { session: any, factory: any, provision: any, now: () -> number }
local reach = { warehouse = true }
-- live = true wires what RobangoIslandServer configures: wildlife, taming, shop and market (whose
-- tutorial gate reads the contracts snapshot, as the server script does).
local function boot(backend: any, server: string, clockAt: { value: number }, live: boolean?): Server
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
	return { session = session, factory = factory, provision = provision, now = now }
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

return {
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
		assert(not far.ok and far.reason == "UNAUTHORIZED" and far.data.phase == "GRANT", "reach gate")
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
		local prefix = source.persistencePrefix .. ":" .. a.id .. ":" .. source.tribe.key
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
