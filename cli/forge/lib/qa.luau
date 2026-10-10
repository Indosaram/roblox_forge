--!strict
-- Pure QA scenario logic for `forge qa`: decode and validate genre qa-scenario
-- YAML, sum the Open Cloud Luau Execution smoke budget, and render the per-pack
-- QA plan. Nothing here touches the filesystem or the network, so the same rules
-- run unchanged under Lune specs; the `qa` command does the walking and writing.
--
-- Smoke scenarios run headlessly through the Luau Execution API, so they may
-- only use actions that need neither client input nor rendering. Playtest
-- scenarios run under the Studio MCP playtest subagent, which can inject input
-- (click) and capture the screen (capture).

local serde = require("@lune/serde")
local contract = require("./genrecontract")
local registryLib = require("./genreregistry")

local M = {}

export type Entry = {
	genre: string,
	scenario: any,
}

export type PlanInput = {
	pack: string,
	genres: { string },
	scenarioNames: { string },
	entries: { Entry },
}

export type Opts = {
	expectedGenre: string?,
	expectedName: string?,
	availableSlots: { [string]: boolean }?,
	operations: { string }?,
	targets: { string }?,
}

--- Open Cloud Luau Execution caps a single job at 5 minutes; the CI smoke
--- contract in plan §11.3 is one headless run under 60 seconds.
M.SMOKE_BUDGET_SECONDS = 60

M.ACTIONS = {
	"join",
	"wait",
	"click",
	"execute_luau",
	"purchase_sim",
	"leave",
	"rejoin",
	"capture",
}

M.KINDS = { "smoke", "playtest" }

-- Paid random items are forbidden, so purchase_sim may only target one of the
-- deterministic monetization slots; `forge qa plan` resolves the pack's keys.
M.PURCHASE_SLOTS = { "gamepass", "product", "subscription" }

-- Actions that need the rendered client (Studio MCP input injection or screen
-- capture) and therefore cannot run in the headless smoke set.
M.PLAYTEST_ONLY_ACTIONS = { "click", "capture" }

local ACTION_REQUIRED_FIELD: { [string]: string } = {
	wait = "seconds",
	click = "target",
	execute_luau = "code",
	purchase_sim = "target",
	capture = "target",
}

local function isKnown(list: { string }, value: any): boolean
	if typeof(value) ~= "string" then
		return false
	end
	for _, known in list do
		if known == value then
			return true
		end
	end
	return false
end

--- Decodes a scenario YAML document. Returns `(scenario, nil)` or `(nil, reason)`.
function M.decode(source: string): (any?, string?)
	local ok, decoded = pcall(function()
		return serde.decode("yaml", source)
	end)
	if not ok then
		return nil, tostring(decoded)
	end
	if typeof(decoded) ~= "table" then
		return nil, "scenario is not a YAML mapping"
	end
	return decoded, nil
end

