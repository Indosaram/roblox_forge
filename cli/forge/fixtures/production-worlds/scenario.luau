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
	world_gather = function(ctx, step): string?
		return ctx.fixture.gather(actorOf(ctx, step))
	end,
	world_survey = function(ctx, step): string?
		return ctx.fixture.survey(actorOf(ctx, step))
	end,
	world_return_reload = function(ctx, step): string?
		return ctx.fixture.returnReload(actorOf(ctx, step))
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
		services.roll = function() return 0 end
		services.emit = function() end
		services.encode = function(value) return require("@lune/serde").encode("json", value) end
		session = Session.new({
			packConfig = require("../../../../games/robango-island/src/shared/GenreConfig"),
			contracts = { require("../../../../genres/survival-coop/module/Contract") },
			durable = require("../../../../games/robango-island/src/shared/GenreDurable"),
			controls = {},
			storeName = "worlds-personal",
		}, ctx.backend, {sessionId = options.sessionId, lockTimeout = 120, retries = 0, now = ctx.now}, services,
			require("../../../../games/robango-island/src/shared/GenreDurable"))
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
		create(role, actor)
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
	function api.gather(actor)
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
			local result = session.commandServer(actor, {
				requestId = "world-gather-" .. tostring(index),
				sessionEpoch = epoch,
				action = action,
				args = { node.id, snapshot.nodes[node.id].version },
			})
			if not result.ok then
				return result.reason
			end
		end
		return nil
	end
	function api.survey(actor)
		for id, marker in world.surveyMarkers do
			engine.move(actor, marker.position)
			local result = factory.archipelago.survey(actor, marker.objective, id)
			if not result.ok then
				return result.reason
			end
		end
		return nil
	end
	function api.returnReload(actor)
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
		local serde = require("@lune/serde")
		if serde.encode("json", before) ~= serde.encode("json", after) then
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
