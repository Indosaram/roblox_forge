--!strict
local Engine = require("./engine")
local Content: any = require("../../../../games/robango-island/src/shared/SurvivalContent")
local Source = require("../../../../games/robango-island/src/shared/SurvivalWorldConfig")
local Policy = require("../../../../games/robango-island/src/shared/WildlifePolicy")
local HomeContent = require("../../../../core/domain/home/HomeContent")
local Session = require("../../../../core/infra/genre/Session")
local Data = require("../../../../core/domain/genre/SerializedData")
local M = {}
local function actorOf(_ctx: any, _step: any): string
	return "11734795308"
end
M.operations = {
	world_join = function(ctx, step): string?
		local ok, result = pcall(ctx.fixture.session.join, actorOf(ctx, step))
		if not ok then
			print(result)
			return "world_join_exception"
		end
		return if result.ok then nil else result.reason
	end,
	world_home = function(ctx, step): string?
		return ctx.fixture.enter("home", actorOf(ctx, step))
	end,
	world_expedition = function(ctx, step): string?
		return ctx.fixture.expedition(actorOf(ctx, step))
	end,
	world_onboarding = function(ctx, step): string?
		return ctx.fixture.onboarding(actorOf(ctx, step))
	end,
	world_gather = function(ctx, step): string?
		return ctx.fixture.gather(actorOf(ctx, step))
	end,
	world_survey = function(ctx, step): string?
		return ctx.fixture.survey(actorOf(ctx, step))
	end,
	world_return_reload = function(ctx, step): string?
		return ctx.fixture.returnReload(actorOf(ctx, step))
	end,
	world_storage_transfer = function(ctx, step): string?
		return ctx.fixture.storageTransfer(actorOf(ctx, step))
	end,
	world_rescue_cargo = function(ctx, step): string?
		return ctx.fixture.rescueCargo(actorOf(ctx, step), false)
	end,
	world_four_rewards = function(ctx, step): string?
		local ok, result = xpcall(function()
			return ctx.fixture.rescueCargo(actorOf(ctx, step), true)
		end, debug.traceback)
		if not ok then
			print(result)
			return "four_island_exception"
		end
		return result
	end,
}
function M.new(ctx: any): any
	local engine = Engine.new()
	local forge = engine.forge
	local module = forge.genres["survival-coop"].module
	module.SurvivalBootstrap = require("../../../../genres/survival-coop/module/SurvivalBootstrap")
	module.Gathering = require("../../../../genres/survival-coop/module/Gathering")
	module.Wildlife = require("../../../../genres/survival-coop/module/Wildlife")
	module.HomeExtension = require("../../../../genres/survival-coop/module/HomeExtension")
	module.ArchipelagoExtension = require("../../../../genres/survival-coop/module/ArchipelagoExtension")
	module.Extensions = { factories = {} }
	forge.core.domain.home = { HomeContent = HomeContent }
	forge.core.domain.settlement = { Settlement = require("../../../../core/domain/settlement/Settlement") }
	forge.core.domain.inventory = { Inventory = require("../../../../core/domain/inventory/Inventory") }
	forge.core.domain.crafting = { Job = require("../../../../core/domain/crafting/Job") }
	forge.core.domain.command = { Journal = require("../../../../core/domain/command/Journal") }
	forge.core.domain.island.Archipelago = require("../../../../core/domain/island/Archipelago")
	forge.core.infra = {
		genre = { Clock = require("../../../../core/infra/genre/Clock"), Session = Session },
		data = { ActorDocumentStore = require("../../../../core/infra/data/ActorDocumentStore") },
	}
	local factoryBuilder = engine.load("games/robango-island/src/server/SurvivalFactory.luau", {}, {
		Parent = { LateEquipmentPorts = require("../../../../games/robango-island/src/server/LateEquipmentPorts") },
	})
	local source: any = table.clone(Source)
	source.seed, source.renderRole = ctx.scenario.seed, engine.role.build
	local factory: any, session: any, world: any
	local sequence = 0
	local actorId: string? = nil
	local function create(role: string, actor: string)
		sequence += 1
		if role == "home" then
			world = engine.home.live(Content, source, Policy, function()
				return ctx.now() * 1000
			end)
		else
			world = engine.archipelago.live(Content, source, Policy, function()
				return ctx.now() * 1000
			end)
		end
		local options: any = {
			sessionId = "worlds:" .. tostring(sequence),
			leaseSeconds = 120,
			now = ctx.now,
			budget = {
				encode = function(value)
					return require("@lune/serde").encode("json", value)
				end,
			},
		}
		local provisionBuilder = engine.load("games/robango-island/src/server/SurvivalProvision.luau", {}, nil)
		local provision = provisionBuilder(
			{ provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} },
			source.tribe.config.tribeId,
			{ studio = false, server = "worlds:" .. tostring(sequence) }
		)
		factory = assert(factoryBuilder(Content, source, world, ctx.backend, ctx.clock, options, provision, Policy))
		local services = table.clone(factory.services)
		services.now = ctx.clock.now
		services.roll = function()
			return 0
		end
		services.emit = function() end
		services.encode = function(value)
			return require("@lune/serde").encode("json", value)
		end
		session = Session.new(
			{
				packConfig = require("../../../../games/robango-island/src/shared/GenreConfig"),
				contracts = { require("../../../../genres/survival-coop/module/Contract") },
				durable = require("../../../../games/robango-island/src/shared/GenreDurable"),
				controls = {},
				storeName = "worlds-personal",
			},
			ctx.backend,
			{ sessionId = options.sessionId, lockTimeout = 120, retries = 0, now = ctx.now },
			services,
			require("../../../../games/robango-island/src/shared/GenreDurable")
		)
		factory.bind(session)
		actorId = actor
	end
	local api: any = {}
	local function close()
		if not factory then
			return { ok = true }
		end
		for _, actor in session.members() do
			local left = session.close(actor)
			if not left.ok then
				return left
			end
		end
		return factory.close()
	end
	function api.enter(role, actor)
		if factory then
			local closed = close()
			if not closed.ok then
				return closed.reason
			end
		end
		local created, failure = xpcall(function()
			create(role, actor)
		end, debug.traceback)
		if not created then
			print(failure)
			return "world_create_failed"
		end
		local joined = session.join(actor)
		if not joined.ok then
			return joined.reason
		end
		api.session = session
		engine.move(actor, Content.homePolicy.dock)
		local home, reason = factory.homeOwner().snapshot(actor)
		return if home and home.owner == actor then nil else reason or "home_missing"
	end
	function api.expedition(actor)
		local opened = factory.archipelago.open(actor, {
			id = "production-expedition",
			index = 1,
			seed = ctx.scenario.seed,
			revision = "production-v2",
			ttl = 1800,
			entryBuffer = 30,
		})
		if not opened.ok then
			return opened.reason
		end
		source.expedition = factory.expeditionStore.snapshot(actor).archipelago
		return api.enter("archipelago", actor)
	end
	local commandSequence = 0
	local function request(actor: string, action: string, args: { any }): any
		commandSequence += 1
		local qualified = "survival-coop:" .. action
		return {
			requestId = "world-command-" .. tostring(commandSequence),
			sessionEpoch = session.commandEpoch(actor, qualified),
			action = qualified,
			args = args,
		}
	end
	local function refused(actor: string, action: string, args: { any }, reason: string)
		ctx.clock.advanceTo(ctx.clock.now() + 3)
		local result = session.command(actor, request(actor, action, args))
		assert(
			not result.ok and result.reason == reason,
			action .. ": expected " .. reason .. " got " .. tostring(result.reason)
		)
	end
	local function command(actor: string, action: string, args: { any }): any
		ctx.clock.advanceTo(ctx.clock.now() + 3)
		session.advance(ctx.clock.now())
		commandSequence += 1
		local qualified = "survival-coop:" .. action
		local result = session.command(actor, {
			requestId = "onboarding-" .. tostring(commandSequence),
			sessionEpoch = session.commandEpoch(actor, qualified),
			action = qualified,
			args = args,
		})
		assert(result.ok or (result.data and result.data.status == "pending"), action .. ":" .. tostring(result.reason))
		return result
	end
	local function gather(actor, item, count)
		local node
		for _, candidate in world.roleSource.nodes do
			if candidate.id == "rw.home." .. item then
				node = candidate
			end
		end
		assert(node, "onboarding node missing: " .. item)
		engine.move(actor, node.position)
		for _ = 1, count do
			local snapshot = factory.services.survivalGathering.snapshot(actor)
			command(actor, "gather", { node.id, snapshot.version })
			local settled = factory.services.survivalGathering.recover(actor, 8)
			assert(settled.status == "confirmed", settled.error)
		end
	end
	local function personal(actor)
		return session.personalTransfer(actor).profile().data.envelope.genres["survival-coop"].data
	end
	local function craft(actor: string, recipeId: string, station: string?)
		local recipe
		for _, row in Content.recipes do
			if row.id == recipeId then
				recipe = row
			end
		end
		assert(recipe, "onboarding recipe missing")
		if station then
			for _, anchor in world.layout.anchors do
				if anchor.id == station then
					engine.move(actor, anchor.position)
				end
			end
		end
		local result = command(actor, "craft-reserve", { recipeId, station or "hand" })
		local job = result.data.jobId
		command(actor, "craft-start", { job })
		ctx.clock.advanceTo(ctx.clock.now() + recipe.craftMillis / 1000)
		command(actor, "craft-complete", { job })
	end
	function api.storageTransfer(actor)
		gather(actor, "branch", 2)
		local id, quantity
		for key, item in personal(actor).inventory.bag.items do
			if item.catalogId == "branch" then
				id, quantity = key, item.quantity
			end
		end
		assert(id and quantity, "gathered owned branch")
		engine.move(actor, Content.homePolicy.dock)
		refused(actor, "home-deposit", { "home:other", { itemId = id, quantity = 1 } }, "WRONG_HOME_TOKEN")
		refused(
			actor,
			"home-deposit",
			{ "home:" .. actor, { itemId = id, quantity = quantity + 1 } },
			"INSUFFICIENT_ITEMS"
		)
		local deposit = request(actor, "home-deposit", { "home:" .. actor, { itemId = id, quantity = quantity } })
		assert(session.command(actor, deposit).ok, "deposit commits")
		assert(session.command(actor, deposit).ok, "deposit replay")
		assert(personal(actor).inventory.bag.items[id] == nil, "bag debited once")
		local home = factory.homeOwner().snapshot(actor)
		assert(home.storage.items[id].quantity == quantity, "home credited once")
		assert(api.enter("home", actor) == nil, "reconnect")
		command(actor, "home-withdraw", { "home:" .. actor, { itemId = id, quantity = quantity } })
		assert(personal(actor).inventory.bag.items[id].quantity == quantity, "same identity and quantity returned")
		refused(actor, "home-withdraw", { "home:" .. actor, { itemId = id, quantity = 1 } }, "INSUFFICIENT_ITEMS")
		return nil
	end
	local function anchor(id)
		for _, row in world.layout.anchors do
			if row.id == id then
				return row.position
			end
		end
		error("missing anchor " .. id)
	end
	local function reloadStage(actor)
		source.expedition = factory.expeditionStore.snapshot(actor).archipelago
		assert(api.enter("archipelago", actor) == nil, "enter stage")
	end
	local function mission(actor, action)
		return command(actor, "mission-action", { action, world.layout.id })
	end
	local function recover(actor)
		assert(session.recoverTransfers(actor, 64).ok, "production recovery")
	end
	local function hunt(actor)
		local objective
		for _, row in Content.stages do
			if row.layout == world.layout.id then
				for _, candidate in row.objectives do
					if candidate.action == "hunt" then
						objective = candidate
					end
				end
			end
		end
		for _, spawn in world.roleWildlife.spawns do
			if spawn.catalogId == objective.target then
				local target = { x = spawn.position.x, y = spawn.position.y, z = spawn.position.z + 2 }
				engine.move(actor, target)
				engine.equip(world, actor, api.spear)
				for _ = 1, 100 do
					local npcs = factory.services.survivalWildlife.snapshot(actor)
					if npcs[spawn.id].healthMilli == 0 then
						break
					end
					command(actor, "attack", { spawn.id })
					ctx.clock.advanceTo(ctx.clock.now() + Content.progressionPolicy.combat.windupMillis / 1000)
					recover(actor)
				end
				recover(actor)
				local state = factory.expeditionStore.snapshot(actor).archipelago
				if state.completed[objective.id] then
					return
				end
			end
		end
		error("hunt objective not completed")
	end
	function api.rescueCargo(actor, finish)
		assert(api.onboarding(actor) == nil, "legitimate onboarding")
		local initialBalance = personal(actor).balance
		gather(actor, "branch", 3)
		gather(actor, "stone", 2)
		craft(actor, "starter-club", "station.workbench.t1")
		for id, item in personal(actor).inventory.bag.items do
			if item.catalogId == "starter-club" then
				api.spear = id
			end
		end
		assert(api.spear, "owned crafted club")
		assert(api.expedition(actor) == nil, "eligible expedition")
		refused(actor, "mission-action", { "next-island", "none" }, "mission_gate")
		assert(api.gather(actor) == nil, "stage one gather")
		assert(api.survey(actor) == nil, "stage one survey")
		mission(actor, "next-island")
		reloadStage(actor)
		engine.move(actor, anchor("objective"))
		refused(actor, "mission-action", { "rescue-treat", world.layout.id }, "BANDAGE_REQUIRED")
		local origin, offset = anchor("objective"), Content.missionPolicy.bandageOffset
		engine.move(actor, { x = origin.x + offset.x, y = origin.y + offset.y, z = origin.z + offset.z })
		mission(actor, "bandage-claim")
		refused(actor, "mission-action", { "bandage-claim", world.layout.id }, "already_claimed")
		engine.move(actor, origin)
		mission(actor, "rescue-treat")
		local state = factory.expeditionStore.snapshot(actor).archipelago
		assert(
			state.treated and state.bandage == 0 and not state.completed["rw.a1.s2.rescue"],
			"treatment consumes reserve, not completion"
		)
		engine.move(actor, anchor("entry"))
		ctx.clock.advanceTo(ctx.clock.now() + 10)
		recover(actor)
		state = factory.expeditionStore.snapshot(actor).archipelago
		assert(state.escort.position.x == origin.x, "escort stops beyond 24")
		reloadStage(actor)
		state = factory.expeditionStore.snapshot(actor).archipelago
		assert(
			state.treated and (not state.escort or state.escort.position.x == origin.x),
			"disconnect retains treatment and resets NPC"
		)
		local destination = anchor("entry")
		local dx, dy, dz = destination.x - origin.x, destination.y - origin.y, destination.z - origin.z
		local length = math.sqrt(dx ^ 2 + dy ^ 2 + dz ^ 2)
		engine.move(actor, origin)
		recover(actor)
		local steps = math.ceil(length / Content.missionPolicy.followStuds)
		for index = 1, steps do
			local alpha = index / steps
			engine.move(actor, { x = origin.x + dx * alpha, y = origin.y + dy * alpha, z = origin.z + dz * alpha })
			ctx.clock.advanceTo(ctx.clock.now() + 1)
			recover(actor)
		end
		assert(factory.expeditionStore.snapshot(actor).archipelago.completed["rw.a1.s2.rescue"], "escort arrival")
		-- The real hand recipe consumes bag branch and runs at the rendered campfire.
		craft(actor, "dry-twig", "station.campfire.t1")
		mission(actor, "next-island")
		reloadStage(actor)
		engine.move(actor, anchor("objective"))
		refused(actor, "mission-action", { "cargo-deliver", world.layout.id }, "COMPLETE_CARGO_REQUIRED")
		engine.move(actor, anchor("resources"))
		mission(actor, "cargo-claim")
		refused(actor, "mission-action", { "cargo-claim", world.layout.id }, "MISSION_SLOT_FULL")
		state = factory.expeditionStore.snapshot(actor).archipelago
		assert(state.questCargo.slots == 1 and state.questCargo.quantity == 5, "separate complete bundle")
		engine.move(actor, anchor("objective"))
		mission(actor, "cargo-deliver")
		assert(factory.expeditionStore.snapshot(actor).archipelago.questCargo == nil, "cargo consumed")
		refused(actor, "mission-action", { "cargo-deliver", world.layout.id }, "objective_mismatch")
		if not finish then
			return nil
		end
		hunt(actor)
		mission(actor, "next-island")
		reloadStage(actor)
		assert(api.survey(actor) == nil, "last survey")
		hunt(actor)
		mission(actor, "next-island")
		recover(actor)
		local document = factory.expeditionStore.snapshot(actor)
		assert(
			document.archipelago.status == "complete" and document.development.instabilityAccess == 2,
			"four island clear"
		)
		local expected, actual = 0, 0
		for _, entry in document.missionRewards do
			expected += entry.rewards.coins
			assert(entry.settled, "all outbox rewards acknowledged")
			actual += 1
		end
		assert(
			actual == 8 and personal(actor).balance == initialBalance + expected,
			"eight catalog objective settlements: "
				.. tostring(actual)
				.. ":"
				.. tostring(personal(actor).balance)
				.. ":"
				.. tostring(initialBalance + expected)
		)
		local beforeBalance = personal(actor).balance
		local beforeProgression = require("../../../../core/domain/command/Journal").hash(personal(actor).progression)
		recover(actor)
		assert(api.enter("home", actor) == nil, "reward reconnect")
		recover(actor)
		assert(personal(actor).balance == beforeBalance, "no reconnect coin award")
		assert(
			require("../../../../core/domain/command/Journal").hash(personal(actor).progression) == beforeProgression,
			"no reconnect XP award"
		)
		return nil
	end
	function api.onboarding(actor)
		local refusal = api.expedition(actor)
		if refusal ~= "level_gate" then
			return "fresh_entry_gate_missing"
		end
		gather(actor, "branch", 4)
		gather(actor, "stone", 2)
		gather(actor, "fiber", 1)
		craft(actor, "campfire-kit", nil)
		craft(actor, "dry-twig", "station.campfire.t1")
		craft(actor, "starter-axe", "station.workbench.t1")
		for id, item in personal(actor).inventory.bag.items do
			if item.catalogId == "starter-axe" then
				api.axe = id
			end
		end
		assert(api.axe, "starter axe was not crafted")
		engine.equip(world, actor, api.axe)
		local wood
		for _, node in world.roleSource.nodes do
			if node.id == "rw.home.extra-0" then
				wood = node
			end
		end
		engine.move(actor, wood.position)
		for _ = 1, 2 do
			command(actor, "gather", { wood.id, factory.services.survivalGathering.snapshot(actor).version })
			assert(factory.services.survivalGathering.recover(actor, 8).status == "confirmed", "wood recovery")
		end
		engine.move(actor, source.tribe.warehousePosition)
		for id, item in personal(actor).inventory.bag.items do
			if item.catalogId == "wood" then
				command(actor, "transfer-deposit", { id, item.quantity })
			end
		end
		assert(session.recoverTransfers(actor, 8).ok, "deposit recovery")
		engine.move(actor, { x = 2, y = 2, z = -14 })
		local shared = session.snapshot(actor).survivalSettlement
		local reservation = command(actor, "settlement-reserve", {
			"campfire",
			8,
			1,
			0,
			shared.settlement.version,
			shared.warehouse.version,
			shared.settlement.membershipRevision,
		})
		shared = session.snapshot(actor).survivalSettlement
		command(
			actor,
			"settlement-place",
			{ reservation.data.reservationId, shared.settlement.version, shared.warehouse.version }
		)
		engine.move(actor, { x = -12, y = 2, z = -16 })
		command(actor, "rest", { "station.campfire.t1" })
		local development = factory.expeditionStore.snapshot(actor).development
		if development.points < 200 or personal(actor).progression.level < 2 then
			return "onboarding_progress_missing"
		end
		return nil
	end
	function api.gather(actor)
		engine.equip(world, actor, api.axe)
		local node = world.roleSource.nodes[1]
		for _, candidate in world.roleSource.nodes do
			if candidate.id == "rw.a1.s1.material.wood" then
				node = candidate
			end
		end
		engine.move(actor, node.position)
		for index = 1, 5 do
			local action = "survival-coop:gather"
			local epoch = session.commandEpoch(actor, action)
			local snapshot = factory.services.survivalGathering.snapshot(actor)
			local result = session.command(actor, {
				requestId = "world-gather-" .. tostring(index),
				sessionEpoch = epoch,
				action = action,
				args = { node.id, snapshot.version },
			})
			if not result.ok and (not result.data or result.data.status ~= "pending") then
				return result.reason or "gather_failed"
			end
			local settled = factory.services.survivalGathering.recover(actor, 8)
			if settled.status ~= "confirmed" then
				return settled.error or "gather_not_finalized"
			end
		end
		return nil
	end
	function api.survey(actor)
		local ids = {}
		for id in world.surveyMarkers do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			local marker = world.surveyMarkers[id]
			engine.move(actor, marker.position)
			local result = command(actor, "mission-action", { "survey-start", id })
			if not result.ok then
				return result.reason
			end
			ctx.clock.advanceTo(ctx.clock.now() + Content.missionPolicy.surveySeconds)
			assert(session.recoverTransfers(actor, 64).ok, "survey recovery")
		end
		return nil
	end
	function api.returnReload(actor)
		local expedition = factory.expeditionStore.snapshot(actor).archipelago
		if not expedition.completed["rw.a1.s1.gather"] or not expedition.completed["rw.a1.s1.survey"] then
			return "objectives_not_persisted"
		end
		local before =
			Data.clone(session.personalTransfer(actor).profile().data.envelope.genres["survival-coop"].data.inventory)
		local home = factory.homeOwner().snapshot(actor)
		local result = session.prepareHandoff(actor)
		if not result.ok then
			return result.reason
		end
		local resumed = session.resumeHandoff(actor)
		if not resumed.ok then
			return resumed.reason
		end
		local reason = api.enter("home", actor)
		if reason then
			return reason
		end
		local after = session.personalTransfer(actor).profile().data.envelope.genres["survival-coop"].data.inventory
		local Journal = require("../../../../core/domain/command/Journal")
		if Journal.hash(before) ~= Journal.hash(after) then
			return "inventory_changed"
		end
		local loaded = factory.homeOwner().snapshot(actor)
		if loaded.homeId ~= home.homeId or loaded.landRank ~= home.landRank then
			return "home_changed"
		end
		return nil
	end
	api.close = close
	api.snapshot = function()
		return { actor = actorId, layout = if world then world.layout.id else nil, sequence = sequence }
	end
	-- A production session is constructed by the first world operation, not a fixture profile.
	api.session = {
		join = function(actor)
			return { ok = api.enter("home", actor) == nil }
		end,
	}
	return api
end
return M
