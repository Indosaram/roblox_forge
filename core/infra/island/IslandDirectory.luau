--!strict
-- IslandDirectory: MemoryStore-backed routing directory (island id -> access
-- code, population, TTL). Plan §11.3: MemoryStore holds routing/display entries
-- only, never island state, and is NOT authoritative for write ownership (that
-- is the FencedStore lease, see Lease.luau).
--
-- The map is injected: memoryMap(now) for Lune specs, sortedMap(map) wraps a
-- live MemoryStoreSortedMap. No engine globals are read at module level.

export type Map = {
	get: (key: string) -> (boolean, any),
	set: (key: string, value: any, ttlSeconds: number) -> (boolean, string?),
	remove: (key: string) -> (boolean, string?),
	list: (limit: number) -> (boolean, { { key: string, value: any } } | string),
}

export type MemoryMap = Map & {
	-- Simulates MemoryStore eviction (entries may vanish before their TTL).
	evict: (key: string) -> (),
}

export type Record = {
	islandId: string,
	accessCode: string,
	population: number,
	expiresAt: number?,
}

export type Options = {
	ttlSeconds: number,
	-- Encodes a stored value to measure its byte size (HttpService:JSONEncode in Studio).
	encode: (any) -> string,
}

export type BudgetInput = {
	itemBytes: number,
	activeIslands: number,
	users: number,
}

export type Budget = {
	usedBytes: number,
	quotaBytes: number,
	limitBytes: number,
	ok: boolean,
}

local KB = 1024
-- C25 [115]: game quota 64 KB + 1.2 KB x users; single value limit 32 KB.
local BASE_QUOTA_BYTES = 64 * KB
local PER_USER_BYTES = 1.2 * KB
local MAX_VALUE_BYTES = 32 * KB
local BUDGET_SHARE = 0.5
local MAX_TTL_SECONDS = 3888000 -- MemoryStore 45-day expiration ceiling.
local PREFIX = "island:"

local function deepClone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = deepClone(item)
	end
	return copy
end

