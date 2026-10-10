--!strict
-- Specs for CollectRaid: team vaults, siege phase hooks, and raid rules.

local CollectRaid = require("./CollectRaid")

-- period 10, duration 4: active during [10, 14), [20, 24), ... idle otherwise.
local function newModule(hooks: CollectRaid.Hooks?): CollectRaid.CollectRaid
	return CollectRaid.new({
		teams = { "red", "blue" },
		siege = { period = 10, duration = 4, maxTake = 2 },
	}, hooks)
end

return {
	["collect deposits into the team vault and fires OnCollect with the context"] = function()
		local seen: { CollectRaid.CollectCtx } = {}
		local mod = newModule({
			OnCollect = function(ctx)
				table.insert(seen, ctx)
			end,
		})

		mod:collect("red", "egg-1", true)

		assert(#seen == 1, "OnCollect fired once")
		assert(seen[1].team == "red", "ctx team")
		assert(seen[1].itemId == "egg-1", "ctx itemId")
		assert(seen[1].raidable == true, "ctx raidable")
		assert(mod:counts().red == 1, "item landed in the red vault")
	end,

	["OnSiegePhase fires exactly once per phase change"] = function()
		local events: { CollectRaid.SiegePhaseCtx } = {}
		local mod = newModule({
			OnSiegePhase = function(ctx)
				table.insert(events, ctx)
			end,
		})

		mod:phase(0) -- idle
		local afterFirst = #events

		mod:phase(1) -- still idle
		assert(#events == afterFirst, "no repeat while the phase is unchanged")

		local phase = mod:phase(11) -- active
		assert(phase == "active", "phase at one period plus one")
		assert(#events == afterFirst + 1, "fires on idle -> active")
		assert(events[#events].phase == "active", "ctx phase")
		assert(events[#events].secondsLeft > 0, "ctx secondsLeft")

		mod:phase(12) -- still active
		assert(#events == afterFirst + 1, "no repeat within active")

		mod:phase(15) -- idle again
		assert(#events == afterFirst + 2, "fires on active -> idle")
		assert(events[#events].phase == "idle", "ctx idle phase")
	end,

	["raid is refused while the siege is idle"] = function()
		local mod = newModule()
		local moved, reason = mod:raid("red", "blue", 1)
		assert(moved == 0, "idle raid moves nothing")
		assert(reason == "siege not active", "refusal reason")
	end,

	["raid is refused when the defender is shielded"] = function()
		local mod = newModule()
		mod:collect("blue", "egg-1", true)

		local moved, reason = mod:raid("red", "blue", 11, true)

		assert(moved == 0, "shielded raid moves nothing")
		assert(reason == "shielded", "refusal reason")
		assert(mod:counts().blue == 1, "defender keeps the item")
	end,

	["raid is refused when attacker and defender are the same team"] = function()
		local mod = newModule()
		mod:collect("red", "egg-1", true)

		local moved, reason = mod:raid("red", "red", 11)

		assert(moved == 0, "same-team raid moves nothing")
		assert(reason == "same team", "refusal reason")
		assert(mod:counts().red == 1, "vault unchanged")
	end,

	["raid moves at most maxTake and fires OnRaid"] = function()
		local raids: { CollectRaid.RaidCtx } = {}
		local mod = newModule({
			OnRaid = function(ctx)
				table.insert(raids, ctx)
			end,
		})
		mod:collect("blue", "a", true)
		mod:collect("blue", "b", true)
		mod:collect("blue", "c", true)

		local moved, reason = mod:raid("red", "blue", 11)

		assert(moved == 2, "moved exactly maxTake")
		assert(reason == nil, "successful raid has no refusal reason")
		assert(mod:counts().red == 2, "attacker gained two")
		assert(mod:counts().blue == 1, "defender kept one")
		assert(#raids == 1, "OnRaid fired once")
		assert(raids[1].attacker == "red", "ctx attacker")
		assert(raids[1].defender == "blue", "ctx defender")
		assert(raids[1].moved == 2, "ctx moved")
	end,

	["raid never moves non-raidable items"] = function()
		local raids: { CollectRaid.RaidCtx } = {}
		local mod = newModule({
			OnRaid = function(ctx)
				table.insert(raids, ctx)
			end,
		})
		mod:collect("blue", "vaulted", false)

		local moved, reason = mod:raid("red", "blue", 11)

		assert(moved == 0, "non-raidable item never moves")
		assert(reason == nil, "raid itself succeeds")
		-- totalCounts sees the locked item too: if a future Vault.raid bug moved it
		-- (or miscounted it as moved), these totals would change even though the
		-- raidable-only counts() below cannot detect that on its own.
		assert(mod:totalCounts().blue == 1, "the locked item stays in the defender's total count")
		assert(mod:totalCounts().red == 0, "attacker's total count gains nothing")
		assert(mod:counts().blue == 0, "no raidable items left on the defender")
		assert(mod:counts().red == 0, "attacker gains nothing")
		assert(#raids == 0, "OnRaid does not fire for a raid that moved nothing")
	end,

	["releaseLocked flips a team's non-raidable items to raidable and leaves raidable ones alone"] = function()
		local mod = newModule()
		mod:collect("blue", "locked-1", false)
		mod:collect("blue", "locked-2", false)
		mod:collect("blue", "already-raidable", true)
		assert(mod:counts().blue == 1, "only the pre-raidable item counts before release")

		local released = mod:releaseLocked("blue")

		assert(released == 2, "reports exactly the two items that were locked")
		assert(mod:counts().blue == 3, "every item in the vault is raidable after release")
		assert(mod:totalCounts().blue == 3, "release never changes the total count")
	end,

	["a lock released when the siege opens does not survive past that window: a raid can take it"] = function()
		-- Reproduces the round-2 M3 finding: Auto Lock deposits non-raidable
		-- "before a siege", but the lock must end when that siege window opens,
		-- not persist forever. Server.luau calls releaseLocked from OnSiegePhase
		-- at the idle -> active edge; this spec exercises the same sequence
		-- directly on CollectRaid so the genre-level contract is pinned even
		-- without the Roblox service wiring in Server.luau.
		local mod = newModule()
		mod:collect("blue", "auto-locked-hatch", false)

		-- Siege becomes active (period 10, duration 4: active during [10, 14)).
		local phase = mod:phase(11)
		assert(phase == "active", "siege window is open")
		mod:releaseLocked("blue")

		local moved, reason = mod:raid("red", "blue", 11)

		assert(moved == 1, "the previously locked hatch is raidable once its siege window opens")
		assert(reason == nil, "raid succeeds")
	end,
}