--- Returns every schema or policy violation in a decoded scenario, in order.
--- An empty list means the scenario is valid.
function M.validate(scenario: any, opts: Opts?): { string }
	local errors: { string } = {}
	local options: Opts = opts or {}

	if typeof(scenario) ~= "table" then
		return { "not a YAML mapping" }
	end
	if scenario.contract_api ~= nil then
		if scenario.contract_api ~= 1 then
			table.insert(errors, "unsupported contract_api")
		end
		if not contract.dense(scenario.operations, 64) or #scenario.operations == 0 then
			table.insert(errors, "operations must be a nonempty dense list")
		else
			local seen = {}
			for _, operation in scenario.operations do
				if
					type(operation) ~= "string"
					or seen[operation]
					or (options.operations and not table.find(options.operations, operation))
				then
					table.insert(errors, "unknown/duplicate operation: " .. tostring(operation))
				end
				seen[operation] = true
			end
		end
	end

	if typeof(scenario.name) ~= "string" or scenario.name == "" then
		table.insert(errors, "missing or empty 'name'")
	elseif options.expectedName ~= nil and scenario.name ~= options.expectedName then
		table.insert(
			errors,
			string.format("name '%s' does not match file '%s.yml'", scenario.name, options.expectedName)
		)
	end

	if typeof(scenario.genre) ~= "string" or scenario.genre == "" then
		table.insert(errors, "missing or empty 'genre'")
	elseif options.expectedGenre ~= nil and scenario.genre ~= options.expectedGenre then
		table.insert(
			errors,
			string.format("genre '%s' does not match directory '%s'", scenario.genre, options.expectedGenre)
		)
	end

	local kind = scenario.kind
	if not isKnown(M.KINDS, kind) then
		table.insert(errors, "kind must be one of " .. table.concat(M.KINDS, "|"))
	end

	local steps = scenario.steps
	if not contract.dense(steps, 1024) then
		table.insert(errors, "missing 'steps' list")
		return errors
	end
	if #steps == 0 then
		table.insert(errors, "steps must not be empty")
		return errors
	end

	for index, rawStep in steps do
		local label = "step " .. tostring(index)
		if typeof(rawStep) ~= "table" then
			table.insert(errors, label .. ": not a mapping")
			continue
		end

		local action = rawStep.action
		if not isKnown(M.ACTIONS, action) then
			table.insert(errors, string.format("%s: unknown action '%s'", label, tostring(action)))
			continue
		end

		if kind == "smoke" and isKnown(M.PLAYTEST_ONLY_ACTIONS, action) then
			table.insert(
				errors,
				string.format("%s (%s): smoke scenarios cannot use '%s' (needs Studio MCP)", label, action, action)
			)
		end

		-- Every smoke step must carry a `seconds` estimate: otherwise the CI Luau
		-- Execution budget gate (M.smokeSeconds/M.budgetWarning) silently sums to 0
		-- and can never catch a scenario that overruns the real budget. Only the
		-- *missing* case is reported here: a present but non-positive or non-number
		-- value is already reported by the generic check below, and reporting both
		-- would emit two errors for one problem.
		if kind == "smoke" and action ~= nil and rawStep.seconds == nil then
			table.insert(
				errors,
				string.format("%s (%s): smoke steps must carry a positive 'seconds' estimate", label, action)
			)
		end

		if rawStep.target ~= nil and typeof(rawStep.target) ~= "string" then
			table.insert(errors, string.format("%s (%s): 'target' must be a string", label, action))
		end
		if
			scenario.contract_api == 1
			and rawStep.target ~= nil
			and options.targets
			and not table.find(options.targets, rawStep.target)
		then
			table.insert(errors, label .. ": undeclared target")
		end
		if rawStep.code ~= nil and typeof(rawStep.code) ~= "string" then
			table.insert(errors, string.format("%s (%s): 'code' must be a string", label, action))
		end
		if rawStep.expect ~= nil and typeof(rawStep.expect) ~= "string" then
			table.insert(errors, string.format("%s (%s): 'expect' must be a string", label, action))
		end
		if
			rawStep.seconds ~= nil
			and (
				typeof(rawStep.seconds) ~= "number"
				or rawStep.seconds ~= rawStep.seconds
				or rawStep.seconds == math.huge
				or rawStep.seconds <= 0
			)
		then
			table.insert(errors, string.format("%s (%s): 'seconds' must be a positive number", label, action))
		end

		local required = ACTION_REQUIRED_FIELD[action]
		if required ~= nil then
			local value = rawStep[required]
			-- For 'seconds', only report a missing field here: a present-but-invalid
			-- value (wrong type, non-positive) is already reported once by the
			-- generic 'seconds' check above (and, for smoke, the missing case is
			-- already reported once by the smoke-only check above), so checking
			-- presence again here would double-report the same problem.
			local present = if required == "seconds" then value ~= nil else typeof(value) == "string" and value ~= ""
			if not present and not (required == "seconds" and kind == "smoke") then
				table.insert(errors, string.format("%s (%s): missing '%s'", label, action, required))
			end
		end

		if action == "purchase_sim" and typeof(rawStep.target) == "string" then
			local target = rawStep.target
			if not isKnown(M.PURCHASE_SLOTS, target) then
				table.insert(
					errors,
					string.format(
						"%s (purchase_sim): target '%s' is not a deterministic slot (%s)",
						label,
						target,
						table.concat(M.PURCHASE_SLOTS, "|")
					)
				)
			elseif options.availableSlots ~= nil and not options.availableSlots[target] then
				table.insert(
					errors,
					string.format("%s (purchase_sim): pack declares no deterministic '%s' item", label, target)
				)
			end
		end
	end

	return errors
