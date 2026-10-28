--!strict
-- Theme: pure, engine-free theme table and deep-merge for the shared UI kit.
-- Colors are plain { r, g, b } numbers so the module loads and is testable under
-- Lune; Components converts them to Color3 for Roblox instances.

export type Color = { r: number, g: number, b: number }

export type Colors = {
	bg: Color,
	panel: Color,
	accent: Color,
	text: Color,
	-- Text drawn on a bright, saturated chip (the accent button, the modal-sheet
	-- header, the bad close button). `text` is near-white and washes out on those
	-- (white on the orange accent is 2.05:1); this dark ink clears WCAG AA on every
	-- chip the kit draws. See core/ui-kit/genre/HudContrast.
	onAccent: Color,
	muted: Color,
	good: Color,
	bad: Color,
}

export type TextSizes = {
	title: number,
	body: number,
	small: number,
}

export type Theme = {
	font: string,
	colors: Colors,
	corner: number,
	padding: number,
	textSizes: TextSizes,
}

local Theme = {}

Theme.default = {
	font = "GothamBold",
	colors = {
		bg = { r = 18, g = 20, b = 28 },
		panel = { r = 32, g = 36, b = 48 },
		accent = { r = 255, g = 140, b = 40 },
		text = { r = 240, g = 240, b = 245 },
		onAccent = { r = 24, g = 16, b = 8 },
		muted = { r = 150, g = 155, b = 170 },
		good = { r = 80, g = 200, b = 120 },
		bad = { r = 230, g = 80, b = 80 },
	},
	corner = 8,
	padding = 8,
	textSizes = { title = 24, body = 18, small = 14 },
} :: Theme

-- Panel shell tokens ("sheet shell"): the one look every docked side sheet shares. Our own shape
-- language: a warm parchment body framed in a wood rim, a leather header with icon + title + round
-- close, ink text left-aligned in rows, sea-glass buttons. Text sizes scale with the safe height H
-- of the sheet's ScreenGui ({ floor, cap } px, floor at H = 360) and never drop under 14 px.
Theme.sheet = table.freeze({
	colors = table.freeze({
		body = { r = 236, g = 226, b = 203 },
		rim = { r = 122, g = 92, b = 62 },
		header = { r = 74, g = 52, b = 36 },
		headerText = { r = 246, g = 238, b = 220 },
		ink = { r = 38, g = 30, b = 24 },
		inkMuted = { r = 92, g = 76, b = 60 },
		chip = { r = 222, g = 208, b = 178 },
		marker = { r = 58, g = 128, b = 118 },
		button = { r = 58, g = 96, b = 88 },
		buttonText = { r = 246, g = 238, b = 220 },
		disabled = { r = 196, g = 186, b = 166 },
		disabledText = { r = 70, g = 58, b = 46 },
		close = { r = 176, g = 72, b = 52 },
	}),
	text = table.freeze({ title = { 18, 22 }, body = { 14, 16 }, small = { 14, 14 } }),
	minText = 14,
	space = table.freeze({ pad = 12, gap = 8, header = 44, close = 44, icon = 30, row = 44, marker = 8, corner = 10 }),
})

--- Shell text size in px for `style` (title, body, small) in a gui `safeHeight` px tall.
function Theme.sheetText(style: string, safeHeight: number): number
	local row = Theme.sheet.text[style] or Theme.sheet.text.body
	return math.max(Theme.sheet.minText, math.clamp(math.floor(row[1] * safeHeight / 360 + 0.5), row[1], row[2]))
end

local function deepMerge(base: any, overrides: any): any
	if type(base) ~= "table" or type(overrides) ~= "table" then
		return overrides
	end
	local result: any = table.clone(base)
	for key, value in overrides do
		local current = result[key]
		if type(current) == "table" and type(value) == "table" then
			result[key] = deepMerge(current, value)
		else
			result[key] = value
		end
	end
	return result
end

--- Returns a new theme with `overrides` deep-merged over `base`. Neither table
--- is mutated, so callers can safely share `Theme.default`.
function Theme.merge(base: Theme, overrides: { [string]: any }): Theme
	return deepMerge(base, overrides) :: Theme
end

return Theme
