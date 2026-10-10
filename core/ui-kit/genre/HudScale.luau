--!strict
-- HudScale: the text-scale contract for every HUD label that scales.
--
-- A `TextScaled` label grows its glyphs to fill the control it lives in. Without
-- a `UITextSizeConstraint` the glyphs grow without a ceiling: a 48px sheet button
-- rendered its whole label at ~48px, so the survival-coop bag sheet's "Refresh
-- supplies" and "Camera controls" buttons were filled edge to edge by their own
-- text. A scaled label must therefore carry a `UITextSizeConstraint` whose
-- `MaxTextSize` caps it at the theme's body size and whose `MinTextSize` keeps it
-- readable; the constraint is what makes the label fit rather than the label
-- being sized by its control.
--
-- Pure Luau and source-level: `core/ui-kit/genre/HudKit` and the shared
-- `core/ui-kit/Components` render the labels, `forge sweep` reads the same
-- sources, so the gate measures the real call sites rather than a copy of them.

local M = {}

-- The theme's own text sizes (`core/ui-kit/Theme.textSizes`): body 15, small 13.
-- A scaled label is capped at the body size so it never renders larger than the
-- HUD's ordinary text, and floored at a size that still reads on a phone.
M.MAX_TEXT_SIZE = 18
M.MIN_TEXT_SIZE = 10

--- True when `source` scales any label's text to its control.
function M.scales(source: string): boolean
	return string.find(source, "TextScaled", 1, true) ~= nil
end

--- True when `source` creates a `UITextSizeConstraint` and caps it: the two
--- pieces a scaled label needs to stop growing at the control's edge.
function M.constrained(source: string): boolean
	return string.find(source, "UITextSizeConstraint", 1, true) ~= nil
		and string.find(source, "MaxTextSize", 1, true) ~= nil
end

--- Strips Luau comments, so a comment that merely mentions `TextScaled` never counts as a scaled
--- label.
local function stripComments(source: string): string
	local text = string.gsub(source, "%-%-%[%[.-%]%]", " ")
	return string.gsub(text, "%-%-[^\n]*", " ")
end

--- The text-scale violations of one module source, labelled with its path. This is STATIC LINT: it
--- proves the module creates a capped `UITextSizeConstraint` (comments do not count), which is what
--- stops a scaled label growing to fill its control. That every *instantiated* label carries its own
--- constraint is measured on the live client instead - the Studio capture walks the owned UI and
--- inspects each scaled label's actual constraint, which source text cannot establish.
function M.violations(source: string, label: string): { string }
	local errors: { string } = {}
	local code = stripComments(source)
	if M.scales(code) and not M.constrained(code) then
		table.insert(
			errors,
			label .. ": scales text with no UITextSizeConstraint MaxTextSize, so a label grows to fill its control"
		)
	end
	return errors
end

--- Every violation across named sources, sorted so the same set always reports
--- the same list.
function M.sourcesViolations(sources: { { label: string, source: string } }): { string }
	local errors: { string } = {}
	for _, entry in sources do
		for _, error in M.violations(entry.source, entry.label) do
			table.insert(errors, error)
		end
	end
	table.sort(errors)
	return errors
end

return M
