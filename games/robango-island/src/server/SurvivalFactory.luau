--!strict
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local Bootstrap = require(Forge.genres["survival-coop"].module.SurvivalBootstrap)
local Gathering = require(Forge.genres["survival-coop"].module.Gathering)
local Settlement = require(Forge.core.domain.settlement.Settlement)
local Inventory = require(Forge.core.domain.inventory.Inventory)
local Job = require(Forge.core.domain.crafting.Job)
local Clock = require(Forge.core.infra.genre.Clock)
local Wildlife = require(Forge.genres["survival-coop"].module.Wildlife)
local HomeExtension = require(Forge.genres["survival-coop"].module.HomeExtension)
local Extensions = require(Forge.genres["survival-coop"].module.Extensions)
local ActorDocuments = require(Forge.core.infra.data.ActorDocumentStore)
local ArchipelagoExtension = require(Forge.genres["survival-coop"].module.ArchipelagoExtension)
local Archipelago = require(Forge.core.domain.island.Archipelago)
return function(content: any, source, world, backend, clock, options, provision, wildlifePolicy): (any, string?)
	-- BEGIN production role projection. Geometry and durable gathering share one layout.
	content, source, wildlifePolicy =
		world.roleContent or content, world.roleSource or source, world.roleWildlife or wildlifePolicy
	-- END production role projection.
	-- The rendered module also carries capability metadata, not domain content.
	content = table.clone(content)
	content.capability = nil
	require(script.Parent.LateEquipmentPorts).bind(world)
	local definitions = {}
	for _, definition in content.structures do
		definitions[definition.id] = {
			id = definition.id,
			footprintX = definition.footprintX,
			footprintZ = definition.footprintZ,
			cost = definition.cost,
		}
	end
	local function seconds()
		return math.floor(clock.now())
	end
	local tribe = source.tribe
	local origin = tribe.origin
	local warehouse = tribe.warehousePosition
	local ports = world.settlementPorts(
		Vector3.new(origin.x, origin.y, origin.z),
		Vector3.new(warehouse.x, warehouse.y, warehouse.z)
	)
	-- The provision may scope the tribe identity (a per-server camp); the grid policy is unchanged.
	local tribeConfig: Settlement.Config = {
		tribeId = tribe.config.tribeId,
		width = tribe.config.width,
		depth = tribe.config.depth,
		cellStuds = tribe.config.cellStuds,
		maxMembers = tribe.config.maxMembers,
	}
	if content.version == 2 then
		tribeConfig.contentVersion = 2
	end
	tribeConfig.tribeId = provision.tribeId or tribeConfig.tribeId
	-- Last confirmed settlement, recorded from the runtime's post-commit publication.
	local confirmed: any = nil
	local function publish(state)
		confirmed = state
		ports.publish(state)
	end
	local prefix = (source.persistencePrefix :: string) .. ":" .. (provision.id :: string)
	local wildlifeConfig = nil
	if wildlifePolicy then
		assert(wildlifePolicy.version == 1, "WILDLIFE_POLICY_VERSION")
		local catalog = Wildlife.catalog(content, wildlifePolicy.catalog)
		local initial: { [string]: Wildlife.State } = {}
		for _, spawn in wildlifePolicy.spawns do
			assert(not initial[spawn.id], "DUPLICATE_WILDLIFE_SPAWN")
			initial[spawn.id] = Wildlife.new(spawn.id, spawn.catalogId, spawn.position, catalog)
		end
		wildlifeConfig = {
			key = prefix .. ":" .. wildlifePolicy.sourceKey,
			catalog = catalog,
			initial = initial,
			carriedContainer = "bag",
			maxReceipts = wildlifePolicy.maxReceipts,
		}
	end
	local extensionFactories = table.clone(Extensions.factories)
	local expeditionStore = ActorDocuments.new(backend, options, "robango-exp-v1")
	local activeSession: any = nil
	local gatherReceipt: any = nil
	-- BEGIN authoritative home owner. Personal profile and server spatial ports supply facts.
	local HomeContent = require(Forge.core.domain.home.HomeContent)
	local homeOwner: any = nil
	local function personalData(actor)
		local port = if activeSession then activeSession.personalTransfer(actor) else nil
		return if port then port.profile().data.envelope.genres["survival-coop"].data else nil
	end
	local function developmentFacts(document: any): any
		local points = if document and document.development then document.development.points else 0
		local rank = 1
		for _, tier in if content.homePolicy then content.homePolicy.tiers else {} do
			if points >= tier.development then
				rank = tier.rank
			end
		end
		return { homeRank = rank, grade = math.min(10, math.floor(points / 100)), points = points }
	end
	if content.homePolicy then
		local rules = HomeContent.rules(content)
		local published: any = {}
		local structures = {}
		for _, definition in content.structures do
			local kit = definition.id .. "-kit"
			for _, item in content.items do
				if item.id == kit then
					structures[definition.id] =
						{ kit = kit, halfSize = math.max(definition.footprintX, definition.footprintZ) * 2, rank = 1 }
				end
			end
		end
		world.home = {
			rules = rules,
			structures = structures,
			seed = function(actor)
				local seed = 0
				for i = 1, #actor do
					seed = (seed * 31 + string.byte(actor, i)) % 2147483647
				end
				return seed
			end,
			ownerOf = function(actor, token)
				return if token == "home:" .. actor then actor else nil
			end,
			facts = function(actor, owner, operation, body)
				local data = personalData(owner)
				local development = developmentFacts(expeditionStore.snapshot(owner))
				local spatial = world.services.survivalDeath
				local position = if spatial then spatial.position(actor) else nil
				local state = published[owner]
				local half = rules.landSizes[if state then state.landRank else 1] / 2
				local target = if operation == "place"
					then body.position
					else if state and body then (state.structures[body.id or body.plot] or {}).position else nil
				local inReach = target == nil or (spatial ~= nil and spatial.reachable(actor, target))
				return {
					reachable = inReach
						and position ~= nil
						and world.layout ~= nil
						and world.layout.id == "rw.home"
						and math.abs(position.x) <= half
						and math.abs(position.z) <= half,
					atDock = spatial ~= nil and spatial.reachable(actor, rules.dock),
					ownerOnline = actor == owner,
					developmentRank = development.homeRank,
					nodes = if data and data.progression then data.progression.nodes or {} else {},
					entitlements = {},
				}
			end,
			publish = function(_owner, state)
				published[_owner] = state
				if world.publishHome then
					world.publishHome(state, rules)
				end
			end,
		}
	end
	-- END authoritative home owner.
	local function expeditionFacts(actor, document: any?)
		local port = if activeSession then activeSession.personalTransfer(actor) else nil
		local envelope = if port then port.profile().data.envelope else nil
		local data = envelope and envelope.genres["survival-coop"].data
		local development = if document then document.development else nil
		return {
			level = if data and data.progression then data.progression.level else 1,
			developmentRank = developmentFacts(document).grade,
			instabilityAccess = if development then development.instabilityAccess else 1,
		}
	end
	local archipelago = ArchipelagoExtension.new({
		content = content,
		entryBuffer = source.archipelago.entryBufferSeconds,
		now = seconds,
		store = expeditionStore,
		facts = expeditionFacts,
		verify = function(actor, operationId)
			return if provision.archipelagoReceipt then provision.archipelagoReceipt(actor, operationId) else nil
		end,
		gatherReceipt = function(actor, epoch, requestId)
			return if gatherReceipt then gatherReceipt(actor, epoch, requestId) else nil
		end,
		-- BEGIN finalized spatial survey receipts. Identity derives from server markers.
		surveyReceipt = function(actor, state, objectiveId, markerId): any
			local marker = if world.surveyMarkers then world.surveyMarkers[markerId] else nil
			if not marker or marker.objective ~= objectiveId or marker.layout ~= Archipelago.layout(state) then
				return nil
			end
			if not world.services.survivalDeath.reachable(actor, marker.position) then
				return nil
			end
			return {
				id = state.id .. ":survey:" .. markerId,
				actor = actor,
				expedition = state.id,
				revision = state.revision,
				objective = objectiveId,
				action = "survey",
				target = objectiveId,
				quantity = 1,
			}
		end,
		-- END finalized spatial survey receipts.
		returnHome = function(actor)
			return if provision.returnHome
				then provision.returnHome(actor)
				else { ok = false, reason = "HOME_ROUTE_UNAVAILABLE" }
		end,
	})
	table.insert(extensionFactories, function()
		return require(Forge.core.infra.genre.Session).registerLifecycle({
			id = "archipelago",
			handles = function()
				return false
			end,
			command = function()
				return { ok = false, reason = "SERVER_ONLY" }
			end,
			snapshot = function(actor)
				local document, reason = expeditionStore.snapshot(actor)
				return if document then document.archipelago else nil, reason
			end,
			drain = expeditionStore.drain,
			releaseActor = expeditionStore.releaseActor,
			resumeActor = expeditionStore.resumeActor,
			close = expeditionStore.close,
		})
	end)
	if world.home then
		table.insert(extensionFactories, function(ctx)
			local config = table.clone(world.home)
			config.content, config.store, config.now = ctx.content, ctx.store, ctx.now
			homeOwner = HomeExtension.new(config)
			return homeOwner
		end)
	end
	local factory, err = Bootstrap.new({
		sourceKey = prefix .. ":" .. source.sourceKey,
		initial = Gathering.new(source.worldRevision, content, source.nodes),
		content = content,
		extensions = extensionFactories,
		now = seconds,
		nowMillis = function()
			return Clock.millis(clock.now())
		end,
		wildlife = wildlifeConfig,
		settlements = {
			maxServerPlayers = 8,
			maxPlots = 1,
			maxReceipts = 4096,
			tribeFor = provision.tribeFor,
			authorize = provision.authorize,
			consent = provision.consent,
			proof = provision.proof,
			tribes = {
				{
					key = prefix .. ":" .. tribe.key,
					now = seconds,
					catalog = Job.catalog(content),
					definitions = definitions,
					acceptedMembers = provision.acceptedMembers,
					verifyPlacement = ports.verify,
					publish = publish,
					initial = {
						settlement = Settlement.new(tribeConfig, provision.ownerId),
						warehouse = Inventory.new(
							tribe.warehouseId,
							{ slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 }
						),
					},
					verifyTransfer = function(actor, proof)
						if provision.verifyTransfer(actor, proof) and ports.warehouse(actor) then
							return true
						end
						return false
					end,
					workshop = {
						content = content,
						revision = tribe.workshopRevision,
						verifyStation = function(actor, id, state)
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
						end,
					},
				},
			},
		},
	}, world, backend, options)
	if not factory then
		return factory, err
	end
	local factoryPorts: any = factory
	factoryPorts.homeOwner = function()
		return homeOwner
	end
	factoryPorts.archipelago = archipelago
	local roleWorld: any = world
	roleWorld.surveyObjective = archipelago.survey
	factoryPorts.expeditionStore = expeditionStore
	factoryPorts.gatherReceipt = function(actor, epoch, requestId)
		local port = factory.services.survivalGathering
		return if port and port.receipt then port.receipt(actor, epoch, requestId) else nil
	end
	gatherReceipt = factoryPorts.gatherReceipt
	local gatheringPort = factory.services.survivalGathering
	if gatheringPort then
		local command = gatheringPort.command
		gatheringPort.command = function(actor, args, context, expiresAt, admit)
			local result = command(actor, args, context, expiresAt, admit)
			if result.ok then
				local credited = archipelago.gatherObjective(actor, context.sessionEpoch, context.requestId)
				if
					not credited.ok
					and credited.reason ~= "missing_expedition"
					and credited.reason ~= "objective_mismatch"
					and credited.reason ~= "receipt_scope"
					and credited.reason ~= "duplicate_receipt"
				then
					local noted = table.clone(result)
					noted.data = table.clone(result.data or {})
					noted.data.objectiveError = credited.reason
					return noted
				end
			end
			return result
		end
	end
	factoryPorts.admitExpedition = function(actor)
		local document, reason = expeditionStore.snapshot(actor)
		if not document or not document.archipelago then
			return false, reason or "missing_expedition"
		end
		return Archipelago.admit(
			document.archipelago,
			content,
			expeditionFacts(actor, document),
			seconds(),
			source.archipelago.entryBufferSeconds
		)
	end
	local bindSession = factory.bind
	factory.bind = function(session)
		activeSession = session
		bindSession(session)
	end
	-- Session asks for a command epoch for every durable action on every state push. The runtime
	-- answers a non-member (a visitor, or anyone routed here without a seat) only after a durable
	-- read-modify-write that refuses and changes nothing, so idle visitors rewrote the camp record
	-- hundreds of times a minute. Refuse them from the last confirmed settlement instead, with the
	-- runtime's own membership rule; members and the owner-reclaim case still reach the runtime.
	local function seated(actor: string): boolean
		local state = confirmed
		return state == nil or state.roles[actor] ~= nil or (actor == state.ownerId and next(state.roles) == nil)
	end
	for _, name in { "survivalSettlement", "survivalTransfer" } do
		local service = (factory.services :: any)[name]
		local epoch = service.epoch
		service.epoch = function(actor, ...)
			if not seated(actor) then
				return nil, "FORBIDDEN"
			end
			return epoch(actor, ...)
		end
	end
	-- Extensions keep one lazily acquired lease token per record and are not re-entrant: while a
	-- slow durable call is in flight, the next per-frame snapshot (or a heartbeat, or a command) finds
	-- no token yet, or a token another caller is about to replace, and acquires again. Every acquire
	-- bumps the record generation and invalidates the other caller's token, so a slow transport turned
	-- an idle player into a re-acquire loop (live: contracts:-1 at generation 57 in about a minute).
	-- Each extension therefore runs one call at a time; concurrent snapshots of one actor coalesce
	-- onto a single queued read (per-frame readers must never pile up behind the transport), every
	-- other entry point waits its turn, and a nested call on the owning thread proceeds.
	local function serialized(extension: any): any
		local owner: thread? = nil
		local depth = 0
		local waiting: { thread } = {}
		local last: { [string]: any } = {}
		local function run(method: (...any) -> ...any, ...: any): ...any
			local me = coroutine.running()
			if owner ~= nil and owner ~= me then
				table.insert(waiting, me)
				repeat
					coroutine.yield()
				until owner == me
			end
			owner, depth = me, depth + 1
			local results = table.pack(pcall(method, ...))
			depth -= 1
			if depth == 0 then
				-- Hand ownership straight to the next live waiter so no newcomer can slip in between.
				local nextThread = table.remove(waiting, 1)
				while nextThread and coroutine.status(nextThread) == "dead" do
					nextThread = table.remove(waiting, 1)
				end
				owner = nextThread
				if nextThread then
					task.defer(nextThread)
				end
			end
			if not results[1] then
				error(results[2], 0)
			end
			return table.unpack(results, 2, results.n)
		end
		local port = table.clone(extension)
		for _, name in { "command", "recover", "observe", "epoch" } do
			local method = extension[name]
			if method then
				port[name] = function(...)
					return run(method, ...)
				end
			end
		end
		local snapshot = extension.snapshot
		if snapshot then
			local reading: { [string]: boolean } = {}
			port.snapshot = function(actor: string, ...)
				-- Coalesce, never starve: while one snapshot of this actor is queued or running, the
				-- others serve its last result. One real read always gets through, and that read is
				-- what renews the record's lease.
				local cached = last[actor]
				if reading[actor] and owner ~= coroutine.running() then
					if cached then
						return table.unpack(cached, 1, cached.n)
					end
					return nil, "EXTENSION_BUSY"
				end
				reading[actor] = true
				local ok, results = pcall(function(...)
					return table.pack(run(snapshot, actor, ...))
				end, ...)
				reading[actor] = nil
				if not ok then
					error(results, 0)
				end
				last[actor] = results
				return table.unpack(results, 1, results.n)
			end
		end
		local Session = require(Forge.core.infra.genre.Session)
		local lifecycle = Session.lifecycle(extension)
		for _, name in { "drain", "releaseActor", "resumeActor" } do
			local method = (lifecycle :: any)[name]
			if method then
				port[name] = function(...)
					return run(method, ...)
				end
			end
		end
		return Session.registerLifecycle(port)
	end
	local extensions = (factory.services :: any).survivalExtensions
	for index, extension in extensions or {} do
		extensions[index] = serialized(extension)
	end
	if not provision.admit then
		return factory, err
	end
	-- Join admission: after a player's profile joins, the provision admits them to this server's
	-- camp through the server-origin settlement path (authorize + consent + domain owner check).
	local settlement = factory.services.survivalSettlement :: any
	local port = {
		state = function()
			return confirmed
		end,
		command = function(actor: string, action: string, args: { any }, requestId: string)
			local epoch, reason = settlement.epoch(actor, action)
			if epoch == nil then
				return { ok = false, reason = reason or "SETTLEMENT_UNAVAILABLE" }
			end
			return settlement.command(
				actor,
				action,
				args,
				{ actorId = actor, requestId = requestId, sessionEpoch = epoch },
				"server",
				nil
			)
		end,
	}
	-- Admissions run one at a time: the backend can yield, and concurrent joins must not race the
	-- owner's invite ledger or read the same settlement version.
	local admitting = false
	local waiting: { thread } = {}
	local function admit(actor: string): any
		if admitting then
			table.insert(waiting, coroutine.running())
			coroutine.yield()
		end
		admitting = true
		local ok, result = pcall(provision.admit, actor, port)
		local nextWaiter = table.remove(waiting, 1)
		if nextWaiter then
			task.defer(nextWaiter)
		else
			admitting = false
		end
		return if ok then result else { ok = false, reason = tostring(result) }
	end
	local bind = factory.bind
	factory.bind = function(session)
		bind(session)
		local join = session.join
		session.join = function(actor)
			local result = join(actor)
			if not result.ok then
				return result
			end
			local admitted = admit(actor)
			if admitted.ok then
				return result
			end
			-- The profile is loaded; only the camp seat failed. Report it, never kick the player.
			local noted = table.clone(result)
			local message = "SETTLEMENT_ADMISSION:" .. tostring(admitted.reason)
			noted.notificationError = if noted.notificationError
				then noted.notificationError .. "; " .. message
				else message
			return noted
		end
	end
	return factory, err
end
