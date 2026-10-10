--!strict
-- Specs for Layout: number formatting across K/M/B, duration formatting across
-- h/m/s, negative clamps, and viewport clamping on both axes.

local Layout = require("./Layout")

return {
	["formatNumber leaves values below 1000 as integers"] = function()
		assert(Layout.formatNumber(0) == "0", "zero")
		assert(Layout.formatNumber(42) == "42", "small")
		assert(Layout.formatNumber(999) == "999", "boundary")
	end,

	["formatNumber appends K for thousands"] = function()
		assert(Layout.formatNumber(1000) == "1K", "exact thousand drops the decimal")
		assert(Layout.formatNumber(1200) == "1.2K", "one decimal")
		assert(Layout.formatNumber(999_000) == "999K", "largest thousand")
	end,

	["formatNumber promotes to the next tier when %.1f would round up to 1000"] = function()
		assert(Layout.formatNumber(999_950) == "1M", "999950 rounds to 1000.0K and must promote to 1M")
		assert(Layout.formatNumber(999_949) == "999.9K", "just below the promotion boundary stays K")
		assert(Layout.formatNumber(999_999_999) == "1B", "999999999 rounds to 1000.0M and must promote to 1B")
	end,

	["formatNumber appends M for millions"] = function()
		assert(Layout.formatNumber(1_000_000) == "1M", "exact million")
		assert(Layout.formatNumber(2_500_000) == "2.5M", "one decimal")
	end,

	["formatNumber appends B for billions"] = function()
		assert(Layout.formatNumber(1_000_000_000) == "1B", "exact billion")
		assert(Layout.formatNumber(3_200_000_000) == "3.2B", "one decimal")
	end,

	["formatNumber keeps the sign for negatives"] = function()
		assert(Layout.formatNumber(-500) == "-500", "small negative")
		assert(Layout.formatNumber(-1200) == "-1.2K", "negative thousand")
		assert(Layout.formatNumber(-2_500_000) == "-2.5M", "negative million")
	end,

	["formatDuration formats hours with padded minutes"] = function()
		assert(Layout.formatDuration(3600) == "1h 00m", "exact hour")
		assert(Layout.formatDuration(3900) == "1h 05m", "pads minutes")
		assert(Layout.formatDuration(7325) == "2h 02m", "truncates seconds")
	end,

	["formatDuration formats minutes with padded seconds"] = function()
		assert(Layout.formatDuration(60) == "1m 00s", "exact minute")
		assert(Layout.formatDuration(185) == "3m 05s", "pads seconds")
	end,

	["formatDuration formats bare seconds"] = function()
		assert(Layout.formatDuration(0) == "0s", "zero")
		assert(Layout.formatDuration(12) == "12s", "seconds")
	end,

	["formatDuration clamps negatives to zero"] = function()
		assert(Layout.formatDuration(-5) == "0s", "negative seconds")
		assert(Layout.formatDuration(-3600) == "0s", "negative hour")
	end,

	["clampToViewport keeps an in-bounds position"] = function()
		local clamped = Layout.clampToViewport({ x = 10, y = 20 }, { x = 100, y = 100 }, { x = 200, y = 200 })
		assert(clamped.x == 10 and clamped.y == 20, "unchanged when inside")
	end,

	["clampToViewport clamps both axes to the far edge"] = function()
		local clamped = Layout.clampToViewport({ x = 500, y = 500 }, { x = 100, y = 100 }, { x = 300, y = 250 })
		assert(clamped.x == 200 and clamped.y == 150, "clamped to viewport minus size")
	end,

	["clampToViewport clamps negative positions to zero"] = function()
		local clamped = Layout.clampToViewport({ x = -40, y = -5 }, { x = 100, y = 100 }, { x = 300, y = 300 })
		assert(clamped.x == 0 and clamped.y == 0, "clamped to origin")
	end,

	["clampToViewport collapses to zero when the box overflows"] = function()
		local clamped = Layout.clampToViewport({ x = 10, y = 10 }, { x = 500, y = 500 }, { x = 300, y = 300 })
		assert(clamped.x == 0 and clamped.y == 0, "no room to move")
	end,

	["rowItemWidth keeps the natural width when the row fits"] = function()
		assert(Layout.rowItemWidth(1256, 2, 150, 8, 44) == 150, "two 150px items fit a desktop bar")
		assert(Layout.rowItemWidth(1256, 3, 150, 8, 44) == 150, "three 150px items fit a desktop bar")
		assert(Layout.rowItemWidth(366.4, 2, 150, 8, 44) == 150, "two items fit a phone-width bar")
	end,

	["rowItemWidth shrinks an overflowing row so it fits"] = function()
		local width = Layout.rowItemWidth(366.4, 3, 150, 8, 44)
		assert(width == 116, "three 150px items shrink to 116 in a 366.4px bar, got " .. tostring(width))
		assert(width * 3 + 8 * 2 <= 366.4, "the shrunk row fits the bar")
	end,

	["rowItemWidth never goes below the touch minimum"] = function()
		assert(Layout.rowItemWidth(100, 4, 150, 8, 44) == 44, "clamped up to the minimum")
		assert(Layout.rowItemWidth(0, 1, 150, 8, 44) == 44, "a zero-width bar still floors at the minimum")
	end,

	["rowItemWidth returns the natural width for an empty row"] = function()
		assert(Layout.rowItemWidth(366.4, 0, 150, 8, 44) == 150, "no items means no fitting")
	end,

	["isPhone is true for a landscape phone viewport"] = function()
		assert(Layout.isPhone({ x = 685, y = 338 }), "Galaxy S25 Ultra landscape is a phone")
		assert(Layout.isPhone({ x = 800, y = 499 }), "just under the breakpoint")
	end,

	["isPhone is false for desktop viewports"] = function()
		assert(not Layout.isPhone({ x = 800, y = 600 }), "a short desktop window is not a phone")
		assert(not Layout.isPhone({ x = 500, y = 500 }), "both breakpoints are exclusive")
		assert(not Layout.isPhone({ x = 1920, y = 1080 }), "desktop is not a phone")
	end,

	["isPhone is true for a portrait phone viewport"] = function()
		-- A portrait phone is narrow and tall: the height-only rule gave it the desktop
		-- column, which laid the objective over the chat window in a live capture.
		assert(Layout.isPhone({ x = 390, y = 844 }), "iPhone 13 portrait is a phone")
		assert(Layout.isPhone({ x = 430, y = 932 }), "iPhone 15 Pro Max portrait is a phone")
	end,

	["uiScaleForViewport never shrinks a 44px control below the touch minimum"] = function()
		assert(Layout.uiScaleForViewport(338) == 1, "phone keeps scale 1")
		assert(Layout.uiScaleForViewport(900) == 1, "baseline is 1")
		assert(Layout.uiScaleForViewport(500) == 1, "short desktop keeps scale 1")
	end,

	["uiScaleForViewport grows on tall displays and clamps"] = function()
		assert(Layout.uiScaleForViewport(1080) == 1.2, "1080 grows to 1.2")
		assert(Layout.uiScaleForViewport(4000) == 1.25, "clamped at 1.25")
	end,

	["sheetSize is at most 80% of the viewport height"] = function()
		local size = Layout.sheetSize({ x = 685, y = 338 })
		assert(size.y == 270, "80% of 338 floored")
		assert(size.y < 338, "fits the viewport")
	end,

	["sheetSize caps width and leaves margins on narrow viewports"] = function()
		local wide = Layout.sheetSize({ x = 1920, y = 1080 })
		assert(wide.x == 560, "width capped at 560")
		local narrow = Layout.sheetSize({ x = 320, y = 480 })
		assert(narrow.x == 296, "narrow width leaves a 24px margin")
	end,

	["sheetSize height respects small viewports"] = function()
		local small = Layout.sheetSize({ x = 200, y = 100 })
		assert(small.y <= 100, "never exceeds the viewport")
	end,
}
