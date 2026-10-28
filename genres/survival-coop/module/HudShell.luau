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
	return if touch then math.max(M.MIN_TOUCH, px) else math.min(px, row[2])
end

M.LABEL_RADIUS = 40
M.LABEL_LIMIT = 24
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
M.VITALS_MIN_HEIGHT = 78
-- Label 26+62, a bar track of at least 80 and the value 46 (SurvivalHUDModel.VITALS): narrower and the
-- bars collapsed to dots on the phone (staging v26).
M.VITALS_MIN_WIDTH = 220

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
			if touch then
				size = math.max(M.MIN_TOUCH, math.floor(size * shrink + 0.5))
			end
			local radius, angle = spec[1] * k * h, math.rad(spec[2])
			local edge = if touch then M.EDGE * h else 0
			local cx, cy = width - edge - radius * math.cos(angle), top + h - edge - radius * math.sin(angle)
			local tall = size * M.PEBBLE.aspect
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
	local function tl(x0: number, x1: number, y0: number, y1: number): Rect
		return rect(x0 * h, top + y0 * h, (x1 - x0) * h, (y1 - y0) * h)
	end
	local function tr(x0: number, x1: number, y0: number, y1: number): Rect
		return rect(width - x1 * h, top + y0 * h, (x1 - x0) * h, (y1 - y0) * h)
	end
	local function tc(x0: number, x1: number, y0: number, y1: number): Rect
		return rect(width / 2 + x0 * h, top + y0 * h, (x1 - x0) * h, (y1 - y0) * h)
	end
	-- The vitals panel holds three bar rows (SurvivalHUDModel.VITALS: 24 px steps, 26 px rows), so it
	-- never gets shorter than VITALS_MIN_HEIGHT; chips and tracker stack under it. On a phone the
	-- spec's 0.12H panel is 42 px and the rows spilled out of it over the coin chip (staging v25).
	local vitals = tl(0.02, 0.46, 0.02, 0.14)
	vitals.height = math.max(vitals.height, M.VITALS_MIN_HEIGHT)
	vitals.width = math.max(vitals.width, M.VITALS_MIN_WIDTH)
	local chips = rect(vitals.x, vitals.y + vitals.height + 0.015 * h, 0.40 * h, 0.07 * h)
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
		status = status,
		row = bounds(rowSlots),
		rowSlots = rowSlots,
		cluster = cluster,
		tokens = tokens,
		target = target,
		endCombat = endCombat,
	}
end

function M.overlaps(a: Rect, b: Rect): boolean
	return hits(a, b, 0)
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
	for index = 1, math.min(#near, limit or M.LABEL_LIMIT) do
		out[index] = near[index][2]
	end
	return out
end

--- Minimap pixel for a world offset (north-up, +x right, +z down), or nil outside the map.
function M.mapPoint(dx: number, dz: number, side: number, window: number?): (number?, number?)
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
M.MARKET_GRID_COLUMNS = 4

export type PanelLayout = {
	kind: string,
	safeHeight: number,
	frame: Rect,
	bar: Rect,
	title: Rect,
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

--- Panel rects in the space of a CoreUISafeInsets ScreenGui of `width` x `height` (`topClear` as in
--- `regions`). `kind` is craft, market or bag.
function M.panel(width: number, height: number, topClear: number?, kind: string): PanelLayout
	local top = topClear or 0
	local h = height - top
	local gap = M.PANEL_GAP
	local pad = math.max(gap, math.floor(0.02 * h + 0.5))
	local barHeight = row("bar", h)
	local close = M.MIN_TOUCH
	local closeRect = rect(width - pad - close, top + (barHeight - close) / 2, close, close)
	local pillHeight = math.min(barHeight - 8, math.max(28, math.floor(0.07 * h + 0.5)))
	local pillWidth = math.clamp(math.floor(0.45 * h + 0.5), 140, 240)
	local currency = rect(closeRect.x - gap - pillWidth, top + (barHeight - pillHeight) / 2, pillWidth, pillHeight)
	local title = rect(pad, top, math.max(0, currency.x - gap - pad), barHeight)
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
M.FAN = table.freeze({ radius = 0.22, step = 40, maximum = 6, caption = 18, pill = 22 })

export type Fan = { tokens: { Rect }, captions: { Rect }, name: Rect, x: number, y: number }

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
	y1 = pillTop + pill
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
		x = px,
		y = py,
	}
end

--- Item-gain toast stack (spec section 5: top-right, 0.46-0.58H, three lines) and the level-up
--- banner (top-centre, the status region). Lines are `caption`-scale but never under 13 px.
function M.feedback(width: number, height: number, topClear: number?): { toasts: { Rect }, banner: Rect }
	local top = topClear or 0
	local h = height - top
	local toasts = {}
	local line = math.max(18, 0.04 * h)
	for index = 1, 3 do
		toasts[index] = rect(width - 1.0 * h, top + 0.46 * h + (index - 1) * line, 0.55 * h, line - 2)
	end
	local bannerWidth = math.min(1.4 * h, width - 16)
	return { toasts = toasts, banner = rect(width / 2 - bannerWidth / 2, top + 0.16 * h, bannerWidth, 0.10 * h) }
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

--- Styles a GuiButton as a pebble token: tealDeep fill (teal and ink glyph when active), a
--- driftwood rim 6% of the edge, squircle corners, bone label text.
function M.pebble(button: any, active: boolean?, enabled: boolean?)
	local P = M.PALETTE
	button.AutoButtonColor = false
	button.BackgroundTransparency = if enabled == false then 0.6 else 0
	button.BackgroundColor3 = color(if enabled == false then P.boneShade elseif active then P.teal else P.tealDeep)
	button.TextColor3 = color(if active then P.ink else P.bone)
	button.Font = Enum.Font.BuilderSans
	local corner = button:FindFirstChild("PebbleCorner") or Instance.new("UICorner")
	corner.Name, corner.CornerRadius, corner.Parent = "PebbleCorner", UDim.new(M.PEBBLE.corner, 0), button
	for _, child in button:GetChildren() do
		if child:IsA("UICorner") and child ~= corner then
			child:Destroy()
		end
	end
	local rim = button:FindFirstChild("PebbleRim") or Instance.new("UIStroke")
	rim.Name, rim.Color, rim.Parent = "PebbleRim", color(P.drift), button
	rim.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rim.Thickness = math.max(2, math.floor(math.min(button.AbsoluteSize.X, button.AbsoluteSize.Y) * M.PEBBLE.rim + 0.5))
end

--- Places a GuiObject at a rect given in the space of `frame`'s ScreenGui (offset by `origin`).
function M.put(item: any, r: Rect, origin: any?)
	local o = origin or Vector2.zero
	item.AnchorPoint = Vector2.zero
	item.Position = UDim2.fromOffset(r.x - o.X, r.y - o.Y)
	item.Size = UDim2.fromOffset(r.width, r.height)
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
}

