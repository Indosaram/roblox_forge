--!strict
local Services = require("./SurvivalServices")
local Memory = require("../../../core/infra/data/MemoryBackend")
local function config(): Services.Config
	return {
		tribes = {},
		maxServerPlayers = 8,
		maxPlots = 4,
		maxReceipts = 4096,
		tribeFor = function()
			return nil
		end,
		authorize = function()
			return { ok = true }
		end,
		consent = function()
			return false
		end,
		proof = function()
			return nil
		end,
	}
end
local options = {
	sessionId = "services-spec",
	leaseSeconds = 120,
	now = function()
		return 0
	end,
	budget = {
		encode = function()
			return "{}"
		end,
	},
}
return {
	["unlinked actors receive no implicit tribe authority"] = function()
		local factory = assert(Services.new(config(), Memory.new(), options))
		assert(factory.services.survivalSettlement.link("outsider") == nil, "no automatic membership")
		assert(factory.services.survivalTransfer.epoch("outsider", "survival-coop:transfer-deposit") == nil, "no epoch")
		local results = factory.services.survivalTransfer.recover("outsider", 8)
		assert(#results == 1, "unavailable owner remains pending")
		local result = results[1]
		assert(
			result.status == "recovering" and result.phase == "DISCOVERY" and result.error == "TRANSFER_UNAVAILABLE",
			"explicit unavailable discovery result"
		)
		assert(result.id == nil and result.source == nil and result.destination == nil, "no hidden personal owner")
		assert(factory.close().ok, "close empty factory")
	end,
	["factory rejects oversized server and plot policy"] = function()
		local value = config()
		value.maxServerPlayers = 9
		assert(not pcall(Services.new, value, Memory.new(), options), "server cap")
		value = config()
		value.maxPlots = 5
		assert(not pcall(Services.new, value, Memory.new(), options), "plot cap")
	end,
}
