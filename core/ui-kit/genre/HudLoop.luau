--!strict
-- HudLoop: the objective chain's own rule, split from the HUD so it can be read and
-- tested without an engine.
--
-- The chain is the spec's `loop`: an ordered list of stages, each naming the actions
-- that complete it. Any *committed* action advances the chain - the HUD's own
-- control, or a world prompt the server dispatched on the player's behalf. The HUD's
-- own dispatch used to be the only path that advanced it, which left a prompt-driven
-- buy showing "Buy a seed (1/8)" while the balance had already moved: the world had
-- committed the action, and the chip a player reads still named the stage they had
-- finished.
--
-- Nothing here names a Roblox global: the HUD reads the spec's loop and the committed
-- result, and this module turns them into the next stage index.

local M = {}

--- The action each declared control drives, keyed by control id. A committed world
--- prompt names the control it came from, and this is what turns that id back into
--- the action the loop's stages are keyed by.
function M.controlActions(spec: any): { [string]: string }
	local out: { [string]: string } = {}
	for _, row in (if type(spec) == "table" and type(spec.actions) == "table" then spec.actions else {}) do
		if type(row) == "table" and type(row.control) == "table" and type(row.control.id) == "string" then
			out[row.control.id] = tostring(row.action)
		end
	end
	return out
end

--- The action a committed state packet names, or nil when the packet committed
--- nothing the loop can close. The server publishes `{ result = ..., control = ... }`
--- for a world prompt's committed action; a refusal names no action.
function M.committedAction(packet: any, controlActions: { [string]: string }): string?
	if type(packet) ~= "table" or type(packet.result) ~= "table" then
		return nil
	end
	if packet.result.ok ~= true or type(packet.control) ~= "string" then
		return nil
	end
	return controlActions[packet.control]
end

--- The stage index (1-based) after `action` is committed at `stageIndex`. A loop
--- that repeats an action (plant, harvest, plant, harvest) has several stages naming
--- the same action, so "the last stage that names it" would jump the chip to the end
--- of the chain on the first press: the chip moves to the stage after the current
--- one, and only an out-of-order completion jumps forward.
function M.advance(stages: { any }, stageIndex: number, action: string): number
	local function matches(index: number): boolean
		local stage = stages[index]
		return type(stage) == "table" and table.find(stage.actions or {}, action) ~= nil
	end
	for index = stageIndex, #stages do
		if matches(index) then
			return math.max(stageIndex, math.min(index + 1, #stages))
		end
	end
	-- The action closes an earlier stage (a repeat, or a completion out of order):
	-- the chip moves to the stage after it rather than resetting to the start.
	for index = 1, stageIndex - 1 do
		if matches(index) then
			return math.max(stageIndex, math.min(index + 1, #stages))
		end
	end
	return stageIndex
end

return M
