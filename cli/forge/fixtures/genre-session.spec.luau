--!strict
local Session = require("../../../core/infra/genre/Session")
local Options = require("../../../core/infra/genre/Options")
local MemoryBackend = require("../../../core/infra/data/MemoryBackend")
local ProfileStore = require("../../../core/infra/data/ProfileStore")
local Runtime = require("../../../genres/grow-harvest/module/Contract")
local Fixture = require("../../../genres/grow-harvest/module/Adapter.fixture")
local Clock = require("../../../core/infra/genre/Clock")
local Survival = require("../../../genres/survival-coop/module/Contract")
local SurvivalFixture = require("../../../genres/survival-coop/module/Adapter.fixture")
local Arena = require("../../../genres/pvp-arena/module/Contract")
local ArenaFixture = require("../../../genres/pvp-arena/module/Adapter.fixture")
local Collect = require("../../../genres/collect-raid/module/Contract")
local CollectFixture = require("../../../genres/collect-raid/module/Adapter.fixture")
local function check(value: any, message: string?): ()
	assert(value, message or "session contract assertion failed")
end
local function tuple(...: any): { any }
	return { ... }
end
local function options(): Options.Options
	return {
		packConfig = { api = 1, order = { Runtime.id }, configs = { [Runtime.id] = Fixture.config() } },
		contracts = { Runtime },
		storeName = "StarterSpec",
		controls = {
			{
				id = Runtime.id .. ":plant",
				action = Runtime.id .. ":plant",
				args = tuple(1, "carrot"),
				label = "Plant",
				kind = "prompt",
			},
		},
	}
end
local function create(backend: ProfileStore.Backend, name: string?, input: Options.Options?)
	local epoch = 100
	local emitted = 0
	local session = Session.new(input or options(), backend, {
		sessionId = name or "mine",
		lockTimeout = 120,
		retries = 1,
		now = function()
			return epoch
		end,
	}, {
		now = function()
			return epoch
		end,
		roll = function()
			return 0
		end,
		emit = function()
			emitted += 1
		end,
	})
	return session,
		function(value: number)
			epoch = value
			session.advance(value)
		end,
		function()
			return emitted
		end
