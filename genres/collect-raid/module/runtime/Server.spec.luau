--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local MemoryBackend = require("../../../../core/infra/data/MemoryBackend")
local ProfileStore = require("../../../../core/infra/data/ProfileStore")
local Receipts = require("../../../../core/infra/monetization/Receipts")

local function selectBackend(studio: boolean, probeFails: boolean): (any, number)
	local source = fs.readFile("genres/collect-raid/module/runtime/Server.luau")
	if process.env.R12_HISTORICAL == "1" then
		local result = process.exec("git", { "show", "9b1d37b:genres/collect-raid/module/runtime/Server.luau" })
		assert(result.ok, result.stderr)
		source = result.stdout
	end
	local block = string.match(source, "\tlocal function dataStoreUsable%b().-\n\tlocal sessionId")
	assert(block ~= nil, "real backend selection found")
	block = string.gsub(block, "\n\tlocal sessionId$", "\nreturn backend")
	local probes = 0
	local storage = MemoryBackend.new()
	local service = {
		GetDataStore = function(_self: any, name: string): any
			assert(name == "fixture", "configured store selected")
			return {
				GetAsync = function()
					probes += 1
					if probeFails then
						error("transient probe failure")
					end
				end,
				UpdateAsync = function(_store: any, key: string, transform: any): any
					if probeFails then
						error("transient durable failure")
					end
					local ok, value = storage.update(key, transform)
					assert(ok, "stub durable update succeeds")
					return value
				end,
			}
		end,
	}
	local adapter = luau.load(
		fs.readFile("core/infra/data/DataStoreBackend.luau"),
		{ environment = {
			game = {
				GetService = function()
					return service
				end,
			},
		} }
	)()
	local backend = luau.load("return function()\n" .. block .. "\nend", {
		environment = {
			RunService = {
				IsStudio = function()
					return studio
				end,
			},
			DataStoreService = service,
			DataStoreBackend = adapter,
			MemoryBackend = MemoryBackend,
			opts = { storeName = "fixture" },
			logPrefix = "",
			print = function() end,
		},
	})()()
	return backend, probes
end

return {
	["production never probes or falls back on startup failure or success"] = function()
		for _, fails in { true, false } do
			local backend, probes = selectBackend(false, fails)
			assert(backend._store ~= nil, "production backend must be durable")
			assert(probes == 0, "production must not gate startup on GetAsync")
			local store = ProfileStore.new(backend, {
				sessionId = "live",
				lockTimeout = 120,
				retries = 3,
				now = function()
					return 10
				end,
			})
			local profile = store:load("player_7", function(raw: any)
				return raw or { coins = 0 }
			end)
			assert((profile == nil) == fails, "durable outage fails closed; healthy storage loads")
		end
	end,
	["studio probe failure allows memory and success uses datastore"] = function()
		for _, fails in { true, false } do
			local backend, probes = selectBackend(true, fails)
			assert((backend._store == nil) == fails, "only Studio outage selects memory")
			assert(probes == 1, "Studio probes once")
			assert(
				backend.update("k", function()
					return {}
				end),
				"Studio selected backend usable"
			)
		end
	end,
	["production receipt cannot acknowledge a failed durable save"] = function()
		local backend = selectBackend(false, true)
		local store = ProfileStore.new(backend, {
			sessionId = "live",
			lockTimeout = 120,
			retries = 3,
			now = function()
				return 10
			end,
		})
		local processed = false
		local profile = store:load("player_7", function(raw: any)
			return raw or { coins = 100 }
		end) or { key = "player_7", data = { coins = 100 } }
		local receipt = Receipts.new({
			grant = function()
				return true
			end,
			hasProcessed = function()
				return processed
			end,
			markProcessed = function()
				processed = true
			end,
			productKeyFor = function()
				return "coins"
			end,
			commit = function()
				return store:save(profile)
			end,
		})
		local input = { PlayerId = 7, ProductId = 1, PurchaseId = "purchase" }
		assert(receipt:process(input) == "NotProcessedYet", "durable save required")
		assert(receipt:process(input) == "NotProcessedYet", "processed ledger still requires durable commit")
	end,
	["healthy production receipt durably saves grant and ledger before acknowledgment"] = function()
		local backend = selectBackend(false, false)
		local store = ProfileStore.new(backend, {
			sessionId = "live",
			lockTimeout = 120,
			retries = 3,
			now = function()
				return 10
			end,
		})
		local profile = store:load("player_7", function(raw: any)
			return raw or { coins = 0, processed = false }
		end)
		assert(profile ~= nil, "durable profile loaded")
		local receipt = Receipts.new({
			grant = function()
				profile.data.coins += 100
				return true
			end,
			hasProcessed = function()
				return profile.data.processed
			end,
			markProcessed = function()
				profile.data.processed = true
			end,
			productKeyFor = function()
				return "coins"
			end,
			commit = function()
				return store:save(profile)
			end,
		})
		local input = { PlayerId = 7, ProductId = 1, PurchaseId = "purchase" }
		assert(receipt:process(input) == "PurchaseGranted", "durable save acknowledged")
		assert(receipt:process(input) == "PurchaseGranted", "retry acknowledged without duplicate grant")
		local reloaded = store:load("player_7", function(raw: any)
			return raw
		end)
		assert(
			reloaded ~= nil and reloaded.data.coins == 100 and reloaded.data.processed,
			"durable grant and ledger survive reload"
		)
	end,
}
