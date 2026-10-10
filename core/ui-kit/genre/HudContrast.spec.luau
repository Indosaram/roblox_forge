--!strict
-- Specs for HudContrast: the WCAG maths and the readability contract the shared
-- HUD theme must satisfy. Pure Luau, no Roblox Studio, no sleeps.

local HudContrast = require("./HudContrast")
local Theme = require("../Theme")

return {
	["contrast is symmetric and spans 1..21"] = function()
		local white = { r = 255, g = 255, b = 255 }
		local black = { r = 0, g = 0, b = 0 }
		assert(math.abs(HudContrast.contrast(white, black) - 21) < 1e-6, "white on black is 21")
		assert(math.abs(HudContrast.contrast(black, white) - 21) < 1e-6, "contrast is symmetric")
		assert(math.abs(HudContrast.contrast(white, white) - 1) < 1e-6, "identical colours are 1")
	end,

	["the default theme keeps every text surface above the AA floor"] = function()
		local errors = HudContrast.violations(Theme.default)
		assert(#errors == 0, table.concat(errors, "; "))
	end,

	["the objective chip reads over a white world"] = function()
		-- The defect this contract exists for: the objective line was near-white
		-- text with no chip, invisible over a light backdrop. The chip surface is
		-- the text colour against the opaque background the kit paints, and it must
		-- clear the floor against the brightest backdrop the world can show.
		local errors = HudContrast.violations(Theme.default)
		for _, error in errors do
			assert(string.find(error, "chip", 1, true) == nil, error)
		end
		local ratio = HudContrast.contrast(Theme.default.colors.text, Theme.default.colors.bg)
		assert(ratio >= HudContrast.MIN_RATIO, "the chip surface must clear the floor, got " .. tostring(ratio))
	end,

	["light text on the accent chip is reported"] = function()
		-- The regression the onAccent colour fixes: near-white text on the bright
		-- accent chip is 2.05:1, far below the floor.
		local broken = Theme.merge(Theme.default, { colors = { onAccent = Theme.default.colors.text } })
		local errors = HudContrast.violations(broken)
		assert(#errors > 0, "light text on the accent chip must be reported")
		local found = false
		for _, error in errors do
			if string.find(error, "accent", 1, true) ~= nil then
				found = true
			end
		end
		assert(found, table.concat(errors, "; "))
	end,

	["a theme whose text is unreadable on every chip reports each one"] = function()
		-- A mid grey close to the dark chips: below the floor on all of them.
		local flat = Theme.merge(Theme.default, {
			colors = {
				text = { r = 120, g = 120, b = 120 },
				onAccent = { r = 120, g = 120, b = 120 },
				muted = { r = 120, g = 120, b = 120 },
			},
		})
		local errors = HudContrast.violations(flat)
		assert(#errors == #HudContrast.surfaces(flat), "every unreadable surface must be reported")
	end,
}
