--!strict
local Contract = require("../../domain/genre/Contract")
local Executor = require("../../domain/genre/Executor")
local ProfileSchema = require("../../domain/state/ProfileSchema")
local ProfileStore = require("../data/ProfileStore")
local Options = require("./Options")
local Ledger = require("../../domain/command/Ledger")
local PersonalAggregate = require("../data/PersonalAggregate")
local FencedStore = require("../data/FencedStore")
local M = {}
export type ActorLifecycle = {
	drain: ((string) -> Contract.Result)?,
	releaseActor: ((string) -> Contract.Result)?,
	resumeActor: ((string) -> Contract.Result)?,
}
-- Bootstrap clones extension ports before validation. Key the lifecycle by the
-- command capability (which survives a clone), not by that transient table.
local actorLifecycles: { [any]: ActorLifecycle } = setmetatable({}, { __mode = "k" }) :: any
function M.registerLifecycle(extension: any): any
	local lifecycle: ActorLifecycle = {
		drain = extension.drain,
		releaseActor = extension.releaseActor,
		resumeActor = extension.resumeActor,
	}
	actorLifecycles[extension.command] = lifecycle
	extension.drain, extension.releaseActor, extension.resumeActor = nil, nil, nil
	return setmetatable(extension, { __index = lifecycle })
end
function M.lifecycle(extension: Contract.Extension): ActorLifecycle
	return actorLifecycles[extension.command] or {}
end
export type LifecycleResult = Executor.LifecycleResult
export type PersonalTransfer = {
	personal: PersonalAggregate.Store,
	profile: () -> FencedStore.Profile,
	install: (FencedStore.Profile) -> (),
}
export type Session = {
	join: (string) -> LifecycleResult,
	close: (string) -> LifecycleResult,
	prepareHandoff: (string) -> LifecycleResult,
	resumeHandoff: (string) -> LifecycleResult,
	completeHandoff: (string) -> LifecycleResult,
	save: (string) -> Contract.Result,
	dispatch: (string, any, any) -> Contract.Result,
	dispatchServer: (string, any, any) -> Contract.Result,
	command: (string, any) -> (Contract.Result, { notificationError: string }?),
	commandServer: (string, any) -> (Contract.Result, { notificationError: string }?),
	commandEpoch: (string, string?) -> number?,
	personalTransfer: (string) -> PersonalTransfer?,
	committedReceipt: (string, number, string, string, { any }, string) -> Contract.Result?,
	recoverTransfers: (string, number) -> Contract.Result,
	advance: (number) -> (),
	snapshot: (string) -> Contract.StateData,
	envelope: (string) -> Contract.SaveEnvelope,
	restore: (string, any) -> LifecycleResult,
	members: () -> { string },
}
local function failure(reason: string?): LifecycleResult
	return { ok = false, reason = reason or "profile operation failed" }
