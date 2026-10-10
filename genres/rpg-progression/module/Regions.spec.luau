--!strict
-- Specs for Regions: level thresholds, ordered listings, and force unlocks.

local Regions = require("./Regions")

local function newRegions(): Regions.Regions
	return Regions.new({
		{ id = "plains", name = "Plains", requiredLevel = 1 },
		{ id = "desert", name = "Desert", requiredLevel = 5 },
		{ id = "volcano", name = "Volcano", requiredLevel = 10 },
	})
end

local function expectError(fn: () -> (), message: string): ()
	local ok = pcall(fn)
	assert(not ok, "expected error: " .. message)
end

return {
	["unlocks by level threshold"] = function()
		local regions = newRegions()
		assert(Regions.isUnlocked(regions, "plains", 1), "level 1 opens plains")
		assert(not Regions.isUnlocked(regions, "desert", 4), "level 4 is below desert")
		assert(Regions.isUnlocked(regions, "desert", 5), "level 5 opens desert")
		assert(not Regions.isUnlocked(regions, "volcano", 9), "level 9 is below volcano")
		assert(Regions.isUnlocked(regions, "volcano", 10), "level 10 opens volcano")
	end,

	["unlockedIds lists open regions in definition order"] = function()
		local regions = newRegions()
		local ids = Regions.unlockedIds(regions, 5)
		assert(#ids == 2, "two regions open at level 5")
		assert(ids[1] == "plains" and ids[2] == "desert", "definition order")
		assert(#Regions.unlockedIds(regions, 0) == 0, "level 0 opens nothing")
	end,

	["force unlock bypasses the level threshold"] = function()
		local regions = newRegions()
		assert(not Regions.isUnlocked(regions, "volcano", 1), "locked before the unlock")
		Regions.unlock(regions, "volcano")
		assert(Regions.isUnlocked(regions, "volcano", 1), "open regardless of level")
		assert(Regions.requiredLevel(regions, "volcano") == 10, "the threshold is unchanged")
	end,

	["unknown regions and bad definitions error"] = function()
		expectError(function()
			Regions.isUnlocked(newRegions(), "missing", 1)
		end, "unknown region")
		expectError(function()
			Regions.new({
				{ id = "a", name = "A", requiredLevel = 1 },
				{ id = "a", name = "Again", requiredLevel = 2 },
			})
		end, "duplicate id")
		expectError(function()
			Regions.new({ { id = "a", name = "A", requiredLevel = 0 } })
		end, "required level must be at least 1")
	end,
}
