--!strict
local CommandTransport = require("../../../core/infra/genre/CommandTransport")
local Layout = require("../../../core/ui-kit/Layout")
local HUDModel = require("./SurvivalHUDModel")
local HudShell = require("./HudShell")
local Locale = require("./SurvivalHUDLocale")
local PackLocale = require("./PackLocale")
local IconFallback = require("../../../core/ui-kit/IconFallback")

export type Context = {
	ui: any,
	locale: string,
	send: (string, { any }) -> any,
	onSnapshot: (({ [string]: any }, { [string]: any }) -> ()) -> () -> (),
	dock: ((DockEntry) -> DockHandle)?,
	fitSheet: ((any) -> ())?,
	objectiveSlot: any?,
	-- Shell text size (Theme.sheetText) for SheetCards inside a fitted sheet (U6).
	sheetText: ((string) -> number)?,
	open: ((string) -> boolean)?,
	availability: ((string) -> (boolean, boolean, string?))?,
	onSend: (((string, { any }, any, string?) -> ()) -> () -> ())?,
	openPanel: ((string) -> ())?,
	dialogue: ((string, string?) -> ())?,
	content: any?,
	-- The pack's icon resolver (ItemIcons: ui/item/recipe -> { image, category }), when given.
	icons: any?,
}
export type DockEntry = {
	id: string,
	label: string,
	order: number,
	setOpen: (boolean) -> (),
	isOpen: () -> boolean,
	-- Hidden entries have no menu tile; they open through ctx.open (navigator, world prompts).
	hidden: boolean?,
}
export type DockHandle = {
	open: () -> (),
	setAvailable: (boolean, string?) -> (),
}
export type Panel = { destroy: () -> () }
export type Factory = (Context) -> Panel?

local env: any = getfenv()
local game: any = env.game
local task: any = env.task
local Instance: any = env.Instance
local Enum: any = env.Enum
local UDim: any = env.UDim
local UDim2: any = env.UDim2
local Vector2: any = env.Vector2
local Color3: any = env.Color3
local RaycastParams: any = env.RaycastParams
local ColorSequence: any = env.ColorSequence

local M = {}
local categories: { [string]: { number | string } } = {
	bag = { 1, "bag" },
	craft = { 1, "craft" },
	build = { 1, "build" },
	skills = { 1, "skills" },
	character = { 1, "skills" },
	equipment = { 1, "bag" },
	journal = { 2, "journal" },
	contracts = { 2, "todo" },
	explore = { 2, "explore" },
	["death-zone"] = { 2, "explore" },
	taming = { 2, "capture" },
	clan = { 3, "clan" },
	tribe = { 3, "social" },
	outpost = { 3, "build" },
	camp = { 3, "party" },
	market = { 3, "market" },
	["clan-join"] = { 3, "invite" },
	construction = { 3, "build" },
	building = { 1, "build" },
	["clan-membership"] = { 3, "invite" },
	brawl = { 3, "party" },
	routes = { 2, "explore" },
	party = { 3, "party" },
	expedition = { 2, "explore" },
	shop = { 4, "currency" },
	music = { 5, "music" },
	navigator = { 1, "todo" },
	["score-import"] = { 5, "music" },
	["score-share"] = { 5, "music" },
	["ensemble-lobby"] = { 5, "music" },
	audio = { 5, "settings" },
	sound = { 5, "settings" },
	farm = { 1, "skills" },
	["crop-book"] = { 1, "journal" },
	processing = { 1, "craft" },
	["craft-preview"] = { 1, "craft" },
	inbox = { 1, "inbox" },
	operations = { 1, "craft" },
	guides = { 1, "journal" },
}
function M.tileOrder(id: string, order: number): number
	return ((categories[id] or { 3 })[1] :: number) * 100 + order
end

local ACTION_LABELS: { [string]: { string } } = PackLocale.rows({}, { "act." })

--- Current archipelago stage objectives with progress, e.g. "Wood 0/5 · Survey 0/1".
--- `state` is the archipelago extension snapshot; nil when no active stage applies.
function M.stageObjectiveText(state: any, content: any, locale: string, names: { [string]: string }?): string?
	if type(state) ~= "table" or state.status ~= "active" or type(content) ~= "table" then
		return nil
	end
	local ko = string.sub(locale, 1, 2) == "ko"
	local layout = tostring(state.templateId) .. ".s" .. tostring(state.stage)
	local parts = {}
	for _, stage in content.stages or {} do
		if stage.layout == layout then
			for _, objective in stage.objectives do
				local row = ACTION_LABELS[objective.action]
				local label = if row
					then row[if ko then 2 else 1]
					else (names and names[objective.target]) or objective.target
				local done = if state.completed and state.completed[objective.id]
					then objective.quantity
					else math.min(objective.quantity, (state.progress and state.progress[objective.id]) or 0)
				table.insert(parts, string.format("%s %d/%d", label, done, objective.quantity))
			end
		end
	end
	return if #parts > 0 then table.concat(parts, " · ") else nil
end

local TRAVEL_REASONS: { [string]: { string } } = PackLocale.rows({}, { "trv." })

--- Player-visible text for the server's dock travel result (`travelling` or a refusal reason).
function M.travelText(locale: string, result: string): string
	local ko = string.sub(locale, 1, 2) == "ko"
	local row = TRAVEL_REASONS[result]
	if row then
		return row[if ko then 2 else 1]
	end
	return if ko then "지금은 이동할 수 없어요" else "You can't travel right now"
end

function M.activate(entries: { DockEntry }, entry: DockEntry)
	for _, other in entries do
		if other ~= entry and other.isOpen() then
			other.setOpen(false)
		end
	end
	-- Launchers open, rather than toggle: a repeated activation must not close its sheet.
	entry.setOpen(true)
end

-- Contextual menu grid: 6px cell gap, and the ScrollingFrame's 6px scrollbar clips the
-- right edge of its canvas, so tiles only get the width left of the scrollbar.
M.MENU_GAP, M.MENU_SCROLLBAR, M.MENU_MIN_TILE = 6, 6, 44
-- p83: 11px labels under a category caption were unreadable. A tile is one 48px row: a 24px
-- icon on the left and the label (16px, never under MENU_LABEL_MIN) in up to two lines beside
-- it. A column is only added while every tile keeps MENU_LABEL_WIDTH for its label.
M.MENU_TILE, M.MENU_LABEL_SIZE, M.MENU_LABEL_MIN, M.MENU_ICON = 48, 16, 14, 24
M.MENU_LABEL_LEFT, M.MENU_LABEL_RIGHT, M.MENU_LABEL_WIDTH = 36, 4, 110
M.MENU_MIN_CELL = M.MENU_LABEL_LEFT + M.MENU_LABEL_WIDTH + M.MENU_LABEL_RIGHT
-- Label rect inside a tile of `cell` width (x, width).
function M.menuLabel(cell: number): (number, number)
	return M.MENU_LABEL_LEFT, cell - M.MENU_LABEL_LEFT - M.MENU_LABEL_RIGHT
end
function M.menuBounds(width: number, height: number): (number, number, number, number)
	local landscape = width > height
	local columns = if landscape and height < 400 then 4 elseif landscape then 5 else 2
	local w = math.min(720, width - 24)
	local fit = math.floor((w - M.MENU_SCROLLBAR + M.MENU_GAP) / (M.MENU_MIN_CELL + M.MENU_GAP))
	return w, math.max(1, math.min(columns, fit)), M.MENU_TILE, 116
