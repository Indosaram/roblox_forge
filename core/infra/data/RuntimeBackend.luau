--!strict
local Memory = require("./MemoryBackend")
local DataStore = require("./DataStoreBackend")
local Observed = require("./ObservedBackend")
local Loopback = require("./LoopbackBackend")
local Ledger = require("../../domain/command/Ledger")
local Fenced = require("./FencedStore")
local M = {}
function M.new(config: any, productionStore: string): any
	local run = game:GetService("RunService")
	if not run:IsStudio() then
		return DataStore.new(productionStore)
	end
	assert(type(config) == "table", "PERSISTENCE_CONFIG_REQUIRED")
	-- Owned editor controller sets these Instance attributes before starting play.
	-- No Source edit, artifact rewrite, replicated secret or committed token.
	local storage = game:GetService("ServerStorage")
	local launch = storage:FindFirstChild("ForgeOwnedPersistenceConfig")
	local initialLeaseKey: any = nil
	local waitLeaseExpiry: any = nil
	if launch then
		assert(launch:IsA("Folder"), "INVALID_LOCAL_LAUNCH_CONFIG")
		assert(launch:GetAttribute("Mode") == "studio-local", "INVALID_LOCAL_LAUNCH_MODE")
		config = {
			mode = "studio-local",
			namespace = launch:GetAttribute("Namespace"),
			port = launch:GetAttribute("Port"),
			token = launch:GetAttribute("Token"),
		}
		initialLeaseKey = launch:GetAttribute("LeaseAcquireKey")
		waitLeaseExpiry = launch:GetAttribute("WaitLeaseExpiry")
		launch:Destroy()
	end
	if config.mode == "memory" then
		return Memory.new()
	end
	assert(config.mode == "studio-datastore" or config.mode == "studio-local", "PERSISTENCE_MODE_UNSUPPORTED")
	assert(
		type(config.namespace) == "string"
			and #config.namespace >= 1
			and #config.namespace <= 32
			and string.match(config.namespace, "^[a-z0-9%-]+$"),
		"ISOLATED_QA_NAMESPACE_REQUIRED"
	)
	if config.mode == "studio-datastore" then
		assert(game.GameId > 0, "PERSISTENT_STUDIO_REQUIRES_PUBLISHED_UNIVERSE")
	end
	assert(not storage:FindFirstChild("ForgePersistence"), "PERSISTENCE_ALREADY_BOUND")
	local http = game:GetService("HttpService")
	local storeName = "forge-qa-" .. config.namespace
	local folder = Instance.new("Folder")
	folder.Name = "ForgePersistence"
	local changed = Instance.new("BindableEvent")
	changed.Name, changed.Parent = "Committed", folder
	local identity = {
		mode = config.mode,
		namespace = config.namespace,
		storeName = storeName,
		universeId = game.GameId,
		placeId = game.PlaceId,
		serverSessionId = game.JobId,
		epoch = http:GenerateGUID(false),
	}
	local reached = Instance.new("BindableEvent")
	reached.Name, reached.Parent = "BarrierReached", folder
	local armed: any = nil
	local held: any = nil
	local lastBarrier: any = nil
	local status = Instance.new("BindableFunction")
	status.Name, status.Parent = "barrierStatus", folder
	status.OnInvoke = function(ticket: string)
		local value = if held and held.ticket == ticket then held else lastBarrier
		if not value or value.ticket ~= ticket then
			return { ticket = ticket, held = false, ackState = "unknown" }
		end
		return {
			ticket = ticket,
			held = held == value and value.ackState == "held",
			expiresAtMs = value.expiresAtMs,
			ackState = value.ackState,
			identity = table.clone(identity),
			requestId = value.requestId,
			phase = value.phase,
			record = value.record,
		}
	end
	local arm = Instance.new("BindableFunction")
	arm.Name, arm.Parent = "armBarrier", folder
	arm.OnInvoke = function(key: string, requestId: string, phase: string)
		assert(not armed and not held, "BARRIER_ALREADY_ARMED")
		assert(type(key) == "string" and #key > 0 and #key <= 128, "INVALID_BARRIER_KEY")
		assert(type(requestId) == "string" and #requestId > 0 and #requestId <= 128, "INVALID_BARRIER_REQUEST")
		assert(
			phase == "ESCROWED"
				or phase == "CREDITED"
				or phase == "FINALIZED"
				or phase == "LEASE_ACQUIRED"
				or phase == "LEASE_RENEWED",
			"INVALID_BARRIER_PHASE"
		)
		armed = { key = key, requestId = requestId, phase = phase, ticket = http:GenerateGUID(false) }
		return { ticket = armed.ticket, identity = table.clone(identity) }
	end
	-- Install the selector and event recorder before returning the backend to
	-- startup owners. No owner can acquire before this subscription exists.
	if initialLeaseKey ~= nil then
		assert(
			type(initialLeaseKey) == "string" and #initialLeaseKey > 0 and #initialLeaseKey <= 128,
			"INVALID_STARTUP_LEASE_KEY"
		)
		local marker = Instance.new("StringValue")
		marker.Name, marker.Parent = "StartupLeaseReached", folder
		local connection = reached.Event:Connect(function(event)
			marker.Value = http:JSONEncode(event)
		end)
		folder.Destroying:Connect(function()
			connection:Disconnect()
		end)
		arm.OnInvoke(initialLeaseKey, "owned-startup-lease", "LEASE_ACQUIRED")
	end
	local release = Instance.new("BindableFunction")
	release.Name, release.Parent = "releaseBarrier", folder
	release.OnInvoke = function(ticket: string)
		if armed and armed.ticket == ticket then
			armed = nil
			return true
		end
		if held and held.ticket == ticket and held.ackState == "held" then
			held.ackState = "released"
			held.signal:Fire()
			return true
		end
		return false
	end
	local loopbackConfig = config
	if config.mode == "studio-local" and type(config.wait) ~= "function" then
		loopbackConfig = table.clone(config)
		loopbackConfig.wait = task.wait
		loopbackConfig.log = warn
	end
	local underlying = if config.mode == "studio-local"
		then Loopback.new(loopbackConfig, http)
		else DataStore.new(storeName)
	if config.mode == "studio-datastore" then
		underlying.observation = function()
			return {
				backend = "roblox-datastore",
				namespace = config.namespace,
				storeName = storeName,
				epoch = identity.epoch,
				sampledAtMs = DateTime.now().UnixTimestampMillis,
				budgetUnit = "UpdateAsync-requests",
				availableRequests = game:GetService("DataStoreService")
					:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync),
				-- The engine adapter returns opaque failures; this sample cannot
				-- claim classified throttles or complete service outcome coverage.
				coverageComplete = false,
			}
		end
	end
	local backend = Observed.new(underlying, identity, function(value)
		return http:JSONEncode(value)
	end, function()
		return DateTime.now().UnixTimestampMillis
	end, function(value)
		changed:Fire(value)
		local selected = armed
		if not selected or selected.key ~= value.key then
			return
		end
		local current = http:JSONDecode(value.serialized)
		local previous = http:JSONDecode(value.previousSerialized)
		local function receipt(wrapper)
			local data = if type(wrapper) == "table" then wrapper.data else nil
			return if data and data.itemTransfers then data.itemTransfers.receipts[selected.requestId] else nil
		end
		local after, before = receipt(current), receipt(previous)
		local leasePhase = if current
				and current.lease
				and current.generation
			then if not previous or current.generation > (previous.generation or 0)
				then "LEASE_ACQUIRED"
				elseif
					previous.lease
					and current.revision > previous.revision
					and current.lease.expiresAt > previous.lease.expiresAt
					and Ledger.canonical(current.data) == Ledger.canonical(previous.data)
				then "LEASE_RENEWED"
				else nil
			else nil
		local phase = if selected.phase == leasePhase
			then leasePhase
			elseif
				after
				and after.phase == selected.phase
				and (not before or before.phase ~= after.phase)
			then after.phase
			else nil
		if not phase then
			return
		end
		armed = nil
		local signal = Instance.new("BindableEvent")
		local barrier = {
			ticket = selected.ticket,
			signal = signal,
			ackState = "held",
			expiresAtMs = DateTime.now().UnixTimestampMillis + 120000,
			requestId = selected.requestId,
			phase = phase,
			record = value,
		}
		held = barrier
		-- Subscribe to release before publishing the event. The waiter is resumed
		-- only after this actual acknowledged UpdateAsync, before owner ACK.
		local waiting = coroutine.running()
		local released = false
		local connection = signal.Event:Connect(function()
			if released then
				return
			end
			released = true
			task.defer(waiting)
		end)
		local timeout = task.delay(120, function()
			if barrier.ackState == "held" then
				barrier.ackState = "expired"
				signal:Fire()
			end
		end)
		reached:Fire({
			ticket = selected.ticket,
			identity = table.clone(identity),
			record = value,
			requestId = selected.requestId,
			phase = phase,
		})
		coroutine.yield()
		if barrier.ackState ~= "expired" then
			task.cancel(timeout)
		end
		connection:Disconnect()
		signal:Destroy()
		held = nil
		lastBarrier = barrier
		if barrier.ackState == "expired" then
			error("DURABLE_BARRIER_EXPIRED_BEFORE_ACK")
		end
	end)
	local snapshot = Instance.new("BindableFunction")
	snapshot.Name, snapshot.OnInvoke, snapshot.Parent = "snapshot", backend.observation, folder
	local stale = Instance.new("BindableFunction")
	stale.Name, stale.Parent = "probeStaleLease", folder
	stale.OnInvoke = function(key: string, sessionId: string, generation: number)
		-- Exercise the real fenced backend with the retained old capability. The
		-- transform is identity-only; a mistakenly accepted write is a failure,
		-- never permission to replace gameplay data or rewrite the token.
		local probe = Fenced.new(backend, {
			sessionId = sessionId,
			leaseSeconds = 120,
			now = function()
				return math.floor(DateTime.now().UnixTimestampMillis / 1000)
			end,
		})
		local transformed = false
		local result, reason = probe:update(
			{ key = key, sessionId = sessionId, generation = generation, data = {} },
			function(data)
				transformed = true
				return data
			end
		)
		return {
			accepted = result ~= nil,
			reason = reason,
			transformExecuted = transformed,
			authoritativeNow = math.floor(DateTime.now().UnixTimestampMillis / 1000),
		}
	end
	folder.Parent = storage
	if waitLeaseExpiry ~= nil then
		assert(type(waitLeaseExpiry) == "number" and waitLeaseExpiry % 1 == 0, "INVALID_LEASE_EXPIRY")
		local now = math.floor(DateTime.now().UnixTimestampMillis / 1000)
		assert(waitLeaseExpiry - now <= 125, "LEASE_EXPIRY_OUTSIDE_BOUND")
		if now < waitLeaseExpiry then
			local signal = Instance.new("BindableEvent")
			local expired = false
			local connection = run.Heartbeat:Connect(function()
				if math.floor(DateTime.now().UnixTimestampMillis / 1000) >= waitLeaseExpiry then
					signal:Fire()
				end
			end)
			local timer = task.delay(126, function()
				expired = true
				signal:Fire()
			end)
			signal.Event:Wait()
			connection:Disconnect()
			if coroutine.status(timer) == "suspended" then
				task.cancel(timer)
			end
			signal:Destroy()
			assert(not expired, "LEASE_EXPIRY_EVENT_TIMEOUT")
		end
		folder:SetAttribute("ObservedLeaseExpiry", math.floor(DateTime.now().UnixTimestampMillis / 1000))
	end
	return backend
end
return M