-- Tags a pack/server sets on a ground drop or a deployed pet so it gets a label.
M.DROP_TAG, M.PET_TAG = "ForgeWorldDrop", "ForgeWorldPet"

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
	if not playerGui then
		return false
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
					return true
				end
				if child.ClassName == "Frame" and child.Visible then
					for _, inner in child:GetChildren() do
						if sheet(inner) then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

function M.startOverlays(options: OverlayOptions): () -> ()
	local players = game:GetService("Players")
	local tags = game:GetService("CollectionService")
	local world = game:GetService("Workspace")
	local run = game:GetService("RunService")
	local player = players.LocalPlayer
	local P = M.PALETTE
	local connections: { any } = {}
	-- Minimap: round, driftwood rim, tealDeep sea with a tealPale wash.
	local map = Instance.new("Frame")
	map.Name, map.BackgroundColor3, map.BackgroundTransparency = "Minimap", color(P.tealDeep), 0.1
	map.ClipsDescendants, map.Parent = true, options.gui
	local mapCorner = Instance.new("UICorner")
	mapCorner.CornerRadius, mapCorner.Parent = UDim.new(0.5, 0), map
	local mapRim = Instance.new("UIStroke")
	mapRim.Color, mapRim.Thickness, mapRim.Parent = color(P.drift), 3, map
	local wash = Instance.new("UIGradient")
	wash.Color = ColorSequence.new(color(P.tealDeep), color(P.tealPale))
	wash.Transparency = NumberSequence.new(0, 0.55)
	wash.Rotation, wash.Parent = 90, map
	local arrow = Instance.new("TextLabel")
	arrow.Name, arrow.BackgroundTransparency, arrow.Text = "Self", 1, "^"
	arrow.AnchorPoint, arrow.Position = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
	arrow.Size, arrow.TextColor3, arrow.Font = UDim2.fromOffset(20, 20), color(P.bone), Enum.Font.BuilderSansBold
	arrow.TextSize, arrow.ZIndex, arrow.Parent = 20, 3, map
	local coords = Instance.new("TextLabel")
	coords.Name, coords.BackgroundColor3, coords.BackgroundTransparency = "Coordinates", color(P.ink), 0.3
	coords.TextColor3, coords.Font, coords.Text = color(P.bone), Enum.Font.BuilderSans, ""
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
		if existing and existing.Parent == labelFolder and existing:FindFirstChild("Text") then
			return existing
		elseif existing then
			existing:Destroy()
		end
		local item = Instance.new("BillboardGui")
		item.Name, item.Size, item.AlwaysOnTop = "WorldLabel", UDim2.fromOffset(180, 28), true
		item.StudsOffsetWorldSpace, item.LightInfluence = Vector3.new(0, 3, 0), 0
		item.MaxDistance = M.LABEL_RADIUS + 8
		local text = Instance.new("TextLabel")
		text.Name, text.AnchorPoint, text.Position = "Text", Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
		text.Size, text.AutomaticSize = UDim2.fromOffset(0, 24), Enum.AutomaticSize.X
		text.BackgroundColor3, text.BackgroundTransparency = color(P.ink), 0.45
		text.Font, text.TextSize = Enum.Font.BuilderSansMedium, 15
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft, pad.PaddingRight, pad.Parent = UDim.new(0, 10), UDim.new(0, 10), text
		local round = Instance.new("UICorner")
		round.CornerRadius, round.Parent = UDim.new(0.5, 0), text
		text.Parent, item.Parent = item, labelFolder
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
		tag.Parent = ringFolder
		local nameLine = Instance.new("TextLabel")
		nameLine.Name, nameLine.BackgroundTransparency, nameLine.Size = "Name", 1, UDim2.new(1, 0, 0, 22)
		nameLine.TextColor3, nameLine.Font, nameLine.TextSize = color(P.bone), Enum.Font.BuilderSansMedium, 16
		nameLine.TextStrokeTransparency, nameLine.Parent = 0.4, tag
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
				entry.ring.Visible, entry.tag.Enabled = alive, alive
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
						entry.name.Size = UDim2.new(1, 0, 0, tagSize.name + 4)
						entry.name.TextSize = tagSize.name
						entry.tribe.Position = UDim2.fromOffset(0, tagSize.name + 4)
						entry.tribe.Size = UDim2.new(1, 0, 0, tagSize.tribe + 2)
						entry.tribe.TextSize = tagSize.tribe
					end
				end
			end
		end)
	)
	local elapsed = 0
	table.insert(
		connections,
		run.Heartbeat:Connect(function(dt)
			elapsed += dt
			if elapsed < 0.2 then
				return
			end
			elapsed = 0
			local size = options.gui.AbsoluteSize
			local regions = M.regions(size.X, size.Y, M.guiClear(options.gui))
			M.put(map, regions.minimap)
			M.put(coords, regions.coords)
			coords.TextSize = M.textSize("caption", regions.safeHeight)
			tagSize = M.nameTag(regions.safeHeight, touch)
			local hidden = options.hidden()
			map.Visible, coords.Visible = not hidden, not hidden
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			used = 0
			local shown = 0
			if root and root:IsA("BasePart") and not hidden then
				local origin = root.Position
				local look = root.CFrame.LookVector
				arrow.Rotation = math.deg(math.atan2(look.X, -look.Z))
				coords.Text = options.coordsText(M.coords(origin.X, origin.Z))
				local side = regions.minimap.width
				local candidates: { Candidate } = {}
				local lookup: { [string]: { any } } = {}
				for index, entry in M.collect(world, tags) do
					local anchor = anchorOf(entry[1])
					if anchor then
						local at = anchor.Position
						local x, y = M.mapPoint(at.X - origin.X, at.Z - origin.Z, side)
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
							lookup[id] = { anchor, text, entry[2] }
							table.insert(candidates, { id = id, kind = entry[2], x = at.X, y = at.Y, z = at.Z })
						end
					end
				end
				for _, other in players:GetPlayers() do
					local body = other ~= player and other.Character
					local at = body and body:FindFirstChild("HumanoidRootPart")
					if at and at:IsA("BasePart") then
						local x, y = M.mapPoint(at.Position.X - origin.X, at.Position.Z - origin.Z, side)
						if x and y then
							dot(x, y, P.bone, 7)
						end
					end
				end
				for _, target in M.labelTargets(candidates, origin.X, origin.Y, origin.Z) do
					shown += 1
					local item = board(shown)
					local entry = lookup[target.id]
					item.Adornee, item.Enabled = entry[1], true
					local text = item:FindFirstChild("Text") :: any
					text.Text = entry[2]
					text.TextColor3 = color(if entry[3] == "wildlife" then P.coral else P.bone)
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
}

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
	local function pick(index: number)
		local part, entry = current, outputs[index]
		if busy or not part or not entry then
			return
		end
		busy = true
		local result = options.gather(part, entry.item)
		busy = false
		if type(result) == "table" and result.ok == true then
			table.insert(toastLines, 1, {
				text = string.format(options.text("toast"), entry.quantity, options.itemName(entry.item)),
				at = os.clock(),
			})
		end
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
		for index, entry in tokens do
			entry.button.Visible, entry.caption.Visible = index <= #offered, index <= #offered
		end
		for index, output in offered do
			local entry = token(index)
			entry.button.Visible, entry.caption.Visible = true, true
			entry.button:SetAttribute("ForgeItem", output.item)
			local image = options.icon(output.item)
			entry.image.Image, entry.image.Visible = image or "", image ~= nil
			entry.glyph.Text = if image then "" else utf8.char(utf8.codepoint(options.itemName(output.item), 1))
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
			local feedback = M.feedback(size.X, size.Y, clear)
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
			for index = 1, #outputs do
				local entry = tokens[index]
				M.put(entry.button, fan.tokens[index])
				M.put(entry.caption, fan.captions[index])
				M.pebble(entry.button, false, not busy)
				entry.count.TextSize = M.tokenText("caption", h, touch)
				entry.glyph.TextSize = M.textSize("title", h)
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
