--!strict
-- HudFit: the text-fit contract for the HUD's action controls.
--
-- A control that shrinks to fit a narrow phone keeps its touch size but loses its
-- label: a live 390x844 capture of the rpg-progression HUD showed "Strike slime",
-- "Strike golem" and "Claim reward" running past three 110px buttons and over each
-- other. The fix is structural, so the measurement is too:
--
--   * `textWidth` estimates the advance width of a label at a text size, over-
--     estimating so a label that passes renders with room to spare.
--   * `plan` packs the labels into at most `MAX_ROWS` rows of the width the phone
--     action bar actually has, growing each control to the widest label it must
--     hold and shrinking only when even the packed layout cannot.
--   * `violations` is the same computation as a gate: it reports every label whose
--     estimate does not fit the control the layout gives it.
--
-- Pure Luau - no Roblox global - so HudKit lays the row out with it at runtime and
-- `forge sweep` measures the same numbers offline.

local M = {}

-- The phone the action bar is designed against. `forge sweep` gates this surface,
-- and HudKit lays the phone row out from the same numbers, so the two can never
-- disagree about how much room the controls have.
M.PHONE_VIEWPORT = { x = 390, y = 844 }
-- Left margin the action row keeps, the touch jump button's reserved footprint,
-- the gap before it, and the gap between controls.
M.BAR_MARGIN = 8
M.JUMP_RESERVE = 90
M.JUMP_GAP = 12
M.GAP = 8
-- The natural control size, the width it may shrink to before it stops being a
-- touch target, and its height.
M.NATURAL_WIDTH = 150
M.MIN_WIDTH = 44
M.ACTION_HEIGHT = 44
-- Horizontal room a control keeps around its label, and the text size labels are
-- drawn at.
M.PADDING = 10
M.TEXT_SIZE = 15
-- The smallest text size the kit renders a label at. Below this a label stops
-- being readable, so the layout wraps the bar instead of scaling further.
M.MIN_TEXT_SIZE = 11
-- Two rows is the most a phone action bar may grow to before the labels, not the
-- layout, are the problem: a pack with more controls than that needs fewer actions
-- on the bar rather than a third row over the avatar.
M.MAX_ROWS = 2

local function isWide(code: number): boolean
	return code >= 0x1100
		and (
			code <= 0x115F
			or (code >= 0x2E80 and code <= 0xA4CF)
			or (code >= 0xAC00 and code <= 0xD7A3)
			or (code >= 0xF900 and code <= 0xFAFF)
			or (code >= 0xFE30 and code <= 0xFE6F)
			or (code >= 0xFF00 and code <= 0xFF60)
			or (code >= 0xFFE0 and code <= 0xFFE6)
		)
end

--- The estimated advance width of `text` at `textSize`, in pixels. Latin letters
--- take about 0.6em, CJK and Hangul a full em, spaces and punctuation less.
function M.textWidth(text: string, textSize: number): number
	local width = 0
	for _, code in utf8.codes(text) do
		if isWide(code) then
			width += textSize
		elseif code == 32 then
			width += textSize * 0.3
		elseif (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) then
			width += textSize * 0.62
		else
			width += textSize * 0.35
		end
	end
	return width
end

--- The width a control needs to hold `text` with its padding.
function M.requiredWidth(text: string, textSize: number?): number
	return math.ceil(M.textWidth(text, textSize or M.TEXT_SIZE) + M.PADDING * 2)
end

export type Layout = {
	rows: number,
	perRow: number,
	itemWidth: number,
	needed: number,
	labels: { string },
}

--- Packs `labels` into the room `available` gives: at most `maxRows` rows, each
--- control at least as wide as the widest label it holds, and never wider than
--- `natural`. A row that already fits keeps its natural width.
function M.plan(
	labels: { string },
	available: number,
	gap: number?,
	natural: number?,
	minimum: number?,
	maxRows: number?
): Layout
	local space = gap or M.GAP
	local itemNatural = natural or M.NATURAL_WIDTH
	local itemMinimum = minimum or M.MIN_WIDTH
	local rowLimit = maxRows or M.MAX_ROWS
	local count = #labels
	local needed = itemMinimum
	for _, label in labels do
		needed = math.max(needed, math.min(itemNatural, M.requiredWidth(label)))
	end
	if count == 0 then
		return { rows = 0, perRow = 0, itemWidth = itemNatural, needed = 0, labels = labels }
	end
	local perRow = math.min(count, math.max(1, math.floor((available + space) / (needed + space))))
	local rows = math.ceil(count / perRow)
	if rows > rowLimit then
		perRow = math.ceil(count / rowLimit)
		rows = rowLimit
	end
	local itemWidth = math.min(itemNatural, math.floor((available - space * (perRow - 1)) / perRow))
	return { rows = rows, perRow = perRow, itemWidth = itemWidth, needed = needed, labels = labels }
end

--- Every label the layout cannot hold, plus the row-count overflow. Sorted, so the
--- same control list always reports the same list.
function M.violations(
	labels: { string },
	available: number,
	gap: number?,
	natural: number?,
	minimum: number?,
	maxRows: number?
): { string }
	local layout = M.plan(labels, available, gap, natural, minimum, maxRows)
	local errors: { string } = {}
	for _, label in labels do
		local required = M.requiredWidth(label)
		if required > layout.itemWidth then
			table.insert(
				errors,
				string.format("%q needs %dpx, its control is %dpx wide", label, required, layout.itemWidth)
			)
		end
	end
	if layout.rows > (maxRows or M.MAX_ROWS) then
		table.insert(
			errors,
			string.format("controls need %d rows, the bar allows %d", layout.rows, maxRows or M.MAX_ROWS)
		)
	end
	table.sort(errors)
	return errors
end

--- The width the phone action bar has, from the reserved jump-button footprint.
function M.phoneRoom(viewport: any): number
	local width = tonumber(viewport.x) or M.PHONE_VIEWPORT.x
	return math.max(M.MIN_WIDTH, width - M.BAR_MARGIN - M.JUMP_RESERVE - M.JUMP_GAP)
end

--- The gate: every action label a spec declares must fit the phone action bar the
--- layout gives it, measured at the same 390x844 surface the visual captures use.
function M.surfaceViolations(labels: { string }, viewport: any?): { string }
	local resolved = viewport or M.PHONE_VIEWPORT
	return M.violations(labels, M.phoneRoom(resolved))
end

return M
