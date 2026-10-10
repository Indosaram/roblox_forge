--!strict
-- DataStoreBackend: ProfileStore backend adapting DataStoreService:UpdateAsync.

local DataStoreService = game:GetService("DataStoreService")

export type Transform = (old: any) -> any

export type Backend = {
	update: (key: string, transform: Transform) -> (boolean, any),
}

export type Store = Backend & {
	_store: DataStore,
}

local DataStoreBackend = {}

-- Runs the transform inside a single atomic UpdateAsync. Any DataStore failure
-- is reported as (false, reason) so ProfileStore can retry or surface it.
function DataStoreBackend.new(storeName: string): Store
	local dataStore = DataStoreService:GetDataStore(storeName)
	return {
		_store = dataStore,
		update = function(key: string, transform: Transform): (boolean, any)
			local ok, result = pcall(function(): any
				return dataStore:UpdateAsync(key, transform)
			end)
			if ok then
				return true, result
			end
			return false, tostring(result)
		end,
	}
end

return DataStoreBackend
