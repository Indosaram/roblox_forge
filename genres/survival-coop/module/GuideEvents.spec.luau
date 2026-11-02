--!strict
local Events = require("./GuideEvents")

return {
	["Build sheet settlement placement credits the same place objective as home placement"] = function()
		local facts = {
			settlement = {
				reservations = {
					reserved = { definition = { id = "tanning-frame" } },
				},
			},
		}
		local event = assert(Events.event("settlement-place", { "reserved", 3, 4 }, facts, { ok = true }))
		assert(
			event.action == "place" and event.target == "tanning-frame" and event.quantity == 1,
			"credits placed structure"
		)
		assert(
			Events.event("settlement-place", { "reserved", 3, 4 }, facts, { ok = false }) == nil,
			"refused placement earns no credit"
		)
		assert(
			Events.event("settlement-place", { "unknown", 3, 4 }, facts, { ok = true }) == nil,
			"unknown reservation earns no credit"
		)
	end,
}
