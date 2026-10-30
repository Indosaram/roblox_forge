--!strict
local Model = require("./SurvivalHUDModel")
local RecipeMarks = require("./RecipeMarks")
local BuildPlacement = require("./BuildPlacement")
local Locale = require("./SurvivalHUDLocale")
local HudShell = require("./HudShell")
local IconFallback = require("../../../core/ui-kit/IconFallback")
local CharacterRules = require("./CharacterRules")
local Spoilage = require("../../../core/domain/survival/Spoilage")
local M = {}
M.NOTICE_SECONDS = 5
M.REFUSAL_SECONDS = 8

M.toasted = {
	WEAPON_UNAVAILABLE = true,
	PLACEMENT_UNREACHABLE = true,
	PLACEMENT_UNSUPPORTED = true,
	PLACEMENT_BLOCKED = true,
	PLACEMENT_BLOCKED_CREATURE = true,
	WAREHOUSE_UNREACHABLE = true,
}
M.TOAST_SECONDS = 6

function M.controls(components: any, theme: any, parent: any, fit: ((Instance) -> ())?): any
	local entries: { [string]: any } = {}
	local present: { [string]: boolean } = {}
	local order, scope = 0, ""
	local controls = { parent = parent }
	function controls.begin(section: string)
		present, order, scope = {}, 0, section
	end
	function controls.order(): number
		order += 1
		return order
	end
	function controls.button(id: string, text: string, callback: () -> (), enabled: boolean): any
		local key = scope .. ":" .. id
		present[key] = true
		local entry = entries[key]
		if not entry then
			entry = {}
			entries[key] = entry
			entry.item = components.button(theme, {
				text = text,
				size = UDim2.new(1, -8, 0, 48),
				parent = parent,
				onClick = function()
					if entry.enabled then
						entry.callback()
					end
				end,
			})
		end
		entry.callback, entry.enabled = callback, enabled
		local item = entry.item
		item.Parent = controls.parent or parent
		item.Name, item.Text, item.TextWrapped, item.TextScaled = id, text, true, true
		if fit ~= nil then
			fit(item)
		end
		item.LayoutOrder = controls.order()
		item.Active, item.Selectable, item.AutoButtonColor, item.Interactable = enabled, enabled, enabled, enabled
		item.BackgroundTransparency = if enabled then 0 else 0.7
		return item
	end
	function controls.finish()
		for key, entry in entries do
			if not present[key] then
				entry.enabled = false
				entry.item:Destroy()
				entries[key] = nil
			end
		end
	end
	return controls
end

export type Options = {
	ui: { components: any, grid: any, theme: any },
	content: any,
	icons: any?,
	locale: string?,
	settlementOrigin: Vector3,
	names: { [string]: string }?,
	contextual: boolean?,
	openPanel: ((string) -> boolean)?,
	-- Melee attack press on a creature model: hands it to the pack's combat loop (CombatHud.engage);
	-- true when engaged. Absent sends one raw attack command per press.
	engage: ((Model) -> boolean)?,
	-- Landscape HUD shell (ui-spec "Tideglass", Robango A4); used only with contextual = true.
	-- `name(kind, key)` labels world entities; `open(id)` opens a panel by id (the mount token opens
	-- "taming"). The menu token is ExtensionPanels' own toggle (its shell option), in row slot 1.
	shell: {
		name: (string, string) -> string?,
		-- Optional second world-label line (`kind`, labelled instance): HudShell OverlayOptions.hint.
		hint: ((string, any) -> string?)?,
		open: (string) -> (),
		-- C4 pet ring (optional): `capturable()` is true while a downed tameable target is in reach;
		-- the capture / dismount / pet tokens call `act(id)`. Absent keeps the panel-only flow.
		pet: {
			capturable: () -> boolean,
			act: (string) -> (),
		}?,
		-- false: no chat token in the bottom-left row (single-player mode). Default true.
		chat: boolean?,
		-- false: the own name tag drops its clan line ("No clan"). Default true.
		clanTag: boolean?,
	}?,
}

