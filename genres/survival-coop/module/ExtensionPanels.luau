--!strict
-- Registry of client panels for survival-coop extensions. Each factory receives
-- the shared UI kit, a durable `send`, a snapshot subscription delivering
-- snapshot.survivalExtensions, and the locale; it returns { destroy }.
-- Packs only call `start`; panel code lives in this genre.
local CommandTransport = require("../../../core/infra/genre/CommandTransport")
local Layout = require("../../../core/ui-kit/Layout")

export type Context = {
	ui: any,
	locale: string,
	send: (string, { any }) -> any,
	-- The listener gets snapshot.survivalExtensions and, second, the whole packet
	-- (snapshots, roster, ...) for panels that also read another snapshot slice.
	onSnapshot: (({ [string]: any }, { [string]: any }) -> ()) -> () -> (),
	-- Registers a launcher button in the shared panel dock. Opening one docked panel closes
	-- the others, so two sheets never stack. `available` hides the button while the panel
	-- has nothing to show. Absent in headless contexts; panels must tolerate nil.
	dock: ((DockEntry) -> DockHandle)?,
	-- Sizes and centers a modal sheet frame for the live viewport (phone and desktop).
	fitSheet: ((any) -> ())?,
	-- The dock column's objective slot: panels may parent one tracker label here.
	objectiveSlot: any?,
}
export type DockEntry = {
	id: string,
	label: string,
	order: number,
	setOpen: (boolean) -> (),
	isOpen: () -> boolean,
}
export type DockHandle = {
	open: () -> (),
	setAvailable: (boolean) -> (),
}
export type Panel = { destroy: () -> () }
export type Factory = (Context) -> Panel?

-- Roblox globals are read from the environment so this module also type-checks under lune.
local env: any = getfenv()
local game: any = env.game
local task: any = env.task
local Instance: any = env.Instance
local Enum: any = env.Enum
local UDim: any = env.UDim
local UDim2: any = env.UDim2
local Vector2: any = env.Vector2

local M = {}
-- Pure placement of the docked panel sheet for a viewport (specced): never wider than 440 or
-- taller than 520, always inside a 12px margin, centered.
function M.sheetBounds(width: number, height: number): (number, number)
	local size = Layout.sheetSize({ x = width, y = height })
	return math.min(440, size.x), math.min(520, math.floor(height * 0.7), size.y)
end

-- Pure placement of a sheet (specced): its top-left corner and height. Centered unless that covers
-- the chat window in the top-left corner. Then the sheet keeps its centered column and starts below
-- the chat, shortened to fit, when at least 240 px remain; the right side belongs to the survival HUD
-- stack, so moving sideways would trade the chat overlap for a HUD overlap. Only when the space below
-- is too short does it move beside the chat, and a viewport too small for both keeps it centered.
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

-- Pure dock placement (specced): a portrait or short phone viewport puts the column at the
-- left edge's vertical center, clear of the chat (top) and the thumbstick (bottom); a desktop
-- viewport anchors it bottom-left where no touch controls exist.
function M.dockPlacement(width: number, height: number, touch: boolean): string
	return if touch or height > width then "left-center" else "bottom-left"
end

M.factories = {
	-- Append panel factories here (one require of ./<Name>Panel per line, then .factory).
	require("./ContractsPanel").factory,
	require("./TamingPanel").factory,
	require("./CampPanel").factory,
	require("./ShopPanel").factory,
	require("./MarketPanel").factory,
	require("./DeathZonePanel").factory,
} :: { Factory }

