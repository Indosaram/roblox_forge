--!strict
-- Specs for Theme: default shape and pure deep-merge behavior.

local Theme = require("./Theme")

return {
	["default theme carries every color key"] = function()
		for _, key in { "bg", "panel", "accent", "text", "onAccent", "muted", "good", "bad" } do
			local color = (Theme.default.colors :: any)[key]
			assert(type(color) == "table", "missing color " .. key)
			assert(type(color.r) == "number" and type(color.g) == "number" and type(color.b) == "number", key)
		end
	end,

	["merge overrides one nested color only"] = function()
		local merged = Theme.merge(Theme.default, { colors = { accent = { r = 1, g = 2, b = 3 } } })
		assert(merged.colors.accent.r == 1 and merged.colors.accent.g == 2 and merged.colors.accent.b == 3, "override")
		assert(merged.colors.bg.r == Theme.default.colors.bg.r, "sibling bg kept")
		assert(merged.colors.bad.b == Theme.default.colors.bad.b, "sibling bad kept")
	end,

	["merge does not mutate the base"] = function()
		local merged = Theme.merge(Theme.default, { colors = { text = { r = 9, g = 9, b = 9 } }, corner = 99 })
		assert(merged.colors.text.r == 9, "merged value")
		assert(Theme.default.colors.text.r ~= 9, "base text untouched")
		assert(Theme.default.corner ~= 99, "base corner untouched")
	end,

	["merge with empty overrides equals base values"] = function()
		local merged = Theme.merge(Theme.default, {})
		assert(merged.font == Theme.default.font, "font")
		assert(merged.corner == Theme.default.corner, "corner")
		assert(merged.padding == Theme.default.padding, "padding")
		assert(merged.colors.panel.g == Theme.default.colors.panel.g, "panel")
		assert(merged.textSizes.small == Theme.default.textSizes.small, "small")
	end,
}