local function validId(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 40 and string.find(value, "^[%w_%-]+$") ~= nil
end

local IslandDirectory = {}
IslandDirectory.__index = IslandDirectory

export type Directory = typeof(setmetatable(
	{} :: {
		_map: Map,
		_opts: Options,
	},
	IslandDirectory
))

IslandDirectory.MAX_VALUE_BYTES = MAX_VALUE_BYTES

-- Pure budget calculator: item size x active islands must stay within 50% of
-- the game-wide MemoryStore quota.
function IslandDirectory.budget(input: BudgetInput): Budget
	assert(type(input.itemBytes) == "number" and input.itemBytes >= 0, "invalid item bytes")
	assert(type(input.activeIslands) == "number" and input.activeIslands >= 0, "invalid island count")
	assert(type(input.users) == "number" and input.users >= 0, "invalid user count")
	local quota = BASE_QUOTA_BYTES + PER_USER_BYTES * input.users
	local limit = quota * BUDGET_SHARE
	local used = input.itemBytes * input.activeIslands
	return { usedBytes = used, quotaBytes = quota, limitBytes = limit, ok = used <= limit }
end

-- Errors when over budget so a boot-time or CI gate fails loudly.
function IslandDirectory.assertBudget(input: BudgetInput): Budget
	local result = IslandDirectory.budget(input)
	if not result.ok then
		error(
			string.format(
				"MEMORYSTORE_BUDGET_EXCEEDED used=%d limit=%d quota=%d",
				result.usedBytes,
				result.limitBytes,
				result.quotaBytes
			)
		)
	end
	return result
end

function IslandDirectory.new(map: Map, opts: Options): Directory
	assert(type(opts.encode) == "function", "invalid encoder")
	assert(
		type(opts.ttlSeconds) == "number"
			and opts.ttlSeconds >= 1
			and opts.ttlSeconds <= MAX_TTL_SECONDS
			and opts.ttlSeconds % 1 == 0,
		"invalid ttl"
	)
	return setmetatable({ _map = map, _opts = table.clone(opts) }, IslandDirectory)
end

-- Byte size of one directory entry (key + encoded value), the itemBytes input of budget().
function IslandDirectory.itemBytes(self: Directory, record: Record): number
	return #(PREFIX .. record.islandId) + #self._opts.encode(record)
end

function IslandDirectory.publish(self: Directory, record: Record): (boolean, string?)
	if not validId(record.islandId) then
		return false, "invalid island id"
	end
	if type(record.accessCode) ~= "string" or #record.accessCode == 0 then
		return false, "invalid access code"
	end
	if type(record.population) ~= "number" or record.population < 0 or record.population % 1 ~= 0 then
		return false, "invalid population"
	end
	local value = { islandId = record.islandId, accessCode = record.accessCode, population = record.population }
	if self:itemBytes(value) > MAX_VALUE_BYTES then
		return false, "value too large"
	end
	return self._map.set(PREFIX .. record.islandId, value, self._opts.ttlSeconds)
end

function IslandDirectory.lookup(self: Directory, islandId: string): (Record?, string?)
	if not validId(islandId) then
		return nil, "invalid island id"
	end
	local ok, value = self._map.get(PREFIX .. islandId)
	if not ok then
		return nil, if type(value) == "string" then value else "directory error"
	end
	if type(value) ~= "table" or type(value.accessCode) ~= "string" or type(value.population) ~= "number" then
		return nil, nil
	end
	return { islandId = islandId, accessCode = value.accessCode, population = value.population }, nil
end

function IslandDirectory.remove(self: Directory, islandId: string): (boolean, string?)
	if not validId(islandId) then
		return false, "invalid island id"
	end
	return self._map.remove(PREFIX .. islandId)
end

-- Snapshot of live directory entries (approximate: MemoryStore may evict).
function IslandDirectory.list(self: Directory, limit: number): ({ Record }?, string?)
	local ok, rows = self._map.list(limit)
	if not ok then
		return nil, if type(rows) == "string" then rows else "directory error"
	end
	local out: { Record } = {}
	for _, row in rows :: { { key: string, value: any } } do
		local value = row.value
		if
			string.sub(row.key, 1, #PREFIX) == PREFIX
			and type(value) == "table"
			and type(value.accessCode) == "string"
			and type(value.population) == "number"
		then
			table.insert(out, {
				islandId = string.sub(row.key, #PREFIX + 1),
				accessCode = value.accessCode,
				population = value.population,
			})
		end
	end
	return out, nil
end

-- In-memory MemoryStore fake with TTL against an injected clock and explicit eviction.
function IslandDirectory.memoryMap(now: () -> number): MemoryMap
	local entries: { [string]: { value: any, expiresAt: number } } = {}
	local function live(key: string): any
		local entry = entries[key]
		if entry and now() >= entry.expiresAt then
			entries[key] = nil
			entry = nil
		end
		return entry
	end
	return {
		get = function(key: string): (boolean, any)
			local entry = live(key)
			return true, if entry then deepClone(entry.value) else nil
		end,
		set = function(key: string, value: any, ttlSeconds: number): (boolean, string?)
			entries[key] = { value = deepClone(value), expiresAt = now() + ttlSeconds }
			return true, nil
		end,
		remove = function(key: string): (boolean, string?)
			entries[key] = nil
			return true, nil
		end,
		list = function(limit: number): (boolean, { { key: string, value: any } } | string)
			local keys = {}
			for key in entries do
				if live(key) then
					table.insert(keys, key)
				end
			end
			table.sort(keys)
			local rows = {}
			for index = 1, math.min(limit, #keys) do
				table.insert(rows, { key = keys[index], value = deepClone(entries[keys[index]].value) })
			end
			return true, rows
		end,
		evict = function(key: string): ()
			entries[key] = nil
		end,
	}
end

-- Adapter over a live MemoryStoreSortedMap (MemoryStoreService:GetSortedMap(name)).
function IslandDirectory.sortedMap(sortedMap: any): Map
	return {
		get = function(key: string): (boolean, any)
			return pcall(function()
				return sortedMap:GetAsync(key)
			end)
		end,
		set = function(key: string, value: any, ttlSeconds: number): (boolean, string?)
			local ok, err = pcall(function()
				sortedMap:SetAsync(key, value, ttlSeconds)
			end)
			return ok, if ok then nil else tostring(err)
		end,
		remove = function(key: string): (boolean, string?)
			local ok, err = pcall(function()
				sortedMap:RemoveAsync(key)
			end)
			return ok, if ok then nil else tostring(err)
		end,
		list = function(limit: number): (boolean, { { key: string, value: any } } | string)
			local ok, result = pcall(function()
				return sortedMap:GetRangeAsync(Enum.SortDirection.Ascending, math.clamp(limit, 1, 200))
			end)
			if not ok then
				return false, tostring(result)
			end
			return true, result
		end,
	}
end

return IslandDirectory
