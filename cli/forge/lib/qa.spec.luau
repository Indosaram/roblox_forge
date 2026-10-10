--!strict
-- Specs for qa: scenario schema validation, deterministic purchase_sim targets,
-- the headless smoke-only action rule, and the 60s smoke budget.

local qa = require("./qa")

local VALID_PLAYTEST = [[
name: core-loop
genre: collect-raid
kind: playtest
steps:
  - action: join
    seconds: 5
  - action: click
    target: buy-egg-button
  - action: execute_luau
    code: 'assert(ForgeQA.owned >= 1, "collected a unit")'
    expect: 'the collection grew by one'
  - action: capture
    target: core-loop
]]

local VALID_SMOKE = [[
name: rejoin
genre: collect-raid
kind: smoke
steps:
  - action: join
    seconds: 5
  - action: wait
    seconds: 10
  - action: purchase_sim
    target: product
    seconds: 3
    expect: 'a deterministic product is granted'
]]

local function decodeOrNil(source: string): any
	local scenario = qa.decode(source)
	return scenario
end

local function errorsOf(source: string, opts: qa.Opts?): { string }
	local scenario = decodeOrNil(source)
	assert(scenario ~= nil, "scenario must decode")
	return qa.validate(scenario, opts)
end

local function contains(list: { string }, needle: string): boolean
	for _, value in list do
		if string.find(value, needle, 1, true) ~= nil then
			return true
		end
	end
	return false
end