end
-- Tile width for `columns` tiles in a `menuWidth` frame. UIGridLayout reserves a gap after every cell.
function M.menuCell(menuWidth: number, columns: number): number
	return math.floor((menuWidth - M.MENU_SCROLLBAR - columns * M.MENU_GAP) / columns)
end
-- Canvas height: top gap, rows, bottom gap (AutomaticCanvasSize came out one row short, p36).
function M.menuCanvas(count: number, columns: number, tile: number): number
	local rows = math.ceil(count / math.max(1, columns))
	return M.MENU_GAP + rows * (tile + M.MENU_GAP)
end
-- Visible menu height trimmed to whole tile rows (p68: at 360x640 a 20px sliver of the next row,
-- with the Music tile's centre below the frame, so a tap there fell through to the world). With
-- whole rows the unscrolled view and the view at maximum scroll both end on a full row.
function M.menuRows(height: number, tile: number): number
	local rows = math.floor(height / (tile + M.MENU_GAP))
	return if rows >= 1 then rows * (tile + M.MENU_GAP) else height
end
-- Columns: design count capped by touch-sized tiles; the grid starts below the menu button and chat.
function M.menuRect(width: number, height: number, touch: boolean): (number, number, number, number, number, number)
	local w, columns, tile, top = M.menuBounds(width, height)
	local button = HUDModel.contextHudBounds(width, height).menu
	top = math.max(top, button.y + button.height + M.MENU_GAP)
	local chat = HUDModel.phoneChat(width, height)
	if chat then
		top = math.max(top, chat.y + chat.height + M.MENU_GAP)
	end
	local x, h = (width - w) / 2, math.max(0, height - top - 128)
	if (touch or width < 700) and width > height and height < 480 then
		x, w, h = HUDModel.THUMB_GUTTER, width - 2 * HUDModel.THUMB_GUTTER, height - top - 8
	elseif chat then
		-- Portrait phone: the open menu is modal (like every portrait sheet), so it runs down to
		-- the bottom margin instead of stopping above the thumbstick (p83: 3 rows at 360x640).
		h = math.max(0, height - top - 16)
	end
	local fit = math.floor((w - M.MENU_SCROLLBAR + M.MENU_GAP) / (M.MENU_MIN_CELL + M.MENU_GAP))
	return x, top, w, h, math.max(1, math.min(columns, fit)), tile
end
-- Robango shell menu (D2b fix 10): the menu toggle is the first pebble of the bottom-left row, so
-- the grid no longer starts under a top-right button (top 116 left 2 rows on the 800x360 phone). A
-- landscape grid runs from the safe-area top to its bottom, right of the toggle, and keeps the
-- camera-cutout inset on touch screens; a wide pointer screen keeps the 720 px grid at the right.
M.SHELL_MENU_MARGIN, M.SHELL_MENU_SIDE = 4, 32
function M.shellMenuRect(
	width: number,
	height: number,
	touch: boolean,
	toggle: { x: number, y: number, width: number, height: number }
): (number, number, number, number, number, number)
	local _, columns, tile = M.menuBounds(width, height)
	local side = if touch then M.SHELL_MENU_SIDE else 12
	local x = toggle.x + toggle.width + M.MENU_GAP
	local w = width - x - side
	if w > 720 then
		x, w = width - side - 720, 720
	end
	local fit = math.floor((w - M.MENU_SCROLLBAR + M.MENU_GAP) / (M.MENU_MIN_CELL + M.MENU_GAP))
	local margin = M.SHELL_MENU_MARGIN
	return x, margin, w, math.max(0, height - 2 * margin), math.max(1, math.min(columns, fit)), tile
end

-- Shell side sheet on a short touch landscape: the whole safe height (the HUD hides under an open
-- sheet) and centred at most 640 wide, instead of the 64 px top reserve of contextSheet.
function M.shellSheet(width: number, height: number, touch: boolean): (number, number, number, number)
	if (touch or width < 700) and width > height and height < 480 then
		local w = math.min(640, width - 2 * M.SHELL_MENU_SIDE)
		return math.floor((width - w) / 2), 8, w, height - 16
	end
	return HUDModel.contextSheet(width, height, touch)
end

-- ---------------------------------------------------------------------------------------------
-- Sheet shell (D2b fix 3): every sheet fitted through ctx.fitSheet gets one look from the ui-kit
-- Theme.sheet tokens: parchment body in a wood rim, a leather header with an icon badge, a
-- left-aligned title and a round close, left-aligned ink rows with a marker, sea-glass buttons, and
-- every text at least Theme.sheetText for the gui's safe height (never under 14 px). Text is styled
-- as it is parented (rows rebuild on every snapshot), so panels keep their own row code. Sheets that
-- lay themselves out as full-screen shell panels (ForgeShellPanel) keep their own palette.
local function rgb(c: any): any
	return Color3.fromRGB(c.r, c.g, c.b)
end

local function child(item: any, class: string): any
	return if type(item.FindFirstChildOfClass) == "function" then item:FindFirstChildOfClass(class) else nil
end

local function childNamed(item: any, name: string): any
	return if type(item.FindFirstChild) == "function" then item:FindFirstChild(name) else nil
end

--- Shell text style of a text object in a sheet: title (header title, close), button or body.
function M.shellRole(item: any, header: any): string
	if item.Parent == header or item.Name == "Close" then
		return "title"
	end
	return if item.ClassName == "TextButton" then "button" else "body"
end

--- Styles one TextLabel/TextButton of a shell sheet. `size(style)` is the current shell text size.
function M.styleShellText(item: any, header: any, tokens: any, size: (string) -> number)
	local C, S = tokens.colors, tokens.space
	local class = item.ClassName
	if (class ~= "TextLabel" and class ~= "TextButton") or item.TextScaled then
		return
	end
	-- SheetCards text (empty states, hero and tile cards) keeps its own centring, weight and ink.
	if type(item.GetAttribute) == "function" and item:GetAttribute("ForgeShellKeep") == true then
		return
	end
	local role = M.shellRole(item, header)
	if role == "title" then
		item.TextSize = size("title")
		item.TextColor3 = rgb(C.headerText)
		if item.Name == "Close" then
			item.BackgroundColor3 = rgb(C.close)
		end
		return
	end
	item.TextSize = math.max(item.TextSize or 0, size("body"))
	local parent = item.Parent
	if parent ~= nil and parent.ClassName == "TextButton" then
		-- A caption inside a button (icon buttons) takes the button's text colour.
		item.TextColor3 = rgb(C.buttonText)
		return
	end
	if role == "button" then
		-- Rows that are buttons (screen links, actions) read as one sea-glass family.
		if item.BackgroundTransparency ~= 1 then
			item.BackgroundColor3, item.TextColor3 = rgb(C.button), rgb(C.buttonText)
		end
		return
	end
	local stroke = child(item, "UIStroke")
	if stroke then
		-- Ink on parchment needs no halo; the kit's world-backdrop stroke only blurs it.
		stroke.Transparency = 1
	end
	item.TextColor3 = rgb(C.ink)
	if item.BackgroundTransparency ~= 1 then
		item.BackgroundColor3 = rgb(C.chip)
	end
	if Enum then
		item.TextXAlignment = Enum.TextXAlignment.Left
	end
	-- A list row (a direct child of the sheet's scroll) gets a sea-glass marker left of its text;
	-- nested labels only keep the left inset.
	local row = item.Parent ~= nil and item.Parent.Name == "Content"
	local padding = child(item, "UIPadding") or Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, if row then S.marker + 2 * S.gap else S.gap)
	padding.PaddingRight, padding.Parent = UDim.new(0, S.gap), item
	if row and Enum then
		-- A row grows with its wrapped text instead of clipping it (panels size rows for 15 px text).
		item.AutomaticSize = Enum.AutomaticSize.Y
	end
	if row and not childNamed(item, "ShellMarker") then
		local marker = Instance.new("Frame")
		marker.Name, marker.BorderSizePixel, marker.BackgroundColor3 = "ShellMarker", 0, rgb(C.marker)
		marker.Size = UDim2.fromOffset(S.marker, math.max(S.marker, size("body")))
		marker.AnchorPoint = Vector2.new(0, 0.5)
		marker.Position = UDim2.new(0, -(S.marker + S.gap), 0.5, 0)
		local corner = Instance.new("UICorner")
		corner.CornerRadius, corner.Parent = UDim.new(0.5, 0), marker
		marker.Parent = item
	end
end

-- Pack ui icon (assets/icons/ui.icon.<icon>.png, manifest key ui-icon-<icon>) per dock id, for its
-- menu tile and sheet header. A dock id not listed here uses its category icon (`categories`).
M.DOCK_ICONS = table.freeze({
	bag = "bag",
	craft = "craft",
	build = "build",
	skills = "skills",
	character = "member",
	equipment = "durability",
	journal = "journal",
	contracts = "todo",
	explore = "explore",
	["death-zone"] = "block",
	taming = "capture",
	clan = "clan",
	tribe = "social",
	outpost = "claim",
	camp = "party",
	market = "market",
	["market-buy"] = "market",
	["clan-join"] = "invite",
	["clan-membership"] = "invite",
	["clan-browse"] = "clan",
	["clan-roles"] = "officer",
	["clan-treasury"] = "currency",
	["clan-research"] = "search",
	construction = "build",
	building = "build",
	["build-manage"] = "build",
	brawl = "stance.attack",
	routes = "explore",
	party = "party",
	expedition = "explore",
	arrival = "explore",
	shop = "currency",
	music = "music",
	["score-import"] = "music",
	["score-share"] = "music",
	["score-library"] = "music",
	["ensemble-lobby"] = "music",
	operations = "music",
	navigator = "sort",
	audio = "settings",
	sound = "settings",
	farm = "fertility",
	["farm-area"] = "fertility",
	["crop-specialize"] = "fertility",
	["crop-book"] = "journal",
	processing = "processing-budget",
	["craft-preview"] = "craft",
	["recipe-tracker"] = "todo",
	inbox = "inbox",
	storage = "capacity",
	guides = "help",
	["skill-reset"] = "refresh",
	["island-rank"] = "exploration-rank",
	["personal-research"] = "search",
	["technical-support"] = "help",
	modify = "sharpness",
	["home-move"] = "visitor",
	["home-permissions"] = "permission",
	organizations = "clan",
	["sea-chart"] = "exploration-rank",
	["sea-chart-dock"] = "exploration-rank",
	["sea-chart-rift"] = "exploration-rank",
	territory = "claim",
	["siege-match"] = "stance.defense",
	["siege-results"] = "stance.defense",
	transaction = "escrow",
	["direct-trade"] = "escrow",
	dialogue = "social",
	players = "member",
	jobs = "clock",
})

-- Glyph ink on a menu tile (ui-spec bone on the tile's dark fill).
local TILE_GLYPH = table.freeze({ r = 0xED, g = 0xE6, b = 0xD6 })

--- Pack ui icon id of dock entry `id`. A pack can give tiles distinct art through its icon resolver's
--- optional `dock` map (dock id -> ui icon id); without one the genre defaults below apply.
function M.iconId(id: string, icons: any?): string
	local override = if type(icons) == "table" and type(icons.dock) == "table" then icons.dock[id] else nil
	if type(override) == "string" then
		return override
	end
	local info: { number | string } = categories[id] or { 3, "social" }
	return M.DOCK_ICONS[id] or info[2] :: string
end

-- Fallback glyph per menu icon id (IconFallback shapes), shared by menu tiles and sheet headers.
local GLYPHS: { [string]: string } = {
	member = "creature",
	durability = "armor",
	block = "armor",
	claim = "building",
	officer = "creature",
	search = "item",
	["stance.attack"] = "weapon",
	["stance.defense"] = "armor",
	sort = "wood",
	fertility = "seed",
	["processing-budget"] = "tool",
	capacity = "item",
	help = "item",
	refresh = "item",
	["exploration-rank"] = "seed",
	sharpness = "weapon",
	visitor = "building",
	permission = "armor",
	escrow = "item",
	clock = "item",
	bag = "item",
	craft = "tool",
	build = "building",
	capture = "creature",
	skills = "seed",
	energy = "food",
	currency = "stone",
	music = "fiber",
	settings = "tool",
	social = "creature",
	party = "creature",
	clan = "creature",
	invite = "creature",
	explore = "seed",
	journal = "wood",
	todo = "wood",
	market = "food",
	inbox = "item",
}

--- Mounts the icon badge `name` for pack ui icon `iconId` in `parent`: the pack's PNG on a clear
--- badge, or (no published icon) the IconFallback glyph drawn in `ink` on a clear badge. Never the
--- dark filled square an empty slot reads as (lead review of the U3 render).
function M.mountIcon(parent: any, iconId: string, icons: any?, size: any, position: any, name: string, ink: any): any
	local icon = if icons then icons.ui(iconId) else nil
	local image = if icon and icon.image and icon.image ~= "" then icon.image else nil
	local badge = IconFallback.mount(parent, GLYPHS[iconId] or "item", size, position, image, name)
	if badge == nil then
		return nil
	end
	badge.BackgroundTransparency = 1
	local glyph = childNamed(badge, "Glyph")
	if glyph and type(glyph.GetChildren) == "function" then
		for _, part in glyph:GetChildren() do
			if part.ClassName == "Frame" then
				part.BackgroundColor3 = rgb(ink)
			end
		end
	end
	return badge
end

--- Header icon badge of a shell sheet for screen `id` (its menu category icon); `icons` is the
--- pack's icon resolver (options.icons), nil for the fallback glyph only.
function M.shellIcon(frame: any, id: string?, icons: any?, tokens: any)
	local header = childNamed(frame, "Header")
	if not header then
		return
	end
	local S = tokens.space
	M.mountIcon(
		header,
		if id then M.iconId(id, icons) else "inbox",
		icons,
		UDim2.fromOffset(S.icon, S.icon),
		UDim2.new(0, S.pad, 0.5, -S.icon / 2),
		"ShellIcon",
		tokens.colors.headerText
	)
	if id then
		frame:SetAttribute("ForgeShellIcon", id)
	end
end

--- Styles a Components.modalSheet frame as the shell sheet (frame, header, icon, close, scroll).
function M.styleShellFrame(frame: any, tokens: any, size: (string) -> number)
	local C, S = tokens.colors, tokens.space
	frame.BackgroundColor3, frame.BackgroundTransparency = rgb(C.body), 0
	local rim = child(frame, "UIStroke")
	if rim then
		rim.Color, rim.Thickness = rgb(C.rim), 3
	end
	local shade = child(frame, "UIGradient")
	if shade and ColorSequence then
		-- The kit's panel gradient darkens the fill to near-black at the bottom; parchment only warms.
		shade.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(232, 222, 204))
	end
	local header = childNamed(frame, "Header")
	if header then
		header.BackgroundColor3 = rgb(C.header)
		local sheen = child(header, "UIGradient")
		if sheen and ColorSequence then
			sheen.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(214, 204, 192))
		end
		local title = childNamed(header, "Title")
		if title then
			local left = S.pad + S.icon + S.gap
			title.Position = UDim2.fromOffset(left, 0)
			title.Size = UDim2.new(1, -(left + S.close + 6 + S.gap), 1, 0)
			if Enum then
				title.TextXAlignment = Enum.TextXAlignment.Left
			end
			M.styleShellText(title, header, tokens, size)
		end
		local close = childNamed(header, "Close")
		if close then
			M.styleShellText(close, header, tokens, size)
		end
		M.shellIcon(frame, nil, nil, tokens)
	end
	local scroll = childNamed(frame, "Content")
	if scroll then
		scroll.ScrollBarImageColor3 = rgb(C.rim)
		local padding = child(scroll, "UIPadding")
		if padding then
			padding.PaddingLeft, padding.PaddingRight = UDim.new(0, S.pad), UDim.new(0, S.pad)
			padding.PaddingTop, padding.PaddingBottom = UDim.new(0, S.pad), UDim.new(0, S.pad)
		end
		local list = child(scroll, "UIListLayout")
		if list then
			list.Padding = UDim.new(0, S.gap)
		end
	end
