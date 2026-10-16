--!strict
-- Separate tribe durability boundary, never a player CommandStage. The caller
-- authenticates ingress/spatial ports; only warehouse materials pay build costs.
local Transaction = require("../../../core/domain/settlement/Transaction")
local Settlement = require("../../../core/domain/settlement/Settlement")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Ledger = require("../../../core/domain/command/Ledger")
local SerializedData = require("../../../core/domain/genre/SerializedData")
local Shared = require("../../../core/domain/genre/Contract")
local FencedStore = require("../../../core/infra/data/FencedStore")
local Workshop = require("./Workshop")
local Content = require("../../../core/domain/survival/Content")
local Job = require("../../../core/domain/crafting/Job")
local Events = require("../../../core/infra/analytics/Events")
local M = {}
export type Config = {
	key: string,
	initial: Transaction.State,
	catalog: Catalog.Catalog,
	definitions: { [string]: Settlement.Definition },
	now: () -> number,
	windowSeconds: number?,
	maxOutcomes: number?,
	-- Explicit server consent, applied once to a new or untouched settlement.
	acceptedMembers: { string }?,
	verifyPlacement: ((string, Settlement.Placement, Settlement.State) -> boolean)?,
	publish: ((Settlement.State) -> ())?,
	workshop: {
		content: Content.Document,
		revision: string,
		-- Trusted, pure server station proof, rechecked against the commit state.
		verifyStation: (string, string, Transaction.State) -> Workshop.Access?,
	}?,
	-- Trusted server geometry/service proof, never a remote boolean. Called in
	-- the source acceptance callback; must be pure, non-yielding and replay-safe.
	verifyTransfer: ((string, any) -> boolean)?,
	-- Optional core analytics emitter: build (place) and craft (workshop
	-- complete) events after the tribe commit is durable; replays never emit.
	analytics: Events.Emitter?,
}
export type TransferPort = {
	profile: () -> FencedStore.Profile,
	update: (TransferPort, FencedStore.Profile, FencedStore.Transform) -> (FencedStore.Profile?, string?),
	acquire: (TransferPort, string, FencedStore.Transform) -> (FencedStore.Profile?, string?),
	authority: (FencedStore.Data, string, number, number, any) -> boolean,
}
export type CommandOptions = {
	origin: "internal" | "client" | "server",
	admit: (() -> Shared.Result)?,
}
export type Runtime = {
	epoch: (string) -> (number?, string?),
	epochWindow: (string, number?) -> ({ epoch: number, expiresAt: number, membershipRevision: number }?, string?),
	command: (string, string, { any }, Shared.CommandContext, CommandOptions?) -> Shared.Result,
	snapshot: (string) -> (Transaction.State?, string?),
	link: () -> { tribeId: string },
	close: () -> Shared.Result,
	transferStore: () -> TransferPort,
}
local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end
local function authorized(state: Settlement.State, actor: string): boolean
	return state.roles[actor] ~= nil or (actor == state.ownerId and next(state.roles) == nil)
end
local function failure(reason: string): Shared.Result
	return { ok = false, reason = reason }
end

