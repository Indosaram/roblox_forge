--!strict
-- HudContrast: the readability contract for every string the HUD draws.
--
-- A HUD element that carries text must sit on a chip (an opaque background the
-- kit owns) or carry a stroke; text drawn straight onto the world is invisible
-- over a bright backdrop. This module is the one authority that measures that:
-- it names every text surface the shared kit renders, computes the WCAG
-- contrast ratio of the text colour against its own chip, and reports the ones
-- below the AA floor.
--
-- Pure Luau - no Roblox global - so the CLI can load it under Lune and the same
-- numbers gate `forge check` as the ones the HUD renders at runtime.

local M = {}

-- WCAG 2.1 AA for normal-size body text. The HUD's smallest text is 14px, below
-- the 18.66px "large text" cutoff, so the strict floor applies.
M.MIN_RATIO = 4.5

local function channel(value: number): number
	local normalized = math.clamp(value, 0, 255) / 255
	if normalized <= 0.03928 then
		return normalized / 12.92
	end
	return ((normalized + 0.055) / 1.055) ^ 2.4
end

--- Relative luminance of a 0..255 `{ r, g, b }` colour (WCAG 2.1).
function M.relativeLuminance(color: any): number
	return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
end

--- The WCAG contrast ratio of two 0..255 colours, from 1.0 (identical) to 21.0.
function M.contrast(foreground: any, background: any): number
	local a, b = M.relativeLuminance(foreground), M.relativeLuminance(background)
	local lighter, darker = math.max(a, b), math.min(a, b)
	return (lighter + 0.05) / (darker + 0.05)
end

--- Every text surface the shared kit draws, as { id, text, chip }: the colour of
--- the text and the colour of the opaque background behind it. `chip` is the
--- panel/background the kit paints, never the world.
function M.surfaces(theme: any): { any }
	local colors = theme.colors
	return {
		{ id = "chip", text = colors.text, chip = colors.bg },
		{ id = "panel", text = colors.text, chip = colors.panel },
		{ id = "accent", text = colors.onAccent, chip = colors.accent },
		{ id = "bad", text = colors.onAccent, chip = colors.bad },
		{ id = "muted-panel", text = colors.muted, chip = colors.panel },
	}
end

--- Every text surface whose text/chip contrast is below the AA floor. Sorted, so
--- the same theme always reports the same list.
function M.violations(theme: any): { string }
	local errors: { string } = {}
	for _, surface in M.surfaces(theme) do
		local ratio = M.contrast(surface.text, surface.chip)
		if ratio < M.MIN_RATIO then
			table.insert(
				errors,
				string.format("%s: text/chip contrast %.2f is below the %.1f floor", surface.id, ratio, M.MIN_RATIO)
			)
		end
	end
	table.sort(errors)
	return errors
end

return M
