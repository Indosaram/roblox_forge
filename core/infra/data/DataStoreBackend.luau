--!strict
-- DataStoreBackend: ProfileStore backend adapting DataStoreService:UpdateAsync.

local DataStoreService = game:GetService("DataStoreService")
local env: any = getfenv()
local taskLib: any = env.task
local clockFn: () -> number = if type(os) == "table" and type(os.clock) == "function"
	then os.clock
	else function()
		return 0
	end

export type Transform = (old: any) -> any

export type Backend = {
	update: (key: string, transform: Transform) -> (boolean, any),
}

export type Store = Backend & {
	_store: DataStore,
}

local DataStoreBackend = {}

-- Roblox DataStoreService enforces a 6-second cooldown between writes to the
-- same key. Once a key is leased by this server via a synchronous UpdateAsync,
-- in-session updates apply atomically to the server's authoritative copy and
-- flush to DataStoreService at most once per cooldown window (and synchronously
-- when the lease/lock is released).
local WRITE_COOLDOWN_SECONDS = 7

local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[k] = clone(v)
	end
	return copy
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function holdingLease(record: any): string?
	if type(record) ~= "table" then
		return nil
	end
	if type(record.lease) == "table" and type(record.lease.sessionId) == "string" and #record.lease.sessionId > 0 then
		return record.lease.sessionId
	end
	if
		type(record.meta) == "table"
		and type(record.meta.sessionLock) == "table"
		and type(record.meta.sessionLock.sessionId) == "string"
		and #record.meta.sessionLock.sessionId > 0
	then
		return record.meta.sessionLock.sessionId
	end
	return nil
end

-- Runs the transform inside a single atomic UpdateAsync. Any DataStore failure
-- is reported as (false, reason) so ProfileStore can retry or surface it.
function DataStoreBackend.new(storeName: string): Store
	local dataStore = DataStoreService:GetDataStore(storeName)
	local cached: { [string]: any } = {}
	local lastSyncAt: { [string]: number } = {}
	local dirty: { [string]: boolean } = {}
	local scheduled: { [string]: boolean } = {}
	local flushing: { [string]: boolean } = {}

	local function syncFlush(key: string): (boolean, any)
		local snapshot = cached[key]
		if snapshot == nil then
			dirty[key] = nil
			return true, nil
		end
		flushing[key] = true
		dirty[key] = nil
		local target = clone(snapshot)
		local ok, result = pcall(function(): any
			return dataStore:UpdateAsync(key, function(_old: any): any
				return clone(cached[key] or target)
			end)
		end)
		flushing[key] = nil
		if ok then
			lastSyncAt[key] = clockFn()
			return true, result
		end
		dirty[key] = true
		return false, tostring(result)
	end

	local function scheduleFlush(key: string)
		if scheduled[key] or type(taskLib) ~= "table" or type(taskLib.delay) ~= "function" then
			return
		end
		scheduled[key] = true
		local elapsed = clockFn() - (lastSyncAt[key] or 0)
		local waitSeconds = math.max(0.1, WRITE_COOLDOWN_SECONDS - elapsed)
		taskLib.delay(waitSeconds, function()
			scheduled[key] = nil
			if dirty[key] and not flushing[key] then
				syncFlush(key)
				if dirty[key] then
					scheduleFlush(key)
				end
			end
		end)
	end

	pcall(function()
		local g: any = game
		if type(g.BindToClose) == "function" then
			g:BindToClose(function()
				for key in dirty do
					syncFlush(key)
				end
			end)
		end
	end)

	return {
		_store = dataStore,
		update = function(key: string, transform: Transform): (boolean, any)
			local current = cached[key]
			local owner = holdingLease(current)
			if current ~= nil and owner ~= nil and type(taskLib) == "table" then
				local candidate = transform(clone(current))
				if deepEqual(candidate, current) then
					return true, clone(current)
				end
				local nextOwner = holdingLease(candidate)
				-- Lease release or ownership change commits synchronously to DataStore.
				if nextOwner == nil or nextOwner ~= owner then
					cached[key] = nil
					dirty[key] = nil
					local ok, result = pcall(function(): any
						return dataStore:UpdateAsync(key, function(old: any): any
							return transform(if current ~= nil then clone(current) else old)
						end)
					end)
					if ok then
						lastSyncAt[key] = clockFn()
						return true, result
					end
					return false, tostring(result)
				end
				cached[key] = clone(candidate)
				dirty[key] = true
				if not flushing[key] and clockFn() - (lastSyncAt[key] or 0) >= WRITE_COOLDOWN_SECONDS then
					taskLib.spawn(function()
						if dirty[key] and not flushing[key] then
							syncFlush(key)
						end
					end)
				else
					scheduleFlush(key)
				end
				return true, clone(candidate)
			end

			local ok, result = pcall(function(): any
				return dataStore:UpdateAsync(key, transform)
			end)
			if ok then
				if holdingLease(result) ~= nil then
					cached[key] = clone(result)
					lastSyncAt[key] = clockFn()
				else
					cached[key] = nil
					dirty[key] = nil
				end
				return true, result
			end
			return false, tostring(result)
		end,
	}
end

return DataStoreBackend
