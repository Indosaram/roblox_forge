--!strict
-- Engine services share the personal-save selector. Memory services are local to
-- this server and are never selected outside Studio, even with a memory config.
local M = {}
local memory: any = nil

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

local function inMemory(): any
	local stores, maps = {}, {}
	local topics: { [string]: { any } } = {}
	local function now(): number
		return DateTime.now().UnixTimestampMillis / 1000
	end
	local data = {}
	function data.GetDataStore(_service: any, name: string, scope: string?): any
		local id = name .. "/" .. (scope or "global")
		if stores[id] then
			return stores[id]
		end
		local records, versions = {}, {}
		local store = {}
		local function keyInfo(record: any): any
			if not record then
				return nil
			end
			return {
				Version = tostring(record.version),
				CreatedTime = record.created,
				UpdatedTime = record.updated,
				GetUserIds = function()
					return copy(record.users)
				end,
				GetMetadata = function()
					return copy(record.metadata)
				end,
			}
		end
		function store:GetAsync(key: string): (any, any)
			local record = records[key]
			return if record then copy(record.value) else nil, keyInfo(record)
		end
		function store:SetAsync(key: string, value: any, users: any?, options: any?): string
			assert(value ~= nil, "DATASTORE_VALUE_REQUIRED")
			versions[key] = (versions[key] or 0) + 1
			local old = records[key]
			records[key] = {
				value = copy(value),
				version = versions[key],
				created = if old then old.created else now() * 1000,
				updated = now() * 1000,
				users = copy(users or {}),
				metadata = if options then copy(options:GetMetadata()) else {},
			}
			return tostring(versions[key])
		end
		function store:UpdateAsync(key: string, transform: any): (any, any)
			local old, info = self:GetAsync(key)
			local value, users, metadata = transform(old, info)
			if value == nil then
				return nil, nil
			end
			self:SetAsync(key, value, users, {
				GetMetadata = function()
					return metadata or {}
				end,
			})
			return self:GetAsync(key)
		end
		function store:RemoveAsync(key: string): (any, any)
			local value, info = self:GetAsync(key)
			records[key] = nil
			return value, info
		end
		function store.ListKeysAsync(_store: any, prefix: string?, pageSize: number?): any
			local keys = {}
			for key in records do
				if string.sub(key, 1, #(prefix or "")) == (prefix or "") then
					table.insert(keys, key)
				end
			end
			table.sort(keys)
			local size, offset = pageSize or 50, 1
			local pages = { IsFinished = #keys <= (pageSize or 50) }
			function pages:GetCurrentPage(): any
				local result = {}
				for index = offset, math.min(offset + size - 1, #keys) do
					table.insert(result, { KeyName = keys[index] })
				end
				return result
			end
			function pages:AdvanceToNextPageAsync()
				assert(not self.IsFinished, "NO_MORE_PAGES")
				offset += size
				self.IsFinished = offset + size - 1 >= #keys
			end
			return pages
		end
		stores[id] = store
		return store
	end
	local transient = {}
	function transient.GetSortedMap(_service: any, name: string): any
		if maps[name] then
			return maps[name]
		end
		local records = {}
		local map = {}
		function map:GetAsync(key: string): (any, any)
			local record = records[key]
			if record and record.expires <= now() then
				records[key], record = nil, nil
			end
			return if record then copy(record.value) else nil, if record then record.sortKey else nil
		end
		function map:SetAsync(key: string, value: any, expiration: number, sortKey: any?): boolean
			assert(value ~= nil, "MEMORYSTORE_VALUE_REQUIRED")
			records[key] = { value = copy(value), sortKey = sortKey, expires = now() + expiration }
			return true
		end
		function map:UpdateAsync(key: string, transform: any, expiration: number): (any, any)
			local old, oldSort = self:GetAsync(key)
			local value, sortKey = transform(old, oldSort)
			if value == nil then
				return nil, nil
			end
			self:SetAsync(key, value, expiration, sortKey)
			return self:GetAsync(key)
		end
		function map:RemoveAsync(key: string)
			records[key] = nil
		end
		function map:GetRangeAsync(direction: any, count: number, lower: any?, upper: any?): any
			local rows = {}
			local function less(a: any, b: any): boolean
				if a.sortKey ~= b.sortKey then
					if a.sortKey == nil then
						return true
					elseif b.sortKey == nil then
						return false
					end
					return a.sortKey < b.sortKey
				end
				return a.key < b.key
			end
			for key in records do
				local value, sortKey = self:GetAsync(key)
				local row = { key = key, value = value, sortKey = sortKey }
				local low = if type(lower) == "string" then { key = lower } else lower
				local high = if type(upper) == "string" then { key = upper } else upper
				if value ~= nil and (not low or less(low, row)) and (not high or less(row, high)) then
					table.insert(rows, row)
				end
			end
			table.sort(rows, function(a, b)
				return if direction == Enum.SortDirection.Descending then less(b, a) else less(a, b)
			end)
			while #rows > count do
				table.remove(rows)
			end
			return rows
		end
		maps[name] = map
		return map
	end
	local messaging = {}
	function messaging.SubscribeAsync(_service: any, topic: string, callback: any): any
		topics[topic] = topics[topic] or {}
		local connection = { Connected = true }
		function connection:Disconnect()
			self.Connected = false
		end
		table.insert(topics[topic], { connection = connection, callback = callback })
		return connection
	end
	function messaging:PublishAsync(topic: string, value: any)
		local subscriptions: { any } = table.clone(topics[topic] or {})
		for _, subscription in subscriptions do
			if subscription.connection.Connected then
				task.spawn(subscription.callback, { Data = copy(value), Sent = math.floor(now()) })
			end
		end
	end
	return { dataStoreService = data, memoryStoreService = transient, messagingService = messaging }
end

function M.new(config: any): any
	local studio = game:GetService("RunService"):IsStudio()
	if studio then
		assert(type(config) == "table", "PERSISTENCE_CONFIG_REQUIRED")
		local storage = game:GetService("ServerStorage")
		local launch = storage:FindFirstChild("ForgeOwnedPersistenceConfig")
		local bound = storage:FindFirstChild("ForgePersistence")
		if config.mode == "memory" and not launch and not bound then
			memory = memory or inMemory()
			return memory
		end
	end
	return {
		dataStoreService = game:GetService("DataStoreService"),
		memoryStoreService = game:GetService("MemoryStoreService"),
		messagingService = game:GetService("MessagingService"),
	}
end

return M
