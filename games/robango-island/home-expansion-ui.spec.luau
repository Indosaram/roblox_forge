--!strict
local Panel = require("../../genres/survival-coop/module/IslandRankPanel")
local Sheet = require("../../genres/survival-coop/module/CharacterSheet")
local _text = require("./PackText.fixture")

return {
	["island rank offers expansion with the authoritative home token"] = function()
		local home = { homeId = "home:player", landRank = 1 }
		local data = Sheet.data({ home = home, character = { points = 200 } }, {})
		-- Use the shipped catalog for rank cells and awards.
		data.content = require("./src/shared/SurvivalContent")
		local expand = nil
		for _, row in Panel.model("en-us", data) do
			if row.name == "Expand" then
				expand = row
			end
		end
		assert(expand, "home expansion must have a client affordance")
		local sent = false
		Sheet.activate("en-us", expand, function(action, args)
			assert(action == "survival-coop:home-expand", "expansion command")
			assert(args[1] == home.homeId and next(args[2]) == nil, "authoritative token and empty body")
			sent = true
			return { ok = true }
		end)
		assert(sent, "enabled expansion sends its command")
		home.landRank = 2
		for _, row in Panel.model("en-us", data) do
			if row.name == "Expand" then
				assert(row.enabled == false, "current land rank cannot expand again")
				Sheet.activate("en-us", row, function()
					error("disabled expansion sent a command")
				end)
			end
		end
	end,
}
