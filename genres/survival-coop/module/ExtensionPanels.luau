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
	shop = { 4, "currency" },
	music = { 5, "music" },
	audio = { 5, "settings" },
	sound = { 5, "settings" },
}
local categoryKeys = { "menu_survival", "menu_world", "menu_social", "menu_shop", "menu_settings" }

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
			local inFlight = type(result) == "table"
				and (
					result.reason == "COMMAND_PENDING"
					or (type(result.data) == "table" and result.data.status == "recovering")
				)
			pending[actionId] = if type(result) == "table" and not inFlight
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
		menuList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		menuList.CanvasSize = UDim2.fromOffset(0, 0)
		menuList.ScrollBarThickness = 6
	end
	local entries: { DockEntry } = {}
	local sheets: { any } = {}
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
			menuList.Parent = dockGui
			local menuWidth, columns, tileHeight, menuTop = M.menuBounds(size.X, size.Y)
			menuList.AnchorPoint = Vector2.new(0.5, 0)
			menuList.Position = UDim2.new(0.5, 0, 0, menuTop)
			local menuHeight = math.max(0, size.Y - menuTop - 128)
			menuList.Size = UDim2.fromOffset(menuWidth, menuHeight)
			local mx, my, mw, mh =
				HUDModel.chatSafe(size.X, size.Y, (size.X - menuWidth) / 2, menuTop, menuWidth, menuHeight)
			menuList.AnchorPoint, menuList.Position, menuList.Size =
				Vector2.zero, UDim2.fromOffset(mx, my), UDim2.fromOffset(mw, mh)
			menuLayout.CellSize = UDim2.fromOffset(math.floor((menuWidth - (columns - 1) * 6) / columns), tileHeight)
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
			if tutorial and tutorial.step == "gather" then
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
	context.dock = function(entry: DockEntry): DockHandle
		table.insert(entries, entry)
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
		return {
			open = open,
			setAvailable = function(available: boolean)
				button.Visible = available
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
	end
	local panels: { Panel } = {}
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
		if type(panel) ~= "string" then
			return
		end
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
