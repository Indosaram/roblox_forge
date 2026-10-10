--!strict
-- Specs for the cue policy's result envelope: a HUD dispatch and a world prompt are the
-- same committed outcome, so both must resolve to the action that succeeded and fire the
-- action-bound cue. `policy` is pure, so no engine global is needed here.

local AudioKit = require("./AudioKit")

local audio: any = {
	cues = { { key = "cue-attack" } },
	bindings = { { on = "action:pvp-arena:attack", cue = "cue-attack" } },
}

local function controller(extra: any)
	local fired = 0
	local options: any = {
		genre = "pvp-arena",
		audio = audio,
		playback = function()
			fired += 1
		end,
	}
	for key, value in extra do
		options[key] = value
	end
	return AudioKit.policy(options), function(): number
		return fired
	end
end

local M = {}

M["a HUD result envelope carrying packet.action fires the action-bound cue"] = function()
	-- The generated client publishes `{ result = result, action = actionId }`, so the action is
	-- read straight off the packet rather than looked up from a control id it never carries.
	local policy, fired = controller({})
	policy.receive(({ result = { ok = true }, action = "pvp-arena:attack" }) :: any)
	assert(fired() == 1, "the HUD envelope's action must fire its binding")
end

M["a prompt result envelope carrying only a control fires through the control mapping"] = function()
	-- A world prompt publishes `{ result = result, control = controlId }`; the echoed control
	-- resolves to the action it drives.
	local policy, fired = controller({ controlActions = { ["pvp-arena:attack"] = "pvp-arena:attack" } })
	policy.receive(({ result = { ok = true }, control = "pvp-arena:attack" }) :: any)
	assert(fired() == 1, "the prompt envelope's control must resolve to its action")
end

M["a namespaced control id resolves to the action it drives"] = function()
	local policy, fired = controller({ controlActions = { ["pvp-arena:attack-button"] = "pvp-arena:attack" } })
	policy.receive(({ result = { ok = true }, control = "pvp-arena:attack-button" }) :: any)
	assert(fired() == 1, "a control whose id is not the action must resolve through the mapping")
end

M["a refused result fires nothing"] = function()
	local policy, fired = controller({})
	policy.receive(({ result = { ok = false, reason = "RATE_LIMITED" }, action = "pvp-arena:attack" }) :: any)
	assert(fired() == 0, "only a committed success fires a cue")
end

return M