return {
	["crafting selection requires executable bootstrap with durable rejoin while wave requirements remain"] = function()
		local registry = assert(require("./genreregistry").discover())
		local fs = require("@lune/fs")
		local scenario: any = assert(qa.decode(fs.readFile("genres/survival-coop/qa-scenarios/bootstrap-crafting.yml")))
		local game = {
			genres = { "survival-coop" },
			genre_contract = 1,
			runtime_mode = "crafting",
			qa_scenarios = { "survival-coop:bootstrap-crafting" },
		}
		local entries = { { genre = "survival-coop", scenario = scenario } }
		assert(#qa.selection(game, registry, entries) == 0, "native crafting selection accepted")
		game.runtime_mode = "wave"
		assert(#qa.selection(game, registry, entries) == 2, "wave still requires loop and rejoin")
		game.runtime_mode = "crafting"
		local noRejoin: { any } = { { op = "join", player = "1" }, { op = "expect_members", members = { "1" } } }
		scenario.steps = noRejoin
		assert(#qa.selection(game, registry, entries) > 0, "bootstrap without rejoin rejected")
		game.qa_scenarios = {}
		assert(#qa.selection(game, registry, entries) > 0, "empty selection rejected")
	end,
	["qualified scenarios require each selected package and enforce 60 second boundary"] = function()
		local generator = { qa = { scenarios = { "contract-loop", "contract-rejoin" } } }
		local registry = {
			root = "fixture",
			order = { "alpha" },
			packages = { alpha = { generator = generator } },
			runtimes = {},
		} :: any
		local game = {
			genres = { "alpha" },
			genre_contract = 1,
			qa_scenarios = {
				"alpha:contract-loop",
				"alpha:contract-rejoin",
			},
		}
		local entries = {
			{ genre = "alpha", scenario = { name = "contract-loop", kind = "smoke", steps = { { seconds = 30 } } } },
			{ genre = "alpha", scenario = { name = "contract-rejoin", kind = "smoke", steps = { { seconds = 30 } } } },
		}
		assert(#qa.selection(game, registry, entries) == 0, "60 seconds must pass")
		entries[2].scenario.steps[1].seconds = 31
		assert(#qa.selection(game, registry, entries) > 0, "61 seconds must fail")
		entries[2] = nil :: any
		assert(#qa.selection(game, registry, entries) > 0, "missing own qualified scenario accepted")
	end,
	["contract operation and target capabilities are validated"] = function()
		local scenario = {
			name = "contract-loop",
			genre = "alpha",
			kind = "smoke",
			contract_api = 1,
			operations = { "unknown" },
			steps = { { action = "execute_luau", code = "opaque", seconds = 1, target = "alpha:missing" } },
		}
		assert(
			#qa.validate(scenario, { operations = { "dispatch" }, targets = { "alpha:increment" } }) == 2,
			"capability errors missing"
		)
	end,
	["valid playtest scenario passes with no errors"] = function()
		local errors = errorsOf(VALID_PLAYTEST)
		assert(#errors == 0, "expected no errors, got: " .. table.concat(errors, "; "))
	end,

	["valid smoke scenario passes with no errors"] = function()
		local errors = errorsOf(VALID_SMOKE)
		assert(#errors == 0, "expected no errors, got: " .. table.concat(errors, "; "))
	end,

	["unknown action fails"] = function()
		local errors = errorsOf([[name: x
genre: collect-raid
kind: playtest
steps:
  - action: teleport
]])
		assert(
			contains(errors, "unknown action"),
			"expected an unknown action error, got: " .. table.concat(errors, "; ")
		)
	end,

	["missing steps fails"] = function()
		local errors = errorsOf([[name: x
genre: collect-raid
kind: playtest
]])
		assert(
			contains(errors, "missing 'steps'"),
			"expected a missing steps error, got: " .. table.concat(errors, "; ")
		)
	end,

	["empty steps fails"] = function()
		local errors = errorsOf([[name: x
genre: collect-raid
kind: playtest
steps: []
]])
		assert(contains(errors, "steps must not be empty"), "expected an empty steps error")
	end,

	["wait without seconds fails"] = function()
		local errors = errorsOf([[name: x
genre: collect-raid
kind: playtest
steps:
  - action: wait
]])
		assert(contains(errors, "missing 'seconds'"), "expected a missing seconds error")
	end,

	["purchase_sim rejects a non-deterministic target"] = function()
		local errors = errorsOf([[name: x
genre: collect-raid
kind: smoke
steps:
  - action: purchase_sim
    target: lootbox
]])
		assert(
			contains(errors, "deterministic slot"),
			"expected a deterministic slot error, got: " .. table.concat(errors, "; ")
		)
	end,

	["purchase_sim rejects a slot the pack does not sell"] = function()
		local errors = errorsOf(
			[[name: x
genre: collect-raid
kind: smoke
steps:
  - action: purchase_sim
    target: subscription
]],
			{ availableSlots = { product = true } }
		)
		assert(contains(errors, "no deterministic"), "expected a pack slot error, got: " .. table.concat(errors, "; "))
	end,

	["smoke scenario rejects click"] = function()
		local errors = errorsOf([[name: x
genre: collect-raid
kind: smoke
steps:
  - action: click
    target: shop
]])
		assert(
			contains(errors, "smoke scenarios cannot use"),
			"expected a smoke-only action error, got: " .. table.concat(errors, "; ")
		)
	end,

	["F9: smoke steps without seconds are rejected instead of silently costing 0s"] = function()
		local errors = errorsOf([[name: x
genre: collect-raid
kind: smoke
steps:
  - action: join
  - action: execute_luau
    code: 'x'
]])
		assert(
			contains(errors, "must carry a positive 'seconds' estimate"),
			"expected a missing-seconds smoke error, got: " .. table.concat(errors, "; ")
		)
		local scenario = decodeOrNil([[name: x
genre: collect-raid
kind: smoke
steps:
  - action: join
  - action: execute_luau
    code: 'x'
]])
		assert(
			qa.smokeSeconds(scenario) == 0,
			"an invalid scenario still sums to 0s (validation, not smokeSeconds, is the gate)"
		)
	end,

	["F9: a playtest scenario is not held to the smoke seconds requirement"] = function()
		local errors = errorsOf([[name: x
genre: collect-raid
kind: playtest
steps:
  - action: join
]])
		assert(
			not contains(errors, "must carry a positive 'seconds' estimate"),
			"playtest steps must not be required to carry seconds: " .. table.concat(errors, "; ")
		)
	end,

	["F9: a smoke step with a non-positive seconds is reported once, not twice"] = function()
		local errors = errorsOf([[name: x
genre: collect-raid
kind: smoke
steps:
  - action: join
    seconds: 0
]])
		local secondsErrors = 0
		for _, err in errors do
			if string.find(err, "seconds", 1, true) ~= nil then
				secondsErrors += 1
			end
		end
		assert(
			secondsErrors == 1,
			"one bad seconds value must yield exactly one error, got "
				.. tostring(secondsErrors)
				.. ": "
				.. table.concat(errors, "; ")
		)
	end,

	["F9: a smoke wait step with a non-positive seconds is reported once, not twice"] = function()
		-- 'wait' is both a smoke-seconds-checked action and one of
		-- ACTION_REQUIRED_FIELD's required-field actions (required = "seconds"),
		-- so a present-but-bad value must not double-report through both paths,
		-- and the required-field path must not call a present field "missing".
		local errors = errorsOf([[name: x
genre: collect-raid
kind: smoke
steps:
  - action: wait
    seconds: 0
]])
		local secondsErrors = 0
		for _, err in errors do
			if string.find(err, "seconds", 1, true) ~= nil then
				secondsErrors += 1
			end
		end
		assert(
			secondsErrors == 1,
			"one bad seconds value on a wait step must yield exactly one error, got "
				.. tostring(secondsErrors)
				.. ": "
				.. table.concat(errors, "; ")
		)
		assert(
			not contains(errors, "missing 'seconds'"),
			"seconds is present (0), so no error may call it missing: " .. table.concat(errors, "; ")
		)
	end,

	["F9: a smoke wait step with no seconds is reported once, not twice"] = function()
		local errors = errorsOf([[name: x
genre: collect-raid
kind: smoke
steps:
  - action: wait
]])
		local secondsErrors = 0
		for _, err in errors do
			if string.find(err, "seconds", 1, true) ~= nil then
				secondsErrors += 1
			end
		end
		assert(
			secondsErrors == 1,
			"a missing seconds on a wait step must yield exactly one error, got "
				.. tostring(secondsErrors)
				.. ": "
				.. table.concat(errors, "; ")
		)
	end,

	["name and genre must match the file location"] = function()
		local errors = errorsOf(VALID_PLAYTEST, { expectedName = "tutorial", expectedGenre = "pvp-arena" })
		assert(contains(errors, "does not match file"), "expected a name mismatch error")
		assert(contains(errors, "does not match directory"), "expected a genre mismatch error")
	end,

	["smoke seconds sums every step estimate"] = function()
		local scenario = decodeOrNil(VALID_SMOKE)
		assert(qa.smokeSeconds(scenario) == 18, "expected 5 + 10 + 3 = 18 seconds")
	end,

	["smoke budget warns only past 60 seconds"] = function()
		assert(qa.budgetWarning(60) == nil, "60s is within budget")
		local warning = qa.budgetWarning(61)
		assert(warning ~= nil, "61s must warn")
		assert(contains({ warning :: string }, "smoke budget exceeded"), "warning must name the budget")
	end,

	["plan renders scenario actions, targets and the budget"] = function()
		local scenario = decodeOrNil(VALID_SMOKE)
		local playtest = decodeOrNil(VALID_PLAYTEST)
		local markdown = qa.renderPlan({
			pack = "kaiju-egg-raiders",
			genres = { "collect-raid" },
			scenarioNames = { "rejoin", "core-loop" },
			entries = {
				{ genre = "collect-raid", scenario = scenario },
				{ genre = "collect-raid", scenario = playtest },
			},
		})
		assert(contains({ markdown }, "`purchase_sim` target=`product` seconds=3"), "smoke purchase target rendered")
		assert(contains({ markdown }, "`click` target=`buy-egg-button`"), "playtest input target rendered")
		assert(
			contains({ markdown }, "code=`" .. playtest.steps[3].code .. "`"),
			"playtest executable assertion rendered"
		)
		assert(contains({ markdown }, "18s / 60s"), "smoke budget rendered")
	end,
}