export type Started = { destroy: () -> (), closeAll: () -> () }
function M.start(options: {
	ui: any,
	locale: string,
	names: { [string]: string }?,
	factories: { Factory }?,
	onOpen: (() -> ())?,
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
			-- The server republishes about once a second even when nothing changed, and every
			-- panel rebuilds its buttons on delivery; a tap whose press and release straddled a
			-- rebuild landed on a destroyed button and did nothing (live shop/camp captures).
			-- Panels are re-rendered only when the snapshots they read actually changed.
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
			local ok, result = pcall(function()
				return action:InvokeServer("command", pending[actionId])
			end)
			if not ok then
				return { ok = false, reason = "TRANSPORT_FAILED: " .. tostring(result) }
			end
			-- An accepted command is a persisted outcome even when the extension returns no
			-- stateVersion (zone-set, contract and camp actions); keeping it pending made the next
			-- press replay this request's args (Studio: "return to safe zone" replayed "danger").
			pending[actionId] = if type(result) == "table" and result.ok == true
				then nil
				else CommandTransport.settle(pending[actionId], result)
			return result
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
	local dockGui = Instance.new("ScreenGui")
	dockGui.Name, dockGui.ResetOnSpawn, dockGui.DisplayOrder = "ForgePanelDock", false, 16
	dockGui.ZIndexBehavior, dockGui.ScreenInsets = Enum.ZIndexBehavior.Sibling, Enum.ScreenInsets.CoreUISafeInsets
	dockGui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local column = Instance.new("Frame")
	column.Name, column.BackgroundTransparency, column.Size = "Dock", 1, UDim2.fromOffset(176, 0)
	column.AutomaticSize, column.Parent = Enum.AutomaticSize.Y, dockGui
	local columnLayout = Instance.new("UIListLayout")
	columnLayout.Padding, columnLayout.SortOrder = UDim.new(0, 6), Enum.SortOrder.LayoutOrder
	columnLayout.Parent = column
	local objectiveSlot = Instance.new("Frame")
	objectiveSlot.Name, objectiveSlot.BackgroundTransparency, objectiveSlot.LayoutOrder = "Objective", 1, 0
	objectiveSlot.Size, objectiveSlot.AutomaticSize = UDim2.fromScale(1, 0), Enum.AutomaticSize.Y
	objectiveSlot.Parent = column
	local slotLayout = Instance.new("UIListLayout")
	slotLayout.Padding, slotLayout.SortOrder = UDim.new(0, 6), Enum.SortOrder.LayoutOrder
	slotLayout.Parent = objectiveSlot
	-- Docked launchers sit in their own list under a Menu toggle. A phone starts collapsed so
	-- the column never covers the avatar; a desktop starts expanded.
	local menuList = Instance.new("Frame")
	menuList.Name, menuList.BackgroundTransparency, menuList.LayoutOrder = "Menu", 1, 2
	menuList.Size, menuList.AutomaticSize = UDim2.fromOffset(176, 0), Enum.AutomaticSize.Y
	menuList.Parent = column
	-- A grid, not a list: one launcher per row ran six launchers 276 px tall, past the bottom
	-- of a landscape phone (843x369 capture: Camp and below unreachable). The cell width
	-- follows the column, two per row when compact.
	local menuLayout = Instance.new("UIGridLayout")
	menuLayout.CellPadding, menuLayout.SortOrder = UDim2.fromOffset(6, 6), Enum.SortOrder.LayoutOrder
	menuLayout.CellSize = UDim2.fromOffset(176, 44)
	menuLayout.Parent = menuList
	local entries: { DockEntry } = {}
	local sheets: { any } = {}
	local ui = options.ui
	-- The dock shares the survival HUD's palette so launchers read as one interface.
	local theme = ui
		and ui.theme
		and ui.theme.merge(ui.theme.default, {
			font = "GothamMedium",
			colors = {
				panel = { r = 27, g = 43, b = 40 },
				accent = { r = 67, g = 112, b = 93 },
				onAccent = { r = 240, g = 244, b = 240 },
			},
			textSizes = { body = 15 },
		})
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
	-- Bottom edge (in dock coordinates) of the visible Roblox chat window, 0 when absent.
	-- The chat window's right and bottom edges in dock space (0, 0 when no chat is shown).
	local function chatEdges(): (number, number)
		local chat = players.LocalPlayer.PlayerGui:FindFirstChild("Chat")
		local right, bottom = 0, 0
		if chat ~= nil and chat:IsA("ScreenGui") and chat.Enabled then
			local maxWidth = dockGui.AbsoluteSize.X * 0.6
			local maxHeight = dockGui.AbsoluteSize.Y * 0.75
			for _, item in chat:GetDescendants() do
				if item:IsA("GuiObject") and item.Visible then
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
	local lastCompact: boolean? = nil
	local function place()
		local size = viewport()
		local isCompact = compact()
		if lastCompact ~= isCompact then
			lastCompact = isCompact
			menuList.Visible = not isCompact
		end
		if M.dockPlacement(size.X, size.Y, input.TouchEnabled) == "left-center" then
			-- The Roblox chat owns the top-left corner. Centering alone put the open menu's first
			-- launcher under a tall chat window (Studio scenario, mobile: chat bottom y 379 vs
			-- Dock-contracts y 376), so the column starts below the chat's live footprint.
			local chatBottom = chatBottomEdge()
			local centered = math.floor(size.Y / 2 - column.AbsoluteSize.Y / 2)
			-- Below the chat when it fits, but never past the bottom edge: the last launcher
			-- must stay tappable even if that means overlapping the chat footprint.
			local lowest = math.max(0, size.Y - column.AbsoluteSize.Y - 8)
			column.AnchorPoint = Vector2.new(0, 0)
			column.Position = UDim2.fromOffset(8, math.min(math.max(centered, chatBottom), lowest))
		else
			column.AnchorPoint, column.Position = Vector2.new(0, 1), UDim2.new(0, 12, 1, -12)
		end
		-- Compact phone viewports get a two-wide launcher grid (three rows for six panels)
		-- so even an open menu fits between the chat and the bottom safe area.
		local twoWide = isCompact
		-- Cells are absolute pixels: the launchers carry a 44 px minimum-size constraint that
		-- collapses scale-sized grid cells to zero width.
		local columnWidth = if isCompact then 132 else 176
		column.Size = UDim2.fromOffset(columnWidth, 0)
		menuList.Size = UDim2.fromOffset(if twoWide then columnWidth * 2 + 6 else columnWidth, 0)
		menuLayout.CellSize = UDim2.fromOffset(columnWidth, 44)
		menuToggle.Visible = isCompact
		local width, height = M.sheetBounds(size.X, size.Y)
		local chatRight, chatBottom = chatEdges()
		local left, top, fitted = M.sheetPosition(size.X, size.Y, width, height, chatRight, chatBottom)
		for _, frame in sheets do
			frame.AnchorPoint, frame.Position = Vector2.new(0, 0), UDim2.fromOffset(left, top)
			frame.Size = UDim2.fromOffset(width, fitted)
		end
	end
	local resizeConnection = dockGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	-- The chat settles over the first seconds and the open menu changes the column height, so
	-- placement follows both each frame and re-runs only when one changes.
	local lastChatRight, lastChat, lastHeight = -1, -1, -1
	local followConnection = game:GetService("RunService").Heartbeat:Connect(function()
		local chatRight, chat = chatEdges()
		local height = column.AbsoluteSize.Y
		if chatRight ~= lastChatRight or chat ~= lastChat or height ~= lastHeight then
			lastChatRight, lastChat, lastHeight = chatRight, chat, height
			place()
		end
	end)
	context.objectiveSlot = objectiveSlot
	context.fitSheet = function(frame: any)
		-- An open sheet is modal: its ScreenGui draws above the survival HUD (15) and the dock (16).
		local owner = frame:FindFirstAncestorWhichIsA("ScreenGui")
		if owner then
			owner.DisplayOrder = 20
		end
		table.insert(sheets, frame)
		place()
	end
	context.dock = function(entry: DockEntry): DockHandle
		table.insert(entries, entry)
		local function open()
			local target = not entry.isOpen()
			for _, other in entries do
				if other ~= entry and other.isOpen() then
					other.setOpen(false)
				end
			end
			entry.setOpen(target)
			if target and options.onOpen then
				options.onOpen()
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
		button.Name, button.LayoutOrder = "Dock-" .. entry.id, entry.order
		return {
			open = open,
			setAvailable = function(available: boolean)
				button.Visible = available
			end,
		}
	end
	place()
	menuList.Visible = not compact()
	local panels: { Panel } = {}
	for _, factory in options.factories or M.factories do
		local panel = factory(context)
		if panel then
			table.insert(panels, panel)
		end
	end
	local destroyed = false
	return {
		-- Closes every open panel sheet (the survival HUD opening its own sheet calls this).
		closeAll = function()
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
