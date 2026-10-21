--!strict
-- Durable listing/operation records; MemoryStore is only a disposable index.
local Hash = require("../../domain/command/Journal")
local M = {}
function M.new(dataStore: any, memoryStore: any, ascending: any): any
	local cursor: any = nil
	local function key(id: string): string
		return (if string.sub(id, 1, 8) == "listing:" then "listing:" else "operation:") .. Hash.fnv1a64(id)
	end
	local api = {}
	function api.update(id: string, transform: (any) -> any): (boolean, any)
		return pcall(function()
			return dataStore:UpdateAsync(key(id), transform)
		end)
	end
	function api.index(partition: string, listing: any)
		pcall(function()
			local map = memoryStore:GetSortedMap("trade-v1:" .. partition)
			if listing.state == "ACTIVE" then
				map:SetAsync(listing.id, listing, 86400, listing.price)
			else
				map:RemoveAsync(listing.id)
			end
		end)
	end
	function api.search(partition: string): { any }
		local ok, rows = pcall(function()
			return memoryStore:GetSortedMap("trade-v1:" .. partition):GetRangeAsync(ascending, 50)
		end)
		local result = {}
		if ok then
			for _, row in rows do
				table.insert(result, row.value)
			end
		end
		return result
	end
	-- Scan durable keys, not MemoryStore: PREPARED and RESERVED survive index loss.
	function api.pending(): { string }
		local result = {}
		local ok = pcall(function()
			if not cursor then
				cursor = dataStore:ListKeysAsync("listing:", 50)
			end
			for _, row in cursor:GetCurrentPage() do
				local listing = dataStore:GetAsync(row.KeyName)
				if
					listing
					and listing.state ~= "SOLD"
					and listing.state ~= "RETURNED"
					and listing.state ~= "ABORTED"
				then
					table.insert(result, listing.id)
				end
			end
			if cursor.IsFinished then
				cursor = nil
			else
				cursor:AdvanceToNextPageAsync()
			end
		end)
		return if ok then result else {}
	end
	return api
end
return M
