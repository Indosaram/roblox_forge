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
