--!strict
-- One CAS directory owns the membership index and clan envelopes together.
-- The injected DataStore is dedicated to this namespace. Never use cached
-- MemoryStore/MessagingService values as authority for membership or balances.
local Data = require("../../domain/genre/SerializedData")
local Fenced = require("./FencedStore")
local M = {}

function M.new(config: any): any
	local function transact(transform: any): (boolean, any)
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
	function api.membership(actor: string): (string?, string?)
		local ok, state = transact(function(_state: any) end)
		if not ok then
			return nil, tostring(state)
		end
		return state.members[actor], nil
	end
	function api.read(key: string): (any?, string?)
		local ok, state = transact(function(_state: any) end)
		if not ok then
			return nil, tostring(state)
		end
		local record = state.records[key]
		return if record then Data.clone(record.data) else nil, nil
	end
	return api
end

return M