end

--- Sums the estimated seconds of every step in a scenario. Smoke steps carry an
--- explicit `seconds` estimate: wait steps use their real duration, everything
--- else its expected round-trip cost.
function M.smokeSeconds(scenario: any): number
	if typeof(scenario) ~= "table" or typeof(scenario.steps) ~= "table" then
		return 0
	end
	local total = 0
	for _, step in scenario.steps do
		if typeof(step) == "table" and typeof(step.seconds) == "number" then
			total += step.seconds
		end
	end
	return total
end

--- Returns a warning string when the smoke set exceeds the CI budget, else nil.
function M.budgetWarning(totalSeconds: number): string?
	if totalSeconds > M.SMOKE_BUDGET_SECONDS then
		return string.format(
			"smoke budget exceeded: %.0fs of %ds (Open Cloud Luau Execution must finish the smoke run under %ds)",
			totalSeconds,
			M.SMOKE_BUDGET_SECONDS,
			M.SMOKE_BUDGET_SECONDS
		)
	end
	return nil
end

local function codeList(values: { string }): string
	local parts: { string } = {}
	for _, value in values do
		table.insert(parts, "`" .. value .. "`")
	end
	return table.concat(parts, ", ")
end

local function stepLine(step: any): string
	local bits: { string } = {}
	if typeof(step.target) == "string" then
		table.insert(bits, "target=`" .. step.target .. "`")
	end
	if typeof(step.seconds) == "number" then
		table.insert(bits, string.format("seconds=%g", step.seconds))
	end
	if typeof(step.code) == "string" then
		table.insert(bits, "code=`" .. step.code .. "`")
	end
	if typeof(step.expect) == "string" then
		table.insert(bits, "expect: " .. step.expect)
	end
	local suffix = if #bits > 0 then " " .. table.concat(bits, " ") else ""
	return "- `" .. tostring(step.action) .. "`" .. suffix
end

local function appendScenarios(lines: { string }, entries: { Entry })
	for _, entry in entries do
		table.insert(lines, "")
		table.insert(lines, string.format("### %s (`%s`)", entry.scenario.name, entry.genre))
		table.insert(lines, "")
		for _, step in entry.scenario.steps do
			table.insert(lines, stepLine(step))
		end
	end
end

--- Renders reports/qa-plan-<pack>.md: smoke steps for the CI Luau Execution run
--- and playtest steps for the Studio MCP playtest subagent.
function M.renderPlan(input: PlanInput): string
	local smoke: { Entry } = {}
	local playtest: { Entry } = {}
	local smokeTotal = 0
	for _, entry in input.entries do
		if entry.scenario.kind == "smoke" then
			table.insert(smoke, entry)
			smokeTotal += M.smokeSeconds(entry.scenario)
		else
			table.insert(playtest, entry)
		end
	end

	local lines: { string } = {}
	table.insert(lines, "# QA plan - " .. input.pack)
	table.insert(lines, "")
	table.insert(lines, "- Pack: `games/" .. input.pack .. "`")
	table.insert(lines, "- Genres: " .. codeList(input.genres))
	table.insert(lines, "- Scenarios: " .. codeList(input.scenarioNames))
	table.insert(lines, "")
	table.insert(lines, "## Smoke - Open Cloud Luau Execution")
	table.insert(lines, "")
	table.insert(lines, string.format("Budget: %gs / %ds", smokeTotal, M.SMOKE_BUDGET_SECONDS))
	local warning = M.budgetWarning(smokeTotal)
	if warning ~= nil then
		table.insert(lines, "")
		table.insert(lines, "> WARNING: " .. warning)
	end
	table.insert(lines, "")
	table.insert(lines, "Headless run: no input injection and no rendering.")
	if #smoke == 0 then
		table.insert(lines, "")
		table.insert(lines, "_No smoke scenarios._")
	else
		appendScenarios(lines, smoke)
	end
	table.insert(lines, "")
	table.insert(lines, "## Playtest - Studio MCP playtest agent")
	table.insert(lines, "")
	table.insert(lines, "Tools: `start_stop_play`, `execute_luau`, `screen_capture`.")
	if #playtest == 0 then
		table.insert(lines, "")
		table.insert(lines, "_No playtest scenarios._")
	else
		appendScenarios(lines, playtest)
	end
	return table.concat(lines, "\n") .. "\n"
