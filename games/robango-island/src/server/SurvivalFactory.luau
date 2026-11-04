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
local Award = require(Forge.genres["survival-coop"].module.ProgressionExtension).award
local ToolTiers = require(Forge.genres["survival-coop"].module.ToolTiers)
local CharacterRules = require(Forge.genres["survival-coop"].module.CharacterRules)
local GuideEvents = require(Forge.genres["survival-coop"].module.GuideEvents)
return function(content: any, source, world, backend, clock, options, provision, wildlifePolicy): (any, string?)
	content, source, wildlifePolicy =
		world.roleContent or content, world.roleSource or source, world.roleWildlife or wildlifePolicy
	content = table.clone(content)
	content.capability = nil
	require(script.Parent.LateEquipmentPorts).bind(world)
	-- C4 pet rename: names pass Roblox text filtering for broadcast (other players see the label);
	-- a filter error refuses the rename rather than storing raw text.
	world.filterPetName = function(actor: string, raw: string): string?
		local userId = tonumber(actor)
		if not userId then
			return nil
		end
		local ok, filtered = pcall(function()
			local result = game:GetService("TextService"):FilterStringAsync(raw, userId)
			return result:GetNonChatStringForBroadcastAsync()
		end)
		return if ok and type(filtered) == "string" then filtered else nil
	end
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
	-- p134 C1 dead end 3: on the onboarding island a build's shortfall is paid from the bag (the card
	-- showed campfire wood 0/4 with 9 logs carried). The reserve command first deposits those stacks into
	-- the camp warehouse through the real transfer; for that one deposit the build site is the reach.
	local bagBuild = world.layout ~= nil
	local buildDeposit: { [string]: boolean } = {}
	local bagSent: { [string]: any } = {}
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
	-- C3 (G12): carcass outputs are picked after a kill (CarcassExtension), not dropped automatically.
	table.insert(extensionFactories, require(Forge.genres["survival-coop"].module.CarcassExtension).factory)
	if world.clanDirectory then
		local directory: any = world.clanDirectory
		local occupying: { string } = {}
		local operations = {}
		for _, operation in content.operations do
			operations[operation.id] = operation
		end
		world.clan = {
			store = function()
				return directory.store
			end,
			now = seconds,
			owner = function(id)
				local state = directory.read("clan:" .. id)
				return if state then state.owner else ""
			end,
			create = directory.create,
			browse = directory.browse,
			identity = function(actor, requested)
				if requested then
					local state = directory.read("clan:" .. requested)
					return if state then requested else nil
				end
				return directory.membership(actor)
			end,
			visible = function(state, actor)
				return state.members[actor] ~= nil and not state.dissolved
			end,
			facts = function(_actor, _id, _operation, args)
				local territory = false
				for _, layout in content.layouts do
					territory = territory or layout.id == args.territory
				end
				local state = directory.read("clan:" .. _id)
				local hall = false
				for _, placed in if confirmed then confirmed.structures else {} do
					hall = hall
						or (
							placed.definition.id == "clan-hall"
							and state ~= nil
							and state.members[placed.actorId] ~= nil
							and world.layout ~= nil
							and state.territory == world.layout.id
						)
				end
				return {
					rules = content.clanPolicy,
					operations = operations,
					hall = hall,
					territoryAllowed = territory,
					hasProperty = state ~= nil and state.territory ~= "",
					transferAuthorized = false,
				}
			end,
		}
		world.captureEligibility = function(actor: string)
			local id = directory.membership(actor)
			local state = if id then directory.read("clan:" .. id) else nil
			local outpost = directory.read("outpost:rw.team-outpost")
			return state ~= nil
				and require(Forge.core.domain.settlement.Clan).effect(
					state,
					actor,
					"advanced-capture",
					seconds(),
					outpost
				)
		end
		world.outpost = {
			store = world.clan.store,
			now = seconds,
			owner = function()
				return ""
			end,
			identity = function(_actor, requested)
				return if requested == nil or requested == "rw.team-outpost" then "rw.team-outpost" else nil
			end,
			facts = function(actor: string, _id: string, _operation: string, _args: any, commandOrigin: string)
				local state = directory.read("outpost:rw.team-outpost")
				local byClan: { [string]: { string } } = {}
				local occupants: { string } = {}
				local function eligible(player: string, clanId: string): boolean
					local current = directory.membership(player)
					return current == clanId
				end
				for player, clanId in if state then state.queue or {} else {} do
					if eligible(player, clanId) then
						byClan[clanId] = byClan[clanId] or {}
						table.insert(byClan[clanId], player)
					end
				end
				local teams: { any } = {}
				local ids: { string } = {}
				for clanId in byClan do
					table.insert(ids, clanId)
				end
				table.sort(ids)
				for _, clanId in ids do
					local actors = byClan[clanId]
					table.sort(actors)
					if #actors >= content.outpostPolicy.minTeam and #teams < 2 then
						while #actors > content.outpostPolicy.maxTeam do
							table.remove(actors)
						end
						table.insert(teams, { clanId = clanId, actors = actors })
					end
				end
				occupants = table.clone(occupying)
				return {
					server = commandOrigin == "server",
					role = if world.layout and world.layout.id == "rw.team-outpost" then "team-outpost" else "",
					rules = content.outpostPolicy,
					teams = teams,
					occupants = occupants,
					clanId = directory.membership(actor),
					eligible = eligible,
					optedIn = function(player: string)
						return state ~= nil and state.queue ~= nil and state.queue[player] ~= nil
					end,
				}
			end,
			sampleOccupancy = function(state: any)
				occupying = {}
				for _, match in state.matches do
					if match.status == "active" then
						for player in match.actors do
							if world.outpostOccupying and world.outpostOccupying(player) then
								table.insert(occupying, player)
							end
						end
					end
				end
			end,
		}
	end
	local expeditionStore = ActorDocuments.new(backend, options, "robango-exp-v1")
	require(Forge.genres["survival-coop"].module.ProgressionPorts).bind(world, content, expeditionStore, seconds)
	require(script.Parent.LateEquipmentPorts).bind(world)
	local activeSession: any = nil
	if world.outpost then
		local sequence = 0
		world.outpost.drive = function(actor: string, extension: any)
			if not world.layout or world.layout.id ~= "rw.team-outpost" then
				return { status = "confirmed", pending = 0 }
			end
			local state = extension.snapshot(actor)
			if not state then
				return { status = "recovering", pending = 1 }
			end
			local operation: string = "start"
			local body: any = nil
			for id, match in state.matches do
				if match.status == "active" then
					operation, body = "advance", { matchId = id }
				end
			end
			if not body then
				local facts = world.outpost.facts(actor, "rw.team-outpost", "start", {}, "server")
				if #facts.teams ~= 2 then
					return { status = "confirmed", pending = 0 }
				end
				body = { matchId = "match:" .. tostring(state.revision) }
			end
			sequence += 1
			local action = "survival-coop:outpost-" .. operation
			local result = extension.command(
				actor,
				action,
				{ "rw.team-outpost", body },
				{
					actorId = actor,
					requestId = "outpost-tick:" .. tostring(seconds()) .. ":" .. tostring(sequence),
					sessionEpoch = 0,
				},
				"server",
				function()
					return { ok = true }
				end
			)
			if result.ok then
				world.outpost.sampleOccupancy(extension.snapshot(actor))
			end
			return {
				status = if result.ok then "confirmed" else "recovering",
				pending = if result.ok then 0 else 1,
				reason = result.reason,
			}
		end
	end
	local monetization: any = nil
	local gatherReceipt: any = nil
	local wildlifeSnapshot: any = nil
	local commandReceipts: any = {}
	if world.marketStore then
		local LocalMarket = require(Forge.genres["survival-coop"].module.MarketExtension)
		for index, create in extensionFactories do
			if create == LocalMarket.factory then
				extensionFactories[index] = function(ctx)
					local personal = require(Forge.core.infra.data.CrossServerMarketPersonal).new({
						personalTransfer = function(actor)
							return if activeSession then activeSession.personalTransfer(actor) else nil
						end,
						personalTransaction = function(actor, transform)
							if not activeSession then
								return false, "PERSONAL_UNAVAILABLE"
							end
							return activeSession.personalTransaction(actor, transform)
						end,
					}, ctx.content.items, require(Forge.games["robango-island"].src.shared.MarketPorts).CATALOG_IDS)
					local tradePorts = table.clone(world.marketStore)
					local durableUpdate = tradePorts.update
					tradePorts.update = function(key, transform)
						if string.sub(key, 1, 7) == "player:" then
							return personal.update(string.sub(key, 8), transform)
						end
						return durableUpdate(key, transform)
					end
					return require(Forge.genres["survival-coop"].module.CrossServerMarketExtension).new(
						tradePorts,
						ctx.now,
						personal,
						require(Forge.games["robango-island"].src.shared.MarketPorts).CATALOG_IDS,
						world.marketAccount
					)
				end
			end
		end
	end
	if world.clan then
		local WalletTransfer = require(Forge.core.infra.data.ClanStoreWallet)
		local Clan = require(Forge.core.domain.settlement.Clan)
		world.clan.wallet = function(actor, operation, body, context, clanToken, retained)
			local personal = if activeSession then activeSession.personalTransfer(actor) else nil
			if not personal then
				return { result = { ok = false, reason = "PERSONAL_UNAVAILABLE" } }
			end
			local actorToken = personal.profile()
			local function slice(data: any, key: string): any
				return if string.sub(key, 1, 5) == "clan:" then data else data.envelope.genres["survival-coop"].data
			end
			local composite = {
				update = function(_, token, transform)
					if string.sub(token.key, 1, 5) == "clan:" then
						local updated, reason = world.clanDirectory.store:update(token, transform)
						if updated then
							clanToken = updated
						end
						return updated, reason
					end
					local saved, reason = activeSession.personalTransaction(actor, transform)
					if saved then
						actorToken = personal.profile()
					end
					return if saved then actorToken else nil, if saved then nil else reason
				end,
			}
			local sourceToken = if operation == "deposit" then actorToken else clanToken
			local destinationToken = if operation == "deposit" then clanToken else actorToken
			local request = retained
				or {
					id = actor .. ":" .. tostring(context.sessionEpoch) .. ":" .. context.requestId,
					actor = actor,
					operation = operation,
					amount = body.amount,
					source = sourceToken.key,
					destination = destinationToken.key,
					epoch = tostring(context.sessionEpoch),
					expiresAt = 9007199254740991,
				}
			local intentResult: any = nil
			local intent, intentError = world.clanDirectory.store:update(clanToken, function(document)
				document.walletOperations = document.walletOperations or {}
				local known = document.walletOperations[request.id]
				local canonical = require(Forge.core.domain.command.Ledger).canonical
				if known and canonical(known.request) ~= canonical(request) then
					intentResult = { ok = false, reason = "TRANSFER_CONFLICT" }
				elseif known then
					intentResult = known.result
				elseif not Clan.allowed(document, actor, operation) then
					intentResult = { ok = false, reason = "FORBIDDEN" }
				else
					document.walletOperations[request.id] = { request = request }
				end
				return document
			end)
			if not intent then
				return { token = clanToken, result = { ok = false, reason = intentError } }
			end
			clanToken = intent
			if intentResult then
				return { token = clanToken, result = intentResult }
			end
			sourceToken = if operation == "deposit" then actorToken else clanToken
			destinationToken = if operation == "deposit" then clanToken else actorToken
			local advanced = WalletTransfer.advance({
				store = composite,
				now = seconds,
				maxReceipts = 4096,
				encode = require(Forge.core.domain.command.Ledger).canonical,
				balance = function(data, key)
					local owner = slice(data, key)
					return if string.sub(key, 1, 5) == "clan:" then owner.funds else owner.balance
				end,
				setBalance = function(data, key, amount)
					local owner = slice(data, key)
					if string.sub(key, 1, 5) == "clan:" then
						owner.funds = amount
					else
						owner.balance = amount
					end
				end,
				authorize = function()
					return Clan.allowed(clanToken.data, actor, operation)
				end,
			}, sourceToken, destinationToken, request)
			local result = {
				ok = advanced.status == "confirmed",
				reason = advanced.reason,
				data = { status = advanced.status },
			}
			if advanced.status == "confirmed" or advanced.status == "rejected" then
				local finished, reason = world.clanDirectory.store:update(clanToken, function(document)
					document.walletOperations[request.id].result = result
					return document
				end)
				if not finished then
					return { token = clanToken, result = { ok = false, reason = reason } }
				end
				clanToken = finished
			end
			return {
				token = clanToken,
				result = result,
			}
		end
	end
	local HomeContent = require(Forge.core.domain.home.HomeContent)
	local homeOwner: any = nil
	local function personalData(actor)
		local port = if activeSession then activeSession.personalTransfer(actor) else nil
		return if port then port.profile().data.envelope.genres["survival-coop"].data else nil
	end
	if world.musicRepository then
		local MusicRange = require(Forge.genres["survival-coop"].module.EnsembleRange)
		local range = MusicRange.new({
			players = game:GetService("Players"),
			workspace = workspace,
			venues = world.musicVenues,
			hasInstrument = function(actor)
				local data = personalData(actor)
				for _, item in if data then data.inventory.bag.items else {} do
					if string.match(item.catalogId, "^instrument%-") then
						return true
					end
				end
				return false
			end,
		})
		require(Forge.genres["survival-coop"].module.EnsembleExtension).configure({
			rules = content.music,
			repository = world.musicRepository,
			decode = world.musicDecode,
			inRange = range.inRange,
			owns = function(actor: string, instrumentId: string): boolean
				local data = personalData(actor)
				for _, item in if data then data.inventory.bag.items else {} do
					if item.catalogId == "instrument-" .. instrumentId and item.quantity > 0 then
						return true
					end
				end
				return false
			end,
			serverNow = function()
				return workspace:GetServerTimeNow()
			end,
			enforceRange = function(room, leave)
				range.enforce(room, leave, content.music.radiusStuds)
			end,
		})
		require(Forge.genres["survival-coop"].module.ScoreTransport).configure({
			repository = world.musicRepository,
			decode = world.musicDecode,
			uploadTtl = 120,
		})
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
	if world.townLayout then
		-- Saltmeadow plot runtime (C5a): fenced plot documents, paid from the personal bag.
		local townCatalog = Job.catalog(content)
		local townDefinitions = {}
		for _, definition in content.structures do
			townDefinitions[definition.id] = {
				id = definition.id,
				footprintX = definition.footprintX,
				footprintZ = definition.footprintZ,
				cost = definition.cost,
				station = definition.station,
			}
		end
		local TownRuntime = require(Forge.games["robango-island"].src.shared.TownRuntime)
		world.town = TownRuntime.new({
			layout = world.townLayout,
			townId = source.townId or "town-01",
			definitions = townDefinitions,
			catalog = townCatalog,
			store = require(Forge.core.infra.data.FencedStore).new(backend, options),
			now = seconds,
			rank = function(actor)
				return developmentFacts(expeditionStore.snapshot(actor)).grade
			end,
			reach = function(actor, plot)
				local spatial = world.services.survivalDeath
				local at = if spatial then spatial.position(actor) else nil
				return at ~= nil
					and at.x >= plot.min.x - 8
					and at.x <= plot.max.x + 8
					and at.z >= plot.min.z - 8
					and at.z <= plot.max.z + 8
			end,
			bag = function(actor, transform)
				if not activeSession then
					return false, "PERSONAL_UNAVAILABLE"
				end
				local reason: string? = nil
				local ok, failure = activeSession.personalTransaction(actor, function(raw)
					reason = nil
					local data = raw.envelope.genres["survival-coop"].data
					local bag = Inventory.fromSave(data.inventory.bag, townCatalog)
					local nextBag, why = transform(bag)
					reason = why
					if nextBag and not why then
						data.inventory.bag = Inventory.save(nextBag)
					end
					return raw
				end)
				if not ok then
					return false, tostring(failure)
				end
				return reason == nil, reason
			end,
			publish = world.publishTownPlot,
		})
		local failed = world.town.start()
		if #failed > 0 then
			warn("TOWN_PLOTS_UNAVAILABLE:" .. table.concat(failed, ","))
		end
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
					-- The visible home dock part with the station reach rule (p126), as every other dock
					-- since p123; the fixed dock point only when no dock part was placed.
					atDock = if world.homeDock and world.homeDock.Parent
						then (world.nearPart :: any)(actor, world.homeDock)
						else spatial ~= nil and spatial.reachable(actor, rules.dock),
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
	-- p134 v65: a voyage asked for by a durable command teleports only after that command returns
	-- (see travelAfterCommand); `go` runs the handoff and answers (ok, reason) or a result table.
	local HANDOFF_WAIT_SECONDS = 5
	local function deferTravel(player: any, go: () -> (any, any)): any
		task.defer(function()
			local actor = tostring(player.UserId)
			local waited = 0
			local function settle()
				while activeSession and not activeSession.settled(actor) and waited < HANDOFF_WAIT_SECONDS do
					waited += task.wait()
				end
			end
			local ok: any, reason
			repeat
				settle()
				ok, reason = go()
				if type(ok) == "table" then
					ok, reason = ok.ok, ok.reason
				end
				-- Other work can take the actor between the check and the handoff: wait again.
				local retry = ok ~= true and reason == "COMMAND_PENDING" and waited < HANDOFF_WAIT_SECONDS
				if retry then
					waited += task.wait()
				end
			until not retry
			if ok ~= true and world.publishTravel then
				world.publishTravel(player, tostring(reason or "travel_failed"))
			end
		end)
		local accepted: any = { ok = true, reason = "travelling" }
		return accepted
	end
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
		-- The trip is settled in the caller's transaction; the handoff home waits until the command
		-- returns (journey6h 304 min: Expedition > Home > Confirm ran the router inside party-action,
		-- where the Session holds the actor and prepareHandoff refuses).
		returnHome = function(actor)
			local player = game:GetService("Players"):GetPlayerByUserId(tonumber(actor) or 0)
			if not provision.returnHome or not player then
				return { ok = false, reason = "HOME_ROUTE_UNAVAILABLE" }
			end
			return deferTravel(player, function()
				local result = provision.returnHome(actor)
				return result.ok, result.reason
			end)
		end,
	})
	-- p134 v65: a voyage asked for by a durable command (sea chart sail, drift-isle depart) teleports
	-- only after that command returns. Inside it the Session holds the actor busy, so the handoff
	-- (Session.prepareHandoff) refused every chart voyage with COMMAND_PENDING while the dock prompt,
	-- which is no command, travelled. The command answers "travelling"; a later refusal is published
	-- on ForgeTravelResult like a dock result.
	local function SeaChartRole(layoutId: string): string
		return require(Forge.games["robango-island"].src.shared.SeaChart).roleOf(layoutId)
	end
	-- p134 v66: the first chart sail after a load was still refused COMMAND_PENDING. The deferred
	-- voyage ran while the actor was held by other session work that yields on a cold DataStore
	-- (the post-command push's recovery sweep, the 1 Hz advance, a guide/xp personal transaction,
	-- another durable command), and prepareHandoff refuses on busy or any staged command. The voyage
	-- waits (bounded, one Heartbeat at a time) until the session can hand the actor off.
	local function travelAfterCommand(player: any, destination: string, route: number?, extra: any?): any
		return deferTravel(player, function()
			return world.travel(player, destination, route, extra)
		end)
	end
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
				if args[1] == "survivor" and world.survivor then
					-- First-join survivor picker (A6): the choice lives in the same actor document.
					local chosen = world.survivor.choose(expeditionStore, actor, args[2])
					if chosen.ok and world.dressSurvivor then
						world.dressSurvivor(actor)
					end
					return chosen
				elseif args[1] == "next-island" then
					return archipelago.nextIsland(actor)
				elseif (args[1] == "town-claim" or args[1] == "town-build") and world.town then
					-- Saltmeadow plots (C5a): claim a free plot or build on your own.
					return world.town.command(actor, args[1], args[2])
				elseif args[1] == "return" then
					return archipelago.recover(actor, "return")
				elseif args[1] == "sail" then
					-- C7 sea chart voyage to a role island: the actor stands at a dock or rift and the
					-- live level gate allows it; travel then goes through the role/teleport router.
					local SeaChart = require(Forge.games["robango-island"].src.shared.SeaChart)
					local role = if world.layout then SeaChart.roleOf(world.layout.id) else "harbor"
					local from = if world.sailPoint then world.sailPoint(actor) else nil
					local level = expeditionFacts(actor, expeditionStore.snapshot(actor)).level
					local ok, reason = SeaChart.sail(args[2], role, level, from)
					local player = game:GetService("Players"):GetPlayerByUserId(tonumber(actor) or 0)
					if not ok or not player or not world.travel then
						local refused: any = { ok = false, reason = reason or "travel_unavailable" }
						return refused
					end
					return travelAfterCommand(player, args[2])
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
				if not document then
					return nil, reason
				end
				-- Mission reputation (four organizations) rides along for ui.organizations; it is
				-- an expedition-owned ledger kept beside, not inside, the active expedition.
				local view: any = if document.archipelago then table.clone(document.archipelago) else {}
				view.reputation = table.clone(document.reputation or {})
				view.survivor = if world.survivor then world.survivor.view(document) else nil
				return view, nil
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
	-- Expedition crew (party) and route departure; travel stays on the server's own port.
	table.insert(extensionFactories, function()
		local crew = require(Forge.genres["survival-coop"].module.ExpeditionExtension)
		return require(Forge.core.infra.genre.Session).registerLifecycle(crew.new({
			content = content,
			now = seconds,
			facts = function(actor)
				return expeditionFacts(actor, expeditionStore.snapshot(actor))
			end,
			document = function(actor)
				return (expeditionStore.snapshot(actor))
			end,
			transaction = expeditionStore.transaction,
			layoutId = function()
				return if world.layout then world.layout.id else nil
			end,
			position = function(actor)
				local spatial = world.services.survivalDeath
				return if spatial then spatial.position(actor) else nil
			end,
			online = function(actor)
				return game:GetService("Players"):GetPlayerByUserId(tonumber(actor) or 0) ~= nil
			end,
			onExpedition = function()
				return workspace:GetAttribute("ForgeWorldRole") == "archipelago"
			end,
			-- This server's role from its layout id (SeaChart.roleOf's rule, inline: not every host
			-- mounts the pack's shared modules).
			role = function(): string?
				local id: any = if world.layout then world.layout.id else nil
				if type(id) ~= "string" then
					return nil
				end
				local role: string = if string.match(id, "^rw%.a%d+%.s%d+$")
					then "archipelago"
					else (string.gsub(id, "^rw%.", ""))
				return role
			end,
			-- G22: live player count per route (SocialPresence via the server's world.population).
			population = function(listing)
				return if world.population then world.population(listing) else nil
			end,
			personal = personalData,
			worn = function(actor)
				local spatial = world.services.survivalDeath
				local equipped = (if spatial then spatial.equipment(actor) else nil) or {}
				local data = personalData(actor)
				local ids = {}
				for id, item in if data then data.inventory.bag.items else {} do
					if equipped[id] == true and item.durabilityMilli > 0 then
						table.insert(ids, item.catalogId)
					end
				end
				return ids
			end,
			token = function()
				return game:GetService("HttpService"):GenerateGUID(false)
			end,
			claim = function(actor, id)
				return expeditionStore.transaction(actor, function(document)
					local ok, reason = require(Forge.genres["survival-coop"].module.MissionRewards).claim(document, id)
					return { ok = ok, reason = reason }
				end)
			end,
			travel = function(actor, destination, route, extra)
				local player = game:GetService("Players"):GetPlayerByUserId(tonumber(actor) or 0)
				if not player or not world.travel then
					local unavailable: any = { ok = false, reason = "travel_unavailable" }
					return unavailable
				end
				-- Leaving a drift isle for home settles the expedition (no teleport): answered in the command.
				if destination == "home" and world.layout and SeaChartRole(world.layout.id) == "archipelago" then
					local ok: any, reason = world.travel(player, destination, route, extra)
					if type(ok) == "table" then
						return ok
					end
					local result: any = { ok = ok == true, reason = if ok then nil else reason or "travel_failed" }
					return result
				end
				return travelAfterCommand(player, destination, route, extra)
			end,
		}))
	end)
	if world.home then
		-- Same-server direct trade is served wherever players meet (DirectTradeExtension).
		world.directTrade = true
		table.insert(extensionFactories, function(ctx)
			local config = table.clone(world.home)
			config.content, config.store, config.now = ctx.content, ctx.store, ctx.now
			homeOwner = HomeExtension.new(config)
			return homeOwner
		end)
	end
	local JournalPorts = require(Forge.genres["survival-coop"].module.JournalPorts)
	local journalPort = JournalPorts.new(
		JournalPorts.personal({
			personalTransaction = function(actor, transform)
				return activeSession.personalTransaction(actor, transform)
			end,
			personalTransfer = function(actor)
				return if activeSession then activeSession.personalTransfer(actor) else nil
			end,
		}),
		content
	)
	journalPort.interact = function(
		actor: string,
		document: any,
		objectiveId: string,
		receiptId: string
	): (any, string?)
		local target = if world.journalTargets then world.journalTargets[objectiveId] else nil
		objectiveId = if target then target.objective else objectiveId
		local chapter: any = nil
		for _, row in content.chapters do
			if document.journal and row.id == document.journal.active then
				chapter = row
			end
		end
		if not chapter then
			return nil, "NO_ACTIVE_CHAPTER"
		end
		local objective: any = nil
		for _, row in chapter.objectives do
			if row.id == objectiveId then
				objective = row
			end
		end
		if not objective then
			return nil, "WRONG_OBJECTIVE"
		end
		local current: any = nil
		for _, row in chapter.objectives do
			if (document.journal.counts[row.id] or 0) < row.quantity then
				current = row
				break
			end
		end
		if not current or current.id ~= objectiveId then
			return nil, "WRONG_OBJECTIVE"
		end
		local death: any = world.services.survivalDeath
		-- Reach the visible marker part with the station rule (a ray to its centre hits the part).
		if
			not target
			or not (
				if target.part and target.part.Parent
					then world.nearPart(actor, target.part)
					else death.reachable(actor, target.position)
			)
		then
			return nil, "OUT_OF_REACH"
		end
		local physical = { survey = true, inspect = true, activate = true, speak = true, tune = true }
		if objective.action == "escort" then
			document.journalEscort = document.journalEscort
				or {
					objective = objective.id,
					chapter = chapter.id,
					position = table.clone(target.position),
					lastAt = seconds(),
					marker = target.marker,
					target = objective.target,
					layout = world.layout.id,
				}
			return { pending = true }, nil
		elseif objective.action == "return" then
			if not document.journalEscort or not document.journalEscort.arrived then
				return nil, "ESCORT_REQUIRED"
			end
			physical["return"] = true
		end
		local consumed = { deposit = true, administer = true, install = true, submit = true, deploy = true, eat = true }
		local catalog = require(Forge.core.domain.crafting.Job).catalog(content)
		local bag = Inventory.fromSave(document.inventory.bag, catalog)
		local function consume(item: string, amount: number): boolean
			local ids = {}
			for id, row in bag.items do
				if row.catalogId == item then
					table.insert(ids, id)
				end
			end
			table.sort(ids)
			for _, id in ids do
				local quantity = math.min(amount, Inventory.available(bag, id))
				if quantity > 0 then
					bag = assert(Inventory.consume(bag, id, quantity, bag.version), "journal material debit")
					amount -= quantity
				end
			end
			return amount == 0
		end
		if objective.action == "assemble" then
			local operation: any = nil
			for _, row in content.operations do
				if row.id == "assemble-" .. objective.target then
					operation = row
				end
			end
			if not operation then
				return nil, "UNKNOWN_OPERATION"
			end
			document.journalJobs = document.journalJobs or {}
			local job = document.journalJobs[objective.id]
			if not job then
				for _, input in operation.inputs do
					if not consume(input.item, input.quantity) then
						return nil, "MATERIALS_REQUIRED"
					end
				end
				document.journalJobs[objective.id] =
					{ jobId = receiptId, finishAt = seconds() + operation.seconds, status = "pending" }
				document.inventory.bag = Inventory.save(bag)
				return { pending = true }, nil
			end
			if seconds() < job.finishAt then
				return nil, "NOT_READY"
			end
			job.status = "completed"
			document.missionItems = document.missionItems or {}
			for _, output in operation.outputs do
				document.missionItems[output.item] = (document.missionItems[output.item] or 0) + output.quantity
			end
		elseif consumed[objective.action] then
			local item = if objective.action == "administer"
				then content.progressionPolicy.journalRemedy
				elseif objective.target == "signal-relay" then "signal-relay-kit"
				else objective.target
			local reserved = if document.missionItems then document.missionItems[item] or 0 else 0
			if reserved >= objective.quantity then
				document.missionItems[item] -= objective.quantity
			elseif not consume(item, objective.quantity) then
				return nil, "MATERIALS_REQUIRED"
			end
		elseif not physical[objective.action] then
			return nil, "OBJECTIVE_REQUIRES_RECEIPT"
		end
		document.inventory.bag = Inventory.save(bag)
		return {
			id = "interact:" .. receiptId,
			action = objective.action,
			target = objective.target,
			quantity = if objective.action == "survey" then 1 else objective.quantity,
			marker = target.marker,
		},
			nil
	end
	local journalFeed = require(Forge.genres["survival-coop"].module.JournalObjectiveFeed).new(journalPort, content, {})
	local function recoverJournal(actor: string)
		local document = journalPort.read(actor)
		if document and document.journal and document.journal.active then
			local escort = document.journalEscort
			if
				escort
				and escort.chapter == document.journal.active
				and escort.layout == world.layout.id
				and not escort.arrived
			then
				local spatial: any = world.services.survivalDeath
				local actorPosition: any = spatial.position(actor)
				local exit: any = nil
				for _, anchor in world.layout.anchors do
					if anchor.id == "exit" then
						exit = anchor.position
					end
				end
				if actorPosition and exit then
					local function distance(a: any, b: any): number
						return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
					end
					local length = distance(escort.position, actorPosition)
					local policy = content.missionPolicy
					local step = if length <= policy.stopStuds
						then math.min(
							math.max(0, seconds() - escort.lastAt) * policy.escortSpeed,
							math.max(0, length - policy.followStuds)
						)
						else 0
					local saved, reason = journalPort.update(actor, function(current: any)
						local npc: any = current.journalEscort
						if step > 0 then
							for _, axis in { "x", "y", "z" } do
								npc.position[axis] += (actorPosition[axis] - npc.position[axis]) * step / length
							end
						end
						npc.lastAt = seconds()
						npc.arrived = distance(npc.position, exit) <= policy.followStuds
							and distance(actorPosition, exit) <= policy.interactionStuds
						return current
					end)
					if not saved then
						return { ok = false, reason = reason }
					end
					document = journalPort.read(actor)
					escort = document.journalEscort
					if world.renderJournalEscort then
						world.renderJournalEscort(actor, escort.position)
					end
				end
			end
			if escort and escort.arrived and escort.chapter == document.journal.active then
				local result = journalFeed.accept({
					actor = actor,
					chapterId = escort.chapter,
					receiptId = "escort:" .. escort.objective,
					committed = true,
					ok = true,
					action = "escort",
					target = escort.target,
					quantity = 1,
				})
				if not result.ok and result.reason ~= "WRONG_OBJECTIVE" then
					return result
				end
			end
			for id, npc in if wildlifeSnapshot then wildlifeSnapshot(actor) or {} else {} do
				if
					npc.healthMilli == 0
					and npc.killer == actor
					and npc.killedAt
					and document.journalOpenedAt
					and npc.killedAt >= document.journalOpenedAt
				then
					journalFeed.accept({
						actor = actor,
						chapterId = document.journal.active,
						receiptId = "biology:" .. id .. ":" .. tostring(npc.killedAt),
						committed = true,
						ok = true,
						action = "fresh-kill",
						target = npc.catalogId,
						quantity = 1,
					})
				end
			end
		end
		return journalFeed.recover(actor, function(binding: any): any
			if binding.action == "survival-coop:gather" then
				local grant = if gatherReceipt then gatherReceipt(actor, binding.epoch, binding.requestId) else nil
				if not grant then
					return nil
				end
				local events = {}
				for item, quantity in grant.items do
					table.insert(events, {
						receiptId = "g:" .. tostring(binding.epoch) .. ":" .. binding.requestId .. ":" .. item,
						action = "gather",
						target = item,
						quantity = quantity,
					})
				end
				return events
			end
			local port = activeSession.personalTransfer(actor)
			local commands = if port then port.profile().data.envelope.commands else nil
			local epoch = if commands then commands.epochs[tostring(binding.epoch)] else nil
			local receipt = if epoch then epoch.outcomes[binding.requestId] else nil
			if not receipt then
				return nil
			end
			local canonical = require(Forge.core.domain.command.Ledger).canonical
			local expected = (if binding.origin == "server" then "S" else "")
				.. canonical({ action = binding.action, args = binding.args })
			if receipt.binding ~= expected or not receipt.result.ok then
				return {}
			end
			return {
				{
					receiptId = tostring(binding.epoch) .. ":" .. binding.requestId,
					action = binding.event.action,
					target = binding.event.target,
					quantity = binding.event.quantity,
				},
			}
		end)
	end
	table.insert(extensionFactories, function(): any
		return require(Forge.core.infra.genre.Session).registerLifecycle({
			id = "journal-delivery",
			handles = function()
				return false
			end,
			command = function()
				return { ok = false, reason = "UNKNOWN_ACTION" }
			end,
			recover = function(actor)
				local result = recoverJournal(actor)
				return {
					status = if result.ok then "confirmed" else "recovering",
					pending = if result.ok then 0 else 1,
					reason = result.reason,
				}
			end,
		})
	end)
	if content.buildingPolicy and world.layout and world.layout.id == "rw.home" then
		local ItemCatalog = require(Forge.core.domain.inventory.ItemCatalog)
		local catalog = ItemCatalog.new(content.items)
		local buildHome: any = nil
		local building = require(Forge.genres["survival-coop"].module.MultistoreyCommands).new(
			JournalPorts.personal({
				personalTransaction = function(actor, transform)
					return activeSession.personalTransaction(actor, transform)
				end,
				personalTransfer = function(actor)
					return if activeSession then activeSession.personalTransfer(actor) else nil
				end,
			}),
			content,
			function(actor, document, operation, body)
				local home = buildHome
				local part = if operation == "place"
					then body.part
					else if document.multistorey then document.multistorey.parts[body.id] else nil
				local position = if part
					then {
						x = part.x * content.buildingPolicy.cellStuds,
						y = content.homePolicy.dock.y + content.homePolicy.floors[part.floor],
						z = part.z * content.buildingPolicy.cellStuds,
					}
					else nil
				local half = if home then world.home.rules.landSizes[home.landRank] / 2 else 0
				return {
					allowed = home ~= nil and home.owner == actor,
					inBounds = position ~= nil
						and math.abs(position.x) + 2 <= half
						and math.abs(position.z) + 2 <= half,
					reachable = position ~= nil and world.services.survivalDeath.reachable(actor, position),
					occupied = false,
				}
			end,
			function(document, consume, grant, receipt: string)
				local bag = Inventory.fromSave(document.inventory.bag, catalog)
				for _, cost in consume do
					local remaining = cost.quantity
					for id, item in bag.items do
						if item.catalogId == cost.item and remaining > 0 then
							local quantity = math.min(Inventory.available(bag, id), remaining)
							if quantity > 0 then
								local updated, reason = Inventory.consume(bag, id, quantity, bag.version)
								if not updated then
									return reason
								end
								bag, remaining = updated, remaining - quantity
							end
						end
					end
					if remaining > 0 then
						return "MISSING_KIT"
					end
				end
				for index, refund in grant do
					local updated, reason = Inventory.add(bag, catalog, {
						itemId = receipt .. ":" .. index,
						catalogId = refund.item,
						quantity = refund.quantity,
						qualityMilli = 1000,
						durabilityMilli = catalog[refund.item].maxDurabilityMilli or 0,
						attributes = {},
					}, bag.version)
					if not updated then
						return reason
					end
					bag = updated
				end
				document.inventory.bag = Inventory.save(bag)
				return nil
			end
		)
		table.insert(extensionFactories, function(): any
			local extension = { id = "building" }
			function extension.handles(action)
				return action == "survival-coop:building-place" or action == "survival-coop:building-remove"
			end
			function extension.command(actor, action, args, context, _origin, admit)
				local admission = admit()
				if not admission.ok then
					return admission
				end
				buildHome = if homeOwner then homeOwner.snapshot(actor) else nil
				local result = building.command(
					actor,
					tostring(context.sessionEpoch) .. ":" .. context.requestId,
					string.sub(action, #"survival-coop:building-" + 1),
					args[1]
				)
				if result.ok and world.publishBuilding then
					world.publishBuilding(actor, building.geometry(result.data))
				end
				return result
			end
			function extension.snapshot(actor)
				local data = personalData(actor)
				local state = if data then data.multistorey else nil
				if state and world.publishBuilding then
					world.publishBuilding(actor, building.geometry(state))
				end
				return state
			end
			return require(Forge.core.infra.genre.Session).registerLifecycle(extension)
		end)
	end
	table.insert(extensionFactories, function(): any
		return {
			id = "audio-settings",
			handles = function(action)
				return action == "survival-coop:audio-settings"
			end,
			command = function(actor, _action, args, _context, _origin, admit)
				local allowed = admit()
				if not allowed.ok then
					return allowed
				end
				local ok, reason = journalPort.update(actor, function(document)
					local extra: any = if type(args[3]) == "table" then args[3] else {}
					document.audioSettings = {
						muted = args[1],
						volume = args[2],
						music = extra.music,
						sfx = extra.sfx,
						ensemble = extra.ensemble,
						reducedEffects = extra.reducedEffects == true,
						language = extra.language,
						textSize = extra.textSize,
					}
					return document
				end)
				return { ok = ok, reason = reason }
			end,
			snapshot = function(actor)
				local document = personalData(actor)
				local settings = if document then document.audioSettings or { muted = false, volume = 1 } else nil
				-- The client picks its pack-text locale from this at startup (the handshake push runs
				-- this snapshot before Client.start returns); nil (auto) follows the player's LocaleId.
				local player = game:GetService("Players"):GetPlayerByUserId(tonumber(actor) or 0)
				if player and settings then
					player:SetAttribute("ForgeLanguage", settings.language)
				end
				return settings
			end,
		}
	end)
	table.insert(extensionFactories, function(): any
		return require(Forge.genres["survival-coop"].module.RecipeMarks).factory(journalPort, content.recipes)
	end)
	if world.opening then
		-- C1 opening (onboarding role only): publishes the per-player beat view, observes the windbreak.
		table.insert(extensionFactories, function(): any
			return world.opening.extension
		end)
	end
	table.insert(extensionFactories, function(ctx)
		local journalContext = table.clone(ctx)
		journalContext.journal = journalPort
		return require(Forge.genres["survival-coop"].module.JournalExtension).factory(journalContext)
	end)
	local brawlController: any = nil
	if world.brawlPlan then
		brawlController = require(script.Parent.BrawlRuntime).new(content, world, options, {
			personalTransaction = function(actor, transform)
				return activeSession.personalTransaction(actor, transform)
			end,
			personalTransfer = function(actor)
				return if activeSession then activeSession.personalTransfer(actor) else nil
			end,
		}, seconds, wildlifePolicy)
		world.brawl = { controller = brawlController }
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
			-- The shared town seats its role capacity (32, plan G17); every other role keeps 8.
			maxServerPlayers = if world.townLayout
				then require(Forge.core.domain.island.Topology).roleCapacity("town")
				else 8,
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
						if
							provision.verifyTransfer(actor, proof)
							and (buildDeposit[actor] == true or ports.warehouse(actor))
						then
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
	factoryPorts.brawlController = brawlController
	local closeFactory = factory.close
	factory.close = function(...)
		journalFeed.close()
		return closeFactory(...)
	end
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
	-- p134 v74 #6a: on a live DataStore the opening flush and the heartbeat reads hold the expedition
	-- document across a yield, and a guide event that met that answered DOCUMENT_BUSY and was dropped
	-- (the opening's fiber and hatchet never counted: guides 0/42, fiber 0/3). The event waits for the
	-- document instead (bounded, one Heartbeat at a time); its receipt id keeps the retry exactly-once.
	local DEVELOPMENT_WAIT_SECONDS = 10
	factoryPorts.recordDevelopment = function(actor, receiptId, event)
		local guideCompleted = false
		local recorded, waited = nil, 0
		repeat
			guideCompleted = false
			recorded = expeditionStore.transaction(actor, function(document)
				local development = document.development or { points = 0, definitions = {}, instabilityAccess = 1 }
				development.events = development.events or {}
				development.progress = development.progress or {}
				if development.events[receiptId] then
					return { ok = true }
				end
				development.events[receiptId] = true
				local data = personalData(actor) or {}
				local progression = data.progression or { level = 1, paid = {} }
				local level = progression.level
				local function grade(points)
					return developmentFacts({ development = { points = points } }).grade
				end
				local function record(applied)
					for _, guide in GuideEvents.apply(content, development, level, grade, applied) do
						ArchipelagoExtension.enqueueGuide(document, guide)
						guideCompleted = true
					end
				end
				record(event)
				-- A skill node learned or gear worn before its guide opened can never be learned or put on
				-- again, so holding it satisfies an open guide's purchase/equip step (audit6h P9 guides).
				local worn = {}
				local bag = if data.inventory then data.inventory.bag else nil
				for _, itemId in if data.gear then data.gear.equipped or {} else {} do
					local item = if bag then bag.items[itemId] else nil
					if item then
						worn[item.catalogId] = true
					end
				end
				local paid = progression.paid or {}
				for _, guide in content.guides or {} do
					if
						not development.definitions[guide.id]
						and GuideEvents.open(guide, level, grade(development.points))
					then
						for _, objective in guide.objectives do
							local held = (objective.action == "purchase" and paid[objective.target] ~= nil)
								or (objective.action == "equip" and worn[objective.target] == true)
							if held and (development.progress[objective.id] or 0) < objective.quantity then
								record({
									action = objective.action,
									target = objective.target,
									quantity = objective.quantity,
								})
							end
						end
					end
				end
				document.development = development
				return { ok = true }
			end)
			local retry = not recorded.ok and recorded.reason == "DOCUMENT_BUSY" and waited < DEVELOPMENT_WAIT_SECONDS
			if retry then
				waited += task.wait()
			end
		until not retry
		if not recorded.ok then
			warn("ForgeGuideEvent " .. actor .. " " .. receiptId .. " not recorded: " .. tostring(recorded.reason))
		end
		-- Guide xp/coins/items settle through the mission reward outbox (once per guide receipt).
		if recorded.ok and guideCompleted then
			archipelago.settleRewards(actor)
		end
		return recorded
	end
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
				local binding = awaiting[actor] and awaiting[actor][tostring(epoch) .. ":" .. requestId]
				if binding and binding.chapterId then
					local credited = journalFeed.accept({
						actor = actor,
						chapterId = binding.chapterId,
						receiptId = "g:" .. tostring(epoch) .. ":" .. requestId .. ":" .. item,
						committed = true,
						ok = true,
						action = "gather",
						target = item,
						quantity = quantity,
					})
					if
						not credited.ok
						and credited.reason ~= "CHAPTER_MISMATCH"
						and credited.reason ~= "WRONG_OBJECTIVE"
						and credited.reason ~= "AWAITING_CLAIM"
					then
						return false
					end
				end
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
			local admittedData = personalData(actor)
			local chapterId = if admittedData and admittedData.journal then admittedData.journal.active else nil
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
					local required = if node.gates then node.gates.characterLevel or 1 else 1
					if not progression or progression.level < required then
						return { ok = false, reason = "LEVEL_LOCKED", data = { level = required } }
					end
					for _, skill in if node.gates then node.gates.skillNodes or {} else {} do
						if not progression.paid[skill] then
							return { ok = false, reason = "SKILL_LOCKED", data = { skill = skill } }
						end
					end
					if node.tool then
						-- Same evidence as GatheringRuntime: a tool in hand or the worn weapon/tool slot (the t1+
						-- pickaxes carry no `tool` tag, so they are never a held Tool; copper needs pickaxe-t1).
						local equipped = CharacterRules.toolEvidence(
							data.gear,
							data.inventory.bag,
							world.services.survivalDeath.equipment(actor) or {}
						)
						local found = false
						for id, item in data.inventory.bag.items do
							found = found
								or (
									equipped[id] == true
									and item.durabilityMilli > 0
									and ToolTiers.accepts(content, node.tool, item.catalogId)
								)
						end
						if not found then
							return {
								ok = false,
								reason = "TOOL_UNAVAILABLE",
								data = { tool = node.tool, orBetter = ToolTiers.hasFamily(content, node.tool) },
							}
						end
					end
				end
				return admit()
			end
			local result = command(actor, args, context, expiresAt, resourceAdmission)
			if result.ok or (result.data and result.data.status == "pending") then
				awaiting[actor] = awaiting[actor] or {}
				awaiting[actor][tostring(context.sessionEpoch) .. ":" .. context.requestId] =
					{ epoch = context.sessionEpoch, requestId = context.requestId, chapterId = chapterId }
				creditGather(actor, context.sessionEpoch, context.requestId)
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
		roleWorld.journalAction = function(actor: string, objective: string)
			missionSequence += 1
			local action = "survival-coop:journal-interact"
			return session.command(actor, {
				requestId = "journal-world:" .. objective .. ":" .. tostring(seconds()) .. ":" .. tostring(
					missionSequence
				),
				sessionEpoch = session.commandEpoch(actor, action),
				action = action,
				args = { objective },
			})
		end
		for _, method in { "command", "commandServer" } do
			local command = session[method]
			-- Onboarding bag-paid build (see bagBuild): deposit the warehouse shortfall of the structure's
			-- cost from the bag, then send the reserve with the warehouse version that deposit produced.
			local function fromBag(actor: string, request: any): any
				-- A resend of the same request (lost answer) replays the rewritten args, not a conflict.
				local key = actor .. ":" .. tostring(request.sessionEpoch) .. ":" .. tostring(request.requestId)
				if bagSent[key] then
					return bagSent[key]
				end
				local definition = definitions[request.args[1]]
				local shared = session.snapshot(actor).survivalSettlement
				local data = personalData(actor)
				if not definition or not shared or not data or request.args[6] ~= shared.warehouse.version then
					return request
				end
				local moved = 0
				for _, cost in definition.cost do
					local stored = 0
					for itemId, item in shared.warehouse.items do
						if item.catalogId == cost.item then
							stored += Inventory.available(shared.warehouse, itemId)
						end
					end
					local short = cost.quantity - stored
					local stacks = {}
					for itemId, item in data.inventory.bag.items do
						if item.catalogId == cost.item then
							table.insert(stacks, itemId)
						end
					end
					table.sort(stacks)
					for _, itemId in stacks do
						local bag = personalData(actor).inventory.bag
						local quantity = math.min(short, Inventory.available(bag, itemId))
						if quantity <= 0 then
							continue
						end
						moved += 1
						buildDeposit[actor] = true
						local ok, result = pcall(command, actor, {
							requestId = request.requestId .. ":bag" .. moved,
							sessionEpoch = session.commandEpoch(actor, "survival-coop:transfer-deposit"),
							action = "survival-coop:transfer-deposit",
							args = { itemId, quantity },
						})
						buildDeposit[actor] = nil
						if not ok or not result.ok then
							return request
						end
						short -= quantity
					end
				end
				if moved == 0 then
					return request
				end
				local args = table.clone(request.args)
				args[6] = session.snapshot(actor).survivalSettlement.warehouse.version
				local sent = table.clone(request)
				sent.args = args
				bagSent[key] = sent
				return sent
			end
			session[method] = function(actor: string, request: any)
				if
					bagBuild
					and method == "command"
					and type(request) == "table"
					and request.action == "survival-coop:settlement-reserve"
					and type(request.args) == "table"
					and #request.args == 7
				then
					request = fromBag(actor, request)
				end
				local data = personalData(actor)
				local chapterId = if data and data.journal then data.journal.active else nil
				local action = string.gsub(request.action, "^survival%-coop:", "")
				local recipe: string? = nil
				if action == "craft-complete" and data and data.workshop then
					local entry = data.workshop.entries[request.args[1]]
					recipe = if entry then entry.job.recipeId else nil
				end
				-- Guide facts are read before the command consumes or moves what the event names.
				local guideFacts = {
					recipe = recipe,
					content = content,
					settlement = if action == "settlement-place"
						then session.snapshot(actor).survivalSettlement.settlement
						else nil,
					bag = if data then data.inventory.bag.items else nil,
					market = if data then data.market else nil,
					companions = if data then data.companions else nil,
					home = if homeOwner and string.sub(action, 1, 5) == "home-" then homeOwner.snapshot(actor) else nil,
				}
				local event: any = GuideEvents.event(action, request.args, guideFacts, { ok = true })
				if chapterId and (event or action == "gather") then
					local staged =
						journalFeed.stage(actor, tostring(request.sessionEpoch) .. ":" .. request.requestId, {
							chapterId = chapterId,
							epoch = request.sessionEpoch,
							requestId = request.requestId,
							action = request.action,
							args = request.args,
							origin = if method == "commandServer" then "server" else "client",
							event = event,
						})
					if not staged.ok then
						return staged
					end
				end
				local result = command(actor, request)
				-- The transfer authority folds warehouse reach into UNAUTHORIZED; name the reach so the
				-- player sees "walk to the warehouse" (p43 Studio: bag deposit showed a generic refusal).
				if
					(action == "transfer-deposit" or action == "transfer-withdraw")
					and not result.ok
					and result.reason == "UNAUTHORIZED"
					and not ports.warehouse(actor)
				then
					result = table.clone(result)
					result.reason = "WAREHOUSE_UNREACHABLE"
				end
				if chapterId then
					recoverJournal(actor)
				end
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
				local id = tostring(request.sessionEpoch) .. ":" .. tostring(request.requestId)
				if result.ok and data and Award(content, data.progression, action, id) ~= data.progression then
					session.personalTransaction(actor, function(raw)
						local d = raw.envelope.genres["survival-coop"].data
						d.progression = Award(content, d.progression, action, id)
						return raw
					end)
				end
				local commandOrigin = if method == "commandServer" then "server" else "client"
				-- Extension actions settle in their own aggregates (and replay from their own receipts);
				-- only personal-executor actions leave a personal ledger receipt to check here.
				event = GuideEvents.event(action, request.args, guideFacts, result)
				if event and result.ok and not GuideEvents.ledgered(action) then
					factoryPorts.recordDevelopment(
						actor,
						tostring(request.sessionEpoch) .. ":" .. request.requestId,
						event
					)
					return result
				end
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
				if event then
					factoryPorts.recordDevelopment(
						actor,
						tostring(request.sessionEpoch) .. ":" .. request.requestId,
						event
					)
					if chapterId then
						journalFeed.accept({
							actor = actor,
							chapterId = chapterId,
							receiptId = tostring(request.sessionEpoch) .. ":" .. request.requestId,
							committed = true,
							ok = true,
							action = event.action,
							target = event.target,
							quantity = event.quantity,
						})
					end
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
	end
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
			monetization = extensions[index]
		end
		if extension.id == "home" then
			homeOwner = extensions[index]
		end
	end
	factoryPorts.refreshWarehouse = function(actor)
		return if homeOwner then homeOwner.snapshot(actor) else nil
	end
	if not provision.admit then
		return factory, err
	end
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
