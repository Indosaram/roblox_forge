--!strict
-- Composition only. Session owns personal persistence and all recovery scheduling.
local Services = require("./SurvivalServices")
local Runtime = require("./GatheringRuntime")
local Bridge = require("./GatheringBridge")
local Gathering = require("./Gathering")
local Wildlife = require("./Wildlife")
local WildlifeRuntime = require("./WildlifeRuntime")
local WildlifeBridge = require("./WildlifeBridge")
local Session = require("../../../core/infra/genre/Session")
local Options = require("../../../core/infra/genre/Options")
local Shared = require("../../../core/domain/genre/Contract")
local Content = require("../../../core/domain/survival/Content")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Fenced = require("../../../core/infra/data/FencedStore")
local ProfileStore = require("../../../core/infra/data/ProfileStore")
local EnvelopeBudget = require("../../../core/infra/data/EnvelopeBudget")
local Workshop = require("./Workshop")
local Events = require("../../../core/infra/analytics/Events")
local Extensions = require("./Extensions")
local M = {}
export type World = {
	services: Options.Services,
	bind: (Session.Session) -> (),
	destroy: () -> (),
	publishNodes: ((Gathering.State) -> ())?,
	wildlifeAccess: ((string, string) -> Wildlife.Access?)?,
	publishWildlife: (({ [string]: Wildlife.State }) -> ())?,
	publishCapacityLimits: ((any) -> ())?,
	gatheringAccess: (
		(Session.Session, Runtime.Request, Inventory.State) -> boolean
	) -> (Runtime.Request, Inventory.State, Fenced.Data) -> Gathering.Access?,
}
export type Config = {
	settlements: Services.Config,
	sourceKey: string,
	initial: Gathering.State,
	content: Content.Document,
	now: () -> number,
	nowMillis: () -> number,
	-- Optional core analytics emitter shared by the gathering source and every
	-- tribe settlement owner (gather/build/craft events).
	analytics: Events.Emitter?,
	-- Extension factories to build; defaults to the genre registry (module/Extensions).
	extensions: { Extensions.Factory }?,
	-- Pack policies handed to extension factories (ctx.policies), keyed by extension id.
	policies: { [string]: any }?,
	wildlife: {
		key: string,
		catalog: Wildlife.Catalog,
		initial: { [string]: Wildlife.State },
		carriedContainer: string,
		maxReceipts: number,
	}?,
}
function M.new(
	config: Config,
	world: World,
	backend: ProfileStore.Backend,
	options: Fenced.Options
): (Services.Factory?, string?)
	assert(options.budget, "SOURCE_BYTE_BUDGET_REQUIRED")
	if config.wildlife then
		assert(world.wildlifeAccess and world.publishWildlife, "WILDLIFE_WORLD_REQUIRED")
		assert(config.wildlife.key ~= config.sourceKey, "WILDLIFE_SOURCE_COLLISION")
		for _, tribe in config.settlements.tribes do
			assert(tribe.key ~= config.wildlife.key, "WILDLIFE_TRIBE_COLLISION")
		end
	end
	local settings = table.clone(config.settlements)
	settings.tribes = {}
	for _, original in config.settlements.tribes do
		assert(original.key ~= config.sourceKey, "SOURCE_TRIBE_KEY_COLLISION")
		local entry = table.clone(original)
		if entry.analytics == nil then
			entry.analytics = config.analytics
		end
		if original.workshop then
			local workshop = table.clone(original.workshop)
			workshop.verifyStation = function(actor, id, state)
				local spatial = world.services.survivalSpatial
				local station = if spatial then spatial.station(actor, id) else nil
				if not station or not station.reachable then
					return nil
				end
				return {
					carriedContainer = state.warehouse.id,
					stationId = id,
					stationKind = station.kind,
					inReach = true,
				}
			end
			entry.workshop = workshop
		end
		table.insert(settings.tribes, entry)
	end
	local settlement, openError = Services.new(settings, backend, options)
	if not settlement then
		return nil, openError
	end
	local active: Session.Session? = nil
	local closed = false
	local closing = false
	local joining: { [string]: boolean } = {}
	local admitted: { [string]: Shared.CommandContext } = {}
	local access = world.gatheringAccess(function(session, request)
		local current = admitted[request.actorId]
		return session == active
			and current ~= nil
			and current.actorId == request.actorId
			and current.sessionEpoch == request.sessionEpoch
			and current.requestId == request.requestId
	end)
	-- Release needs identity/generation, not a stale data snapshot. Fenced.release
	-- applies an identity transform to the current persisted record.
	local sourceToken: Fenced.Profile? = nil
	local store = Fenced.new({
		update = function(key, transform)
			local ok, record = backend.update(key, transform)
			if not sourceToken and ok and record and record.lease and record.lease.sessionId == options.sessionId then
				sourceToken =
					{ key = key, sessionId = options.sessionId, generation = record.generation, data = record.data }
			end
			return ok, record
		end,
	}, options)
	local source, sourceError = Runtime.new({
		key = config.sourceKey,
		initial = config.initial,
		content = config.content,
		now = config.now,
		nowMillis = config.nowMillis,
		maxReceipts = settings.maxReceipts,
		analytics = config.analytics,
		resolvePersonal = function(actor)
			local session = active
			local port = if session and not closed then session.personalTransfer(actor) else nil
			assert(not port or port.profile().key ~= config.sourceKey, "SOURCE_PERSONAL_KEY_COLLISION")
			return port
		end,
		access = access,
	}, store)
	if not source then
		if sourceToken then
			store:release(sourceToken)
		end
		settlement.close()
		return nil, sourceError
	end
	local function publish()
		local callback = world.publishNodes
		if callback then
			local confirmed = source.snapshot()
			if confirmed then
				callback(confirmed.nodes)
			end
		end
	end
	local bridge = Bridge.new({
		resolve = function()
			return if active and not closed then source else nil
		end,
	})
	local gathering = table.clone(bridge)
	gathering.command = function(actor, args, context, expiresAt, admit)
		-- The Session callback is the actual origin/contract admission. Capture it
		-- inside the shared source lock; never ask commandEpoch while Session is busy.
		local ok, result = pcall(bridge.command, actor, args, context, expiresAt, function()
			local admission = admit()
			if admission.ok then
				admitted[actor] = context
			end
			return admission
		end)
		admitted[actor] = nil
		if not ok then
			error(result)
		end
		if result.ok then
			publish()
		end
		return result
	end
	gathering.recover = function(actor, maximum)
		local result = bridge.recover(actor, maximum)
		if result.status == "confirmed" then
			publish()
		end
		return result
	end
	local services = table.clone(world.services)
	services.survivalSettlement = settlement.services.survivalSettlement
	services.survivalTransfer = settlement.services.survivalTransfer
	services.survivalGathering = gathering
	local wildlifeOwner: WildlifeRuntime.Runtime? = nil
	local wildlifeToken: Fenced.Profile? = nil
	local wildlifeStore: Fenced.Store? = nil
	if config.wildlife then
		local policy = config.wildlife
		local ownerStore = Fenced.new({
			update = function(key, transform)
				local ok, record = backend.update(key, transform)
				if
					not wildlifeToken
					and ok
					and record
					and record.lease
					and record.lease.sessionId == options.sessionId
				then
					wildlifeToken =
						{ key = key, sessionId = options.sessionId, generation = record.generation, data = record.data }
				end
				return ok, record
			end,
		}, options)
		wildlifeStore = ownerStore
		local owner, err = WildlifeRuntime.new({
			key = policy.key,
			catalog = policy.catalog,
			initial = policy.initial,
			content = config.content,
			carriedContainer = policy.carriedContainer,
			maxReceipts = policy.maxReceipts,
			now = config.now,
			nowMillis = config.nowMillis,
			resolvePersonal = function(actor)
				return if active and not closed then active.personalTransfer(actor) else nil
			end,
			access = function(actor, target)
				if not active or closed or not table.find(active.members(), actor) then
					return nil
				end
				return (world.wildlifeAccess :: (string, string) -> Wildlife.Access?)(actor, target)
			end,
		}, ownerStore)
		if not owner then
			if wildlifeToken then
				ownerStore:release(wildlifeToken)
			end
			if sourceToken then
				store:release(sourceToken)
			end
			settlement.close()
			return nil, err
		end
		wildlifeOwner = owner
		local wildlifeBridge = WildlifeBridge.new({
			resolve = function()
				return if active and not closed then owner else nil
			end,
		})
		local function publishWildlife()
			local confirmed = owner.snapshot()
			if confirmed then
				(world.publishWildlife :: ({ [string]: Wildlife.State }) -> ())(confirmed)
			end
		end
		local command, recover = wildlifeBridge.command, wildlifeBridge.recover
		wildlifeBridge.command = function(...)
			local result = command(...)
			publishWildlife()
			return result
		end
		wildlifeBridge.recover = function(...)
			local result = recover(...)
			publishWildlife()
			return result
		end
		services.survivalWildlife = wildlifeBridge
		local previousPublish = publish
		publish = function()
			previousPublish()
			publishWildlife()
		end
	end
	local extensionClosers: { () -> Shared.Result } = {}
	local built: { Shared.Extension } = {}
	local extensionContext: Extensions.Context = {
		content = config.content,
		store = function()
			return Fenced.new(backend, options)
		end,
		backend = backend,
		options = options,
		now = config.now,
		nowMillis = config.nowMillis,
		world = world,
		members = function()
			return if active and not closed then active.members() else {}
		end,
		personalTransfer = function(actor)
			return if active and not closed then active.personalTransfer(actor) else nil
		end,
		wildlife = function(id)
			local owner = wildlifeOwner
			local states = if owner and not closed then owner.snapshot() else nil
			local state = if states then states[id] else nil
			return if state then { catalogId = state.catalogId, healthMilli = state.healthMilli } else nil
		end,
		policies = config.policies,
	}
	for _, factory in config.extensions or Extensions.factories do
		local extension = factory(extensionContext)
		if extension then
			if extension.close then
				table.insert(extensionClosers, extension.close)
			end
			local port: any = table.clone(extension)
			port.close = nil
			table.insert(built, port)
		end
	end
	if #built > 0 then
		services.survivalExtensions = built
	end
	local api = { services = services }
	function api.bind(session: Session.Session)
		assert(not closed and active == nil and #session.members() == 0, "BIND_BEFORE_JOIN")
		local join = session.join
		session.join = function(actor)
			if closed or closing then
				return { ok = false, reason = "BOOTSTRAP_CLOSED" }
			end
			local members = session.members()
			local count = #members
			for id in joining do
				if not table.find(members, id) then
					count += 1
				end
			end
			if joining[actor] or (not table.find(members, actor) and count >= settings.maxServerPlayers) then
				return { ok = false, reason = "SERVER_PLAYER_LIMIT" }
			end
			joining[actor] = true
			local ok, result = pcall(join, actor)
			joining[actor] = nil
			if not ok then
				error(result)
			end
			return result
		end
		active = session
		settlement.bind(session)
		world.bind(session)
		if world.publishCapacityLimits then
			world.publishCapacityLimits({
				payloadBytes = assert(options.budget).maxBytes or EnvelopeBudget.DEFAULT_MAX_BYTES,
				receipts = settings.maxReceipts,
				jobs = Workshop.MAX_RETAINED,
				admission = settings.maxServerPlayers,
				wildlifeReceipts = if config.wildlife then config.wildlife.maxReceipts else nil,
			})
		end
		publish()
	end
	function api.close(): Shared.Result
		if next(joining) or (active and #active.members() > 0) then
			return { ok = false, reason = "PLAYERS_ACTIVE" }
		end
		closing = true
		for index = #extensionClosers, 1, -1 do
			local released = extensionClosers[index]()
			if not released.ok then
				return released
			end
			table.remove(extensionClosers, index)
		end
		if wildlifeToken and wildlifeStore then
			local released, err = wildlifeStore:release(wildlifeToken)
			if not released then
				return { ok = false, reason = err }
			end
			wildlifeToken = nil
		end
		if sourceToken then
			local released, err = store:release(sourceToken)
			if not released then
				return { ok = false, reason = err }
			end
			sourceToken = nil
		end
		local result = settlement.close()
		if not result.ok then
			return result
		end
		if not closed then
			world.destroy()
		end
		closed = true
		return { ok = true }
	end
	return api, nil
end
return M
