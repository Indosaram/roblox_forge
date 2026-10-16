--!strict
-- QA-CORE-01 specs: the survival first five minutes emit tutorial_step 1..N in
-- order, with no duplicates, tutorial_complete exactly once, and a rejoin
-- resumes at the same step.

local Events = require("../../../core/infra/analytics/Events")
local SurvivalTutorial = require("./SurvivalTutorial")

local GOLDEN = {
	"ArrivalDone",
	"Gathered",
	"CraftedStoneAxe",
	"SettlementDeclared",
	"ContractAccepted",
	"ContractDelivered",
}

type Log = { { name: string, step: number? } }

local function recorder(): (Events.Emitter, Log)
	local log: Log = {}
	local emitter = Events.new(function(name, fields)
		table.insert(log, { name = name, step = fields.step })
	end)
	return emitter, log
end

local function emitVia(emitter: Events.Emitter): SurvivalTutorial.Emit
	return function(name, fields)
		emitter:emit(name, fields)
	end
end

-- Returns nil when the log is a valid QA-CORE-01 trace, else the first defect.
local function audit(log: Log, total: number): string?
	local expected = 1
	local completes = 0
	for _, entry in log do
		if entry.name == "tutorial_step" then
			if completes > 0 then
				return "step after complete"
			end
			if entry.step ~= expected then
				return string.format("step %s where %d was expected", tostring(entry.step), expected)
			end
			expected += 1
		elseif entry.name == "tutorial_complete" then
			completes += 1
		end
	end
	if expected ~= total + 1 then
		return string.format("%d steps emitted, %d expected", expected - 1, total)
	end
	if completes ~= 1 then
		return string.format("tutorial_complete emitted %d times", completes)
	end
	return nil
end

return {
	["golden path teaches gather, stone axe, settlement, then the first contract"] = function()
		local order = {}
		for _, step in SurvivalTutorial.STEPS do
			table.insert(order, step.id)
		end
		assert(
			table.concat(order, ",")
				== "arrive,gather,craft-stone-axe,declare-settlement,accept-contract,deliver-contract",
			"plan §9.4 order: " .. table.concat(order, ",")
		)
	end,

	["golden path emits every step once in order and completes once"] = function()
		local emitter, log = recorder()
		local session = SurvivalTutorial.resume(nil, emitVia(emitter))
		assert(SurvivalTutorial.skipArrival(session), "arrival scene is skippable at once")
		for index = 2, #GOLDEN do
			assert(SurvivalTutorial.observe(session, GOLDEN[index]), GOLDEN[index] .. " advances")
		end
		assert(SurvivalTutorial.current(session) == nil, "tutorial complete")
		assert(audit(log, #GOLDEN) == nil, tostring(audit(log, #GOLDEN)))
		assert(emitter:counts().tutorial_complete == 1, "complete counted once")
		assert(not SurvivalTutorial.observe(session, "ContractDelivered"), "completed tutorial ignores events")
		assert(audit(log, #GOLDEN) == nil, "nothing emitted after completion")
	end,

	["out of order and repeated events emit nothing"] = function()
		local emitter, log = recorder()
		local session = SurvivalTutorial.resume(nil, emitVia(emitter))
		assert(not SurvivalTutorial.observe(session, "CraftedStoneAxe"), "craft before gather refused")
		assert(SurvivalTutorial.observe(session, "ArrivalDone"))
		assert(not SurvivalTutorial.observe(session, "ArrivalDone"), "repeat refused")
		assert(not SurvivalTutorial.observe(session, "ContractAccepted"), "contract before settlement refused")
		assert(#log == 1 and log[1].step == 1, "only the one valid step was emitted")
		assert(SurvivalTutorial.current(session) == "gather", "still on gather")
	end,

	["rejoin resumes at the same step without re-emitting finished steps"] = function()
		local emitter, log = recorder()
		local session = SurvivalTutorial.resume(nil, emitVia(emitter))
		for index = 1, 3 do
			assert(SurvivalTutorial.observe(session, GOLDEN[index]))
		end
		assert(SurvivalTutorial.current(session) == "declare-settlement", "on step 4 before leaving")
		local saved = SurvivalTutorial.save(session)
		local rejoined = SurvivalTutorial.resume(saved, emitVia(emitter))
		assert(SurvivalTutorial.current(rejoined) == "declare-settlement", "same step after rejoin")
		assert(#log == 3, "rejoin emits nothing")
		for index = 4, #GOLDEN do
			assert(SurvivalTutorial.observe(rejoined, GOLDEN[index]))
		end
		assert(audit(log, #GOLDEN) == nil, tostring(audit(log, #GOLDEN)))
		local again = SurvivalTutorial.resume(SurvivalTutorial.save(rejoined), emitVia(emitter))
		assert(SurvivalTutorial.current(again) == nil, "completed tutorial stays complete on rejoin")
		assert(audit(log, #GOLDEN) == nil, "no second completion after rejoin")
	end,

	["the audit catches duplicate, skipped and doubled completion traces"] = function()
		local total = #GOLDEN
		local function trace(steps: { number }, completes: number): Log
			local log: Log = {}
			for _, step in steps do
				table.insert(log, { name = "tutorial_step", step = step })
			end
			for _ = 1, completes do
				table.insert(log, { name = "tutorial_complete" })
			end
			return log
		end
		assert(audit(trace({ 1, 2, 3, 4, 5, 6 }, 1), total) == nil, "valid trace passes")
		assert(audit(trace({ 1, 2, 2, 3, 4, 5, 6 }, 1), total) ~= nil, "duplicate caught")
		assert(audit(trace({ 1, 3, 4, 5, 6 }, 1), total) ~= nil, "skip caught")
		assert(audit(trace({ 1, 2, 3, 4, 5, 6 }, 2), total) ~= nil, "double completion caught")
		assert(audit(trace({ 1, 2, 3 }, 0), total) ~= nil, "incomplete caught")
	end,
}