end

function M.sheetBounds(width: number, height: number): (number, number)
	local size = Layout.sheetSize({ x = width, y = height })
	return math.min(440, size.x), math.min(520, math.floor(height * 0.7), size.y)
end

function M.sheetPosition(
	width: number,
	height: number,
	sheetWidth: number,
	sheetHeight: number,
	chatRight: number,
	chatBottom: number
): (number, number, number)
	local margin = 12
	local x, y = math.floor((width - sheetWidth) / 2), math.floor((height - sheetHeight) / 2)
	if chatRight <= 0 or chatBottom <= 0 or x >= chatRight or y >= chatBottom then
		return x, y, sheetHeight
	end
	local below = math.min(sheetHeight, height - chatBottom - margin)
	if below >= 240 then
		return x, chatBottom, below
	end
	if chatRight + sheetWidth + margin <= width then
		return math.max(chatRight, x), y, sheetHeight
	end
	return x, y, sheetHeight
end

function M.dockPlacement(width: number, height: number, touch: boolean): string
	return if touch or height > width then "left-center" else "bottom-left"
end

M.factories = {
	require("./ContractsPanel").factory,
	require("./TamingPanel").factory,
	require("./CampPanel").factory,
	require("./ShopPanel").factory,
	require("./MarketPanel").factory,
	require("./DeathZonePanel").factory,
	require("./BrawlPanel").factory,
	require("./ExpeditionPanels").factory,
	require("./OperationPanel").factory,
	-- Renders only while survivalExtensions.rescue is published (opt-in RescueExtension).
	require("./DownPanel").factory,
} :: { Factory }