end
return {
	["legal collect income beyond a billion survives save close and backend rejoin"] = function()
		local backend = MemoryBackend.new()
		local config = CollectFixture.config()
		config.startingCoins = 1e9
		local input: Options.Options = {
			packConfig = { api = 1, order = { Collect.id }, configs = { [Collect.id] = config } },
			contracts = { Collect },
			storeName = "CollectBalanceSpec",
			controls = {},
		}
		local session, advance = create(backend, "collect-first", input)
		check(session.join("1").ok)
		check(session.dispatch("1", Collect.id .. ":buy-source", { "ember" }).ok)
		advance(105)
		check(session.dispatch("1", Collect.id .. ":hatch", { 1 }).ok)
		advance(156)
		check(session.snapshot("1")[Collect.id].coins == 1000000001, "natural production crosses old save ceiling")
		check(session.save("1").ok, "normal income must remain saveable")
		check(session.close("1").ok and #session.members() == 0, "close saves detaches and releases")
		local nextSession, nextAdvance = create(backend, "collect-next", input)
		nextAdvance(156)
		check(nextSession.join("1").ok and nextSession.snapshot("1")[Collect.id].coins == 1000000001)
		local saved = nextSession.envelope("1")
		saved.genres[Collect.id].data.loop.coins = 2 ^ 53 - 1
		check(#Collect.validateSave(saved.genres[Collect.id].data) == 0, "wallet safe integer maximum accepted")
		saved.genres[Collect.id].data.loop.coins = 2 ^ 53
		check(#Collect.validateSave(saved.genres[Collect.id].data) > 0, "unsafe integer rejected")
		check(nextSession.close("1").ok)
	end,
	["departing arena forfeit persists both ratings through backend rejoin"] = function()
		local backend = MemoryBackend.new()
		local input: Options.Options = {
			packConfig = { api = 1, order = { Arena.id }, configs = { [Arena.id] = ArenaFixture } },
			contracts = { Arena },
			storeName = "ArenaLeaveSpec",
			controls = {},
		}
		local session, advance = create(backend, "arena-first", input)
		check(session.join("1").ok and session.join("2").ok)
		check(session.dispatch("1", Arena.id .. ":enqueue", {}).ok)
		check(session.dispatch("2", Arena.id .. ":enqueue", {}).ok)
		advance(101)
		check(session.close("1").ok and #session.members() == 1)
		check(session.snapshot("2")[Arena.id].rating == 1016)
		check(session.close("1").ok, "repeated departure is idempotent")
		advance(102)
		check(session.snapshot("2")[Arena.id].rating == 1016, "departure must not settle twice")
		check(session.close("2").ok)
		local restored = create(backend, "arena-next", input)
		check(restored.join("1").ok and restored.join("2").ok)
		check(restored.snapshot("1")[Arena.id].rating == 984, "departing penalty must survive release")
		check(restored.snapshot("2")[Arena.id].rating == 1016)
		check(restored.close("1").ok and restored.close("2").ok)
	end,
	["leave during suspended save detaches immediately and deferred release excludes wave reward"] = function()
		local memory = MemoryBackend.new()
		local suspended = false
		local pause = false
		local backend = {
			update = function(key: string, transform: (any) -> any): (boolean, any)
				if pause then
					pause = false
					suspended = true
					coroutine.yield("save-backend-entered")
				end
				return memory.update(key, transform)
			end,
		}
		local input = options()
		local config = table.clone(SurvivalFixture.config)
		config.baseDefense = 4
		input.packConfig = { api = 1, order = { Survival.id }, configs = { [Survival.id] = config } }
		input.contracts, input.controls = { Survival }, {}
		local session, advance = create(backend, "mine", input)
		check(session.join("1").ok and session.join("2").ok)
		advance(100)
		advance(102)
		pause = true
		local saved: any = nil
		local worker = coroutine.create(function()
			saved = session.save("1")
		end)
		local entered, signal = coroutine.resume(worker)
		check(entered and signal == "save-backend-entered" and suspended, "exact backend suspension signal")
		check(not session.close("1").ok, "busy release remains explicit")
		check(#session.members() == 1 and session.members()[1] == "2", "departure detaches synchronously")
		check(not session.dispatch("1", Survival.id .. ":defend-active", {}).ok)
		check(session.dispatch("2", Survival.id .. ":defend-active", {}).ok)
		check(session.snapshot("2")[Survival.id].balance == 15, "remaining participant earns native reward")
		local resumed, err = coroutine.resume(worker)
		check(resumed, tostring(err))
		check(coroutine.status(worker) == "dead" and saved.ok, "save completes only after explicit resume")
		check(session.close("1").ok and session.close("2").ok)
		local nextSession = create(memory, "next", input)
		check(
			nextSession.join("1").ok and nextSession.snapshot("1")[Survival.id].balance == 10,
			"departed envelope has no settlement reward"
		)
		check(nextSession.join("2").ok and nextSession.snapshot("2")[Survival.id].balance == 15)
		check(nextSession.close("1").ok and nextSession.close("2").ok)
	end,
	["wall clock permits half-second native attack cooldown between heartbeat advances"] = function()
		local wall = 100
		local clock = Clock.new(function()
			return wall
		end)
		local input = options()
		local config = table.clone(ArenaFixture)
		config.attackCooldown = 0.5
		input.packConfig = { api = 1, order = { Arena.id }, configs = { [Arena.id] = config } }
		input.contracts, input.controls = { Arena }, {}
		local session = Session.new(input, MemoryBackend.new(), {
			sessionId = "clock",
			lockTimeout = 120,
			retries = 0,
			now = function()
				return wall
			end,
		}, {
			now = clock.now,
			roll = function()
				return 0
			end,
			emit = function() end,
		})
		check(session.join("1").ok and session.join("2").ok)
		check(
			session.dispatch("1", Arena.id .. ":enqueue", {}).ok
				and session.dispatch("2", Arena.id .. ":enqueue", {}).ok
		)
		wall = 101
		session.advance(clock.now())
		check(session.dispatch("1", Arena.id .. ":attack", {}).ok)
		wall = 101.499
		check(not session.dispatch("1", Arena.id .. ":attack", {}).ok)
		wall = 101.5
		check(session.dispatch("1", Arena.id .. ":attack", {}).ok, "no intermediate heartbeat advance required")
		check(session.snapshot("2")[Arena.id].health == 1)
		wall = 102.75
		check(clock.now() == 102.75, "tick samples wall time rather than accumulating delta drift")
		check(session.close("1").ok and session.close("2").ok)
	end,
	["QA clock handshake freezes epoch and advances relative fixture time without rewind"] = function()
		local wall = 1700000000.25
		local clock = Clock.new(function()
			return wall
		end)
		check(not pcall(clock.advanceElapsed, 0), "relative advance requires handshake")
		local base = clock.begin()
		wall += 100
		check(clock.now() == base and clock.advanceElapsed(0) == base)
		check(clock.advanceElapsed(0.5) == base + 0.5 and clock.now() == base + 0.5)
		check(
			not pcall(clock.advanceElapsed, 0) and not pcall(clock.advanceElapsed, math.huge),
			"reject backwards/nonfinite QA time"
		)
		check(not pcall(clock.begin), "handshake cannot silently reset an active scenario")
	end,
	["actual native farming effects survive one envelope and failed writes without reward replay"] = function()
		local backend = MemoryBackend.new()
		local session, advance, events = create(backend)
		check(session.join("1").ok)
		check(session.dispatch("1", Runtime.id .. ":plant", tuple(1, "carrot")).ok)
		check(not session.dispatch("1", Runtime.id .. ":harvest", { 1 }).ok)
		advance(102)
		check(session.dispatch("1", Runtime.id .. ":harvest", { 1 }).ok)
		check(session.dispatch("1", Runtime.id .. ":sell-held", { "carrot" }).ok)
		check(session.snapshot("1")[Runtime.id].balance == 20 and events() == 3)
		backend.failNext(2)
		local failed = session.save("1")
		check(not failed.ok and failed.reason == "throttled")
		check(session.snapshot("1")[Runtime.id].balance == 20 and events() == 3)
		check(session.save("1").ok)
		backend.failNext(2)
		check(not session.close("1").ok and #session.members() == 0)
		check(not session.join("1").ok, "failed release retains active profile")
		check(session.close("1").ok, "retained profile can retry release")
		local reloaded, _, restoredEvents = create(backend, "next")
		check(reloaded.join("1").ok)
		check(reloaded.snapshot("1")[Runtime.id].balance == 20 and restoredEvents() == 0)
		check(not reloaded.dispatch("1", Runtime.id .. ":sell-held", { "carrot" }).ok)
		check(reloaded.close("1").ok)
	end,
	["session conflicts and backend load failures deny joins"] = function()
		local backend = MemoryBackend.new()
		local first = create(backend)
		check(first.join("1").ok)
		local second = create(backend, "other")
		local conflict = second.join("1")
		check(not conflict.ok and conflict.reason == "locked" and #second.members() == 0)
		backend.failNext(2)
		check(not second.join("2").ok and #second.members() == 0)
		check(first.close("1").ok)
		check(second.join("1").ok and second.close("1").ok)
	end,
	["future invalid and legacy records reject before joining or granting"] = function()
		local records: { any } = {
			{ version = 2, genres = {} },
			{ version = 1, genres = { [Runtime.id] = { version = 2, data = {} } } },
			{ version = 1, genres = { [Runtime.id] = { version = 1, data = { balance = -1 } } } },
			{ version = 1, coins = 50 },
		}
		for _, raw in records do
			local backend = MemoryBackend.new()
			check(backend.update("player-1", function()
				return { data = raw }
			end))
			local session, _, events = create(backend)
			local result = session.join("1")
			check(not result.ok and result.reason ~= nil and #session.members() == 0 and events() == 0)
		end
	end,
	["UpdateAsync replay uses cloned pure migration and never replays native grants"] = function()
		local memory = MemoryBackend.new()
		local callbacks = 0
		local backend = {
			update = function(key: string, transform: (any) -> any): (boolean, any)
				return memory.update(key, function(old)
					callbacks += 2
					transform(old)
					return transform(old)
				end)
			end,
		}
		local session, _, events = create(backend)
		check(session.join("1").ok and callbacks == 2 and events() == 0)
		check(session.dispatch("1", Runtime.id .. ":buy-seed", { "carrot" }).ok)
		check(session.save("1").ok and callbacks == 4 and events() == 1)
		check(session.close("1").ok and callbacks == 6 and events() == 1)
		local saved = { version = 1, genres = {} }
		local copy = Session.migrate(saved, { Runtime })
		copy.genres.extra = { version = 1, data = {} }
		check(next(saved.genres) == nil)
	end,
	["malicious ingress and invalid restore cannot change native state"] = function()
		local session = create(MemoryBackend.new())
		check(session.join("1").ok)
		for _, action in { "hook", Runtime.id .. ":unknown" } do
			check(not session.dispatch("1", action, {}).ok)
		end
		check(not session.dispatch("1", {}, {}).ok)
		for _, args in
			{
				tuple(1, "carrot", "extra"),
				{ [1] = 1, [3] = "carrot" } :: { any },
				tuple(0 / 0, "carrot"),
				tuple(math.huge, "carrot"),
			}
		do
			check(not session.dispatch("1", Runtime.id .. ":plant", args).ok)
		end
		local forged: { [any]: any } = tuple(1, "carrot")
		forged.playerId = "2"
		check(not session.dispatch("1", Runtime.id .. ":plant", forged).ok)
		check(not session.dispatch("2", Runtime.id .. ":plant", tuple(1, "carrot")).ok)
		check(not session.restore("1", { version = 2, genres = {} }).ok)
		check(session.snapshot("1")[Runtime.id].balance == 10 and session.snapshot("1")[Runtime.id].seeds.carrot == 1)
		check(session.close("1").ok)
	end,
	["options boundary rejects unknown fields malformed controls configs and hooks before IO"] = function()
		local input = options()
		Options.validate(input)
		for _, mutate in
			{
				function(o: any)
					o.storeName = ""
				end,
				function(o: any)
					o.extra = true
				end,
				function(o: any)
					o.controls[1].action = Runtime.id .. ":unknown"
				end,
				function(o: any)
					o.controls[1].args = tuple(1, "carrot", "extra")
				end,
				function(o: any)
					o.controls[1].id = "unnamespaced"
				end,
				function(o: any)
					o.controls[1].kind = "arbitrary"
				end,
				function(o: any)
					o.packConfig.configs[Runtime.id].plotCount = 0
				end,
				function(o: any)
					o.hooks = { [Runtime.id .. ":unknown"] = function() end }
				end,
			}
		do
			local calls = 0
			local backend = {
				update = function(_key: string, _transform: (any) -> any): (boolean, any)
					calls += 1
					return false, "unexpected"
				end,
			}
			local bad = options()
			mutate(bad)
			check(not pcall(function()
				create(backend, "mine", bad)
			end) and calls == 0)
		end
	end,
}
