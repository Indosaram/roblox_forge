--!strict
-- Tutorial: pure first-session step machine advanced by observed gameplay events.

export type Step = { id: string, hint: string, event: string }

export type State = { steps: { Step }, index: number, completed: boolean }

export type Save = { index: number, completed: boolean }

local Tutorial = {}

-- A completed tutorial points one past its last step.
local function indexAfter(steps: { Step }): number
	return #steps + 1
end

function Tutorial.new(steps: { Step }, completed: boolean?): State
	local done = completed == true
	return {
		steps = steps,
		index = if done then indexAfter(steps) else 1,
		completed = done,
	}
end

function Tutorial.current(state: State): Step?
	if state.completed then
		return nil
	end
	return state.steps[state.index]
end

-- Advances one step when the observed event matches the current step's event.
function Tutorial.observe(state: State, eventName: string): boolean
	local step = Tutorial.current(state)
	if step == nil or step.event ~= eventName then
		return false
	end
	state.index += 1
	if state.index > #state.steps then
		state.completed = true
	end
	return true
end

function Tutorial.isComplete(state: State): boolean
	return state.completed or state.index > #state.steps
end

function Tutorial.skip(state: State): ()
	state.index = indexAfter(state.steps)
	state.completed = true
end

function Tutorial.toSave(state: State): Save
	return { index = state.index, completed = state.completed }
end

function Tutorial.fromSave(steps: { Step }, saved: Save?): State
	if saved == nil then
		return Tutorial.new(steps)
	end
	local index = saved.index
	if type(index) ~= "number" or index ~= index or index % 1 ~= 0 then
		index = 1
	end
	if saved.completed or index > #steps then
		return Tutorial.new(steps, true)
	end
	local state = Tutorial.new(steps)
	state.index = math.max(1, index)
	return state
end

return Tutorial