export type Started = {
	destroy: () -> (),
	closeAll: () -> (),
	open: ((string) -> boolean)?,
}
function M.start(
	options: {
		ui: any,
		locale: string,
		names: { [string]: string }?,
		factories: { Factory }?,
		onOpen: (() -> ())?,
		contextual: boolean?,
		icons: any?,
		launchers: { { id: string, label: string, open: () -> () } }?,
		content: any?,
		-- Robango HUD shell (A4): the objective card sits in the HudShell quest region and the menu
		-- toggle becomes the first pebble of the bottom-left row instead of a top-right button.
		shell: boolean?,
		-- Dock ids kept off the menu grid (id -> reason). The panel still mounts and still opens
		-- through ctx.open / world prompts; only its tile is hidden.
		held: { [string]: string }?,
	}
): Started
	local storage = game:GetService("ReplicatedStorage")
	local http = game:GetService("HttpService")
	local action = storage:WaitForChild("ForgeAction")
	local state = storage:WaitForChild("ForgeState")
	local durable: any = nil
	local latest: { [string]: any } = {}
	local latestPacket: { [string]: any } = {}
	local listeners: { [number]: ({ [string]: any }, { [string]: any }) -> () } = {}
	local nextListener = 0
	local pending: { [string]: any } = {}
	local sendListeners: { [number]: (string, any, any) -> () } = {}
	local nextSendListener = 0
	local lastEncoded: string? = nil
	local connection = state.OnClientEvent:Connect(function(packet)
		if type(packet) ~= "table" then
			return
		end
		if packet.durable then
			durable = packet.durable
		end
		if type(packet.snapshots) == "table" then
			latest = packet.snapshots.survivalExtensions or {}
			latestPacket = packet
			local ok, encoded = pcall(http.JSONEncode, http, packet.snapshots)
			if ok and encoded == lastEncoded then
				return
			end
			lastEncoded = if ok then encoded else nil
			for _, listener in listeners do
				task.spawn(listener, latest, latestPacket)
			end
		end
	end)
	local context: Context = {
		ui = options.ui,
		locale = options.locale,
		names = options.names,
		content = options.content,
		icons = options.icons,
		send = function(actionId, args)
			local epoch = if durable and durable.epochs then durable.epochs[actionId] else nil
			if not CommandTransport.durable(durable, actionId) or (pending[actionId] == nil and epoch == nil) then
				return { ok = false, reason = "COMMAND_UNAVAILABLE" }
			end
			pending[actionId] = CommandTransport.request(pending[actionId], actionId, args, epoch, function()
				return http:GenerateGUID(false)
			end)
			local requestId = pending[actionId].requestId
			local ok, result = pcall(function()
				return action:InvokeServer("command", pending[actionId])
			end)
			if not ok then
				return { ok = false, reason = "TRANSPORT_FAILED: " .. tostring(result) }
			end
			local inFlight = type(result) == "table"
				and (
					result.reason == "COMMAND_PENDING"
					or (type(result.data) == "table" and result.data.status == "recovering")
				)
			pending[actionId] = if type(result) == "table" and not inFlight
				then nil
				else CommandTransport.settle(pending[actionId], result)
			for _, listener in sendListeners do
				task.spawn(listener, actionId, args, result, requestId)
			end
			return result
		end,
		-- Settlement observers (ui.transaction); the same pending request is reused on retry.
		onSend = function(callback)
			nextSendListener += 1
			local key = nextSendListener
			sendListeners[key] = callback
			return function()
				sendListeners[key] = nil
			end
		end,
		onSnapshot = function(callback)
			nextListener += 1
			local key = nextListener
			listeners[key] = callback
			task.spawn(callback, latest, latestPacket)
			return function()
				listeners[key] = nil
			end
		end,
	}
	local players = game:GetService("Players")
	local input = game:GetService("UserInputService")
	local contextual = options.contextual == true
	local shell = contextual and options.shell == true
	local dockGui = Instance.new("ScreenGui")
	dockGui.Name, dockGui.ResetOnSpawn, dockGui.DisplayOrder = "ForgePanelDock", false, 30
	dockGui.ZIndexBehavior, dockGui.ScreenInsets = Enum.ZIndexBehavior.Sibling, Enum.ScreenInsets.CoreUISafeInsets
	dockGui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local column = Instance.new("Frame")
	column.Name, column.BackgroundTransparency, column.Size = "Dock", 1, UDim2.fromOffset(176, 0)
	column.AutomaticSize, column.Parent = Enum.AutomaticSize.Y, dockGui
	local columnLayout = Instance.new("UIListLayout")
	columnLayout.Padding, columnLayout.SortOrder = UDim.new(0, 6), Enum.SortOrder.LayoutOrder
	columnLayout.Parent = column
	if contextual then
		-- This is a single fixed hit target, not an automatically sized list. In
		-- particular, do not collapse its ancestor to zero height every Heartbeat:
		-- input must see the same bounds from pointer down through activation.
		column.AutomaticSize = Enum.AutomaticSize.None
		column.Size = UDim2.fromOffset(64, 44)
		columnLayout:Destroy()
	end
	local objectiveSlot = Instance.new("Frame")
	objectiveSlot.Name, objectiveSlot.BackgroundTransparency, objectiveSlot.LayoutOrder = "Objective", 1, 0
	objectiveSlot.Size, objectiveSlot.AutomaticSize = UDim2.fromScale(1, 0), Enum.AutomaticSize.Y
	objectiveSlot.Parent = column
	if contextual then
		objectiveSlot.Parent = dockGui
		objectiveSlot.AnchorPoint = Vector2.new(1, 0)
		objectiveSlot.Position = UDim2.new(1, -12, 0, 148)
		objectiveSlot.Size = UDim2.fromOffset(216, 56)
		objectiveSlot.AutomaticSize = Enum.AutomaticSize.None
	end
	local slotLayout = Instance.new("UIListLayout")
	slotLayout.Padding, slotLayout.SortOrder = UDim.new(0, 6), Enum.SortOrder.LayoutOrder
	slotLayout.Parent = objectiveSlot
	local menuList = Instance.new(if contextual then "ScrollingFrame" else "Frame")
	menuList.Name, menuList.BackgroundTransparency, menuList.LayoutOrder = "Menu", 1, 2
	menuList.Size, menuList.AutomaticSize = UDim2.fromOffset(176, 0), Enum.AutomaticSize.Y
	menuList.Parent = column
	local menuLayout = Instance.new("UIGridLayout")
	menuLayout.CellPadding, menuLayout.SortOrder = UDim2.fromOffset(6, 6), Enum.SortOrder.LayoutOrder
	menuLayout.CellSize = UDim2.fromOffset(176, 44)
	menuLayout.Parent = menuList
	if contextual then
		menuList.AutomaticSize = Enum.AutomaticSize.None
		menuList.ClipsDescendants = true
		-- place() sizes the canvas from the tile rows (menuCanvas); no AutomaticCanvasSize.
		menuList.AutomaticCanvasSize = Enum.AutomaticSize.None
		menuList.CanvasSize = UDim2.fromOffset(0, 0)
		menuList.ScrollBarThickness = 6
		-- Scroll affordance: a light, opaque bar on the dark tiles shows that more rows sit below.
		menuList.ScrollBarImageColor3, menuList.ScrollBarImageTransparency = Color3.fromRGB(224, 241, 229), 0
		-- Vertical only, so wheel and drag in either direction always move the rows.
		menuList.ScrollingDirection = Enum.ScrollingDirection.Y
		local menuPad = Instance.new("UIPadding")
		menuPad.PaddingTop, menuPad.Parent = UDim.new(0, M.MENU_GAP), menuList
		-- The canvas stops left of the scrollbar, so the bar never covers the last tile column.
		menuList.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	end
	local entries: { DockEntry } = {}
	local sheets: { any } = {}
	local tiles: { any } = {}
	local ui = options.ui
	local theme = ui
		and ui.theme
		and ui.theme.merge(ui.theme.default, {
			font = "GothamMedium",
			colors = {
				bg = { r = 18, g = 28, b = 26 },
				panel = { r = 27, g = 43, b = 40 },
				accent = { r = 67, g = 112, b = 93 },
				text = { r = 240, g = 244, b = 240 },
				onAccent = { r = 240, g = 244, b = 240 },
				muted = { r = 108, g = 148, b = 132 },
				good = { r = 82, g = 192, b = 122 },
				bad = { r = 208, g = 76, b = 68 },
			},
			textSizes = { title = 20, body = 15, small = 13 },
		})
	if ui and theme then
		context.ui = {
			components = ui.components,
			grid = (ui :: any).grid,
			theme = {
				default = theme,
				merge = ui.theme.merge,
			},
		}
	end
	-- Robango C8: panels may lay themselves out full-screen (HudShell.panel) when the shell is on.
	(context :: any).shell = shell
	local menuToggle = ui.components.button(theme, {
		text = if string.sub(options.locale, 1, 2) == "ko" then "메뉴" else "Menu",
		size = UDim2.new(1, 0, 0, 40),
		parent = column,
		onClick = function()
			menuList.Visible = not menuList.Visible
			if contextual then
				menuList.CanvasPosition = Vector2.zero
			end
		end,
	})
	menuToggle.Name, menuToggle.LayoutOrder = "MenuToggle", 1
	if contextual then
		-- A world combat card (shoot/stance) can float behind the screen-space menu button; the
		-- outline keeps the button reading as its own control instead of merging into that card.
		local menuOutline = Instance.new("UIStroke")
		menuOutline.Name, menuOutline.Thickness = "MenuOutline", 2
		menuOutline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		menuOutline.Color, menuOutline.Parent = Color3.fromRGB(240, 244, 240), menuToggle
	end
	if shell then
		local outline = menuToggle:FindFirstChild("MenuOutline")
		if outline then
			outline:Destroy()
		end
		local menuIcon = if options.icons then options.icons.ui(HudShell.TOKEN_ICONS.menu) else nil
		HudShell.iconToken(menuToggle, menuIcon and menuIcon.image, "normal")
	end
	-- Collapsible quest tracker (shell): a round toggle at the card's left; collapsed shows only it.
	local questToggle: any = nil
	local questCollapsed = false
	local function questIcon(id: string): string?
		local icon = if options.icons then options.icons.ui(id) else nil
		return icon and icon.image
	end
	if shell then
		questToggle = ui.components.button(theme, {
			text = "",
			size = UDim2.fromOffset(HudShell.MIN_TOUCH, HudShell.MIN_TOUCH),
			parent = dockGui,
			onClick = function()
				questCollapsed = not questCollapsed
				HudShell.questToggleLook(questToggle, questCollapsed, questIcon)
			end,
		})
		questToggle.Name = "QuestToggle"
		HudShell.questToggleLook(questToggle, questCollapsed, questIcon)
	end
	local function viewport(): any
		return dockGui.AbsoluteSize
	end
	local function compact(): boolean
		local size = viewport()
		return input.TouchEnabled or size.X < 700
	end
	local function actuallyVisible(item: any, stopAt: any): boolean
		local current: any = item
		while current ~= nil and current ~= stopAt do
			if current:IsA("GuiObject") and not current.Visible then
				return false
			end
			current = current.Parent
		end
		return true
	end
	local function chatEdges(): (number, number)
		local chat = players.LocalPlayer.PlayerGui:FindFirstChild("Chat")
		local right, bottom = 0, 0
		if chat ~= nil and chat:IsA("ScreenGui") and chat.Enabled then
			local maxWidth = dockGui.AbsoluteSize.X * 0.6
			local maxHeight = dockGui.AbsoluteSize.Y * 0.75
			for _, item in chat:GetDescendants() do
				if item:IsA("GuiObject") and actuallyVisible(item, chat) then
					local frameSize = item.AbsoluteSize
					local named = item.Name == "ChatWindow"
						or item.Name == "ChatChannelParentFrame"
						or item.Name == "ChatBarParentFrame"
						or item.Name == "ChatBar"
					local sized = frameSize.X >= 80
						and frameSize.Y >= 16
						and frameSize.X <= maxWidth
						and frameSize.Y <= maxHeight
					if named or sized then
						bottom =
							math.max(bottom, item.AbsolutePosition.Y + frameSize.Y - dockGui.AbsolutePosition.Y + 8)
						right = math.max(right, item.AbsolutePosition.X + frameSize.X - dockGui.AbsolutePosition.X + 8)
					end
				end
			end
		end
		return right, bottom
	end
	local function chatBottomEdge(): number
		local _, bottom = chatEdges()
		return bottom
	end
	local function dockHeight(): number
		local h = column.AbsoluteSize.Y
		if menuList.Visible then
			local gridH = objectiveSlot.AbsoluteSize.Y
				+ menuToggle.AbsoluteSize.Y
				+ menuLayout.AbsoluteContentSize.Y
				+ 12
			h = math.max(h, gridH)
		end
		return h
	end
	local lastCompact: boolean? = nil
	-- place() runs every Heartbeat: write only changed values so a scroll is never reset.
	local function set(item: any, key: string, value: any)
		if item[key] ~= value then
			item[key] = value
		end
	end
	local function place()
		local size = viewport()
		local isCompact = compact()
		if contextual then
			menuToggle.Visible = true
			local bounds = HUDModel.contextHudBounds(size.X, size.Y)
			local objective = bounds.objective
			objectiveSlot.AnchorPoint = Vector2.zero
			objectiveSlot.Position = UDim2.fromOffset(objective.x, objective.y)
			objectiveSlot.Size = UDim2.fromOffset(objective.width, objective.height)
			local menu = bounds.menu
			column.AnchorPoint, column.Position = Vector2.zero, UDim2.fromOffset(menu.x, menu.y)
			column.Size = UDim2.fromOffset(menu.width, menu.height)
			if shell then
				-- Quest card under the minimap; the menu toggle is the first token of the bottom-left row.
				local regions = HudShell.regions(size.X, size.Y, HudShell.guiClear(dockGui), input.TouchEnabled)
				local quest = regions.quest
				objectiveSlot.Position = UDim2.fromOffset(quest.x, quest.y)
				objectiveSlot.Size = UDim2.fromOffset(quest.width, quest.height)
				if questToggle then
					local r = regions.questToggle
					set(questToggle, "Position", UDim2.fromOffset(r.x, r.y))
					set(questToggle, "Size", UDim2.fromOffset(r.width, r.height))
				end
				local slot = regions.rowSlots[1]
				column.Position, column.Size =
					UDim2.fromOffset(slot.x, slot.y), UDim2.fromOffset(slot.width, slot.height)
				set(menuToggle, "Size", UDim2.fromScale(1, 1))
				set(menuToggle, "TextSize", HudShell.tokenText("label", regions.safeHeight, input.TouchEnabled))
			end
			set(menuList, "Parent", dockGui)
			local menuX, menuTop, menuWidth, menuHeight, columns, tileHeight =
				M.menuRect(size.X, size.Y, input.TouchEnabled)
			if shell and size.X > size.Y then
				local regions = HudShell.regions(size.X, size.Y, HudShell.guiClear(dockGui), input.TouchEnabled)
				menuX, menuTop, menuWidth, menuHeight, columns, tileHeight =
					M.shellMenuRect(size.X, size.Y, input.TouchEnabled, regions.rowSlots[1])
			end
			local mx, my, mw, mh = HUDModel.chatSafe(size.X, size.Y, menuX, menuTop, menuWidth, menuHeight)
			mh = M.menuRows(mh, tileHeight)
			local shownTiles = 0
			for _, tile in tiles do
				if tile.Visible then
					shownTiles += 1
				end
			end
			if shell then
				-- The shell grid runs the full safe height; it ends after its last row when that fits.
				mh = math.min(mh, M.menuCanvas(shownTiles, columns, tileHeight) - M.MENU_GAP)
			end
			set(menuList, "AnchorPoint", Vector2.zero)
			set(menuList, "Position", UDim2.fromOffset(mx, my))
			set(menuList, "Size", UDim2.fromOffset(mw, mh))
			set(menuLayout, "CellSize", UDim2.fromOffset(M.menuCell(menuWidth, columns), tileHeight))
			-- The layout's own content height wins if it wraps into more rows than predicted.
			local canvas = math.max(
				M.menuCanvas(shownTiles, columns, tileHeight),
				menuLayout.AbsoluteContentSize.Y + 2 * M.MENU_GAP
			)
			set(menuList, "CanvasSize", UDim2.fromOffset(0, canvas))
			objectiveSlot.Visible = not menuList.Visible
				and players.LocalPlayer:GetAttribute("ForgeSurvivalSheetOpen") ~= true
			local open = false
			for _, entry in entries do
				open = open or entry.isOpen()
			end
			-- Shell: a sheet the dock does not own (e.g. the survivor picker) also hides the menu token and
			-- the quest card, so neither draws over its header.
			local foreign = shell and HudShell.sheetOpen(players.LocalPlayer:FindFirstChild("PlayerGui"))
			column.Visible = not open
				and not foreign
				and players.LocalPlayer:GetAttribute("ForgeSurvivalSheetOpen") ~= true
			objectiveSlot.Visible = objectiveSlot.Visible and not open and not foreign
			if questToggle then
				set(questToggle, "Visible", objectiveSlot.Visible)
				objectiveSlot.Visible = objectiveSlot.Visible and not questCollapsed
			end
			players.LocalPlayer:SetAttribute("ForgeExtensionSheetOpen", open or menuList.Visible)
			local sx, sy, sw, sh = HUDModel.contextSheet(size.X, size.Y, input.TouchEnabled)
			if shell then
				sx, sy, sw, sh = M.shellSheet(size.X, size.Y, input.TouchEnabled)
			end
			for _, frame in sheets do
				local owner = frame:FindFirstAncestorWhichIsA("ScreenGui")
				if owner then
					owner.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
				end
				local kind = if shell then frame:GetAttribute("ForgeShellPanel") else nil
				if type(kind) == "string" and owner then
					-- Full-screen panel (ui-spec section 6): the panel lays out its own columns.
					local view = owner.AbsoluteSize
					frame.AnchorPoint = Vector2.zero
					local r = HudShell.panel(view.X, view.Y, HudShell.guiClear(owner), kind).frame
					local badge = frame:FindFirstChild("Header")
					badge = badge and badge:FindFirstChild("ShellIcon")
					if badge then
						-- The full-screen panel title starts at the bar's left edge, where the badge sits.
						badge:Destroy()
					end
					set(frame, "Position", UDim2.fromOffset(r.x, r.y))
					set(frame, "Size", UDim2.fromOffset(r.width, r.height))
					continue
				end
				frame.AnchorPoint, frame.Position = Vector2.zero, UDim2.fromOffset(sx, sy)
				frame.Size = UDim2.fromOffset(sw, sh)
			end
			return
		end
		if lastCompact ~= isCompact then
			lastCompact = isCompact
			menuList.Visible = not isCompact
		end
		local twoWide = isCompact
		local columnWidth = if isCompact then 132 else 176
		column.Size = UDim2.fromOffset(columnWidth, 0)
		menuList.Size = UDim2.fromOffset(if twoWide then columnWidth * 2 + 6 else columnWidth, 0)
		menuLayout.CellSize = UDim2.fromOffset(columnWidth, 44)
		menuToggle.Visible = isCompact
		if M.dockPlacement(size.X, size.Y, input.TouchEnabled) == "left-center" then
			local chatBottom = chatBottomEdge()
			local totalH = dockHeight()
			local centered = math.floor(size.Y / 2 - totalH / 2)
			local reserve = if input.TouchEnabled then 116 else 8
			local aboveStick = math.max(8, size.Y - totalH - reserve)
			local lowest = math.min(math.max(chatBottom, aboveStick), math.max(0, size.Y - totalH - 8))
			column.AnchorPoint = Vector2.new(0, 0)
			column.Position = UDim2.fromOffset(8, math.min(math.max(centered, chatBottom), lowest))
		else
			column.AnchorPoint, column.Position = Vector2.new(0, 1), UDim2.new(0, 12, 1, -12)
		end
		local width, height = M.sheetBounds(size.X, size.Y)
		local chatRight, chatBottom = chatEdges()
		local left, top, fitted = M.sheetPosition(size.X, size.Y, width, height, chatRight, chatBottom)
		for _, frame in sheets do
			frame.AnchorPoint, frame.Position = Vector2.new(0, 0), UDim2.fromOffset(left, top)
			frame.Size = UDim2.fromOffset(width, fitted)
		end
	end
	local restyle: () -> () = function() end
	local resizeConnection = dockGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		place()
		restyle()
	end)
	local lastChatRight, lastChat, lastHeight = -1, -1, -1
	local arrivalSent = false
	local travelSeen: string?, travelUntil = nil, 0
	local followConnection = game:GetService("RunService").Heartbeat:Connect(function()
		if contextual then
			place()
			local tutorial = latest.contracts and latest.contracts.tutorial
			local character = players.LocalPlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if
				tutorial
				and tutorial.step == "arrive"
				and not arrivalSent
				and humanoid
				and humanoid.FloorMaterial ~= Enum.Material.Air
			then
				local actionId = "survival-coop:tutorial-skip-arrival"
				if CommandTransport.durable(durable, actionId) then
					arrivalSent = true
					task.spawn(function()
						context.send(actionId, {})
					end)
				end
			end
			local pivot = character and character:FindFirstChild("HumanoidRootPart")
			local tracker = objectiveSlot:FindFirstChild("ObjectiveTracker")
			local ko = string.sub(options.locale, 1, 2) == "ko"
			local free = pivot ~= nil and tracker ~= nil and not tracker:GetAttribute("ForgeContractsNotice")
			-- Server dock result "<outcome>|<serial>": shown for a few seconds after each change.
			local travel = if free then players.LocalPlayer:GetAttribute("ForgeTravelResult") else nil
			if type(travel) == "string" and travel ~= travelSeen then
				travelSeen, travelUntil = travel, os.clock() + 4
			end
			local stageText = if free
					and options.content
					and game:GetService("Workspace"):GetAttribute("ForgeWorldRole") == "archipelago"
				then M.stageObjectiveText(latest.archipelago, options.content, options.locale, options.names)
				else nil
			if free and travelSeen and os.clock() < travelUntil then
				tracker.Text = M.travelText(options.locale, string.match(travelSeen, "^[^|]+") or travelSeen)
			elseif stageText then
				-- Archipelago roles: the onboarding tutorial does not apply; show the stage.
				tracker.Text = (if ko then "목표: " else "Objective: ") .. stageText
			elseif tutorial and tutorial.step == "gather" then
				if pivot and tracker and not tracker:GetAttribute("ForgeContractsNotice") then
					local candidates = {}
					local params = RaycastParams.new()
					params.FilterType = Enum.RaycastFilterType.Exclude
					params.FilterDescendantsInstances = { character }
					params.RespectCanCollide = true
					for _, node in game:GetService("CollectionService"):GetTagged("ForgeSurvivalNode") do
						if
							node:IsA("BasePart")
							and node:IsDescendantOf(game:GetService("Workspace"))
							and node:GetAttribute("ForgeNodeDepleted") == false
						then
							local hit = game:GetService("Workspace")
								:Raycast(pivot.Position, node.Position - pivot.Position, params)
							table.insert(candidates, {
								target = node,
								distance = (node.Position - pivot.Position).Magnitude,
								available = (node:GetAttribute("ForgeNodeCount") or 0) > 0,
								reachable = hit == nil or hit.Instance == node,
							})
						end
					end
					local nearest = HUDModel.nearestGatherable(candidates)
					if nearest then
						local target = nearest.target
						local kind = target:GetAttribute("ForgeNodeItem") or target:GetAttribute("ForgeNodeKind")
						local label = if options.names then options.names[kind] else nil
						tracker.Text = string.format(
							if ko then "채집: %s (%dm)" else "Gather: %s (%dm)",
							label or kind,
							math.ceil(nearest.distance)
						)
					end
				end
			elseif pivot and tracker and not tracker:GetAttribute("ForgeContractsNotice") then
				local gap = math.huge
				for _, mark in game:GetService("CollectionService"):GetTagged("ForgeSurvey") do
					if not mark:GetAttribute("ForgeSurveyed" .. players.LocalPlayer.UserId) then
						gap = math.min(gap, (mark.Position - pivot.Position).Magnitude)
					end
				end
				if gap < math.huge then
					tracker.Text = string.format(if ko then "조사: %dm" else "Survey: %dm", math.ceil(gap))
				end
			end
			return
		end
		local chatRight, chat = chatEdges()
		local height = column.AbsoluteSize.Y
		if chatRight ~= lastChatRight or chat ~= lastChat or height ~= lastHeight then
			lastChatRight, lastChat, lastHeight = chatRight, chat, height
			place()
		end
	end)
	context.objectiveSlot = objectiveSlot
	-- Sheet shell (D2b fix 3): fitted sheets take the ui-kit Theme.sheet look; their text is styled as
	-- it is parented and re-sized when the viewport changes.
	local tokens = if contextual and ui and ui.theme then ui.theme.sheet else nil
	local function shellSize(style: string): number
		return ui.theme.sheetText(style, dockGui.AbsoluteSize.Y)
	end
	-- U6: SheetCards inside a fitted sheet use the same text scale as its rows.
	context.sheetText = function(style: string): number
		return if tokens then shellSize(style) else 15
	end
	local shellConnections: { any } = {}
	-- Panels fit their sheet and then register its dock entry: that entry names the header icon.
	local lastFitted: any = nil
	local function shellText(frame: any, item: any)
		if tokens and frame:GetAttribute("ForgeShellPanel") == nil and item:IsA("GuiObject") then
			M.styleShellText(item, frame:FindFirstChild("Header"), tokens, shellSize)
		end
	end
	function restyle()
		for _, frame in sheets do
			for _, item in frame:GetDescendants() do
				shellText(frame, item)
			end
		end
	end
	context.fitSheet = function(frame: any)
		local owner = frame:FindFirstAncestorWhichIsA("ScreenGui")
		if owner then
			owner.DisplayOrder = math.max(20, owner.DisplayOrder)
			owner.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		end
		table.insert(sheets, frame)
		if tokens then
			lastFitted = frame
			M.styleShellFrame(frame, tokens, shellSize)
			for _, item in frame:GetDescendants() do
				shellText(frame, item)
			end
			table.insert(
				shellConnections,
				frame.DescendantAdded:Connect(function(item)
					shellText(frame, item)
				end)
			)
		end
		place()
	end
	local function styleTile(button: any, entry: any)
		button.Name, button.LayoutOrder = "Dock-" .. entry.id, entry.order
		if contextual then
			local iconId = M.iconId(entry.id, options.icons)
			button.LayoutOrder = M.tileOrder(entry.id, entry.order)
			button.Text = ""
			-- Tiles stay grouped by category through LayoutOrder (tileOrder); no 11px caption.
			M.mountIcon(
				button,
				iconId,
				options.icons,
				UDim2.fromOffset(M.MENU_ICON, M.MENU_ICON),
				UDim2.new(0, 6, 0.5, -M.MENU_ICON / 2),
				"MenuIconFallback",
				TILE_GLYPH
			)
			local caption = ui.components.label(theme, {
				text = if entry.id == "music" then Locale.text(options.locale, "music") else entry.label,
				parent = button,
				size = UDim2.new(1, -(M.MENU_LABEL_LEFT + M.MENU_LABEL_RIGHT), 1, -4),
				position = UDim2.fromOffset(M.MENU_LABEL_LEFT, 2),
				textSize = M.MENU_LABEL_SIZE,
			})
			caption.Name = "MenuLabel"
			caption.TextScaled, caption.TextWrapped = true, true
			caption.TextXAlignment = Enum.TextXAlignment.Left
			local limit = Instance.new("UITextSizeConstraint")
			limit.MinTextSize, limit.MaxTextSize, limit.Parent = M.MENU_LABEL_MIN, M.MENU_LABEL_SIZE, caption
		end
	end
	local locks: { [string]: { any } } = {}
	context.dock = function(entry: DockEntry): DockHandle
		if options.held and options.held[entry.id] then
			entry = table.clone(entry)
			entry.hidden = true
		end
		table.insert(entries, entry)
		if tokens and lastFitted then
			M.shellIcon(lastFitted, entry.id, options.icons, tokens)
			lastFitted = nil
		end
		locks[entry.id] = { true }
		local function open()
			if options.onOpen then
				options.onOpen()
			end
			M.activate(entries, entry)
			if contextual then
				menuList.Visible = false
			end
		end
		local button = ui.components.button(theme, {
			text = entry.label,
			size = UDim2.new(1, 0, 0, 40),
			parent = menuList,
			onClick = function()
				open()
				if compact() then
					menuList.Visible = false
				end
			end,
		})
		styleTile(button, entry)
		button.Visible = entry.hidden ~= true
		table.insert(tiles, button)
		return {
			open = open,
			setAvailable = function(available: boolean, reason: string?)
				button.Visible = available and entry.hidden ~= true
				locks[entry.id] = { available, reason }
			end,
		}
	end
	place()
	menuList.Visible = not contextual and not compact()
	local launchers: { { id: string, label: string, open: () -> () } } = options.launchers or {}
	for index, launcher in launchers do
		local button = ui.components.button(theme, {
			text = launcher.label,
			size = UDim2.fromOffset(132, 48),
			parent = menuList,
			onClick = function()
				menuList.Visible = false
				for _, entry in entries do
					entry.setOpen(false)
				end
				launcher.open()
			end,
		})
		styleTile(button, { id = launcher.id, label = launcher.label, order = index })
		table.insert(tiles, button)
	end
	-- Navigator ports: open any entry or launcher by id; report (known, available, lock reason).
	context.open = function(id: string): boolean
		for _, entry in entries do
			if entry.id == id and (locks[id] or { true })[1] then
				if options.onOpen then
					options.onOpen()
				end
				M.activate(entries, entry)
				menuList.Visible = false
				return true
			end
		end
		for _, launcher in launchers do
			if launcher.id == id then
				menuList.Visible = false
				for _, entry in entries do
					entry.setOpen(false)
				end
				launcher.open()
				return true
			end
		end
		return false
	end
	context.availability = function(id: string): (boolean, boolean, string?)
		for _, launcher in launchers do
			if launcher.id == id then
				return true, true, nil
			end
		end
		local lock = locks[id]
		return lock ~= nil, lock ~= nil and lock[1] == true, if lock then lock[2] else nil
	end
	local panels: { Panel } = {}
	local function openPanel(panel: string)
		for _, entry in entries do
			if entry.id == panel then
				if options.onOpen then
					options.onOpen()
				end
				M.activate(entries, entry)
				return
			end
		end
		for _, launcher in launchers do
			if launcher.id == panel then
				launcher.open()
				return
			end
		end
	end
	context.openPanel = openPanel
	for _, factory in options.factories or M.factories do
		local panel = factory(context)
		if panel then
			table.insert(panels, panel)
		end
	end
	local destroyed = false
	local harborConnection = game:GetService("ProximityPromptService").PromptTriggered:Connect(function(prompt, player)
		if player and player ~= players.LocalPlayer then
			return
		end
		local panel = prompt:GetAttribute("ForgePanel")
		local holder = prompt.Parent
		-- Practice stands run their content operation; the sheet then shows the outcome.
		local operation = prompt:GetAttribute("ForgeOperation")
		if type(operation) == "string" then
			context.send("survival-coop:operation-run", { operation, "hand" })
			if type(panel) == "string" then
				openPanel(panel)
			end
			return
		end
		local facility = if holder then holder:GetAttribute("ForgeHarborFacility") else nil
		-- Stations (workbench, communication station, market board) carry ForgeDialogue.
		local talk = prompt:GetAttribute("ForgeDialogue")
		local speaker = if type(talk) == "string"
			then talk
			elseif type(facility) == "string" and string.sub(facility, 1, 4) == "npc." then string.sub(facility, 5)
			else nil
		if speaker and context.dialogue then
			if options.onOpen then
				options.onOpen()
			end
			-- NPCs and stations speak first; their service panel is one of the dialogue choices.
			context.dialogue(speaker, if type(panel) == "string" then panel else nil)
			return
		end
		if type(panel) ~= "string" then
			return
		end
		openPanel(panel)
	end)
	return {
		open = context.open,
		closeAll = function()
			if contextual then
				menuList.Visible = false
			end
			for _, entry in entries do
				if entry.isOpen() then
					entry.setOpen(false)
				end
			end
		end,
		destroy = function()
			if destroyed then
				return
			end
			destroyed = true
			harborConnection:Disconnect()
			connection:Disconnect()
			resizeConnection:Disconnect()
			for _, shellConnection in shellConnections do
				shellConnection:Disconnect()
			end
			followConnection:Disconnect()
			dockGui:Destroy()
			table.clear(listeners)
			for _, panel in panels do
				panel.destroy()
			end
		end,
	}
end
return M
