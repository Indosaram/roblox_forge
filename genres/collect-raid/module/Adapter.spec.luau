--!strict
local Executor = require("../../../core/domain/genre/Executor")
local Runtime = require("./Contract")
local Fixture = require("./Adapter.fixture")
local Loop = require("./runtime/Loop")
local Session = require("../../../core/infra/genre/Session")
local MemoryBackend = require("../../../core/infra/data/MemoryBackend")
local function harness(config: { [string]: any }?): (Executor.Executor, (number) -> (), { any }, (number) -> ())
	local now = 0
	local events: { any } = {}
	local executor = Executor.new(
		{ api = 1, order = { "collect-raid" }, configs = { ["collect-raid"] = config or Fixture.config() } },
		{ Runtime },
		{
			now = function()
				return now
			end,
			roll = function()
				return 0
			end,
			emit = function(event)
				table.insert(events, event)
			end,
		}
	)
	return executor,
		function(epoch)
			now = epoch
			executor.advance(epoch)
		end,
		events,
		function(epoch)
			now = epoch
		end
end
local function state(e: Executor.Executor, player: string): any
	return e.snapshot(player)["collect-raid"]
end
return {
	["midnight raid progress survives heartbeat ordering claim and durable rejoin"] = function()
		for _, heartbeatFirst in { false, true } do
			local now = 86399
			local config = Fixture.config()
			config.siege = { period = 1, duration = 0.5, maxTake = 1 }
			config.dailyQuests = { { id = "raid", target = 1, reward = 10 } }
			local services = {
				now = function()
					return now
				end,
				roll = function()
					return 0
				end,
				emit = function() end,
			}
			local pack = { api = 1, order = { Runtime.id }, configs = { [Runtime.id] = config } }
			local executor = Executor.new(pack, { Runtime }, services)
			assert(executor.join("a").ok and executor.join("b").ok, "joined")
			assert(executor.dispatchServer("b", Runtime.id .. ":collect", { "pyro-pup", false }).ok, "vault funded")
			now = 86400
			if heartbeatFirst then
				executor.advance(now)
			end
			assert(executor.dispatchClient("a", Runtime.id .. ":raid", { "blue" }).ok, "midnight raid accepted")
			assert(not executor.dispatchClient("a", Runtime.id .. ":raid", { "blue" }).ok, "empty vault refuses replay")
			local saved = executor.save("a")
			assert(saved.genres[Runtime.id].data.loop.quest.progress.raid == 1, "progress survives serialization")
			local backend = MemoryBackend.new()
			local function fresh(name: string)
				return Session.new({
					packConfig = pack,
					contracts = { Runtime },
					controls = {},
					storeName = "MidnightRaid",
				}, backend, { sessionId = name, lockTimeout = 120, retries = 0, now = services.now }, services)
			end
			local session = fresh("first")
			assert(session.join("a").ok and session.restore("a", saved).ok, "actual profile restored")
			local before = session.snapshot("a")[Runtime.id].coins
			assert(session.dispatch("a", Runtime.id .. ":claim-quest", { "raid" }).ok, "current-day claim")
			assert(session.snapshot("a")[Runtime.id].coins == before + 10, "one complete reward")
			assert(session.save("a").ok and session.close("a").ok, "durable claim and release")
			local restored = fresh("second")
			assert(restored.join("a").ok, "durable rejoin")
			assert(not restored.dispatch("a", Runtime.id .. ":claim-quest", { "raid" }).ok, "no reward replay")
			assert(restored.snapshot("a")[Runtime.id].coins == before + 10, "reward retained")
			assert(restored.close("a").ok, "released")
		end
	end,
	["saturated quest reward remains claimable after spending and durable retry"] = function()
		for _, room in { 0, 149, 150 } do
			local now = 0
			local backend = MemoryBackend.new()
			local config = Fixture.config()
			config.sources.ember.price = 150
			local services = {
				now = function()
					return now
				end,
				roll = function()
					return 0
				end,
				emit = function() end,
			}
			local function create(name: string)
				return Session.new({
					packConfig = { api = 1, order = { Runtime.id }, configs = { [Runtime.id] = config } },
					contracts = { Runtime },
					controls = {},
					storeName = "QuestCapacity",
				}, backend, { sessionId = name, lockTimeout = 120, retries = 0, now = services.now }, services)
			end
			local session = create("first")
			assert(session.join("a").ok, "member joined")
			local envelope = session.envelope("a")
			envelope.genres[Runtime.id].data.loop.coins = 2 ^ 53 - 1 - room
			envelope.genres[Runtime.id].data.loop.quest.progress.buy = 5
			assert(session.restore("a", envelope).ok, "legal completed quest restored")
			local result = session.dispatch("a", "collect-raid:claim-quest", { "buy" })
			assert(result.ok == (room == 150), "only complete fitting reward is accepted")
			local saved = session.envelope("a").genres[Runtime.id].data.loop
			assert(saved.quest.claimed.buy == (room == 150), "refusal never consumes entitlement")
			assert(session.close("a").ok, "refusal state persisted")
			local fresh = create("second")
			assert(fresh.join("a").ok, "profile rejoined")
			if room < 150 then
				assert(fresh.dispatch("a", "collect-raid:buy-source", { "ember" }).ok, "spending opens room")
				assert(fresh.dispatch("a", "collect-raid:claim-quest", { "buy" }).ok, "retained claim succeeds")
			end
			assert(not fresh.dispatch("a", "collect-raid:claim-quest", { "buy" }).ok, "reward paid only once")
			assert(fresh.save("a").ok and fresh.close("a").ok, "paid claim durable")
		end
	end,
	["purchase discards pre-spend saturated income and pays only later interval"] = function()
		local now = 0
		local executor = Executor.new(
			{ api = 1, order = { Runtime.id }, configs = { [Runtime.id] = Fixture.config() } },
			{ Runtime },
			{
				now = function()
					return now
				end,
				roll = function()
					return 0
				end,
				emit = function() end,
			}
		)
		assert(executor.join("a").ok and executor.join("b").ok, "players joined")
		local saved = executor.save("a")
		saved.genres[Runtime.id].data.loop.coins = 2 ^ 53 - 1
		saved.genres[Runtime.id].data.loop.creatures = { "pyro-pup" }
		executor.leave("a")
		assert(executor.join("a", saved).ok, "earning maximum restored")
		now = 1
		assert(executor.dispatchClient("a", "collect-raid:buy-source", { "ember" }).ok, "purchase succeeds")
		now = 2
		assert(
			executor.save("a").genres[Runtime.id].data.loop.coins == 2 ^ 53 - 1 - 54 + 1,
			"pre-spend output discarded"
		)
		assert(executor.snapshot("b")[Runtime.id].coins == 100, "other player not advanced")
	end,
	["ordinary save settles its current clock and survives immediate rejoin"] = function()
		local now = 0
		local backend = MemoryBackend.new()
		local function create(name: string)
			return Session.new(
				{
					packConfig = { api = 1, order = { Runtime.id }, configs = { [Runtime.id] = Fixture.config() } },
					contracts = { Runtime },
					storeName = "SaveClock",
					controls = {},
				},
				backend,
				{
					sessionId = name,
					lockTimeout = 0,
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
				}
			)
		end
		local s = create("first")
		assert(s.join("a").ok and s.dispatch("a", "collect-raid:buy-source", { "ember" }).ok, "earning source bought")
		now = 5
		assert(s.dispatch("a", "collect-raid:hatch", { 1 }).ok, "earning creature hatched")
		now = 5.9
		s.advance(now)
		now = 6
		assert(s.save("a").ok, "ordinary save succeeds")
		local saved = s.envelope("a").genres[Runtime.id].data.loop
		assert(saved.coins == 51 and saved.lastSeen == 6, "ordinary save uses current epoch")
		-- Expire the abandoned session lock without closing (crash recovery).
		now = 6.1
		local fresh = create("second")
		assert(fresh.join("a").ok and fresh.snapshot("a")[Runtime.id].coins == 51, "online whole coin durable")
		assert(fresh.close("a").ok, "rejoined profile releases")
	end,
	["maximum and near maximum earning balances close release and rejoin"] = function()
		for _, balance in { 2 ^ 53 - 1, 2 ^ 53 - 2 } do
			local now = 0
			local backend = MemoryBackend.new()
			local function create(name: string)
				return Session.new(
					{
						packConfig = { api = 1, order = { Runtime.id }, configs = { [Runtime.id] = Fixture.config() } },
						contracts = { Runtime },
						storeName = "MaxIncome",
						controls = {},
					},
					backend,
					{
						sessionId = name,
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
					}
				)
			end
			local s = create("first")
			assert(s.join("a").ok and s.dispatch("a", "collect-raid:buy-source", { "ember" }).ok, "source bought")
			now = 5
			assert(s.dispatch("a", "collect-raid:hatch", { 1 }).ok, "earning creature hatched")
			now = 5.9
			s.advance(now)
			local saved = s.envelope("a")
			saved.genres[Runtime.id].data.loop.coins = balance
			assert(s.restore("a", saved).ok, "legal boundary balance accepted")
			now = 7
			assert(s.close("a").ok and #s.members() == 0, "saturation cannot block departure")
			now = 10
			local fresh = create("second")
			assert(fresh.join("a").ok, "saturated offline income cannot block rejoin")
			assert(fresh.snapshot("a")[Runtime.id].coins == 2 ^ 53 - 1, "income saturates exactly")
			assert(fresh.close("a").ok, "saturated profile releases")
		end
	end,
	["capacity boundaries remain durable through Session close and rejoin"] = function()
		local config = Fixture.config()
		config.startingCoins, config.sources.ember.price = 10000, 1
		config.sources.ember.hatchSeconds, config.pricing.growthPerOwned = 0, 0
		local now = 0
		local backend = MemoryBackend.new()
		local function create(name: string)
			return Session.new(
				{
					packConfig = { api = 1, order = { Runtime.id }, configs = { [Runtime.id] = config } },
					contracts = { Runtime },
					storeName = "CollectCapacity",
					controls = {},
				},
				backend,
				{
					sessionId = name,
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
				}
			)
		end
		local s = create("first")
		assert(s.join("a").ok and s.join("b").ok, "capacity and income regression invariant")
		for _ = 1, 1024 do
			now += 1
			assert(
				s.dispatch("a", "collect-raid:buy-source", { "ember" }).ok,
				"capacity and income regression invariant"
			)
			assert(s.dispatch("a", "collect-raid:hatch", { 1 }).ok, "capacity and income regression invariant")
		end
		now += 1
		assert(s.dispatch("a", "collect-raid:buy-source", { "ember" }).ok, "capacity and income regression invariant")
		local coins = s.snapshot("a")[Runtime.id].coins
		assert(not s.dispatch("a", "collect-raid:hatch", { 1 }).ok, "first overflowing hatch refused")
		assert(
			#s.snapshot("a")[Runtime.id].incubators == 1 and s.snapshot("a")[Runtime.id].coins == coins,
			"refused hatch preserves input"
		)
		assert(s.save("a").ok and s.close("a").ok and s.close("b").ok, "capacity and income regression invariant")
		local nextSession = create("next")
		assert(nextSession.join("a").ok, "capacity and income regression invariant")
		assert(
			#nextSession.snapshot("a")[Runtime.id].creatures == 1024
				and #nextSession.snapshot("a")[Runtime.id].incubators == 1,
			"inventory and incubator survive durable rejoin"
		)
		assert(nextSession.join("b").ok, "capacity and income regression invariant")
		local a, b = nextSession.envelope("a"), nextSession.envelope("b")
		for _ = 1, 1023 do
			table.insert(a.genres[Runtime.id].data.tokens, { id = "pyro-pup", locked = false })
		end
		table.insert(b.genres[Runtime.id].data.tokens, { id = "pyro-pup", locked = false })
		assert(
			nextSession.restore("a", a).ok and nextSession.restore("b", b).ok,
			"capacity and income regression invariant"
		)
		now += 10
		assert(nextSession.dispatch("a", "collect-raid:raid", { "blue" }).ok, "last representable Session raid")
		b = nextSession.envelope("b")
		table.insert(b.genres[Runtime.id].data.tokens, { id = "pyro-pup", locked = false })
		assert(nextSession.restore("b", b).ok, "capacity and income regression invariant")
		assert(not nextSession.dispatch("a", "collect-raid:raid", { "blue" }).ok, "Session overflowing raid rejected")
		assert(nextSession.save("a").ok and nextSession.save("b").ok, "capacity and income regression invariant")
		assert(nextSession.close("a").ok and nextSession.close("b").ok, "capacity and income regression invariant")
		local final = create("final")
		assert(final.join("a").ok and final.join("b").ok, "capacity and income regression invariant")
		assert(
			#final.envelope("a").genres[Runtime.id].data.tokens == 1024
				and #final.envelope("b").genres[Runtime.id].data.tokens == 1,
			"refused raid preserves both durable token ledgers"
		)
		assert(final.close("a").ok and final.close("b").ok, "capacity and income regression invariant")
	end,
	["collect and receiving raid refuse whole transfers above token capacity"] = function()
		local e, advance, _, clock = harness()
		assert(e.join("a", nil).ok and e.join("b", nil).ok, "capacity and income regression invariant")
		for i = 1, 1023 do
			clock(i / 50)
			assert(
				e.dispatchServer("a", "collect-raid:collect", { "pyro-pup", false } :: { any }).ok,
				"capacity and income regression invariant"
			)
		end
		assert(
			e.dispatchServer("b", "collect-raid:collect", { "pyro-pup", false } :: { any }).ok,
			"capacity and income regression invariant"
		)
		advance(30)
		assert(e.dispatchClient("a", "collect-raid:raid", { "blue" }).ok, "last valid raid")
		assert(
			e.dispatchServer("b", "collect-raid:collect", { "pyro-pup", false } :: { any }).ok,
			"capacity and income regression invariant"
		)
		assert(not e.dispatchClient("a", "collect-raid:raid", { "blue" }).ok, "overflow raid refused")
		assert(
			not e.dispatchServer("a", "collect-raid:collect", { "pyro-pup", false } :: { any }).ok,
			"overflow collect refused"
		)
		assert(
			#e.save("a").genres[Runtime.id].data.tokens == 1024 and #e.save("b").genres[Runtime.id].data.tokens == 1,
			"no token moved on refusal"
		)
	end,
	["hatch and merge settle only the acting player at the old income rate"] = function()
		local e, advance, _, clock = harness()
		assert(e.join("a", nil).ok and e.join("b", nil).ok, "capacity and income regression invariant")
		assert(
			e.dispatchClient("a", "collect-raid:buy-source", { "ember" }).ok,
			"capacity and income regression invariant"
		)
		advance(4)
		clock(5)
		assert(e.dispatchClient("a", "collect-raid:hatch", { 1 }).ok, "capacity and income regression invariant")
		advance(6)
		assert(state(e, "a").coins == 51, "new creature earns only after hatch")
		local saved = e.save("a")
		saved.genres[Runtime.id].data.loop.creatures = { "pyro-pup", "pyro-pup", "pyro-pup" }
		e.leave("a")
		assert(e.join("a", saved).ok, "capacity and income regression invariant")
		clock(7)
		assert(
			e.dispatchClient("a", "collect-raid:merge", { "ember", 1 }).ok,
			"capacity and income regression invariant"
		)
		assert(state(e, "a").coins == 54 and state(e, "b").coins == 100, "old merge rate credited only to actor")
		advance(8)
		assert(
			state(e, "a").coins == 54 + Fixture.config().creatures["magma-mauler"].coinsPerSecond,
			"capacity and income regression invariant"
		)
	end,
	["final Session save settles carry across a whole coin boundary without hooks"] = function()
		local now, events = 0, 0
		local backend = MemoryBackend.new()
		local function create(name: string)
			return Session.new(
				{
					packConfig = { api = 1, order = { Runtime.id }, configs = { [Runtime.id] = Fixture.config() } },
					contracts = { Runtime },
					storeName = "CollectIncome",
					controls = {},
				},
				backend,
				{
					sessionId = name,
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
					emit = function()
						events += 1
					end,
				}
			)
		end
		local s = create("first")
		assert(
			s.join("a").ok and s.dispatch("a", "collect-raid:buy-source", { "ember" }).ok,
			"capacity and income regression invariant"
		)
		now = 5
		assert(s.dispatch("a", "collect-raid:hatch", { 1 }).ok, "capacity and income regression invariant")
		now = 5.9
		s.advance(now)
		assert(s.snapshot("a")[Runtime.id].coins == 50, "capacity and income regression invariant")
		local before = events
		now = 6
		assert(s.save("a").ok and s.close("a").ok, "capacity and income regression invariant")
		assert(events == before, "serialization does not replay gameplay hooks")
		local nextSession = create("next")
		assert(
			nextSession.join("a").ok and nextSession.snapshot("a")[Runtime.id].coins == 51,
			"final earned coin survives close"
		)
		assert(nextSession.close("a").ok, "capacity and income regression invariant")
	end,
	["late restored players accrue only their online intervals without overlapping offline income"] = function()
		local original, advance = harness()
		assert(original.join("seed", nil).ok, "earning seed joins")
		assert(original.dispatchClient("seed", "collect-raid:buy-source", { "ember" }).ok, "seed buys source")
		advance(5)
		assert(original.dispatchClient("seed", "collect-raid:hatch", { 1 }).ok, "seed hatches earning creature")
		local saved = original.save("seed")
		original.leave("seed")
		local e, tick, _, setClock = harness()
		setClock(5)
		assert(e.join("a", saved).ok, "first late restored join")
		assert(state(e, "a").coins == 50, "same-time join has no offline reward")
		setClock(5.5)
		assert(e.join("b", saved).ok, "second distinct late restored join")
		tick(6)
		assert(state(e, "a").coins == 51 and state(e, "b").coins == 50, "individual join baselines")
		tick(6.5)
		assert(state(e, "a").coins == 51 and state(e, "b").coins == 51, "fractional accrual retained")
		e.leave("a")
		setClock(7)
		assert(e.join("a", saved).ok, "left player rejoins with new accrual baseline")
		local offline = math.floor(2 * Fixture.config().offline.efficiency)
		assert(state(e, "a").coins == 50 + offline, "offline reward uses only saved lastSeen")
		tick(8)
		assert(state(e, "a").coins == 51 + offline, "offline and online intervals do not overlap")
	end,
	["zero quest reward is rejected before runtime join"] = function()
		local config = Fixture.config()
		config.dailyQuests[1].reward = 0
		assert(#Runtime.validateConfig(config) > 0, "native quests require positive rewards")
		assert(not pcall(harness, config), "executor preflights invalid quest reward")
		config.dailyQuests[1].reward = 1
		local e = harness(config)
		assert(e.join("a", nil).ok, "minimum positive reward reaches native join")
	end,
	["zero source price is rejected before runtime purchase"] = function()
		local config = Fixture.config()
		config.sources.ember.price = 0
		assert(#Runtime.validateConfig(config) > 0, "wallet debits require positive source prices")
		assert(not pcall(harness, config), "executor preflights free source")
		config.sources.ember.price = 1
		local e = harness(config)
		assert(e.join("a", nil).ok, "minimum price config joins")
		assert(e.dispatchClient("a", "collect-raid:buy-source", { "ember" }).ok, "minimum positive price buys")
		assert(state(e, "a").coins == 99, "minimum purchase debits exactly one")
	end,
	["zero offline efficiency is rejected while zero duration saves and rejoins"] = function()
		local config = Fixture.config()
		config.offline.efficiency = 0
		assert(#Runtime.validateConfig(config) > 0, "native offline efficiency must be positive")
		assert(not pcall(harness, config), "executor preflights invalid offline efficiency")
		config.offline.efficiency, config.offline.maxSeconds = 1, 0
		local e, advance = harness(config)
		assert(e.join("a", nil).ok, "zero offline duration joins")
		assert(e.dispatchClient("a", "collect-raid:buy-source", { "ember" }).ok, "zero duration buys source")
		advance(5)
		assert(e.dispatchClient("a", "collect-raid:hatch", { 1 }).ok, "zero duration hatches earning creature")
		local saved = e.save("a")
		e.leave("a")
		advance(20)
		assert(e.join("a", saved).ok and state(e, "a").coins == 50, "zero duration disables offline reward")
	end,
	["legacy CamelCase IDs and fractional money boundary"] = function()
		local config = Fixture.config()
		config.sources.EmberEgg = config.sources.ember
		config.sources.ember = nil
		config.sources.EmberEgg.id = "EmberEgg"
		config.sourceOrder[1] = "EmberEgg"
		config.mergeFamilies[1].id = "EmberEgg"
		config.teams = { "Red Team", 'Blue"Team' }
		local now = 0
		local e = Executor.new(
			{ api = 1, order = { "collect-raid" }, configs = { ["collect-raid"] = config } },
			{ Runtime },
			{
				now = function()
					return now
				end,
				roll = function()
					return 0
				end,
				emit = function() end,
			}
		)
		assert(e.join("a", nil).ok, "legacy IDs join")
		assert(e.dispatchClient("a", "collect-raid:buy-source", { "EmberEgg" }).ok, "CamelCase source accepted")
		now = 5
		e.advance(now)
		assert(e.dispatchClient("a", "collect-raid:hatch", { 1 }).ok, "legacy hatch")
		local saved = e.save("a")
		e.leave("a")
		assert(e.join("a", saved).ok, "quoted team restores")
		for _, field in { "startingCoins", "price", "reward" } do
			local invalid = Fixture.config()
			if field == "startingCoins" then
				invalid.startingCoins = 0.5
			elseif field == "price" then
				invalid.sources.ember.price = 0.5
			else
				invalid.dailyQuests[1].reward = 0.5
			end
			assert(#Runtime.validateConfig(invalid) > 0, "fractional money rejected: " .. field)
		end
	end,
	["merge rules are server resolved and quest claim pays once"] = function()
		local e = harness()
		assert(e.join("a", nil).ok, "join")
		local saved = e.save("a")
		saved.genres["collect-raid"].data.loop.creatures = { "pyro-pup", "pyro-pup", "pyro-pup" }
		saved.genres["collect-raid"].data.loop.quest.progress.hatch = 3
		e.leave("a")
		assert(e.join("a", saved).ok, "restore")
		assert(e.dispatchClient("a", "collect-raid:merge", { "ember", 1 }).ok, "native merge")
		assert(state(e, "a").creatures[1] == "magma-mauler" and #state(e, "a").creatures == 1, "native rarity merge")
		assert(e.dispatchClient("a", "collect-raid:claim-quest", { "hatch" }).ok, "native claim")
		assert(not e.dispatchClient("a", "collect-raid:claim-quest", { "hatch" }).ok, "no duplicate claim")
		assert(state(e, "a").coins == 200, "one reward")
	end,
	["executor runs exact hatch boundary team vault raid and restore"] = function()
		local e, advance, events = harness()
		assert(e.join("a", nil).ok and e.join("b", nil).ok, "Adapter.spec.luau invariant")
		assert(state(e, "a").team == "red" and state(e, "b").team == "blue", "Adapter.spec.luau invariant")
		assert(e.dispatchClient("a", "collect-raid:buy-source", { "ember" }).ok, "Adapter.spec.luau invariant")
		assert(state(e, "a").coins == 50, "Adapter.spec.luau invariant")
		advance(4.999)
		assert(not e.dispatchClient("a", "collect-raid:hatch", { 1 }).ok, "Adapter.spec.luau invariant")
		advance(5)
		assert(e.dispatchClient("a", "collect-raid:hatch", { 1 }).ok, "Adapter.spec.luau invariant")
		assert(state(e, "a").creatures[1] == "pyro-pup", "Adapter.spec.luau invariant")
		assert(
			e.dispatchServer("b", "collect-raid:collect", { "pyro-pup", false } :: { any }).ok,
			"Adapter.spec.luau invariant"
		)
		assert(e.dispatchServer("b", "collect-raid:collect", { "solar-titan", true }).ok, "Adapter.spec.luau invariant")
		advance(10)
		assert(e.dispatchClient("a", "collect-raid:raid", { "blue" }).ok, "Adapter.spec.luau invariant")
		assert(state(e, "a").counts.red == 1 and state(e, "b").counts.blue == 0, "Adapter.spec.luau invariant")
		assert(state(e, "b").totalCounts.blue == 1, "Adapter.spec.luau invariant")
		assert(state(e, "a").coins == 55, "Adapter.spec.luau invariant")
		local saved = e.save("a")
		e.leave("a")
		assert(e.join("a", saved).ok, "Adapter.spec.luau invariant")
		assert(state(e, "a").coins == 55 and state(e, "a").counts.red == 1, "Adapter.spec.luau invariant")
		saved.genres["collect-raid"].data.loop.coins = 999
		assert(state(e, "a").coins == 55, "Adapter.spec.luau invariant")
		local raids, phases = 0, 0
		for _, event in events do
			if event.name == "OnRaid" then
				raids += 1
			elseif event.name == "OnSiegePhase" then
				phases += 1
			end
		end
		assert(raids == 1 and phases == 1, "Adapter.spec.luau invariant")
	end,
	["malicious tuples and server collect are immutable"] = function()
		local e = harness()
		assert(e.join("a", nil).ok, "Adapter.spec.luau invariant")
		local inputs: { { any } } = {
			{ "collect-raid:collect", { "pyro-pup", false } :: { any } },
			{ "collect-raid:hatch", { 0 / 0 } },
			{ "collect-raid:hatch", { math.huge } },
			{ "collect-raid:merge", { "ember", { count = 1 } } :: { any } },
			{ "collect-raid:buy-source", { "ember", "b" } },
			{ "collect-raid:raid", { "unknown" } },
			{ "collect-raid:hatch", { [2] = 1 } },
		}
		for _, input in inputs do
			assert(not e.dispatchClient("a", input[1], input[2]).ok, "Adapter.spec.luau invariant")
		end
		assert(
			state(e, "a").coins == 100 and #state(e, "a").incubators == 0 and state(e, "a").totalCounts.red == 0,
			"Adapter.spec.luau invariant"
		)
	end,
	["paid deterministic native grant receipt and shield survive adapter restore"] = function()
		local e, advance = harness()
		assert(e.join("a", nil).ok and e.join("b", nil).ok, "Adapter.spec.luau invariant")
		local saved = e.save("b")
		local config = Fixture.config() :: any
		config.profile = {
			version = 1,
			defaults = function()
				return {}
			end,
		}
		local native = Loop.fromSave(config, saved.genres["collect-raid"].data.loop, 0)
		assert(
			Loop.grantProduct(config, native, { kind = "kaiju", kaijuId = "solar-titan" }, 0),
			"Adapter.spec.luau invariant"
		)
		assert(Loop.grantProduct(config, native, { kind = "shield", seconds = 11 }, 0), "Adapter.spec.luau invariant")
		Loop.markProcessed(native, "paid-deterministic")
		assert(#native.creatures == 0 and native.vaultedCreatures[1] == "solar-titan", "Adapter.spec.luau invariant")
		saved.genres["collect-raid"].data.loop = Loop.toSave(config, native, 0)
		e.leave("b")
		assert(e.join("b", saved).ok, "Adapter.spec.luau invariant")
		assert(
			e.dispatchServer("b", "collect-raid:collect", { "pyro-pup", false } :: { any }).ok,
			"Adapter.spec.luau invariant"
		)
		advance(10)
		assert(not e.dispatchClient("a", "collect-raid:raid", { "blue" }).ok, "Adapter.spec.luau invariant")
		advance(11)
		assert(e.dispatchClient("a", "collect-raid:raid", { "blue" }).ok, "Adapter.spec.luau invariant")
		local restored = Loop.fromSave(config, e.save("b").genres["collect-raid"].data.loop, 11)
		assert(
			Loop.hasProcessed(restored, "paid-deterministic") and #restored.vaultedCreatures == 1,
			"Adapter.spec.luau invariant"
		)
	end,
	["unknown fields references and future slices fail validation"] = function()
		local config = Fixture.config()
		assert(#Runtime.validateConfig(config) == 0, "Adapter.spec.luau invariant")
		config.arbitrary = true
		assert(#Runtime.validateConfig(config) > 0, "Adapter.spec.luau invariant")
		config = Fixture.config()
		config.sources.ember = table.clone(config.sources.ember)
		config.sources.ember.pool = { { id = "missing", weight = 1 } }
		assert(#Runtime.validateConfig(config) > 0, "Adapter.spec.luau invariant")
		local e = harness()
		assert(e.join("a", nil).ok, "Adapter.spec.luau invariant")
		local saved = e.save("a")
		e.leave("a")
		saved.genres["collect-raid"].version = 2
		assert(not e.join("a", saved).ok, "Adapter.spec.luau invariant")
	end,
}
