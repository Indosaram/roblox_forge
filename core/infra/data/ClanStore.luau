--!strict
-- One CAS directory owns the membership index and clan envelopes together.
-- The injected DataStore is dedicated to this namespace. Never use cached
-- MemoryStore/MessagingService values as authority for membership or balances.
local Data = require("../../domain/genre/SerializedData")
local Fenced = require("./FencedStore")
local Clan = require("../../domain/settlement/Clan")
local M = {}

function M.new(config: any): any
	-- Reads (membership, record lookups, browse) never write: a live UpdateAsync on this one
	-- global key counts against the 1-write-per-6s per-key limit even when nothing changes, and
	-- per-heartbeat snapshot reads flooded the DataStore queue (p134 v22 D6). With
	-- config.readSeconds a read reuses the last directory this server read or committed for at
	-- most that many seconds; every mutation still runs inside the CAS below.
	local cached: any = nil
	local cachedAt = 0
	local function write(transform: any): (boolean, any)
		return pcall(function(): any
			return config.dataStore:UpdateAsync("directory", function(old: any): any
				local state = if old then Data.clone(old) else { version = 1, records = {}, members = {} }
				assert(state.version == 1, "CLAN_DIRECTORY_VERSION")
				transform(state)
				local members = {}
				for key, record in state.records do
					if string.sub(key, 1, 5) == "clan:" and not record.data.dissolved then
						assert(key == "clan:" .. record.data.clanId, "CLAN_ID_MISMATCH")
						local count = 0
						for actor in record.data.members do
							assert(members[actor] == nil, "ALREADY_IN_CLAN")
							members[actor] = record.data.clanId
							count += 1
						end
						assert(count <= config.rules.maxMembers, "CLAN_FULL")
					end
				end
				state.members = members
				-- JSON size check belongs inside CAS: an oversized candidate never commits.
				assert(#config.encode(state) <= config.maxBytes, "CLAN_DIRECTORY_FULL")
				return state
			end)
		end)
	end
	local function transact(transform: any): (boolean, any)
		local ok, state = write(transform)
		cached = if ok then Data.clone(state) else nil
		cachedAt = config.fence.now()
		return ok, state
	end
	local function readDirectory(): (boolean, any)
		local now = config.fence.now()
		if cached ~= nil and config.readSeconds and now - cachedAt < config.readSeconds then
			return true, cached
		end
		if not config.dataStore.GetAsync then
			return transact(function(_state: any) end)
		end
		local ok, state = pcall(function(): any
			return config.dataStore:GetAsync("directory")
		end)
		if not ok then
			cached = nil
			return false, state
		end
		cached, cachedAt = if state then Data.clone(state) else { version = 1, records = {}, members = {} }, now
		return true, cached
	end
	local backend = {
		update = function(key: string, transform: any): (boolean, any)
			local ok, result = transact(function(state: any)
				state.records[key] = transform(state.records[key])
			end)
			if ok and config.memoryMap then
				pcall(function()
					config.memoryMap:SetAsync(key, { invalidatedAt = config.fence.now() }, config.cacheSeconds)
				end)
			end
			if ok and config.messaging then
				pcall(function()
					config.messaging:PublishAsync(config.topic, { key = key })
				end)
			end
			return ok, if ok then result.records[key] else tostring(result)
		end,
	}
	local store = Fenced.new(backend, config.fence)
	local api = { store = store }
	function api.create(actor: string, id: string): any
		local outcome: any = nil
		local ok, state = transact(function(directory)
			local existing = directory.members[actor]
			local record = directory.records["clan:" .. id]
			if existing then
				outcome = { ok = existing == id, reason = if existing == id then nil else "ALREADY_IN_CLAN" }
				return
			elseif record then
				outcome = { ok = false, reason = "CLAN_EXISTS" }
				return
			end
			outcome = { ok = true }
			directory.records["clan:" .. id] = {
				version = 1,
				generation = 1,
				revision = 0,
				data = Clan.new(id, actor),
			}
		end)
		return if ok then outcome else { ok = false, reason = tostring(state) }
	end
	function api.membership(actor: string): (string?, string?)
		local ok, state = readDirectory()
		if not ok then
			return nil, tostring(state)
		end
		return state.members[actor], nil
	end
	function api.read(key: string): (any?, string?)
		local ok, state = readDirectory()
		if not ok then
			return nil, tostring(state)
		end
		local record = state.records[key]
		return if record then Data.clone(record.data) else nil, nil
	end
	-- Browse page (name, member count, capacity, recruiting) over the same CAS directory, which
	-- already indexes every clan; a listing only, never membership authority.
	function api.browse(query: string, page: number, size: number): (any?, string?)
		local ok, state = readDirectory()
		if not ok then
			return nil, tostring(state)
		end
		local needle, rows = string.lower(query), {}
		for key, record in state.records do
			local clan = record.data
			if
				string.sub(key, 1, 5) == "clan:"
				and not clan.dissolved
				and string.find(string.lower(clan.clanId), needle, 1, true)
			then
				local count = 0
				for _ in clan.members do
					count += 1
				end
				local capacity = config.rules.maxMembers
				table.insert(
					rows,
					{ id = clan.clanId, members = count, capacity = capacity, recruiting = count < capacity }
				)
			end
		end
		table.sort(rows, function(a: any, b: any): boolean
			return a.id < b.id
		end)
		local pages = math.max(1, math.ceil(#rows / size))
		page = math.clamp(page, 1, pages)
		local slice = table.move(rows, (page - 1) * size + 1, math.min(#rows, page * size), 1, {})
		return { query = query, page = page, pages = pages, total = #rows, rows = slice }, nil
	end
	return api
end

return M
