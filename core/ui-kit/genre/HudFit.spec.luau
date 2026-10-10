--!strict
-- Specs for the HUD text-fit contract: the estimate, the packed layout and the
-- gate that fails a label no control can hold. Pure arithmetic, no engine.

local HudFit = require("./HudFit")

return {
	["the phone action bar has the room left of the jump footprint"] = function()
		assert(HudFit.phoneRoom(HudFit.PHONE_VIEWPORT) == 280, "390 - 8 margin - 90 jump - 12 gap")
	end,

	["a label set too wide for one row wraps instead of overflowing"] = function()
		-- The rpg-progression HUD: three long labels on one row were 110px each and
		-- their text ran past the buttons and over each other.
		local labels = { "Strike slime", "Strike golem", "Claim reward" }
		local layout = HudFit.plan(labels, HudFit.phoneRoom(HudFit.PHONE_VIEWPORT))
		assert(layout.rows == 2 and layout.perRow == 2, "three labels pack into two rows of two")
		assert(layout.itemWidth >= HudFit.requiredWidth("Strike slime"), "a control holds its own label")
		assert(
			#HudFit.surfaceViolations(labels) == 0,
			"the packed row fits: " .. table.concat(HudFit.surfaceViolations(labels), "; ")
		)
	end,

	["a label no control can hold is reported"] = function()
		local errors = HudFit.surfaceViolations({ "Strike slime", "Claim every single reward in this world" })
		assert(#errors == 1, "exactly the overflowing label is reported: " .. table.concat(errors, "; "))
		assert(string.find(errors[1], "Claim every single reward in this world", 1, true) ~= nil, "the label is named")
	end,

	["a row wider than the bar wraps before it shrinks a control below its label"] = function()
		local labels = { "Harvest", "Sell crop", "Buy seed", "Plant seed" }
		local layout = HudFit.plan(labels, HudFit.phoneRoom(HudFit.PHONE_VIEWPORT))
		assert(layout.rows == 2, "four labels take two rows")
		assert(layout.itemWidth >= layout.needed, "the control holds the widest label it carries")
	end,

	["Hangul and CJK are estimated wider than Latin"] = function()
		assert(HudFit.textWidth("증가", 15) == 30, "two Hangul glyphs take two ems")
		assert(HudFit.textWidth("ab", 15) < HudFit.textWidth("증가", 15), "Latin is narrower than Hangul")
		assert(HudFit.textWidth("", 15) == 0, "an empty label needs no room")
	end,

	["a short label keeps its natural control width"] = function()
		local layout = HudFit.plan({ "Menu" }, HudFit.phoneRoom(HudFit.PHONE_VIEWPORT))
		assert(layout.rows == 1 and layout.itemWidth == HudFit.NATURAL_WIDTH, "one short control is natural size")
	end,
}
