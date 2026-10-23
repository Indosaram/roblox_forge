--!strict
local CommandTransport = require("../../../core/infra/genre/CommandTransport")
local Layout = require("../../../core/ui-kit/Layout")
local HUDModel = require("./SurvivalHUDModel")
local Locale = require("./SurvivalHUDLocale")
local IconFallback = require("../../../core/ui-kit/IconFallback")

export type Context = {
	ui: any,
	locale: string,
	send: (string, { any }) -> any,
	onSnapshot: (({ [string]: any }, { [string]: any }) -> ()) -> () -> (),
	dock: ((DockEntry) -> DockHandle)?,
	fitSheet: ((any) -> ())?,
	objectiveSlot: any?,
	open: ((string) -> boolean)?,
	availability: ((string) -> (boolean, boolean, string?))?,
	onSend: (((string, { any }, any, string?) -> ()) -> () -> ())?,
	openPanel: ((string) -> ())?,
	dialogue: ((string, string?) -> ())?,
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
}
local categoryKeys = { "menu_survival", "menu_world", "menu_social", "menu_shop", "menu_settings" }

local ACTION_LABELS: { [string]: { string } } = {
	survey = { "Survey", "조사" },
	rescue = { "Rescue", "구조" },
	transport = { "Transport", "운송" },
}

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

local TRAVEL_REASONS: { [string]: { string } } = {
	mission_gate = { "Finish this island's objectives first", "이 섬의 목표를 먼저 완료하세요" },
	route_expired = { "This route has expired", "항로가 만료되었습니다" },
	expiry_imminent = {
		"The route expires too soon to travel",
		"항로 만료가 임박해 이동할 수 없습니다",
	},
	expedition_inactive = { "No active route", "진행 중인 항로가 없습니다" },
	missing_expedition = { "No active route", "진행 중인 항로가 없습니다" },
	level_gate = { "Your level is too low for this route", "항로 레벨이 부족합니다" },
	development_gate = { "Raise your island development first", "개발 등급을 먼저 올리세요" },
	instability_gate = { "This route is not unlocked yet", "아직 열리지 않은 항로입니다" },
	dock_unreachable = { "Move closer to the dock", "부두에 더 가까이 가세요" },
	transition_not_allowed = { "Depart from the harbor", "항구에서 출발하세요" },
	studio_no_teleport = {
		"Accepted. Teleport is unavailable in Studio",
		"승인됨. Studio에서는 섬 이동이 불가합니다",
	},
	travelling = { "Travelling...", "이동 중..." },
}

--- Player-visible text for the server's dock travel result (`travelling` or a refusal reason).
function M.travelText(locale: string, result: string): string
	local ko = string.sub(locale, 1, 2) == "ko"
	local row = TRAVEL_REASONS[result]
	if row then
		return row[if ko then 2 else 1]
	end
	return (if ko then "이동할 수 없습니다 (" else "Cannot travel (") .. result .. ")"
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

function M.menuBounds(width: number, height: number): (number, number, number, number)
	local landscape = width > height
	local columns = if landscape and height < 400 then 10 elseif landscape then 6 else 4
	return math.min(720, width - 24), columns, if landscape and height < 400 then 56 else 64, 116
end
-- Contextual menu grid: 6px cell gap, and the ScrollingFrame's 6px scrollbar clips the
-- right edge of its canvas, so tiles only get the width left of the scrollbar.
M.MENU_GAP, M.MENU_SCROLLBAR, M.MENU_MIN_TILE = 6, 6, 44
-- Width of one tile when `columns` tiles share a `menuWidth` menu frame.
function M.menuCell(menuWidth: number, columns: number): number
	return math.floor((menuWidth - M.MENU_SCROLLBAR - (columns - 1) * M.MENU_GAP) / columns)
end
-- Canvas height: top gap (first header unclipped), rows, bottom gap (last row reachable).
-- The dock sets this explicitly; AutomaticCanvasSize with the UIGridLayout came out one row
-- short in Studio (p36: 414px canvas for 7 rows, last row unreachable at 1076x634).
function M.menuCanvas(count: number, columns: number, tile: number): number
	local rows = math.ceil(count / math.max(1, columns))
	return M.MENU_GAP + rows * (tile + M.MENU_GAP)
