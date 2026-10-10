--!strict
-- Specs for Tutorial: step order, event matching, completion, and save round-trips.

local Tutorial = require("./Tutorial")

local STEPS: { Tutorial.Step } = {
	{ id = "move", hint = "Move with WASD", event = "Move" },
	{ id = "hatch", hint = "Hatch an egg", event = "Hatch" },
	{ id = "sell", hint = "Sell some produce", event = "Sell" },
}

return {
	["fresh tutorial starts at step 1"] = function()
		local state = Tutorial.new(STEPS)
		local step = Tutorial.current(state)
		assert(step ~= nil, "fresh tutorial has a current step")
		assert(step.id == "move", "starts at first step")
		assert(Tutorial.isComplete(state) == false, "fresh tutorial is not complete")
	end,

	["wrong event does not advance"] = function()
		local state = Tutorial.new(STEPS)
		assert(Tutorial.observe(state, "Sell") == false, "wrong event must not advance")
		local step = Tutorial.current(state)
		assert(step ~= nil and step.id == "move", "still on first step")
	end,

	["matching events walk to completion"] = function()
		local state = Tutorial.new(STEPS)
		assert(Tutorial.observe(state, "Move") == true, "first event advances")
		assert(Tutorial.observe(state, "Hatch") == true, "second event advances")
		assert(Tutorial.current(state) ~= nil, "still has a step before the last")
		assert(Tutorial.observe(state, "Sell") == true, "last event advances")
		assert(Tutorial.current(state) == nil, "no current step when complete")
		assert(Tutorial.isComplete(state) == true, "walked to completion")
	end,

	["completed save restores as complete"] = function()
		local state = Tutorial.fromSave(STEPS, { index = 1, completed = true })
		assert(Tutorial.current(state) == nil, "completed restore has no current step")
		assert(Tutorial.isComplete(state) == true, "completed restore stays complete")
	end,

	["partial save resumes at the saved step"] = function()
		local state = Tutorial.fromSave(STEPS, { index = 2, completed = false })
		local step = Tutorial.current(state)
		assert(step ~= nil, "resumed tutorial has a current step")
		assert(step.id == "hatch", "resumes at the saved step")
	end,

	["an out-of-range index with completed false still restores as complete"] = function()
		local state = Tutorial.fromSave(STEPS, { index = 99, completed = false })
		assert(Tutorial.current(state) == nil, "out-of-range restore has no current step")
		assert(Tutorial.isComplete(state) == true, "out-of-range restore reports complete")
		local saved = Tutorial.toSave(state)
		assert(saved.completed == true, "round-tripped save is marked completed")
	end,

	["skip completes"] = function()
		local state = Tutorial.new(STEPS)
		Tutorial.skip(state)
		assert(Tutorial.isComplete(state) == true, "skip completes")
		assert(Tutorial.current(state) == nil, "skip leaves no current step")
	end,

	["a fractional saved index falls back to step 1 instead of soft-locking"] = function()
		local state = Tutorial.fromSave(STEPS, { index = 1.5, completed = false })
		local step = Tutorial.current(state)
		assert(step ~= nil, "fractional index must not soft-lock the tutorial")
		assert(step.id == "move", "fractional index falls back to the first step")
		assert(Tutorial.isComplete(state) == false, "fractional index restore is not complete")
		assert(Tutorial.observe(state, "Move") == true, "restored tutorial can still advance")
	end,

	["a nil saved index falls back to step 1 instead of erroring"] = function()
		local state = Tutorial.fromSave(STEPS, { index = nil :: any, completed = false })
		local step = Tutorial.current(state)
		assert(step ~= nil, "nil index must not soft-lock the tutorial")
		assert(step.id == "move", "nil index falls back to the first step")
		assert(Tutorial.isComplete(state) == false, "nil index restore is not complete")
	end,
}
