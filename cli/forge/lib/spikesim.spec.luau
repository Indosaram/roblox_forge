--!strict
-- Specs for spikesim (QA-SPIKE-01 layer 1): the N=64 join spike meets the
-- wait target with nobody lost, no island over capacity, no split-brain lease
-- and no internal text in player messages; injected faults must be detected.

local spikesim = require("./spikesim")

local function describe(report: spikesim.Report): string
	return string.format(
		"p95=%s lost=%d dup=%d unadmitted=%d overfull=%d splitBrain=%d leaks=%d failures=%s",
		tostring(report.wait.p95),
		report.lost,
		report.duplicated,
		report.unadmitted,
		report.overfull,
		report.splitBrain,
		report.leaks,
		table.concat(report.failures, ",")
	)
end

local function assertHealthy(report: spikesim.Report)
	assert(report.wait.p95 <= spikesim.TARGET_P95_SECONDS, "p95 over target: " .. describe(report))
	assert(report.lost == 0, "players lost: " .. describe(report))
	assert(report.duplicated == 0, "players duplicated: " .. describe(report))
	assert(report.unadmitted == 0, "players never admitted: " .. describe(report))
	assert(report.overfull == 0, "overfull islands: " .. describe(report))
	assert(report.splitBrain == 0, "split-brain lease: " .. describe(report))
	assert(report.leaks == 0, "player message leaked internal text: " .. describe(report))
	assert(report.ok, "report not ok: " .. describe(report))
end

return {
	["N=64 spike meets the p95 target with nothing lost, overfull or leaked"] = function()
		local report = spikesim.run({ players = 64, seed = 1 })
		assert(report.players == 64 and report.wait.admitted == 64, describe(report))
		-- The spike really exercised the hard paths, not an empty run.
		assert(report.directJoins > 0, "no friend-follow joins were simulated")
		assert(report.moves > 0, "the allocator never rebalanced an overfull island")
		assert(report.islands >= 8, "64 players at cap 8 need at least 8 islands")
		assert(report.wait.p50 <= report.wait.p95 and report.wait.p95 <= report.wait.max, describe(report))
		assertHealthy(report)
	end,

	["the spike stays healthy across seeds, sizes and throttled commits"] = function()
		for _, options in
			{
				{ seed = 2 },
				{ seed = 7 },
				{ seed = 42, throttleRate = 0.3 },
				{ players = 256, seed = 3 },
			} :: { spikesim.Options }
		do
			local report = spikesim.run(options)
			assertHealthy(report)
		end
		local throttled = spikesim.run({ seed = 42, throttleRate = 0.3 })
		assert(throttled.throttled > 0, "throttle injection never fired")
	end,

	["the same seed gives the same report"] = function()
		local a = spikesim.run({ seed = 11, throttleRate = 0.2 })
		local b = spikesim.run({ seed = 11, throttleRate = 0.2 })
		assert(describe(a) == describe(b) and a.messages == b.messages and a.ticks == b.ticks, "nondeterministic")
		assert(a.wait.p50 == b.wait.p50 and a.wait.max == b.wait.max, "wait distribution differs")
	end,

	["NEGATIVE: with rebalancing disabled the spike detects overfull islands"] = function()
		local report = spikesim.run({ players = 64, seed = 1, rebalance = false })
		assert(report.overfull > 0, "overfull went undetected: " .. describe(report))
		assert(not report.ok and table.find(report.failures, "overfull") ~= nil, describe(report))
		assert(report.lost == 0, "disabling rebalance must not lose players: " .. describe(report))
	end,

	["NEGATIVE: raw backend errors in player messages are flagged as leaks"] = function()
		local report = spikesim.run({ seed = 42, throttleRate = 0.3, rawErrorMessages = true })
		assert(report.throttled > 0, "no failure path was exercised")
		assert(report.leaks > 0, "raw error text went undetected: " .. describe(report))
		assert(table.find(report.leakReasons, "internal_id") ~= nil, "island id leak not named")
		assert(table.find(report.leakReasons, "backend") ~= nil, "backend text leak not named")
		assert(not report.ok, describe(report))
	end,

	["NEGATIVE: an unreachable p95 target fails the run"] = function()
		-- One new instance per tick and a slow start push waits past the target.
		local report = spikesim.run({ seed = 1, maxNewInstancesPerTick = 1, instanceStartSeconds = 30 })
		assert(report.wait.p95 > spikesim.TARGET_P95_SECONDS, describe(report))
		assert(table.find(report.failures, "p95") ~= nil, describe(report))
		assert(report.lost == 0, describe(report))
	end,

	["the message scan catches ids, stack traces and SQL text"] = function()
		local ids = { "player-0001", "new:landing:3" }
		local clean = spikesim.scanMessages({ { key = "island.queue.waiting", params = { approxPosition = 5 } } }, ids)
		assert(clean == 0, "clean message flagged")
		local leaks, reasons = spikesim.scanMessages({
			{ key = "island.error.generic", params = {}, detail = "SQL error near SELECT" },
			{ key = "island.error.generic", params = {}, detail = "core/x.luau:12: attempt to index nil" },
			{ key = "island.error.generic", params = {}, detail = "player-0001 failed" },
			{ key = "island.travel.assigned", params = {} },
		}, ids)
		assert(leaks == 3, "expected 3 leaks, got " .. leaks)
		assert(table.concat(reasons, ",") == "internal_id,sql,stack", table.concat(reasons, ","))
	end,

	["percentile uses nearest rank"] = function()
		local sorted = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
		assert(spikesim.percentile(sorted, 0.5) == 5)
		assert(spikesim.percentile(sorted, 0.95) == 10)
		assert(spikesim.percentile({}, 0.95) == 0)
	end,

	["invalid options are rejected"] = function()
		for _, options in { { players = 0 }, { seed = -1 }, { throttleRate = 2 }, { kind = "moon" } } :: { any } do
			assert(not pcall(spikesim.run, options), "accepted invalid options")
		end
	end,
}
