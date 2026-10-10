--!strict
local Session = require("../../../core/infra/genre/Session")
local MemoryBackend = require("../../../core/infra/data/MemoryBackend")
local Arena = require("../../../genres/pvp-arena/module/Contract")
local Fixture = require("../../../genres/pvp-arena/module/Adapter.fixture")

local function setup(
	hooks: any?,
	descriptor: any?,
	config: any?
): (Session.Session, MemoryBackend.Memory, (string) -> Session.Session, (number) -> ())
	local now = 100
	local backend = MemoryBackend.new()
	local runtime = descriptor or Arena
	local options = {
		packConfig = { api = 1, order = { "pvp-arena" }, configs = { ["pvp-arena"] = config or Fixture } },
		contracts = { runtime },
		controls = {},
		storeName = "test",
		hooks = hooks,
	}
	local services = {
		now = function()
			return now
		end,
		roll = function()
			return 0
		end,
		emit = function(_event: any) end,
	}
	local function fresh(id: string): Session.Session
		return Session.new(
			options,
			backend,
			{ sessionId = id, lockTimeout = 120, retries = 0, now = services.now },
			services
		)
	end
	return fresh("first"), backend, fresh, function(value: number): ()
		now = value
	end
end

local tests = {
	["trusted server ingress enforces lifecycle transport and origin"] = function()
		local runtime = table.clone(Arena)
		runtime.actions = table.clone(Arena.actions)
		local selected = table.clone(runtime.actions[1])
		selected.origin = "server"
		runtime.actions[1] = selected
		local action = "pvp-arena:" .. selected.id
		local session = setup(nil, runtime)
		assert(not session.dispatchServer("1", action, {}).ok, "unjoined actor refused")
		assert(session.join("1").ok, "join")
		assert(not session.dispatchServer("1", false, {}).ok, "malformed action refused")
		assert(not session.dispatchServer("1", action, false).ok, "malformed tuple refused")
		assert(
			session.dispatch("1", action, {}).reason == "unknown/disallowed action",
			"client cannot use server action"
		)
		assert(session.dispatchServer("1", action, {}).ok, "trusted executor origin accepted")
		assert(session.close("1").ok, "release")
		assert(not session.dispatchServer("1", action, {}).ok, "closed actor refused")
	end,
	["fractional arena deadline settles heartbeat action and departure identically"] = function()
		for _, first in { "heartbeat", "action", "departure" } do
			local config = table.clone(Fixture)
			config.Round = table.clone(Fixture.Round)
			config.Round.duration = 0.1
			local settlements = 0
			local session, _, fresh, clock = setup({
				["pvp-arena:MatchSettled"] = function()
					settlements += 1
				end,
			}, nil, config)
			assert(session.join("1").ok and session.join("2").ok, "joined")
			assert(session.dispatch("1", "pvp-arena:enqueue", {}).ok, "first queued")
			assert(session.dispatch("2", "pvp-arena:enqueue", {}).ok, "second queued")
			clock(101)
			session.advance(101)
			assert(session.dispatch("1", "pvp-arena:attack", {}).ok, "rival damaged before deadline")
			clock(101 + 0.1)
			if first == "heartbeat" then
				session.advance(101 + 0.1)
			elseif first == "action" then
				assert(not session.dispatch("1", "pvp-arena:attack", {}).ok, "expired attack refused")
			else
				assert(session.close("1").ok, "departure settles timeout")
			end
			assert(session.snapshot("2")["pvp-arena"].phase == "ended", "exact deadline ends round")
			assert(session.snapshot("2")["pvp-arena"].rating == 984, "health-based loss settles immediately")
			assert(settlements == 1, "one settlement at deadline")
			assert(session.close("1").ok, "winner releases")
			assert(session.close("1").ok, "repeat close")
			assert(session.close("2").ok, "rival releases")
			local restored = fresh("second")
			assert(restored.join("1").ok and restored.join("2").ok, "durable rejoin")
			assert(restored.snapshot("1")["pvp-arena"].rating == 1016, "durable winner")
			assert(restored.snapshot("2")["pvp-arena"].rating == 984, "durable loser")
			assert(settlements == 1, "no settlement replay")
			assert(restored.close("1").ok and restored.close("2").ok, "release rejoined profiles")
		end
	end,
	["arena departure uses authoritative timeout before durable capture"] = function()
		for _, epoch in { 104, 105, 106 } do
			for _, heartbeatFirst in { false, true } do
				for _, damaged in { false, true } do
					local settlements = 0
					local session, _, fresh, clock = setup({
						["pvp-arena:MatchSettled"] = function()
							settlements += 1
						end,
					})
					assert(session.join("1").ok and session.join("2").ok, "players joined")
					assert(session.dispatch("1", "pvp-arena:enqueue", {}).ok, "first queued")
					assert(session.dispatch("2", "pvp-arena:enqueue", {}).ok, "second queued")
					clock(101)
					session.advance(101)
					if damaged then
						assert(session.dispatch("1", "pvp-arena:attack", {}).ok, "rival damaged")
					end
					clock(epoch)
					if heartbeatFirst then
						session.advance(epoch)
					end
					assert(session.close("1").ok, "departure releases")
					assert(session.close("1").ok, "repeated close remains released")
					assert(session.close("2").ok and #session.members() == 0, "both detached")
					local rejoined = fresh("second")
					assert(rejoined.join("1").ok and rejoined.join("2").ok, "released profiles rejoin")
					local rating = if epoch < 105 then 984 elseif damaged then 1016 else 1000
					assert(rejoined.snapshot("1")["pvp-arena"].rating == rating, "correct durable departure outcome")
					assert(rejoined.snapshot("2")["pvp-arena"].rating == 2000 - rating, "rival durable outcome")
					assert(settlements == 1, "preparation and repeated close settle once")
					assert(rejoined.close("1").ok and rejoined.close("2").ok, "rejoin releases")
				end
			end
		end
	end,
	["failed final serialization detaches and unlocks without overwriting durable data"] = function()
		for _, failRelease in { false, true } do
			local runtime = table.clone(Arena)
			local create = runtime.create
			local broken = false
			runtime.create = function(config: any, services: any)
				local instance = create(config, services)
				local save = instance.save
				instance.save = function(id: string)
					assert(not broken, "final capture failed")
					return save(id)
				end
				return instance
			end
			local session, backend, fresh = setup(nil, runtime)
			assert(session.join("1").ok, "initial member joined")
			local envelope = session.envelope("1")
			envelope.genres["pvp-arena"].data.rating = 1200
			assert(session.restore("1", envelope).ok and session.save("1").ok, "baseline persisted")
			envelope.genres["pvp-arena"].data.rating = 1400
			assert(session.restore("1", envelope).ok, "uncommitted state restored")
			broken = true
			if failRelease then
				backend.failNext(1)
			end
			local result = session.close("1")
			assert(not result.ok and result.released == not failRelease, "capture and release outcomes separated")
			assert(string.find(result.reason or "", "final capture failed", 1, true))
			assert(#session.members() == 0, "failed serialization cannot retain member")
			if failRelease then
				local retry = session.close("1")
				assert(not retry.ok and retry.released, "retry unlocks and still reports lost final capture")
			end
			broken = false
			local restored = fresh("second")
			assert(restored.join("1").ok, "released lock permits rejoin")
			assert(restored.snapshot("1")["pvp-arena"].rating == 1200, "only last durable data preserved")
			assert(restored.close("1").ok, "rejoined profile releases")
		end
	end,
	["departure hook failure detaches and persists settled rating"] = function()
		for _, failRelease in { false, true } do
			local settlements = 0
			local session, backend, fresh, clock = setup({
				["pvp-arena:OnRoundEnd"] = function()
					error("departure notification")
				end,
				["pvp-arena:MatchSettled"] = function()
					settlements += 1
				end,
			})
			assert(session.join("1").ok and session.join("2").ok, "both players join")
			assert(session.dispatch("1", "pvp-arena:enqueue", {}).ok, "first player queues")
			assert(session.dispatch("2", "pvp-arena:enqueue", {}).ok, "second player queues")
			clock(101)
			session.advance(101)
			if failRelease then
				backend.failNext(1)
			end
			local ok, result = pcall(session.close, "1")
			assert(ok, "departure hook must not abort close")
			assert(result.ok == not failRelease, "release outcome is authoritative")
			assert(
				string.find(result.notificationError or "", "departure notification", 1, true),
				"hook error reported"
			)
			assert(#session.members() == 1 and session.members()[1] == "2", "departed member removed")
			assert(not session.dispatch("1", "pvp-arena:enqueue", {}).ok, "departed ingress rejected")
			assert(session.snapshot("2")["pvp-arena"].rating == 1016, "winner rating settled")
			local retry = session.close("1")
			assert(retry.ok and retry.notificationError == nil, "retry releases without replaying notification")
			assert(session.close("2").ok, "winner released")
			local rejoined = fresh("second")
			assert(rejoined.join("1").ok and rejoined.join("2").ok, "released profiles rejoin")
			assert(rejoined.snapshot("1")["pvp-arena"].rating == 984, "loser rating durable")
			assert(rejoined.snapshot("2")["pvp-arena"].rating == 1016, "winner rating durable")
			clock(110)
			rejoined.advance(110)
			assert(settlements == 1, "release retry and rejoin cannot settle twice")
		end
	end,
	["join and restore hook failures preserve committed membership"] = function()
		local runtime = table.clone(Arena)
		local create = runtime.create
		runtime.create = function(config: any, services: any)
			local instance = create(config, services)
			local join, leave = instance.join, instance.leave
			instance.join = function(id: string, save: any)
				local result = join(id, save)
				if result.ok then
					services.emit({ genre = "pvp-arena", name = "OnRoundStart", data = {} })
				end
				return result
			end
			instance.leave = function(id: string)
				leave(id)
				services.emit({ genre = "pvp-arena", name = "OnRoundEnd", data = {} })
			end
			return instance
		end
		local session = setup({
			["pvp-arena:OnRoundStart"] = function()
				error("join notification")
			end,
			["pvp-arena:OnRoundEnd"] = function()
				error("leave notification")
			end,
		}, runtime)
		local ok, result = pcall(session.join, "1")
		assert(ok and result.ok and result.notificationError, "join commits with notification error")
		assert(#session.members() == 1 and session.save("1").ok, "committed join owns save")
		local saved = session.envelope("1")
		saved.genres["pvp-arena"].data.rating = 1200
		local restored, restoredResult = pcall(session.restore, "1", saved)
		assert(restored and restoredResult.ok and restoredResult.notificationError, "restore commits with errors")
		assert(string.find(restoredResult.notificationError, "leave notification", 1, true), "leave error preserved")
		assert(string.find(restoredResult.notificationError, "join notification", 1, true), "join error preserved")
		assert(
			#session.members() == 1 and session.snapshot("1")["pvp-arena"].rating == 1200,
			"restored member coherent"
		)
		assert(session.save("1").ok and session.close("1").ok, "restored member saves and releases")
		assert(#session.members() == 0, "close removes restored member")
	end,
}
return tests