function M.start(options: Options)
	local Components, Grid, Theme = options.ui.components, options.ui.grid, options.ui.theme
	local players = game:GetService("Players")
	local player = players.LocalPlayer
	local storage = game:GetService("ReplicatedStorage")
	local world = game:GetService("Workspace")
	local tags = game:GetService("CollectionService")
	local input = game:GetService("UserInputService")
	local run = game:GetService("RunService")
	local http = game:GetService("HttpService")
	local action = storage:WaitForChild("ForgeAction") :: RemoteFunction
	local state = storage:WaitForChild("ForgeState") :: RemoteEvent
	local locale = options.locale or player.LocaleId
	local content = options.content
	local contextual = options.contextual == true
	local shell = if contextual then options.shell else nil
	-- Keyboard hints: a trailing " [I]" and any {{...}} span (e.g. "가방{{(I)}}", "{{ Y로 회전한 뒤}}")
	-- show only while a keyboard is the input; on a touch-only phone they are dropped (p134 v61).
	local function t(key: string): string
		return Locale.keyHints(Locale.text(locale, key), input.TouchEnabled and not input.KeyboardEnabled)
	end
	local function name(id: string): string
		return if options.names and options.names[id] then options.names[id] else t(id)
	end
	local theme = Theme.merge(Theme.default, {
		font = "Gotham",
		colors = {
			bg = { r = 18, g = 28, b = 26 },
			panel = { r = 27, g = 43, b = 40 },
			accent = { r = 67, g = 112, b = 93 },
			text = { r = 240, g = 244, b = 240 },
			onAccent = { r = 240, g = 244, b = 240 },
			muted = { r = 108, g = 148, b = 132 },
		},
	})
	local model = Model.new(tostring(player.UserId), function()
		return http:GenerateGUID(false)
	end)
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "ForgeSurvivalHUD", false, 15
	gui.ScreenInsets, gui.ZIndexBehavior = Enum.ScreenInsets.CoreUISafeInsets, Enum.ZIndexBehavior.Sibling
	local root = Instance.new("Frame")
	root.Name, root.BackgroundTransparency = "SafeArea", 1
	root.Position, root.Size, root.Parent = UDim2.fromOffset(12, 8), UDim2.new(1, -24, 1, -16), gui
	local vitals =
		Components.label(theme, { text = t("loading"), size = UDim2.new(1, 0, 0, 52), parent = root, textSize = 15 })
	vitals.Name = "Vitals"
	vitals.BackgroundColor3, vitals.BackgroundTransparency = Color3.fromRGB(22, 36, 33), if shell then 0.45 else 0.08
	pcall(function()
		local vc = Instance.new("UICorner")
		vc.CornerRadius = UDim.new(0, 8)
		vc.Parent = vitals
		local vs = Instance.new("UIStroke")
		vs.Color, vs.Thickness, vs.Transparency = Color3.fromRGB(88, 138, 114), 1.2, 0.25
		vs.Parent = vitals
	end)
	local statBars: { [string]: any } = {}
	-- HUD polish (shell): slim icon + bar + number rows sized by HudShell.vitalsRows; the stat word is
	-- dropped (the icon carries it) and a level badge sits at the panel's left.
	local levelBadge: TextLabel? = nil
	local levelNumber: TextLabel? = nil
	if shell then
		local badge = Instance.new("TextLabel")
		badge.Name, badge.BackgroundColor3 = "Level", HudShell.color(HudShell.PALETTE.tealDeep)
		badge.TextColor3, badge.Font = HudShell.color(HudShell.PALETTE.bone), Enum.Font.BuilderSansBold
		badge.Text, badge.Parent = "", vitals
		local round = Instance.new("UICorner")
		round.CornerRadius, round.Parent = UDim.new(0.5, 0), badge
		local ring = Instance.new("UIStroke")
		ring.Color, ring.Thickness, ring.Parent = HudShell.color(HudShell.PALETTE.ochre), 2, badge
		levelBadge = badge
		-- Portrait in the ring (Durango R05-1 / R08-1); the painted member icon stands in until it loads.
		local fallback = if options.icons then options.icons.ui("member") else nil
		levelNumber = HudShell.levelPortrait(badge, players, player.UserId, fallback and fallback.image)
	end
	for index, stat in { "health", "hunger", "fatigue" } do
		local icon = if options.icons then options.icons.ui(if stat == "hunger" then "energy" else stat) else nil
		local rowY = Model.VITALS.rowTop + (index - 1) * Model.VITALS.rowStep
		local symbol = Instance.new("TextLabel")
		symbol.Name, symbol.BackgroundTransparency = stat .. "Icon", 1
		symbol.Position = UDim2.fromOffset(Model.VITALS.labelX, rowY)
		symbol.Size = UDim2.fromOffset(Model.VITALS.labelWidth, Model.VITALS.rowHeight)
		symbol.TextXAlignment = Enum.TextXAlignment.Left
		symbol.Text, symbol.TextColor3, symbol.TextSize = t(stat), Color3.fromRGB(240, 244, 240), Model.VITALS.textSize
		symbol.TextScaled = true
		local textLimit = Instance.new("UITextSizeConstraint")
		textLimit.MinTextSize, textLimit.MaxTextSize, textLimit.Parent =
			Model.VITALS.textSize, Model.VITALS.textSize, symbol
		if icon and icon.image then
			local image = Instance.new("ImageLabel")
			image.Name, image.BackgroundTransparency = stat .. "Asset", 1
			local size = Model.VITALS.iconSize
			image.Size = UDim2.fromOffset(size, size)
			image.Position = UDim2.fromOffset(Model.VITALS.iconX, rowY + (Model.VITALS.rowHeight - size) / 2)
			image.Image, image.Parent = icon.image, vitals
		end
		symbol.Parent = vitals
		local track = Instance.new("Frame")
		track.Name, track.BorderSizePixel, track.BackgroundColor3 = stat .. "Track", 0, Color3.fromRGB(45, 62, 56)
		track.Position, track.Size, track.Parent =
			UDim2.fromOffset(Model.VITALS.trackX, rowY + Model.VITALS.rowHeight / 2 - 4),
			UDim2.new(1, -(Model.VITALS.trackX + Model.VITALS.trackRight), 0, 8),
			vitals
		local fill = Instance.new("Frame")
		fill.Name, fill.BorderSizePixel = "Fill", 0
		fill.BackgroundColor3 = ({
			health = Color3.fromRGB(107, 207, 142),
			hunger = Color3.fromRGB(232, 190, 97),
			fatigue = Color3.fromRGB(119, 181, 220),
		})[stat]
		fill.Size, fill.Parent = UDim2.fromScale(1, 1), track
		for _, frame in { track, fill } do
			local corner = Instance.new("UICorner")
			corner.CornerRadius, corner.Parent = UDim.new(0, 4), frame
		end
		local value = Components.label(theme, {
			text = "",
			textSize = Model.VITALS.textSize,
			parent = vitals,
			size = UDim2.fromOffset(38, Model.VITALS.rowHeight),
			position = UDim2.new(1, -42, 0, rowY),
		})
		statBars[stat] = {
			fill = fill,
			value = value,
			symbol = symbol,
			track = track,
			icon = vitals:FindFirstChild(stat .. "Asset"),
		}
	end
	local coins = Components.label(theme, { text = "", size = UDim2.fromOffset(100, 28), parent = root, textSize = 13 })
	coins.Name, coins.Visible, coins.BackgroundColor3 = "Coins", false, Color3.fromRGB(22, 36, 33)
	if shell then
		-- Currency chip: an ink pill with the shell-money icon and the amount (no loose text line).
		coins.BackgroundColor3, coins.BackgroundTransparency = HudShell.color(HudShell.PALETTE.ink), 0.35
		coins.TextColor3, coins.Font = HudShell.color(HudShell.PALETTE.bone), Enum.Font.BuilderSansBold
		coins.TextXAlignment = Enum.TextXAlignment.Left
		local round = Instance.new("UICorner")
		round.CornerRadius, round.Parent = UDim.new(0.5, 0), coins
		local rim = Instance.new("UIStroke")
		rim.Name, rim.ApplyStrokeMode = "ChipRim", Enum.ApplyStrokeMode.Border
		rim.Color, rim.Thickness, rim.Transparency, rim.Parent = HudShell.color(HudShell.PALETTE.ochre), 1.5, 0.2, coins
		local coinIcon = if options.icons then options.icons.ui("currency") else nil
		if coinIcon and coinIcon.image then
			local image = Instance.new("ImageLabel")
			image.Name, image.BackgroundTransparency, image.Image = "CoinIcon", 1, coinIcon.image
			image.ScaleType, image.Parent = Enum.ScaleType.Fit, coins
		end
	end
	local status = Components.label(theme, {
		text = t("loading"),
		size = UDim2.new(1, 0, 0, 64),
		position = UDim2.fromOffset(0, 56),
		parent = root,
		textSize = 14,
	})
	status.Name = "Status"
	status.TextScaled = true
	local statusLimit = Instance.new("UITextSizeConstraint")
	statusLimit.MaxTextSize, statusLimit.MinTextSize, statusLimit.Parent = 14, 8, status
	status.BackgroundColor3, status.BackgroundTransparency = Color3.fromRGB(22, 36, 33), 0.08
	pcall(function()
		local sc = Instance.new("UICorner")
		sc.CornerRadius = UDim.new(0, 8)
		sc.Parent = status
		local ss = Instance.new("UIStroke")
		ss.Color, ss.Thickness, ss.Transparency = Color3.fromRGB(88, 138, 114), 1.2, 0.25
		ss.Parent = status
	end)
	local toolbar = Instance.new("Frame")
	toolbar.Name, toolbar.BackgroundTransparency = "Navigation", 1
	toolbar.Position, toolbar.Size, toolbar.Parent = UDim2.fromOffset(0, 124), UDim2.new(1, 0, 0, 48), root
	local tracker =
		Components.label(theme, { text = "", size = UDim2.fromOffset(216, 50), parent = root, textSize = 13 })
	tracker.Name, tracker.Visible = "RecipeTracker", false
	tracker.TextXAlignment, tracker.TextYAlignment, tracker.TextWrapped =
		Enum.TextXAlignment.Left, Enum.TextYAlignment.Top, true
	tracker.BackgroundColor3, tracker.BackgroundTransparency = Color3.fromRGB(22, 36, 33), 0.15
	local sheet = Components.modalSheet(theme, { name = "SurvivalSheet", title = "", parent = root })
	-- Robango C8 full-screen craft / bag layout (HudShell.panel), set by resize() while one is open.
	local panelLayout: any = nil
	local function fitText(item: Instance): ()
		local existing = item:FindFirstChild("ForgeTextFit")
		local constraint: UITextSizeConstraint
		if existing ~= nil and existing:IsA("UITextSizeConstraint") then
			constraint = existing
		else
			if existing ~= nil then
				existing:Destroy()
			end
			constraint = Instance.new("UITextSizeConstraint")
			constraint.Name, constraint.Parent = "ForgeTextFit", item
		end
		constraint.MinTextSize, constraint.MaxTextSize =
			if panelLayout then HudShell.PANEL_MIN_TEXT else 10, if panelLayout then panelLayout.text.body else 15
	end
	sheet.frame.Visible = false
	local controls = M.controls(Components, theme, sheet.scroll, fitText)
	sheet.frame.AnchorPoint, sheet.frame.Position = Vector2.new(1, 0), UDim2.new(1, 0, 0, 178)
	sheet.close.Text = "X"
	local panes = Instance.new("Frame")
	panes.Name, panes.BackgroundTransparency = "PanelPanes", 1
	panes.Size, panes.AutomaticSize, panes.Parent = UDim2.new(1, -8, 0, 0), Enum.AutomaticSize.Y, sheet.scroll
	local listPane, detailPane = Instance.new("ScrollingFrame"), Instance.new("ScrollingFrame")
	for _, pane in { listPane, detailPane } do
		pane.BackgroundTransparency, pane.AutomaticSize, pane.Parent = 1, Enum.AutomaticSize.Y, panes
		pane.BorderSizePixel, pane.ScrollBarThickness, pane.CanvasSize = 0, 6, UDim2.new()
		pane.AutomaticCanvasSize = Enum.AutomaticSize.Y
		local layout = Instance.new("UIListLayout")
		layout.Padding, layout.SortOrder, layout.Parent = UDim.new(0, 6), Enum.SortOrder.LayoutOrder, pane
	end
	listPane.Name, detailPane.Name = "ItemList", "ItemDetails"
	local craftActions = Instance.new("Frame")
	panes.ZIndex, craftActions.ZIndex = 52, 52
	craftActions.Name, craftActions.BackgroundTransparency, craftActions.Parent = "CraftActions", 1, sheet.frame
	craftActions.Position, craftActions.Size = UDim2.new(0, 8, 1, -56), UDim2.new(1, -16, 0, 48)
	local actionLayout = Instance.new("UIListLayout")
	actionLayout.FillDirection, actionLayout.Padding, actionLayout.Parent =
		Enum.FillDirection.Horizontal, UDim.new(0, 6), craftActions
	-- Full-screen craft / bag panel (ui-spec section 6, Robango C8; shell only): categories (craft) or
	-- the equipment doll (bag) on the left, the list in the middle, the detail on the right and the
	-- one primary button (craftActions) at the detail's bottom.
	local categoryPane = Instance.new("ScrollingFrame")
	categoryPane.Name, categoryPane.BackgroundTransparency, categoryPane.Visible = "Categories", 1, false
	categoryPane.BorderSizePixel, categoryPane.ScrollBarThickness = 0, 6
	categoryPane.CanvasSize, categoryPane.AutomaticCanvasSize = UDim2.new(), Enum.AutomaticSize.Y
	categoryPane.ZIndex, categoryPane.Parent = 52, sheet.frame
	local categoryLayout = Instance.new("UIListLayout")
	categoryLayout.Padding, categoryLayout.SortOrder, categoryLayout.Parent =
		UDim.new(0, 6), Enum.SortOrder.LayoutOrder, categoryPane
	local filterBar = Instance.new("ScrollingFrame")
	filterBar.Name, filterBar.BackgroundTransparency, filterBar.Visible = "Filters", 1, false
	filterBar.BorderSizePixel, filterBar.ScrollBarThickness = 0, 4
	filterBar.ScrollingDirection, filterBar.Size = Enum.ScrollingDirection.X, UDim2.new(1, -8, 0, 50)
	filterBar.CanvasSize, filterBar.AutomaticCanvasSize = UDim2.new(), Enum.AutomaticSize.X
	filterBar.LayoutOrder, filterBar.Parent = 0, listPane
	local filterLayout = Instance.new("UIListLayout")
	filterLayout.FillDirection, filterLayout.Padding, filterLayout.SortOrder, filterLayout.Parent =
		Enum.FillDirection.Horizontal, UDim.new(0, 6), Enum.SortOrder.LayoutOrder, filterBar
	local currency =
		Components.label(theme, { text = "", size = UDim2.fromOffset(140, 32), parent = sheet.frame, textSize = 15 })
	currency.Name, currency.Visible, currency.ZIndex = "Currency", false, 53
	-- Shell money pill: ochre with ink text (ui-spec section 1).
	currency.BackgroundColor3, currency.BackgroundTransparency = HudShell.color(HudShell.PALETTE.ochre), 0
	currency.TextColor3 = HudShell.color(HudShell.PALETTE.ink)
	local pill = Instance.new("UICorner")
	pill.CornerRadius, pill.Parent = UDim.new(0.5, 0), currency
	local panelCategory, bagFilter = "all", "all"
	local characterGear: any = nil
	local function fitPanes()
		if panelLayout then
			panes.Parent, panes.AutomaticSize = sheet.frame, Enum.AutomaticSize.None
			panes.Position, panes.Size = UDim2.new(), UDim2.fromScale(1, 1)
			listPane.AutomaticSize, detailPane.AutomaticSize = Enum.AutomaticSize.None, Enum.AutomaticSize.None
			local frameAt = Vector2.new(panelLayout.frame.x, panelLayout.frame.y)
			HudShell.put(listPane, panelLayout.list, frameAt)
			HudShell.put(detailPane, panelLayout.detailBody, frameAt)
			HudShell.put(categoryPane, panelLayout.categories, frameAt)
			HudShell.put(craftActions, panelLayout.primary, frameAt)
			return
		end
		if craftActions.Visible then
			local bounds = Model.craftPanes(sheet.frame.AbsoluteSize.X, sheet.frame.AbsoluteSize.Y)
			panes.Parent, panes.Position, panes.Size =
				sheet.frame, UDim2.fromOffset(8, 44), UDim2.new(1, -16, 0, bounds.height)
			panes.AutomaticSize = Enum.AutomaticSize.None
			listPane.AutomaticSize, detailPane.AutomaticSize = Enum.AutomaticSize.None, Enum.AutomaticSize.None
			local side = bounds.listHeight < 102 and sheet.frame.AbsoluteSize.X >= 400
			local listHeight = Model.wholeRows(if side then bounds.height else bounds.listHeight, 48, 6)
			listPane.Size = UDim2.new(if side then 0.5 else 1, -4, 0, listHeight)
			detailPane.Size =
				UDim2.new(if side then 0.5 else 1, -4, 0, bounds.height - (if side then 0 else listHeight + 8))
			detailPane.Position = if side then UDim2.new(0.5, 4, 0, 0) else UDim2.fromOffset(0, listHeight + 8)
			return
		end
		panes.Parent, panes.Position, panes.Size = sheet.scroll, UDim2.new(), UDim2.new(1, -8, 0, 0)
		panes.AutomaticSize, listPane.AutomaticSize, detailPane.AutomaticSize =
			Enum.AutomaticSize.Y, Enum.AutomaticSize.Y, Enum.AutomaticSize.Y
		local wide = sheet.frame.AbsoluteSize.X >= 600
		listPane.Size = UDim2.new(if wide then 0.52 else 1, if wide then -8 else 0, 0, 0)
		detailPane.Size = UDim2.new(if wide then 0.48 else 1, if wide then -8 else 0, 0, 0)
		detailPane.Position = if wide
			then UDim2.new(0.52, 8, 0, 0)
			else UDim2.fromOffset(0, listPane.AbsoluteSize.Y + 12)
	end
	listPane:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitPanes)
	sheet.frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitPanes)
	fitPanes()
	local contentParent = sheet.scroll
	local capacityTrack = Instance.new("Frame")
	capacityTrack.Name, capacityTrack.BorderSizePixel = "CapacityBar", 0
	capacityTrack.Size, capacityTrack.BackgroundColor3 = UDim2.new(1, -8, 0, 8), Color3.fromRGB(45, 62, 56)
	capacityTrack.Parent = listPane
	local capacityFill = Instance.new("Frame")
	capacityFill.Name, capacityFill.BorderSizePixel = "Fill", 0
	capacityFill.BackgroundColor3, capacityFill.Parent = Color3.fromRGB(127, 224, 156), capacityTrack
	local section, selected, recipeId, structureId = "", nil, nil, nil
	local ghostLocked = false
	local allRecipes = false
	local refusedSkill = nil
	local buildCards = Instance.new("Frame")
	-- Skills sheet (sheets3, Durango R06-3): a compact level / SP / XP strip in the sheet header, then
	-- a 2-column category grid left and the selected category's next node right (Learn at its bottom),
	-- so rows are on screen at 800x360 and 1280x720. The art per skill category is { resolver, id }.
	local skillCategory: string? = nil
	local skillHead = Instance.new("Frame")
	skillHead.Name, skillHead.BackgroundTransparency, skillHead.Visible = "SkillStats", 1, false
	skillHead.AnchorPoint, skillHead.Position = Vector2.new(1, 0), UDim2.new(1, -58, 0, 0)
	skillHead.Size, skillHead.ZIndex = UDim2.new(1, -150, 1, 0), 52
	skillHead.Parent = sheet.frame:FindFirstChild("Header")
	local headFlow = Instance.new("UIListLayout")
	headFlow.FillDirection, headFlow.HorizontalAlignment = Enum.FillDirection.Horizontal, Enum.HorizontalAlignment.Right
	headFlow.VerticalAlignment, headFlow.SortOrder = Enum.VerticalAlignment.Center, Enum.SortOrder.LayoutOrder
	headFlow.Padding, headFlow.Parent = UDim.new(0, 8), skillHead
	local skillLevel = Instance.new("TextLabel")
	skillLevel.Name, skillLevel.BackgroundTransparency, skillLevel.LayoutOrder = "SkillLevel", 1, 2
	skillLevel.Size, skillLevel.AutomaticSize = UDim2.fromScale(0, 1), Enum.AutomaticSize.X
	skillLevel.Font, skillLevel.TextWrapped, skillLevel.ZIndex = Enum.Font.BuilderSansBold, false, 52
	skillLevel.Parent = skillHead
	local xpTrack = Instance.new("Frame")
	xpTrack.Name, xpTrack.BorderSizePixel, xpTrack.LayoutOrder = "XPBar", 0, 3
	xpTrack.Size, xpTrack.BackgroundColor3, xpTrack.ZIndex = UDim2.fromOffset(84, 10), Color3.fromRGB(28, 20, 14), 52
	xpTrack.Parent = skillHead
	local xpFill = Instance.new("Frame")
	xpFill.Name, xpFill.BorderSizePixel, xpFill.BackgroundColor3 = "Fill", 0, Color3.fromRGB(222, 176, 82)
	xpFill.ZIndex, xpFill.Parent = 52, xpTrack
	for _, bar in { xpTrack, xpFill } do
		local round = Instance.new("UICorner")
		round.CornerRadius, round.Parent = UDim.new(0, 5), bar
	end
	local skillXP = Instance.new("TextLabel")
	skillXP.Name, skillXP.BackgroundTransparency, skillXP.LayoutOrder = "SkillXP", 1, 4
	skillXP.Size, skillXP.AutomaticSize = UDim2.fromScale(0, 1), Enum.AutomaticSize.X
	skillXP.Font, skillXP.TextWrapped, skillXP.ZIndex = Enum.Font.BuilderSans, false, 52
	skillXP.Parent = skillHead
	local skillBody = Instance.new("Frame")
	skillBody.Name, skillBody.BackgroundTransparency, skillBody.Visible = "SkillPanes", 1, false
	skillBody.Size, skillBody.Parent = UDim2.new(1, -8, 0, 120), sheet.scroll
	local skillList = Instance.new("ScrollingFrame")
	skillList.Name, skillList.BackgroundTransparency, skillList.BorderSizePixel = "SkillCategories", 1, 0
	skillList.Size, skillList.ScrollBarThickness = UDim2.new(0.58, -6, 1, 0), 6
	skillList.CanvasSize, skillList.AutomaticCanvasSize = UDim2.new(), Enum.AutomaticSize.Y
	skillList.Parent = skillBody
	local skillGrid = Instance.new("UIGridLayout")
	skillGrid.CellSize, skillGrid.CellPadding = UDim2.new(0.5, -8, 0, 44), UDim2.fromOffset(6, 6)
	skillGrid.SortOrder, skillGrid.Parent = Enum.SortOrder.LayoutOrder, skillList
	-- text audit: at 800x360 the grid shows ~2.5 of its 7 rows and the 6 px bar was easy to miss.
	-- A 10 px opaque bar, a parchment fade over the last visible row and a "more below" pill that
	-- hides at the bottom of the canvas show that the categories continue.
	-- p134 v61: the parchment-tinted bar could not be seen in a still phone capture. Dark ink on a
	-- visible tan track (SkillScrollTrack) reads on parchment; the shell styler leaves it alone.
	skillList.ScrollBarThickness, skillList.ScrollBarImageTransparency = 10, 0
	skillList.ScrollBarImageColor3 = Color3.fromRGB(74, 52, 34)
	skillList:SetAttribute("ForgeShellKeep", true)
	skillList.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	local skillTrack = Instance.new("Frame")
	skillTrack.Name, skillTrack.BorderSizePixel, skillTrack.ZIndex = "SkillScrollTrack", 0, 0
	skillTrack.BackgroundColor3, skillTrack.BackgroundTransparency = Color3.fromRGB(196, 176, 140), 0.2
	skillTrack.AnchorPoint, skillTrack.Position = Vector2.new(1, 0), UDim2.new(0.58, -6, 0, 0)
	skillTrack.Size, skillTrack.Parent = UDim2.new(0, 10, 1, 0), skillBody
	local skillFade = Instance.new("Frame")
	skillFade.Name, skillFade.BorderSizePixel, skillFade.Visible = "SkillMoreFade", 0, false
	skillFade.BackgroundColor3, skillFade.Active = Color3.fromRGB(236, 226, 203), false
	skillFade.AnchorPoint, skillFade.Position = Vector2.new(0, 1), UDim2.new(0, 0, 1, -28)
	skillFade.Size, skillFade.ZIndex = UDim2.new(0.58, -18, 0, 40), 8
	skillFade.Parent = skillBody
	local fadeRamp = Instance.new("UIGradient")
	fadeRamp.Rotation = 90
	fadeRamp.Transparency = NumberSequence.new(1, 0.05)
	fadeRamp.Parent = skillFade
	local skillMore = Instance.new("TextLabel")
	skillMore.Name, skillMore.BorderSizePixel, skillMore.ZIndex = "SkillMore", 0, 9
	-- p134 v61: the pill sat on the faded row and touched its name ("원거리아래에 더 있어요"). It now
	-- has its own strip under the grid: the list stops SKILL_PILL px short while the hint shows.
	skillMore.AnchorPoint, skillMore.Position = Vector2.new(0.5, 0), UDim2.new(0.5, 0, 1, 2)
	skillMore.Size = UDim2.fromOffset(148, 24)
	skillMore.BackgroundColor3, skillMore.BackgroundTransparency = Color3.fromRGB(222, 208, 178), 0
	skillMore.Font, skillMore.TextColor3 = Enum.Font.BuilderSansBold, Color3.fromRGB(38, 30, 24)
	skillMore.Parent = skillFade
	local moreRound = Instance.new("UICorner")
	moreRound.CornerRadius, moreRound.Parent = UDim.new(0, 12), skillMore
	local skillCanvas = 0 -- grid content height in px, set by render from the cell count
	local SKILL_PILL = 28
	local function skillHint()
		-- Overflowing grid: the list stops SKILL_PILL px short so the pill strip never covers a row;
		-- the fade and pill show while more than 8 px of the grid is still below the window.
		local overflow = skillBody.Visible and skillCanvas - skillBody.AbsoluteSize.Y > 8
		local inset = if overflow then -SKILL_PILL else 0
		if skillList.Size.Y.Offset ~= inset then
			skillList.Size = UDim2.new(0.58, -6, 1, inset)
			skillTrack.Size = UDim2.new(0, 10, 1, inset)
		end
		skillTrack.Visible = overflow
		local below = skillCanvas - (skillList.CanvasPosition.Y + skillList.AbsoluteSize.Y)
		skillFade.Visible = overflow and below > 8
	end
	skillList:GetPropertyChangedSignal("CanvasPosition"):Connect(skillHint)
	skillList:GetPropertyChangedSignal("AbsoluteSize"):Connect(skillHint)
	local skillDetail = Instance.new("Frame")
	skillDetail.Name, skillDetail.BorderSizePixel = "SkillDetail", 0
	skillDetail.Position, skillDetail.Size = UDim2.new(0.58, 2, 0, 0), UDim2.new(0.42, -2, 1, 0)
	skillDetail.BackgroundColor3, skillDetail.BackgroundTransparency = Color3.fromRGB(222, 208, 178), 0
	skillDetail.Parent = skillBody
	local detailRound = Instance.new("UICorner")
	detailRound.CornerRadius, detailRound.Parent = UDim.new(0, 10), skillDetail
	local skillInfo = Instance.new("ScrollingFrame")
	skillInfo.Name, skillInfo.BackgroundTransparency, skillInfo.BorderSizePixel = "SkillInfo", 1, 0
	skillInfo.Position, skillInfo.Size = UDim2.fromOffset(8, 6), UDim2.new(1, -12, 1, -60)
	skillInfo.ScrollBarThickness, skillInfo.CanvasSize = 4, UDim2.new()
	skillInfo.AutomaticCanvasSize, skillInfo.Parent = Enum.AutomaticSize.Y, skillDetail
	local infoFlow = Instance.new("UIListLayout")
	infoFlow.SortOrder, infoFlow.Padding, infoFlow.Parent = Enum.SortOrder.LayoutOrder, UDim.new(0, 4), skillInfo
	local skillLines: { [string]: TextLabel } = {}
	for index, key in { "SkillName", "SkillEffect", "SkillNeed" } do
		local line = Instance.new("TextLabel")
		line.Name, line.BackgroundTransparency, line.LayoutOrder = key, 1, index
		line.Size, line.AutomaticSize = UDim2.new(1, -6, 0, 0), Enum.AutomaticSize.Y
		line.Font = if key == "SkillName" then Enum.Font.BuilderSansBold else Enum.Font.BuilderSans
		line.TextWrapped, line.TextXAlignment, line.Parent = true, Enum.TextXAlignment.Left, skillInfo
		skillLines[key] = line
	end
	local function fitSkillBody()
		-- The panes fill the scroll's visible height (its 8 px top and bottom padding off).
		skillBody.Size = UDim2.new(1, -8, 0, math.max(96, sheet.scroll.AbsoluteSize.Y - 16))
	end
	sheet.scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitSkillBody)
	fitSkillBody()
	local SKILL_ART: { [string]: { string } } = {
		survival = { "ui", "health" },
		butchering = { "item", "knife-t1" },
		gathering = { "item", "axe-t1" },
		processing = { "ui", "processing-budget" },
		weapon_tool = { "item", "hammer-t1" },
		tailoring = { "ui", "cat.clothing" },
		cooking = { "ui", "cat.food" },
		farming = { "ui", "cat.farm" },
		construction = { "ui", "build" },
		melee = { "ui", "stance.attack" },
		ranged = { "ui", "stance.shoot" },
		defense = { "ui", "stance.defense" },
	}
	buildCards.Name, buildCards.BackgroundTransparency = "BuildCards", 1
	buildCards.Size, buildCards.AutomaticSize, buildCards.Parent =
		UDim2.new(1, -8, 0, 0), Enum.AutomaticSize.Y, sheet.scroll
	local buildLayout = Instance.new("UIGridLayout")
	buildLayout.CellPadding, buildLayout.SortOrder, buildLayout.Parent =
		UDim2.fromOffset(8, 8), Enum.SortOrder.LayoutOrder, buildCards
	local function fitBuildCards()
		-- U7: three columns from 560 px (the 800x360 phone sheet is ~590 wide), a 46 px art row.
		local columns = if sheet.frame.AbsoluteSize.X >= 560
			then 3
			elseif sheet.frame.AbsoluteSize.X >= 400 then 2
			else 1
		local rows = 1
		for _, definition in content.structures do
			rows = math.max(rows, #definition.cost)
		end
		buildLayout.CellSize = UDim2.new(1 / columns, -8, 0, 48 + rows * 42)
	end
	sheet.frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitBuildCards)
	fitBuildCards()
	local missingText: string? = nil
	local toast = Components.label(theme, {
		text = "",
		size = UDim2.new(1, -24, 0, 64),
		position = UDim2.new(0, 12, 1, -140),
		parent = gui,
	})
	toast.Name, toast.Visible = "MaterialToast", false
	toast.BackgroundColor3, toast.BackgroundTransparency = Color3.fromRGB(22, 36, 33), 0.08
	local function suppliesAvailable(bag: any, inputs: { any }): boolean
		local missing = Model.missingMaterials(bag, inputs)
		local details = {}
		for _, ingredient in missing do
			table.insert(details, name(ingredient.id) .. " " .. ingredient.available .. "/" .. ingredient.needed)
		end
		missingText = if #details > 0 then t("missing") .. ": " .. table.concat(details, ", ") else nil
		toast.Text, toast.Visible = missingText or "", missingText ~= nil
		return missingText == nil
	end
	local helpVisible = false
	local inventoryGrid: any = nil
	local x, z, rotation = 1, 1, 0
	local disposed, refreshing = false, false
	local connections: { RBXScriptConnection } = {}
	local ghost = Instance.new("Folder")
	ghost.Name, ghost.Parent = "ForgeBuildPreview", world
	local highlight = Instance.new("Highlight")
	highlight.Name, highlight.FillTransparency, highlight.OutlineColor =
		"ForgeTarget", 0.85, Color3.fromRGB(219, 229, 155)
	highlight.DepthMode, highlight.Parent = Enum.HighlightDepthMode.Occluded, world
	highlight.Enabled = false
	local resultEvent = Instance.new("BindableEvent")
	resultEvent.Name, resultEvent.Parent = "ForgeHUDResult", player
	local requestEvent = Instance.new("BindableEvent")
	requestEvent.Name, requestEvent.Parent = "ForgeHUDRequested", player
	local render: () -> ()
	local refresh: () -> ()
	local handshakeRetries, hand = 0, {}
	local reportedDeaths: number? = nil
	local function send(request: any)
		if not request then
			render()
			return
		end
		render()
		task.spawn(function()
			local ok, result = pcall(function()
				local envelope = game:GetService("HttpService")
					:JSONDecode(game:GetService("HttpService"):JSONEncode(request))
				local function freeze(value)
					if type(value) == "table" then
						for _, child in value do
							freeze(child)
						end
						table.freeze(value)
					end
				end
				freeze(envelope)
				local observed = table.freeze({
					requestId = request.requestId,
					action = request.action,
					envelope = envelope,
					actorId = tostring(player.UserId),
					serverTime = world:GetServerTimeNow(),
				})
				requestEvent:Fire(observed)
				if game:GetService("RunService"):IsStudio() then
					local gate = player:FindFirstChild("ForgeOwnedDispatchGate")
					if gate and gate:IsA("BindableFunction") then
						assert(gate:Invoke(observed) == true, "OWNED_DISPATCH_NOT_RELEASED")
					end
				end
				return action:InvokeServer("command", request)
			end)
			if disposed then
				return
			end
			model.finish(ok, result)
			local notice = model.notice
			if notice then
				task.delay(M.NOTICE_SECONDS, function()
					if not disposed and model.expireNotice(notice) then
						render()
					end
				end)
			end
			if M.toasted[model.reason] then
				local line = Locale.refusal(locale, model.reason)
				toast.Text, toast.Visible = line, true
				task.delay(M.TOAST_SECONDS, function()
					if not disposed and toast.Text == line then
						toast.Visible = false
					end
				end)
			end
			local refused = if contextual and model.status == "conflict" then model.reason else nil
			if refused then
				task.delay(M.REFUSAL_SECONDS, function()
					if not disposed and model.expireRefusal(refused) then
						render()
					end
				end)
			end
			resultEvent:Fire({ request = request, result = result, status = model.status })
			render()
			refresh()
			if model.autoRetries then
				task.delay(Model.AUTO_RETRY_SECONDS, function()
					if not disposed then
						local again = model.autoRetry()
						if again then
							send(again)
						end
					end
				end)
			end
			local verb, args, wait = Model.handChain(request, ok and result, hand, content.recipes)
			if verb then
				task.delay(wait, function()
					local function go(tries: number)
						local next = not disposed and model.begin(verb, args :: any)
						if next then
							send(next)
						elseif not disposed and tries < 10 then
							task.delay(1, go, tries + 1)
						end
					end
					go(0)
				end)
			end
		end)
	end
	local function command(verb: string, args: { any })
		send(model.begin(verb, args))
	end
	local function nearest(kind: string?): BasePart?
		local character = player.Character
		local pivot = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if not pivot or not pivot:IsA("BasePart") then
			return nil
		end
		local best: BasePart? = nil
		local distance = 12
		for _, part in tags:GetTagged("ForgeSurvivalStation") do
			if
				part:IsA("BasePart")
				and part:IsDescendantOf(world)
				and (not kind or part:GetAttribute("ForgeStationKind") == kind)
			then
				local d = (part.Position - pivot.Position).Magnitude
				if d < distance then
					best, distance = part, d
				end
			end
		end
		return best
	end
	local function rest()
		if model.pending then
			send(model.retry())
			return
		end
		if not model.durable or not table.find(model.durable.actions, "survival-coop:rest") then
			model.status, model.reason = "conflict", "HANDSHAKE_FAILED"
			render()
			return
		end
		local fire = nearest("campfire")
		if fire then
			command("rest", { fire:GetAttribute("ForgeStationId") })
		else
			model.status, model.reason = "conflict", "CAMPFIRE_UNREACHABLE"
			render()
		end
	end
	local function playerLevel(): number?
		local progression = model.snapshot and model.snapshot.progression
		return if type(progression) == "table" and type(progression.level) == "number" then progression.level else nil
	end
	local function attack(ranged: boolean?)
		if model.pending then
			send(model.retry())
			return
		end
		local verb = if ranged then "attack-ranged" else "attack"
		if not model.durable or not table.find(model.durable.actions, "survival-coop:" .. verb) then
			return
		end
		local character = player.Character
		local pivot = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if not pivot or not pivot:IsA("BasePart") then
			return
		end
		local reach = if ranged then Model.RANGED_STUDS else 8
		local candidates = {}
		for _, instance in world:GetDescendants() do
			local id = instance:GetAttribute("ForgeWildlifeId")
			local hp = instance:GetAttribute("ForgeWildlifeHealthMilli")
			if instance:IsA("Model") and type(id) == "string" and (type(hp) ~= "number" or hp > 0) then
				local rootPart = instance:FindFirstChild("HumanoidRootPart")
				if rootPart and rootPart:IsA("BasePart") then
					local d = (rootPart.Position - pivot.Position).Magnitude
					if d < reach then
						table.insert(candidates, {
							kind = instance:GetAttribute("ForgeWildlifeKind"),
							distance = d,
							target = { id = id, position = rootPart.Position, model = instance },
						})
					end
				end
			end
		end
		-- Never an automatic swing at a creature far above the player (Model.autoTarget).
		local picked = Model.autoTarget(content, candidates, playerLevel())
		local target: string? = if picked then picked.id else nil
		local targetPos: Vector3? = if picked then picked.position else nil
		-- p134 v58: one raw swing per press refused OUT_OF_RANGE (picked at 8 studs, the knife
		-- reaches 5) or COOLDOWN (presses 1 s apart, swing + windup 1.6 s) and read "Action refused".
		-- With the pack's combat loop, a melee press engages it: walk into reach, paced swings.
		if picked and not ranged and options.engage and options.engage(picked.model) then
			return
		end
		if target and targetPos then
			local flat = Vector3.new(targetPos.X - pivot.Position.X, 0, targetPos.Z - pivot.Position.Z)
			if flat.Magnitude > 0.001 then
				pivot.CFrame = CFrame.lookAt(pivot.Position, pivot.Position + flat)
			end
			command(verb, { target })
		else
			model.status, model.reason = "conflict", "WILDLIFE_UNREACHABLE"
			render()
		end
	end
	local notePool: { TextLabel } = {}
	local noteUsed = 0
	local function label(text: string, height: number?): TextLabel
		noteUsed += 1
		local pooled: TextLabel? = notePool[noteUsed]
		local item: TextLabel
		if pooled == nil then
			item = Components.label(
				theme,
				{ text = text, size = UDim2.new(1, -8, 0, height or 48), parent = sheet.scroll, textSize = 15 }
			)
			item.TextXAlignment = Enum.TextXAlignment.Left
			notePool[noteUsed] = item
		else
			item = pooled
		end
		item.Name = "Note" .. noteUsed
		item.Font = (Enum.Font :: any)[theme.font]
		item.Parent = contentParent
		item.Text = text
		item.Size = UDim2.new(1, -8, 0, height or 48)
		item.LayoutOrder = controls.order()
		item.Visible = true
		item:SetAttribute("FinishAt", nil)
		item:SetAttribute("JobLabel", nil)
		local icon = item:FindFirstChild("ItemIcon")
		if icon then
			(icon :: ImageLabel).Visible = false
		end
		local fallback = item:FindFirstChild("IconFallback")
		if fallback then
			(fallback :: Frame).Visible = false
		end
		for _, childName in { "RowName", "RowCount" } do
			local child = item:FindFirstChild(childName)
			if child then
				(child :: TextLabel).Visible = false
			end
		end
		local padding = item:FindFirstChild("IconPadding")
		if padding then
			(padding :: UIPadding).PaddingLeft = UDim.new(0, 0)
		end
		return item
	end
	local focusId: string? = nil
	local focusBottom: string? = nil
	local function button(id: string, text: string, callback: () -> (), enabled: boolean?)
		return controls.button(id, text, callback, enabled ~= false)
	end
	local function mutation(id: string, text: string, verb: string, callback: () -> ())
		local policy = model.durable
		local enabled = policy and table.find(policy.actions, "survival-coop:" .. verb) ~= nil and model.pending == nil
		return button(id, text, callback, enabled == true)
	end
	local function itemIcon(item: any, icon: any)
		icon = icon or {}
		IconFallback.mount(item, icon.category, UDim2.fromOffset(28, 28), UDim2.fromOffset(4, 6), icon.image)
		local padding = item:FindFirstChild("IconPadding") or Instance.new("UIPadding")
		padding.Name, padding.PaddingLeft, padding.Parent = "IconPadding", UDim.new(0, 40), item
		item:FindFirstChild("IconFallback").Position = UDim2.fromOffset(-36, 6)
	end
	local function materialRow(id: string, available: number?, needed: number, parent: any?): any
		local row = if parent
			then parent:FindFirstChild("Cost-" .. id) or Components.label(
				theme,
				{ text = "", parent = parent, size = UDim2.new(1, -8, 0, 40) }
			)
			else label("", 40)
		if parent then
			row.Name = "Cost-" .. id
		end
		itemIcon(row, if options.icons then options.icons.item(id) else nil)
		local specs: { { any } } = {
			{ "RowName", name(id), UDim2.new(1, -72, 1, 0), UDim2.fromOffset(0, 0) },
			{
				"RowCount",
				(if available then available .. "/" else "") .. needed,
				UDim2.fromOffset(68, 40),
				UDim2.new(1, -68, 0, 0),
			},
		}
		for _, spec in specs do
			local text = row:FindFirstChild(spec[1])
				or Components.label(theme, { text = "", parent = row, textSize = 12, size = spec[3] })
			text.Name, text.Text, text.Size, text.Position, text.Visible = spec[1], spec[2], spec[3], spec[4], true
			text.TextXAlignment = if spec[1] == "RowCount" then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left
			text.TextScaled, text.TextWrapped = true, true
			fitText(text)
			text.TextColor3 = if available and available < needed
				then Color3.fromRGB(255, 155, 132)
				else Color3.fromRGB(127, 224, 156)
		end
		return row
	end
	local function selectedDefinition(): any
		for _, definition in options.content.structures do
			if definition.id == structureId then
				return definition
			end
		end
		return nil
	end
	local placementReason: string? = nil
	local function preview()
		ghost:ClearAllChildren()
		placementReason = nil
		local definition, settlement = selectedDefinition(), model.snapshot.settlement
		if section ~= "build" or not definition or not settlement then
			return
		end
		for _, entry in Model.placements(settlement, model.actor) do
			if entry.placement.definition.id == structureId then
				x, z, rotation = entry.placement.x, entry.placement.z, entry.placement.rotation
				break
			end
		end
		local placement, reason = Model.preview(model.snapshot, model.actor, definition, x, z, rotation)
		if placement and not reason then
			local excluded: { Instance } = { ghost }
			for _, other in players:GetPlayers() do
				if other.Character then
					table.insert(excluded, other.Character)
				end
			end
			local ray = RaycastParams.new()
			ray.FilterType, ray.FilterDescendantsInstances, ray.RespectCanCollide =
				Enum.RaycastFilterType.Exclude, excluded, true
			local box = OverlapParams.new()
			box.FilterType, box.FilterDescendantsInstances, box.RespectCanCollide =
				Enum.RaycastFilterType.Exclude, excluded, true
			local studs = settlement.config.cellStuds
			local checked = table.clone(placement.cells)
			table.insert(checked, placement.entry)
			reason = BuildPlacement.occupancy(checked, function(cell)
				local center = options.settlementOrigin + Vector3.new((cell.x + 0.5) * studs, 0, (cell.z + 0.5) * studs)
				local support = world:Raycast(center + Vector3.new(0, 32, 0), Vector3.new(0, -64, 0), ray)
				if support then
					center = Vector3.new(center.X, support.Position.Y, center.Z)
				end
				local size = Vector3.new(studs - 0.1, 3.5, studs - 0.1)
				return support, world:GetPartBoundsInBox(CFrame.new(center + Vector3.new(0, 2, 0)), size, box)
			end, false)
		end
		placementReason = reason
		local cells: { any } = if placement then table.clone(placement.cells) else {}
		if not placement then
			for dx = 0, definition.footprintX - 1 do
				for dz = 0, definition.footprintZ - 1 do
					local a, b = dx, dz
					for _ = 1, rotation do
						a, b = -b, a
					end
					table.insert(cells, { x = x + a, z = z + b })
				end
			end
		end
		local size = settlement.config.cellStuds
		local lowX, lowZ, highX, highZ = math.huge, math.huge, -math.huge, -math.huge
		for _, cell in cells do
			lowX, lowZ = math.min(lowX, cell.x), math.min(lowZ, cell.z)
			highX, highZ = math.max(highX, cell.x), math.max(highZ, cell.z)
		end
		local at = options.settlementOrigin
			+ Vector3.new((lowX + highX + 1) * size / 2, 0, (lowZ + highZ + 1) * size / 2)
		local params = RaycastParams.new()
		params.FilterType, params.FilterDescendantsInstances = Enum.RaycastFilterType.Include, { world.Terrain }
		local hit = world:Raycast(at + Vector3.new(0, 128, 0), Vector3.new(0, -256, 0), params)
		if hit then
			at = Vector3.new(at.X, hit.Position.Y + 0.2, at.Z)
		end
		local kits = storage:FindFirstChild("ForgeStructureKits")
		local kit = if kits then kits:FindFirstChild(definition.id) else nil
		if kit then
			local visual = kit:Clone()
			for _, item in visual:GetDescendants() do
				if item:IsA("BasePart") then
					item.Color = if reason then Color3.fromRGB(240, 72, 65) else Color3.fromRGB(65, 230, 120)
					item.Transparency, item.Material = 0.45, Enum.Material.Neon
					item.CanCollide, item.CanTouch, item.CanQuery = false, false, false
				elseif item:IsA("Fire") or item:IsA("Light") then
					item:Destroy()
				end
			end
			visual:PivotTo(CFrame.new(at) * CFrame.Angles(0, -rotation * math.pi / 2, 0))
			visual.Parent = ghost
			local outline = Instance.new("Highlight")
			outline.Adornee, outline.FillTransparency, outline.OutlineTransparency = visual, 0.7, 0
			outline.FillColor = if reason then Color3.fromRGB(240, 72, 65) else Color3.fromRGB(65, 230, 120)
			outline.OutlineColor, outline.Parent = outline.FillColor, visual
		end
		local entryX, entryZ = 0, -1
		for _ = 1, rotation do
			entryX, entryZ = -entryZ, entryX
		end
		table.insert(cells, { x = x + entryX, z = z + entryZ, entry = true })
		for _, cell in cells do
			local part = Instance.new("Part")
			part.Name, part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery =
				"Footprint", true, false, false, false
			part.Size = Vector3.new(size - 0.1, 0.15, size - 0.1)
			if cell.entry then
				part.Name = "Entry"
				part.Size *= 0.6
			end
			part.Position = Vector3.new(
				options.settlementOrigin.X + (cell.x + 0.5) * size,
				at.Y + 0.15,
				options.settlementOrigin.Z + (cell.z + 0.5) * size
			)
			part.Color = if reason then Color3.fromRGB(223, 99, 85) else Color3.fromRGB(141, 201, 149)
			part.Transparency, part.Material, part.Parent = 0.4, Enum.Material.Neon, ghost
		end
	end
	local placementGui = Instance.new("ScreenGui")
	placementGui.Name, placementGui.ResetOnSpawn, placementGui.DisplayOrder = "ForgePlacementHUD", false, 40
	placementGui.ScreenInsets, placementGui.ZIndexBehavior = gui.ScreenInsets, gui.ZIndexBehavior
	placementGui.Parent = player:WaitForChild("PlayerGui")
	local placementBar = Instance.new("Frame")
	placementBar.Name, placementBar.BackgroundTransparency = "PlacementControls", 1
	placementBar.ZIndex = sheet.frame.ZIndex + 3
	placementBar.Size, placementBar.Position = UDim2.fromOffset(272, 48), UDim2.new(0.5, -136, 1, -72)
	placementBar.Parent, placementBar.Visible = placementGui, false
	local blocked = Components.label(theme, {
		text = "",
		parent = placementBar,
		size = UDim2.fromOffset(328, 52),
		position = UDim2.fromOffset(0, -60),
		textSize = 14,
	})
	blocked.Name, blocked.TextWrapped = "PlacementReason", true
	local function placeSelected()
		local settlement, warehouse = model.snapshot.settlement, model.snapshot.warehouse
		if model.pending then
			return
		end
		if not settlement or not warehouse then
			toast.Text, toast.Visible = Locale.refusal(locale, "SETTLEMENT_UNAVAILABLE"), true
			return
		end
		for _, entry in Model.placements(settlement, model.actor) do
			if entry.placement.definition.id == structureId then
				command("settlement-place", { entry.id, settlement.version, warehouse.version })
				return
			end
		end
		local definition = selectedDefinition()
		if definition and suppliesAvailable(warehouse, definition.cost) then
			local args, reason = Model.buildArgs(model.snapshot, definition, x, z, rotation)
			if args then
				command("settlement-reserve", args)
			else
				toast.Text, toast.Visible = Locale.refusal(locale, reason or "SETTLEMENT_UNAVAILABLE"), true
			end
		else
			local reason = if definition then "MISSING_INPUTS" else "SETTLEMENT_UNAVAILABLE"
			toast.Text, toast.Visible = Locale.refusal(locale, reason), true
		end
	end
	local confirmPlacement = Components.button(theme, {
		text = t("place"),
		parent = placementBar,
		size = UDim2.fromOffset(132, 48),
		onClick = placeSelected,
	})
	confirmPlacement.Name = "ConfirmPlacement"
	local cancelPlacement = Components.button(theme, {
		text = t("cancel"),
		parent = placementBar,
		size = UDim2.fromOffset(132, 48),
		position = UDim2.fromOffset(140, 0),
		onClick = function()
			local settlement, warehouse = model.snapshot.settlement, model.snapshot.warehouse
			if settlement and warehouse and not model.pending then
				for _, entry in Model.placements(settlement, model.actor) do
					if entry.placement.definition.id == structureId then
						command("settlement-cancel", { entry.id, settlement.version, warehouse.version })
					end
				end
			end
			structureId, ghostLocked = nil, false
			preview()
			placementBar.Visible = false
			sheet.frame.Visible = true
			render()
		end,
	})
	cancelPlacement.Name = "CancelPlacement"
	local rotatePlacement = Components.button(theme, {
		text = t("rotate"),
		parent = placementBar,
		size = UDim2.fromOffset(80, 48),
		position = UDim2.fromOffset(0, 0),
		onClick = function()
			rotation = (rotation + 1) % 4
			render()
		end,
	})
	rotatePlacement.Name = "RotatePlacement"
	for _, control in { confirmPlacement, cancelPlacement, rotatePlacement } do
		control.ZIndex = placementBar.ZIndex + 1
	end
	placementBar.Size, placementBar.Position =
		UDim2.fromOffset(328, 48), UDim2.new(0.5, -164, 1, -Model.PLACEMENT_BOTTOM)
	confirmPlacement.Size, confirmPlacement.Position = UDim2.fromOffset(116, 48), UDim2.fromOffset(88, 0)
	cancelPlacement.Size, cancelPlacement.Position = UDim2.fromOffset(116, 48), UDim2.fromOffset(212, 0)
	toast.Size, toast.Position = UDim2.new(1, -24, 0, 52), UDim2.new(0, 12, 1, -264)
	local function overControl(px: number, py: number): boolean
		local p, s = placementBar.AbsolutePosition, placementBar.AbsoluteSize
		if Model.overPlacementBar(px, py, p, s) then
			return true
		end
		for _, item in player.PlayerGui:GetGuiObjectsAtPosition(px, py) do
			if item.Active then
				return true
			end
		end
		return false
	end
	local function pointAt(position: Vector3)
		local camera, settlement = world.CurrentCamera, model.snapshot.settlement
		if not camera or not settlement then
			return
		end
		for _, entry in Model.placements(settlement, model.actor) do
			if entry.placement.definition.id == structureId then
				return
			end
		end
		local ray = camera:ScreenPointToRay(position.X, position.Y)
		if math.abs(ray.Direction.Y) < 0.001 then
			return
		end
		local distance = (options.settlementOrigin.Y - ray.Origin.Y) / ray.Direction.Y
		if distance < 0 then
			return
		end
		local hit = ray.Origin + ray.Direction * distance
		local nextX, nextZ =
			Model.pointerCell(hit.X, hit.Z, options.settlementOrigin.X, options.settlementOrigin.Z, settlement.config)
		if nextX ~= x or nextZ ~= z then
			x, z = nextX, nextZ
			preview()
			blocked.Text = if placementReason then Locale.refusal(locale, placementReason) else ""
		end
	end
	local touchStart: { [any]: Vector3 } = {}
	table.insert(
		connections,
		input.InputChanged:Connect(function(event, processed)
			if section ~= "build" or not structureId then
				return
			end
			local kind = event.UserInputType.Name
			local over = (kind == "Touch" or kind == "MouseMovement")
				and overControl(event.Position.X, event.Position.Y)
			if BuildPlacement.pointerUse(kind, processed, over, ghostLocked) then
				pointAt(event.Position)
			end
		end)
	)
	table.insert(
		connections,
		input.InputBegan:Connect(function(event, processed)
			if event.UserInputType == Enum.UserInputType.Touch then
				touchStart[event] = event.Position
			elseif
				section == "build"
				and structureId
				and BuildPlacement.clickLocks(
					event.UserInputType.Name,
					processed,
					overControl(event.Position.X, event.Position.Y)
				)
			then
				pointAt(event.Position)
				ghostLocked = true
			end
		end)
	)
	table.insert(
		connections,
		input.InputEnded:Connect(function(event, processed)
			local start = touchStart[event]
			touchStart[event] = nil
			if not start or section ~= "build" or not structureId then
				return
			end
			local at = event.Position
			if
				BuildPlacement.isTap(start.X, start.Y, at.X, at.Y)
				and BuildPlacement.pointerUse("Touch", processed, overControl(at.X, at.Y))
			then
				pointAt(at)
			end
		end)
	)
	local shellRegions: any = nil
	local function renderTracker()
		local rows = RecipeMarks.tracker(
			Model.bag(model.snapshot),
			model.snapshot.warehouse,
			content.recipes,
			model.snapshot.recipeMarks
		)
		local sheetOpen = sheet.frame.Visible and section ~= ""
		tracker.Visible = #rows > 0 and not sheetOpen
		if not tracker.Visible then
			return
		end
		local lines = { t("tracker_title") }
		for _, row in rows do
			local parts = {}
			for _, need in row.inputs do
				table.insert(
					parts,
					string.format(
						"%s %d/%d",
						name(need.id),
						math.min(need.needed, need.bag + need.warehouse),
						need.needed
					)
				)
			end
			table.insert(
				lines,
				name(row.recipeId) .. ": " .. (if row.ready then t("tracker_ready") else table.concat(parts, ", "))
			)
		end
		tracker.Text = table.concat(lines, "\n")
		local size = root.AbsoluteSize
		local bounds = Model.trackerBounds(size.X + 24, size.Y + 16, #rows)
		if shellRegions then
			HudShell.put(tracker, shellRegions.tracker)
			return
		end
		tracker.AnchorPoint = Vector2.zero
		tracker.Position = UDim2.fromOffset(bounds.x - 12, bounds.y - 8)
		tracker.Size = UDim2.fromOffset(bounds.width, bounds.height)
	end
	-- Shell (Robango C8): bag and craft open as full-screen panels; other sections keep the side sheet.
	local panelSelected: { [Instance]: boolean } = {}
	local PANEL_GLYPH: { [string]: string } = {
		all = "item",
		tool = "tool",
		weapon = "weapon",
		clothing = "armor",
		food = "food",
		medicine = "medicine",
		material = "wood",
		building = "building",
		farm = "seed",
		pet = "creature",
	}
	local itemDefinitions: { [string]: any } = {}
	for _, definition in content.items or {} do
		itemDefinitions[definition.id] = definition
	end
	local function itemCategory(id: string): string
		return IconFallback.category(itemDefinitions[id] or { id = id })
	end
	-- Contextual side sheet (skills, build, ...). Its header Close stays below the top-bar band that
	-- swallows presses (HudShell.hitClear): the sheet top is pushed down to it when needed.
	local function placeSideSheet()
		local size = root.AbsoluteSize
		local sx, sy, sw, sh = Model.contextSheet(size.X, size.Y, input.TouchEnabled)
		local band = HudShell.hitClear(gui) - (root.AbsolutePosition.Y - gui.AbsolutePosition.Y)
		if sy < band then
			sy, sh = band, math.max(0, sh - (band - sy))
		end
		sheet.frame.AnchorPoint, sheet.frame.Position, sheet.frame.Size =
			Vector2.zero, UDim2.fromOffset(sx, sy), UDim2.fromOffset(sw, sh)
	end
	local function fitShellPanel()
		local kind = if shell and sheet.frame.Visible and (section == "bag" or section == "craft") then section else nil
		if kind then
			local view = gui.AbsoluteSize
			panelLayout = HudShell.panel(view.X, view.Y, HudShell.guiClear(gui), kind, HudShell.hitClear(gui))
			HudShell.applyPanel(sheet, panelLayout, root.AbsolutePosition - gui.AbsolutePosition)
			HudShell.put(currency, panelLayout.currency, Vector2.new(panelLayout.frame.x, panelLayout.frame.y))
			currency.TextSize = panelLayout.text.label
		elseif panelLayout then
			panelLayout = nil
			HudShell.restorePanel(sheet, {
				panel = HudShell.color(theme.colors.panel),
				accent = HudShell.color(theme.colors.accent),
				close = HudShell.color(theme.colors.bad),
				titleSize = theme.textSizes.body,
			})
			-- applyPanel left the frame on the full-screen rect (Close at gui y ~0, under the top bar):
			-- D2b skills/build opened after bag/craft could only be closed by their key.
			placeSideSheet()
		end
	end
	render = function()
		if disposed then
			return
		end
		fitShellPanel()
		table.clear(panelSelected)
		placementBar.Visible = section == "build" and structureId ~= nil
		if section == "build" then
			sheet.frame.Visible = structureId == nil
		end
		confirmPlacement.Interactable = model.pending == nil
		local reservedPlacement = false
		if model.snapshot.settlement then
			for _, entry in Model.placements(model.snapshot.settlement, model.actor) do
				reservedPlacement = reservedPlacement or entry.placement.definition.id == structureId
			end
		end
		confirmPlacement.Text = t(if reservedPlacement then "place" else "reserve")
		local v = model.snapshot.vitals
		vitals.Visible = v ~= nil
		vitals.Text = ""
		if v then
			for stat, bar in statBars do
				local amount = v[stat .. "Milli"] / 1000
				bar.fill.Size = UDim2.fromScale(math.clamp(amount / 100, 0, 1), 1)
				bar.value.Text = tostring(math.floor(amount))
			end
		end
		if levelNumber then
			local progression = model.snapshot.progression
			levelNumber.Text = if progression and progression.level then tostring(progression.level) else "1"
		end
		local hungry = Model.hungry(v)
		local hint = Model.hungerHint(model.snapshot, content and content.items)
		local detail = if model.reason
			then Locale.refusal(locale, model.reason, refusedSkill)
			elseif model.notice then t(model.notice)
			elseif hint then t(hint)
			else nil
		-- Shell: the status slot shows only the notice itself; the idle "ready" headline above it
		-- read as a second objective card in mid-screen on the phone (staging v26).
		local quiet = shell ~= nil and (model.status == "ready" or model.status == "confirmed")
		status.Text = if quiet and detail then detail else t(model.status) .. (if detail then "\n" .. detail else "")
		if contextual then
			status.Visible = model.status == "conflict" or model.status == "pending" or model.notice ~= nil or hungry
		end
		local scrollPosition = sheet.scroll.CanvasPosition
		controls.begin(section)
		noteUsed = 0
		panes.Visible = section == "bag" or section == "craft"
		craftActions.Visible = section == "craft" or (panelLayout ~= nil and section == "bag")
		categoryPane.Visible, currency.Visible = panelLayout ~= nil, panelLayout ~= nil
		filterBar.Visible = panelLayout ~= nil and section == "bag"
		if panelLayout then
			currency.Text = string.format(t("coins"), tonumber(model.snapshot.balance) or 0)
		end
		fitPanes()
		buildCards.Visible = section == "build"
		skillHead.Visible, skillBody.Visible = false, false
		capacityTrack.Visible = section == "bag"
		panes.LayoutOrder = 1
		contentParent = if panes.Visible then listPane else sheet.scroll
		controls.parent = contentParent
		if inventoryGrid then
			inventoryGrid.frame.Visible = section == "bag"
		end
		if model.pending then
			button("Retry", t("retry"), function()
				send(model.retry())
			end, not model.busy)
		end
		if model.reason then
			label(Locale.refusal(locale, model.reason, refusedSkill), 100)
		elseif model.notice then
			label(t(model.notice), 48)
		end
		local bag = Model.bag(model.snapshot)
		if section == "bag" then
			if bag then
				local slots, maximum, weight, hard = Model.capacity(bag)
				capacityFill.Size = UDim2.fromScale(
					math.clamp(math.max(slots / math.max(1, maximum), weight / math.max(1, hard)), 0, 1),
					1
				)
				capacityTrack.LayoutOrder = controls.order()
				label(
					string.format(
						"%s %d/%d   %s %.1f/%.1f",
						t("slots"),
						slots,
						maximum,
						t("weight"),
						weight / 1000,
						hard / 1000
					)
				)
				if weight > bag.limits.softWeightMilli then
					label(t("slow"))
				end
				local rows = Model.items(bag)
				if panelLayout then
					-- Category chips over the grid; only categories the bag holds.
					local held = {}
					for _, row in rows do
						table.insert(held, itemCategory(row.item.catalogId))
					end
					local chips = HudShell.panelCategories(held)
					if not table.find(chips, bagFilter) then
						bagFilter = "all"
					end
					controls.parent = filterBar
					for _, id in chips do
						local text = t("cat." .. id)
						local chip = button("Filter-" .. id, text, function()
							bagFilter = id
							render()
						end)
						chip.Size = UDim2.fromOffset(math.max(64, (utf8.len(text) or #text) * 9 + 20), 44)
						panelSelected[chip] = id == bagFilter
					end
					controls.parent = listPane
					local shown = {}
					for _, row in rows do
						if
							bagFilter == "all"
							or HudShell.panelCategory(itemCategory(row.item.catalogId)) == bagFilter
						then
							table.insert(shown, row)
						end
					end
					rows = shown
					-- Equipment doll (spec 6.3): one row per gear slot with what is worn there.
					contentParent, controls.parent = categoryPane, categoryPane
					local equipped = if type(characterGear) == "table" then characterGear.equipped or {} else {}
					for _, slot in HudShell.DOLL_SLOTS do
						local itemId = equipped[slot]
						local worn = if itemId then bag.items[itemId] else nil
						local slotButton = button(
							"Slot-" .. slot,
							string.format(
								t("chr.equip_slot"),
								t("chr.slot_" .. slot),
								if worn then name(worn.catalogId) else t("chr.modify_empty")
							),
							function()
								if worn then
									selected = itemId
									render()
								end
							end
						)
						panelSelected[slotButton] = worn ~= nil and itemId == selected
					end
					contentParent, controls.parent = listPane, listPane
				end
				if selected == nil or bag.items[selected] == nil then
					selected = if rows[1] then rows[1].item.itemId else nil
				end
				local display = {}
				for _, row in rows do
					table.insert(display, {
						id = row.item.itemId,
						image = if options.icons then options.icons.item(row.item.catalogId).image else nil,
						text = name(row.item.catalogId),
						category = if options.icons then options.icons.item(row.item.catalogId).category else "item",
						quantity = row.item.quantity,
					})
				end
				if not inventoryGrid then
					inventoryGrid = Grid.new(listPane, theme, function(id)
						selected = id
						focusBottom = "Deposit-" .. id
						render()
					end)
				end
				local grid = inventoryGrid
				grid.frame.LayoutOrder = controls.order()
				grid.update(display, selected)
				local cells = grid.frame:FindFirstChildOfClass("UIGridLayout")
				if panelLayout and cells then
					-- Six square cells (spec 6.3); the name moves to the detail card, the count stays >= 13 px.
					cells.CellSize = UDim2.fromOffset(panelLayout.cell, panelLayout.cell)
					-- The count is a corner badge at the sheet skin's body size (skinSheet never shrinks it).
					local countSize = if shell and Theme.sheet
						then math.max(HudShell.PANEL_MIN_TEXT, Theme.sheetText("body", gui.AbsoluteSize.Y))
						else HudShell.PANEL_MIN_TEXT
					for _, slot in grid.frame:GetChildren() do
						local caption, quantity = slot:FindFirstChild("Caption"), slot:FindFirstChild("Quantity")
						if caption and quantity then
							caption.Visible = false
							local cell = HudShell.bagSlot(panelLayout.cell, countSize, quantity.Text)
							quantity.TextSize = countSize
							quantity.Size = UDim2.fromOffset(cell.badge.width, cell.badge.height)
							quantity.Position = UDim2.fromOffset(cell.badge.x, cell.badge.y)
							local icon = slot:FindFirstChild("IconFallback")
							if icon then
								icon.Size = UDim2.fromOffset(cell.icon.width, cell.icon.height)
								icon.Position = UDim2.fromOffset(cell.icon.x, cell.icon.y)
							end
							-- InventoryGrid re-mounts the icon on every update, so it became the later sibling
							-- at the same ZIndex and covered the count's top half (phone v40: digits unreadable).
							quantity.ZIndex = slot.ZIndex + 2
						end
					end
				elseif cells then
					cells.CellSize = UDim2.new(0.333, -6, 0, 92)
					for _, slot in grid.frame:GetChildren() do
						local caption, quantity = slot:FindFirstChild("Caption"), slot:FindFirstChild("Quantity")
						if caption and quantity then
							caption.Visible = true
							quantity.TextSize, quantity.Size = 12, UDim2.fromOffset(32, 20)
							quantity.Position = UDim2.new(1, -34, 0, 6)
							quantity.ZIndex = slot.ZIndex + 2
						end
					end
				end
				if #rows == 0 then
					label(t("empty"))
				end
				local item = if selected then bag.items[selected] else nil
				contentParent, controls.parent = detailPane, detailPane
				if item then
					local policy = Spoilage.policy(options.content)
					local fresh = if policy
						then Spoilage.freshness(item, policy, math.floor(world:GetServerTimeNow() * 1000), false)
						else nil
					label(
						name(item.catalogId)
							.. "\n"
							.. t("quality")
							.. " "
							.. item.qualityMilli / 1000
							-- Materials and food have no durability (no maxDurabilityMilli): no "durability 0".
							.. (if Model.wears(options.content, item.catalogId)
								then "  " .. t("durability") .. " " .. item.durabilityMilli / 1000
								else "")
							.. (if fresh then "\n" .. Locale.freshness(locale, fresh) else ""),
						if fresh then 84 else 64
					)
					-- Panel: one primary action at the detail's bottom (eat, else equip, else store).
					local food, slot = false, if panelLayout then CharacterRules.slotOf(item.catalogId) else nil
					for _, definition in options.content.items do
						if definition.id == item.catalogId and definition.foodEffects then
							food = true
							if panelLayout then
								controls.parent = craftActions
							end
							mutation("Eat-" .. item.itemId, t("eat"), "food", function()
								command("food", { item.itemId })
							end)
							controls.parent = detailPane
						end
					end
					local wornHere = slot ~= nil
						and type(characterGear) == "table"
						and (characterGear.equipped or {})[slot] == item.itemId
					if slot and not food and not wornHere then
						controls.parent = craftActions
						mutation("Equip-" .. item.itemId, t("panel.equip"), "gear-equip", function()
							command("gear-equip", { item.itemId })
						end)
						controls.parent = detailPane
					end
					if panelLayout and not food and (not slot or wornHere) then
						controls.parent = craftActions
					end
					mutation("Deposit-" .. item.itemId, t("deposit"), "transfer-deposit", function()
						command("transfer-deposit", { item.itemId, 1 })
					end)
					controls.parent = detailPane
					local cost = Model.repairCost(item, options.content)
					if cost then
						mutation("Repair-" .. item.itemId, string.format(t("repair"), cost), "item-repair", function()
							command("item-repair", { item.itemId })
						end)
					end
				else
					label(t("select"))
				end
			end
			if panelLayout then
				-- Warehouse access sits under the equipment doll.
				contentParent, controls.parent = categoryPane, categoryPane
			end
			if options.openPanel then
				button("Storage", t("warehouse"), function()
					options.openPanel("storage")
				end)
			else
				label(t("warehouse"))
			end
			for _, row in Model.items(model.snapshot.warehouse) do
				mutation(
					"Withdraw-" .. row.item.itemId,
					t("withdraw") .. " - " .. name(row.item.catalogId) .. " x" .. row.available,
					"transfer-withdraw",
					function()
						command("transfer-withdraw", { row.item.itemId, 1 })
					end
				)
			end
		elseif section == "skills" then
			local progression = model.snapshot.progression
			if progression then
				local tree = content.progressionPolicy and content.progressionPolicy.tree
				if shell and options.icons and tree and Theme.sheetText then
					-- sheets3: level / SP / XP in the header strip; category grid left, the selected
					-- category's next node right with Learn at its bottom; reset is the grid's last cell.
					local xp = CharacterRules.character(content, progression, 0)
					skillHead.Visible, skillBody.Visible = true, true
					skillBody.LayoutOrder = controls.order()
					fitSkillBody()
					skillLevel.Text = string.format(t("level_sp"), progression.level, progression.sp)
					skillXP.Text = string.format("XP %d/%d", xp.xp, xp.nextXP)
					xpFill.Size = UDim2.fromScale(if xp.nextXP > 0 then math.clamp(xp.xp / xp.nextXP, 0, 1) else 1, 1)
					local order, byCategory = {}, {}
					for _, node in content.skillNodes or {} do
						if not byCategory[node.category] then
							byCategory[node.category] = {}
							table.insert(order, node.category)
						end
						table.insert(byCategory[node.category], node)
					end
					local function nextOf(category: string): (any, number)
						local learned, nextNode = 0, nil
						for _, node in byCategory[category] do
							if progression.paid[node.id] ~= nil then
								learned += 1
							elseif not nextNode then
								nextNode = node
							end
						end
						return nextNode, learned
					end
					if not skillCategory or not byCategory[skillCategory] then
						skillCategory = order[1]
						for _, category in order do
							local nextNode = nextOf(category)
							if nextNode and progression.sp >= nextNode.cost then
								skillCategory = category
								break
							end
						end
					end
					controls.parent = skillList
					local body = Theme.sheetText("body", gui.AbsoluteSize.Y)
					skillGrid.CellSize = UDim2.new(0.5, -8, 0, math.max(44, 2 * body + 14))
					for _, category in order do
						local nextNode, learned = nextOf(category)
						local cell = button(
							"skill-" .. category,
							string.format(
								"%s\n%d/%d%s",
								(string.gsub(Locale.skillName(locale, category), "%s+$", "")),
								learned,
								#byCategory[category],
								if nextNode and progression.sp >= nextNode.cost then "  +" else ""
							),
							function()
								skillCategory = category
								render()
							end
						)
						cell.TextYAlignment = Enum.TextYAlignment.Center
						local art = SKILL_ART[category] or { "ui", "skills" }
						itemIcon(cell, options.icons[art[1]](art[2]))
						panelSelected[cell] = category == skillCategory
					end
					local reset = button("skill-reset", t("skill_reset"), function()
						if not (options.openPanel and options.openPanel("skill-reset")) then
							command("skill-reset", { progression.version })
						end
					end, true)
					itemIcon(reset, options.icons.ui("refund"))
					skillCanvas = math.ceil((#order + 1) / 2) * (skillGrid.CellSize.Y.Offset + 6)
					skillMore.Text = t("skill_more")
					skillHint()
					local category = skillCategory :: string
					local nextNode, learned = nextOf(category)
					local node = nextNode or byCategory[category][#byCategory[category]]
					skillLines.SkillName.Text = if nextNode
						then Locale.skill(locale, nextNode)
						else string.format("%s  %d/%d", Locale.skillName(locale, category), learned, learned)
					local effect = Locale.text(locale, "skills." .. node.id)
					skillLines.SkillEffect.Text = if effect ~= "skills." .. node.id then effect else ""
					local missing = {}
					for _, id in node.prerequisites or {} do
						if progression.paid[id] == nil then
							table.insert(missing, Locale.skillName(locale, id))
						end
					end
					skillLines.SkillNeed.Text = if nextNode and #missing > 0
						then string.format(t("skill_needed"), table.concat(missing, ", "))
						elseif nextNode then string.format("SP %d / %d", nextNode.cost, progression.sp)
						else ""
					skillLines.SkillNeed.TextColor3 = if #missing > 0
						then Color3.fromRGB(176, 72, 52)
						else skillLines.SkillName.TextColor3
					if nextNode then
						controls.parent = skillDetail
						local learn = button(
							"learn-" .. nextNode.id,
							t("learn") .. "  ·  " .. nextNode.cost .. " SP",
							function()
								command("skill-learn", { nextNode.id })
							end,
							progression.sp >= nextNode.cost
						)
						learn.AnchorPoint, learn.Position = Vector2.new(0, 1), UDim2.new(0, 6, 1, -6)
						learn.Size = UDim2.new(1, -12, 0, 44)
						itemIcon(learn, options.icons.ui("skill-point"))
					end
					skillInfo.Size = UDim2.new(1, -12, 1, if nextNode then -60 else -12)
					controls.parent = sheet.scroll
				else
					local heading = label(string.format(t("level_sp"), progression.level, progression.sp), 40)
					if shell then
						heading.Font, heading.TextSize = Enum.Font.BuilderSansBold, math.max(heading.TextSize, 18)
						if options.icons then
							itemIcon(heading, options.icons.ui("skill-point"))
						end
					end
					button("skill-reset", t("skill_reset"), function()
						if not (options.openPanel and options.openPanel("skill-reset")) then
							command("skill-reset", { progression.version })
						end
					end, true)
					for _, node in content.skillNodes or {} do
						local learned = progression.paid[node.id] ~= nil
						local row = button("learn-" .. node.id, Locale.skill(locale, node), function()
							command("skill-learn", { node.id })
						end, not learned)
						if shell and options.icons then
							itemIcon(row, options.icons.ui(if learned then "success" else "skill-point"))
						end
					end
				end
			end
		elseif section == "craft" then
			local tutorial = model.snapshot.contracts and model.snapshot.contracts.tutorial
			local pin = if tutorial and tutorial.step == "craft-stone-axe"
				then Model.axePin(bag, options.content.recipes)
				else nil
			local activeJobs = Model.jobs(model.snapshot, model.actor)
			local jobs = {}
			for _, entry in activeJobs do
				jobs[entry.job.recipeId] = true
			end
			local orderedRecipes = Model.recipeOrder(
				bag,
				options.content.recipes,
				function(station)
					return nearest(station) ~= nil
				end,
				options.content.items,
				{
					all = allRecipes,
					pin = pin,
					jobs = jobs,
					progression = model.snapshot.progression,
					details = options.content.recipeDetails,
					favorites = if model.snapshot.recipeMarks then model.snapshot.recipeMarks.favorites else nil,
				}
			)
			if panelLayout then
				-- Category rail (spec 6.1): only categories with at least one recipe, output item's category.
				local outputs = {}
				for _, row in orderedRecipes do
					table.insert(outputs, itemCategory(row.recipe.outputs[1].item))
				end
				local rail = HudShell.panelCategories(outputs)
				if not table.find(rail, panelCategory) then
					panelCategory = "all"
				end
				contentParent, controls.parent = categoryPane, categoryPane
				for _, id in rail do
					local tab = button("Category-" .. id, t("cat." .. id), function()
						panelCategory, recipeId = id, nil
						render()
					end)
					-- Pack art for the category (ui.icon.cat.<id>) when published; the glyph otherwise.
					local art = if options.icons then options.icons.ui("cat." .. id).image else nil
					IconFallback.mount(tab, PANEL_GLYPH[id], UDim2.fromOffset(24, 24), UDim2.new(0, 6, 0.5, -12), art)
					local pad = tab:FindFirstChild("IconPadding") or Instance.new("UIPadding")
					pad.Name, pad.PaddingLeft, pad.Parent = "IconPadding", UDim.new(0, 34), tab
					tab:FindFirstChild("IconFallback").Position = UDim2.new(0, -28, 0.5, -12)
					tab.Size = UDim2.new(1, -8, 0, panelLayout.categoryRow)
					panelSelected[tab] = id == panelCategory
				end
				local kept = {}
				for _, row in orderedRecipes do
					if
						panelCategory == "all"
						or HudShell.panelCategory(itemCategory(row.recipe.outputs[1].item)) == panelCategory
					then
						table.insert(kept, row)
					end
				end
				orderedRecipes = kept
			end
			button("RecipeFilter", t(if allRecipes then "craft_nearby" else "craft_all"), function()
				allRecipes = not allRecipes
				recipeId = nil
				render()
			end)
			local visible = false
			for _, row in orderedRecipes do
				visible = visible or row.recipe.id == recipeId
			end
			if not visible and orderedRecipes[1] then
				recipeId = orderedRecipes[1].recipe.id
			end
			local function renderJobs()
				for _, entry in activeJobs do
					local job = entry.job
					if job.recipeId ~= recipeId then
						continue
					end
					local verb = if job.state == "Reserved" then "start" else "complete"
					controls.parent = craftActions
					mutation(verb .. "-" .. entry.id, t(job.state) .. " / " .. t(verb), "craft-" .. verb, function()
						command("craft-" .. verb, { entry.id })
					end)
					mutation("cancel-" .. entry.id, t("cancel"), "craft-cancel", function()
						command("craft-cancel", { entry.id })
					end)
					break
				end
			end
			for _, row in orderedRecipes do
				contentParent, controls.parent = listPane, listPane
				local recipe = row.recipe
				local recipeButton = button(
					"Recipe-" .. recipe.id,
					name(recipe.id)
						.. "\n"
						.. (
							if row.ready
								then t("reserve") .. " +"
								elseif row.skill then string.format(
									t("skill_needed"),
									Locale.skillName(locale, row.skill)
								)
								elseif not row.stationReady then t("station") .. ": " .. name(row.station)
								else t("missing")
						),
					function()
						recipeId = recipe.id
						focusBottom = "Reserve-" .. recipe.id
						render()
					end
				)
				if options.icons then
					local icon = options.icons.recipe(recipe.id)
					itemIcon(recipeButton, if icon.image then icon else options.icons.item(recipe.outputs[1].item))
				end
				if panelLayout then
					recipeButton.Size = UDim2.new(1, -8, 0, panelLayout.listRow)
					panelSelected[recipeButton] = recipe.id == recipeId
				end
				if recipe.id == recipeId then
					contentParent, controls.parent = detailPane, detailPane
					label(name(recipe.id), 36)
					label(t("inputs"))
					for _, ingredient in Model.ingredients(bag, recipe) do
						materialRow(ingredient.id, ingredient.available, ingredient.needed)
					end
					for _, item in recipe.outputs do
						local outputRow = materialRow(item.item, nil, item.quantity)
						-- The yield, then how many the bag holds over every stack (p134 v43).
						local yield = outputRow:FindFirstChild("RowCount")
						if yield then
							yield.Text = string.format(t("craft_held"), item.quantity, Model.held(bag, item.item))
						end
					end
					label(
						(if recipe.station then name(recipe.station) else t("hand"))
							.. " / "
							.. string.format(t("seconds"), tostring(recipe.craftMillis / 1000)),
						32
					)
					if recipe.requiredToolTag then
						label(t("tool") .. ": " .. name(recipe.requiredToolTag), 32)
					end
					local marks = model.snapshot.recipeMarks
					local favorite = marks ~= nil and marks.favorites[recipe.id] == true
					local tracked = marks ~= nil and marks.todo[recipe.id] == true
					mutation(
						"Favorite-" .. recipe.id,
						t(if favorite then "craft_unfavorite" else "craft_favorite"),
						"recipe-mark",
						function()
							command("recipe-mark", { recipe.id, "favorite", not favorite })
						end
					)
					mutation(
						"Todo-" .. recipe.id,
						t(if tracked then "craft_untrack" else "craft_track"),
						"recipe-mark",
						function()
							command("recipe-mark", { recipe.id, "todo", not tracked })
						end
					)
					controls.parent = craftActions
					local make = t(if recipe.station then "reserve" else "make")
					mutation("Reserve-" .. recipe.id, make, "craft-reserve", function()
						if not suppliesAvailable(Model.bag(model.snapshot), recipe.inputs) then
							return
						end
						local station = if recipe.station then nearest(recipe.station) else nil
						if recipe.station and not station then
							model.status, model.reason = "conflict", "STATION_UNAVAILABLE"
							render()
							return
						end
						refusedSkill = if row.skill then Locale.skillName(locale, row.skill) else nil
						command(
							"craft-reserve",
							{ recipe.id, if station then station:GetAttribute("ForgeStationId") else "hand" }
						)
					end)
				end
			end
			renderJobs()
		elseif section == "build" then
			label(t("buildHint"), 36)
			buildCards.LayoutOrder = controls.order()
			local STRUCTURE_PRIORITY: { [string]: number } = {
				["floor"] = 1,
				["campfire"] = 2,
				["workbench"] = 3,
				["storage"] = 4,
				["roof"] = 5,
			}
			local orderedStructures: { any } = table.clone(options.content.structures)
			table.sort(orderedStructures, function(a: any, b: any)
				local pa = STRUCTURE_PRIORITY[a.id] or 10
				local pb = STRUCTURE_PRIORITY[b.id] or 10
				if pa ~= pb then
					return pa < pb
				end
				return a.id < b.id
			end)
			for _, definition in orderedStructures do
				controls.parent = buildCards
				local card = button("Structure-" .. definition.id, "", function()
					structureId, ghostLocked = definition.id, false
					focusBottom = "BuildReserve-" .. definition.id
					render()
				end, true)
				-- The structure's kit art (item.icon.<id>-kit), else the build icon; the glyph without either.
				local kit = if options.icons then options.icons.item(definition.id .. "-kit") else nil
				local art = if kit and kit.image
					then kit.image
					elseif options.icons then options.icons.ui("build").image
					else nil
				-- U7: kit art (40 px since sheets3, so a whole card fits the 800x360 sheet under the hint), a bold
				-- name beside it, a ready tick and rim when storage covers it.
				IconFallback.mount(card, "building", UDim2.fromOffset(40, 40), UDim2.fromOffset(6, 3), art)
				local title = card:FindFirstChild("StructureName")
					or Components.label(
						theme,
						{ text = "", parent = card, textSize = 12, size = UDim2.new(1, -80, 0, 44) }
					)
				title.Name, title.Text = "StructureName", name(definition.id)
				title.Size, title.Position = UDim2.new(1, -80, 0, 44), UDim2.fromOffset(52, 1)
				title.TextScaled, title.TextWrapped, title.Font = true, true, Enum.Font.BuilderSansBold
				fitText(title)
				local ready = true
				for index, cost in Model.ingredients(model.snapshot.warehouse, { inputs = definition.cost }) do
					local chip = materialRow(cost.id, cost.available, cost.needed, card)
					chip.Position = UDim2.fromOffset(4, 46 + (index - 1) * 42)
					chip.BackgroundTransparency = 0.25
					-- sheets3: the name takes the chip's full width on its own line (it wrapped into a cut second
					-- line on the phone) and the have/need count sits right-aligned on the line under it.
					local rowName, rowCount = chip:FindFirstChild("RowName"), chip:FindFirstChild("RowCount")
					if rowName and rowCount then
						rowName.Size, rowName.Position = UDim2.new(1, -4, 0, 20), UDim2.fromOffset(0, 1)
						rowCount.Size, rowCount.Position = UDim2.new(1, -4, 0, 18), UDim2.fromOffset(0, 20)
						rowName.TextTruncate, rowCount.TextTruncate = Enum.TextTruncate.AtEnd, Enum.TextTruncate.AtEnd
					end
					ready = ready and (cost.available or 0) >= cost.needed
				end
				local tick = if options.icons then options.icons.ui("success").image else nil
				local badge = IconFallback.mount(
					card,
					"item",
					UDim2.fromOffset(24, 24),
					UDim2.new(1, -28, 0, 4),
					tick,
					"ReadyBadge"
				)
				badge.BackgroundTransparency, badge.Visible = 1, ready
				local rim = card:FindFirstChild("ReadyRim") or Instance.new("UIStroke")
				rim.Name, rim.ApplyStrokeMode, rim.Thickness = "ReadyRim", Enum.ApplyStrokeMode.Border, 2
				rim.Color, rim.Transparency, rim.Parent = Color3.fromRGB(58, 128, 118), if ready then 0 else 1, card
			end
			controls.parent = sheet.scroll
			local definition = selectedDefinition()
			if definition then
				label(t("placementHint"))
				local _, reason = Model.preview(model.snapshot, model.actor, definition, x, z, rotation)
				label(
					name(definition.id)
						.. "  ("
						.. x
						.. ", "
						.. z
						.. ")  "
						.. rotation * 90
						.. "\n"
						.. (if reason then Locale.refusal(locale, reason) else t("preview")),
					48
				)
				for _, cost in definition.cost do
					label(name(cost.item) .. " x" .. cost.quantity)
				end
			end
			local settlement, warehouse = model.snapshot.settlement, model.snapshot.warehouse
			if settlement and warehouse then
				for _, entry in Model.placements(settlement, model.actor) do
					local id, placement = entry.id, entry.placement
					label(name(placement.definition.id) .. " - " .. t("Reserved"))
					for _, verb in { "place", "cancel" } do
						mutation(verb .. "-" .. id, t(verb), "settlement-" .. verb, function()
							command("settlement-" .. verb, { id, settlement.version, warehouse.version })
						end)
					end
				end
			end
		end
		if section ~= "bag" and section ~= "craft" and not skillBody.Visible then
			button("Refresh", t("refresh"), refresh)
			button("CameraHelp", t("cameraHelp"), function()
				helpVisible = not helpVisible
				render()
			end)
			if helpVisible then
				label(t("cameraHint"), 100)
			end
		end
		fitPanes()
		controls.finish()
		local actionButtons = {}
		for _, child in craftActions:GetChildren() do
			if child:IsA("GuiButton") then
				table.insert(actionButtons, child)
			end
		end
		for _, child in actionButtons do
			if panelLayout then
				-- The detail column's bottom: one primary (teal, ink text) plus a job's cancel if any.
				child.Size = UDim2.new(1 / #actionButtons, -6, 1, 0)
				HudShell.panelButton(child, string.sub(child.Name, 1, 7) ~= "cancel-")
			else
				child.Size = UDim2.new(1 / 3, -6, 0, 48)
			end
		end
		if panelLayout then
			for _, pane in { listPane, detailPane, categoryPane, filterBar } do
				for _, child in pane:GetChildren() do
					if child:IsA("GuiButton") then
						HudShell.panelButton(child, panelSelected[child] == true)
					elseif child:IsA("TextLabel") then
						child.TextColor3 = HudShell.color(HudShell.PALETTE.bone)
						child.TextSize = math.max(HudShell.PANEL_MIN_TEXT, child.TextSize)
					end
				end
			end
		end
		if shell and Theme.sheet and sheet.frame.Visible then
			-- The bag / craft / skills / build sheets wear the same shell as the docked sheets.
			local safe = gui.AbsoluteSize.Y
			local primary: { [Instance]: boolean } = {}
			for _, child in craftActions:GetChildren() do
				primary[child] = string.sub(child.Name, 1, 7) ~= "cancel-"
			end
			HudShell.skinSheet(sheet.frame, {
				tokens = Theme.sheet,
				body = Theme.sheetText("body", safe),
				title = Theme.sheetText("title", safe),
				selected = function(item: any): boolean
					return panelSelected[item] == true
						or primary[item] == true
						or (inventoryGrid ~= nil and item.Parent == inventoryGrid.frame and item.Name == selected)
				end,
				lists = {
					listPane,
					categoryPane,
					filterBar,
					sheet.scroll,
					buildCards,
					skillList,
					if inventoryGrid then inventoryGrid.frame else listPane,
				},
			})
		end
		for index = noteUsed + 1, #notePool do
			notePool[index].Visible = false
		end
		sheet.scroll.CanvasPosition = scrollPosition
		local focused = if focusId then sheet.scroll:FindFirstChild(focusId) else nil
		focusId = nil
		if focused and focused:IsA("GuiObject") then
			sheet.scroll.CanvasPosition = Vector2.new(
				0,
				math.max(0, scrollPosition.Y + focused.AbsolutePosition.Y - sheet.scroll.AbsolutePosition.Y - 8)
			)
		end
		local bottom = if focusBottom then sheet.scroll:FindFirstChild(focusBottom) else nil
		focusBottom = nil
		if bottom and bottom:IsA("GuiObject") then
			local overflow = bottom.AbsolutePosition.Y
				+ bottom.AbsoluteSize.Y
				- (sheet.scroll.AbsolutePosition.Y + sheet.scroll.AbsoluteSize.Y)
				+ 8
			if overflow > 0 then
				sheet.scroll.CanvasPosition = sheet.scroll.CanvasPosition + Vector2.new(0, overflow)
			end
		end
		preview()
		blocked.Text = if placementReason then Locale.refusal(locale, placementReason) else ""
		renderTracker()
	end
	refresh = function()
		if disposed or refreshing then
			return
		end
		refreshing = true
		task.spawn(function()
			local ok, result = pcall(function()
				return action:InvokeServer()
			end)
			refreshing = false
			if disposed then
				return
			end
			if ok and result.ok then
				model.receive(result)
				handshakeRetries = 0
			elseif model.durable == nil and handshakeRetries < 8 then
				handshakeRetries += 1
				task.delay(math.min(8, handshakeRetries), function()
					refresh()
				end)
				return
			else
				model.status, model.reason = "conflict", "HANDSHAKE_FAILED"
			end
			render()
		end)
	end
	local function open(key: string)
		section = if section == key then "" else key
		sheet.frame.Visible = section ~= ""
		local title = sheet.frame:WaitForChild("Header"):WaitForChild("Title") :: TextLabel
		title.Text = t(key)
		sheet.scroll.CanvasPosition = Vector2.zero
		render()
	end
	if content.progressionPolicy and not contextual then
		local skillsButton = Components.button(theme, {
			text = t("skills"),
			parent = root,
			size = UDim2.fromOffset(160, 48),
			position = UDim2.new(1, -168, 0, 240),
			onClick = function()
				open("skills")
			end,
		})
		skillsButton.Name = "Skills"
	end
	local tabs: { [string]: TextButton } = {}
	for index, key in { "bag", "craft", "build" } do
		local tab = Components.button(theme, {
			text = t(key),
			size = UDim2.new(1 / 3, -4, 1, 0),
			position = UDim2.fromScale((index - 1) / 3, 0),
			parent = toolbar,
			onClick = function()
				open(key)
			end,
		})
		tab.Name = "Tab-" .. key
		fitText(tab)
		tabs[key] = tab
	end
	local restButton = Components.button(theme, {
		text = t("rest"),
		size = UDim2.new(1, 0, 0, 48),
		position = UDim2.new(0, 0, 1, -48),
		parent = root,
		onClick = rest,
	})
	restButton.Name, restButton.TextSize = "Rest", 15
	fitText(restButton)
	local attackButton = Components.button(theme, {
		text = t("attack"),
		size = UDim2.fromOffset(320, 48),
		parent = root,
		onClick = attack,
	})
	attackButton.Name, attackButton.AnchorPoint = "Attack", Vector2.new(1, 0)
	fitText(attackButton)
	attackButton.Visible = false
	-- Ranged shot and stance selector (catalog ui.combat): touch buttons on the combat card, V / X on PC.
	local function cycleStance()
		local view = model.snapshot.contracts and model.snapshot.contracts.stance
		local nextId = Model.nextStance(view)
		if nextId then
			command("stance-set", { nextId })
		end
	end
	local defenseButtons: { [string]: TextButton } = {}
	for index, combatAction in { "shoot", "stance" } do
		local combatButton = Components.button(theme, {
			text = t(combatAction),
			size = UDim2.fromOffset(76, 48),
			position = UDim2.new(1, -(index + 2) * 84, 0, 184),
			parent = root,
			onClick = function()
				if combatAction == "shoot" then
					attack(true)
				else
					cycleStance()
				end
			end,
		})
		combatButton.Name = combatAction
		combatButton.Visible = false
		defenseButtons[combatAction] = combatButton
	end
	for index, defenseAction in { "dodge", "guard" } do
		local defenseButton = Components.button(theme, {
			text = t(defenseAction),
			size = UDim2.fromOffset(76, 48),
			position = UDim2.new(1, -index * 84, 0, 184),
			parent = root,
			onClick = function()
				command(defenseAction, {})
			end,
		})
		defenseButton.Name = defenseAction
		defenseButton.Visible = content.progressionPolicy ~= nil and content.progressionPolicy.combat ~= nil
		defenseButtons[defenseAction] = defenseButton
	end
	local restPrompt: BillboardGui? = nil
	local combatPrompt: BillboardGui? = nil
	if contextual and not shell then
		local restCard = Instance.new("BillboardGui")
		restCard.Name, restCard.Size = "RestInteraction", UDim2.fromOffset(132, 48)
		restCard.Active = true
		restCard.StudsOffset, restCard.AlwaysOnTop = Vector3.new(0, 3, 0), true
		restCard.Parent = gui
		restButton.Parent, restButton.AnchorPoint = restCard, Vector2.zero
		restButton.Position, restButton.Size = UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1)
		restPrompt = restCard
		local combatCard = Instance.new("BillboardGui")
		combatCard.Name, combatCard.Size = "CombatInteraction", UDim2.fromOffset(216, 160)
		combatCard.Active = true
		combatCard.StudsOffset, combatCard.AlwaysOnTop = Vector3.new(0, 4, 0), true
		combatCard.Parent = gui
		attackButton.Parent, attackButton.AnchorPoint = combatCard, Vector2.zero
		attackButton.Position, attackButton.Size = UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 48)
		for index, key in { "dodge", "guard", "shoot", "stance" } do
			local defenseControl = defenseButtons[key]
			defenseControl.Parent = combatCard
			defenseControl.Position, defenseControl.Size =
				UDim2.fromOffset(((index - 1) % 2) * 112, 56 * (1 + (index - 1) // 2)), UDim2.fromOffset(104, 48)
		end
		combatPrompt = combatCard
		toolbar.Visible = false
	end
	-- HUD shell (Robango A4, ui-spec "Tideglass"): vitals top-left, minimap + XY and the quest card
	-- top-right (ExtensionPanels), a menu (ExtensionPanels) / emote / chat row bottom-left and the tide-arc cluster of
	-- pebble tokens bottom-right. The combat buttons above become cluster tokens.
	local shellButtons: { [string]: TextButton } = {}
	local nearestPromptFn: (() -> ProximityPrompt?)? = nil
	local function labelOf(prompt: ProximityPrompt?): string
		return if prompt and prompt.ActionText ~= "" then prompt.ActionText else t("shell.interact")
	end
	local shellRow: { [number]: TextButton } = {}
	local extensions: any = {}
	local shownPrompts: { [ProximityPrompt]: boolean } = {}
	local stopOverlays: (() -> ())? = nil
	local shellOptions = shell
	if shellOptions then
		toolbar.Visible, restButton.Visible = false, false
		for _, item in { vitals, coins, status, tracker, restButton, attackButton } do
			item.Parent = gui
		end
		for _, item in defenseButtons do
			item.Parent = gui
		end
		local function nearestPrompt(): ProximityPrompt?
			local character = player.Character
			local pivot = if character then character:FindFirstChild("HumanoidRootPart") else nil
			local best: ProximityPrompt? = nil
			local distance = math.huge
			for prompt in shownPrompts do
				local holder = prompt.Parent
				local at = if holder and holder:IsA("Attachment")
					then holder.WorldPosition
					elseif holder and holder:IsA("BasePart") then holder.Position
					else nil
				if prompt.Enabled and at and pivot and pivot:IsA("BasePart") then
					local d = (at - pivot.Position).Magnitude
					if d < distance then
						best, distance = prompt, d
					end
				end
			end
			return best
		end
		nearestPromptFn = nearestPrompt
		local function interact()
			if nearest("campfire") then
				rest()
				return
			end
			local best = nearestPrompt()
			-- A hold prompt completes only by holding the token (hold-to-fill below); a tap on it
			-- began and ended the hold at HoldDuration, which never fired the prompt (D2c R04).
			if best and best.HoldDuration <= 0 then
				best:InputHoldBegin()
				task.defer(function()
					best:InputHoldEnd()
				end)
			end
		end
		local guiService = game:GetService("GuiService")
		local actionsById: { [string]: () -> () } = {
			interact = interact,
			mount = function()
				shellOptions.open("taming")
			end,
			skills = function()
				open("skills")
			end,
			consume = function()
				open("bag")
			end,
			build = function()
				open("build")
			end,
			capture = function()
				if shellOptions.pet then
					shellOptions.pet.act("capture")
				end
			end,
			dismount = function()
				if shellOptions.pet then
					shellOptions.pet.act("dismount")
				end
			end,
			pet = function()
				if shellOptions.pet then
					shellOptions.pet.act("pet")
				end
			end,
			emote = function()
				pcall(function()
					guiService:SetEmotesMenuOpen(not guiService:GetEmotesMenuOpen())
				end)
			end,
			chat = function()
				local starter = game:GetService("StarterGui")
				local ok = pcall(function()
					starter:SetCore("ChatActive", not starter:GetCore("ChatActive"))
				end)
				if not ok then
					local window = game:GetService("TextChatService"):FindFirstChildOfClass("ChatWindowConfiguration")
					if window then
						window.Enabled = not window.Enabled
					end
				end
			end,
		}
		local function token(id: string): TextButton
			local item = Components.button(theme, {
				text = t("shell." .. id),
				size = UDim2.fromOffset(48, 48),
				parent = gui,
				onClick = actionsById[id],
			})
			item.Name = "Token-" .. id
			return item
		end
		for _, id in { "interact", "mount", "skills", "consume", "build", "capture", "dismount", "pet" } do
			shellButtons[id] = token(id)
		end
		-- D2c R04 hold-to-fill: pressing the interact token on a hold prompt holds it; the ring fills
		-- over HoldDuration; the hold ends once the prompt fired, or cancels on an early release.
		do
			local holdToken = shellButtons.interact
			local setRing = HudShell.holdRing(holdToken)
			local hold: any = nil
			local function finish(kind: string)
				local current = hold
				if not current then
					return
				end
				hold = nil
				current.connection:Disconnect()
				current.prompt:InputHoldEnd()
				setRing(0)
				holdToken:SetAttribute("ForgeHoldResult", kind)
			end
			local function pressed(inputObject: InputObject): boolean
				local kind = inputObject.UserInputType
				return kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1
			end
			table.insert(
				connections,
				holdToken.InputBegan:Connect(function(inputObject: InputObject)
					if hold or not pressed(inputObject) or nearest("campfire") then
						return
					end
					local best = nearestPrompt()
					if not best or best.HoldDuration <= 0 or not holdToken.Interactable then
						return
					end
					local current: any = {
						prompt = best,
						started = os.clock(),
						triggered = false,
						released = false,
					}
					current.connection = best.Triggered:Connect(function()
						current.triggered = true
					end)
					hold = current
					holdToken:SetAttribute("ForgeHoldResult", "hold")
					best:InputHoldBegin()
				end)
			)
			table.insert(
				connections,
				holdToken.InputEnded:Connect(function(inputObject: InputObject)
					if hold and pressed(inputObject) then
						hold.released = true
					end
				end)
			)
			table.insert(
				connections,
				run.RenderStepped:Connect(function()
					local current = hold
					if not current then
						return
					end
					local elapsed = os.clock() - current.started
					local step = HudShell.holdStep({
						elapsed = elapsed,
						duration = current.prompt.HoldDuration,
						triggered = current.triggered,
						-- The prompt went away (walked off, beat over): same as letting go.
						released = current.released or not shownPrompts[current.prompt] or not current.prompt.Enabled,
					})
					if step == "hold" then
						setRing(math.max(0.01, HudShell.holdProgress(elapsed, current.prompt.HoldDuration)))
					else
						finish(step)
					end
				end)
			)
		end
		shellButtons.attack, shellButtons.shoot = attackButton, defenseButtons.shoot
		for _, id in { "dodge", "guard", "stance" } do
			shellButtons[id] = defenseButtons[id]
		end
		local rowTokens: { string } = if shellOptions.chat == false then { "emote" } else { "emote", "chat" }
		for index, id in rowTokens do
			shellRow[index + 1] = token(id)
		end
		for _, item in shellButtons do
			-- Fixed token text (HudShell.tokenText): TextScaled shrank two-word labels under 10 px.
			item.TextScaled, item.TextWrapped = false, true
		end
		for _, item in pairs(shellRow) do
			item.TextScaled, item.TextWrapped = false, true
		end
		local promptService = game:GetService("ProximityPromptService")
		table.insert(
			connections,
			promptService.PromptShown:Connect(function(prompt: ProximityPrompt)
				shownPrompts[prompt] = true
				-- Shell: the interact token carries the prompt (its ActionText); Roblox's default prompt
				-- card drew over the player at spawn (staging v26). Local-only property change.
				if input.TouchEnabled and prompt.Style == Enum.ProximityPromptStyle.Default then
					prompt.Style = Enum.ProximityPromptStyle.Custom
				end
			end)
		)
		table.insert(
			connections,
			promptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
				shownPrompts[prompt] = nil
			end)
		)
		stopOverlays = HudShell.startOverlays({
			gui = gui,
			hidden = function(): boolean
				return sheet.frame.Visible
					or player:GetAttribute("ForgeExtensionSheetOpen") == true
					or HudShell.sheetOpen(player:FindFirstChild("PlayerGui"))
			end,
			name = shellOptions.name,
			hint = shellOptions.hint,
			-- The focus label (HudShell declutter): the engaged creature (CombatHud sets its id on the
			-- player), else the highlighted gather node (nearestGather).
			focus = function(): Instance?
				local fighting = player:GetAttribute(HudShell.COMBAT_TARGET_ATTRIBUTE)
				local wildlife = if fighting ~= nil then world:FindFirstChild("ForgeWildlife") else nil
				for _, animal in if wildlife then wildlife:GetChildren() else {} do
					if animal:GetAttribute("ForgeWildlifeId") == fighting then
						return animal
					end
				end
				return if highlight.Enabled then highlight.Adornee else nil
			end,
			coordsText = function(px: number, pz: number): string
				return string.format(t("shell.coords"), px, pz)
			end,
			tribe = function(): string
				if shellOptions.clanTag == false then
					return ""
				end
				local clan = extensions.clan
				return if type(clan) == "table"
						and type(clan.clanId) == "string"
						and clan.clanId ~= ""
					then string.format(t("shell.tribe"), clan.clanId)
					else t("shell.no_tribe")
			end,
			-- Other players' clan: the server's ForgeClan player attribute (G22); none shows the name only.
			tribeOf = function(other: Player): string?
				local clanId = other:GetAttribute("ForgeClan")
				return if type(clanId) == "string" and clanId ~= ""
					then string.format(t("shell.tribe"), clanId)
					else nil
			end,
		})
	end
	-- Item hotbar (shell, HUD polish): the backpack tools as icon slots bottom-centre, replacing the
	-- engine Backpack bar (RobangoBoot hides it while ForgeHudHotbar is set). Tap or 1-6 equips,
	-- tapping the held tool puts it away. Presentation only: the server tools registry stays the
	-- authority over what a Tool does.
	local hotbarSlots: { any } = {}
	local hotbarTools: { [number]: any } = {}
	local function equipSlot(index: number)
		local tool = hotbarTools[index]
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not tool or not humanoid then
			return
		end
		if tool.Parent == character then
			humanoid:UnequipTools()
		else
			humanoid:EquipTool(tool)
		end
	end
	local function hotbarStep(modal: boolean)
		local region = shellRegions and shellRegions.hotbar
		if not region then
			return
		end
		local tools: { any } = {}
		local character = player.Character
		local backpack = player:FindFirstChildOfClass("Backpack")
		for _, holder in { character, backpack } do
			for _, child in if holder then holder:GetChildren() else {} do
				if child:IsA("Tool") then
					table.insert(tools, child)
				end
			end
		end
		-- Stable order: by catalog id then name, so a slot keeps its tool when it is equipped.
		table.sort(tools, function(a, b)
			local ka = tostring(a:GetAttribute("ForgeCatalogId") or "") .. a.Name
			local kb = tostring(b:GetAttribute("ForgeCatalogId") or "") .. b.Name
			return ka < kb
		end)
		local size = region.height
		local inside = HudShell.hotbarSlot(size)
		local shownSlots = if modal then 0 else (shellRegions.hotbarSlots or 0)
		-- Framed tray behind the slots (iconfix capture: bare numbers floated over the ground).
		local tray: any = gui:FindFirstChild("HotbarTray")
		if not tray then
			tray = Instance.new("Frame")
			tray.Name, tray.BorderSizePixel, tray.Active = "HotbarTray", 0, false
			tray.BackgroundColor3, tray.BackgroundTransparency = HudShell.color(HudShell.PALETTE.ink), 0.45
			local round = Instance.new("UICorner")
			round.CornerRadius, round.Parent = UDim.new(0, 10), tray
			local rim = Instance.new("UIStroke")
			rim.Color, rim.Thickness, rim.Transparency = HudShell.color(HudShell.PALETTE.driftDark), 1.5, 0.2
			rim.ApplyStrokeMode, rim.Parent = Enum.ApplyStrokeMode.Border, tray
			tray.Parent = gui
		end
		HudShell.put(
			tray,
			HudShell.hotbarTray({
				x = region.x,
				y = region.y,
				width = shownSlots * size + math.max(0, shownSlots - 1) * HudShell.HOTBAR_GAP,
				height = size,
			})
		)
		tray.Visible = shownSlots > 0
		-- One name tooltip, for the selected (held) slot only: the per-slot names stacked into each
		-- other under the bar ("돌무더기" over another line).
		local tip: any = gui:FindFirstChild("HotbarTip")
		if not tip then
			tip = Instance.new("TextLabel")
			tip.Name, tip.BorderSizePixel, tip.Active = "HotbarTip", 0, false
			tip.BackgroundColor3, tip.BackgroundTransparency = HudShell.color(HudShell.PALETTE.ink), 0.25
			tip.TextColor3, tip.Font = HudShell.color(HudShell.PALETTE.bone), Enum.Font.BuilderSansBold
			tip.TextTruncate = Enum.TextTruncate.AtEnd
			local round = Instance.new("UICorner")
			round.CornerRadius, round.Parent = UDim.new(0.5, 0), tip
			tip.Parent = gui
		end
		local bag = Model.bag(model.snapshot)
		local heldSlot: number? = nil
		for index = 1, HudShell.HOTBAR_SLOTS do
			local slot: any = hotbarSlots[index]
			if not slot then
				slot = Instance.new("TextButton")
				slot.Name, slot.Text, slot.AutoButtonColor = "HotbarSlot" .. index, "", false
				slot.Font, slot.TextWrapped = Enum.Font.BuilderSansBold, true
				slot.TextColor3 = HudShell.color(HudShell.PALETTE.bone)
				local round = Instance.new("UICorner")
				round.CornerRadius, round.Parent = UDim.new(0, 8), slot
				local rim = Instance.new("UIStroke")
				rim.Name, rim.ApplyStrokeMode, rim.Parent = "SlotRim", Enum.ApplyStrokeMode.Border, slot
				local image = Instance.new("ImageLabel")
				image.Name, image.BackgroundTransparency, image.ScaleType = "Icon", 1, Enum.ScaleType.Fit
				image.Parent = slot
				local key = Instance.new("TextLabel")
				key.Name, key.BackgroundTransparency, key.Text = "Key", 1, tostring(index)
				key.Font, key.ZIndex = Enum.Font.BuilderSansBold, 2
				key.TextColor3, key.TextXAlignment =
					HudShell.color(HudShell.PALETTE.boneShade), Enum.TextXAlignment.Left
				key.TextYAlignment, key.Parent = Enum.TextYAlignment.Top, slot
				local count = Instance.new("TextLabel")
				count.Name, count.BackgroundTransparency, count.Text = "Count", 1, ""
				count.Font, count.ZIndex = Enum.Font.BuilderSansBold, 2
				count.TextColor3, count.TextXAlignment =
					HudShell.color(HudShell.PALETTE.bone), Enum.TextXAlignment.Right
				count.TextStrokeColor3, count.TextStrokeTransparency = HudShell.color(HudShell.PALETTE.ink), 0.2
				count.Parent = slot
				slot.Activated:Connect(function()
					equipSlot(index)
				end)
				slot.Parent = gui
				hotbarSlots[index] = slot
			end
			local tool = tools[index]
			hotbarTools[index] = tool
			HudShell.put(slot, {
				x = region.x + (index - 1) * (size + HudShell.HOTBAR_GAP),
				y = region.y,
				width = size,
				height = size,
			})
			slot.Visible = index <= shownSlots
			local held = tool ~= nil and tool.Parent == character
			if held and slot.Visible then
				heldSlot = index
			end
			local catalogId = tool and tool:GetAttribute("ForgeCatalogId")
			local icon = if tool
					and options.icons
					and type(catalogId) == "string"
				then options.icons.item(catalogId)
				else nil
			local image = slot:FindFirstChild("Icon") :: ImageLabel
			HudShell.put(image, inside.icon)
			image.Image = if icon and icon.image then icon.image else ""
			-- No painted icon: the tool's first letter, never a blank slot.
			slot.Text = if tool and image.Image == "" then utf8.char(utf8.codepoint(tool.Name, 1)) else ""
			slot.TextSize = math.floor(size * 0.4)
			local key = slot:FindFirstChild("Key") :: TextLabel
			HudShell.put(key, inside.key)
			key.TextSize = inside.text
			-- Stack count inside the slot (bottom right), only when more than one is carried.
			local amount = if bag and type(catalogId) == "string" then Model.held(bag, catalogId) else 0
			local count = slot:FindFirstChild("Count") :: TextLabel
			HudShell.put(count, inside.count)
			count.TextSize, count.Text = inside.text, if amount > 1 then tostring(amount) else ""
			local look = HudShell.hotbarLook(if held then "selected" elseif tool then "filled" else "empty")
			slot.BackgroundColor3 = HudShell.color((HudShell.PALETTE :: any)[look.fillColor])
			slot.BackgroundTransparency = look.fill
			key.TextTransparency = look.key
			slot:SetAttribute("ForgeSlotState", if held then "selected" elseif tool then "filled" else "empty")
			slot.Active, slot.Interactable = tool ~= nil, tool ~= nil
			local rim = slot:FindFirstChild("SlotRim") :: UIStroke
			rim.Color = HudShell.color((HudShell.PALETTE :: any)[look.rim])
			rim.Thickness, rim.Transparency = look.rimWidth, look.rimAlpha
		end
		local tipText = HudShell.tokenText("caption", shellRegions.safeHeight, input.TouchEnabled)
		local held = heldSlot and hotbarTools[heldSlot]
		if held then
			HudShell.put(tip, HudShell.hotbarTip(region, heldSlot :: number, tipText))
			tip.Text, tip.TextSize = held.Name, tipText
		end
		tip.Visible = held ~= nil
	end
	if shell then
		player:SetAttribute("ForgeHudHotbar", true)
		table.insert(
			connections,
			input.InputBegan:Connect(function(key: InputObject, processed: boolean)
				if processed or input:GetFocusedTextBox() then
					return
				end
				local fanGui = player.PlayerGui:FindFirstChild("ForgeGatherFan")
				local fan = fanGui and fanGui:FindFirstChild("GatherFan")
				if fan and fan:IsA("GuiObject") and fan.Visible then
					return -- 1-6 pick a gather output while the fan is open.
				end
				local number = key.KeyCode.Value - Enum.KeyCode.One.Value + 1
				if number >= 1 and number <= HudShell.HOTBAR_SLOTS then
					equipSlot(number)
				end
			end)
		)
	end
	-- Shows the tokens for the current context at their tide-arc slots; hides the rest.
	local function layoutShell(actions: any, modal: boolean)
		if not shellRegions then
			return
		end
		-- D2c: the hotbar and the bottom-left row hide under any full sheet or flagged picker (down
		-- panel, carcass harvest picker, survivor picker) and come back when it closes.
		local bottomHidden = modal
			or HudShell.bottomHidden(player:FindFirstChild("PlayerGui"), function(attribute: string): any
				return player:GetAttribute(attribute)
			end)
		hotbarStep(bottomHidden)
		local taming = extensions.taming
		local companions = if type(taming) == "table" then taming.companions else nil
		local policy = model.durable
		local flags = {
			combat = actions.attack or actions.shoot,
			building = placementBar.Visible,
			interact = nearest("campfire") ~= nil or next(shownPrompts) ~= nil,
			dodge = actions.dodge,
			guard = actions.guard,
			stance = actions.stance,
			attack = actions.attack,
			shoot = actions.shoot,
			mount = type(taming) == "table"
				and (taming.ride ~= nil or (type(companions) == "table" and companions.deployed ~= nil)),
			skills = content.progressionPolicy ~= nil,
			capture = shell ~= nil and shell.pet ~= nil and shell.pet.capturable(),
			riding = shell ~= nil and shell.pet ~= nil and type(taming) == "table" and taming.ride ~= nil,
		}
		local shown: { [string]: boolean } = {}
		local stanceView = model.snapshot.contracts and model.snapshot.contracts.stance
		local iconContext = {
			rest = nearest("campfire") ~= nil,
			gather = nearestPromptFn ~= nil and (function()
				local best = nearestPromptFn()
				return best ~= nil and best.Name == "ForgeGather"
			end)(),
			stance = if type(stanceView) == "table" then stanceView.current else nil,
		}
		local function glyph(id: string): string?
			local icon = if options.icons then options.icons.ui(HudShell.tokenIcon(id, iconContext)) else nil
			return if icon then icon.image else nil
		end
		local caption = ""
		local primaryRect: any = nil
		-- The caption pill keeps clear of every other shown token and the hotbar (studio-after defect 3).
		local captionAvoid: { any } = { shellRegions.hotbarFrame }
		if not modal then
			for _, entry in HudShell.tokens(flags) do
				local item = shellButtons[entry.id]
				local r = shellRegions.tokens[entry.slot]
				if item and r then
					shown[entry.id] = true
					HudShell.put(item, r)
					item.TextSize = HudShell.tokenText("label", shellRegions.safeHeight, input.TouchEnabled)
					local enabled = entry.enabled and policy ~= nil and model.pending == nil
					item.Active, item.Interactable = enabled, enabled
					local tokenLabel = if entry.id == "stance"
						then Model.stanceLabel(locale, model.snapshot.contracts and model.snapshot.contracts.stance, t)
						elseif entry.id == "interact" and nearestPromptFn and not nearest("campfire") then labelOf(
							nearestPromptFn()
						)
						elseif entry.id == "interact" and nearest("campfire") then t("rest")
						else t("shell." .. entry.id)
					item.Text = tokenLabel
					-- Icon-only token; the label stays the button's Text (accessibility, QA) but is drawn
					-- only as the primary action's caption pill.
					HudShell.iconToken(
						item,
						glyph(entry.id),
						if not enabled then "disabled" elseif entry.slot == "P" then "primary" else "normal"
					)
					if entry.slot == "P" and enabled then
						caption, primaryRect = tokenLabel, r
					elseif entry.slot ~= "P" then
						table.insert(captionAvoid, r)
					end
				end
			end
		end
		for id, item in shellButtons do
			item.Visible = shown[id] == true
		end
		-- The genre gather button (GatheringClient's ForgeGatherTouch.Gather, focus-aware) becomes the
		-- primary token while a node is in reach: same slot, painted gather glyph, its own caption.
		local gatherGui = player.PlayerGui:FindFirstChild("ForgeGatherTouch")
		local gather = gatherGui and gatherGui:FindFirstChild("Gather")
		local pSlot = shellRegions.tokens.P
		if gather and gather:IsA("TextButton") and gather.Visible and not modal and pSlot then
			HudShell.put(gather, pSlot)
			HudShell.iconToken(gather, glyph("gather"), "primary")
			if shellButtons.interact and shown.interact then
				shellButtons.interact.Visible = false
			end
			if primaryRect == nil or primaryRect == pSlot then
				caption, primaryRect = gather.Text, pSlot
			end
		end
		HudShell.tokenCaption(
			gui,
			"PrimaryCaption",
			primaryRect or { x = 0, y = 0, width = 0, height = 0 },
			if primaryRect then caption else "",
			HudShell.tokenText("label", shellRegions.safeHeight, input.TouchEnabled),
			captionAvoid,
			HudShell.guiClear(gui),
			shellRegions.cluster
		)
		restButton.Visible = false
		local rowVisible = not bottomHidden
		for index, item in pairs(shellRow) do
			HudShell.put(item, shellRegions.rowSlots[index])
			item.Visible = rowVisible
			item.TextSize = HudShell.tokenText("label", shellRegions.safeHeight, input.TouchEnabled)
			HudShell.iconToken(item, glyph(if index == 2 then "emote" else "chat"), "normal")
		end
	end
	local CHAT_RESERVE_WIDTH = 240
	local MIN_STACK_WIDTH = 160
	local function chatRightEdge(): number
		local chat = player.PlayerGui:FindFirstChild("Chat")
		local right = 0
		if chat ~= nil and chat:IsA("ScreenGui") and chat.Enabled then
			for _, item in chat:GetDescendants() do
				if item:IsA("GuiObject") and item.Visible then
					local frameSize = item.AbsoluteSize
					if frameSize.X >= 80 and frameSize.Y >= 16 and frameSize.X <= gui.AbsoluteSize.X * 0.6 then
						right = math.max(right, item.AbsolutePosition.X + frameSize.X - gui.AbsolutePosition.X)
					end
				end
			end
		end
		return if right > 0 then right + 8 else CHAT_RESERVE_WIDTH
	end

	local placeNotices: () -> ()
	local function resize()
		local size = root.AbsoluteSize
		if contextual then
			if not panelLayout then
				placeSideSheet()
			end
			if shell then
				local view = gui.AbsoluteSize
				shellRegions = HudShell.regions(view.X, view.Y, HudShell.guiClear(gui), input.TouchEnabled)
				HudShell.put(vitals, shellRegions.vitals)
				HudShell.put(status, shellRegions.banner)
				local chips = shellRegions.chips
				HudShell.put(
					coins,
					{ x = chips.x, y = chips.y, width = chips.width, height = math.min(28, chips.height) }
				)
				HudShell.coinChip(coins, math.min(28, chips.height))
				local geometry = HudShell.vitalsRows(shellRegions.vitals)
				local badge = levelBadge
				if badge then
					HudShell.put(badge, geometry.badge)
					if levelNumber then
						levelNumber.TextSize = math.max(11, math.floor(geometry.badge.height * 0.3))
					end
				end
				for index, stat in { "health", "hunger", "fatigue" } do
					local bar, row = statBars[stat], geometry.rows[index]
					bar.symbol.Visible = bar.icon == nil
					if bar.icon then
						HudShell.put(bar.icon, row.icon)
					else
						-- No painted icon: the first letter of the stat word stands in.
						HudShell.put(bar.symbol, row.icon)
						bar.symbol.Text = utf8.char(utf8.codepoint(t(stat), 1))
					end
					HudShell.put(bar.track, row.track)
					HudShell.put(bar.value, row.value)
					bar.value.TextSize = geometry.text
					bar.value.TextXAlignment = Enum.TextXAlignment.Right
					local fit = bar.value:FindFirstChildOfClass("UITextSizeConstraint")
					if fit then
						fit.MaxTextSize, fit.MinTextSize = geometry.text, math.min(fit.MinTextSize, geometry.text)
					end
				end
				if panelLayout then
					render()
				end
				return
			end
			local hud = Model.contextHudBounds(size.X + 24, size.Y + 16)
			local bounds = hud.vitals
			vitals.AnchorPoint, vitals.Position = Vector2.zero, UDim2.fromOffset(bounds.x - 12, bounds.y - 8)
			vitals.Size = UDim2.fromOffset(bounds.width, bounds.height)
			coins.Position = UDim2.fromOffset(hud.coins.x - 12, hud.coins.y - 8)
			if hud.status then
				-- Portrait phone: the sync status stays in the HUD column, right of Roblox's chat.
				status.AnchorPoint, status.Position =
					Vector2.zero, UDim2.fromOffset(hud.status.x - 12, hud.status.y - 8)
				status.Size = UDim2.fromOffset(hud.status.width, hud.status.height)
				return
			end
			status.AnchorPoint, status.Position = Vector2.new(1, 0), UDim2.new(1, -80, 0, 0)
			status.Size = UDim2.fromOffset(math.min(312, size.X - 80), 56)
			return
		end
		local portrait = size.Y > size.X
		local chatRight = chatRightEdge()
		local width = if portrait
			then math.max(MIN_STACK_WIDTH, math.floor(size.X - chatRight - 12))
			else math.min(320, math.floor(size.X * 0.45))
		local sheetWidth, sheetHeight, top, right = Model.sheetBounds(size.X, size.Y, if portrait then nil else width)
		sheet.frame.Position = UDim2.new(1, -right, 0, top)
		sheet.frame.Size = UDim2.fromOffset(sheetWidth, sheetHeight)
		vitals.AnchorPoint, status.AnchorPoint, toolbar.AnchorPoint, restButton.AnchorPoint =
			Vector2.new(1, 0), Vector2.new(1, 0), Vector2.new(1, 0), Vector2.new(1, 0)
		vitals.Position, toolbar.Position, status.Position, restButton.Position =
			UDim2.fromScale(1, 0), UDim2.new(1, 0, 0, 40), UDim2.new(1, 0, 0, 92), UDim2.new(1, 0, 0, 132)
		vitals.Size, status.Size, toolbar.Size =
			UDim2.fromOffset(width, 76), UDim2.fromOffset(width, 36), UDim2.fromOffset(width, 48)
		toolbar.Position, status.Position = UDim2.new(1, 0, 0, 80), UDim2.new(1, 0, 0, 132)
		restButton.Size = UDim2.fromOffset(width, 48)
		attackButton.Position, attackButton.Size =
			UDim2.new(1, 0, 0, 132), UDim2.fromOffset(math.floor(width / 2) - 4, 48)
		restButton.Position, restButton.Size =
			UDim2.new(1, -math.floor(width / 2) - 4, 0, 132), UDim2.fromOffset(math.floor(width / 2) - 4, 48)
	end
	table.insert(connections, root:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize))
	-- Status line and material/refusal toast while a sheet is open: HudShell.noticeLane, never over
	-- the sheet's rows (D2b: "pending" top-centre over bag, skills and build). Back to the HUD slots
	-- when the sheet closes.
	local laned = false
	-- p134 v57: the hunger line (status region, 0.16H) covered half of the companion's name tag. The
	-- contextual banner takes the first lane (HudShell.bannerRect) that misses every shown world name
	-- tag (HudShell.NAME_TAG: player tags, the companion plate) and the combat target bar.
	local function placeBanner()
		if not shell or not shellRegions or not status.Visible then
			return
		end
		local camera = world.CurrentCamera
		local origin = gui.AbsolutePosition
		local avoid: { HudShell.Rect } = {}
		for _, tag in tags:GetTagged(HudShell.NAME_TAG) do
			local adornee = if tag:IsA("BillboardGui") then (tag.Adornee or tag.Parent) else nil
			if camera and tag.Enabled and adornee and adornee:IsA("BasePart") then
				local lift = tag.StudsOffsetWorldSpace + adornee.CFrame:VectorToWorldSpace(tag.StudsOffset)
				-- Screen point (top-bar inset applied), the same space as the gui's AbsolutePosition.
				local point, visible = camera:WorldToScreenPoint(adornee.Position + lift)
				if visible then
					local size = tag.AbsoluteSize
					table.insert(avoid, {
						x = point.X - origin.X - size.X / 2,
						y = point.Y - origin.Y - size.Y / 2,
						width = size.X,
						height = size.Y,
					})
				end
			end
		end
		local combat = player.PlayerGui:FindFirstChild("ForgeCombatHUD")
		local bar = combat and combat:FindFirstChild("TargetBar")
		if bar and bar:IsA("GuiObject") and bar.Visible then
			local at = bar.AbsolutePosition - origin
			table.insert(avoid, { x = at.X, y = at.Y, width = bar.AbsoluteSize.X, height = bar.AbsoluteSize.Y })
		end
		HudShell.put(status, HudShell.bannerRect(shellRegions, avoid), status.Parent.AbsolutePosition - origin)
	end
	placeNotices = function()
		if not sheet.frame.Visible then
			if laned then
				laned = false
				toast.Size, toast.Position = UDim2.new(1, -24, 0, 52), UDim2.new(0, 12, 1, -264)
				resize()
			end
			placeBanner()
			return
		end
		laned = true
		-- Above the sheet (Sibling ZIndex at the gui level; the sheet's root is ZIndex 1).
		toast.ZIndex, status.ZIndex = 60, 60
		local view, at = gui.AbsoluteSize, gui.AbsolutePosition
		local frameAt = sheet.frame.AbsolutePosition - at
		local frameSize = sheet.frame.AbsoluteSize
		local lane = HudShell.noticeLane(view.X, view.Y, HudShell.guiClear(gui), {
			x = frameAt.X,
			y = frameAt.Y,
			width = frameSize.X,
			height = frameSize.Y,
		}, panelLayout)
		HudShell.put(toast, lane, toast.Parent.AbsolutePosition - at)
		HudShell.put(status, lane, status.Parent.AbsolutePosition - at)
		-- One line at a time: the newer toast hides the status line behind it.
		if toast.Visible then
			status.Visible = false
		end
	end
	local RunService = game:GetService("RunService")
	local lastChatRight: number? = nil
	local function followChat(): ()
		local right = chatRightEdge()
		if right ~= lastChatRight then
			lastChatRight = right
			resize()
		end
	end
	followChat()
	table.insert(connections, RunService.Heartbeat:Connect(followChat))
	table.insert(
		connections,
		sheet.close.Activated:Connect(function()
			section = ""
			sheet.frame.Visible = false
			placementBar.Visible, toast.Visible = false, false
			preview()
		end)
	)
	table.insert(
		connections,
		input.InputBegan:Connect(function(key, processed)
			if processed or input:GetFocusedTextBox() then
				return
			end
			if key.KeyCode == Enum.KeyCode.I then
				open("bag")
			elseif key.KeyCode == Enum.KeyCode.Return and section == "build" then
				local settlement, warehouse = model.snapshot.settlement, model.snapshot.warehouse
				if settlement and warehouse then
					for _, entry in Model.placements(settlement, model.actor) do
						if entry.placement.definition.id == structureId then
							command("settlement-place", { entry.id, settlement.version, warehouse.version })
							break
						end
					end
				end
			elseif key.KeyCode == Enum.KeyCode.C then
				open("craft")
			elseif key.KeyCode == Enum.KeyCode.B then
				open("build")
			elseif key.KeyCode == Enum.KeyCode.R then
				rest()
			elseif
				key.KeyCode == (Enum.KeyCode :: any)[BuildPlacement.ROTATE_KEY]
				and section == "build"
				and structureId
			then
				rotation = (rotation + 1) % 4
				render()
			elseif key.KeyCode == Enum.KeyCode.F then
				attack()
			elseif key.KeyCode == Enum.KeyCode.V then
				attack(true)
			elseif key.KeyCode == Enum.KeyCode.X and content.progressionPolicy and content.progressionPolicy.combat then
				cycleStance()
			elseif key.KeyCode == Enum.KeyCode.Q and content.progressionPolicy and content.progressionPolicy.combat then
				command("dodge", {})
			elseif key.KeyCode == Enum.KeyCode.G and content.progressionPolicy and content.progressionPolicy.combat then
				command("guard", {})
			end
		end)
	)
	table.insert(
		connections,
		state.OnClientEvent:Connect(function(packet)
			if type(packet) == "table" and type(packet.snapshots) == "table" then
				extensions = packet.snapshots.survivalExtensions or extensions
				characterGear = if type(extensions.character) == "table" then extensions.character.gear else nil
			end
			if model.receive(packet) then
				if reportedDeaths == nil or (model.snapshot.vitals and model.snapshot.vitals.healthMilli == 0) then
					-- First snapshot, or down now: the knockout panel speaks, so the toast stays quiet.
					reportedDeaths = Model.deathSequence(model.snapshot)
				elseif Model.knockedDown(reportedDeaths, model.snapshot) then
					reportedDeaths = Model.deathSequence(model.snapshot)
					-- The server already moved the character to spawn: say why instead of a silent reset.
					local line = t("knocked_down")
					toast.Text, toast.Visible = line, true
					task.delay(M.TOAST_SECONDS, function()
						if not disposed and toast.Text == line then
							toast.Visible = false
						end
					end)
				end
				render()
			end
		end)
	)
	local promptService = game:GetService("ProximityPromptService")
	local visibleGather: { [ProximityPrompt]: boolean } = {}
	local function nearestGather()
		local character = player.Character
		local origin = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local closest: BasePart? = nil
		local distance = math.huge
		for prompt in visibleGather do
			local anchor = prompt.Parent
			local target = if anchor and anchor:IsA("Attachment") then anchor.Parent else anchor
			if origin and target and target:IsA("BasePart") then
				local d = (target.Position - (origin :: BasePart).Position).Magnitude
				if d < distance then
					closest, distance = target, d
				end
			end
		end
		highlight.Adornee, highlight.Enabled = closest, closest ~= nil
	end
	table.insert(
		connections,
		promptService.PromptShown:Connect(function(prompt: ProximityPrompt)
			if prompt.Name == "ForgeGather" then
				visibleGather[prompt] = true
				nearestGather()
			end
		end)
	)
	table.insert(
		connections,
		promptService.PromptHidden:Connect(function(prompt)
			visibleGather[prompt] = nil
			nearestGather()
		end)
	)
	table.insert(
		connections,
		run.Heartbeat:Connect(function()
			nearestGather()
			for key, tab in tabs do
				tab.Text = t(key)
			end
			restButton.Text, attackButton.Text = t("rest"), t("attack")
			attackButton.Visible = model.durable ~= nil
				and table.find(model.durable.actions, "survival-coop:attack") ~= nil
			if contextual then
				local modal = sheet.frame.Visible
					or player:GetAttribute("ForgeExtensionSheetOpen") == true
					or (shell ~= nil and HudShell.sheetOpen(player:FindFirstChild("PlayerGui")))
				vitals.Visible = not modal and model.snapshot.vitals ~= nil
				local balance = tonumber(model.snapshot.balance)
				coins.Visible = not modal and balance ~= nil
				-- Shell chip: the shell-money icon carries the name, the pill shows the amount.
				coins.Text = if coins:FindFirstChild("CoinIcon")
					then tostring(balance or 0)
					else string.format(t("coins"), balance or 0)
				local restTarget = nearest("campfire")
				local character = player.Character
				local pivot = if character then character:FindFirstChild("HumanoidRootPart") else nil
				local attackTarget: BasePart? = nil
				local rangedTarget: BasePart? = nil
				local distance = 8
				local rangedDistance = Model.RANGED_STUDS
				local wildlife = world:FindFirstChild("ForgeWildlife")
				local level = playerLevel()
				if pivot and pivot:IsA("BasePart") and wildlife then
					for _, animal in wildlife:GetChildren() do
						local anchor = animal:FindFirstChild("HumanoidRootPart")
						local hp = animal:GetAttribute("ForgeWildlifeHealthMilli")
						if
							anchor
							and anchor:IsA("BasePart")
							and type(hp) == "number"
							and hp > 0
							and Model.autoEligible(content, animal:GetAttribute("ForgeWildlifeKind"), level)
						then
							local d = (anchor.Position - pivot.Position).Magnitude
							if d < distance then
								attackTarget, distance = anchor, d
							end
							if d < rangedDistance then
								rangedTarget, rangedDistance = anchor, d
							end
						end
					end
				end
				local actions = Model.contextActions(
					model.durable,
					model.pending,
					modal,
					restTarget,
					attackTarget,
					rangedTarget,
					Model.rangedReady(Model.bag(model.snapshot), content)
				)
				restButton.Visible, attackButton.Visible = actions.rest, actions.attack
				for key, defenseControl in defenseButtons do
					defenseControl.Visible = actions[key]
				end
				local stanceView = model.snapshot.contracts and model.snapshot.contracts.stance
				defenseButtons.stance.Text = Model.stanceLabel(locale, stanceView, t)
				defenseButtons.shoot.Text = t("shoot")
				if shell then
					layoutShell(actions, modal)
				end
				if restPrompt then
					restPrompt.Enabled = actions.rest
					if restTarget then
						restPrompt.Adornee = restTarget
					end
				end
				if combatPrompt then
					combatPrompt.Enabled = actions.attack or actions.shoot
					local adornee: BasePart? = attackTarget or rangedTarget
					if adornee then
						combatPrompt.Adornee = adornee
					end
				end
				player:SetAttribute("ForgeSurvivalSheetOpen", sheet.frame.Visible)
				placeNotices()
				local gatherGui = player.PlayerGui:FindFirstChild("ForgeGatherTouch")
				promptService.Enabled = not modal
				if gatherGui and gatherGui:IsA("ScreenGui") then
					-- The 360x640 placement bar overlaps the gather button by 8px (p68): hide it while placing.
					gatherGui.Enabled = not modal and not placementBar.Visible
				end
			end
			for item, verb in { [restButton] = "rest", [attackButton] = "attack" } do
				if shell then
					continue
				end
				local enabled = model.pending == nil
					and model.durable ~= nil
					and table.find(model.durable.actions, "survival-coop:" .. verb) ~= nil
				item.Active, item.Selectable, item.Interactable = enabled, enabled, enabled
				item.BackgroundTransparency = if enabled then 0 else 0.7
			end
		end)
	)
	local function destroy()
		if disposed then
			return
		end
		disposed = true
		if contextual then
			promptService.Enabled = true
			player:SetAttribute("ForgeSurvivalSheetOpen", nil)
		end
		for _, connection in connections do
			connection:Disconnect()
		end
		ghost:Destroy()
		highlight:Destroy()
		resultEvent:Destroy()
		requestEvent:Destroy()
		placementGui:Destroy()
		if stopOverlays then
			stopOverlays()
		end
		gui:Destroy()
	end
	table.insert(connections, gui.Destroying:Connect(destroy))
	gui.Parent = player:WaitForChild("PlayerGui")
	resize()
	render()
	refresh()
	return {
		destroy = destroy,
		open = open,
		gui = gui,
		close = function()
			section = ""
			sheet.frame.Visible = false
			placementBar.Visible, toast.Visible = false, false
			preview()
		end,
		isOpen = function(): boolean
			return sheet.frame.Visible or placementBar.Visible
		end,
		-- The player's progression level (nil before the first snapshot), for automatic targeting.
		level = playerLevel,
		opened = sheet.frame:GetPropertyChangedSignal("Visible"),
	}
end
return M