end
-- Short landscape: contextSheet's thumb-gutter rule. The column count is the design count
-- capped by how many touch-sized tiles fit the width left of the scrollbar. The grid always
-- starts one gap below the HUD menu button and, on a portrait phone, below Roblox's chat.
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
	end
	local fit = math.floor((w - M.MENU_SCROLLBAR + M.MENU_GAP) / (M.MENU_MIN_TILE + M.MENU_GAP))
	return x, top, w, h, math.max(1, math.min(columns, fit)), tile
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
} :: { Factory }

export type Started = { destroy: () -> (), closeAll: () -> () }
function M.start(options: {
	ui: any,
	locale: string,
	names: { [string]: string }?,
	factories: { Factory }?,
	onOpen: (() -> ())?,
	contextual: boolean?,
	icons: any?,
	launchers: { { id: string, label: string, open: () -> () } }?,
	content: any?,
}): Started
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
	local menuToggle = ui.components.button(theme, {
		text = if string.sub(options.locale, 1, 2) == "ko" then "메뉴" else "Menu",
		size = UDim2.new(1, 0, 0, 40),
		parent = column,
		onClick = function()
			menuList.Visible = not menuList.Visible
		end,
	})
	menuToggle.Name, menuToggle.LayoutOrder = "MenuToggle", 1
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
			set(menuList, "Parent", dockGui)
			local menuX, menuTop, menuWidth, menuHeight, columns, tileHeight =
				M.menuRect(size.X, size.Y, input.TouchEnabled)
			local mx, my, mw, mh = HUDModel.chatSafe(size.X, size.Y, menuX, menuTop, menuWidth, menuHeight)
			set(menuList, "AnchorPoint", Vector2.zero)
			set(menuList, "Position", UDim2.fromOffset(mx, my))
			set(menuList, "Size", UDim2.fromOffset(mw, mh))
			set(menuLayout, "CellSize", UDim2.fromOffset(M.menuCell(menuWidth, columns), tileHeight))
			local shownTiles = 0
			for _, tile in tiles do
				if tile.Visible then
					shownTiles += 1
				end
			end
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
			column.Visible = not open and players.LocalPlayer:GetAttribute("ForgeSurvivalSheetOpen") ~= true
			objectiveSlot.Visible = objectiveSlot.Visible and not open
			players.LocalPlayer:SetAttribute("ForgeExtensionSheetOpen", open or menuList.Visible)
			local sx, sy, sw, sh = HUDModel.contextSheet(size.X, size.Y, input.TouchEnabled)
			for _, frame in sheets do
				local owner = frame:FindFirstAncestorWhichIsA("ScreenGui")
				if owner then
					owner.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
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
	local resizeConnection = dockGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
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
	context.fitSheet = function(frame: any)
		local owner = frame:FindFirstAncestorWhichIsA("ScreenGui")
		if owner then
			owner.DisplayOrder = math.max(20, owner.DisplayOrder)
			owner.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		end
		table.insert(sheets, frame)
		place()
	end
	local function styleTile(button: any, entry: any)
		button.Name, button.LayoutOrder = "Dock-" .. entry.id, entry.order
		if contextual then
			local info: { number | string } = categories[entry.id] or { 3, "social" }
			local category, iconId = info[1] :: number, info[2] :: string
			button.LayoutOrder = category * 100 + entry.order
			button.Text = ""
			local heading = ui.components.label(theme, {
				text = Locale.text(options.locale, categoryKeys[category]),
				parent = button,
				size = UDim2.new(1, 0, 0, 16),
				textSize = 11,
			})
			heading.TextColor3 = Color3.fromRGB(224, 241, 229)
			heading.TextXAlignment = Enum.TextXAlignment.Center
			local icon = if options.icons then options.icons.ui(iconId) else nil
			local glyphs = {
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
			IconFallback.mount(
				button,
				glyphs[iconId],
				UDim2.fromOffset(20, 20),
				UDim2.new(0.5, -10, 0, 17),
				if icon then icon.image else nil,
				"MenuIconFallback"
			)
			local caption = ui.components.label(theme, {
				text = if entry.id == "music" then Locale.text(options.locale, "music") else entry.label,
				parent = button,
				size = UDim2.new(1, -4, 0, 16),
				position = UDim2.new(0, 2, 1, -17),
				textSize = 11,
			})
			caption.TextScaled, caption.TextWrapped = true, true
			caption.TextXAlignment = Enum.TextXAlignment.Center
			local limit = Instance.new("UITextSizeConstraint")
			limit.MinTextSize, limit.MaxTextSize, limit.Parent = 8, 12, caption
		end
	end
	local locks: { [string]: { any } } = {}
	context.dock = function(entry: DockEntry): DockHandle
		table.insert(entries, entry)
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
