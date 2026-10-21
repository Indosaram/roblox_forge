--!strict
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local Bootstrap = require(Forge.genres["survival-coop"].module.SurvivalBootstrap)
local Gathering = require(Forge.genres["survival-coop"].module.Gathering)
local Settlement = require(Forge.core.domain.settlement.Settlement)
local Inventory = require(Forge.core.domain.inventory.Inventory)
local Job = require(Forge.core.domain.crafting.Job)
local Clock = require(Forge.core.infra.genre.Clock)
local Wildlife = require(Forge.genres["survival-coop"].module.Wildlife)
return function(content: any, source, world, backend, clock, options, provision, wildlifePolicy): (any, string?)
	-- The rendered module also carries capability metadata, not domain content.
	content = table.clone(content)
	content.capability = nil
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
	local factory, err = Bootstrap.new({
		sourceKey = prefix .. ":" .. source.sourceKey,
		initial = Gathering.new(source.worldRevision, content, source.nodes),
		content = content,
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
		return port
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
