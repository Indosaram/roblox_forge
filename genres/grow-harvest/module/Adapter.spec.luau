--!strict
local Adapter = require("./Adapter")
local Fixture = require("./Adapter.fixture")
local Shared = require("../../../core/domain/genre/Contract")
local serde = require("@lune/serde")
local function harness(config: Adapter.Config?)
	local clock = 100
	local events: { Shared.Event } = {}
	local services: Shared.Services = {
		now = function()
			return clock
		end,
		roll = function()
			return 0
		end,
		emit = function(event)
			table.insert(events, event)
		end,
	}
	local adapter = Adapter.create(config or Fixture.config(), services)
	return adapter, function(now: number)
		clock = now
		adapter.advance(now)
	end, events
end
local function bytes(data: Shared.StateData): string
	return serde.encode("json", data)
end
local function refusal(adapter: Adapter.Instance, action: string, args: { any }, events: { Shared.Event })
	local before, count = bytes(adapter.save("p")), #events
	assert(not adapter.dispatch("p", action, args).ok, 'expected not adapter.dispatch("p", action, args).ok')
	assert(bytes(adapter.save("p")) == before and #events == count, "failure changed ledger or emitted event")
end
return {
	["native effects and exact timers own the authoritative ledger"] = function()
		local a, advance, events = harness()
		assert(a.join("p").ok, 'expected a.join("p").ok')
		assert(a.dispatch("p", "buy-seed", { "carrot" }).ok, 'expected a.dispatch("p", "buy-seed", { "carrot" }).ok')
		assert(
			a.snapshot("p").balance == 9 and a.snapshot("p").seeds.carrot == 2,
			'expected a.snapshot("p").balance == 9 and a.snapshot("p").seeds.carrot == 2'
		)
		assert(a.dispatch("p", "plant", { 1, "carrot" }).ok, 'expected a.dispatch("p", "plant", { 1, "carrot" }).ok')
		assert(
			a.snapshot("p").seeds.carrot == 1 and a.snapshot("p").plots[1].readyAt == 102,
			'expected a.snapshot("p").seeds.carrot == 1 and a.snapshot("p").plots[1].readyAt == 102'
		)
		refusal(a, "plant", { 1, "carrot" }, events)
		advance(101.999)
		refusal(a, "harvest", { 1 }, events)
		advance(102)
		assert(a.snapshot("p").plots[1].ready, 'expected a.snapshot("p").plots[1].ready')
		assert(a.dispatch("p", "harvest", { 1 }).ok, 'expected a.dispatch("p", "harvest", { 1 }).ok')
		assert(
			a.snapshot("p").inventory.carrot == 1 and a.snapshot("p").plots[1].cropId == nil,
			'expected a.snapshot("p").inventory.carrot == 1 and a.snapshot("p").plots[1].cropId == nil'
		)
		refusal(a, "harvest", { 1 }, events)
		assert(a.dispatch("p", "sell-held", { "carrot" }).ok, 'expected a.dispatch("p", "sell-held", { "carrot" }).ok')
		assert(
			a.snapshot("p").balance == 19 and a.snapshot("p").inventory.carrot == 0,
			'expected a.snapshot("p").balance == 19 and a.snapshot("p").inventory.carrot == 0'
		)
		refusal(a, "sell-held", { "carrot" }, events)
		assert(
			#events == 4
				and events[1].name == "SeedBought"
				and events[2].name == "OnPlant"
				and events[3].name == "OnHarvest"
				and events[4].name == "CropSold",
			'expected #events == 4 and events[1].name == "SeedBought" and events[2].name == "OnPlant" and events[3].name == "OnHarvest" and events[4].name == "CropSold"'
		)
	end,
	["malformed and malicious actions cannot mutate"] = function()
		local a, _, events = harness()
		assert(a.join("p").ok, 'expected a.join("p").ok')
		local malicious: { { any } } = {
			{ 0, "carrot" },
			{ 3, "carrot" },
			{ 1.5, "carrot" },
			{ 0 / 0, "carrot" },
			{ math.huge, "carrot" },
			{ 1, "unknown" },
			{ 1, "carrot", "extra" },
			{ [1] = 1, [3] = "carrot" },
			{ [1] = 1, [2] = "carrot", forged = "p" },
		}
		for _, args in malicious do
			refusal(a, "plant", args, events)
		end
		refusal(a, "sell-held", { "carrot" }, events)
		refusal(a, "buy-seed", { "unknown" }, events)
		refusal(a, "hook", {}, events)
		assert(
			not a.dispatch("forged", "buy-seed", { "carrot" }).ok,
			'expected not a.dispatch("forged", "buy-seed", { "carrot" }).ok'
		)
		assert(a.dispatch("p", "plant", { 1, "carrot" }).ok, 'expected a.dispatch("p", "plant", { 1, "carrot" }).ok')
		refusal(a, "plant", { 2, "carrot" }, events)
	end,
	["save restore preserves expired planted crops without payout or events and isolates aliases"] = function()
		local config = Fixture.config()
		local a, advance, events = harness(config)
		config.crops.carrot.sellPrice = 999
		config.startingSeeds.carrot = 999
		assert(a.join("p").ok, 'expected a.join("p").ok')
		assert(a.dispatch("p", "plant", { 2, "carrot" }).ok, 'expected a.dispatch("p", "plant", { 2, "carrot" }).ok')
		local save = a.save("p")
		local clean = a.save("p")
		save.balance = 999
		save.seeds.carrot = 999
		save.plots[1].plantedAt = 0
		assert(bytes(a.save("p")) == bytes(clean), 'expected bytes(a.save("p")) == bytes(clean)')
		advance(110)
		a.leave("p")
		local eventCount = #events
		assert(a.join("p", clean).ok, 'expected a.join("p", clean).ok')
		clean.balance = 777
		clean.seeds.carrot = 777
		clean.plots[1].plantedAt = 109
		local state = a.snapshot("p")
		assert(
			#events == eventCount
				and state.balance == 10
				and state.seeds.carrot == 0
				and state.plots[2].readyAt == 102
				and state.plots[2].ready,
			"expected #events == eventCount and state.balance == 10 and state.seeds.carrot == 0 and state.plots[2].readyAt == 102 and state.plots[2].ready"
		)
		state.inventory.carrot = 777
		state.plots[2].readyAt = 888
		assert(a.snapshot("p").plots[2].readyAt == 102, 'expected a.snapshot("p").plots[2].readyAt == 102')
		assert(
			a.dispatch("p", "harvest", { 2 }).ok and a.dispatch("p", "sell-held", { "carrot" }).ok,
			'expected a.dispatch("p", "harvest", { 2 }).ok and a.dispatch("p", "sell-held", { "carrot" }).ok'
		)
		assert(a.snapshot("p").balance == 20, 'expected a.snapshot("p").balance == 20')
	end,
	["saved references and future times reject before join mutation"] = function()
		local a, _, events = harness()
		local invalid: { Shared.StateData } = {
			{ balance = 10, seeds = { turnip = 1 }, inventory = {}, plots = {} },
			{ balance = 10, seeds = {}, inventory = { turnip = 1 }, plots = {} },
			{ balance = 10, seeds = {}, inventory = {}, plots = { { plot = 3, cropId = "carrot", plantedAt = 100 } } },
			{ balance = 10, seeds = {}, inventory = {}, plots = { { plot = 1, cropId = "turnip", plantedAt = 100 } } },
			{ balance = 10, seeds = {}, inventory = {}, plots = { { plot = 1, cropId = "carrot", plantedAt = 101 } } },
			{
				balance = 10,
				seeds = {},
				inventory = {},
				plots = {
					{ plot = 1, cropId = "carrot", plantedAt = 100 },
					{ plot = 1, cropId = "carrot", plantedAt = 100 },
				},
			},
			{ balance = math.huge, seeds = {}, inventory = {}, plots = {} },
			{
				balance = 10,
				seeds = {},
				inventory = {},
				plots = { [2] = { plot = 1, cropId = "carrot", plantedAt = 100 } },
			},
			{ balance = 10, seeds = {}, inventory = {}, plots = {}, version = 2 },
		}
		for _, saved in invalid do
			assert(not a.join("p", saved).ok and #events == 0, 'expected not a.join("p", saved).ok and #events == 0')
		end
		assert(
			a.join("p").ok and a.snapshot("p").balance == 10,
			'expected a.join("p").ok and a.snapshot("p").balance == 10'
		)
	end,
	["config bounds native integer money and canonical crop IDs"] = function()
		assert(
			#Adapter.validateConfig(Fixture.config()) == 0,
			"expected #Adapter.validateConfig(Fixture.config()) == 0"
		)
		for _, value in { 0, -1, 65, 1.5, math.huge, 0 / 0 } do
			local c = Fixture.config()
			c.plotCount = value
			assert(#Adapter.validateConfig(c) > 0, "expected #Adapter.validateConfig(c) > 0")
		end
		for _, value in { 0, -1, math.huge, 0 / 0, 86401 } do
			local c = Fixture.config()
			c.crops.carrot.growthSeconds = value
			assert(#Adapter.validateConfig(c) > 0, "expected #Adapter.validateConfig(c) > 0")
		end
		for _, value in { 0, 1.5, -1, math.huge, 0 / 0, 1e9 + 1 } do
			local c = Fixture.config()
			c.seedPrice.carrot = value
			assert(#Adapter.validateConfig(c) > 0, "expected #Adapter.validateConfig(c) > 0")
		end
		for _, name in { "carrot-", "carrot--root", "Carrot", "-carrot" } do
			local c = Fixture.config()
			c.crops[name] = { growthSeconds = 2, sellPrice = 10 }
			assert(#Adapter.validateConfig(c) > 0, "expected #Adapter.validateConfig(c) > 0")
		end
		local c: Shared.ConfigData = Fixture.config()
		c.extra = true
		assert(#Adapter.validateConfig(c) > 0, "expected #Adapter.validateConfig(c) > 0")
		c = Fixture.config()
		c.seedPrice = {}
		assert(#Adapter.validateConfig(c) > 0, "expected #Adapter.validateConfig(c) > 0")
		c = Fixture.config()
		c.startingSeeds.turnip = 1
		assert(#Adapter.validateConfig(c) > 0, "expected #Adapter.validateConfig(c) > 0")
		c = Fixture.config()
		c.crops.carrot.sellPrice = 0.5
		assert(#Adapter.validateConfig(c) > 0, "expected #Adapter.validateConfig(c) > 0")
	end,
	["composition wallet is the single native balance and enforces bounds"] = function()
		local a = harness()
		assert(a.join("p").ok, 'expected a.join("p").ok')
		local port = a.walletPort
		assert(
			port.balance("p") == 10 and port.debit("p", 10) and port.balance("p") == 0,
			'expected port.balance("p") == 10 and port.debit("p", 10) and port.balance("p") == 0'
		)
		assert(
			not port.debit("p", 1)
				and not port.debit("p", 0)
				and not port.debit("p", 0 / 0)
				and not port.debit("p", 0.5),
			'expected not port.debit("p", 1) and not port.debit("p", 0) and not port.debit("p", 0 / 0) and not port.debit("p", 0.5)'
		)
		port.credit("p", 5)
		assert(a.save("p").balance == 5, 'expected a.save("p").balance == 5')
		for _, amount in { 0, -1, math.huge, 0 / 0, 0.5, 1e9 } do
			assert(not pcall(function()
				port.credit("p", amount)
			end), 'expected not pcall(function() port.credit("p", amount) end)')
			assert(port.balance("p") == 5, 'expected port.balance("p") == 5')
		end
		port.credit("p", 1e9 - 5)
		assert(port.balance("p") == 1e9, 'expected port.balance("p") == 1e9')
	end,
	["ledger overflow and insufficient funds reject without mutation"] = function()
		local a, _, events = harness()
		assert(
			a.join("p", { balance = 0, seeds = { carrot = 1e9 }, inventory = { carrot = 1 }, plots = {} }).ok,
			'expected a.join("p", { balance = 0, seeds = { carrot = 1e9 }, inventory = { carrot = 1 }, plots = {} }).ok'
		)
		refusal(a, "buy-seed", { "carrot" }, events)
		a.leave("p")
		assert(
			a.join("p", { balance = 1e9, seeds = {}, inventory = { carrot = 1 }, plots = {} }).ok,
			'expected a.join("p", { balance = 1e9, seeds = {}, inventory = { carrot = 1 }, plots = {} }).ok'
		)
		refusal(a, "sell-held", { "carrot" }, events)
		a.leave("p")
		assert(
			a.join("p", { balance = 0, seeds = {}, inventory = {}, plots = {} }).ok,
			'expected a.join("p", { balance = 0, seeds = {}, inventory = {}, plots = {} }).ok'
		)
		refusal(a, "buy-seed", { "carrot" }, events)
	end,
}
