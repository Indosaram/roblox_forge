--!strict
local Session = require("../../../core/infra/genre/Session")
local MemoryBackend = require("../../../core/infra/data/MemoryBackend")
local Contract = require("../../../genres/survival-coop/module/Contract")
local serde = require("@lune/serde")
local pack = require("../src/shared/GenreConfig")
local policy = require("../src/shared/GenreDurable")
return {
	run = function(_fixture: string?)
		-- Native smoke has no character Instances; keep engine-only death disabled here.
		local nativePack = serde.decode("json", serde.encode("json", pack))
		nativePack.configs["survival-coop"].survivalDeath = false
		local now = 1000
		local session = Session.new(
			{
				packConfig = nativePack,
				contracts = { Contract },
				controls = {},
				storeName = "crafting-smoke",
				durable = policy,
			},
			MemoryBackend.new(),
			{
				sessionId = "smoke",
				lockTimeout = 120,
				retries = 0,
				now = function()
					return now
				end,
			},
			{
				now = function()
					return now
				end,
				roll = function()
					return 0
				end,
				emit = function() end,
				encode = function(value)
					return serde.encode("json", value)
				end,
			},
			policy
		)
		assert(session.join("1").ok, "join")
		local function command(request, action, args)
			return session.command("1", {
				requestId = request,
				sessionEpoch = session.commandEpoch("1"),
				action = "survival-coop:" .. action,
				args = args,
			})
		end
		local reserved = command("reserve", "craft-reserve", { "cord", "hand" })
		assert(reserved.ok, tostring(reserved.reason))
		local job = assert(reserved.data).jobId
		assert(command("start", "craft-start", { job }).ok, "start")
		now += 4
		assert(command("complete", "craft-complete", { job }).ok, "complete")
		local state = session.snapshot("1")["survival-coop"]
		assert(state.workshop.entries[job].job.state == "Committed", "committed job")
		assert(state.inventory.bag.items["starter-fiber"].quantity == 9, "single ingredient debit")
		assert(state.vitals ~= nil, "configured vitals")
		assert(session.close("1").ok, "close")
		return { { name = "native personal crafting commit", ok = true } }
	end,
}
