--!strict
local Adapter = require("./Adapter")
local Fixture = require("./Adapter.fixture")
local Executor = require("../../../core/domain/genre/Executor")
local Contract = require("./Contract")
local Session = require("../../../core/infra/genre/Session")
local MemoryBackend = require("../../../core/infra/data/MemoryBackend")
local function setup()
	local events = {}
	local instance = Adapter.create(Fixture, {
		now = function()
			return 0
		end,
		roll = function()
			return 0.75
		end,
		emit = function(event)
			table.insert(events, event)
		end,
	})
	assert(instance.join("a", nil).ok and instance.join("b", nil).ok, "fashion invariant failed")
	return instance, events
end
return {
	["fractional deadline catchup rejects late actions and releases durable rewards"] = function()
		for _, mode in { "dispatch", "advance", "close" } do
			local config = Executor.clone(Fixture)
			config.round.dressingSeconds = 0.1
			config.round.votingSeconds = 0.1
			local now, results = 100, 0
			local backend = MemoryBackend.new()
			local function create(name: string)
				return Session.new(
					{
						packConfig = { api = 1, order = { Contract.id }, configs = { [Contract.id] = config } },
						contracts = { Contract },
						controls = {},
						storeName = "FashionFractional",
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
						emit = function(event)
							if event.name == "OnResults" then
								results += 1
							end
						end,
					}
				)
			end
			local session = create("first")
			assert(session.join("a").ok and session.join("b").ok, "joined fractional round")
			session.advance(now)
			if mode ~= "advance" then
				now = 100 + 0.1
				assert(
					not session.dispatch("a", Contract.id .. ":equip", { "starter-hat" } :: { any }).ok,
					"late equip"
				)
				assert(next(session.snapshot("a")[Contract.id].equipped) == nil, "no late outfit mutation")
				assert(session.dispatch("b", Contract.id .. ":vote", { "a", 5 } :: { any }).ok, "timely vote")
			end
			now = 101
			if mode == "dispatch" then
				assert(not session.dispatch("a", Contract.id .. ":vote", { "b", 5 } :: { any }).ok, "late vote")
			elseif mode == "advance" then
				session.advance(now)
			end
			assert(session.close("a").ok, "winner releases")
			assert(session.close("a").ok, "repeated close succeeds")
			assert(results == 1, "two overdue phases settle exactly once")
			local restored = create("second")
			assert(restored.join("a").ok, "released winner rejoins")
			assert(
				restored.snapshot("a")[Contract.id].balance == (if mode == "advance" then 0 else 5),
				"earned reward released durably; a round without votes pays nobody"
			)
			assert(restored.snapshot("a")[Contract.id].phase == "lobby", "persistence does not start a round")
			assert(session.close("b").ok and restored.close("a").ok, "release remaining profiles")
		end
	end,
	["deadline departure persists earned reward independent of heartbeat"] = function()
		for _, epoch in { 3, 4, 5 } do
			for _, heartbeatFirst in { false, true } do
				local now, results = 0, 0
				local backend = MemoryBackend.new()
				local function create(name: string)
					return Session.new(
						{
							packConfig = { api = 1, order = { Contract.id }, configs = { [Contract.id] = Fixture } },
							contracts = { Contract },
							controls = {},
							storeName = "FashionDeadline",
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
							emit = function(event)
								if event.name == "OnResults" then
									results += 1
								end
							end,
						}
					)
				end
				local session = create("first")
				assert(session.join("a").ok and session.join("b").ok, "joined")
				session.advance(0)
				now = 2
				session.advance(now)
				assert(session.dispatch("b", Contract.id .. ":vote", { "a", 5 } :: { any }).ok, "timely vote")
				now = epoch
				if heartbeatFirst then
					session.advance(now)
				end
				assert(session.close("a").ok, "winner releases")
				assert(session.close("a").ok, "repeat does not settle again")
				local restored = create("second")
				assert(restored.join("a").ok, "durable rejoin")
				assert(
					restored.snapshot("a")[Contract.id].balance == (if epoch < 4 then 0 else 5),
					"earned reward durable"
				)
				assert(
					not session.dispatch("b", Contract.id .. ":vote", { "a", 5 } :: { any }).ok,
					"departed eligibility lost"
				)
				now = 5
				session.advance(now)
				assert(results == 1, "one settlement")
				assert(session.close("b").ok and restored.close("a").ok, "release all")
			end
		end
	end,
	["expired dressing and voting refuse late actions without heartbeat"] = function()
		local now = 0
		local instance = Adapter.create(Fixture, {
			now = function()
				return now
			end,
			roll = function()
				return 0
			end,
			emit = function() end,
		})
		assert(instance.join("a", nil).ok and instance.join("b", nil).ok, "joined")
		instance.advance(0)
		now = 2
		assert(not instance.dispatch("a", "equip", { "starter-hat" }).ok, "late dressing rejected")
		assert(next(instance.snapshot("a").equipped) == nil, "no outfit mutation")
		assert(instance.dispatch("b", "vote", { "a", 5 }).ok, "timely vote accepted")
		now = 4
		assert(not instance.dispatch("a", "vote", { "b", 5 }).ok, "late vote rejected")
		assert(instance.snapshot("a").ranking[1].target == "a", "late vote cannot change winner")
	end,
	["reward capacity settles explicitly once through executor and persistent release"] = function()
		for _, balance in { 1e9, 1e9 - 4, 1e9 - 5 } do
			local events: { any } = {}
			local epoch = 0
			local backend = MemoryBackend.new()
			local envelope = {
				version = 1,
				genres = {
					[Contract.id] = {
						version = 1,
						data = { owned = Fixture.startingOwned, equipped = { hat = "starter-hat" }, balance = balance },
					},
				},
			}
			assert(#Executor.validateSave(envelope, { Contract }) == 0, "boundary save is valid")
			assert(
				backend.update("player-a", function()
					return { data = envelope }
				end),
				"seed actual profile backend"
			)
			local function create(name: string)
				return Session.new(
					{
						packConfig = { api = 1, order = { Contract.id }, configs = { [Contract.id] = Fixture } },
						contracts = { Contract },
						storeName = "FashionCapacitySpec",
						controls = {},
					},
					backend,
					{
						sessionId = name,
						lockTimeout = 120,
						retries = 0,
						now = function()
							return epoch
						end,
					},
					{
						now = function()
							return epoch
						end,
						roll = function()
							return 0
						end,
						emit = function(event)
							table.insert(events, event)
						end,
					}
				)
			end
			local session = create("first")
			assert(session.join("a").ok and session.join("b").ok, "native session joins")
			session.advance(0)
			epoch = 2
			session.advance(epoch)
			assert(session.dispatch("b", Contract.id .. ":vote", { "a", 5 } :: { any }).ok, "native vote")
			epoch = 4
			session.advance(epoch)
			local expected = if balance + Fixture.resultReward <= 1e9 then balance + Fixture.resultReward else balance
			local snapshot = session.snapshot("a")[Contract.id]
			assert(snapshot.balance == expected, "reward must fit completely or leave the wallet unchanged")
			assert(snapshot.phase == "results" and snapshot.ranking[1].target == "a", "native results retained")
			assert(
				snapshot.equipped.hat == "starter-hat" and session.snapshot("b")[Contract.id].balance == 0,
				"atomic state"
			)
			assert(snapshot.settlement.ok == (balance == 1e9 - 5), "explicit settlement outcome")
			assert(
				events[3].name == "OnResults" and events[3].data.settlement.ok == snapshot.settlement.ok,
				"result event outcome"
			)
			if not snapshot.settlement.ok then
				assert(snapshot.settlement.reason == "reward exceeds balance limit", "machine-readable failure reason")
			end
			snapshot.settlement.ok = not snapshot.settlement.ok
			assert(
				session.snapshot("a")[Contract.id].settlement.ok == (balance == 1e9 - 5),
				"snapshot cannot mutate outcome"
			)
			session.advance(epoch)
			epoch = 4.5
			session.advance(epoch)
			assert(#events == 3 and session.snapshot("a")[Contract.id].balance == expected, "settlement happens once")
			assert(#Executor.validateSave(session.envelope("a"), { Contract }) == 0, "executor save remains valid")
			assert(session.save("a").ok, "actual profile save")
			assert(session.close("a").ok and session.close("b").ok and #session.members() == 0, "release and detach")
			local eventCount = #events
			local restored = create("next")
			assert(restored.join("a").ok, "released profile can rejoin")
			local rejoined = restored.snapshot("a")[Contract.id]
			assert(
				rejoined.balance == expected and rejoined.equipped.hat == "starter-hat",
				"persistent wallet and outfit"
			)
			assert(
				rejoined.phase == "lobby" and rejoined.settlement == nil and #events == eventCount,
				"no settlement replay"
			)
			assert(restored.close("a").ok, "restored profile release")
		end
	end,
	["caller config mutation cannot change round timing or rewards"] = function()
		local config = table.clone(Fixture)
		config.round = table.clone(Fixture.round)
		config.themes = table.clone(Fixture.themes)
		local instance = Adapter.create(config, {
			now = function()
				return 0
			end,
			roll = function()
				return 0
			end,
			emit = function(_event) end,
		})
		config.round.dressingSeconds = 100
		config.resultReward = 999
		config.themes[1] = "changed"
		assert(instance.join("a", nil).ok and instance.join("b", nil).ok, "join original config")
		instance.advance(0)
		assert(instance.snapshot("a").theme == "garden", "original theme retained")
		instance.advance(2)
		assert(instance.dispatch("b", "vote", { "a", 5 }).ok, "original voting deadline retained")
		instance.advance(4)
		assert(instance.snapshot("a").balance == 5, "original reward retained")
	end,

	["phase ownership membership and native vote validation"] = function()
		local instance, events = setup()
		assert(not instance.dispatch("missing", "equip", { "starter-hat" }).ok, "fashion invariant failed")
		assert(not instance.dispatch("a", "vote", { "b", 5 }).ok, "fashion invariant failed")
		assert(not instance.dispatch("a", "equip", { "ghost" }).ok, "fashion invariant failed")
		assert(instance.dispatch("a", "equip", { "starter-hat" }).ok, "fashion invariant failed")
		instance.advance(0)
		assert(instance.snapshot("a").theme == "space", "fashion invariant failed")
		assert(instance.join("c", nil).ok, "fashion invariant failed")
		assert(not instance.dispatch("c", "equip", { "starter-top" }).ok, "fashion invariant failed")
		instance.advance(2)
		assert(not instance.dispatch("a", "equip", { "starter-top" }).ok, "fashion invariant failed")
		local invalidVotes: { { any } } = {
			{ "a", 5 },
			{ "ghost", 5 },
			{ "c", 5 },
			{ "b", 0 },
			{ "b", 6 },
			{ "b", 1.5 },
			{ "b", math.huge },
			{ "b", 0 / 0 },
		}
		for _, args in invalidVotes do
			assert(not instance.dispatch("a", "vote", args).ok, "fashion invariant failed")
		end
		assert(instance.dispatch("a", "vote", { "b", 5 }).ok, "fashion invariant failed")
		assert(not instance.dispatch("a", "vote", { "b", 1 }).ok, "fashion invariant failed")
		instance.leave("b")
		assert(not instance.dispatch("b", "vote", { "a", 5 }).ok, "fashion invariant failed")
		assert(instance.join("b", nil).ok, "fashion invariant failed")
		assert(not instance.dispatch("b", "vote", { "a", 5 }).ok, "fashion invariant failed")
		assert(not instance.dispatch("a", "vote", { "b", 5 }).ok, "fashion invariant failed")
		assert(#events == 3, "fashion invariant failed")
	end,
	["native tie order reward once cloned saves and fresh rejoin"] = function()
		local instance, events = setup()
		assert(instance.dispatch("a", "equip", { "starter-hat" }).ok, "fashion invariant failed")
		instance.advance(0)
		instance.advance(2)
		assert(instance.dispatch("a", "vote", { "b", 5 }).ok, "fashion invariant failed")
		assert(instance.dispatch("b", "vote", { "a", 5 }).ok, "fashion invariant failed")
		instance.advance(4)
		local snapshot = instance.snapshot("a")
		assert(
			snapshot.phase == "results" and snapshot.ranking[1].target == "a" and snapshot.balance == 5,
			"fashion invariant failed"
		)
		snapshot.ranking[1].target = "forged"
		assert(instance.snapshot("a").ranking[1].target == "a", "fashion invariant failed")
		instance.advance(4)
		instance.advance(4.5)
		assert(instance.snapshot("a").balance == 5 and #events == 5, "fashion invariant failed")
		local saved = instance.save("a")
		instance.leave("a")
		assert(instance.join("a", saved).ok, "fashion invariant failed")
		saved.equipped.hat = "ghost"
		assert(instance.snapshot("a").equipped.hat == "starter-hat", "fashion invariant failed")
		assert(not instance.snapshot("a").enrolled, "fashion invariant failed")
		instance.advance(5)
		instance.advance(6)
		instance.advance(8)
		instance.advance(10)
		assert(#instance.snapshot("a").ranking == 0 and instance.snapshot("a").balance == 5, "fashion invariant failed")
		local fresh = setup()
		assert(fresh.join("restored", instance.save("a")).ok, "fashion invariant failed")
		assert(
			fresh.snapshot("restored").phase == "lobby" and fresh.snapshot("restored").balance == 5,
			"fashion invariant failed"
		)
	end,
	["unowned item and invalid save fail without mutation"] = function()
		local instance = setup()
		assert(
			instance.join("limited", { owned = { "starter-top" }, equipped = {}, balance = 0 }).ok,
			"fashion invariant failed"
		)
		assert(not instance.dispatch("limited", "equip", { "starter-hat" }).ok, "fashion invariant failed")
		assert(
			not instance.join("bad", { owned = { "ghost" }, equipped = {}, balance = 0 }).ok,
			"fashion invariant failed"
		)
		assert(
			not instance.join("bad", { owned = { "starter-hat" }, equipped = { top = "starter-hat" }, balance = 0 }).ok,
			"fashion invariant failed"
		)
		for _, balance in { -1, 0.5, math.huge, 0 / 0 } do
			assert(
				#Adapter.validateSave({ owned = {}, equipped = {}, balance = balance }) > 0,
				"fashion invariant failed"
			)
		end
		local config = Executor.clone(Fixture)
		config.extra = true
		assert(#Adapter.validateConfig(config) > 0, "fashion invariant failed")
		config = Executor.clone(Fixture)
		config.catalog[1] = false
		assert(#Adapter.validateConfig(config) > 0, "fashion invariant failed")
	end,
}
