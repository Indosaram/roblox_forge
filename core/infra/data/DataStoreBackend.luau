--!strict
-- Every successful update acknowledges a committed UpdateAsync, never a local
-- write-behind candidate. In particular the transform must see the authoritative
-- fencing token: a cached lease cannot authorize a delayed write or release.
local DataStoreService = game:GetService("DataStoreService")

export type Transform = (old: any) -> any
export type Backend = {
	update: (key: string, transform: Transform) -> (boolean, any),
}
export type Store = Backend & { _store: DataStore }

local DataStoreBackend = {}

function DataStoreBackend.new(storeName: string): Store
	local dataStore = DataStoreService:GetDataStore(storeName)
	return {
		_store = dataStore,
		update = function(key: string, transform: Transform): (boolean, any)
			local ok, result = pcall(function(): any
				return dataStore:UpdateAsync(key, transform)
			end)
			return ok, if ok then result else tostring(result)
		end,
	}
end

return DataStoreBackend
