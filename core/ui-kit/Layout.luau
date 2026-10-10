--!strict
-- Layout: pure, engine-free formatting and placement helpers for the shared UI
-- kit. Numbers are plain values and positions are plain { x, y } tables so the
-- module loads and is testable under Lune.

export type Vec2 = { x: number, y: number }

local Layout = {}

local function stripTrailingZero(text: string): string
	if string.sub(text, -2) == ".0" then
		return string.sub(text, 1, -3)
	end
	return text
end

local function scaled(value: number, divisor: number, suffix: string): string
	if value < 0 then
		return "-" .. stripTrailingZero(string.format("%.1f", -value / divisor)) .. suffix
	end
	return stripTrailingZero(string.format("%.1f", value / divisor)) .. suffix
end

--- Formats a count with a K/M/B suffix. Values below 1000 are integer strings.
function Layout.formatNumber(n: number): string
	local magnitude = math.abs(n)
	-- A magnitude that rounds up to "1000" of the current unit at %.1f
	-- precision (e.g. 999950, which is 999.95K) must promote to the next
	-- tier instead of printing "1000K". 999.95 * divisor is the smallest
	-- value that rounds up to 1000.0 at one decimal place.
	if magnitude < 1000 then
		return string.format("%d", n)
	elseif magnitude < 999_950 then
		return scaled(n, 1000, "K")
	elseif magnitude < 999_950_000 then
		return scaled(n, 1_000_000, "M")
	else
		return scaled(n, 1_000_000_000, "B")
	end
end

--- Formats a whole number of seconds as "1h 02m", "3m 05s", or "12s".
--- Negative input clamps to "0s".
function Layout.formatDuration(seconds: number): string
	if seconds < 0 or seconds ~= seconds then
		return "0s"
	end
	local total = math.floor(seconds)
	if total >= 3600 then
		local hours = math.floor(total / 3600)
		local minutes = math.floor((total % 3600) / 60)
		return string.format("%dh %02dm", hours, minutes)
	elseif total >= 60 then
		local minutes = math.floor(total / 60)
		return string.format("%dm %02ds", minutes, total % 60)
	else
		return string.format("%ds", total)
	end
end

local function clampAxis(position: number, extent: number, viewport: number): number
	local maxPosition = viewport - extent
	if maxPosition < 0 then
		maxPosition = 0
	end
	if position < 0 then
		return 0
	elseif position > maxPosition then
		return maxPosition
	end
	return position
end

--- Clamps a top-left position so a `size` box stays inside a `viewport`,
--- keeping each axis within [0, viewport - size].
function Layout.clampToViewport(pos: Vec2, size: Vec2, viewport: Vec2): Vec2
	return {
		x = clampAxis(pos.x, size.x, viewport.x),
		y = clampAxis(pos.y, size.y, viewport.y),
	}
end

--- Roblox's minimum comfortable touch target (absolute pixels).
Layout.MIN_TOUCH_TARGET = 44

--- Viewports shorter than this use the compact phone HUD (landscape phones).
Layout.PHONE_HEIGHT = 500

--- Viewports narrower than this use the compact phone HUD (portrait phones). A phone
--- held upright is 390..430 wide with a viewport far taller than `PHONE_HEIGHT`, so a
--- height-only rule gave a portrait phone the desktop column: a live 390x844 capture
--- then laid the objective over the chat window.
Layout.PHONE_WIDTH = 500

--- True when the viewport is phone-sized: too short for the desktop column (a phone in
--- landscape) or too narrow for it (a phone in portrait). Checked against the viewport
--- itself so Studio's device simulator matches a real phone.
function Layout.isPhone(viewport: Vec2): boolean
	return viewport.y < Layout.PHONE_HEIGHT or viewport.x < Layout.PHONE_WIDTH
end

--- UIScale factor for a viewport height. Scales the HUD up on tall displays but
--- never below 1, so a 44px design control keeps an AbsoluteSize of at least
--- `MIN_TOUCH_TARGET` and stays tappable.
function Layout.uiScaleForViewport(height: number): number
	return math.clamp(height / 900, 1, 1.25)
end

--- The width each item of a single row takes so `count` items plus the gaps
--- between them fit inside `available`. A row that already fits keeps its
--- natural `itemWidth`; an overflowing row shrinks, but never below `minimum`,
--- which is the touch-target floor and therefore a hard lower bound.
function Layout.rowItemWidth(available: number, count: number, itemWidth: number, gap: number, minimum: number): number
	if count <= 0 then
		return itemWidth
	end
	local fit = (available - gap * (count - 1)) / count
	return math.clamp(math.floor(fit), minimum, itemWidth)
end

--- Size of a centered modal sheet for `viewport`: at most 80% of the viewport
--- height and no wider than 560px, leaving a 24px horizontal margin.
function Layout.sheetSize(viewport: Vec2): Vec2
	local width = math.min(560, math.max(0, math.floor(viewport.x - 24)))
	local height = math.floor(viewport.y * 0.8)
	height = math.clamp(height, 0, math.max(0, math.floor(viewport.y - 24)))
	return { x = width, y = height }
end

return Layout