end
function M.migrate(raw: any, contracts: { Contract.RuntimeContract }): Contract.SaveEnvelope
	-- Pure/replayable UpdateAsync callback: no join, hooks, or reward grants.
	if raw ~= nil then
		local errors = Executor.validateSave(raw, contracts)
		assert(#errors == 0, table.concat(errors, "; "))
	end
	return ProfileSchema.migrate(raw, 1, function()
		return { version = 1, genres = {} }
	end, {}) :: Contract.SaveEnvelope
end
function M.new(
	options: Options.Options,
	backend: ProfileStore.Backend,
	storeOptions: ProfileStore.Options,
	services: Contract.Services,
	durable: Ledger.Policy?
): Session
	Options.validate(options)
	local ttl = if durable then durable.windowSeconds or 86400 else 86400
	local limit = if durable then durable.maxOutcomes or 4096 else 4096
	if durable then
		assert(Executor.finite(ttl) and ttl >= 1, "invalid command window")
		assert(limit >= 1 and limit <= 4096 and limit % 1 == 0, "invalid command limit")
	end
	local executor = Executor.new(options.packConfig, options.contracts, services, options.hooks)
	local extensions: { Contract.Extension } = services.survivalExtensions or {}
	local function extensionFor(action: string?): Contract.Extension?
		if action == nil then
			return nil
		end
		for _, extension in extensions do
			if extension.handles(action) then
				return extension
			end
		end
		return nil
	end
	local store = ProfileStore.new(backend, storeOptions)
	local personal: PersonalAggregate.Store? = nil
	local tokens: { [string]: FencedStore.Profile } = {}
	local admissions: { [string]: { requestId: string, binding: string } } = {}
	if durable and durable.personal then
		executor.requireHydration()
		assert(services.encode ~= nil, "personal aggregate requires encoder")
		personal = PersonalAggregate.new(backend, {
			namespace = durable.personal.namespace,
			inventoryPath = durable.personal.inventoryPath,
			validateEnvelope = function(value)
				return #Executor.validateSave(value, options.contracts) == 0
			end,
			store = {
				sessionId = storeOptions.sessionId,
				leaseSeconds = storeOptions.lockTimeout,
				now = function()
					return math.floor(storeOptions.now())
				end,
				budget = { encode = services.encode },
			},
		})
	end
	local profiles: { [string]: ProfileStore.Profile } = {}
	local joined: { [string]: boolean } = {}
	local leaving: { [string]: boolean } = {}
	local departed: { [string]: boolean } = {}
	local releasedActors: { [string]: { [string]: boolean } } = {}
	local busy: { [string]: boolean } = {}
	local captureErrors: { [string]: string } = {}
	local ledgers: { [string]: Ledger.Ledger } = {}
	local pending: {
		[string]: {
			envelope: Contract.SaveEnvelope,
			stage: Contract.CommandStage,
			requestId: string,
			binding: string,
			expected: number?,
		},
	} =
		{}
	local session: Session = {} :: Session
	local scheduled: { [string]: any } = {}
	local function flushServerEvent(id: string): LifecycleResult
		if not durable or not durable.tickAction or not joined[id] then
			return { ok = true }
		end
		local request = scheduled[id]
		if request == nil then
			if next(pending) then
				return failure("COMMAND_PENDING")
			end
			local event = executor.pendingServerEvent(id, durable.tickAction)
			if event == nil then
				return { ok = true }
			end
			local epoch = session.commandEpoch(id)
			if epoch == nil then
				return failure("COMMAND_PENDING")
			end
			request = { requestId = event, sessionEpoch = epoch, action = durable.tickAction, args = {} }
			scheduled[id] = request
		end
		local result, diagnostic = session.commandServer(id, request)
		if result.stateVersion ~= nil then
			scheduled[id] = nil
		end
		if result.ok and executor.pendingServerEvent(id, durable.tickAction) ~= nil then
			return failure("SERVER_EVENT_PENDING")
		end
		local lifecycle: LifecycleResult = Executor.clone(result)
		lifecycle.notificationError = if diagnostic then diagnostic.notificationError else nil
		return lifecycle
	end
	local function capture(id: string): Contract.SaveEnvelope
		local envelope = executor.save(id)
		if ledgers[id] then
			envelope.commands = Executor.clone(ledgers[id])
		end
		return envelope
	end
	local function hydrate(id: string, token: FencedStore.Profile)
		tokens[id] = token
		profiles[id] = { key = token.key, data = Executor.clone(token.data.envelope) }
		ledgers[id] = Executor.clone(token.data.envelope.commands)
		executor.hydrate(id, token.data.envelope)
	end
	function session.personalTransfer(id)
		if not personal or not joined[id] or pending[id] or departed[id] then
			return nil
		end
		local owner = personal
		local key = tokens[id].key
		return {
			personal = owner,
			profile = function()
				assert(joined[id] and not pending[id] and not departed[id], "personal transfer actor unavailable")
				return tokens[id]
			end,
			install = function(token)
				assert(joined[id] and not pending[id] and not departed[id], "personal transfer actor unavailable")
				assert(
					token.key == key and token.sessionId == storeOptions.sessionId,
					"foreign personal transfer token"
				)
				hydrate(id, token)
			end,
		}
	end
	function session.committedReceipt(id, epochId, requestId, action, args, origin)
		-- Only persisted personal data is evidence. Pending/executor state can contain
		-- a candidate whose backend acknowledgment has not arrived yet.
		if not joined[id] or departed[id] or busy[id] or pending[id] or not tokens[id] then
			return nil
		end
		if origin ~= "server" and origin ~= "client" then
			return nil
		end
		local ledger = tokens[id].data.envelope.commands
		local epoch = ledger and ledger.epochs[tostring(epochId)]
		local receipt = epoch and epoch.outcomes[requestId]
		if not receipt or not receipt.result.ok or storeOptions.now() >= receipt.expiresAt then
			return nil
		end
		local binding = (if origin == "server" then "S" else "") .. Ledger.canonical({ action = action, args = args })
		return if receipt.binding == binding then Executor.clone(receipt.result) else nil
	end
	local recoveryTurn: { [string]: number } = {}
	function session.recoverTransfers(id, maximum)
		assert(maximum % 1 == 0 and maximum >= 1 and maximum <= 64, "invalid transfer recovery bound")
		if departed[id] then
			return { ok = true, data = { results = {} } }
		end
		local transfer = services.survivalTransfer
		local gathering = services.survivalGathering
		local wildlife = services.survivalWildlife
		local recoverable = {}
		for _, extension in extensions do
			if extension.recover then
				table.insert(recoverable, extension)
			end
		end
		if
			(not transfer and not gathering and not wildlife and #recoverable == 0)
			or not personal
			or not joined[id]
		then
			return failure("TRANSFER_UNAVAILABLE")
		end
		if busy[id] or next(pending) then
			return failure("COMMAND_PENDING")
		end
		busy[id] = true
		local ok, results = pcall(function()
			local batch = {}
			local ports: { any } = {}
			if transfer then
				table.insert(ports, transfer)
			end
			if gathering then
				table.insert(ports, gathering)
			end
			if wildlife then
				table.insert(ports, wildlife)
			end
			for _, extension in recoverable do
				table.insert(ports, extension)
			end
			for _ = 1, math.min(maximum, 8) do
				recoveryTurn[id] = (recoveryTurn[id] or 0) % #ports + 1
				local service = ports[recoveryTurn[id]]
				table.insert(batch, (service :: any).recover(id, 1))
			end
			return batch
		end)
		busy[id] = nil
		if not ok then
			error(results)
		end
		return { ok = true, data = { results = results } }
	end
	function session.join(id)
		if profiles[id] or busy[id] then
			return failure("profile already active/loading")
		end
		local rejoining = departed[id] == true
		departed[id] = nil
		leaving[id], releasedActors[id] = nil, nil
		busy[id] = true
		local ok, profile, err = pcall(function(): (ProfileStore.Profile?, string?)
			local function migrate(raw: any)
				local migrated = M.migrate(raw, options.contracts)
				if durable and migrated.commands == nil then
					local now = storeOptions.now()
					migrated.commands = {
						version = 2,
						epoch = 0,
						stateVersion = 0,
						epochs = {
							["0"] = { createdAt = now, expiresAt = now + ttl, outcomes = {} },
						},
					}
				end
				return migrated
			end
			if personal then
				local token, reason = personal:load(id, function()
					return migrate(nil)
				end)
				if token then
					tokens[id] = token
					return { key = token.key, data = token.data.envelope }, nil
				end
				return nil, reason
			end
			return store:load("player-" .. id, migrate)
		end)
		busy[id] = nil
		if not ok then
			return failure(tostring(profile))
		end
		if not profile then
			return failure(err)
		end
		profiles[id] = profile
		ledgers[id] = if profile.data.commands then Executor.clone(profile.data.commands) else nil
		local result = executor.join(id, profile.data :: Contract.SaveEnvelope, personal ~= nil)
		if personal then
			busy[id] = true
			if not result.ok then
				personal:release(tokens[id])
				profiles[id], tokens[id] = nil, nil
				busy[id] = nil
				return result
			end
			local committed, reason = personal:commit(tokens[id], tokens[id].data.stateRevision, capture(id), nil)
			if not committed or reason then
				executor.discard(id)
				personal:release(tokens[id])
				profiles[id], tokens[id] = nil, nil
				busy[id] = nil
				return failure(reason)
			end
			hydrate(id, committed)
			joined[id] = true
			busy[id] = nil
			for _, extension in extensions do
				local lifecycle = M.lifecycle(extension)
				if rejoining and lifecycle.resumeActor then
					local resumed = lifecycle.resumeActor(id)
					if not resumed.ok then
						return failure(resumed.reason)
					end
				end
			end
			if services.survivalTransfer or services.survivalGathering then
				session.recoverTransfers(id, 8)
			end
			return { ok = true, notificationError = executor.flushCommand() }
		end
		if result.ok then
			joined[id] = true
			for _, extension in extensions do
				local lifecycle = M.lifecycle(extension)
				if rejoining and lifecycle.resumeActor then
					local resumed = lifecycle.resumeActor(id)
					if not resumed.ok then
						return failure(resumed.reason)
					end
				end
			end
		else
			local released, releaseErr = store:release(profile)
			if released then
				profiles[id] = nil
			else
				return failure(tostring(result.reason) .. "; release: " .. tostring(releaseErr))
			end
		end
		return result
	end
	local function write(id: string, release: boolean): LifecycleResult
		if pending[id] then
			return failure("COMMAND_PENDING")
		end
		local profile = profiles[id]
		if not profile then
			return failure("profile not active")
		end
		if busy[id] then
			return failure("profile operation in progress")
		end
		if personal then
			busy[id] = true
			local token, reason = personal:commit(tokens[id], tokens[id].data.stateRevision, capture(id), nil)
			busy[id] = nil
			if token then
				hydrate(id, token)
			end
			if not token or reason then
				return failure(reason)
			end
			return { ok = true }
		end
		busy[id] = true
		local ok, written, err = pcall(function()
			if joined[id] then
				profile.data = capture(id)
			end
			local committed = { key = profile.key, data = profile.data }
			if release then
				return store:release(committed)
			end
			return store:save(committed)
		end)
		busy[id] = nil
		if not ok then
			return failure(tostring(written))
		end
		if not written then
			return failure(err)
		end
		if release then
			profiles[id] = nil
		end
		return { ok = true }
	end
	function session.save(id)
		if departed[id] then
			return failure("ACTOR_LEFT")
		end
		return write(id, false)
	end
	local function drainActor(id: string): LifecycleResult
		local ports: { any } = {}
		for _, name in { "survivalTransfer", "survivalGathering", "survivalWildlife" } do
			local port = (services :: any)[name]
			if port then
				table.insert(ports, port)
			end
		end
		for _, port in ports do
			local settled = false
			for _ = 1, 64 do
				local result = (port :: any).recover(id, 64)
				if result.ok == false or result.status == "recovering" then
					return failure(result.reason or result.error or "TRANSFER_PENDING")
				end
				local transfers = if result[1] ~= nil
					then result
					elseif result.data then result.data.transfers
					else result.transfers
				local unfinished = false
				for _, transfer in transfers or {} do
					if transfer.status == "recovering" or transfer.ok == false then
						return failure(transfer.error or transfer.reason or "TRANSFER_PENDING")
					end
					if
						transfer.phase ~= "FINALIZED"
						and transfer.phase ~= "CANCELLED"
						and transfer.phase ~= "RETIRED"
					then
						unfinished = true
					end
				end
				if not unfinished then
					settled = true
					break
				end
			end
			if not settled then
				return failure("TRANSFER_PENDING")
			end
		end
		for _, extension in extensions do
			local lifecycle = M.lifecycle(extension)
			if lifecycle.drain then
				local drained = lifecycle.drain(id)
				if not drained.ok then
					return failure(drained.reason)
				end
			end
		end
		return { ok = true }
	end
	local function releaseActor(id: string): LifecycleResult
		local released = releasedActors[id] or {}
		releasedActors[id] = released
		for _, extension in extensions do
			local lifecycle = M.lifecycle(extension)
			if lifecycle.releaseActor and not released[extension.id] then
				local result = lifecycle.releaseActor(id)
				if not result.ok then
					return failure(result.reason)
				end
				released[extension.id] = true
			end
		end
		return { ok = true }
	end
	function session.prepareHandoff(id)
		if departed[id] then
			return { ok = true }
		end
		if not joined[id] or busy[id] or pending[id] then
			return failure("COMMAND_PENDING")
		end
		local eventResult = flushServerEvent(id)
		if not eventResult.ok then
			return eventResult
		end
		leaving[id] = true
		local drained = drainActor(id)
		if not drained.ok then
			return drained
		end
		local saved = write(id, false)
		if not saved.ok then
			return saved
		end
		local released = releaseActor(id)
		if not released.ok then
			return released
		end
		if personal then
			local ok, reason = personal:release(tokens[id])
			if not ok then
				return failure(reason)
			end
		else
			local ok, reason = store:release(profiles[id])
			if not ok then
				return failure(reason)
			end
		end
		departed[id] = true
		executor.discard(id)
		return { ok = true }
	end
	function session.resumeHandoff(id)
		if departed[id] and profiles[id] == nil then
			return failure("ACTOR_LEFT")
		end
		if not leaving[id] then
			return { ok = joined[id] == true }
		end
		if departed[id] then
			-- Reacquisition is fenced by the durable owner. If the destination has
			-- claimed it, this fails without unlocking or rolling it back.
			if personal then
				local token, reason = personal:load(id, function()
					error("handoff profile missing")
				end)
				if not token then
					return failure(reason)
				end
				local restored = executor.join(id, token.data.envelope, true)
				if not restored.ok then
					return restored
				end
				hydrate(id, token)
			else
				local profile, reason = store:load("player-" .. id, function(raw)
					return M.migrate(raw, options.contracts)
				end)
				if not profile then
					return failure(reason)
				end
				profiles[id] = profile
				local restored = executor.join(id, profile.data)
				if not restored.ok then
					return restored
				end
			end
		end
		for _, extension in extensions do
			local lifecycle = M.lifecycle(extension)
			if lifecycle.resumeActor then
				local result = lifecycle.resumeActor(id)
				if not result.ok then
					return failure(result.reason)
				end
			end
		end
		leaving[id], departed[id], releasedActors[id] = nil, nil, nil
		return { ok = true, notificationError = executor.flushCommand() }
	end
	function session.completeHandoff(id)
		if profiles[id] == nil then
			return { ok = true }
		end
		if not departed[id] then
			return failure("HANDOFF_NOT_READY")
		end
		local notification = executor.leave(id)
		joined[id], profiles[id], tokens[id], ledgers[id] = nil, nil, nil, nil
		leaving[id] = nil
		return { ok = true, notificationError = notification }
	end
	function session.close(id)
		if departed[id] then
			return session.completeHandoff(id)
		end
		local eventResult = flushServerEvent(id)
		if not eventResult.ok then
			return eventResult
		end
		if pending[id] then
			return failure("COMMAND_PENDING")
		end
		if profiles[id] == nil then
			return { ok = true }
		end
		if personal then
			if busy[id] then
				return failure("profile operation in progress")
			end
			leaving[id] = true
			local drained = drainActor(id)
			if not drained.ok then
				return drained
			end
			local prepared = executor.prepareLeave(id)
			local saved = write(id, false)
			if not saved.ok then
				return saved
			end
			local extensionRelease = releaseActor(id)
			if not extensionRelease.ok then
				return extensionRelease
			end
			local released, reason = personal:release(tokens[id])
			if not released then
				return failure(reason)
			end
			local notification = executor.leave(id)
			joined[id], profiles[id], tokens[id], ledgers[id] = nil, nil, nil, nil
			departed[id] = true
			return { ok = true, notificationError = notification or prepared }
		end
		if #extensions > 0 then
			local ready = session.prepareHandoff(id)
			if not ready.ok then
				return ready
			end
			return session.completeHandoff(id)
		end
		-- Capture before detaching even if a backend write is suspended. The
		-- in-flight write owns a separate profile object; retry releases this
		-- final envelope without rejoining or keeping a departed wave member.
		local notifications: { string } = {}
		if joined[id] then
			local captured, captureError = pcall(function()
				local prepareError = executor.prepareLeave(id)
				if prepareError then
					table.insert(notifications, prepareError)
				end
				profiles[id].data = capture(id)
			end)
			if not captured then
				captureErrors[id] = tostring(captureError)
			end
			joined[id] = nil
			local leaveError = executor.leave(id)
			if leaveError then
				table.insert(notifications, leaveError)
			end
		end
		if captureErrors[id] then
			local reason = captureErrors[id]
			if busy[id] then
				return { ok = false, reason = reason .. "; profile operation in progress", released = false }
			end
			busy[id] = true
			local ok, released, err = pcall(store.releaseLock, store, profiles[id])
			busy[id] = nil
			if ok and released then
				profiles[id], captureErrors[id] = nil, nil
			end
			return {
				ok = false,
				reason = reason
					.. (if ok and released then "" else "; release: " .. tostring(if ok then err else released)),
				released = ok and released == true,
				notificationError = if #notifications > 0 then table.concat(notifications, "; ") else nil,
			}
		end
		local result: LifecycleResult = write(id, true)
		result.notificationError = if #notifications > 0 then table.concat(notifications, "; ") else nil
		return result
	end
	function session.dispatch(id, action, args)
		if leaving[id] then
			return failure("ACTOR_LEAVING")
		end
		if next(pending) then
			return failure("COMMAND_PENDING")
		end
		if busy[id] then
			return failure("profile operation in progress")
		end
		if type(action) ~= "string" or type(args) ~= "table" then
			return failure("invalid action transport")
		end
		for _, control in options.controls do
			if
				control.action == action
				and control.kind == "player-button"
				and (type(args[1]) ~= "string" or not joined[args[1]])
			then
				return failure("target not in roster")
			end
		end
		return executor.dispatchClient(id, action, args)
	end
	function session.dispatchServer(id, action, args)
		if leaving[id] then
			return failure("ACTOR_LEAVING")
		end
		if next(pending) then
			return failure("COMMAND_PENDING")
		end
		if busy[id] then
			return failure("profile operation in progress")
		end
		if not joined[id] then
			return failure("player not joined")
		end
		if type(action) ~= "string" or type(args) ~= "table" then
			return failure("invalid action transport")
		end
		if durable and durable.serverActions and table.find(durable.serverActions, action) then
			return failure("DURABLE_COMMAND_REQUIRED")
		end
		return executor.dispatchServer(id, action, args)
	end
	local lastCommandRecovery: { [string]: number } = {}
	function session.commandEpoch(id, action)
		if not durable or not joined[id] or leaving[id] or busy[id] or pending[id] then
			return nil
		end
		if services.survivalWildlife then
			-- Opportunistic pre-command recovery, at most one sweep per second per
			-- member: commandState polls commandEpoch for every action on every
			-- push, and an uncapped sweep here burns the loopback request budget
			-- long before any real command arrives. The 1 Hz advance sweep still
			-- guarantees catch-up.
			local now = storeOptions.now()
			if lastCommandRecovery[id] == nil or now - lastCommandRecovery[id] >= 1 then
				lastCommandRecovery[id] = now
				local recovered = session.recoverTransfers(id, 8)
				if not recovered.ok then
					return nil
				end
				for _, result in (recovered.data :: Contract.StateData).results do
					if result.ok == false then
						return nil
					end
				end
			end
		end
		if action and services.survivalTransfer and services.survivalTransfer.handles(action) then
			local epoch = services.survivalTransfer.epoch(id, action)
			return epoch
		end
		if action and services.survivalSettlement and services.survivalSettlement.handles(action) then
			local epoch = services.survivalSettlement.epoch(id, action)
			return epoch
		end
		local extension = extensionFor(action)
		if extension and extension.epoch then
			local epoch = extension.epoch(id, action :: string)
			return epoch
		end
		local ledger = ledgers[id]
		if not ledger then
			return nil
		end
		local now = storeOptions.now()
		if now < ledger.epochs[tostring(ledger.epoch)].expiresAt then
			return ledger.epoch
		end
		local candidate: Ledger.Ledger = Executor.clone(ledger)
		for key, epoch in candidate.epochs do
			local retained = false
			for requestId, outcome in epoch.outcomes do
				if now >= outcome.expiresAt then
					epoch.outcomes[requestId] = nil
				else
					retained = true
				end
			end
			if not retained then
				candidate.epochs[key] = nil
			end
		end
		local issuedTtl = ledger.epochs[tostring(ledger.epoch)].expiresAt
			- ledger.epochs[tostring(ledger.epoch)].createdAt
		candidate.epoch += 1
		candidate.epochs[tostring(candidate.epoch)] = { createdAt = now, expiresAt = now + issuedTtl, outcomes = {} }
		local envelope = capture(id)
		envelope.commands = candidate
		busy[id] = true
		local ok, saved = pcall(function(): boolean
			if personal then
				local token, reason = personal:commit(tokens[id], tokens[id].data.stateRevision, envelope, nil)
				if token then
					hydrate(id, token)
				end
				return token ~= nil and reason == nil
			end
			local written = store:save({ key = profiles[id].key, data = envelope })
			return written
		end)
		busy[id] = nil
		if not ok or not saved then
			return nil
		end
		profiles[id].data = envelope
		ledgers[id] = candidate
		return candidate.epoch
	end
	local function command(
		id: string,
		request: any,
		origin: "client" | "server"
	): (Contract.Result, { notificationError: string }?)
		if leaving[id] then
			return failure("ACTOR_LEAVING")
		end
		if not joined[id] then
			return failure("player not joined")
		end
		if not durable then
			return failure("durable commands disabled")
		end
		if
			type(request) ~= "table"
			or not Executor.data(request)
			or (request.actorId ~= nil and request.actorId ~= id)
			or type(request.requestId) ~= "string"
			or #request.requestId == 0
			or #request.requestId > 128
			or type(request.action) ~= "string"
			or type(request.args) ~= "table"
			or not Executor.finite(request.sessionEpoch)
			or request.sessionEpoch % 1 ~= 0
		then
			return failure("invalid command transport")
		end
		for key in request do
			if not table.find({ "actorId", "requestId", "sessionEpoch", "action", "args" }, key) then
				return failure("invalid command transport")
			end
		end
		local valid = if origin == "server"
			then executor.validateServer(id, request.action, request.args)
			else executor.validateClient(id, request.action, request.args)
		if not valid.ok then
			return valid
		end
		local allowed = if origin == "server" then durable.serverActions or {} else durable.actions
		if not table.find(allowed, request.action) then
			return failure("durable action disallowed")
		end
		if services.survivalWildlife and not services.survivalWildlife.handles(request.action) then
			local recovered = session.recoverTransfers(id, 8)
			if not recovered.ok then
				return recovered
			end
			for _, result in (recovered.data :: Contract.StateData).results do
				if result.ok == false then
					return failure("COMBAT_PENDING")
				end
			end
		end
		local transfer = services.survivalTransfer
		local gathering: {
			handles: (string) -> boolean,
			command: (string, { any }, Contract.CommandContext, number, () -> Contract.Result) -> Contract.Result,
		}? =
			services.survivalGathering
		local wildlife = services.survivalWildlife
		if wildlife and wildlife.handles(request.action) then
			gathering = wildlife
		end
		if gathering and gathering.handles(request.action) then
			if not personal or busy[id] or next(pending) then
				return failure("COMMAND_PENDING")
			end
			local ledger = ledgers[id]
			local epoch = if ledger then ledger.epochs[tostring(request.sessionEpoch)] else nil
			local wildlifeRequest = wildlife and wildlife.handles(request.action)
			if
				not wildlifeRequest
				and (not epoch or ledger.epoch ~= request.sessionEpoch or storeOptions.now() >= epoch.expiresAt)
			then
				return failure("REQUEST_EXPIRED")
			end
			busy[id] = true
			local ok, result = pcall(
				gathering.command,
				id,
				request.args,
				{
					actorId = id,
					requestId = request.requestId,
					sessionEpoch = request.sessionEpoch,
					serverId = storeOptions.sessionId,
				},
				if epoch then math.floor(epoch.expiresAt) else 0,
				function()
					return executor.admit(id, request.action, request.args, origin)
				end
			)
			busy[id] = nil
			if not ok then
				error(result)
			end
			return result
		end
		if transfer and transfer.handles(request.action) then
			if not personal or busy[id] or next(pending) then
				return failure("COMMAND_PENDING")
			end
			busy[id] = true
			local ok, result = pcall(function()
				return transfer.command(
					id,
					request.action,
					request.args,
					{
						actorId = id,
						requestId = request.requestId,
						sessionEpoch = request.sessionEpoch,
						serverId = storeOptions.sessionId,
					},
					origin,
					function()
						return executor.admit(id, request.action, request.args, origin)
					end
				)
			end)
			busy[id] = nil
			if not ok then
				error(result)
			end
			return result
		end
		local bridge = services.survivalSettlement
		if bridge and bridge.handles(request.action) then
			return bridge.command(
				id,
				request.action,
				request.args,
				{
					actorId = id,
					requestId = request.requestId,
					sessionEpoch = request.sessionEpoch,
					serverId = storeOptions.sessionId,
				},
				origin,
				function()
					return executor.admit(id, request.action, request.args, origin)
				end
			)
		end
		local extension = extensionFor(request.action)
		if extension then
			if busy[id] or next(pending) then
				return failure("COMMAND_PENDING")
			end
			busy[id] = true
			local ok, result = pcall(
				extension.command,
				id,
				request.action,
				request.args,
				{
					actorId = id,
					requestId = request.requestId,
					sessionEpoch = request.sessionEpoch,
					serverId = storeOptions.sessionId,
				},
				origin,
				function()
					return executor.admit(id, request.action, request.args, origin)
				end
			)
			busy[id] = nil
			if not ok then
				error(result)
			end
			return result
		end
		-- A fixed discriminator binds origin without spending payload budget on
		-- another canonical mapping key. Client bindings retain their prior form;
		-- server bindings cannot collide with a canonical mapping's opening brace.
		local binding = (if origin == "server" then "S" else "")
			.. Ledger.canonical({ action = request.action, args = request.args })
		-- Keep the canonical binding itself: collision-free and bounded like all saved strings.
		if #binding > 256 then
			return failure("command payload too large")
		end
		local ledger = ledgers[id]
		local now = storeOptions.now()
		local epoch = if ledger then ledger.epochs[tostring(request.sessionEpoch)] else nil
		local staged = pending[id]
		-- An accepted in-flight command retains its original epoch while a failed
		-- or ambiguous backend write is retried; new commands use the current window.
		if busy[id] then
			return failure("COMMAND_PENDING")
		end
		if personal and not staged then
			busy[id] = true
			local current, reason = personal:refresh(tokens[id])
			busy[id] = nil
			if not current then
				return failure(reason)
			end
			hydrate(id, current)
			ledger = ledgers[id]
			epoch = if ledger then ledger.epochs[tostring(request.sessionEpoch)] else nil
		end
		if epoch and epoch.outcomes[request.requestId] and now < epoch.outcomes[request.requestId].expiresAt then
			local outcome = epoch.outcomes[request.requestId]
			if outcome.binding ~= binding then
				return failure("REQUEST_CONFLICT")
			end
			admissions[id] = nil
			return Executor.clone(outcome.result)
		end
		if not staged and (not epoch or now >= epoch.expiresAt or epoch.outcomes[request.requestId] ~= nil) then
			return failure("REQUEST_EXPIRED")
		end
		if staged and staged.envelope.commands.epoch ~= request.sessionEpoch then
			return failure("REQUEST_EXPIRED")
		end
		if staged and (staged.requestId ~= request.requestId or staged.binding ~= binding) then
			return failure("COMMAND_PENDING")
		end
		if not staged then
			if next(pending) then
				return failure("COMMAND_PENDING")
			end
			local nextLedger: Ledger.Ledger = Executor.clone(ledger)
			local outcomes = nextLedger.epochs[tostring(request.sessionEpoch)].outcomes
			local count = 0
			for _ in outcomes do
				count += 1
			end
			if count >= limit then
				return failure("REQUEST_WINDOW_FULL")
			end
			local context = {
				actorId = id,
				requestId = request.requestId,
				sessionEpoch = request.sessionEpoch,
				expiredBeforeEpoch = Ledger.retentionFloor(nextLedger, now),
				serverId = storeOptions.sessionId,
			}
			local admission = admissions[id]
			if admission and (admission.requestId ~= request.requestId or admission.binding ~= binding) then
				return failure("COMMAND_PENDING")
			end
			local stage, err
			if origin == "server" then
				stage, err = executor.stageServer(id, request.action, request.args, context, admission ~= nil)
			else
				stage, err = executor.stageClient(id, request.action, request.args, context, admission ~= nil)
			end
			if not stage then
				return err :: Contract.Result
			end
			if personal then
				admissions[id] = { requestId = request.requestId, binding = binding }
			end
			assert(Executor.data(stage.result), "invalid command result")
			nextLedger.stateVersion += 1
			local result = Executor.clone(stage.result)
			result.stateVersion = nextLedger.stateVersion
			local issued = nextLedger.epochs[tostring(request.sessionEpoch)]
			outcomes[request.requestId] = {
				binding = binding,
				result = result,
				createdAt = now,
				expiresAt = now + (issued.expiresAt - issued.createdAt),
			}
			local envelope = capture(id)
			local genre = string.match(request.action, "^([^:]+):") :: string
			envelope.genres[genre].data = Executor.clone(stage.data)
			envelope.commands = nextLedger
			assert(#Executor.validateSave(envelope, options.contracts) == 0, "invalid durable envelope")
			staged = {
				envelope = envelope,
				stage = stage,
				requestId = request.requestId,
				binding = binding,
				expected = if personal then tokens[id].data.stateRevision else nil,
			}
			pending[id] = staged
		end
		busy[id] = true
		assert(staged ~= nil, "missing staged command")
		local committed = staged
		if personal then
			local token, reason, outcome, won =
				personal:commit(tokens[id], committed.expected :: number, committed.envelope, {
					epoch = request.sessionEpoch,
					requestId = request.requestId,
					binding = binding,
				})
			busy[id] = nil
			if token then
				hydrate(id, token)
			end
			if reason == "STALE_PERSONAL_REVISION" then
				pending[id] = nil
				return failure(reason)
			end
			if not token or reason then
				return failure(reason or "COMMIT_FAILED")
			end
			pending[id], admissions[id] = nil, nil
			local notifyError: string? = nil
			if won and committed.stage.notify then
				local notified, err = pcall(function(): boolean
					(committed.stage.notify :: () -> ())()
					return true
				end)
				if not notified then
					notifyError = tostring(err)
				end
			end
			local notificationError = executor.flushCommand() or notifyError
			return Executor.clone(outcome), if notificationError then { notificationError = notificationError } else nil
		end
		local ok, written = pcall(function(): boolean
			local saved = store:save({ key = profiles[id].key, data = committed.envelope })
			return saved
		end)
		busy[id] = nil
		if not ok or not written then
			return failure("COMMIT_FAILED")
		end
		profiles[id].data = Executor.clone(committed.envelope)
		ledgers[id] = Executor.clone(committed.envelope.commands)
		committed.stage.apply()
		pending[id] = nil
		local notificationError = executor.flushCommand()
		return Executor.clone(ledgers[id].epochs[tostring(request.sessionEpoch)].outcomes[request.requestId].result),
			if notificationError then { notificationError = notificationError } else nil
	end
	-- Extensions observe every settled command result; a failing observer is
	-- reported as a notification error, never allowed to rewrite the result.
	local function observed(
		id: string,
		request: any,
		origin: "client" | "server"
	): (Contract.Result, { notificationError: string }?)
		local result, note = command(id, request, origin)
		if type(request) == "table" and type(request.action) == "string" and type(request.args) == "table" then
			for _, extension in extensions do
				if extension.observe then
					local ok, err = pcall(function(): boolean
						(extension.observe :: any)(id, request.action, request.args, result)
						return true
					end)
					if not ok then
						note = { notificationError = tostring(err) }
					end
				end
			end
		end
		return result, note
	end
	function session.command(id, request)
		return observed(id, request, "client")
	end
	function session.commandServer(id, request)
		return observed(id, request, "server")
	end
	function session.advance(epoch)
		if next(busy) then
			return
		end
		if durable and durable.tickAction then
			for id in joined do
				if leaving[id] then
					continue
				end
				local result = flushServerEvent(id)
				if not result.ok then
					return
				end
			end
		end
		if next(pending) then
			return
		end
		-- A flushed server event dispatches, and dispatch refreshes the executor clock to
		-- services.now(), which may already be past the epoch the caller sampled before this
		-- tick: advance to whichever is later so the tick never runs the clock backwards.
		executor.advance(math.max(epoch, services.now()))
		if services.survivalTransfer or services.survivalGathering or #extensions > 0 then
			for id in joined do
				if leaving[id] then
					continue
				end
				if personal and tokens[id] then
					local renewed = personal:renew(tokens[id])
					if renewed then
						tokens[id] = renewed
					end
				end
				session.recoverTransfers(id, 8)
			end
		end
	end
	function session.snapshot(id)
		local snapshot = executor.snapshot(id)
		if leaving[id] then
			return snapshot
		end
		if services.survivalGathering then
			local shared = services.survivalGathering.snapshot(id)
			if shared then
				snapshot.survivalGathering = shared
			end
		end
		if services.survivalSettlement then
			local shared = services.survivalSettlement.snapshot(id)
			if shared then
				snapshot.survivalSettlement = shared
			end
		end
		for _, extension in extensions do
			if extension.snapshot then
				local shared = extension.snapshot(id)
				if shared then
					snapshot.survivalExtensions = snapshot.survivalExtensions or {}
					snapshot.survivalExtensions[extension.id] = shared
				end
			end
		end
		return snapshot
	end
	function session.envelope(id)
		return capture(id)
	end
	function session.members()
		local ids = {}
		for id in joined do
			table.insert(ids, id)
		end
		table.sort(ids)
		return ids
	end
	function session.restore(id, raw)
		if next(pending) then
			return failure("COMMAND_PENDING")
		end
		if not joined[id] or busy[id] then
			return failure("profile not available")
		end
		-- Administrative restore must not roll back an acknowledged mutation while
		-- retaining its replay record (or remove the record and permit a second debit).
		if ledgers[id] ~= nil then
			return failure("durable profile cannot be restored")
		end
		local errors = Executor.validateSave(raw, options.contracts)
		if #errors > 0 then
			return failure(table.concat(errors, "; "))
		end
		local previous = executor.save(id)
		local leaveError = executor.leave(id)
		local result = executor.join(id, raw)
		if not result.ok then
			local rollback = executor.join(id, previous)
			assert(rollback.ok, "restore rollback failed")
			result.notificationError = rollback.notificationError
		end
		if leaveError then
			result.notificationError = leaveError
				.. (if result.notificationError then "; " .. result.notificationError else "")
		end
		return result
	end
	return session
end
return M