function M.new(config: Config, store: FencedStore.Store): (Runtime?, string?)
	local ttl, cap = config.windowSeconds or 86400, config.maxOutcomes or 4096
	assert(Catalog.integer(ttl, 1, 86400) and Catalog.integer(cap, 1, 4096), "invalid receipt policy")
	local definitions = copy(config.definitions)
	local catalog = config.catalog
	local workshop = if config.workshop then copy(config.workshop) else nil
	if workshop then
		assert(Catalog.identity(workshop.revision), "INVALID_WORKSHOP_REVISION")
		local raw = copy(workshop.content)
		raw.survival_content, raw.version = raw.version, nil
		local canonical, errors = Content.canonicalize(raw)
		assert(canonical, table.concat(errors, "; "))
		workshop.content = canonical
		assert(Ledger.canonical(Job.catalog(canonical)) == Ledger.canonical(catalog), "WORKSHOP_CATALOG_MISMATCH")
	end
	local initial = Transaction.snapshot(config.initial)
	assert(initial.workshops == nil or next(initial.workshops) == nil, "INITIAL_WORKSHOP_JOBS_FORBIDDEN")
	initial.settlement =
		Settlement.fromSave(Settlement.save(initial.settlement), initial.settlement.config, definitions)
	for _, definition in definitions do
		for _, cost in definition.cost do
			assert(catalog[cost.item] and Catalog.integer(cost.quantity, 1, 1000000000), "invalid catalog build cost")
		end
	end
	local tribeId = initial.settlement.config.tribeId
	local function clock(): number
		local now = config.now()
		local maximum = if workshop then math.floor((2 ^ 53 - 1 - Content.CAPS.millis) / 1000) else 2 ^ 53 - 86401
		assert(Catalog.integer(now, 0, maximum), "invalid server clock")
		return now
	end
	local profile, loadError = store:acquire(config.key, function(data)
		if next(data) == nil then
			data = { version = 1, aggregate = Transaction.snapshot(initial), actors = {}, operationIds = {} }
		end
		if config.acceptedMembers and not data.membersProvisioned then
			-- A legacy settlement with membership history must never resurrect a
			-- departed member. The marker and initial grants commit together.
			local settlement = data.aggregate.settlement
			if settlement.membershipRevision == 0 then
				local members = table.clone(config.acceptedMembers)
				table.sort(members)
				for _, actor in members do
					assert(Catalog.identity(actor), "INVALID_ACCEPTED_MEMBER")
					if actor ~= settlement.ownerId then
						local invited, reason = Settlement.membership(
							settlement,
							settlement.ownerId,
							settlement.version,
							settlement.membershipRevision,
							"invite",
							actor
						)
						assert(invited, reason)
						settlement = invited
					end
				end
				data.aggregate.settlement = settlement
			end
			data.membersProvisioned = true
		end
		assert(
			data.version == 1 and type(data.actors) == "table" and type(data.operationIds) == "table",
			"unsupported settlement save"
		)
		assert(data.aggregate.settlement.config.tribeId == tribeId, "tribe identity mismatch")
		data.aggregate.settlement =
			Settlement.fromSave(Settlement.save(data.aggregate.settlement), initial.settlement.config, definitions)
		assert(Transaction.validateOwnership(data.aggregate) == nil, "invalid storage ownership")
		data.aggregate.warehouse = Inventory.fromSave(Inventory.save(data.aggregate.warehouse), catalog)
		local jobs: { [string]: boolean } = {}
		for actor, raw in data.aggregate.workshops or {} do
			assert(workshop and data.actors[actor], "WORKSHOP_CONFIG_REQUIRED")
			local restored = Workshop.fromSave(raw, actor, { [data.aggregate.warehouse.id] = data.aggregate.warehouse })
			for id in restored.entries do
				assert(not jobs[id], "DUPLICATE_WORKSHOP_JOB")
				jobs[id] = true
			end
			local saved = Workshop.save(restored)
			assert(Catalog.integer(raw.recoveryUntil or 0, 0, 2 ^ 53 - 1), "INVALID_RECOVERY_HORIZON")
			saved.recoveryUntil = raw.recoveryUntil
			data.aggregate.workshops[actor] = saved
		end
		for id in data.aggregate.warehouse.reservations do
			if string.match(id, "^w%d+:") then
				assert(jobs[id], "ORPHAN_WORKSHOP_RESERVATION")
			end
		end
		for id, placement in data.aggregate.settlement.reservations do
			local amounts: { [string]: number } = {}
			local reserved = data.aggregate.warehouse.reservations[id]
			if #placement.definition.cost > 0 then
				assert(reserved, "MISSING_BUILD_RESERVATION")
				for itemId, quantity in reserved do
					local item = data.aggregate.warehouse.items[itemId]
					amounts[item.catalogId] = (amounts[item.catalogId] or 0) + quantity
				end
			else
				assert(reserved == nil, "UNEXPECTED_BUILD_RESERVATION")
			end
			for _, cost in placement.definition.cost do
				assert(amounts[cost.item] == cost.quantity, "BUILD_RESERVATION_COST_MISMATCH")
				amounts[cost.item] = nil
			end
			assert(next(amounts) == nil, "UNEXPECTED_BUILD_INGREDIENT")
		end
		local buildPrefix = "build:" .. tostring(#tribeId) .. ":" .. tribeId .. ":"
		for owner in data.aggregate.warehouse.reservations do
			if string.sub(owner, 1, #buildPrefix) == buildPrefix then
				assert(data.aggregate.settlement.reservations[owner], "ORPHAN_BUILD_RESERVATION")
			end
		end
		if data.aggregate.structureContents then
			for id, contents in data.aggregate.structureContents do
				data.aggregate.structureContents[id] = Inventory.fromSave(Inventory.save(contents), catalog)
			end
		end
		for _, ledger in data.actors do
			assert(Ledger.valid(ledger, SerializedData.data), "invalid tribe command ledger")
		end
		for id, origin in data.operationIds do
			assert(
				type(id) == "string"
					and data.aggregate.settlement.usedIds[id]
					and type(origin) == "table"
					and type(origin.actor) == "string"
					and data.actors[origin.actor]
					and Catalog.integer(origin.epoch, 0, data.actors[origin.actor].epoch),
				"invalid operation identity"
			)
		end
		return data
	end)
	if not profile then
		return nil, loadError
	end
	local token: FencedStore.Profile = profile
	local closed = false
	-- One durable renew in flight per settlement, plus a short cooldown after a
	-- failed renew: snapshot callers run per frame (Heartbeat, state pushes),
	-- and stacked renews behind a slow transport build a backlog that cannot
	-- drain, starving every other key on the shared loopback.
	local renewing = false
	local renewBackoffUntil = 0
	local admissions: { [string]: string } = {}
	local executing: { [string]: boolean } = {}
	local runtime = {} :: Runtime
	local function publish(): string?
		if config.publish then
			local ok, err = pcall(function()
				config.publish(Settlement.snapshot(token.data.aggregate.settlement))
				return nil
			end)
			if not ok then
				return tostring(err)
			end
		end
		return nil
	end
	local publicationError = publish()
	if publicationError then
		store:release(token)
		return nil, "SETTLEMENT_PUBLICATION_FAILED:" .. publicationError
	end
	-- This lens is internal to the server coordinator. It is not a remote API
	-- or a second owner. Transforms may change only inventory/transfer receipts;
	-- the current authoritative grid, actors and command ledgers stay in place.
	local function project(data: FencedStore.Data): FencedStore.Data
		local epochs = {}
		for actor, ledger in data.actors do
			local epoch = ledger.epochs[tostring(ledger.epoch)]
			epochs[actor] = { epoch = ledger.epoch, expiresAt = epoch.expiresAt }
		end
		return {
			inventory = Inventory.save(data.aggregate.warehouse),
			itemTransfers = copy(data.itemTransfers),
			transferGrants = copy(data.transferGrants or { version = 1, entries = {} }),
			authority = {
				tribeId = tribeId,
				roles = copy(data.aggregate.settlement.roles),
				membershipRevision = data.aggregate.settlement.membershipRevision,
				epochs = epochs,
			},
		}
	end
	local function projectedProfile(value: FencedStore.Profile): FencedStore.Profile
		return {
			key = value.key,
			sessionId = value.sessionId,
			generation = value.generation,
			data = project(value.data),
			-- Lease bookkeeping travels with the shell: the lens projects DATA,
			-- not fencing metadata. Dropping these would reset the caller into a
			-- state where every snapshot performs a real renew write again.
			leaseExpiresAt = value.leaseExpiresAt,
			leaseRenewed = value.leaseRenewed,
		}
	end
	local function transformCurrent(transform: FencedStore.Transform): FencedStore.Transform
		return function(data)
			local projected = transform(project(data))
			data.aggregate.warehouse = Inventory.fromSave(projected.inventory, catalog)
			data.itemTransfers = copy(projected.itemTransfers)
			assert(
				projected.transferGrants.version == 1 and type(projected.transferGrants.entries) == "table",
				"INVALID_TRANSFER_GRANTS"
			)
			data.transferGrants = copy(projected.transferGrants)
			return data
		end
	end
	local port = {} :: TransferPort
	function port.profile()
		return projectedProfile(token)
	end
	function port:update(expected, transform)
		if closed then
			return nil, "CLOSED"
		end
		if
			expected.key ~= token.key
			or expected.sessionId ~= token.sessionId
			or expected.generation ~= token.generation
		then
			return nil, "STALE_TRANSFER_TOKEN"
		end
		local updated, err = store:update(expected, transformCurrent(transform))
		if not updated then
			return nil, err
		end
		token = updated
		return projectedProfile(updated), nil
	end
	function port:acquire(key, transform)
		if closed then
			return nil, "CLOSED"
		end
		if key ~= token.key then
			return nil, "WRONG_TRIBE_KEY"
		end
		-- Cleanup fences older destination callbacks. Install the new generation
		-- here immediately, including a transform that returns a refusal receipt.
		local updated, err = store:acquire(key, transformCurrent(transform))
		if not updated then
			return nil, err
		end
		token = updated
		return projectedProfile(updated), nil
	end
	function port.authority(data, actor, epoch, revision, proof)
		local authority = data.authority
		local issued = if authority then authority.epochs[actor] else nil
		local verify = config.verifyTransfer
		return authority ~= nil
			and authority.tribeId == tribeId
			and authority.roles[actor] ~= nil
			and authority.membershipRevision == revision
			and issued ~= nil
			and issued.epoch == epoch
			and clock() < issued.expiresAt
			and verify ~= nil
			and verify(actor, proof)
	end
	function runtime.transferStore()
		return port
	end
	function runtime.link()
		return { tribeId = tribeId }
	end
	function runtime.epoch(actor)
		if closed then
			return nil, "CLOSED"
		end
		-- Fast path: the durable transform only ever creates, extends or prunes.
		-- When the local fenced snapshot already answers "authorized, not
		-- expired, nothing to prune", the round-trip cannot change anything —
		-- yet this runs for every action on every state push, and each missed
		-- round-trip is an HttpService request on studio-local loopback.
		local settlementView = token.data.aggregate.settlement
		local existing = token.data.actors[actor]
		if existing ~= nil then
			local now = clock()
			local current = existing.epochs[tostring(existing.epoch)]
			if current ~= nil and now < current.expiresAt then
				if not authorized(settlementView, actor) then
					return nil, "FORBIDDEN"
				end
				local raw = if token.data.aggregate.workshops then token.data.aggregate.workshops[actor] else nil
				local workshopPending = raw ~= nil and now >= (raw.recoveryUntil or 0)
				if not workshopPending then
					local floor = Ledger.retentionFloor(existing, now)
					local idsPending = false
					for id, origin in token.data.operationIds do
						if
							origin.actor == actor
							and origin.epoch < floor
							and not settlementView.reservations[id]
							and not settlementView.structures[tribeId .. ":" .. id]
						then
							idsPending = true
							break
						end
					end
					if not idsPending then
						return existing.epoch, nil
					end
				end
			end
		end
		local issued: number? = nil
		local refusal: string? = nil
		local updated, err = store:update(token, function(data)
			issued, refusal = nil, nil
			if not authorized(data.aggregate.settlement, actor) then
				refusal = "FORBIDDEN"
				return data
			end
			local now = clock()
			local ledger: Ledger.Ledger? = data.actors[actor]
			if not ledger then
				ledger = {
					version = 2,
					epoch = 0,
					stateVersion = 0,
					epochs = { ["0"] = { createdAt = now, expiresAt = now + ttl, outcomes = {} } },
				}
				data.actors[actor] = ledger
			elseif now >= ledger.epochs[tostring(ledger.epoch)].expiresAt then
				for id, epoch in ledger.epochs do
					for requestId, outcome in epoch.outcomes do
						if now >= outcome.expiresAt then
							epoch.outcomes[requestId] = nil
						end
					end
					if now >= epoch.expiresAt and next(epoch.outcomes) == nil then
						ledger.epochs[id] = nil
					end
				end
				ledger.epoch += 1
				ledger.epochs[tostring(ledger.epoch)] = { createdAt = now, expiresAt = now + ttl, outcomes = {} }
			end
			local current = assert(ledger, "issued actor ledger")
			issued = current.epoch
			-- Receipt floor, not wall-clock guesses: a late committed receipt can
			-- retain its old epoch after acceptance has expired. Active placements
			-- always retain identity even after every associated receipt expires.
			local floor = Ledger.retentionFloor(current, now)
			local raw = if data.aggregate.workshops then data.aggregate.workshops[actor] else nil
			if raw and now >= (raw.recoveryUntil or 0) then
				local restored =
					Workshop.fromSave(raw, actor, { [data.aggregate.warehouse.id] = data.aggregate.warehouse })
				data.aggregate.workshops[actor] = Workshop.save(Workshop.prune(restored, floor))
			end
			local settlement = data.aggregate.settlement
			for id, origin in data.operationIds do
				if
					origin.actor == actor
					and origin.epoch < floor
					and not settlement.reservations[id]
					and not settlement.structures[tribeId .. ":" .. id]
				then
					settlement.usedIds[id] = nil
					data.operationIds[id] = nil
				end
			end
			return data
		end)
		if not updated then
			return nil, err
		end
		token = updated
		return issued, refusal
	end
	function runtime.epochWindow(actor, requestedEpoch)
		local epoch, err = runtime.epoch(actor)
		if epoch == nil then
			return nil, err
		end
		if requestedEpoch ~= nil and requestedEpoch ~= epoch then
			return nil, "REQUEST_EXPIRED"
		end
		return {
			epoch = epoch,
			expiresAt = token.data.actors[actor].epochs[tostring(epoch)].expiresAt,
			membershipRevision = token.data.aggregate.settlement.membershipRevision,
		},
			nil
	end
	function runtime.snapshot(actor)
		if closed then
			return nil, "CLOSED"
		end
		if renewing or clock() < renewBackoffUntil then
			-- Serve the in-memory aggregate: concurrent callers would read the
			-- same pre-renew token anyway, and this keeps per-frame snapshot
			-- demand off the durable transport while a renew is pending.
			if not authorized(token.data.aggregate.settlement, actor) then
				return nil, "FORBIDDEN"
			end
			return Transaction.snapshot(token.data.aggregate), nil
		end
		renewing = true
		local refreshed, err = store:renew(token)
		renewing = false
		if not refreshed then
			renewBackoffUntil = clock() + 1
			return nil, err
		end
		token = refreshed
		if not authorized(token.data.aggregate.settlement, actor) then
			return nil, "FORBIDDEN"
		end
		-- Repair a prior postcommit publication failure from confirmed state.
		local publishErr = publish()
		if publishErr then
			return nil, "SETTLEMENT_PUBLICATION_FAILED:" .. publishErr
		end
		return Transaction.snapshot(token.data.aggregate), nil
	end
	function runtime.command(actor, action, args, context, options)
		if closed then
			return failure("CLOSED")
		end
		if context.actorId ~= actor then
			return failure("FORBIDDEN")
		end
		if
			not Catalog.identity(context.requestId)
			or not Catalog.integer(context.sessionEpoch, 0, 2 ^ 53 - 2)
			or not SerializedData.data(args)
		then
			return failure("INVALID_COMMAND")
		end
		local crafting = table.find(
			{ "workshop-reserve", "workshop-start", "workshop-complete", "workshop-cancel" },
			action
		) ~= nil
		local arity = if crafting then 5 elseif action == "reserve" then 7 elseif action == "demolish" then 4 else 3
		if
			not crafting
			and not table.find(
				{ "invite", "leave", "kick", "transfer-owner", "rejoin", "reserve", "place", "cancel", "demolish" },
				action
			)
		then
			return failure("UNKNOWN_ACTION")
		end
		if #args ~= arity or not Catalog.identity(args[1]) then
			return failure("INVALID_ARGUMENTS")
		end
		if crafting and not Catalog.identity(args[2]) then
			return failure("INVALID_ARGUMENTS")
		end
		for index = if crafting then 3 else 2, arity do
			if not Catalog.integer(args[index], 0, 2 ^ 53 - 2) then
				return failure("INVALID_ARGUMENTS")
			end
		end
		local origin = if options then options.origin else "internal"
		local binding = (if origin == "internal" then "" else origin .. ":")
			.. Ledger.canonical({ action = action, args = args })
		local admissionId =
			Ledger.canonical({ epoch = context.sessionEpoch, request = context.requestId, binding = binding })
		if executing[actor] then
			return failure("COMMAND_PENDING")
		end
		-- External ingress admission is intentionally outside every backend callback.
		-- This refresh is authoritative, but not authorization for the later write:
		-- the mutation callback below must repeat membership/epoch/receipt checks.
		if options then
			executing[actor] = true
			local current, refreshError = store:renew(token)
			if not current then
				executing[actor] = nil
				return failure("COMMIT_FAILED:" .. tostring(refreshError))
			end
			token = current
			local data = current.data
			local ledger = data.actors[actor]
			local epoch = if ledger then ledger.epochs[tostring(context.sessionEpoch)] else nil
			local receipt = if epoch then epoch.outcomes[context.requestId] else nil
			local now = clock()
			local refused: Shared.Result? = nil
			if not authorized(data.aggregate.settlement, actor) then
				refused = failure("FORBIDDEN")
			elseif receipt and now < receipt.expiresAt then
				refused = if receipt.binding == binding then copy(receipt.result) else failure("REQUEST_CONFLICT")
			elseif not epoch or now >= epoch.expiresAt or receipt then
				refused = failure("REQUEST_EXPIRED")
			else
				local count = 0
				for _ in epoch.outcomes do
					count += 1
				end
				if count >= cap then
					refused = failure("REQUEST_CAPACITY")
				end
			end
			if refused then
				if admissions[actor] == admissionId then
					admissions[actor] = nil
				end
				executing[actor] = nil
				return refused
			end
			if admissions[actor] and admissions[actor] ~= admissionId then
				executing[actor] = nil
				return failure("COMMAND_PENDING")
			end
			if not admissions[actor] then
				local admit = options.admit
				if origin == "client" and not admit then
					executing[actor] = nil
					return failure("ADMISSION_REQUIRED")
				end
				if admit then
					local ok, admitted = pcall(admit)
					if not ok then
						executing[actor] = nil
						return failure("ADMISSION_FAILED")
					end
					if not admitted.ok then
						executing[actor] = nil
						return admitted
					end
				end
				admissions[actor] = admissionId
			end
		end
		local response: Shared.Result = failure("UNCONFIRMED")
		local observed: { { name: string, fields: Events.Fields } } = {}
		local updated, err = store:update(token, function(data)
			response = failure("UNCONFIRMED")
			observed = {}
			local state: Transaction.State = data.aggregate
			if not authorized(state.settlement, actor) then
				response = failure("FORBIDDEN")
				return data
			end
			local now = clock()
			local ledger: Ledger.Ledger? = data.actors[actor]
			local epoch = if ledger then ledger.epochs[tostring(context.sessionEpoch)] else nil
			local receipt = if epoch then epoch.outcomes[context.requestId] else nil
			if receipt and now < receipt.expiresAt then
				response = if receipt.binding == binding then copy(receipt.result) else failure("REQUEST_CONFLICT")
				return data
			end
			if not ledger or not epoch or now >= epoch.expiresAt or receipt then
				response = failure("REQUEST_EXPIRED")
				return data
			end
			local count = 0
			for _ in epoch.outcomes do
				count += 1
			end
			if count >= cap then
				response = failure("REQUEST_CAPACITY")
				return data
			end
			local commandId = string.format("%d:%s:%d:%s", #actor, actor, context.sessionEpoch, context.requestId)
			local candidate: Transaction.State? = nil
			local reason: string? = nil
			local resultData: Shared.StateData? = nil
			if crafting then
				if not workshop then
					reason = "WORKSHOP_UNAVAILABLE"
				elseif state.settlement.roles[actor] == nil then
					reason = "FORBIDDEN"
				elseif args[3] ~= state.settlement.version then
					reason = "STALE_SETTLEMENT_VERSION"
				elseif args[4] ~= state.warehouse.version then
					reason = "STALE_WAREHOUSE_VERSION"
				elseif args[5] ~= state.settlement.membershipRevision then
					reason = "STALE_MEMBERSHIP_REVISION"
				else
					local author = if action == "workshop-reserve" then actor else args[2]
					local raw = if state.workshops then state.workshops[author] else nil
					local jobs = if raw
						then Workshop.fromSave(raw, author, { [state.warehouse.id] = state.warehouse })
						else Workshop.new(author)
					local jobContext =
						{ actorId = author, sessionEpoch = context.sessionEpoch, requestId = context.requestId }
					local crafted: Workshop.Candidate? = nil
					if action == "workshop-reserve" then
						local access = workshop.verifyStation(actor, args[2], Transaction.snapshot(state))
						if not access then
							reason = "STATION_UNAVAILABLE"
						else
							crafted, reason = Workshop.reserve(
								jobs,
								state.warehouse,
								jobContext,
								workshop.content,
								workshop.revision,
								args[1],
								now * 1000,
								access
							)
						end
					elseif author ~= actor and (action ~= "workshop-cancel" or state.settlement.ownerId ~= actor) then
						reason = "FORBIDDEN"
					else
						if author ~= actor then
							jobContext.sessionEpoch = jobs.epoch
						end
						crafted, reason = Workshop.transition(
							jobs,
							state.warehouse,
							jobContext,
							args[1],
							string.sub(action, 10),
							now * 1000
						)
					end
					if crafted then
						local changed = Transaction.snapshot(state)
						local saved = Workshop.save(crafted.jobs)
						saved.recoveryUntil = math.max(
							if raw then raw.recoveryUntil or 0 else 0,
							if author ~= actor then now + ttl else 0
						)
						changed.workshops = changed.workshops or {}
						(changed.workshops :: { [string]: any })[author] = saved
						changed.warehouse = crafted.inventory
						candidate = changed
						reason = crafted.reason
						resultData = { jobId = crafted.jobId, state = crafted.jobs.entries[crafted.jobId].job.state }
						local job = crafted.jobs.entries[crafted.jobId].job
						if action == "workshop-complete" and reason == nil and job.state == "Committed" then
							table.insert(observed, {
								name = "craft",
								fields = {
									actorId = actor,
									recipeId = job.recipeId,
									jobId = crafted.jobId,
									settlementId = tribeId,
									atMillis = now * 1000,
								},
							})
						end
					end
				end
			elseif table.find({ "invite", "leave", "kick", "transfer-owner", "rejoin" }, action) then
				local operation = if action == "kick"
					then "revoke"
					elseif action == "transfer-owner" then "transferOwner"
					else action
				local target = if action == "leave" or action == "rejoin" then actor else args[1]
				local settlement, membershipError =
					Settlement.membership(state.settlement, actor, args[2], args[3], operation, target)
				reason = membershipError
				if settlement then
					local changed = Transaction.snapshot(state)
					changed.settlement = settlement
					candidate = changed
				end
			elseif action == "reserve" then
				local definition = definitions[args[1]]
				if not definition then
					reason = "UNKNOWN_STRUCTURE"
				else
					candidate, reason = Transaction.reserve(state, catalog, {
						actorId = actor,
						commandId = commandId,
						settlementVersion = args[5],
						warehouseVersion = args[6],
						membershipRevision = args[7],
					}, { definition = definition, x = args[2], z = args[3], rotation = args[4] })
					local reservedId = Transaction.reservationId(tribeId, commandId)
					resultData = { reservationId = reservedId }
					if candidate then
						if
							config.verifyPlacement
							and not config.verifyPlacement(
								actor,
								candidate.settlement.reservations[reservedId],
								Settlement.snapshot(state.settlement)
							)
						then
							candidate, reason = nil, "PLACEMENT_UNREACHABLE"
						else
							data.operationIds[reservedId] = { actor = actor, epoch = context.sessionEpoch }
						end
					end
				end
			elseif action == "place" or action == "cancel" or action == "demolish" then
				local txContext: Transaction.Context = {
					actorId = actor,
					commandId = commandId,
					settlementVersion = args[2],
					warehouseVersion = args[3],
					membershipRevision = args[4] or state.settlement.membershipRevision,
				}
				if action == "place" then
					candidate, reason = Transaction.commit(state, catalog, txContext, args[1])
					if
						candidate
						and config.verifyPlacement
						and not config.verifyPlacement(
							actor,
							state.settlement.reservations[args[1]],
							Settlement.snapshot(state.settlement)
						)
					then
						candidate, reason = nil, "PLACEMENT_UNREACHABLE"
					end
					local reservation = state.settlement.reservations[args[1]]
					if candidate and reservation then
						table.insert(observed, {
							name = "build",
							fields = {
								actorId = actor,
								structureId = reservation.definition.id,
								placementId = args[1],
								settlementId = tribeId,
								atMillis = now * 1000,
							},
						})
					end
				elseif action == "cancel" then
					candidate, reason = Transaction.cancel(state, txContext, args[1])
				else
					candidate, reason = Transaction.demolish(state, catalog, txContext, args[1])
				end
			else
				reason = "UNKNOWN_ACTION"
			end
			ledger.stateVersion += 1
			response = {
				ok = candidate ~= nil,
				reason = reason,
				stateVersion = ledger.stateVersion,
				data = if candidate then resultData else nil,
			}
			if candidate then
				data.aggregate = candidate
			else
				observed = {}
			end
			epoch.outcomes[context.requestId] = {
				binding = binding,
				result = copy(response),
				createdAt = now,
				expiresAt = now + (epoch.expiresAt - epoch.createdAt),
			}
			return data
		end)
		if not updated then
			executing[actor] = nil
			return failure("COMMIT_FAILED:" .. tostring(err))
		end
		token = updated
		admissions[actor], executing[actor] = nil, nil
		if config.analytics then
			for _, event in observed do
				config.analytics:emit(event.name, event.fields)
			end
		end
		local notificationError = publish()
		if notificationError then
			response = copy(response)
			response.data = response.data or {}
			(response.data :: Shared.StateData).notificationError = notificationError
		end
		return copy(response)
	end
	function runtime.close()
		if closed then
			return failure("CLOSED")
		end
		local released, err = store:release(token)
		if not released then
			return failure("COMMIT_FAILED:" .. tostring(err))
		end
		closed = true
		return { ok = true }
	end
	return runtime, nil
end
return M
