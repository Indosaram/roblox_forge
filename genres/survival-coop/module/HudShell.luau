--!strict
-- HUD shell (Robango plan A4: G4, G5, G6), laid out per .omo/plans/robango-durango-specs/ui-spec.md
-- ("Tideglass"). Engine-free: every rect is in the space of a CoreUISafeInsets ScreenGui of
-- `width` x `height`; `topClear` is how far the Roblox top bar reaches into that space. Regions are
-- placed in H-units (fractions of the safe height H = height - topClear) from their anchor edge,
-- so a region keeps its distance from its corner on 16:9 and 20:9 alike (spec section 5).
local M = {}

export type Rect = { x: number, y: number, width: number, height: number }

local function hex(value: number): { r: number, g: number, b: number }
	return table.freeze({ r = value // 65536, g = (value // 256) % 256, b = value % 256 })
end

-- Spec section 1. Never put bone text on teal or coral (contrast); glyphs there are ink.
M.PALETTE = table.freeze({
	tealDeep = hex(0x1F4E4C),
	panel = hex(0x163735),
	teal = hex(0x5FA8A0),
	tealPale = hex(0xA9D3CC),
	drift = hex(0x8A7560),
	driftDark = hex(0x4A3D31),
	driftPale = hex(0xB9A58C),
	bone = hex(0xEDE6D6),
	boneShade = hex(0xCFC4AD),
	ink = hex(0x1B2224),
	coral = hex(0xD9674E),
	ochre = hex(0xC99A3B),
	moss = hex(0x7FA35B),
	lilac = hex(0x9A8FB5),
	slateLock = hex(0x6E7477),
})

-- Type scale (spec section 2): pt at 1 pt = H/360, capped at the PC px value.
M.TYPE = table.freeze({
	display = { 28, 40 },
	title = { 20, 30 },
	heading = { 16, 24 },
	body = { 14, 20 },
	label = { 12, 18 },
	caption = { 10, 15 },
	micro = { 9, 13 },
})
function M.textSize(style: string, safeHeight: number): number
	local row = M.TYPE[style]
	return math.min(math.floor(row[1] * safeHeight / 360 + 0.5), row[2])
end

-- Pebble token (spec section 3): a 100 x 92 squircle-egg, drift rim 6 units, glyph 52 units.
M.PEBBLE = table.freeze({ aspect = 0.92, rim = 0.06, corner = 0.36 })
M.TOKEN = table.freeze({ L = { 72, 64 }, M = { 56, 52 }, S = { 40, 36 } })
M.MIN_TOUCH = 44
--- Token edge in px: spec pt on the phone (never under the 44 px touch minimum), capped at the
--- spec's PC px on a pointer screen.
function M.tokenSize(size: string, safeHeight: number, touch: boolean): number
	local row = M.TOKEN[size]
	local px = math.floor(row[1] * safeHeight / 360 + 0.5)
	-- HUD polish: every target is at least MIN_TOUCH on PC too (the spec's 36 px S token was small).
	return if touch then math.max(M.MIN_TOUCH, px) else math.max(M.MIN_TOUCH, math.min(px, row[2]))
end

M.LABEL_RADIUS = 40
M.LABEL_LIMIT = 24
-- Gather node labels are capped apart from the total, nearest first (a node field must not take
-- every pooled board from NPCs and creatures, and a phone draws at most this many node boards).
M.NODE_LABEL_LIMIT = 8
-- World label board (L10b). Depth-tested: an AlwaysOnTop BillboardGui never drew on the Studio
-- client (same adornee, size and parent drew once AlwaysOnTop was false), so the pooled labels were
-- enabled and sized yet invisible. The board rides `clear` studs over the anchor's tallest child
-- (a node's mesh) so the depth test never hides it inside the node it names.
M.LABEL_BOARD = table.freeze({ width = 220, height = 40, name = 16, hint = 12, clear = 1.2, base = 3 })
-- Which labels show is decided from the character (labelTargets: LABEL_RADIUS, nearest first, node
-- cap), so the board itself never cuts on distance. BillboardGui.MaxDistance is measured from the
-- camera, and a 48-stud cap hid every label behind a 50-60 stud play camera (studio-after defect 1).
M.LABEL_DRAW_DISTANCE = math.huge
M.MAP_WINDOW = 160

-- Tide arc slots (spec section 3): { radius in H, angle in degrees from the right edge, size }.
M.SLOTS = table.freeze({
	P = { 0.17, 45, "L" } :: { any },
	I1 = { 0.30, 10, "M" } :: { any },
	I2 = { 0.30, 45, "M" } :: { any },
	I3 = { 0.30, 80, "M" } :: { any },
	O1 = { 0.42, 20, "M" } :: { any },
	O2 = { 0.42, 70, "M" } :: { any },
	X = { 0.42, 45, "S" } :: { any },
})
M.SLOT_ORDER = table.freeze({ "P", "I1", "I2", "I3", "O1", "O2", "X" })
M.ARC_GAP = 2
-- Touch screens keep tokens this fraction of the safe height off the bottom and side edges: on the
-- phone the arc hugged the edge and the 회피 token's rim ran past the rounded screen corner (v25).
M.EDGE = 0.03
-- Compact vitals (HUD polish, Durango R05-1 / R08-1): a level badge, then three slim rows of
-- icon + bar + number, no stat words. Rows are VITALS_ROW px (clamped from 0.05H), the panel
-- 3 rows + 8 px tall; the width keeps a bar track of at least 90 px (narrower collapsed the bars to
-- dots on the phone, staging v26).
M.VITALS_ROW = table.freeze({ 16, 22 })
M.VITALS_MIN_HEIGHT = 3 * 16 + 8
M.VITALS_MIN_WIDTH = 210
M.VITALS_MAX_WIDTH = 300
-- Item hotbar (bottom centre, Durango-style slots): at most this many backpack tools.
M.HOTBAR_SLOTS = 6
M.HOTBAR_GAP = 6
-- The framed tray behind the slots reaches this far past them (iconfix capture: bare slot numbers
-- floated over the ground with no visible frame).
M.HOTBAR_TRAY_PAD = 4
-- Contextual banners (hunger hint, notices, skill level-up) are this many H tall (two lines).
M.BANNER_HEIGHT = 0.10
-- The primary token keeps its L size on touch screens (only the other tokens shrink to the 44 px
-- floor), so the contextual action reads as the big button (Durango R08-1).
M.PRIMARY_MIN = 52

local function rect(x: number, y: number, width: number, height: number): Rect
	return {
		x = math.floor(x + 0.5),
		y = math.floor(y + 0.5),
		width = math.floor(width + 0.5),
		height = math.floor(height + 0.5),
	}
end

--- Local px the top bar reaches into a gui whose top edge sits at `guiTop` (GuiService.TopbarInset.Max.Y).
function M.topClear(topbarBottom: number, guiTop: number): number
	return math.max(0, topbarBottom - guiTop)
end

local function hits(a: Rect, b: Rect, gap: number): boolean
	return a.x < b.x + b.width + gap
		and b.x < a.x + a.width + gap
		and a.y < b.y + b.height + gap
		and b.y < a.y + a.height + gap
end

--- Tide arc token rects by slot. On a short phone safe height the spec's token pt sizes overlap
--- on the spec radii (H=353: L 71 px, M 55 px), so first the tokens shrink toward the 44 px touch
--- floor, and only if that is not enough every radius grows by the smallest 2% step that parts them.
function M.cluster(width: number, height: number, topClear: number?, touch: boolean?): ({ [string]: Rect }, number)
	local top = topClear or 0
	local h = height - top
	local function place(k: number, shrink: number): ({ [string]: Rect }, boolean)
		local out: { [string]: Rect } = {}
		for _, slot in M.SLOT_ORDER do
			local spec = M.SLOTS[slot]
			local size = M.tokenSize(spec[3], h, touch == true)
			if touch and slot == "P" then
				size = math.max(M.PRIMARY_MIN, math.floor(size * shrink + 0.5))
			elseif touch then
				size = math.max(M.MIN_TOUCH, math.floor(size * shrink + 0.5))
			end
			local radius, angle = spec[1] * k * h, math.rad(spec[2])
			local edge = if touch then M.EDGE * h else 0
			local cx, cy = width - edge - radius * math.cos(angle), top + h - edge - radius * math.sin(angle)
			local tall = size
			if touch then
				tall = math.max(M.MIN_TOUCH, tall)
			end
			-- Keep the whole token inside the safe corner (10 and 80 degree slots sit near the edges).
			cx = math.min(cx, width - edge - size / 2 - M.ARC_GAP)
			cy = math.min(cy, top + h - edge - tall / 2 - M.ARC_GAP)
			out[slot] = rect(cx - size / 2, cy - tall / 2, size, tall)
		end
		for i, a in M.SLOT_ORDER do
			for j = i + 1, #M.SLOT_ORDER do
				-- Hit area is the token's bounding circle (spec section 3).
				local p, q = out[a], out[M.SLOT_ORDER[j]]
				local dx = (p.x + p.width / 2) - (q.x + q.width / 2)
				local dy = (p.y + p.height / 2) - (q.y + q.height / 2)
				local reach = (math.max(p.width, p.height) + math.max(q.width, q.height)) / 2 + M.ARC_GAP
				if dx * dx + dy * dy < reach * reach then
					return out, false
				end
			end
		end
		return out, true
	end
	local shrink = 1
	while shrink >= 0.6 do
		local out, clear = place(1, shrink)
		if clear then
			return out, 1
		end
		shrink -= 0.05
	end
	local k = 1.02
	while true do
		local out, clear = place(k, 0.6)
		if clear or k >= 2 then
			return out, k
		end
		k += 0.02
	end
end

local function bounds(rects: { [any]: Rect }): Rect
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, r in rects do
		x0, y0 = math.min(x0, r.x), math.min(y0, r.y)
		x1, y1 = math.max(x1, r.x + r.width), math.max(y1, r.y + r.height)
	end
	return { x = x0, y = y0, width = x1 - x0, height = y1 - y0 }
end

--- Every HUD region (spec section 5). `rowSlots` are the bottom-left menu, emote and chat tokens.
function M.regions(width: number, height: number, topClear: number?, touch: boolean?): any
	local top = topClear or 0
	local h = height - top
	local function tr(x0: number, x1: number, y0: number, y1: number): Rect
		return rect(width - x1 * h, top + y0 * h, (x1 - x0) * h, (y1 - y0) * h)
	end
	local function tc(x0: number, x1: number, y0: number, y1: number): Rect
		return rect(width / 2 + x0 * h, top + y0 * h, (x1 - x0) * h, (y1 - y0) * h)
	end
	-- The vitals panel holds three bar rows (SurvivalHUDModel.VITALS: 24 px steps, 26 px rows), so it
	-- never gets shorter than VITALS_MIN_HEIGHT; chips and tracker stack under it. On a phone the
	-- spec's 0.12H panel is 42 px and the rows spilled out of it over the coin chip (staging v25).
	local vitalsRow = math.clamp(math.floor(0.05 * h + 0.5), M.VITALS_ROW[1], M.VITALS_ROW[2])
	local vitals =
		rect(0.02 * h, top + 0.02 * h, math.clamp(0.56 * h, M.VITALS_MIN_WIDTH, M.VITALS_MAX_WIDTH), 3 * vitalsRow + 8)
	-- Currency chip under the vitals: a slim pill (icon + amount), not a loose line of text.
	local chips =
		rect(vitals.x, vitals.y + vitals.height + 0.015 * h, math.clamp(0.25 * h, 96, 140), math.max(24, 0.07 * h))
	local tracker = rect(vitals.x, chips.y + chips.height + 0.015 * h, 0.40 * h, 0.16 * h)
	local minimap = tr(0.03, 0.25, 0.02, 0.24)
	local coords = tr(0.05, 0.23, 0.245, 0.285)
	local status = tc(-0.4, 0.4, 0.16, 0.26)
	local clearX = vitals.x + vitals.width + 0.02 * h
	if status.x < clearX then
		-- Narrow screens: the banner starts right of the widened vitals panel.
		local right = status.x + status.width
		status.x, status.width = math.floor(clearX + 0.5), math.max(0, right - math.floor(clearX + 0.5))
	end
	local quest = tr(0.03, 0.52, 0.30, 0.42)
	-- A wide touch screen has room left of the minimap: the quest card sits there at the minimap's
	-- height (about five lines) instead of between the minimap and the action cluster, where its
	-- wrapped text ran into the top token on the phone (staging v25).
	local side = rect(minimap.x - 0.02 * h - 0.48 * h, minimap.y, 0.48 * h, minimap.height)
	if touch and side.x >= status.x + status.width + 0.02 * h then
		quest = side
	elseif touch then
		-- Under the minimap: wider than the spec card so a compact two-line objective fits beside
		-- the collapse toggle.
		quest = tr(0.03, 0.66, 0.30, 0.42)
	end
	-- Bottom-left row: S tokens bottom-aligned at 0.98H, starting 0.02H from the left edge.
	local size = M.tokenSize("S", h, touch == true)
	local gap = math.max(8, 0.03 * h)
	local rowSlots = {}
	local edge = if touch then M.EDGE * h else 0
	for index = 1, 3 do
		rowSlots[index] = rect(0.02 * h + edge + (index - 1) * (size + gap), top + 0.98 * h - size - edge, size, size)
	end
	local tokens, k = M.cluster(width, height, top, touch)
	local cluster = bounds(tokens)
	if quest.y + quest.height > cluster.y - 2 and quest.x + quest.width > cluster.x then
		-- Narrow phones: the quest card ends above the action cluster instead of running into it.
		quest.height = math.max(0.06 * h, cluster.y - 2 - quest.y)
	end
	-- Collapsible quest tracker: a touch-size toggle at the card's left edge; the card text sits
	-- right of it and collapsing leaves only the toggle.
	if quest.y + M.MIN_TOUCH > cluster.y - 2 and quest.x + quest.width > cluster.x then
		-- Short phones: no touch-height room above the arc, so the card sits left of the arc instead.
		quest.x = math.floor(cluster.x - 4 - quest.width + 0.5)
	end
	quest.height = math.max(quest.height, M.MIN_TOUCH)
	local questToggle = rect(quest.x, quest.y, M.MIN_TOUCH, M.MIN_TOUCH)
	quest.x, quest.width = quest.x + M.MIN_TOUCH + 4, quest.width - M.MIN_TOUCH - 4
	-- Item hotbar: bottom centre on the bottom-left row's line, between the row and the cluster.
	local slotSize = if touch then M.MIN_TOUCH else math.max(M.MIN_TOUCH, math.min(52, math.floor(0.07 * h)))
	-- As many of HOTBAR_SLOTS as fit centred between the row and the arc (narrow phones get fewer).
	local rowRight = 0.02 * h + edge + 3 * (size + gap)
	local room = 2 * math.min(width / 2 - rowRight, cluster.x - width / 2) - 2 * M.HOTBAR_GAP
	local slots = math.clamp(math.floor((room + M.HOTBAR_GAP) / (slotSize + M.HOTBAR_GAP)), 0, M.HOTBAR_SLOTS)
	local hotbarWidth = math.max(0, slots * slotSize + (slots - 1) * M.HOTBAR_GAP)
	local hotbar = rect(width / 2 - hotbarWidth / 2, top + 0.98 * h - slotSize - edge, hotbarWidth, slotSize)
	-- Combat (C3, G12): the target bar (name, Lv, HP) top-centre, kept right of the vitals panel and
	-- left of the minimap on narrow screens, and the end-combat pill above the action cluster.
	local target = tc(-0.4, 0.4, 0.02, 0.14)
	if target.x < clearX then
		local right = target.x + target.width
		target.x, target.width = math.floor(clearX + 0.5), math.max(0, right - math.floor(clearX + 0.5))
	end
	local mapGap = minimap.x - math.floor(0.02 * h + 0.5)
	if target.x + target.width > mapGap then
		target.width = math.max(0, mapGap - target.x)
	end
	-- Contextual banner lanes (p134 v57: the hunger line at 0.16H covered half of the companion's
	-- name tag). First choice is the top strip between the vitals and the minimap / quest card,
	-- above where the player and companion tags draw; the alternate sits in the left column under the
	-- tracker, clear of the screen middle. `bannerRect` picks the first that hits no shown tag.
	local laneHeight = math.max(30, M.BANNER_HEIGHT * h)
	local laneLeft = clearX
	local laneRight = minimap.x - 0.02 * h
	if questToggle.y < top + 0.02 * h + laneHeight and questToggle.x < laneRight then
		laneRight = questToggle.x - 0.02 * h
	end
	local laneWidth = math.max(0, math.min(1.2 * h, laneRight - laneLeft))
	local banner = rect((laneLeft + laneRight) / 2 - laneWidth / 2, top + 0.02 * h, laneWidth, laneHeight)
	local altY = tracker.y + tracker.height + 0.02 * h
	local bannerAlt = rect(
		vitals.x,
		altY,
		math.max(vitals.width, tracker.width),
		math.max(0, math.min(laneHeight * 1.4, rowSlots[1].y - 0.02 * h - altY))
	)
	local endCombat = rect(width - 0.40 * h, top + 0.48 * h, 0.37 * h, 0.10 * h)
	if endCombat.y + endCombat.height > cluster.y - M.ARC_GAP then
		endCombat.y = math.floor(cluster.y - M.ARC_GAP - endCombat.height + 0.5)
	end
	if hits(endCombat, quest, M.ARC_GAP) then
		-- Short phones: no room between the quest card and the arc, so the pill sits left of the arc.
		endCombat.x = math.floor(cluster.x - M.ARC_GAP * 4 - endCombat.width + 0.5)
		endCombat.y = math.floor(cluster.y + cluster.height * 0.5 - endCombat.height / 2 + 0.5)
	end
	return {
		safeHeight = h,
		arcScale = k,
		vitals = vitals,
		chips = chips,
		tracker = tracker,
		minimap = minimap,
		coords = coords,
		quest = quest,
		questToggle = questToggle,
		hotbar = hotbar,
		hotbarSlots = slots,
		status = status,
		row = bounds(rowSlots),
		rowSlots = rowSlots,
		cluster = cluster,
		tokens = tokens,
		target = target,
		endCombat = endCombat,
		banner = banner,
		bannerAlt = bannerAlt,
		-- The framed hotbar as drawn: tray plus the selected slot's tooltip band above it.
		hotbarFrame = (function(): Rect
			local tray = M.hotbarTray(hotbar)
			local tip = M.tokenText("caption", h, touch == true) + 8 + 3
			return rect(tray.x, tray.y - tip, tray.width, tray.height + tip)
		end)(),
	}
end

--- The rect a contextual banner takes: the first of the top lane, the left lane and the old status
--- region that overlaps none of `avoid` (screen rects of shown name tags, the combat target bar).
function M.bannerRect(regions: any, avoid: { Rect }): Rect
	for _, candidate in { regions.banner, regions.bannerAlt, regions.status } do
		local clear = candidate.width > 0 and candidate.height > 0
		for _, other in avoid do
			clear = clear and not hits(candidate, other, 2)
		end
		if clear then
			return candidate
		end
	end
	return regions.banner
end

-- Hotbar slot looks (Durango R05-1 / R08-1 framed item slots): an empty slot stays a visible but
-- dim frame, a filled slot a solid framed tile, the selected (held) slot the ochre highlight.
M.HOTBAR_LOOK = table.freeze({
	empty = table.freeze({
		fill = 0.55,
		fillColor = "panel",
		rim = "slateLock",
		rimWidth = 1.5,
		rimAlpha = 0.25,
		key = 0.45,
	}),
	filled = table.freeze({ fill = 0.15, fillColor = "panel", rim = "drift", rimWidth = 2, rimAlpha = 0, key = 0.15 }),
	selected = table.freeze({ fill = 0.05, fillColor = "tealDeep", rim = "ochre", rimWidth = 3, rimAlpha = 0, key = 0 }),
})

function M.hotbarLook(state: string): any
	return M.HOTBAR_LOOK[state] or M.HOTBAR_LOOK.empty
end

--- Inside-slot geometry for a `size` px slot (relative rects): the item icon in the middle, the
--- slot number in the top-left corner and the stack count in the bottom-right corner, all inside.
function M.hotbarSlot(size: number): { icon: Rect, key: Rect, count: Rect, text: number }
	local text = math.max(10, math.floor(size * 0.26))
	local icon = math.floor(size * 0.68)
	return {
		icon = rect((size - icon) / 2, (size - icon) / 2, icon, icon),
		key = rect(3, 2, text, text + 2),
		count = rect(size - 3 - 3 * text, size - 3 - text - 2, 3 * text, text + 2),
		text = text,
	}
end

--- The framed tray behind the hotbar slots.
function M.hotbarTray(hotbar: Rect): Rect
	local pad = M.HOTBAR_TRAY_PAD
	return rect(hotbar.x - pad, hotbar.y - pad, hotbar.width + 2 * pad, hotbar.height + 2 * pad)
end

--- The one name tooltip (selected slot only): a pill above the tray, centred on slot `index` and
--- kept within the tray's width so it never reaches the bottom-left row or the action cluster.
function M.hotbarTip(hotbar: Rect, index: number, textSize: number): Rect
	local tray = M.hotbarTray(hotbar)
	local size = hotbar.height
	local width = math.min(tray.width, 3 * size + 2 * M.HOTBAR_GAP)
	local centre = hotbar.x + (index - 1) * (size + M.HOTBAR_GAP) + size / 2
	local x = math.clamp(centre - width / 2, tray.x, tray.x + tray.width - width)
	local height = textSize + 8
	return rect(x, tray.y - 3 - height, width, height)
end

--- Whether the hotbar and the bottom-left row hide: under a full modal sheet (`playerGui` shows one,
--- e.g. the survivor picker) or while a flagged surface is up (D2c: the hotbar drew over the down
--- card and under the carcass harvest picker's Leave pill). `attribute` reads a LocalPlayer attribute.
M.BOTTOM_HIDE_ATTRIBUTES = table.freeze({
	"ForgeSurvivalSheetOpen",
	"ForgeExtensionSheetOpen",
	"ForgeDownPanelOpen",
	"ForgeCarcassPickerOpen",
})
function M.bottomHidden(playerGui: any, attribute: (string) -> any): boolean
	for _, name in M.BOTTOM_HIDE_ATTRIBUTES do
		if attribute(name) == true then
			return true
		end
	end
	return M.sheetOpen(playerGui)
end

function M.overlaps(a: Rect, b: Rect): boolean
	return hits(a, b, 0)
end

-- Rough rendered width of `text` at `size` px: Hangul is about one em per glyph, Latin narrower.
local function textWidth(text: string, size: number): number
	local width = 0
	for _, code in utf8.codes(text) do
		width += if code >= 0x1100 then size else size * 0.55
	end
	return width
end

--- Screen rect a world label's text covers when its board centre projects to (x, y): the name line,
--- plus the hint line when there is one, as wide as the longer text (never past the board).
function M.labelRect(x: number, y: number, name: string, hint: string?): Rect
	local B = M.LABEL_BOARD
	local wide = textWidth(name, B.name)
	if hint and hint ~= "" then
		wide = math.max(wide, textWidth(hint, B.hint))
	end
	local w = math.min(B.width, wide + 8)
	local tall = if hint and hint ~= "" then B.name + B.hint + 8 else B.name + 6
	return rect(x - w / 2, y - B.height / 2, w, tall)
end

-- HUD regions a world label must never draw over (studio-after defects 10 and 11: billboard text ran
-- across the minimap, the quest card and the hotbar). The minimap grows by its bezel.
-- `hotbarFrame` is the framed tray plus the selected slot's name tooltip above it (hud2).
M.LABEL_BLOCKERS = table.freeze({
	"vitals",
	"chips",
	"coords",
	"quest",
	"questToggle",
	"hotbar",
	"hotbarFrame",
	"row",
	"cluster",
})

-- Clear px a world label keeps from every HUD region (labels2: with 0 px a label sat on the vitals
-- panel's top edge on the phone, p134 v63 lb_d4_tl; text stroke and descenders draw past labelRect).
M.LABEL_HUD_PAD = 6

--- True when a label rect (gui space) touches a HUD region of `regions` (M.regions output), within
--- LABEL_HUD_PAD, or one of `core` (the Roblox top bar buttons, M.coreRects).
function M.labelBlocked(r: Rect, regions: any, core: { Rect }?): boolean
	local pad = M.LABEL_HUD_PAD
	local map = regions.minimap
	if map and hits(r, { x = map.x - 6, y = map.y - 6, width = map.width + 12, height = map.height + 12 }, pad) then
		return true
	end
	for _, key in M.LABEL_BLOCKERS do
		local region = regions[key]
		if region and region.width > 0 and region.height > 0 and hits(r, region, pad) then
			return true
		end
	end
	for _, region in core or ({} :: { Rect }) do
		if hits(r, region, pad) then
			return true
		end
	end
	return false
end

--- Gui-space rects of the Roblox top bar a world label must stay off (labels2: '프로토케라톱스' and
--- '쓰러진 통나무' drew under the Roblox button pill, p134 v63 lb_d4_tl / lb_crea0_c). `inset` is
--- GuiService:GetGuiInset()'s top-left (the bar height `y` that WorldToScreenPoint already takes off),
--- `freeMinX` / `freeMaxX` the TopbarInset free span (left of it the Roblox menu/chat/voice buttons,
--- right of it the right-side buttons), `barBottom` TopbarInset.Max.Y in viewport px, `guiTop` the
--- gui's AbsolutePosition.Y, `width` the viewport width. The whole bar band (a label there is cut by
--- the screen edge or drawn under the bar) and above it is one rect; the button spans reach down to
--- `barBottom`.
function M.coreRects(
	inset: number,
	freeMinX: number,
	freeMaxX: number,
	barBottom: number,
	guiLeft: number,
	guiTop: number,
	width: number
): { Rect }
	local y0 = -inset - guiTop
	local tall = math.max(inset, barBottom)
	local out = { rect(-guiLeft - width, y0 - 400, 3 * width, 400 + inset) }
	if freeMinX > 0 then
		table.insert(out, rect(-guiLeft, y0, freeMinX, tall))
	end
	if freeMaxX > 0 and freeMaxX < width then
		table.insert(out, rect(freeMaxX - guiLeft, y0, width - freeMaxX, tall))
	end
	return out
end

--- The Roblox top bar rects (M.coreRects) for a gui, from GuiService; none when the engine has no
--- top bar API (headless spec engines).
function M.coreBlockers(gui: any, guiService: any, viewportWidth: number): { Rect }
	if not guiService then
		return {}
	end
	local ok, topLeft = pcall(function()
		return guiService:GetGuiInset()
	end)
	if not ok or not topLeft then
		return {}
	end
	local bar = guiService.TopbarInset
	local at = gui.AbsolutePosition
	local minX = if bar then bar.Min.X else 0
	local maxX = if bar and bar.Max.X > bar.Min.X then bar.Max.X else viewportWidth
	local bottom = if bar then bar.Max.Y else topLeft.Y
	return M.coreRects(topLeft.Y, minX, maxX, bottom, at.X, at.Y, viewportWidth)
end

-- World label declutter (labels audit: at 800x360 "모닥불" drew over "프로토케라톱스" and "섬유 덤불"
-- over the player; Durango R05-1 shows the focused label in full and few others). Rank by kind, lower
-- first: the current target is 0, creatures and people 1, gather nodes and drops 2, structures 3.
M.LABEL_RANK = table.freeze({ wildlife = 1, pet = 1, npc = 1, node = 2, drop = 2, station = 3, dock = 3 })
-- Screen px { dx, dy } a label may move off its anchor point to clear a higher-priority one, in order.
M.LABEL_NUDGES = table.freeze({ { 0, 0 }, { 0, -6 }, { 0, 6 }, { 0, -12 }, { 0, 12 }, { -12, 0 }, { 12, 0 } })
-- The focus label never yields to another label; it may move further than the rest to clear the player
-- and the HUD (a creature beside the player wears a wide name).
M.LABEL_FOCUS_NUDGES = table.freeze({ { 0, -24 }, { 0, 24 }, { -40, 0 }, { 40, 0 }, { 0, -40 }, { -80, 0 }, { 80, 0 } })
-- Labels drawn at once: a phone (safe height under 480 px) shows at most `phone`, a larger screen `wide`.
M.LABEL_CAP = table.freeze({ phone = 6, wide = 12 })
-- Clear px kept between two labels, and around the player's figure / a name tag (rounding and the 0.2 s
-- label cadence against a moving camera must not let edges touch).
M.LABEL_GAP = table.freeze({ label = 2, avoid = 4 })

function M.labelCap(safeHeight: number): number
	return if safeHeight < 480 then M.LABEL_CAP.phone else M.LABEL_CAP.wide
end

-- Same-name creatures within this many studs of a flock member share one label '도도 ×5' (labels2:
-- a dodo flock took three of the phone's six labels, p134 v63 lb_crea0_c).
M.FLOCK_STUDS = 12

--- Collapse flocks: wildlife targets with the same `texts[id]` chained within FLOCK_STUDS of each other
--- keep only their first (nearest) member, which carries the flock size in the returned counts. Targets
--- in `alone` (the focus) never merge. Order is kept.
--- D2 R07 (four '프로토케라톱스' labels stacked over one herd): members of one herd (`herds[id]`, the
--- ForgeHerdId attribute) always share a single label, however far apart they wander; the focused
--- member carries it when it is in the herd, else the nearest member.
function M.flocks(
	targets: { Candidate },
	texts: { [string]: string },
	alone: { [string]: boolean },
	herds: { [string]: string }?
): ({ Candidate }, { [string]: number })
	local herdOf: { [string]: string } = herds or {}
	local lead: { [string]: string } = {}
	local size: { [string]: number } = {}
	for _, target in targets do
		local herd = if target.kind == "wildlife" then herdOf[target.id] else nil
		if herd then
			size[herd] = (size[herd] or 0) + 1
			if alone[target.id] and lead[herd] == nil then
				lead[herd] = target.id
			end
		end
	end
	for _, target in targets do
		local herd = if target.kind == "wildlife" then herdOf[target.id] else nil
		if herd and lead[herd] == nil then
			lead[herd] = target.id
		end
	end
	local out: { Candidate } = {}
	local counts: { [string]: number } = {}
	local groups: { { leader: string, text: string, members: { Candidate } } } = {}
	for _, target in targets do
		local herd = if target.kind == "wildlife" then herdOf[target.id] else nil
		if herd then
			if lead[herd] == target.id then
				counts[target.id] = size[herd]
				table.insert(out, target)
			end
			continue
		end
		local joined = false
		if target.kind == "wildlife" and not alone[target.id] then
			for _, group in groups do
				if group.text == texts[target.id] then
					for _, member in group.members do
						local dx, dz = member.x - target.x, member.z - target.z
						if dx * dx + dz * dz <= M.FLOCK_STUDS * M.FLOCK_STUDS then
							table.insert(group.members, target)
							counts[group.leader] += 1
							joined = true
							break
						end
					end
				end
				if joined then
					break
				end
			end
			if not joined then
				table.insert(groups, { leader = target.id, text = texts[target.id], members = { target } })
			end
		end
		if not joined then
			counts[target.id] = 1
			table.insert(out, target)
		end
	end
	return out, counts
end

--- Flock label text: the name, then ' ×n' for more than one.
function M.flockText(name: string, count: number): string
	return if count > 1 then name .. " \u{00D7}" .. count else name
end

--- Screen rect (gui space) of a world name tag BillboardGui on `adornee`, or nil off screen.
--- StudsOffset is camera space (screen up), StudsOffsetWorldSpace world space (labels2: adding
--- StudsOffset as world up put the '텀블 (동료)' plate ~2 studs low at the 55 degree pitch, so
--- '모닥불' was placed onto its top half, p134 v63 dn4_c). A pixel-sized plate uses its Size.
function M.tagRect(camera: any, tag: any, adornee: any, inset: any): Rect?
	local lift = tag.StudsOffsetWorldSpace + camera.CFrame:VectorToWorldSpace(tag.StudsOffset)
	local point, seen = camera:WorldToScreenPoint(adornee.Position + lift)
	if not seen then
		return nil
	end
	local w, h = tag.Size.X.Offset, tag.Size.Y.Offset
	if tag.Size.X.Scale ~= 0 or tag.Size.Y.Scale ~= 0 or w <= 0 or h <= 0 then
		w, h = tag.AbsoluteSize.X, tag.AbsoluteSize.Y
	end
	return rect(point.X - inset.X - w / 2, point.Y - inset.Y - h / 2, w, h)
end

-- Roblox default ProximityPrompt card (px): the input button square plus the text column.
M.PROMPT_CARD = table.freeze({ height = 72, button = 72, pad = 24, action = 19, object = 14 })

--- Screen rect of a default prompt card centred at (x, y).
function M.promptRect(x: number, y: number, action: string, object: string): Rect
	local C = M.PROMPT_CARD
	local w = C.button + C.pad + math.max(textWidth(action, C.action), textWidth(object, C.object))
	return rect(x - w / 2, y - C.height / 2, w, C.height)
end

--- True when the own name tag (`tag`, screen rect) must hide because a shown prompt card covers it
--- (labels2: the gather card '고사리 섬유 / 채집하기' sat on 'indosaram5', p134 v63 cs1). The card is
--- Roblox's own billboard and cannot move off its node, so the tag yields while it shows.
function M.tagCovered(tag: Rect, cards: { Rect }): boolean
	for _, card in cards do
		if hits(tag, card, M.LABEL_GAP.avoid) then
			return true
		end
	end
	return false
end

export type LabelItem = { id: string, kind: string, rect: Rect, distance: number, target: boolean?, fixed: boolean? }

--- Which world labels draw, and how far each moves: items sorted by rank (target, creatures, nodes,
--- structures), then distance, then id. Each takes the first nudge (LABEL_NUDGES, screen px down) whose
--- rect touches no placed label, no `avoid` rect (the local player's figure and plate, name tags) and,
--- when given, nothing `blocked` rejects (HUD regions); otherwise it is hidden. At most `cap` draw.
--- The focus (target) also tries LABEL_FOCUS_NUDGES. Returns { id, dx, dy } in draw order.
function M.declutter(
	items: { LabelItem },
	avoid: { Rect },
	cap: number,
	blocked: ((Rect) -> boolean)?
): { { id: string, dx: number, dy: number } }
	local order = table.clone(items)
	local function rank(item: LabelItem): number
		return if item.fixed then -1 elseif item.target then 0 else M.LABEL_RANK[item.kind] or 3
	end
	table.sort(order, function(a, b)
		local ra, rb = rank(a), rank(b)
		if ra ~= rb then
			return ra < rb
		end
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.id < b.id
	end)
	local placed: { Rect } = {}
	local out: { { id: string, dx: number, dy: number } } = {}
	for _, item in order do
		if #out >= cap then
			break
		end
		if item.fixed then
			-- A plate another script draws (the companion's '텀블 (동료)'): it cannot move or hide, so it
			-- takes its spot and a cap slot first (labels2: 6 labels plus the plate made 7 on the phone).
			table.insert(placed, item.rect)
			table.insert(out, { id = item.id, dx = 0, dy = 0 })
			continue
		end
		local tries = M.LABEL_NUDGES
		if item.target then
			tries = table.clone(tries)
			table.move(M.LABEL_FOCUS_NUDGES, 1, #M.LABEL_FOCUS_NUDGES, #tries + 1, tries)
		end
		for _, nudge in tries do
			local dx, dy = nudge[1], nudge[2]
			local r = rect(item.rect.x + dx, item.rect.y + dy, item.rect.width, item.rect.height)
			local clear = not (blocked and blocked(r))
			for _, other in avoid do
				clear = clear and not hits(r, other, M.LABEL_GAP.avoid)
			end
			for _, other in placed do
				clear = clear and not hits(r, other, M.LABEL_GAP.label)
			end
			if clear then
				table.insert(placed, r)
				table.insert(out, { id = item.id, dx = dx, dy = dy })
				break
			end
		end
	end
	return out
end

--- Screen rect (gui space) of the local player's figure and own name plate: from `head` (the screen
--- point over the head) down to `plate` (the plate centre, under the feet), as wide as the plate text
--- (`name` at `size` px) and never narrower than the body.
function M.playerRect(head: { x: number, y: number }, plate: { x: number, y: number }, name: string, size: number): Rect
	local w = math.max(48, textWidth(name, size) + 8)
	local top = math.min(head.y, plate.y - size)
	local bottom = math.max(head.y, plate.y + size)
	local cx = (head.x + plate.x) / 2
	return rect(cx - w / 2, top, w, bottom - top)
end

--- Caption pill rect for the primary token `p` (`width` x `height`): left of the token, else under,
--- else over it, else left of or above the whole cluster; the first spot inside the gui that touches none of
--- `others` (the other shown tokens and HUD regions). Studio-after defect 3: the left-only pill sat
--- on the consume token and the slot under it.
function M.captionRect(
	p: Rect,
	width: number,
	height: number,
	others: { Rect },
	guiWidth: number,
	guiHeight: number,
	top: number?,
	cluster: Rect?
): Rect
	local gap = 6
	local cx, cy = p.x + p.width / 2, p.y + p.height / 2
	local function clamp(r: Rect): Rect
		local x = math.clamp(r.x, 0, math.max(0, guiWidth - r.width))
		local y = math.clamp(r.y, top or 0, math.max(top or 0, guiHeight - r.height))
		return rect(x, y, r.width, r.height)
	end
	local spots = {
		rect(p.x - gap - width, cy - height / 2, width, height),
		clamp(rect(cx - width / 2, p.y + p.height + 2, width, height)),
		clamp(rect(cx - width / 2, p.y - 2 - height, width, height)),
	}
	if cluster then
		-- Long captions on PC: on the primary's row left of the whole cluster, else above it.
		table.insert(spots, rect(cluster.x - gap - width, cy - height / 2, width, height))
		table.insert(spots, clamp(rect(cluster.x + cluster.width - width, cluster.y - gap - height, width, height)))
	end
	for _, spot in spots do
		local clear = M.inside(spot, guiWidth, guiHeight, top)
		for _, other in others do
			if clear and hits(spot, other, 0) then
				clear = false
			end
		end
		if clear then
			return spot
		end
	end
	return spots[#spots]
end

--- Inside-panel geometry of the compact vitals (relative to the panel's top-left): a round level
--- badge on the left, then per stat row an icon, a bar track and a right-aligned number.
function M.vitalsRows(panel: Rect): { badge: Rect, rows: { { icon: Rect, track: Rect, value: Rect } }, text: number }
	local row = math.floor((panel.height - 8) / 3)
	local badgeSide = math.min(panel.height - 8, 3 * row)
	local badge = rect(4, (panel.height - badgeSide) / 2, badgeSide, badgeSide)
	local x0 = badge.x + badge.width + 6
	local valueWidth = math.max(26, math.floor(row * 1.7))
	local iconSide = row - 2
	local rows = {}
	for index = 1, 3 do
		local y = 4 + (index - 1) * row
		local trackX = x0 + iconSide + 4
		local barHeight = math.max(6, math.floor(row * 0.42))
		rows[index] = {
			icon = rect(x0, y + 1, iconSide, iconSide),
			track = rect(trackX, y + (row - barHeight) / 2, panel.width - trackX - valueWidth - 6, barHeight),
			value = rect(panel.width - valueWidth - 4, y, valueWidth, row),
		}
	end
	return { badge = badge, rows = rows, text = math.max(11, row - 4) }
end

--- Bounding circles of two tokens overlap (the tokens' hit test).
function M.circlesOverlap(a: Rect, b: Rect): boolean
	local dx = (a.x + a.width / 2) - (b.x + b.width / 2)
	local dy = (a.y + a.height / 2) - (b.y + b.height / 2)
	local reach = (math.max(a.width, a.height) + math.max(b.width, b.height)) / 2
	return dx * dx + dy * dy < reach * reach
end

function M.inside(r: Rect, width: number, height: number, top: number?): boolean
	return r.x >= 0 and r.y >= (top or 0) and r.x + r.width <= width and r.y + r.height <= height
end

-- Action cluster contents per context (spec section 5). `flags` are what the client can do now.
export type Flags = {
	combat: boolean,
	building: boolean,
	interact: boolean,
	dodge: boolean,
	guard: boolean,
	stance: boolean,
	attack: boolean,
	shoot: boolean,
	mount: boolean,
	skills: boolean,
	-- C4: a stunned (downed) tameable target is in reach, and the player is riding.
	capture: boolean?,
	riding: boolean?,
}
export type Token = { slot: string, id: string, enabled: boolean }

-- Painted glyph per token id (ui icon ids, ItemIcons.ui): every HUD action is an icon button.
M.TOKEN_ICONS = table.freeze({
	interact = "hud.interact",
	attack = "hud.attack",
	shoot = "stance.shoot",
	dodge = "dodge",
	guard = "stance.defense",
	stance = "stance.attack",
	mount = "cat.pet",
	skills = "skills",
	consume = "cat.food",
	build = "build",
	capture = "capture",
	dismount = "hud.dismount",
	pet = "cat.pet",
	menu = "hud.menu",
	emote = "hud.emote",
	chat = "hud.chat",
	rest = "hud.rest",
	gather = "hud.gather",
	quest = "todo",
	questHide = "close",
	currency = "currency",
	level = "xp",
})
M.STANCE_ICONS = table.freeze({
	attack = true,
	charge = true,
	counter = true,
	defense = true,
	onslaught = true,
	shoot = true,
})

--- Icon id for a token. The interact token follows what it will do (rest at a campfire, gather at
--- a node); the stance token shows the current stance.
function M.tokenIcon(id: string, context: { rest: boolean?, gather: boolean?, stance: string? }?): string
	local c: any = context or {}
	if id == "interact" then
		return if c.rest then M.TOKEN_ICONS.rest elseif c.gather then M.TOKEN_ICONS.gather else M.TOKEN_ICONS.interact
	elseif id == "stance" and c.stance and M.STANCE_ICONS[c.stance] then
		return "stance." .. c.stance
	end
	return M.TOKEN_ICONS[id] or M.TOKEN_ICONS.interact
end

function M.context(flags: Flags): string
	return if flags.building
		then "build"
		elseif flags.combat then "combat"
		elseif flags.riding then "mount"
		else "explore"
end

--- Tokens shown for the current context, in slot order. Build mode shows none: the placement bar
--- (confirm / rotate / cancel) owns that context. Tokens keep their slot between contexts unless
--- their function changes.
function M.tokens(flags: Flags): { Token }
	local context = M.context(flags)
	if context == "build" then
		return {}
	end
	local out: { Token } = {}
	local function add(slot: string, id: string, enabled: boolean)
		table.insert(out, { slot = slot, id = id, enabled = enabled })
	end
	if context == "combat" then
		add("P", if flags.attack or not flags.shoot then "attack" else "shoot", flags.attack or flags.shoot)
		add("I1", "dodge", flags.dodge)
		add("I2", "stance", flags.stance)
		add("I3", "guard", flags.guard)
		add("O1", "skills", flags.skills)
		add("O2", "consume", true)
		if flags.capture then
			add("X", "capture", true)
		elseif flags.attack and flags.shoot then
			add("X", "shoot", true)
		end
	elseif context == "mount" then
		-- Riding (spec section 5): dismount first, the pet ring, interact and consume.
		add("P", "dismount", true)
		add("I2", "pet", true)
		add("I3", "interact", flags.interact)
		add("O1", "consume", true)
	else
		add("P", "interact", flags.interact)
		add("I1", "dodge", flags.dodge)
		if flags.mount then
			add("I2", "mount", true)
		end
		add("I3", "skills", flags.skills)
		add("O1", "consume", true)
		add("O2", "build", true)
		if flags.capture then
			add("X", "capture", true)
		end
	end
	return out
end

export type Candidate = { id: string, kind: string, x: number, y: number, z: number }

--- Label targets: candidates within `radius` studs of the origin, nearest first, at most `limit`;
--- ties break on id so the chosen set is stable frame to frame.
function M.labelTargets(
	candidates: { Candidate },
	ox: number,
	oy: number,
	oz: number,
	radius: number?,
	limit: number?
): { Candidate }
	local reach = radius or M.LABEL_RADIUS
	local near: { { any } } = {}
	for _, candidate in candidates do
		local d = math.sqrt((candidate.x - ox) ^ 2 + (candidate.y - oy) ^ 2 + (candidate.z - oz) ^ 2)
		if d <= reach then
			table.insert(near, { d, candidate } :: { any })
		end
	end
	table.sort(near, function(a, b)
		if a[1] ~= b[1] then
			return a[1] < b[1]
		end
		return a[2].id < b[2].id
	end)
	local out: { Candidate } = {}
	local nodes = 0
	for _, entry in near do
		if #out >= (limit or M.LABEL_LIMIT) then
			break
		end
		local candidate = entry[2]
		if candidate.kind == "node" then
			nodes += 1
			if nodes > M.NODE_LABEL_LIMIT then
				continue
			end
		end
		table.insert(out, candidate)
	end
	return out
end

--- Studs above an anchor's centre for its label: over the tallest BasePart child (a node's shown
--- mesh) plus LABEL_BOARD.clear, never under LABEL_BOARD.base.
function M.labelLift(anchor: any): number
	local top = anchor.Size.Y / 2
	for _, child in anchor:GetChildren() do
		if child:IsA("BasePart") and child.Transparency < 1 then
			top = math.max(top, child.Position.Y + child.Size.Y / 2 - anchor.Position.Y)
		end
	end
	return math.max(M.LABEL_BOARD.base, top + M.LABEL_BOARD.clear)
end

--- Minimap pixel for a world offset (north-up, +x right, +z down), or nil outside the map.
--- With the camera's look (`lookX`, `lookZ`, flattened) the map turns so its up is screen up:
--- the quarter view looks along a 45 degree yaw, so a north-up map disagreed with every tap
--- (p134 v54 read that as camera yaw drift).
function M.mapPoint(
	dx: number,
	dz: number,
	side: number,
	window: number?,
	lookX: number?,
	lookZ: number?
): (number?, number?)
	local lx, lz = lookX or 0, lookZ or -1
	local length = math.sqrt(lx * lx + lz * lz)
	if length < 1e-6 then
		lx, lz, length = 0, -1, 1
	end
	lx, lz = lx / length, lz / length
	dx, dz = dx * -lz + dz * lx, -(dx * lx + dz * lz)
	local half = (window or M.MAP_WINDOW) / 2
	if math.abs(dx) > half or math.abs(dz) > half then
		return nil, nil
	end
	return side / 2 + dx / half * side / 2, side / 2 + dz / half * side / 2
end

--- Map coordinates shown under the minimap: world X and Z rounded to whole studs.
function M.coords(x: number, z: number): (number, number)
	return math.floor(x + 0.5), math.floor(z + 0.5)
end

-- Player ring (spec section 5, G6): 3.5 stud teal ring, 50 degree facing wedge reaching 1.2x.
M.RING = table.freeze({ radius = 3.5, wedgeDegrees = 50, wedgeReach = 1.2, wedgeAlpha = 0.35, otherAlpha = 0.3 })

-- ---------------------------------------------------------------------------------------------
-- Full-screen panels (spec section 6, Robango C8): craft, trading post and bag cover the safe area
-- with a title bar and three columns (categories | list | detail) and one primary button at the
-- detail column's bottom. Column widths are fractions of the body width (spec SW).
M.PANEL_COLUMNS = table.freeze({
	craft = { 0.16, 0.40, 0.44 },
	market = { 0.12, 0.48, 0.40 },
	bag = { 0.28, 0.46, 0.26 },
})
M.PANEL_GAP = 8
M.PANEL_MIN_TEXT = 13
-- Row heights in H (spec 6.1: 0.09H category rows, 0.11H list rows, 0.12H primary button) with the
-- touch floor; on a pointer screen they stop growing at the cap so a 1022 px tall PC keeps lists dense.
M.PANEL_ROWS =
	table.freeze({ bar = { 0.10, 72 }, category = { 0.09, 56 }, list = { 0.11, 72 }, primary = { 0.12, 64 } })
M.BAG_COLUMNS = 6
-- Smallest notice lane height (one 13 px line plus padding).
M.NOTICE_MIN = 28
M.MARKET_GRID_COLUMNS = 4

export type PanelLayout = {
	kind: string,
	safeHeight: number,
	frame: Rect,
	bar: Rect,
	title: Rect,
	-- Status / refusal toast lane while the panel is open (never over the columns).
	notice: Rect,
	currency: Rect,
	close: Rect,
	categories: Rect,
	list: Rect,
	detail: Rect,
	detailBody: Rect,
	primary: Rect,
	categoryRow: number,
	listRow: number,
	cell: number,
	gap: number,
	text: { [string]: number },
}

--- Panel text size: the spec type scale, never under 13 px (phone readability floor).
function M.panelText(style: string, safeHeight: number): number
	return math.max(M.PANEL_MIN_TEXT, M.textSize(style, safeHeight))
end

local function row(kind: string, h: number): number
	local spec = M.PANEL_ROWS[kind]
	return math.max(M.MIN_TOUCH, math.floor(math.min(spec[1] * h, spec[2]) + 0.5))
end

--- Grid cell edge for `columns` cells in a list column `width` wide (bag: 6 columns, trading post
--- category grid: 4); the 6 px scrollbar and the grid frame's 8 px inset take their width off.
function M.gridCell(width: number, columns: number, gap: number?): number
	local g = gap or M.PANEL_GAP
	return math.floor((width - 6 - 8 - (columns - 1) * g) / columns)
end

--- Bag slot of edge `cell` px (relative rects): the item icon fills the top-centre and the stack
--- count is a compact badge in the bottom-right corner, sized to its digits at `textSize`.
--- p134 v53 (phone): a 36x22 count box sat across the lower half of every 49-53 px slot's icon.
function M.bagSlot(cell: number, textSize: number, count: string): { icon: Rect, badge: Rect }
	local iconSize = math.floor(cell * 0.74)
	local height = math.min(textSize + 4, math.floor(cell * 0.4))
	-- BuilderSans digits are ~0.55 em wide; 2 px padding each side. The badge label never wraps
	-- (skinSheet): a wrapped "15" showed as "1" (p134 C1).
	local digit = math.ceil(textSize * 0.55)
	local width = math.min(cell - 4, math.max(height, #count * digit + 4))
	return {
		icon = rect(math.floor((cell - iconSize) / 2), 3, iconSize, iconSize),
		badge = rect(cell - 2 - width, cell - 2 - height, width, height),
	}
end

--- Panel rects in the space of a CoreUISafeInsets ScreenGui of `width` x `height` (`topClear` as in
--- `regions`). `kind` is craft, market or bag. `hitTop` is the first gui row that receives presses
--- (HudShell.hitClear): D2b Studio, the 1280x720 craft/bag Close at gui y 11 never activated by path
--- or by coordinates, and ac58d0f saw the same for the dock at y 8. The title row then drops below
--- it and the strip it leaves at the top of the bar is the notice lane; with no band the notice lane
--- is the bar between the title and the currency pill. Either way it never covers the columns.
function M.panel(width: number, height: number, topClear: number?, kind: string, hitTop: number?): PanelLayout
	local top = topClear or 0
	local h = height - top
	local gap = M.PANEL_GAP
	local pad = math.max(gap, math.floor(0.02 * h + 0.5))
	local barHeight = row("bar", h)
	local close = M.MIN_TOUCH
	local inset = (barHeight - close) / 2
	local rowY = math.max(top, (hitTop or top) - inset)
	local closeRect = rect(width - pad - close, rowY + inset, close, close)
	local pillHeight = math.min(barHeight - 8, math.max(28, math.floor(0.07 * h + 0.5)))
	local pillWidth = math.clamp(math.floor(0.45 * h + 0.5), 140, 240)
	local currency = rect(closeRect.x - gap - pillWidth, rowY + (barHeight - pillHeight) / 2, pillWidth, pillHeight)
	local titleRoom = math.max(0, currency.x - gap - pad)
	local title, notice
	if rowY - top >= M.NOTICE_MIN then
		title = rect(pad, rowY, titleRoom, barHeight)
		notice = rect(pad, top, width - 2 * pad, rowY - top)
	else
		local titleWidth = math.floor(titleRoom * 0.4 + 0.5)
		title = rect(pad, rowY, titleWidth, barHeight)
		notice = rect(pad + titleWidth + gap, rowY, math.max(0, titleRoom - titleWidth - gap), barHeight)
	end
	barHeight += rowY - top
	local y0 = top + barHeight + gap
	local bodyHeight = top + h - pad - y0
	local bodyWidth = width - 2 * pad - 2 * gap
	local fractions = M.PANEL_COLUMNS[kind] or M.PANEL_COLUMNS.craft
	local w1 = math.floor(bodyWidth * fractions[1] + 0.5)
	local w2 = math.floor(bodyWidth * fractions[2] + 0.5)
	local w3 = bodyWidth - w1 - w2
	local categories = rect(pad, y0, w1, bodyHeight)
	local list = rect(pad + w1 + gap, y0, w2, bodyHeight)
	local detail = rect(list.x + w2 + gap, y0, w3, bodyHeight)
	local primaryHeight = row("primary", h)
	local primary = rect(detail.x, detail.y + detail.height - primaryHeight, detail.width, primaryHeight)
	local detailBody = rect(detail.x, detail.y, detail.width, detail.height - primaryHeight - gap)
	local columns = if kind == "market" then M.MARKET_GRID_COLUMNS else M.BAG_COLUMNS
	local cell = M.gridCell(list.width, columns, gap)
	local text: { [string]: number } = {}
	for style: string in M.TYPE :: any do
		text[style] = M.panelText(style, h)
	end
	return {
		kind = kind,
		safeHeight = h,
		frame = rect(0, top, width, h),
		bar = rect(0, top, width, barHeight),
		title = title,
		notice = notice,
		currency = currency,
		close = closeRect,
		categories = categories,
		list = list,
		detail = detail,
		detailBody = detailBody,
		primary = primary,
		categoryRow = row("category", h),
		listRow = row("list", h),
		cell = cell,
		gap = gap,
		text = text,
	}
end

-- Panel categories (spec 6.1 order). Item icon categories (IconFallback.category) map onto them;
-- only categories with at least one entry are shown.
M.PANEL_CATEGORY_ORDER = table.freeze({
	"all",
	"tool",
	"weapon",
	"clothing",
	"food",
	"medicine",
	"material",
	"building",
	"farm",
	"pet",
})
local ICON_CATEGORY: { [string]: string } = {
	tool = "tool",
	weapon = "weapon",
	armor = "clothing",
	food = "food",
	medicine = "medicine",
	building = "building",
	seed = "farm",
	creature = "pet",
}
function M.panelCategory(iconCategory: string?): string
	return ICON_CATEGORY[iconCategory or ""] or "material"
end

--- Categories to show for entries whose icon categories are `iconCategories`: "all" first, then
--- every non-empty category in spec order.
function M.panelCategories(iconCategories: { string }): { string }
	local present: { [string]: boolean } = {}
	for _, category in iconCategories do
		present[M.panelCategory(category)] = true
	end
	local out = { "all" }
	for _, id in M.PANEL_CATEGORY_ORDER do
		if id ~= "all" and present[id] then
			table.insert(out, id)
		end
	end
	return out
end

-- Trading post rail tabs (spec 6.2). The fourth tab is the collection box: this market books
-- sales and withdrawals as claims, and that box is the history the player acts on.
M.MARKET_TABS = table.freeze({ "buy", "sell", "mine", "claims" })
-- Sell price steppers (spec 6.2: not the reference's 1000/100/10/1 buttons).
M.PRICE_STEPS = table.freeze({ -100, -10, 10, 100 })
function M.stepPrice(price: number, step: number): number
	return math.clamp(math.floor(price) + step, 1, 1000000)
end

-- Bag equipment doll slots (spec 6.3), CharacterRules.SLOTS order.
M.DOLL_SLOTS = table.freeze({ "head", "top", "bottom", "shoes", "gloves", "bag", "weapon" })

-- Gather picker ("shell fan", spec section 3, plan C2/G7): M pebbles on an arc opening upward over
-- the node's screen point, 40 degrees apart (200 degrees at six), radius 0.22H grown until the
-- tokens part; captions sit outside the ring, the node name pill under the target. The fan is
-- shifted as a whole so every token, caption and the pill stays inside the safe area.
-- `hint` is the line under the pill that says what a tap does next (p134 v75 B1: the first tap only
-- opened the fan and nothing said a second tap gathers) or why the gather was refused (B3).
M.FAN = table.freeze({ radius = 0.22, step = 40, maximum = 6, caption = 18, pill = 22, hint = 22 })

export type Fan = { tokens: { Rect }, captions: { Rect }, name: Rect, hint: Rect, x: number, y: number }

function M.fan(
	width: number,
	height: number,
	topClear: number?,
	touch: boolean?,
	x: number,
	y: number,
	count: number
): Fan
	local top = topClear or 0
	local h = height - top
	local n = math.clamp(count, 1, M.FAN.maximum)
	local size = M.tokenSize("M", h, touch == true)
	local tall = math.max(if touch then M.MIN_TOUCH else 0, size * M.PEBBLE.aspect)
	local half = math.rad(M.FAN.step / 2)
	local radius = math.max(M.FAN.radius * h, (math.max(size, tall) + M.ARC_GAP * 2) / (2 * math.sin(half)))
	local caption, pill = M.FAN.caption, M.FAN.pill
	local pillWidth = math.min(width - 8, math.max(4 * size, 0.6 * h))
	-- Relative layout around (0, 0), then one shift into the screen.
	local tokens, captions = {}, {}
	local x0, y0, x1, y1 = -pillWidth / 2, 0, pillWidth / 2, 0
	for index = 1, n do
		local angle = math.rad(90 + M.FAN.step * ((n - 1) / 2 - (index - 1)))
		local cx, cy = radius * math.cos(angle), -radius * math.sin(angle)
		local token = rect(cx - size / 2, cy - tall / 2, size, tall)
		local out = (radius + math.max(size, tall) / 2 + caption / 2 + 2)
		local kx, ky = out * math.cos(angle), -out * math.sin(angle)
		local label = rect(kx - size * 0.8, ky - caption / 2, size * 1.6, caption)
		tokens[index], captions[index] = token, label
		for _, r in { token, label } do
			x0, y0 = math.min(x0, r.x), math.min(y0, r.y)
			x1, y1 = math.max(x1, r.x + r.width), math.max(y1, r.y + r.height)
		end
	end
	-- The name pill sits under the target and under the lowest pebble or caption of a wide fan.
	local pillTop = math.max(6, y1 + 4)
	local hintTop = pillTop + pill + 2
	y1 = hintTop + M.FAN.hint
	-- Touch keeps the spec's 32 px camera-cutout side inset as well as the edge margin.
	local edge = if touch then math.max(M.EDGE * h, 32) else 4
	local px = math.clamp(x, edge - x0, width - edge - x1)
	local py = math.clamp(y, top + edge - y0, height - edge - y1)
	local function shift(r: Rect): Rect
		return rect(r.x + px, r.y + py, r.width, r.height)
	end
	for index = 1, n do
		tokens[index], captions[index] = shift(tokens[index]), shift(captions[index])
	end
	return {
		tokens = tokens,
		captions = captions,
		name = shift(rect(-pillWidth / 2, pillTop, pillWidth, pill)),
		hint = shift(rect(-pillWidth / 2, hintTop, pillWidth, M.FAN.hint)),
		x = px,
		y = py,
	}
end

--- Status line and refusal toast lane while a sheet is open, in gui space, never over the sheet's
--- content (D2b: the "pending" line sat top-centre over the bag, skills and build rows). A full-screen
--- panel has its own lane in the title bar (`panel.notice`); a side sheet gets the strip above it,
--- else the wider gap beside it, else whatever strip is left above it (possibly empty).
function M.noticeLane(width: number, height: number, topClear: number?, sheet: Rect, panel: PanelLayout?): Rect
	if panel then
		return panel.notice
	end
	local top = topClear or 0
	local h = height - top
	local lane = math.clamp(math.floor(0.08 * h + 0.5), M.NOTICE_MIN, 44)
	if sheet.y - top >= lane + 8 then
		return rect(sheet.x, sheet.y - 4 - lane, sheet.width, lane)
	end
	local left, right = sheet.x, width - sheet.x - sheet.width
	if math.max(left, right) >= 136 then
		local x = if left >= right then 8 else sheet.x + sheet.width + 8
		return rect(x, sheet.y, math.max(left, right) - 16, 2 * lane)
	end
	return rect(sheet.x, top, sheet.width, math.max(0, sheet.y - top))
end

--- Item-gain toast stack (spec section 5: top-right, 0.46-0.58H, three lines) and the level-up
--- banner (top-centre, the status region). Lines are `caption`-scale but never under 13 px.
function M.feedback(
	width: number,
	height: number,
	topClear: number?,
	touch: boolean?
): { toasts: { Rect }, banner: Rect }
	local top = topClear or 0
	local h = height - top
	local toasts = {}
	local line = math.max(18, 0.04 * h)
	for index = 1, 3 do
		toasts[index] = rect(width - 1.0 * h, top + 0.46 * h + (index - 1) * line, 0.55 * h, line - 2)
	end
	-- The skill banner takes the contextual banner's top lane (never the screen middle, where the
	-- player and companion tags draw: p134 v57).
	return { toasts = toasts, banner = M.regions(width, height, topClear, touch).banner }
end

-- ---------------------------------------------------------------------------------------------
-- Runtime overlays (Roblox only; the layout above stays engine-free for Lune specs). One module
-- on purpose: the pack's QA-PERF-01 static budget counts every shipped ModuleScript.

-- Engine globals through the environment: this module is also loaded by Lune specs (standard
-- platform), where only the layout above runs.
local env: any = getfenv()
local game: any = env.game
local Instance: any, Enum: any, UDim: any, UDim2: any = env.Instance, env.Enum, env.UDim, env.UDim2
local Vector2: any, Vector3: any, CFrame: any, Color3: any = env.Vector2, env.Vector3, env.CFrame, env.Color3
local task: any = env.task
local ColorSequence: any, NumberSequence: any = env.ColorSequence, env.NumberSequence

local function color(c: any): any
	return Color3.fromRGB(c.r, c.g, c.b)
end
M.color = color

--- The pebble shape (spec section 3) on any GuiObject: fill, squircle corners and the driftwood rim.
--- Action tokens, gather fan outputs and the down-card icon badges all take their shape from here,
--- so the HUD speaks one token language (decision 9: our pebble, never a hex).
function M.pebbleShape(item: any, fill: any, transparency: number?)
	item.BackgroundTransparency = transparency or 0
	item.BackgroundColor3 = color(fill)
	local corner = item:FindFirstChild("PebbleCorner") or Instance.new("UICorner")
	corner.Name, corner.CornerRadius, corner.Parent = "PebbleCorner", UDim.new(M.PEBBLE.corner, 0), item
	for _, child in item:GetChildren() do
		if child:IsA("UICorner") and child ~= corner then
			child:Destroy()
		end
	end
	local rim = item:FindFirstChild("PebbleRim") or Instance.new("UIStroke")
	rim.Name, rim.Color, rim.Parent = "PebbleRim", color(M.PALETTE.drift), item
	rim.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rim.Thickness = math.max(2, math.floor(math.min(item.AbsoluteSize.X, item.AbsoluteSize.Y) * M.PEBBLE.rim + 0.5))
end

--- Styles a GuiButton as a pebble token: tealDeep fill (teal and ink glyph when active), a
--- driftwood rim 6% of the edge, squircle corners, bone label text.
function M.pebble(button: any, active: boolean?, enabled: boolean?)
	local P = M.PALETTE
	button.AutoButtonColor = false
	M.pebbleShape(
		button,
		if enabled == false then P.boneShade elseif active then P.teal else P.tealDeep,
		if enabled == false then 0.6 else 0
	)
	button.TextColor3 = color(if active then P.ink else P.bone)
	button.Font = Enum.Font.BuilderSans
end

-- HUD action token look (HUD polish, Durango R08-1 icon buttons): a round translucent disc with a
-- driftwood rim and a painted glyph, no text. `state`: "primary" (the big contextual action, teal
-- rim glow), "normal", or "disabled" (same disc, dimmed glyph and slate rim: reads as unavailable,
-- never as a broken grey blob).
M.TOKEN_STYLE = table.freeze({
	fill = { normal = 0.22, primary = 0.12, disabled = 0.5 },
	glyph = { normal = 0, primary = 0, disabled = 0.55 },
	glyphScale = 0.68,
})

--- Pure: the token look for a state (fill transparency, glyph transparency, rim colour key).
function M.tokenLook(state: string): { fill: number, glyph: number, rim: string, fillColor: string }
	local S = M.TOKEN_STYLE
	return {
		fill = S.fill[state] or S.fill.normal,
		glyph = S.glyph[state] or 0,
		rim = if state == "primary" then "tealPale" elseif state == "disabled" then "slateLock" else "drift",
		fillColor = if state == "primary" then "teal" else "panel",
	}
end

--- Styles a GuiButton as a round HUD icon token and sets its glyph image. With no image the
--- button keeps its text (the painted icon failed to resolve), so it is never a blank disc.
function M.iconToken(button: any, image: string?, state: string)
	local P = M.PALETTE
	local look = M.tokenLook(state)
	button.AutoButtonColor = false
	button.BackgroundColor3 = color((P :: any)[look.fillColor])
	button.BackgroundTransparency = look.fill
	for _, child in button:GetChildren() do
		if child:IsA("UIGradient") or (child:IsA("UICorner") and child.Name ~= "TokenCorner") then
			child:Destroy()
		end
	end
	local corner = button:FindFirstChild("TokenCorner") or Instance.new("UICorner")
	corner.Name, corner.CornerRadius, corner.Parent = "TokenCorner", UDim.new(0.5, 0), button
	local rim = button:FindFirstChild("PebbleRim")
		or button:FindFirstChildOfClass("UIStroke")
		or Instance.new("UIStroke")
	rim.Name, rim.Color, rim.Transparency, rim.Parent = "PebbleRim", color((P :: any)[look.rim]), 0, button
	rim.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rim.Thickness = if state == "primary" then 3 else 2
	local glyph = button:FindFirstChild("Glyph")
	if image and image ~= "" then
		if not glyph then
			glyph = Instance.new("ImageLabel")
			glyph.Name, glyph.BackgroundTransparency = "Glyph", 1
			glyph.AnchorPoint, glyph.Position = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
			glyph.ScaleType, glyph.Active, glyph.Parent = Enum.ScaleType.Fit, false, button
		end
		glyph.Size = UDim2.fromScale(M.TOKEN_STYLE.glyphScale, M.TOKEN_STYLE.glyphScale)
		glyph.Image, glyph.ImageTransparency, glyph.Visible = image, look.glyph, true
		glyph.ImageColor3 = if state == "disabled" then Color3.fromRGB(150, 150, 150) else Color3.new(1, 1, 1)
		button.TextTransparency = 1
	else
		if glyph then
			glyph.Visible = false
		end
		button.TextTransparency = if state == "disabled" then 0.45 else 0
		button.TextColor3 = color(if state == "primary" then P.ink else P.bone)
	end
	button.Font = Enum.Font.BuilderSansBold
end

-- D2c R04 hold-to-fill: a ProximityPrompt with a HoldDuration (the opening stakes' 1.2 s 'Pull')
-- completes from the primary token only while the token is held; a ring of dots around the token
-- fills with the hold. Ending the hold at exactly HoldDuration raced the prompt's own timer and the
-- prompt never fired (stakes stayed 0/3), so the hold ends only once Triggered has fired.
M.HOLD_RING = table.freeze({ dots = 24, dot = 6, gap = 5 })

--- Pure: hold progress 0..1 after `elapsed` seconds of a `duration` second hold (1 when no hold).
function M.holdProgress(elapsed: number, duration: number): number
	if duration <= 0 then
		return 1
	end
	return math.clamp(elapsed / duration, 0, 1)
end

--- Pure: how many of `dots` ring dots are lit at `progress` (0 none, all at 1).
function M.holdLit(progress: number, dots: number): number
	return math.clamp(math.floor(progress * dots + 1e-6), 0, dots)
end

--- Pure: centre offset of ring dot `index` (1-based, clockwise from 12 o'clock) for a `size` px
--- token; the ring sits `gap` px outside the token's rim.
function M.holdDot(index: number, dots: number, size: number): (number, number)
	local radius = size / 2 + M.HOLD_RING.gap
	local angle = (index - 1) / dots * 2 * math.pi
	return size / 2 + radius * math.sin(angle), size / 2 - radius * math.cos(angle)
end

--- Pure: the hold step. `hold` = { elapsed, duration, triggered, released }. "end" once the prompt
--- fired (complete), "cancel" on an early release, else "hold".
function M.holdStep(hold: { elapsed: number, duration: number, triggered: boolean, released: boolean }): string
	if hold.triggered then
		return "end"
	elseif hold.released then
		return "cancel"
	end
	return "hold"
end

--- The ring on a token: `HoldRing` with HOLD_RING.dots round dots around the button. Returns a
--- setter for the progress (0 hides the ring).
function M.holdRing(button: any): (number) -> ()
	local P = M.PALETTE
	local cfg = M.HOLD_RING
	local ring = button:FindFirstChild("HoldRing")
	if not ring then
		ring = Instance.new("Frame")
		ring.Name, ring.BackgroundTransparency, ring.Size, ring.Active = "HoldRing", 1, UDim2.fromScale(1, 1), false
		ring.ZIndex = button.ZIndex + 2
		for index = 1, cfg.dots do
			local dot = Instance.new("Frame")
			dot.Name, dot.BorderSizePixel, dot.AnchorPoint = "Dot" .. index, 0, Vector2.new(0.5, 0.5)
			dot.Size, dot.ZIndex = UDim2.fromOffset(cfg.dot, cfg.dot), ring.ZIndex
			local round = Instance.new("UICorner")
			round.CornerRadius, round.Parent = UDim.new(0.5, 0), dot
			dot.Parent = ring
		end
		ring.Parent = button
	end
	return function(progress: number)
		ring.Visible = progress > 0
		if progress <= 0 then
			return
		end
		local size = button.AbsoluteSize.X
		local lit = M.holdLit(progress, cfg.dots)
		for index = 1, cfg.dots do
			local dot = ring:FindFirstChild("Dot" .. index)
			local x, y = M.holdDot(index, cfg.dots, size)
			dot.Position = UDim2.fromOffset(x, y)
			dot.BackgroundColor3 = color(if index <= lit then P.tealPale else P.ink)
			dot.BackgroundTransparency = if index <= lit then 0 else 0.45
		end
	end
end

--- Caption pill beside a token (the primary action's contextual name, e.g. "Gather"): placed
--- left of `r`, vertically centred, in the token's ScreenGui space. Returns the caption label.
--- `others` (optional) are the rects the pill must not cover; see M.captionRect.
function M.tokenCaption(
	gui: any,
	name: string,
	r: Rect,
	text: string,
	size: number,
	others: { Rect }?,
	top: number?,
	cluster: Rect?
): any
	local P = M.PALETTE
	local label = gui:FindFirstChild(name)
	if not label then
		label = Instance.new("TextLabel")
		label.Name, label.BackgroundColor3, label.BackgroundTransparency = name, color(P.ink), 0.35
		label.TextColor3, label.Font = color(P.bone), Enum.Font.BuilderSansBold
		label.TextXAlignment = Enum.TextXAlignment.Center
		local round = Instance.new("UICorner")
		round.CornerRadius, round.Parent = UDim.new(0.5, 0), label
		label.Parent = gui
	end
	label.Text, label.TextSize = text, size
	local view = gui.AbsoluteSize
	local spot = M.captionRect(r, textWidth(text, size) + 20, size + 10, others or {}, view.X, view.Y, top, cluster)
	M.put(label, spot)
	label.Visible = text ~= ""
	return label
end

--- Coin chip (`coins`, a TextLabel `chip` px tall): the CoinIcon at the left, then the amount after
--- it. The label had no UIPadding, so the amount started at x=0 under the icon and the pill read as
--- empty (studio-after defect 2). Returns the left padding.
function M.coinChip(coins: any, chip: number): number
	local icon = coins:FindFirstChild("CoinIcon")
	local side = chip - 2
	local pad = coins:FindFirstChild("CoinPad")
	if not pad then
		pad = Instance.new("UIPadding")
		pad.Name, pad.Parent = "CoinPad", coins
	end
	local left = if icon then 4 + side + 4 else 10
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, left), UDim.new(0, 8)
	if icon then
		-- Padding does not move children positioned in offsets against the padded box, so the
		-- icon is placed back over the left padding.
		icon.AnchorPoint, icon.Position = Vector2.new(0, 0.5), UDim2.new(0, 4 - left, 0.5, 0)
		icon.Size = UDim2.fromOffset(side, side)
	end
	coins.TextXAlignment = Enum.TextXAlignment.Left
	coins.TextSize = math.max(13, chip - 12)
	return left
end

--- Quest-card text sizing: the card is as tall as its lines (capped at `limit` px, the quest slot),
--- at a fixed label size. A card sized to the whole slot with TextScaled capped at 15 px left a dark
--- box about 3x its two lines on PC (studio-after defect 13).
M.QUEST_TEXT = table.freeze({ touch = 13, pc = 15 })
function M.fitQuestText(label: any, limit: number?, touch: boolean)
	label.TextScaled, label.TextWrapped = false, true
	label.TextSize = if touch then M.QUEST_TEXT.touch else M.QUEST_TEXT.pc
	label.Size, label.AutomaticSize = UDim2.fromScale(1, 0), Enum.AutomaticSize.Y
	label.TextTruncate = Enum.TextTruncate.AtEnd
	for _, fit in label:GetChildren() do
		if fit.ClassName == "UITextSizeConstraint" then
			fit:Destroy()
		end
	end
	local cap = label:FindFirstChild("QuestCap")
	if not cap then
		cap = Instance.new("UISizeConstraint")
		cap.Name, cap.Parent = "QuestCap", label
	end
	cap.MaxSize = Vector2.new(math.huge, if limit and limit > 0 then limit else math.huge)
	local pad = label:FindFirstChildOfClass("UIPadding")
	if pad then
		pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
	end
end

--- Places a GuiObject at a rect given in the space of `frame`'s ScreenGui (offset by `origin`).
function M.put(item: any, r: Rect, origin: any?)
	local o = origin or Vector2.zero
	item.AnchorPoint = Vector2.zero
	item.Position = UDim2.fromOffset(r.x - o.X, r.y - o.Y)
	item.Size = UDim2.fromOffset(r.width, r.height)
end

-- Level badge portrait (Durango R05-1 / R08-1): the player's avatar headshot inside the level ring,
-- the level number on a small pip at the ring's foot. One thumbnail request per user id per client.
local headshots: { [number]: string } = {}
local headshotPending: { [number]: { any } } = {}

--- Turns the round level badge into a portrait ring: a round "Portrait" image (the painted
--- `fallback` until the headshot resolves, and for good if it never does) and a "LevelNumber" pip.
--- Returns the pip; the caller writes the level into its Text.
function M.levelPortrait(badge: any, players: any, userId: number, fallback: string?): any
	local P = M.PALETTE
	badge.Text, badge.TextTransparency = "", 1
	local portrait = badge:FindFirstChild("Portrait")
	if not portrait then
		portrait = Instance.new("ImageLabel")
		portrait.Name, portrait.BackgroundTransparency = "Portrait", 1
		portrait.AnchorPoint, portrait.Position = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
		portrait.Size, portrait.ScaleType = UDim2.fromScale(0.88, 0.88), Enum.ScaleType.Crop
		local round = Instance.new("UICorner")
		round.CornerRadius, round.Parent = UDim.new(0.5, 0), portrait
		portrait.Parent = badge
	end
	portrait.Image = headshots[userId] or fallback or ""
	local pip = badge:FindFirstChild("LevelNumber")
	if not pip then
		pip = Instance.new("TextLabel")
		pip.Name, pip.BackgroundColor3, pip.BackgroundTransparency = "LevelNumber", color(P.ink), 0.1
		pip.TextColor3, pip.Font = color(P.bone), Enum.Font.BuilderSansBold
		pip.AnchorPoint, pip.Position = Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, 2)
		pip.Size, pip.ZIndex = UDim2.fromScale(0.62, 0.36), portrait.ZIndex + 1
		local round = Instance.new("UICorner")
		round.CornerRadius, round.Parent = UDim.new(0.5, 0), pip
		local rim = Instance.new("UIStroke")
		rim.Color, rim.Thickness, rim.ApplyStrokeMode = color(P.ochre), 1, Enum.ApplyStrokeMode.Border
		rim.Parent = pip
		pip.Parent = badge
	end
	if headshots[userId] == nil and players ~= nil and userId > 0 then
		local waiting = headshotPending[userId]
		if waiting then
			table.insert(waiting, portrait)
		else
			headshotPending[userId] = { portrait }
			task.spawn(function()
				local ok, content = pcall(
					players.GetUserThumbnailAsync,
					players,
					userId,
					Enum.ThumbnailType.HeadShot,
					Enum.ThumbnailSize.Size150x150
				)
				local list = headshotPending[userId]
				headshotPending[userId] = nil
				if ok and type(content) == "string" and content ~= "" then
					headshots[userId] = content
					for _, image in list do
						image.Image = content
					end
				end
			end)
		end
	end
	return pip
end

--- Quest card toggle look: the quest (to-do) glyph while the card is collapsed (tap to show it), the
--- close glyph while it is shown (tap to hide it). `icon(id)` resolves a ui icon id to an image.
function M.questToggleLook(button: any, collapsed: boolean, icon: (string) -> string?)
	local id = M.TOKEN_ICONS[if collapsed then "quest" else "questHide"]
	M.iconToken(button, icon(id), "normal")
	button:SetAttribute("ForgeQuestCollapsed", collapsed)
	button:SetAttribute("ForgeIcon", id)
end

--- Lays a Components.modalSheet out as a full-screen panel (spec section 6): the frame covers the
--- safe area in the panel palette, the header becomes the title bar and the close button a pebble.
--- `origin` is the gui-space position of the frame's parent. The sheet's own scroll is hidden; the
--- caller places its columns at the layout's rects (relative to `layout.frame`).
function M.applyPanel(sheet: any, layout: PanelLayout, origin: any?)
	local P = M.PALETTE
	local frame = sheet.frame
	M.put(frame, layout.frame, origin)
	frame.BackgroundColor3, frame.BackgroundTransparency = color(P.panel), 0.06
	local header = frame:FindFirstChild("Header")
	if header then
		header.Size, header.BackgroundColor3 = UDim2.new(1, 0, 0, layout.bar.height), color(P.tealDeep)
		local title = header:FindFirstChild("Title")
		if title then
			M.put(title, layout.title, Vector2.new(layout.frame.x, layout.frame.y))
			title.TextSize, title.TextColor3 = layout.text.title, color(P.bone)
		end
	end
	M.put(sheet.close, layout.close, Vector2.new(layout.frame.x, layout.frame.y))
	sheet.close.TextSize = layout.text.heading
	M.pebble(sheet.close, false, true)
	sheet.scroll.Visible = false
end

--- Undoes applyPanel (Components.modalSheet geometry and the given theme colours) for sections of
--- the same sheet that stay a side sheet.
function M.restorePanel(sheet: any, colors: { panel: any, accent: any, close: any, titleSize: number })
	sheet.frame.BackgroundColor3, sheet.frame.BackgroundTransparency = colors.panel, 0
	local header = sheet.frame:FindFirstChild("Header")
	if header then
		header.Size, header.BackgroundColor3 = UDim2.new(1, 0, 0, 44), colors.accent
		local title = header:FindFirstChild("Title")
		if title then
			title.Position, title.Size = UDim2.fromOffset(14, 0), UDim2.new(1, -70, 1, 0)
			title.TextSize = colors.titleSize
		end
	end
	sheet.close.AnchorPoint, sheet.close.Position = Vector2.new(1, 0.5), UDim2.new(1, -6, 0.5, 0)
	sheet.close.Size, sheet.close.BackgroundColor3 = UDim2.fromOffset(44, 44), colors.close
	sheet.scroll.Visible = true
end

--- Panel button colours: the primary action is teal with ink text (bone on teal fails contrast),
--- every other control tealDeep with bone text; a selected row or tab reads teal too.
function M.panelButton(button: any, primary: boolean)
	local P = M.PALETTE
	button.BackgroundColor3 = color(if primary then P.teal else P.tealDeep)
	button.TextColor3 = color(if primary then P.ink else P.bone)
	button.Font = Enum.Font.BuilderSans
end

-- Sheet skin (lead review of U3: the bag / craft / skills / build sheets of SurvivalHUD on the same
-- shell as the docked sheets): the ui-kit Theme.sheet tokens (parchment body in a wood rim, leather
-- header, round close, ink rows left-aligned, item counts right-aligned, sea-glass buttons) and the
-- Theme.sheetText floors. Colours, alignment and text size only: every rect stays where the layout
-- (HudShell.panel / contextSheet, U4's Close row and notice lane) put it.
local SKIN_RIGHT = table.freeze({ RowCount = true, Quantity = true })

local function rgb(c: any): any
	return Color3.fromRGB(c.r, c.g, c.b)
end

--- Icon badges (IconFallback frames) on parchment: no dark filled square; a glyph draws in `ink`.
function M.skinIcon(badge: any, ink: any)
	badge.BackgroundTransparency = 1
	local glyph = badge:FindFirstChild("Glyph")
	if glyph then
		for _, part in glyph:GetChildren() do
			if part:IsA("Frame") then
				part.BackgroundColor3 = rgb(ink)
			end
		end
	end
end

export type SkinOptions = {
	-- Theme.sheet tokens and the current text sizes (Theme.sheetText for the gui's safe height).
	tokens: any,
	body: number,
	title: number,
	-- True for a selected row / tab or the primary action: sea-glass; other list rows are chips.
	selected: (any) -> boolean,
	-- Containers whose buttons are list rows (chip unless selected); other buttons are sea-glass.
	lists: { any },
}

--- Skins a Components.modalSheet frame (and everything in it) with the sheet tokens.
function M.skinSheet(frame: any, options: SkinOptions)
	local C = options.tokens.colors
	frame.BackgroundColor3, frame.BackgroundTransparency = rgb(C.body), 0
	local rim = frame:FindFirstChildOfClass("UIStroke")
	if rim then
		rim.Color, rim.Thickness = rgb(C.rim), 3
	end
	local shade = frame:FindFirstChildOfClass("UIGradient")
	if shade and ColorSequence then
		shade.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(232, 222, 204))
	end
	local header = frame:FindFirstChild("Header")
	if header then
		header.BackgroundColor3, header.BackgroundTransparency = rgb(C.header), 0
		local sheen = header:FindFirstChildOfClass("UIGradient")
		if sheen and ColorSequence then
			sheen.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(214, 204, 192))
		end
	end
	local function inList(item: any): boolean
		for _, list in options.lists do
			if item.Parent == list then
				return true
			end
		end
		return false
	end
	for _, item in frame:GetDescendants() do
		local class = item.ClassName
		if class == "Frame" and (item.Name == "IconFallback" or item.Name == "ShellIcon") then
			M.skinIcon(item, if header and item:IsDescendantOf(header) then C.headerText else C.ink)
		elseif class == "ScrollingFrame" then
			if item:GetAttribute("ForgeShellKeep") ~= true then
				item.ScrollBarImageColor3 = rgb(C.rim)
			end
		elseif class == "TextLabel" or class == "TextButton" then
			local stroke = item:FindFirstChildOfClass("UIStroke")
			if header and item:IsDescendantOf(header) and item:GetAttribute("ForgeShellKeep") == true then
				-- sheets4b: the build group tabs and the (?) toggle in the header keep their own look.
				continue
			end
			if header and item:IsDescendantOf(header) then
				item.TextScaled, item.TextSize = false, options.title
				item.TextColor3 = rgb(C.headerText)
				if item.Name == "Close" then
					item.BackgroundColor3 = rgb(C.close)
				else
					item.TextXAlignment = Enum.TextXAlignment.Left
				end
				continue
			end
			if item.Name == "Close" then
				-- The full-screen panel's close pebble sits on the frame (HudShell.applyPanel).
				item.TextScaled, item.TextSize = false, options.title
				item.BackgroundColor3, item.TextColor3 = rgb(C.close), rgb(C.headerText)
				continue
			end
			if item.Text ~= "" then
				-- Fixed sizes at the floor: TextScaled shrank rows to 10 px (D2b: ~9 px body text).
				item.TextScaled, item.TextWrapped = false, true
				item.TextSize = math.max(item.TextSize, options.body)
				local fit = item:FindFirstChildOfClass("UITextSizeConstraint")
				if fit then
					fit.MaxTextSize = math.max(fit.MaxTextSize, item.TextSize)
					fit.MinTextSize = math.min(fit.MaxTextSize, math.max(fit.MinTextSize, options.body))
				end
			end
			if class == "TextLabel" and item:GetAttribute("ForgeShellKeep") == true then
				-- sheets4: build-card names and green/red material counts keep their own ink (size floor only).
				continue
			end
			if stroke and class == "TextLabel" then
				-- Ink on parchment needs no halo.
				stroke.Transparency = 1
			end
			if class == "TextButton" then
				local enabled = item.Interactable ~= false and item.Active ~= false
				local chip = inList(item) and not options.selected(item)
				item.BackgroundTransparency = 0
				item.BackgroundColor3 = rgb(if not enabled then C.disabled elseif chip then C.chip else C.button)
				item.TextColor3 = rgb(if not enabled then C.disabledText elseif chip then C.ink else C.buttonText)
				if item:FindFirstChild("IconPadding") or inList(item) then
					-- A list row: icon (if any) left, then its text left-aligned beside it.
					item.TextXAlignment = Enum.TextXAlignment.Left
					if not item:FindFirstChild("IconPadding") then
						local pad = item:FindFirstChild("SkinPadding") or Instance.new("UIPadding")
						pad.Name, pad.PaddingLeft, pad.PaddingRight = "SkinPadding", UDim.new(0, 12), UDim.new(0, 8)
						pad.Parent = item
					end
				end
			else
				local parent = item.Parent
				local onButton = parent ~= nil and parent:IsA("TextButton")
				if SKIN_RIGHT[item.Name] then
					item.TextXAlignment = Enum.TextXAlignment.Right
				elseif item.Name == "Currency" then
					item.TextXAlignment = Enum.TextXAlignment.Center
				else
					item.TextXAlignment = Enum.TextXAlignment.Left
				end
				if item.Name == "Quantity" then
					-- Inventory cell count: an ink pill bottom-right of the cell, bone digits. One line: a
					-- wrapped "15" showed only "1" in the badge (p134 C1 bag2: 12 + 15 fiber read "1" and "1").
					item.TextWrapped = false
					item.BackgroundColor3, item.BackgroundTransparency = rgb(C.header), 0.05
					item.TextColor3 = rgb(C.headerText)
				elseif item.Name == "RowCount" and item.TextColor3 == Color3.fromRGB(255, 155, 132) then
					-- A short material count (materialRow colours it) stays a warning, in the close red.
					item.TextColor3 = rgb(C.close)
				elseif onButton and parent.BackgroundColor3 == rgb(C.button) then
					item.TextColor3 = rgb(C.buttonText)
				else
					item.TextColor3 = rgb(C.ink)
					if item.BackgroundTransparency < 1 then
						item.BackgroundColor3 = rgb(C.chip)
					end
				end
			end
		end
	end
end

--- Top-bar clearance for a ScreenGui. A CoreUISafeInsets gui already starts below the top bar, and
--- its AbsolutePosition still reads 0, so subtracting TopbarInset again pushed the whole shell down by
--- the bar height and shrank the safe height to ~295 px on the phone (staging v25: vitals overflow,
--- banner mid-screen, tiny menu label, the cluster cut at the bottom edge).
function M.guiClear(gui: any): number
	if Enum and gui.ScreenInsets == Enum.ScreenInsets.CoreUISafeInsets then
		return 0
	end
	-- Headless spec engines have no TopbarInset; there is no top bar to clear then.
	local inset = game:GetService("GuiService").TopbarInset
	return if inset then M.topClear(inset.Max.Y, gui.AbsolutePosition.Y) else 0
end

--- First gui row that receives presses: GuiService.TopbarInset.Max.Y in the gui's space, also for a
--- CoreUISafeInsets gui. Layout keeps using guiClear (no double inset); only hit targets clear this.
--- U6 probes: the dead strip is the PC player list; a touch CoreUISafeInsets gui has none.
function M.hitClear(gui: any): number
	if
		Enum
		and gui.ScreenInsets == Enum.ScreenInsets.CoreUISafeInsets
		and game:GetService("UserInputService").TouchEnabled
	then
		return 0
	end
	local inset = game:GetService("GuiService").TopbarInset
	return if inset then M.topClear(inset.Max.Y, gui.AbsolutePosition.Y) else 0
end

--- Token caption size: the spec type scale, but never under 13 px on a touch screen (the 10 px
--- caption on the phone row read as unreadable, staging v25).
function M.tokenText(style: string, safeHeight: number, touch: boolean): number
	local size = M.textSize(style, safeHeight)
	return if touch then math.max(13, size) else size
end

--- Player name tag text sizes (spec section 5 player ring: name `label`, clan tag `caption`). On a
--- touch screen the name keeps one px over the 13 px floor so it still reads above the clan tag.
function M.nameTag(safeHeight: number, touch: boolean): { name: number, tribe: number, width: number, height: number }
	local tribe = M.tokenText("caption", safeHeight, touch)
	local name = math.max(M.tokenText("label", safeHeight, touch), tribe + 1)
	return { name = name, tribe = tribe, width = name * 16, height = name + tribe + 6 }
end

--- A dock or departure post part a pack marked with its destination role (world label kind "dock").
M.DESTINATION_ATTRIBUTE = "ForgeDestination"

export type OverlayOptions = {
	gui: any,
	hidden: () -> boolean,
	-- Localized label text for a world entity of `kind` keyed by `key`, or nil to skip it.
	name: (string, string) -> string?,
	coordsText: (number, number) -> string,
	-- Own clan tag text ("" hides the line).
	tribe: () -> string,
	-- Another player's clan tag text, or nil/"" for none. Optional: without it others show their name only.
	tribeOf: ((any) -> string?)?,
	-- Small second label line under a world label (`kind`, labelled instance), e.g. a gather node's
	-- tool hint ("Lv 1 . by hand"). Optional: nil or "" shows the name alone.
	hint: ((string, any) -> string?)?,
	-- The instance the player is acting on (combat target, highlighted gather node), or nil. Its label
	-- wins every declutter conflict. Optional.
	focus: (() -> any?)?,
}

-- CollectionService tag on world name tags the contextual banner must never cover (player tags,
-- pet labels, a pack's companion plate): SurvivalHUD steers the banner around their screen rects.
M.NAME_TAG = "ForgeNameTag"
-- CollectionService tag on a pack's HUD pill (the drift-isle timer): the banner steers around it too
-- (p134 v74 #11: the hunger line sat under the '표류섬 남은 시간' pill).
M.HUD_PILL_TAG = "ForgeHudPill"
-- Player name plate (D2 R16): ink plate transparency behind the name, the name's ink stroke
-- transparency and the plate's side padding in px.
M.NAME_PLATE = table.freeze({ plate = 0.35, stroke = 0, pad = 6 })

-- Tags a pack/server sets on a ground drop or a deployed pet so it gets a label.
M.DROP_TAG, M.PET_TAG = "ForgeWorldDrop", "ForgeWorldPet"
-- Set on the local player (CombatHud) to the engaged creature's ForgeWildlifeId: its label is the focus.
M.COMBAT_TARGET_ATTRIBUTE = "ForgeCombatTargetId"

local function anchorOf(instance: any): any
	if instance:IsA("BasePart") then
		return instance
	elseif instance:IsA("Model") then
		local root = instance:FindFirstChild("HumanoidRootPart") or instance.PrimaryPart
		return if root and root:IsA("BasePart") then root else nil
	end
	return nil
end

--- Label candidates in the world: { instance, kind, key }.
function M.collect(world: any, tags: any): { { any } }
	local out: { { any } } = {}
	for _, part in tags:GetTagged("ForgeSurvivalNode") do
		if part:GetAttribute("ForgeNodeDepleted") ~= true then
			table.insert(
				out,
				{ part, "node", part:GetAttribute("ForgeNodeKind") or part:GetAttribute("ForgeNodeItem") }
			)
		end
	end
	for _, part in tags:GetTagged("ForgeSurvivalStation") do
		table.insert(out, { part, "station", part:GetAttribute("ForgeStationKind") })
	end
	for _, item in tags:GetTagged(M.DROP_TAG) do
		-- A death-bundle marker names its owner ("owner:<name>"); other drops keep their item key.
		local owner = item:GetAttribute("ForgeDropOwner")
		table.insert(out, {
			item,
			"drop",
			if type(owner) == "string" then "owner:" .. owner else item:GetAttribute("ForgeItemId") or "drop",
		})
	end
	for _, item in tags:GetTagged(M.PET_TAG) do
		table.insert(out, { item, "pet", item:GetAttribute("ForgeSpecies") })
	end
	for _, item in world:GetDescendants() do
		local facility = item:GetAttribute("ForgeHarborFacility")
		local destination = item:GetAttribute(M.DESTINATION_ATTRIBUTE)
		if type(facility) == "string" and string.sub(facility, 1, 4) == "npc." then
			table.insert(out, { item, "npc", facility })
		elseif type(destination) == "string" and item:IsA("BasePart") then
			table.insert(out, { item, "dock", destination })
		elseif item:IsA("Model") and item.Name == "ForgeMount" then
			table.insert(out, { item, "pet", item:GetAttribute("ForgeMountSpecies") })
		end
	end
	local wildlife = world:FindFirstChild("ForgeWildlife")
	for _, animal in if wildlife then wildlife:GetChildren() else {} do
		if animal:GetAttribute("ForgeWildlifeState") ~= "captured" then
			table.insert(out, { animal, "wildlife", animal:GetAttribute("ForgeWildlifeKind") })
		end
	end
	return out
end

--- Minimap + XY readout (in options.gui), world labels and the player ring. Returns a destroyer.
-- HUD ScreenGuis that never count as a full sheet.
M.HUD_GUIS = table.freeze({ ForgeSurvivalHUD = true, ForgePanelDock = true, ForgePlacementHUD = true })

-- True when another ScreenGui shows a full sheet (Components.modalSheet shape: a visible Frame
-- with Header > Close, directly or one level under the gui). Catches sheets the dock does not
-- own, e.g. the survivor picker, so the HUD regions hide instead of drawing over them.
function M.sheetOpen(playerGui: any): boolean
	return M.openSheet(playerGui) ~= nil
end

--- The first full sheet frame another ScreenGui shows (see sheetOpen), or nil.
function M.openSheet(playerGui: any): any
	if not playerGui then
		return nil
	end
	local function sheet(item: any): boolean
		if item.ClassName ~= "Frame" or not item.Visible then
			return false
		end
		local header = item:FindFirstChild("Header")
		return header ~= nil and header:FindFirstChild("Close") ~= nil
	end
	for _, gui in playerGui:GetChildren() do
		if gui.ClassName == "ScreenGui" and gui.Enabled and not M.HUD_GUIS[gui.Name] then
			for _, child in gui:GetChildren() do
				if sheet(child) then
					return child
				end
				if child.ClassName == "Frame" and child.Visible then
					for _, inner in child:GetChildren() do
						if sheet(inner) then
							return inner
						end
					end
				end
			end
		end
	end
	return nil
end

--- Rect of a corner button (`width` x `height`, wanted at the gui's top right) that never covers an
--- open sheet `sheet` (gui space, or nil): beside the sheet in the right gutter, narrowed down to
--- `minWidth`, else under the sheet's header row (`header` px) on the gutter edge. Studio-after
--- defect 4: the cold open's Skip sat on the arrival sheet's close X.
function M.cornerButton(
	guiWidth: number,
	guiHeight: number,
	width: number,
	height: number,
	sheet: Rect?,
	minWidth: number,
	header: number
): Rect
	local edge = 12
	local y = math.floor(guiHeight * 0.1 + 0.5)
	local wanted = rect(guiWidth - edge - width, y, width, height)
	if not sheet or not hits(wanted, sheet, 4) then
		return wanted
	end
	local right = sheet.x + sheet.width
	local room = guiWidth - right - 2 * 4
	if room >= minWidth then
		local w = math.min(width, room)
		return rect(right + 4 + (room - w) / 2, math.max(y, sheet.y + header + 4), w, height)
	end
	local left = sheet.x - 2 * 4
	if left >= minWidth then
		local w = math.min(width, left)
		return rect(sheet.x - 4 - w, math.max(y, sheet.y + header + 4), w, height)
	end
	-- No gutter: the bottom-right corner of the sheet body, clear of its header and close.
	return rect(right - edge - width, sheet.y + sheet.height - edge - height, width, height)
end

function M.startOverlays(options: OverlayOptions): () -> ()
	local players = game:GetService("Players")
	local tags = game:GetService("CollectionService")
	local world = game:GetService("Workspace")
	local run = game:GetService("RunService")
	local player = players.LocalPlayer
	local P = M.PALETTE
	local connections: { any } = {}
	-- Minimap: round, tealDeep sea with a tealPale wash, in a framed bezel (HUD polish, Durango
	-- R08-1): a dark outer ring behind the map, a driftwood rim and a north pip. Style only; the
	-- map's placement and orientation stay below.
	local bezel = Instance.new("Frame")
	bezel.Name, bezel.BackgroundColor3, bezel.BackgroundTransparency = "MinimapFrame", color(P.ink), 0.25
	bezel.AnchorPoint, bezel.Parent = Vector2.new(0.5, 0.5), options.gui
	local bezelCorner = Instance.new("UICorner")
	bezelCorner.CornerRadius, bezelCorner.Parent = UDim.new(0.5, 0), bezel
	local bezelRim = Instance.new("UIStroke")
	bezelRim.Color, bezelRim.Thickness, bezelRim.Transparency, bezelRim.Parent = color(P.driftDark), 1.5, 0.2, bezel
	local north = Instance.new("TextLabel")
	north.Name, north.BackgroundColor3, north.BackgroundTransparency = "North", color(P.coral), 0
	north.Text, north.TextColor3, north.Font = "N", color(P.bone), Enum.Font.BuilderSansBold
	north.AnchorPoint, north.Position = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0)
	north.Size, north.ZIndex, north.Parent = UDim2.fromOffset(16, 16), 4, bezel
	local northRound = Instance.new("UICorner")
	northRound.CornerRadius, northRound.Parent = UDim.new(0.5, 0), north
	local map = Instance.new("Frame")
	map.Name, map.BackgroundColor3, map.BackgroundTransparency = "Minimap", color(P.tealDeep), 0.1
	map.ClipsDescendants, map.Parent = true, options.gui
	local mapCorner = Instance.new("UICorner")
	mapCorner.CornerRadius, mapCorner.Parent = UDim.new(0.5, 0), map
	local mapRim = Instance.new("UIStroke")
	mapRim.Color, mapRim.Thickness, mapRim.Parent = color(P.driftPale), 2.5, map
	local wash = Instance.new("UIGradient")
	wash.Color = ColorSequence.new(color(P.tealDeep), color(P.tealPale))
	wash.Transparency = NumberSequence.new(0, 0.55)
	wash.Rotation, wash.Parent = 90, map
	local arrow = Instance.new("TextLabel")
	arrow.Name, arrow.BackgroundTransparency, arrow.Text = "Self", 1, "\u{25B2}"
	arrow.AnchorPoint, arrow.Position = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
	arrow.Size, arrow.TextColor3, arrow.Font = UDim2.fromOffset(20, 20), color(P.bone), Enum.Font.BuilderSansBold
	arrow.TextSize, arrow.ZIndex, arrow.Parent = 16, 3, map
	arrow.TextStrokeColor3, arrow.TextStrokeTransparency = color(P.ink), 0.2
	local coords = Instance.new("TextLabel")
	coords.Name, coords.BackgroundColor3, coords.BackgroundTransparency = "Coordinates", color(P.ink), 0.45
	coords.TextColor3, coords.Font, coords.Text = color(P.boneShade), Enum.Font.BuilderSans, ""
	coords.Parent = options.gui
	local pill = Instance.new("UICorner")
	pill.CornerRadius, pill.Parent = UDim.new(0.5, 0), coords
	local dots: { any } = {}
	local used = 0
	local function dot(x: number, y: number, tint: any, size: number)
		used += 1
		local item = dots[used]
		if not item then
			item = Instance.new("Frame")
			item.Name, item.BorderSizePixel, item.AnchorPoint = "Dot", 0, Vector2.new(0.5, 0.5)
			local round = Instance.new("UICorner")
			round.CornerRadius, round.Parent = UDim.new(0.5, 0), item
			item.ZIndex, item.Parent = 2, map
			dots[used] = item
		end
		item.Position, item.Size = UDim2.fromOffset(x, y), UDim2.fromOffset(size, size)
		item.BackgroundColor3, item.Visible = color(tint), true
	end
	-- World labels: pooled BillboardGuis in PlayerGui. On respawn Roblox deletes every PlayerGui child
	-- that is not a LayerCollector, so a Folder here took the whole pool (and the rings) with it and the
	-- cached boards had no "Text" left (staging v38: HudShell:1129 every heartbeat). A ScreenGui that
	-- does not reset survives; a nested BillboardGui still renders in the world.
	local labelFolder = Instance.new("ScreenGui")
	labelFolder.Name, labelFolder.ResetOnSpawn = "ForgeWorldLabels", false
	labelFolder.Parent = player:WaitForChild("PlayerGui")
	local boards: { any } = {}
	local function board(index: number): any
		local existing = boards[index]
		if
			existing
			and existing.Parent == labelFolder
			and existing:FindFirstChild("Text")
			and existing:FindFirstChild("Hint")
		then
			return existing
		elseif existing then
			existing:Destroy()
		end
		local B = M.LABEL_BOARD
		local item = Instance.new("BillboardGui")
		item.Name, item.Size, item.AlwaysOnTop = "WorldLabel", UDim2.fromOffset(B.width, B.height), false
		item.StudsOffsetWorldSpace, item.LightInfluence = Vector3.new(0, B.base, 0), 0
		item.MaxDistance = M.LABEL_DRAW_DISTANCE
		-- R05-1: floating white text with a dark stroke, no plate (the old ink pill read as UI chrome).
		local text = Instance.new("TextLabel")
		text.Name, text.BackgroundTransparency = "Text", 1
		text.Size = UDim2.new(1, 0, 0, B.name + 6)
		text.Font, text.TextSize = Enum.Font.BuilderSansBold, B.name
		text.TextStrokeColor3, text.TextStrokeTransparency = color(P.ink), 0.25
		local hint = Instance.new("TextLabel")
		hint.Name, hint.BackgroundTransparency = "Hint", 1
		hint.Position, hint.Size = UDim2.fromOffset(0, B.name + 4), UDim2.new(1, 0, 0, B.hint + 4)
		hint.Font, hint.TextSize, hint.TextColor3 = Enum.Font.BuilderSansMedium, B.hint, color(P.boneShade)
		hint.TextStrokeColor3, hint.TextStrokeTransparency, hint.Visible = color(P.ink), 0.35, false
		text.Parent, hint.Parent, item.Parent = item, item, labelFolder
		boards[index] = item
		return item
	end
	-- Player rings: own ring (teal) with a 50 degree facing fan and name / tribe tag under it;
	-- other players get a 30% ring and their name only. Handle adornments are client-only.
	local ringFolder = Instance.new("Folder")
	ringFolder.Name, ringFolder.Parent = "ForgePlayerRings", labelFolder
	local touch = game:GetService("UserInputService").TouchEnabled
	local tagSize = M.nameTag(360, touch)
	local rings: { [any]: any } = {}
	local function ringFor(owner: any): any
		local entry = rings[owner]
		if entry and entry.ring.Parent == ringFolder and entry.tag.Parent == ringFolder then
			return entry
		end
		local own = owner == player
		local ring = Instance.new("CylinderHandleAdornment")
		ring.Name, ring.Radius, ring.InnerRadius, ring.Height = "Ring", M.RING.radius, M.RING.radius - 0.22, 0.06
		ring.Color3, ring.Transparency = color(P.teal), if own then 0.1 else 1 - M.RING.otherAlpha
		ring.Parent = ringFolder
		local fan: { any } = {}
		if own then
			local reach = M.RING.radius * M.RING.wedgeReach
			for step = 0, 8 do
				local spoke = Instance.new("BoxHandleAdornment")
				spoke.Name, spoke.Size = "Facing", Vector3.new(0.35, 0.04, reach)
				spoke.Color3, spoke.Transparency = color(P.teal), 1 - M.RING.wedgeAlpha
				spoke:SetAttribute("Angle", -M.RING.wedgeDegrees / 2 + step * M.RING.wedgeDegrees / 8)
				spoke.Parent = ringFolder
				table.insert(fan, spoke)
			end
		end
		local tag = Instance.new("BillboardGui")
		tag.Name, tag.Size, tag.AlwaysOnTop, tag.LightInfluence = "NameTag", UDim2.fromOffset(220, 40), true, 0
		tag:AddTag(M.NAME_TAG)
		tag.Parent = ringFolder
		-- D2 R16 (v68): the bone name with a 0.4 stroke was faint on grass and sand. The name sits on an
		-- ink plate sized to its text (M.NAME_PLATE) under a solid ink stroke.
		local nameLine = Instance.new("TextLabel")
		nameLine.Name, nameLine.Size = "Name", UDim2.fromOffset(0, 22)
		nameLine.AutomaticSize, nameLine.AnchorPoint = Enum.AutomaticSize.X, Vector2.new(0.5, 0)
		nameLine.Position = UDim2.fromScale(0.5, 0)
		nameLine.BackgroundColor3 = color(P.ink)
		nameLine.BackgroundTransparency = M.NAME_PLATE.plate
		nameLine.TextColor3, nameLine.Font, nameLine.TextSize = color(P.bone), Enum.Font.BuilderSansBold, 16
		nameLine.TextStrokeColor3, nameLine.TextStrokeTransparency = color(P.ink), M.NAME_PLATE.stroke
		nameLine.Parent = tag
		local namePad = Instance.new("UIPadding")
		namePad.PaddingLeft, namePad.PaddingRight = UDim.new(0, M.NAME_PLATE.pad), UDim.new(0, M.NAME_PLATE.pad)
		namePad.Parent = nameLine
		local nameCorner = Instance.new("UICorner")
		nameCorner.CornerRadius, nameCorner.Parent = UDim.new(0, 6), nameLine
		local tribeLine = Instance.new("TextLabel")
		tribeLine.Name, tribeLine.BackgroundTransparency = "Tribe", 1
		tribeLine.Position, tribeLine.Size = UDim2.fromOffset(0, 22), UDim2.new(1, 0, 0, 16)
		tribeLine.TextColor3, tribeLine.Font, tribeLine.TextSize = color(P.tealPale), Enum.Font.BuilderSans, 13
		tribeLine.TextStrokeTransparency, tribeLine.Visible, tribeLine.Parent = 0.5, false, tag
		entry = { ring = ring, fan = fan, tag = tag, name = nameLine, tribe = tribeLine, sized = 0 }
		rings[owner] = entry
		return entry
	end
	local function dropRing(owner: any)
		local entry = rings[owner]
		if entry then
			entry.ring:Destroy()
			entry.tag:Destroy()
			for _, spoke in entry.fan do
				spoke:Destroy()
			end
			rings[owner] = nil
		end
	end
	table.insert(connections, players.PlayerRemoving:Connect(dropRing))
	-- Prompt cards (labels2 fix 5): Roblox draws a shown ProximityPrompt's card as a BillboardGui under
	-- PlayerGui.ProximityPrompts; a gather node at the feet put '고사리 섬유 / 채집하기' over the own name tag
	-- (p134 v63 cs1). The card cannot move off its node, so the own tag hides while a drawn card covers it
	-- (`tagCovered`, set by the label heartbeat). Only drawn cards count: a Custom prompt draws none.
	local tagCovered = false
	local elapsed = 0
	-- Respawn (labels2 fix 4): the new character starts a fresh label pass at once, so no board keeps
	-- the old body's placement and companion plates re-enter the overlap pass on the first frame.
	local function rebuild()
		for _, item in boards do
			item.Enabled, item.SizeOffset = false, Vector2.zero
		end
		tagCovered = false
		elapsed = math.huge
	end
	if player.CharacterAdded then
		table.insert(connections, player.CharacterAdded:Connect(rebuild))
	end
	table.insert(
		connections,
		run.RenderStepped:Connect(function()
			local hidden = options.hidden()
			for _, owner in players:GetPlayers() do
				local character = owner.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				local entry = ringFor(owner)
				local alive = not hidden
					and root ~= nil
					and root:IsA("BasePart")
					and humanoid ~= nil
					and humanoid.Health > 0
				entry.ring.Visible, entry.tag.Enabled = alive, alive and not (owner == player and tagCovered)
				for _, spoke in entry.fan do
					spoke.Visible = alive
				end
				if alive and root and humanoid and root:IsA("BasePart") then
					local down = -(humanoid.HipHeight + root.Size.Y / 2) + 0.08
					entry.ring.Adornee, entry.tag.Adornee = root, root
					entry.ring.CFrame = CFrame.new(0, down, 0) * CFrame.Angles(math.rad(90), 0, 0)
					local reach = M.RING.radius * M.RING.wedgeReach
					for _, spoke in entry.fan do
						spoke.Adornee = root
						spoke.CFrame = CFrame.new(0, down + 0.03, 0)
							* CFrame.Angles(0, math.rad(spoke:GetAttribute("Angle") :: number), 0)
							* CFrame.new(0, 0, -reach / 2)
					end
					entry.tag.StudsOffsetWorldSpace = Vector3.new(0, down - 1.1, 0)
					entry.name.Text = owner.DisplayName
					-- G22: every tag carries the clan line (own: "No clan" too; others: only when in one).
					local tribe = if owner == player
						then options.tribe()
						elseif options.tribeOf then options.tribeOf(owner) or ""
						else ""
					entry.tribe.Text, entry.tribe.Visible = tribe, tribe ~= ""
					if entry.sized ~= tagSize.name then
						entry.sized = tagSize.name
						entry.tag.Size = UDim2.fromOffset(tagSize.width, tagSize.height)
						entry.name.Size = UDim2.fromOffset(0, tagSize.name + 4)
						entry.name.TextSize = tagSize.name
						entry.tribe.Position = UDim2.fromOffset(0, tagSize.name + 4)
						entry.tribe.Size = UDim2.new(1, 0, 0, tagSize.tribe + 2)
						entry.tribe.TextSize = tagSize.tribe
					end
				end
			end
		end)
	)
	table.insert(
		connections,
		run.Heartbeat:Connect(function(dt)
			elapsed += dt
			if elapsed < 0.2 then
				return
			end
			elapsed = 0
			local size = options.gui.AbsoluteSize
			local regions = M.regions(size.X, size.Y, M.guiClear(options.gui), touch)
			M.put(map, regions.minimap)
			local mm = regions.minimap
			bezel.Position = UDim2.fromOffset(mm.x + mm.width / 2, mm.y + mm.height / 2)
			bezel.Size = UDim2.fromOffset(mm.width + 10, mm.height + 10)
			M.put(coords, regions.coords)
			coords.TextSize = M.textSize("caption", regions.safeHeight)
			tagSize = M.nameTag(regions.safeHeight, touch)
			local hidden = options.hidden()
			map.Visible, coords.Visible, bezel.Visible = not hidden, not hidden, not hidden
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			used = 0
			local shown = 0
			if root and root:IsA("BasePart") and not hidden then
				local origin = root.Position
				local look = root.CFrame.LookVector
				local camera = world.CurrentCamera
				local view = if camera then camera.CFrame.LookVector else Vector3.new(0, 0, -1)
				-- The facing arrow in the camera-aligned map frame (up = where the camera looks).
				local ax, ay = M.mapPoint(look.X * 10, look.Z * 10, 2, 40, view.X, view.Z)
				arrow.Rotation = if ax and ay then math.deg(math.atan2(ax - 1, -(ay - 1))) else 0
				coords.Text = options.coordsText(M.coords(origin.X, origin.Z))
				local side = regions.minimap.width
				local candidates: { Candidate } = {}
				local lookup: { [string]: { any } } = {}
				for index, entry in M.collect(world, tags) do
					local anchor = anchorOf(entry[1])
					if anchor then
						local at = anchor.Position
						local x, y = M.mapPoint(at.X - origin.X, at.Z - origin.Z, side, nil, view.X, view.Z)
						if x and y then
							local tint = if entry[2] == "node"
								then P.moss
								elseif entry[2] == "wildlife" then P.coral
								elseif entry[2] == "drop" then P.ochre
								else P.driftPale
							dot(x, y, tint, if entry[2] == "node" then 5 else 7)
						end
						local text = if type(entry[3]) == "string" then options.name(entry[2], entry[3]) else nil
						if text then
							local id = string.format("%s:%06d", entry[2], index)
							lookup[id] = { anchor, text, entry[2], entry[1] }
							table.insert(candidates, { id = id, kind = entry[2], x = at.X, y = at.Y, z = at.Z })
						end
					end
				end
				for _, other in players:GetPlayers() do
					local body = other ~= player and other.Character
					local at = body and body:FindFirstChild("HumanoidRootPart")
					if at and at:IsA("BasePart") then
						local x, y =
							M.mapPoint(at.Position.X - origin.X, at.Position.Z - origin.Z, side, nil, view.X, view.Z)
						if x and y then
							dot(x, y, P.bone, 7)
						end
					end
				end
				local full: string? = nil
				local focus = if options.focus then options.focus() else nil
				local targets = M.labelTargets(candidates, origin.X, origin.Y, origin.Z)
				local focused: { [string]: boolean } = {}
				for _, target in targets do
					local holder = lookup[target.id][1]
					if focus ~= nil and (holder == focus or holder.Parent == focus) then
						focused[target.id] = true
						full = full or target.id
					end
				end
				-- A flock is one label '도도 ×5' (M.flocks); the focus creature keeps its own. A herd
				-- (ForgeHerdId, WildlifeWorld) is always one label.
				local texts: { [string]: string } = {}
				local herdIds: { [string]: string } = {}
				for _, target in targets do
					local entry = lookup[target.id]
					texts[target.id] = entry[2]
					local herd = if entry[3] == "wildlife" then entry[4]:GetAttribute("ForgeHerdId") else nil
					if type(herd) == "string" then
						herdIds[target.id] = herd
					end
				end
				local counts: { [string]: number }
				targets, counts = M.flocks(targets, texts, focused, herdIds)
				for _, target in targets do
					texts[target.id] = M.flockText(texts[target.id], counts[target.id])
				end
				-- The focus label shows in full (name + tool hint); without one, the nearest node does.
				if not full then
					for _, target in targets do
						if target.kind == "node" then
							full = target.id
							break
						end
					end
				end
				local inset = if camera then options.gui.AbsolutePosition else Vector2.zero
				-- Screen rects labels must stay off: the local player's figure and own plate, and every other
				-- shown name tag (other players, the companion plate).
				local avoid: { Rect } = {}
				local fixed: { LabelItem } = {}
				local plates = 0
				local own = rings[player]
				if camera then
					if own and (own.tag.Enabled or tagCovered) then
						-- The own plate (ringFor) rides under the feet; the rect spans it up to the head.
						local head = character:FindFirstChild("Head")
						local top = if head and head:IsA("BasePart")
							then head.Position + Vector3.new(0, head.Size.Y / 2, 0)
							else origin + Vector3.new(0, 3, 0)
						local a, seenA = camera:WorldToScreenPoint(top)
						local b, seenB = camera:WorldToScreenPoint(origin + own.tag.StudsOffsetWorldSpace)
						if seenA or seenB then
							table.insert(
								avoid,
								M.playerRect(
									{ x = a.X - inset.X, y = a.Y - inset.Y },
									{ x = b.X - inset.X, y = b.Y - inset.Y },
									tostring(player.DisplayName or ""),
									tagSize.name
								)
							)
						end
						-- Fix 5: the own tag yields while a drawn Roblox prompt card covers it.
						local cards: { Rect } = {}
						local promptGui = labelFolder.Parent and labelFolder.Parent:FindFirstChild("ProximityPrompts")
						for _, card in if promptGui then promptGui:GetDescendants() else {} do
							local holder = if card:IsA("BillboardGui") and card.Enabled then card.Adornee else nil
							local at = if holder and holder:IsA("Attachment")
								then holder.WorldPosition
								elseif holder and holder:IsA("BasePart") then holder.Position
								else nil
							if at then
								local box = M.tagRect(camera, card, { Position = at }, inset)
								if box then
									table.insert(cards, box)
								end
							end
						end
						tagCovered = seenB
							and M.tagCovered(
								rect(
									b.X - inset.X - tagSize.width / 2,
									b.Y - inset.Y - tagSize.height / 2,
									tagSize.width,
									tagSize.height
								),
								cards
							)
						if tagCovered then
							own.tag.Enabled = false
						end
						labelFolder:SetAttribute("ForgeTagCovered", tagCovered)
					end
					for _, tag in tags:GetTagged(M.NAME_TAG) do
						local adornee = if tag:IsA("BillboardGui") then (tag.Adornee or tag.Parent) else nil
						if
							tag.Enabled
							and tag.Parent ~= labelFolder
							and not (own and tag == own.tag)
							and adornee
							and adornee:IsA("BasePart")
						then
							local box = M.tagRect(camera, tag, adornee, inset)
							if box and tag.Parent == ringFolder then
								table.insert(avoid, box)
							elseif
								box
								and box.x < size.X
								and box.x + box.width > 0
								and box.y < size.Y
								and box.y + box.height > 0
							then
								-- A pet / companion plate another script draws (OpeningClient's '텀블 (동료)'): a label
								-- in the same overlap pass and cap, placed first since it cannot move (labels2).
								plates += 1
								table.insert(fixed, {
									id = string.format("plate:%03d", plates),
									kind = "pet",
									rect = box,
									distance = 0,
									fixed = true,
								})
							end
						end
					end
				end
				-- Screen rect of every candidate label, then the declutter pass (M.declutter): priority, a few
				-- px of nudge, else hidden; never over the HUD (LABEL_BLOCKERS) or the player; capped.
				local items: { LabelItem } = {}
				local lines: { [string]: string? } = {}
				local order: { string } = {}
				for index, target in targets do
					local entry = lookup[target.id]
					local line = if target.id == full
							and entry[3] == "node"
							and options.hint
						then options.hint("node", entry[1])
						else nil
					lines[target.id] = line
					if camera then
						-- WorldToScreenPoint, not WorldToViewportPoint: AbsolutePosition is measured below the
						-- top bar (GuiInset), so a viewport point tested every label 58 px (phone) / 36 px (PC)
						-- under where it draws and labels through the vitals, the quest toggle and hotbar
						-- slot 1 passed the check (p134 v60 lb4).
						local lift = M.labelLift(entry[1])
						local point, visible = camera:WorldToScreenPoint(entry[1].Position + Vector3.new(0, lift, 0))
						if visible then
							local dx, dy = target.x - origin.X, target.z - origin.Z
							table.insert(items, {
								id = target.id,
								kind = target.kind,
								rect = M.labelRect(point.X - inset.X, point.Y - inset.Y, texts[target.id], line),
								distance = math.sqrt(dx * dx + dy * dy) + index * 1e-6,
								target = focused[target.id],
							})
						end
					else
						table.insert(order, target.id)
					end
				end
				local cap = M.labelCap(regions.safeHeight)
				local placed: { { id: string, dx: number, dy: number } } = {}
				if camera then
					-- The Roblox top bar buttons (GuiService:GetGuiInset / TopbarInset) block like the HUD.
					local viewport = camera.ViewportSize
					local core = M.coreBlockers(
						options.gui,
						game:GetService("GuiService"),
						if viewport then viewport.X else size.X
					)
					table.move(fixed, 1, #fixed, #items + 1, items)
					placed = M.declutter(items, avoid, cap, function(r: Rect): boolean
						return M.labelBlocked(r, regions, core)
					end)
				else
					for index = 1, math.min(cap, #order) do
						table.insert(placed, { id = order[index], dx = 0, dy = 0 })
					end
				end
				labelFolder:SetAttribute("ForgePlateCount", #fixed)
				for _, slot in placed do
					local entry = lookup[slot.id]
					if not entry then
						-- A fixed plate (another script's companion label): counted, never drawn here.
						continue
					end
					local lift = M.labelLift(entry[1])
					local line = lines[slot.id]
					shown += 1
					local item = board(shown)
					item.Adornee, item.Enabled = entry[1], true
					item.StudsOffsetWorldSpace = Vector3.new(0, lift, 0)
					-- The nudge, in board sizes (SizeOffset +X moves the board right, +Y up the screen).
					item.SizeOffset = Vector2.new(slot.dx / M.LABEL_BOARD.width, -slot.dy / M.LABEL_BOARD.height)
					item:SetAttribute("ForgeLabelId", slot.id)
					item:SetAttribute("ForgeLabelNudge", slot.dx .. "," .. slot.dy)
					local text = item:FindFirstChild("Text") :: any
					text.Text = texts[slot.id] or entry[2]
					-- One label style for every kind (R05-1 white text): creatures used to get a small coral
					-- line here plus the client's own nameplate (studio-after defects 8 and 9).
					text.TextColor3 = color(P.bone)
					-- Pet / companion labels are name tags the contextual banner steers around.
					if entry[3] == "pet" then
						item:AddTag(M.NAME_TAG)
					else
						item:RemoveTag(M.NAME_TAG)
					end
					local hint = item:FindFirstChild("Hint") :: any
					hint.Text, hint.Visible = line or "", line ~= nil and line ~= ""
				end
			end
			for index = used + 1, #dots do
				dots[index].Visible = false
			end
			for index = shown + 1, #boards do
				boards[index].Enabled, boards[index].Adornee = false, nil
			end
			labelFolder:SetAttribute("ForgeLabelCount", shown)
		end)
	)
	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		map:Destroy()
		bezel:Destroy()
		coords:Destroy()
		labelFolder:Destroy()
	end
end

--- Skill categories whose mastery level rose between two progression snapshots ({ [id]: { level } }),
--- sorted by id. A nil `before` is the first snapshot: a baseline, never a level-up.
function M.levelUps(before: { [string]: any }?, after: { [string]: any }?): { { id: string, level: number } }
	local out: { { id: string, level: number } } = {}
	if not before or not after then
		return out
	end
	for id, entry in after do
		local previous = before[id]
		if type(entry) == "table" and type(previous) == "table" and entry.level > previous.level then
			table.insert(out, { id = id, level = entry.level })
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

export type PickerOptions = {
	-- A ScreenGui with IgnoreGuiInset (screen space = viewport space).
	gui: any,
	touch: () -> boolean,
	hidden: () -> boolean,
	-- Offered outputs of a node part and its authored level (nil = none to show).
	offered: (any) -> ({ { item: string, quantity: number } }, number?),
	nodeName: (any) -> string,
	itemName: (string) -> string,
	icon: (string) -> string?,
	-- Sends one gather of `output`; yields and returns the server result.
	gather: (any, string) -> any,
	text: (string) -> string,
	-- Studs: the fan closes once the character is this far from the node.
	reach: number,
	-- Walks the character to within `within` flat studs of the node, then calls `arrive` (the tap
	-- router's moveTo; a newer walk or tap supersedes it and `arrive` never runs). With it, a pick
	-- out of gather reach walks up first, and a NODE_UNREACHABLE answer walks closer and retries once.
	approach: ((any, number, () -> ()) -> ())?,
	-- Player-facing line for a refused gather (nil: say nothing). It shows under the node name inside
	-- the fan: a separate bottom bar drew under the fan's name pill (p134 v75 B3 '...필요').
	refusal: ((any) -> string?)?,
}

-- Flat studs: a pick farther than PICK_REACH from its node walks to PICK_STOP first (server reach is
-- 8 studs in 3D with a clear ray; p134 v49: the first pick answered "too far, move closer").
M.PICK_REACH, M.PICK_STOP = 5, 3

--- True while a fan token's item initial must show: no art, or art that has not loaded.
function M.fanGlyphVisible(image: any): boolean
	return image.Image == "" or not image.IsLoaded
end

--- Gather picker runtime plus the item toasts and the skill banner. Returns
--- { open(part), close(), isOpen(), toast(line), banner(title, line), destroy() }.
function M.startPicker(options: PickerOptions): any
	local run = game:GetService("RunService")
	local guiService = game:GetService("GuiService")
	local input = game:GetService("UserInputService")
	local player = game:GetService("Players").LocalPlayer
	local world = game:GetService("Workspace")
	local P = M.PALETTE
	local gui = options.gui
	local connections: { any } = {}
	local root = Instance.new("Frame")
	root.Name, root.BackgroundTransparency, root.Size, root.Visible = "GatherFan", 1, UDim2.fromScale(1, 1), false
	root.Parent = gui
	local namePill = Instance.new("TextButton")
	namePill.Name, namePill.AutoButtonColor, namePill.BackgroundColor3 = "NodeName", false, color(P.ink)
	namePill.BackgroundTransparency, namePill.TextColor3 = 0.3, color(P.bone)
	namePill.Font, namePill.Parent = Enum.Font.BuilderSansBold, root
	local pillCorner = Instance.new("UICorner")
	pillCorner.CornerRadius, pillCorner.Parent = UDim.new(0.5, 0), namePill
	-- What a tap does next, or why the gather was refused (FAN.hint).
	local hintLabel = Instance.new("TextLabel")
	hintLabel.Name, hintLabel.BackgroundColor3, hintLabel.BackgroundTransparency = "GatherHint", color(P.ink), 0.3
	hintLabel.TextColor3, hintLabel.Font, hintLabel.Parent = color(P.bone), Enum.Font.BuilderSansBold, root
	hintLabel.TextWrapped, hintLabel.Text = true, ""
	local hintCorner = Instance.new("UICorner")
	hintCorner.CornerRadius, hintCorner.Parent = UDim.new(0.5, 0), hintLabel
	local function setHint(line: string, alert: boolean)
		hintLabel.Text = line
		hintLabel.BackgroundColor3 = color(if alert then P.coral else P.ink)
		hintLabel.TextColor3 = color(if alert then P.ink else P.bone)
		hintLabel.BackgroundTransparency = if alert then 0.05 else 0.3
	end
	local tokens: { any } = {}
	local function token(index: number): any
		local entry = tokens[index]
		if entry then
			return entry
		end
		local button = Instance.new("TextButton")
		button.Name, button.Text, button.Parent = "Output" .. index, "", root
		local image = Instance.new("ImageLabel")
		image.Name, image.BackgroundTransparency = "Icon", 1
		image.AnchorPoint, image.Position = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
		image.Size, image.Parent = UDim2.fromScale(0.56, 0.56), button
		local glyph = Instance.new("TextLabel")
		glyph.Name, glyph.BackgroundTransparency, glyph.Size = "Glyph", 1, UDim2.fromScale(1, 1)
		glyph.TextColor3, glyph.Font, glyph.Parent = color(P.bone), Enum.Font.BuilderSansBold, button
		-- The initial stays until the art has loaded: a published image the experience may not use
		-- (p134 v51: 403 InvalidPermission) never loads and would leave an empty pebble.
		image:GetPropertyChangedSignal("IsLoaded"):Connect(function()
			glyph.Visible = M.fanGlyphVisible(image)
		end)
		local count = Instance.new("TextLabel")
		count.Name, count.BackgroundTransparency, count.AnchorPoint = "Count", 1, Vector2.new(1, 1)
		count.Position, count.Size = UDim2.new(1, -4, 1, -2), UDim2.fromScale(0.6, 0.34)
		count.TextXAlignment, count.TextColor3 = Enum.TextXAlignment.Right, color(P.bone)
		count.Font, count.Parent = Enum.Font.BuilderSansBold, button
		local caption = Instance.new("TextLabel")
		caption.Name, caption.BackgroundColor3, caption.BackgroundTransparency = "Caption", color(P.ink), 0.3
		caption.TextColor3, caption.Font, caption.Parent = color(P.bone), Enum.Font.BuilderSansMedium, root
		local round = Instance.new("UICorner")
		round.CornerRadius, round.Parent = UDim.new(0.5, 0), caption
		entry = { button = button, image = image, glyph = glyph, count = count, caption = caption }
		tokens[index] = entry
		return entry
	end
	local current: any = nil
	local outputs: { { item: string, quantity: number } } = {}
	local busy = false
	local function close()
		current, busy = nil, false
		root.Visible = false
		root:SetAttribute("ForgeGatherNode", nil)
	end
	-- Toasts (stack of three, newest on top) and the banner.
	local toastLabels: { any } = {}
	local toastLines: { { text: string, at: number } } = {}
	for index = 1, 3 do
		local label = Instance.new("TextLabel")
		label.Name, label.BackgroundColor3, label.BackgroundTransparency = "Toast" .. index, color(P.ink), 0.25
		label.TextColor3, label.Font, label.Visible = color(P.bone), Enum.Font.BuilderSansBold, false
		label.TextXAlignment, label.Parent = Enum.TextXAlignment.Right, gui
		local pad = Instance.new("UIPadding")
		pad.PaddingRight, pad.Parent = UDim.new(0, 10), label
		local round = Instance.new("UICorner")
		round.CornerRadius, round.Parent = UDim.new(0.5, 0), label
		toastLabels[index] = label
	end
	local banner = Instance.new("Frame")
	banner.Name, banner.BackgroundColor3, banner.BackgroundTransparency = "SkillBanner", color(P.tealDeep), 0.08
	banner.Visible, banner.Parent = false, gui
	local bannerRim = Instance.new("UIStroke")
	bannerRim.Color, bannerRim.Thickness, bannerRim.Parent = color(P.ochre), 2, banner
	local bannerCorner = Instance.new("UICorner")
	bannerCorner.CornerRadius, bannerCorner.Parent = UDim.new(0.3, 0), banner
	local bannerTitle = Instance.new("TextLabel")
	bannerTitle.Name, bannerTitle.BackgroundTransparency, bannerTitle.Size = "Title", 1, UDim2.fromScale(1, 0.45)
	bannerTitle.TextColor3, bannerTitle.Font, bannerTitle.Parent = color(P.bone), Enum.Font.BuilderSansMedium, banner
	local bannerLine = Instance.new("TextLabel")
	bannerLine.Name, bannerLine.BackgroundTransparency = "Line", 1
	bannerLine.Position, bannerLine.Size = UDim2.fromScale(0, 0.42), UDim2.fromScale(1, 0.58)
	bannerLine.TextColor3, bannerLine.Font, bannerLine.Parent = color(P.ochre), Enum.Font.BuilderSansBold, banner
	local bannerUntil = 0
	local function topClear(): number
		local inset = guiService.TopbarInset
		return if inset then inset.Max.Y else 0
	end
	local function screenPoint(part: any): (number?, number?)
		local camera = world.CurrentCamera
		if not camera then
			return nil, nil
		end
		local point, visible = camera:WorldToViewportPoint(part.Position)
		return if visible and point.Z > 0 then point.X else nil, point.Y
	end
	local function gap(part: any): number?
		local character = player.Character
		local body = character and character:FindFirstChild("HumanoidRootPart")
		return if body
			then Vector3.new(body.Position.X - part.Position.X, 0, body.Position.Z - part.Position.Z).Magnitude
			else nil
	end
	local function send(part: any, entry: { item: string, quantity: number }, walked: boolean)
		if busy then
			return
		end
		busy = true
		local result = options.gather(part, entry.item)
		busy = false
		local refused = if options.refusal
				and type(result) == "table"
				and result.ok == false
			then options.refusal(result)
			else nil
		if refused and current == part then
			setHint(refused, true)
		elseif type(result) == "table" and result.ok == true and current == part then
			setHint(options.text("again"), false)
		end
		if type(result) == "table" and result.ok == true then
			table.insert(toastLines, 1, {
				text = string.format(options.text("toast"), entry.quantity, options.itemName(entry.item)),
				at = os.clock(),
			})
		elseif
			options.approach
			and not walked
			and type(result) == "table"
			and result.reason == "NODE_UNREACHABLE"
			and part.Parent
		then
			options.approach(part, M.PICK_STOP, function()
				send(part, entry, true)
			end)
		end
	end
	local function pick(index: number)
		local part, entry = current, outputs[index]
		if busy or not part or not entry then
			return
		end
		local distance = gap(part)
		if options.approach and distance and distance > M.PICK_REACH then
			-- Walk into reach, then gather, like the combat approach (never a "too far" refusal).
			options.approach(part, M.PICK_STOP, function()
				if part.Parent then
					send(part, entry, true)
				end
			end)
			return
		end
		send(part, entry, false)
	end
	local function open(part: any)
		-- The fan is already open on this node: the big gather button (or another tap on the node)
		-- gathers the default output instead of silently re-opening the same fan (p134 v43).
		if current ~= nil and current == part and root.Visible then
			task.spawn(pick, 1)
			return true
		end
		local offered, level = options.offered(part)
		if #offered == 0 or options.hidden() then
			return false
		end
		current, outputs = part, offered
		root:SetAttribute("ForgeGatherNode", part:GetAttribute("ForgeNodeId"))
		local name = options.nodeName(part)
		namePill.Text = if level then name .. "  " .. string.format(options.text("level"), level) else name
		setHint(options.text("again"), false)
		for index, entry in tokens do
			entry.button.Visible, entry.caption.Visible = index <= #offered, index <= #offered
		end
		for index, output in offered do
			local entry = token(index)
			entry.button.Visible, entry.caption.Visible = true, true
			entry.button:SetAttribute("ForgeItem", output.item)
			local image = options.icon(output.item)
			entry.image.Image, entry.image.Visible = image or "", image ~= nil
			entry.glyph.Text = utf8.char(utf8.codepoint(options.itemName(output.item), 1))
			entry.glyph.Visible = M.fanGlyphVisible(entry.image)
			entry.count.Text = "x" .. output.quantity
			entry.caption.Text = options.itemName(output.item)
		end
		root.Visible = true
		return true
	end
	for index = 1, M.FAN.maximum do
		local entry = token(index)
		entry.button.Visible, entry.caption.Visible = false, false
		table.insert(
			connections,
			entry.button.Activated:Connect(function()
				task.spawn(pick, index)
			end)
		)
	end
	table.insert(connections, namePill.Activated:Connect(close))
	table.insert(
		connections,
		input.InputBegan:Connect(function(key: any, processed: boolean)
			if processed or not current then
				return
			end
			if key.KeyCode == Enum.KeyCode.Escape or key.KeyCode == Enum.KeyCode.ButtonB then
				close()
			end
			-- PC: number keys 1-6 pick the matching output.
			local number = key.KeyCode.Value - Enum.KeyCode.One.Value + 1
			if number >= 1 and number <= #outputs then
				task.spawn(pick, number)
			end
		end)
	)
	table.insert(
		connections,
		run.RenderStepped:Connect(function()
			local size = gui.AbsoluteSize
			local touch = options.touch()
			local clear = topClear()
			local h = size.Y - clear
			local now = os.clock()
			-- Feedback.
			local feedback = M.feedback(size.X, size.Y, clear, touch)
			while #toastLines > 0 and now - toastLines[#toastLines].at > 3 do
				table.remove(toastLines)
			end
			for index, label in toastLabels do
				local line = toastLines[index]
				label.Visible = line ~= nil and not options.hidden()
				if line then
					M.put(label, feedback.toasts[index])
					label.Text, label.TextSize = line.text, M.tokenText("label", h, touch)
				end
			end
			banner.Visible = now < bannerUntil and not options.hidden()
			if banner.Visible then
				M.put(banner, feedback.banner)
				bannerTitle.TextSize = M.tokenText("label", h, touch)
				bannerLine.TextSize = M.textSize("title", h)
			end
			-- Fan.
			local part = current
			if not part then
				return
			end
			local character = player.Character
			local body = character and character:FindFirstChild("HumanoidRootPart")
			local far = body
				and Vector3.new(body.Position.X - part.Position.X, 0, body.Position.Z - part.Position.Z).Magnitude
					> options.reach
			local x, y = screenPoint(part)
			if not part:IsDescendantOf(world) or far or options.hidden() or not x then
				close()
				return
			end
			local fan = M.fan(size.X, size.Y, clear, touch, x, y :: number, #outputs)
			M.put(namePill, fan.name)
			namePill.TextSize = M.tokenText("label", h, touch)
			M.put(hintLabel, fan.hint)
			hintLabel.TextSize = M.tokenText("caption", h, touch)
			for index = 1, #outputs do
				local entry = tokens[index]
				M.put(entry.button, fan.tokens[index])
				M.put(entry.caption, fan.captions[index])
				M.pebble(entry.button, false, not busy)
				entry.count.TextSize = M.tokenText("caption", h, touch)
				entry.glyph.TextSize = M.textSize("title", h)
				entry.glyph.Visible = M.fanGlyphVisible(entry.image)
				entry.caption.TextSize = M.tokenText("caption", h, touch)
			end
		end)
	)
	return {
		open = open,
		close = close,
		isOpen = function(): boolean
			return current ~= nil
		end,
		-- The node part whose fan is open (nil when closed).
		node = function(): any
			return current
		end,
		toast = function(line: string)
			table.insert(toastLines, 1, { text = line, at = os.clock() })
		end,
		banner = function(title: string, line: string)
			bannerTitle.Text, bannerLine.Text, bannerUntil = title, line, os.clock() + 3
		end,
		destroy = function()
			for _, connection in connections do
				connection:Disconnect()
			end
			root:Destroy()
			banner:Destroy()
			for _, label in toastLabels do
				label:Destroy()
			end
		end,
	}
end

return M
