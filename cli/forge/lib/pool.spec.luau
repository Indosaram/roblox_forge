--!strict
local pool = require("./pool")

-- Cheap real forge invocations: `--help` prints usage and exits 0, an unknown
-- command exits 2. Each spawns a fresh lune process (~1-2 s on a dev machine).
local HELP = { "--help" }
local UNKNOWN = { "no-such-cmd" }

return {
	["run keeps job order, stops a job at its first failing step, and reports each job once"] = function()
		local done: { [string]: number } = {}
		local doneCount = 0
		local results = pool.run(
			{
				{ name = "help", steps = { HELP } },
				{ name = "fails-first", steps = { UNKNOWN, HELP } },
				{ name = "help-twice", steps = { HELP, HELP } },
			},
			2,
			function(result)
				done[result.name] = (done[result.name] or 0) + 1
				doneCount += 1
			end
		)

		assert(#results == 3, "expected 3 results, got " .. #results)
		assert(
			results[1].name == "help" and results[2].name == "fails-first" and results[3].name == "help-twice",
			"order"
		)

		assert(results[1].ok == true and #results[1].steps == 1, "help job")
		assert(results[1].steps[1].code == 0, results[1].steps[1].stderr)
		assert(
			string.find(results[1].steps[1].stdout, "Usage: lune run cli/forge", 1, true),
			results[1].steps[1].stdout
		)

		local failing = results[2]
		assert(failing.ok == false, "a failing step must fail the job")
		assert(#failing.steps == 1, "the step after the first failure ran: " .. #failing.steps .. " steps")
		assert(failing.steps[1].code == 2, "unknown command exit " .. failing.steps[1].code)
		assert(failing.steps[1].args[1] == "no-such-cmd", "step args")

		assert(results[3].ok == true and #results[3].steps == 2, "every passing step runs")
		assert(results[3].steps[1].code == 0 and results[3].steps[2].code == 0, "help-twice codes")

		assert(doneCount == 3, "onDone calls: " .. doneCount)
		for _, name in { "help", "fails-first", "help-twice" } do
			assert(done[name] == 1, name .. " onDone count " .. tostring(done[name]))
		end
	end,

	["concurrency above one overlaps jobs"] = function()
		-- Proof without sleeps: each job's own ms is its measured duration, so a
		-- serial run takes at least their sum. Two overlapping jobs must finish in
		-- clearly less wall time than that sum.
		local started = os.clock()
		local results = pool.run({
			{ name = "a", steps = { HELP } },
			{ name = "b", steps = { HELP } },
		}, 2)
		local wallMs = (os.clock() - started) * 1000
		assert(results[1].ok and results[2].ok, "both help jobs must pass")
		local serialMs = results[1].ms + results[2].ms
		assert(
			wallMs < serialMs * 0.8,
			string.format("no overlap: wall %.0f ms vs serial sum %.0f ms", wallMs, serialMs)
		)
	end,
}
