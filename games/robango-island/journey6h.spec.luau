--!strict
-- journey6h: a fresh actor's first ~6 hours driven headlessly through the real RoleWorld,
-- SurvivalFactory, Session and the shipped client panel section (Journey.fixture). Every action is
-- picked from what the client shows: the quest card (opening tracker / objective tracker), its
-- waypoint target, the visible menu tiles and sheet buttons, and the world ProximityPrompts within
-- reach. The sim clock advances by walk time (16 studs/s) and the content's craft / respawn times.
-- Each stall (no affordance leads forward, a refused action, an unreachable target, a grind wall)
-- is recorded with the sim time, the shown objective (ko + en), what was shown, why it stalled and
-- the owning file:line. The full journey log goes to build/journey6h.json (gitignored); the spec
-- asserts only the known-good prefix, so new dead ends further down never flake it.
-- Budget: JOURNEY_HOURS sim hours (default 0.5: the opening, home, harbor and route 1's four drift
-- isles). The full six-hour journey is JOURNEY_HOURS=6 (slow: the sim runs near real time).
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Journey = require("./Journey.fixture")
local Runner = require("./JourneyRunner.fixture")

local OUT = "build/journey6h.json"

return {
	["journey6h: a fresh player's first six hours, every stall recorded (known-good prefix asserted)"] = function()
		local okr, log = xpcall(Runner.run, debug.traceback, Journey, {
			hours = tonumber(process.env.JOURNEY_HOURS) or 0.5,
			debug = process.env.JOURNEY_DEBUG == "1",
		})
		assert(okr, log)
		pcall(fs.writeDir, "build")
		fs.writeFile(OUT, serde.encode("json", log, true))
		print(string.format("WORKING journey6h: %d milestones, %d stalls -> %s", #log.pace, #log.stalls, OUT))
		for _, row in log.pace do
			print(string.format("  %7.1f min  L%-3d %s", row.minutes, row.level, row.milestone))
		end
		for index, stall in log.stalls do
			print(string.format("  stall %d @%.1f min [%s] %s", index, stall.minutes, stall.kind, stall.why))
		end
		-- Known-good prefix (6ff723b): opening, home, the harbor sale and route 1's four drift isles.
		local reached: { [string]: boolean } = {}
		for _, row in log.pace do
			reached[row.milestone] = true
		end
		for _, milestone in Runner.KNOWN_GOOD do
			assert(reached[milestone], "known-good milestone not reached: " .. milestone)
		end
	end,
}
