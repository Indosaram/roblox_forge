--!strict
-- Specs for the objective chain's own rule: a committed world prompt advances the
-- chain exactly like the HUD's own control does. No engine, no network, no sleeps.

local HudLoop = require("./HudLoop")

--- A loop shaped like the generated packs': a repeated action (the grow-harvest
--- chain names the buy once, the plant twice) so a jump-to-the-last-stage bug would
--- show up here.
local function stages(): { any }
	return {
		{ id = "buy", actions = { "grow-harvest:buy-seed" } },
		{ id = "plant", actions = { "grow-harvest:plant" } },
		{ id = "harvest", actions = { "grow-harvest:harvest" } },
		{ id = "plant-again", actions = { "grow-harvest:plant" } },
		{ id = "sell", actions = { "grow-harvest:sell-held" } },
	}
end

local function spec(): any
	return {
		actions = {
			{
				action = "grow-harvest:buy-seed",
				control = { id = "grow-harvest:seed-shop", kind = "button", args = { "carrot" } },
			} :: any,
			{ action = "grow-harvest:plant", control = { id = "grow-harvest:plant-plot" } } :: any,
		},
	}
end

return {
	["a committed world prompt advances the chain, exactly like a HUD control"] = function()
		local chain = stages()
		local controls = HudLoop.controlActions(spec())
		assert(controls["grow-harvest:seed-shop"] == "grow-harvest:buy-seed", "control action mapping")
		-- The packet the world server publishes when a prompt's action commits.
		local packet = { result = { ok = true }, control = "grow-harvest:seed-shop" }
		local action = HudLoop.committedAction(packet, controls)
		assert(action == "grow-harvest:buy-seed", "the prompt's committed action resolves")
		assert(HudLoop.advance(chain, 1, action) == 2, "the chip moves to the stage the action completes")
	end,

	["a refused prompt advances nothing"] = function()
		local chain = stages()
		local controls = HudLoop.controlActions(spec())
		local refused = { result = { ok = false, reason = "INSUFFICIENT_FUNDS" }, control = "grow-harvest:seed-shop" }
		assert(HudLoop.committedAction(refused, controls) == nil, "a refusal names no committed action")
		-- A plain snapshot push carries no control at all, and must not move the chip.
		local snapshot = { snapshots = { ["grow-harvest"] = { balance = 9 } }, revision = 4 }
		assert(HudLoop.committedAction(snapshot, controls) == nil, "a snapshot push names no control")
		assert(HudLoop.advance(chain, 1, "grow-harvest:buy-seed") == 2, "the chain itself still advances")
	end,

	["a repeated action moves one stage, not to the last stage that names it"] = function()
		local chain = stages()
		assert(HudLoop.advance(chain, 2, "grow-harvest:plant") == 3, "plant completes its own stage")
		-- The chip names the goal the player is working on, so a completed stage shows
		-- the stage after it. A repeat matches the *next* stage naming that action, not
		-- the last one in the chain.
		assert(HudLoop.advance(chain, 3, "grow-harvest:plant") == 5, "the repeat matches the next stage naming it")
		assert(HudLoop.advance(chain, 5, "grow-harvest:buy-seed") == 5, "a completed stage holds the chip at the end")
	end,

	["an out-of-order completion jumps forward and never backwards"] = function()
		local chain = stages()
		-- A player who sells first has completed a later stage; the chip must not
		-- reset to the start of the chain.
		assert(HudLoop.advance(chain, 1, "grow-harvest:sell-held") == 5, "the chip jumps to the completed stage")
		assert(HudLoop.advance(chain, 5, "grow-harvest:buy-seed") == 5, "the chip never moves backwards")
	end,

	["a spec with no actions maps no control"] = function()
		assert(next(HudLoop.controlActions({})) == nil, "an empty spec maps no control")
		assert(next(HudLoop.controlActions(nil)) == nil, "a nil spec maps no control")
		assert(HudLoop.committedAction(nil, {}) == nil, "a nil packet names no action")
	end,
}
