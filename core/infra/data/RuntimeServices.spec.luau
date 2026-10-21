--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")

local function harness(studio: boolean, marker: string?): (any, any, any)
	local at = { value = 100 }
	local real: any = {}
	local module = luau.load(fs.readFile("core/infra/data/RuntimeServices.luau"), {
		environment = {
			task = task,
			Enum = { SortDirection = { Ascending = "asc", Descending = "desc" } },
			DateTime = {
				now = function()
					return { UnixTimestampMillis = at.value * 1000 }
				end,
			},
			game = {
				GameId = if studio then 0 else 123,
				GetService = function(_, name): any
					if name == "RunService" then
						return {
							IsStudio = function()
								return studio
							end,
						}
					elseif name == "ServerStorage" then
						return {
							FindFirstChild = function(_, child)
								return if child == marker then {} else nil
							end,
						}
					end
					real[name] = real[name] or {}
					return real[name]
				end,
			},
		},
	})()
	return module, real, at
end

return {
	["only Studio memory selects local services and owned persistent modes keep real services"] = function()
		for _, studio in { false, true } do
			for _, mode in { "memory", "studio-datastore", "studio-local" } do
				local runtime, real = harness(studio)
				local services = runtime.new({ mode = mode })
				if studio and mode == "memory" then
					assert(services == runtime.new({ mode = mode }), "one server shares services")
					assert(next(real) == nil, "memory never obtains cloud services")
				else
					assert(services.dataStoreService == real.DataStoreService, "real datastore")
					assert(services.memoryStoreService == real.MemoryStoreService, "real memory store")
					assert(services.messagingService == real.MessagingService, "real messaging")
				end
			end
		end
		for _, marker in { "ForgeOwnedPersistenceConfig", "ForgePersistence" } do
			local runtime, real = harness(true, marker)
			assert(
				runtime.new({ mode = "memory" }).dataStoreService == real.DataStoreService,
				"owned persistent launch"
			)
		end
	end,
	["datastore transforms cancel without mutation and retain key info and versions"] = function()
		local runtime = harness(true)
		local services = runtime.new({ mode = "memory" })
		local store = services.dataStoreService:GetDataStore("test")
		local value, info = store:UpdateAsync("one", function(old, keyInfo)
			assert(old == nil and keyInfo == nil, "missing key")
			return { count = 1 }, { 42 }, { tag = "first" }
		end)
		assert(value.count == 1 and info.Version == "1", "first commit")
		assert(info:GetUserIds()[1] == 42 and info:GetMetadata().tag == "first", "metadata commit")
		assert(store:UpdateAsync("one", function(old, keyInfo)
			assert(keyInfo.Version == "1", "transform sees committed version")
			old.count = 99
			return nil
		end) == nil, "nil cancels update")
		value, info = store:GetAsync("one")
		assert(value.count == 1 and info.Version == "1", "cancel cannot leak transform mutations")
		assert(not pcall(function()
			store:UpdateAsync("one", function(old)
				old.count = 88
				error("refused")
			end)
		end), "transform errors propagate")
		assert(store:GetAsync("one").count == 1, "error does not commit")
		value.count = 5
		assert(store:GetAsync("one").count == 1, "read returns a copy")
		assert(store:SetAsync("one", { count = 2 }) == "2", "next version")
		assert(store:RemoveAsync("one").count == 2 and store:GetAsync("one") == nil, "remove returns old value")
		store:SetAsync("listing:b", {})
		store:SetAsync("listing:a", {})
		store:SetAsync("other", {})
		local pages = store:ListKeysAsync("listing:", 1)
		assert(not pages.IsFinished and pages:GetCurrentPage()[1].KeyName == "listing:a", "first page")
		pages:AdvanceToNextPageAsync()
		assert(pages.IsFinished and pages:GetCurrentPage()[1].KeyName == "listing:b", "last page")
	end,
	["sorted maps order tied keys and honor range bounds cancellation and expiration"] = function()
		local runtime, _, at = harness(true)
		local map = runtime.new({ mode = "memory" }).memoryStoreService:GetSortedMap("test")
		map:SetAsync("b", { n = 2 }, 10, 3)
		map:SetAsync("a", { n = 1 }, 10, 3)
		map:SetAsync("c", { n = 3 }, 20, 4)
		assert(map:GetRangeAsync("asc", 2)[1].key == "a", "ascending tie order")
		assert(map:GetRangeAsync("desc", 1)[1].key == "c", "descending limit")
		assert(
			#map:GetRangeAsync("asc", 10, { key = "a", sortKey = 3 }, { key = "c", sortKey = 4 }) == 1,
			"exclusive bounds"
		)
		assert(map:UpdateAsync("a", function(old, sortKey)
			assert(sortKey == 3, "transform sort key")
			old.n = 99
			return nil
		end, 100) == nil, "cancel sorted update")
		assert(map:GetAsync("a").n == 1, "cancel isolates candidate")
		local value, sortKey = map:UpdateAsync("c", function(old: any)
			return { n = old.n + 1 }, 1
		end, 20)
		assert(value.n == 4 and sortKey == 1, "updated sorted value")
		at.value = 110
		assert(map:GetAsync("a") == nil and #map:GetRangeAsync("asc", 10) == 1, "expiry at deadline")
		map:RemoveAsync("c")
		assert(#map:GetRangeAsync("asc", 10) == 0, "remove sorted item")
	end,
	["messaging delivers topic data and disconnect stops delivery"] = function()
		local runtime = harness(true)
		local messaging = runtime.new({ mode = "memory" }).messagingService
		local received = nil
		local connection = messaging:SubscribeAsync("topic", function(message)
			received = message
		end)
		messaging:PublishAsync("other", "ignored")
		assert(received == nil, "topic isolation")
		messaging:PublishAsync("topic", { n = 1 })
		assert(received and received.Data.n == 1 and received.Sent == 100, "message envelope")
		connection:Disconnect()
		messaging:PublishAsync("topic", { n = 2 })
		assert(received.Data.n == 1 and not connection.Connected, "disconnect prevents delivery")
	end,
}