end

function M.selection(game: any, registry: registryLib.Registry, entries: { Entry }): { string }
	local errors: { string } = {}
	if not contract.dense(game.genres, 64) or #game.genres == 0 then
		return { "invalid genres list" }
	end
	local seen = {}
	for _, id in game.genres do
		if not contract.id(id) or seen[id] or registry.packages[id] == nil then
			table.insert(errors, "invalid/duplicate/unknown genre: " .. tostring(id))
		end
		seen[id] = true
	end
	if not contract.dense(game.qa_scenarios, 1024) or #game.qa_scenarios == 0 then
		return { "invalid qa_scenarios list" }
	end
	local available, requested = {}, {}
	local total = 0
	for _, entry in entries do
		available[entry.genre .. ":" .. entry.scenario.name] = true
		if entry.scenario.kind == "smoke" then
			total += M.smokeSeconds(entry.scenario)
		end
	end
	for _, name in game.qa_scenarios do
		if type(name) ~= "string" or requested[name] then
			table.insert(errors, "invalid/duplicate scenario: " .. tostring(name))
			continue
		end
		requested[name] = true
		if game.genre_contract ~= nil then
			local id, localName = string.match(name, "^([^:]+):([^:]+)$")
			if not id or not seen[id] or not contract.id(localName) or not available[name] then
				table.insert(errors, "missing qualified scenario: " .. name)
			end
		else
			local found = false
			for _, id in game.genres do
				if available[id .. ":" .. name] then
					found = true
				end
			end
			if not found then
				table.insert(errors, "missing scenario: " .. name)
			end
		end
	end
	if game.genre_contract ~= nil then
		if game.genre_contract ~= 1 then
			table.insert(errors, "unsupported genre_contract")
		end
		for _, id in game.genres do
			local package = registry.packages[id]
			if package then
				local crafting = game.runtime_mode == "crafting" and id == "survival-coop"
				local required: { string } = if crafting
					then { "bootstrap-crafting" }
					else package.generator.qa.scenarios
				for _, name in required do
					local qualified = id .. ":" .. name
					if not requested[qualified] or not available[qualified] then
						table.insert(errors, "required scenario missing: " .. qualified)
					end
					if crafting then
						for _, entry in entries do
							if entry.genre ~= id or entry.scenario.name ~= name then
								continue
							end
							local closed, reloaded, joined, asserted = false, false, false, false
							for _, step in entry.scenario.steps do
								closed = closed or step.op == "close"
								reloaded = reloaded or (closed and step.op == "reload")
								joined = joined or (reloaded and step.op == "join")
								asserted = asserted or (joined and step.op == "expect_snapshot")
							end
							if entry.scenario.kind ~= "native" or not asserted then
								table.insert(errors, "crafting bootstrap requires native durable rejoin assertions")
							end
						end
					end
				end
			end
		end
		local warning = M.budgetWarning(total)
		if warning then
			table.insert(errors, warning)
		end
	end
	table.sort(errors)
	return errors
end
return M
