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
	local monetization: any = nil
	local gatherReceipt: any = nil
	local wildlifeSnapshot: any = nil
	local commandReceipts: any = {}
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
		structures["farm-plot"] =
			{ kit = "practice-seedbed", halfSize = content.homePolicy.structureSize.x / 2, rank = 1 }
		world.home = {
			personal = function(actor)
				return if activeSession then activeSession.personalTransfer(actor) else nil
			end,
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
				local shop = if monetization then monetization.snapshot(owner) else nil
				local entitlements: { [string]: boolean } = if shop then table.clone(shop.passes) else {}
				if shop and shop.subscription.active then
					entitlements.routeGuildMonthly = true
				end
				return {
					reachable = inReach
						and position ~= nil
						and world.layout ~= nil
						and world.layout.id == "rw.home"
						and math.abs(position.x) <= half
						and math.abs(position.z) <= half,
					atDock = spatial ~= nil and spatial.reachable(actor, rules.dock),
					ownerOnline = personalData(owner) ~= nil,
					friend = if world.isFriend then world.isFriend(owner, actor) else false,
					developmentRank = development.homeRank,
					nodes = if data and data.progression then data.progression.paid or {} else {},
					entitlements = entitlements,
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
	-- BEGIN provision receipt resolver. The operation id resolves a binding that
	-- Session has already committed, never client-provided completion facts.
	provision.archipelagoReceipt = function(actor: string, operationId: string, current: any): any
		local binding = commandReceipts[actor .. ":" .. operationId]
		if
			not binding
			or not activeSession.committedReceipt(
				actor,
				binding.epoch,
				binding.requestId,
				binding.action,
				binding.args,
				binding.origin
			)
		then
			return nil
		end
		local document = current or expeditionStore.snapshot(actor)
		local state = if document then document.archipelago else nil
		if not state then
			return nil
		end
		for _, stage in content.stages do
			if stage.layout == Archipelago.layout(state) then
				for _, objective in stage.objectives do
					if objective.action == "craft" and objective.target == binding.target then
						return {
							id = "command:" .. operationId,
							actor = actor,
							expedition = state.id,
							revision = state.revision,
							objective = objective.id,
							action = "craft",
							target = binding.target,
							quantity = 1,
						}
					end
				end
			end
		end
		return nil
	end
	-- END provision receipt resolver.
	local archipelago = ArchipelagoExtension.new({
		content = content,
		entryBuffer = source.archipelago.entryBufferSeconds,
		now = seconds,
		store = expeditionStore,
		facts = expeditionFacts,
		position = function(actor)
			return world.services.survivalDeath.position(actor)
		end,
		personal = function(actor)
			return if activeSession then activeSession.personalTransfer(actor) else nil
		end,
		wildlife = function(actor)
			return if wildlifeSnapshot then wildlifeSnapshot(actor) else nil
		end,
		verify = function(actor, operationId, document)
			return if provision.archipelagoReceipt
				then provision.archipelagoReceipt(actor, operationId, document)
				else nil
		end,
		gatherReceipt = function(actor, epoch, requestId)
			return if gatherReceipt then gatherReceipt(actor, epoch, requestId) else nil
		end,
		returnHome = function(actor)
			return if provision.returnHome
				then provision.returnHome(actor)
				else { ok = false, reason = "HOME_ROUTE_UNAVAILABLE" }
		end,
	})
	table.insert(extensionFactories, function()
		return require(Forge.core.infra.genre.Session).registerLifecycle({
			id = "archipelago",
			handles = function(action)
				return action == "survival-coop:mission-action"
			end,
			command = function(actor, _action, args, context, _origin, admit)
				if context.actorId ~= actor then
					return { ok = false, reason = "FORBIDDEN" }
				end
				local allowed = admit()
				if not allowed.ok then
					return allowed
				end
				if args[1] == "next-island" then
					return archipelago.nextIsland(actor)
				elseif args[1] == "return" then
					return archipelago.recover(actor, "return")
				end
				return archipelago.mission(actor, args[1], args[2])
			end,
			recover = function(actor)
				local result = archipelago.tick(actor)
				if result.ok then
					result = archipelago.settleRewards(actor)
				end
				if world.publishEscort then
					local document = expeditionStore.snapshot(actor)
					world.publishEscort(actor, if document then document.archipelago else nil)
				end
				return {
					status = if result.ok then "confirmed" else "recovering",
					pending = if result.ok then 0 else 1,
					reason = result.reason,
				}
			end,
			snapshot = function(actor)
				local document, reason = expeditionStore.snapshot(actor)
				return if document then document.archipelago else nil, reason
			end,
			drain = expeditionStore.drain,
			releaseActor = function(actor)
				local reset = expeditionStore.transaction(actor, function(document)
					if document.archipelago then
						document.archipelago.escortAtStart = true
						document.archipelago.escort, document.archipelago.surveyHold = nil, nil
					end
					return { ok = true }
				end)
				return if reset.ok then expeditionStore.releaseActor(actor) else reset
			end,
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
	if factoryPorts.services.survivalWildlife then
		wildlifeSnapshot = factoryPorts.services.survivalWildlife.snapshot
	end
	for _, extension in factoryPorts.services.survivalExtensions or {} do
		if extension.id == "monetization" then
			monetization = extension
		end
	end
	factoryPorts.homeOwner = function()
		return homeOwner
	end
	factoryPorts.archipelago = archipelago
	local roleWorld: any = world
	factoryPorts.expeditionStore = expeditionStore
	-- BEGIN authored guide progress. Only trusted finalized event callers below
	-- can reach this port; clients cannot supply a completion or award amount.
	factoryPorts.recordDevelopment = function(actor, receiptId, event)
		return expeditionStore.transaction(actor, function(document)
			local development = document.development or { points = 0, definitions = {}, instabilityAccess = 1 }
			development.events = development.events or {}
			development.progress = development.progress or {}
			if development.events[receiptId] then
				return { ok = true }
			end
			development.events[receiptId] = true
			for _, guide in content.guides or {} do
				if
					(guide.gates.characterLevel or 1)
						<= ((personalData(actor) or {}).progression or { level = 1 }).level
					and (guide.gates.developmentRank or 0) <= developmentFacts(document).grade
					and not development.definitions[guide.id]
				then
					local complete = true
					for _, objective in guide.objectives do
						if objective.action == event.action and objective.target == event.target then
							development.progress[objective.id] =
								math.min(objective.quantity, (development.progress[objective.id] or 0) + event.quantity)
						end
						complete = complete and (development.progress[objective.id] or 0) >= objective.quantity
					end
					if complete then
						development.definitions[guide.id] = true
						development.points += guide.rewards.development or 0
					end
				end
			end
			document.development = development
			return { ok = true }
		end)
	end
	-- END authored guide progress.
	factoryPorts.gatherReceipt = function(actor, epoch, requestId)
		local port = factory.services.survivalGathering
		return if port and port.receipt then port.receipt(actor, epoch, requestId) else nil
	end
	gatherReceipt = factoryPorts.gatherReceipt
	local gatheringPort = factory.services.survivalGathering
	if gatheringPort then
		local awaiting: any = {}
		local function creditGather(actor, epoch, requestId)
			local grant = factoryPorts.gatherReceipt(actor, epoch, requestId)
			if not grant then
				return false
			end
			for item, quantity in grant.items do
				factoryPorts.recordDevelopment(
					actor,
					"g:" .. tostring(epoch) .. ":" .. requestId .. ":" .. item,
					{ action = "gather", target = item, quantity = quantity }
				)
			end
			local credited = archipelago.gatherObjective(actor, epoch, requestId)
			return credited.ok
				or credited.reason == "missing_expedition"
				or credited.reason == "objective_mismatch"
				or credited.reason == "receipt_scope"
				or credited.reason == "duplicate_receipt"
		end
		local recoverGather = gatheringPort.recover
		gatheringPort.recover = function(actor, maximum)
			local result = recoverGather(actor, maximum)
			for id, binding in awaiting[actor] or {} do
				if creditGather(actor, binding.epoch, binding.requestId) then
					awaiting[actor][id] = nil
				end
			end
			return result
		end
		local command = gatheringPort.command
		gatheringPort.command = function(actor, args, context, expiresAt, admit)
			local function resourceAdmission()
				local node: any = nil
				for _, candidate in source.resourceNodes or {} do
					if candidate.id == args[1] then
						node = candidate
					end
				end
				if node then
					local data = personalData(actor)
					local progression = if data then data.progression else nil
					if
						not progression
						or progression.level < (if node.gates then node.gates.characterLevel or 1 else 1)
					then
						return { ok = false, reason = "LEVEL_LOCKED" }
					end
					for _, skill in if node.gates then node.gates.skillNodes or {} else {} do
						if not progression.paid[skill] then
							return { ok = false, reason = "SKILL_LOCKED" }
						end
					end
					if node.tool then
						local equipped = world.services.survivalDeath.equipment(actor) or {}
						local found = false
						for id, item in data.inventory.bag.items do
							found = found
								or (equipped[id] == true and item.catalogId == node.tool and item.durabilityMilli > 0)
						end
						if not found then
							return { ok = false, reason = "TOOL_UNAVAILABLE" }
						end
					end
				end
				return admit()
			end
			local result = command(actor, args, context, expiresAt, resourceAdmission)
			if result.ok or (result.data and result.data.status == "pending") then
				awaiting[actor] = awaiting[actor] or {}
				awaiting[actor][tostring(context.sessionEpoch) .. ":" .. context.requestId] =
					{ epoch = context.sessionEpoch, requestId = context.requestId }
				local grant = factoryPorts.gatherReceipt(actor, context.sessionEpoch, context.requestId)
				if grant then
					for item, quantity in grant.items do
						factoryPorts.recordDevelopment(
							actor,
							"g:" .. tostring(context.sessionEpoch) .. ":" .. context.requestId .. ":" .. item,
							{ action = "gather", target = item, quantity = quantity }
						)
					end
				end
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
		local missionSequence = 0
		roleWorld.missionAction = function(actor, operation, target)
			missionSequence += 1
			local action = "survival-coop:mission-action"
			return session.command(actor, {
				requestId = "world-mission-" .. tostring(missionSequence),
				sessionEpoch = session.commandEpoch(actor, action),
				action = action,
				args = { operation, target },
			})
		end
		-- BEGIN finalized command development receipts. No request fact is credited
		-- until Session proves the exact durable binding succeeded.
		for _, method in { "command", "commandServer" } do
			local command = session[method]
			session[method] = function(actor, request)
				local data = personalData(actor)
				local action = string.gsub(request.action, "^survival%-coop:", "")
				local recipe: string? = nil
				if action == "craft-complete" and data and data.workshop then
					local entry = data.workshop.entries[request.args[1]]
					recipe = if entry then entry.job.recipeId else nil
				end
				local result = command(actor, request)
				if result.ok and action == "settlement-place" then
					local shared = session.snapshot(actor).survivalSettlement
					local placed = if shared
						then shared.settlement.structures[shared.settlement.config.tribeId .. ":" .. request.args[1]]
						else nil
					if placed and placed.actorId == actor then
						factoryPorts.recordDevelopment(actor, "place:" .. placed.id, {
							action = "place",
							target = placed.definition.id,
							quantity = 1,
						})
					end
				end
				local commandOrigin = if method == "commandServer" then "server" else "client"
				if
					not result.ok
					or not session.committedReceipt(
						actor,
						request.sessionEpoch,
						request.requestId,
						request.action,
						request.args,
						commandOrigin
					)
				then
					return result
				end
				local event: any = nil
				if action == "craft-complete" and recipe then
					event = { action = "craft", target = recipe, quantity = 1 }
				elseif action == "rest" then
					event = { action = "rest", target = "rw.onboarding.rest-mat", quantity = 1 }
				elseif action == "home-place" then
					event = { action = "place", target = request.args[2].kind, quantity = 1 }
				end
				if event then
					factoryPorts.recordDevelopment(
						actor,
						tostring(request.sessionEpoch) .. ":" .. request.requestId,
						event
					)
				end
				if recipe then
					local operation = tostring(request.sessionEpoch) .. ":" .. request.requestId
					commandReceipts[actor .. ":" .. operation] = {
						epoch = request.sessionEpoch,
						requestId = request.requestId,
						action = request.action,
						args = table.clone(request.args),
						origin = commandOrigin,
						target = recipe,
					}
					archipelago.objective(actor, operation)
				end
				return result
			end
		end
		-- END finalized command development receipts.
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
		if extension.id == "monetization" then
			-- Home entitlement reads must use the same serialized owner as
			-- Session snapshots, including when the backend yields on renew.
			monetization = extensions[index]
		end
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
