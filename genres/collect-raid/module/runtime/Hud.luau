--!strict
-- Hud: collect-raid HUD (coins, hatch, siege, merge, quests, store). Generic
-- across packs: config, catalog, and every user-facing string come from `opts`.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Theme = require("../../../../core/ui-kit/Theme")
local Layout = require("../../../../core/ui-kit/Layout")
local Components = require("../../../../core/ui-kit/Components")
local Icons = require("../../../../core/domain/procgen/Icons")
local ImageAdapter = require("../../../../core/infra/render/ImageAdapter")
local theme = Theme.default

export type SourceConfig = {
	id: string,
	displayName: string,
	price: number,
	pool: { { id: string, weight: number, [string]: any } },
	[string]: any,
}
export type CreatureConfig = { id: string, displayName: string, rarity: string, [string]: any }
export type MergeFamily = {
	id: string,
	displayName: string,
	rules: { { from: string, to: string, count: number, resultId: string, [string]: any } },
	[string]: any,
}

export type Config = {
	sources: { [string]: SourceConfig },
	sourceOrder: { string },
	creatures: { [string]: CreatureConfig },
	mergeFamilies: { MergeFamily },
	[string]: any,
}

export type CatalogEntry = { key: string, id: number, price: number, name: string, [string]: any }
export type Catalog = {
	gamepasses: { CatalogEntry },
	products: { CatalogEntry },
	[string]: any,
}

export type ProcAssetsSpecs = { [string]: { spec: any } }

export type Fx = {
	play: (name: string, volume: number?) -> (),
	burst: (position: Vector3, color: Color3, count: number?) -> (),
	popText: (parent: GuiBase2d, text: string, color: Color3) -> (),
	flash: (screenGui: ScreenGui, color: Color3) -> (),
}

export type Copy = {
	guiName: string,
	title: string,
	buyEggsTitle: string,
	mergeTitle: string,
	raidQuestsTitle: string,
	storeTitle: string,
	incubatorsHeader: string,
	hatchOddsHeader: string,
	coinsLabel: (coins: string) -> string,
	creaturesOwnedLabel: (count: number) -> string,
	vaultedLabel: (count: number) -> string,
	emptyInventoryHint: string,
	nextSiegeLabel: (clock: string) -> string,
	siegeActiveLabel: (clock: string) -> string,
	vaultCountsLabel: (teamNames: { string }, counts: { [string]: number }) -> string,
	raidButtonText: string,
	raidResultText: (reason: string) -> string,
	raidNothingReason: string,
	mergeButtonText: (displayName: string) -> string,
	buyButtonText: (id: string, price: number) -> string,
	storeButtonText: (name: string, price: number) -> string,
	storeUnpublishedText: string,
	inviteButtonText: string,
	invitesUnavailableText: string,
	dailyQuestsHeader: string,
	gamePassesHeader: string,
	devProductsHeader: string,
	claimButtonText: string,
	claimedButtonText: string,
	questRowText: (id: string, progress: number, target: number, reward: number) -> string,
	hatchButtonText: (index: number) -> string,
	hatchedPopText: (creatureId: string) -> string,
	slotStatusText: (index: number, sourceId: string, remaining: string) -> string,
	tutorialPrefix: string,
	isRareHatchNotify: (text: string) -> boolean,
}

export type StoreIcons = { [string]: string }

export type Options = {
	config: Config,
	catalog: Catalog,
	fx: Fx,
	procAssets: ProcAssetsSpecs,
	storeIcons: StoreIcons,
	copy: Copy,
	rarityRank: { [string]: number },
	teamNames: { string },
	remotes: {
		BuyEgg: RemoteFunction,
		HatchEgg: RemoteFunction,
		StateChanged: RemoteEvent,
		Raid: RemoteFunction,
		Merge: RemoteFunction,
		ClaimQuest: RemoteFunction,
		SiegeState: RemoteEvent,
		Notify: RemoteEvent,
		StoreOpen: RemoteEvent,
		TutorialState: RemoteEvent,
	},
}

local Hud = {}

function Hud.start(opts: Options): ()
	local Config = opts.config
	local Catalog = opts.catalog
	local Fx = opts.fx
	local Copy = opts.copy

	-- Generated art cache: one EditableImage (Content) per logical icon key, shared
	-- by every label so the client allocates each texture once and reuses it.
	local ICON_SIZE = 28
	local ICON_PX = 64
	local iconCache: { [string]: Content } = {}

	local function iconContent(key: string, pixels: any): Content?
		local cached: Content? = iconCache[key]
		if cached ~= nil then
			return cached
		end
		local content = ImageAdapter.toContent(pixels)
		if content ~= nil then
			iconCache[key] = content
		end
		return content
	end

	local function makeImage(content: Content?, px: number): ImageLabel?
		if content == nil then
			return nil
		end
		local image = Instance.new("ImageLabel")
		image.Name = "Icon"
		image.Size = UDim2.fromOffset(px, px)
		image.BackgroundTransparency = 1
		image.ImageContent = content
		return image
	end

	local function makeIcon(key: string, pixels: any): ImageLabel?
		return makeImage(iconContent(key, pixels), ICON_SIZE)
	end

	local function glyphContent(kind: string): Content?
		local pixels = Icons.glyph(kind, ICON_PX)
		if pixels == nil then
			return nil
		end
		return iconContent("glyph:" .. kind, pixels)
	end

	local function rarityContent(rarity: string): Content?
		return iconContent("rarity:" .. string.lower(rarity), Icons.rarityBadge(rarity, ICON_PX))
	end

	local function creatureContent(id: string): Content?
		local entry = opts.procAssets[id]
		if entry == nil then
			return nil
		end
		return iconContent("creature:" .. id, Icons.creature(entry.spec, ICON_PX))
	end

	local function eggContent(id: string): Content?
		local entry = opts.procAssets[id]
		if entry ~= nil then
			return iconContent("egg:" .. id, Icons.egg(entry.spec, ICON_PX))
		end
		return iconContent(
			"egg:default",
			Icons.egg({ body = { 120, 200, 255 }, accent = { 255, 255, 255 }, seed = 7 }, ICON_PX)
		)
	end

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local BuyEgg = opts.remotes.BuyEgg
	local HatchEgg = opts.remotes.HatchEgg
	local StateChanged = opts.remotes.StateChanged
	local Raid = opts.remotes.Raid
	local MergeRemote = opts.remotes.Merge
	local ClaimQuest = opts.remotes.ClaimQuest
	local SiegeState = opts.remotes.SiegeState
	local Notify = opts.remotes.Notify
	local StoreOpen = opts.remotes.StoreOpen
	local TutorialState = opts.remotes.TutorialState

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = Copy.guiName
	screenGui.ResetOnSpawn = false
	-- Sibling ZIndex keeps descendants drawn above their parent, so the desktop
	-- controls reparented into a phone sheet (ZIndex 1) stay above the opaque
	-- sheet panel (ZIndex 50). Global would sort them behind it and into the
	-- desktop column's shadow ordering.
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Safe area by construction: CoreUISafeInsets insets this ScreenGui's contents
	-- away from the topbar and the touch thumbstick, and one SafeArea frame holds
	-- every element. Nothing here is parented to the raw ScreenGui.
	screenGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	screenGui.Parent = playerGui
	Components.attachScale(screenGui, Layout.uiScaleForViewport)

	local safeArea = Instance.new("Frame")
	safeArea.Name = "SafeArea"
	safeArea.BackgroundTransparency = 1
	safeArea.Position = UDim2.fromOffset(12, 8)
	safeArea.Size = UDim2.new(1, -24, 1, -16)
	safeArea.Parent = screenGui

	-- Local-only notifications. The raid handler fires this and both the HUD (toast)
	-- and Audio (raidMiss cue) listen, so a rejected raid scores without a
	-- server round-trip. Create it if the audio client did not get there first.
	local localNotify = ReplicatedStorage:FindFirstChild("LocalNotify")
	if localNotify == nil or not localNotify:IsA("BindableEvent") then
		local created = Instance.new("BindableEvent")
		created.Name = "LocalNotify"
		created.Parent = ReplicatedStorage
		localNotify = created
	end
	local LocalNotifyEvent = localNotify :: BindableEvent
	LocalNotifyEvent.Event:Connect(function(text: any)
		if type(text) == "string" then
			Components.toast(theme, safeArea, text, "info", 5)
		end
	end)

	local frame = Instance.new("ScrollingFrame")
	frame.Name = "MainFrame"
	frame.Size = UDim2.fromOffset(340, 0)
	frame.Position = UDim2.new(1, -20, 0, 20)
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.BackgroundColor3 = Color3.fromRGB(theme.colors.panel.r, theme.colors.panel.g, theme.colors.panel.b)
	frame.BorderSizePixel = 0
	frame.ScrollBarThickness = 6
	frame.ScrollingDirection = Enum.ScrollingDirection.Y
	frame.CanvasSize = UDim2.new()
	frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	frame.Parent = safeArea

	local frameCorner = Instance.new("UICorner")
	frameCorner.CornerRadius = UDim.new(0, theme.corner)
	frameCorner.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.FillDirection = Enum.FillDirection.Vertical
	-- Creation order is the intended HUD order; without this the default Name sort
	-- would alphabetize the column. Ties (every sibling keeps the default 0) fall
	-- back to child order, so a later sibling renders directly beneath its peers.
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = frame

	local HUD_WIDTH = 340
	local collapsed = false
	local toggleButton = Components.iconButton(theme, {
		name = "HudToggle",
		text = "",
		size = UDim2.fromOffset(44, 44),
		baseColor = { r = 44, g = 46, b = 62 },
		icon = glyphContent("menu"),
		iconSize = 26,
		parent = screenGui,
	})
	toggleButton.AnchorPoint = Vector2.new(1, 0)
	toggleButton.Position = UDim2.new(1, -8, 0, 8)
	toggleButton.ZIndex = 20

	-- Compact phone HUD (viewport height < 500): a bottom-right action bar and
	-- centered modal sheets replace the scroll column. Content instances are moved
	-- into the sheets by setContentMode, so every handler stays wired to its
	-- original button. Hidden while the desktop column is active.
	local phoneBackdrop = Instance.new("TextButton")
	phoneBackdrop.Name = "PhoneBackdrop"
	phoneBackdrop.Size = UDim2.fromScale(1, 1)
	phoneBackdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	phoneBackdrop.BackgroundTransparency = 0.5
	phoneBackdrop.BorderSizePixel = 0
	phoneBackdrop.AutoButtonColor = false
	phoneBackdrop.Text = ""
	phoneBackdrop.Visible = false
	phoneBackdrop.ZIndex = 40
	phoneBackdrop.Parent = safeArea

	-- Phone action bar geometry. Declared before the bar so the list layout can
	-- reference the shared padding; the buttons are BUTTON_SIZE square.
	local JUMP_GAP = 12
	local PHONE_BAR_PAD = 8
	local PHONE_BAR_MARGIN = 8
	local JUMP_BUTTON_RESERVE = 90 -- standard touch jump footprint, kept clear before the button exists
	local BUTTON_SIZE = 52

	local phoneBar = Instance.new("Frame")
	phoneBar.Name = "PhoneActionBar"
	phoneBar.AnchorPoint = Vector2.new(1, 1)
	phoneBar.Position = UDim2.new(1, -8, 1, -8)
	phoneBar.BackgroundTransparency = 1
	phoneBar.AutomaticSize = Enum.AutomaticSize.XY
	phoneBar.Visible = false
	phoneBar.ZIndex = 30
	phoneBar.Parent = safeArea

	-- One horizontal row: four 52px buttons plus 8px padding (232px wide).
	local phoneBarLayout = Instance.new("UIListLayout")
	phoneBarLayout.FillDirection = Enum.FillDirection.Horizontal
	phoneBarLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	phoneBarLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	phoneBarLayout.Padding = UDim.new(0, PHONE_BAR_PAD)
	phoneBarLayout.SortOrder = Enum.SortOrder.LayoutOrder
	phoneBarLayout.Parent = phoneBar

	local function findJumpButton(): GuiObject?
		local touchGui = playerGui:FindFirstChild("TouchGui")
		local control = if touchGui ~= nil then touchGui:FindFirstChild("TouchControlFrame") else nil
		local jump = if control ~= nil then control:FindFirstChild("JumpButton") else nil
		if jump ~= nil and jump:IsA("GuiObject") then
			return jump
		end
		return nil
	end

	-- Roblox's touch jump button sits bottom-right on phones. Place the action
	-- row to its left, bottom-aligned with it, so it never covers the avatar or the
	-- coins pill. Without a jump button, fall back to the bottom-right corner.
	local function positionPhoneBar(bottomInset: number): ()
		local jump = findJumpButton()
		local rightX: number
		local bottomY: number
		if jump ~= nil and jump.Visible then
			-- The touch jump button lives in CoreGui, but its AbsolutePosition is in
			-- the same pixel space as this ScreenGui's children (verified in Studio:
			-- the bar's own AbsolutePosition maps 1:1). Align to the button's bottom
			-- and left edge relative to the SafeArea the bar is parented to.
			local jumpPos = jump.AbsolutePosition - safeArea.AbsolutePosition
			rightX = jumpPos.X - JUMP_GAP
			bottomY = jumpPos.Y + jump.AbsoluteSize.Y
		else
			-- No jump button yet: reserve the standard jump footprint so a button
			-- that appears later never sits under the bar.
			local bounds = safeArea.AbsoluteSize
			rightX = bounds.X - PHONE_BAR_MARGIN - JUMP_BUTTON_RESERVE - JUMP_GAP
			bottomY = bounds.Y - bottomInset - PHONE_BAR_MARGIN
		end

		phoneBar.AnchorPoint = Vector2.new(1, 1)
		phoneBar.Position = UDim2.fromOffset(rightX, bottomY)
	end

	local function makePhoneAction(
		name: string,
		icon: Content?,
		base: { r: number, g: number, b: number },
		order: number
	): TextButton
		local button = Components.iconButton(theme, {
			name = name,
			text = "",
			size = UDim2.fromOffset(BUTTON_SIZE, BUTTON_SIZE),
			baseColor = base,
			icon = icon,
			iconSize = 30,
			corner = UDim.new(1, 0),
			iconOnly = true,
			parent = phoneBar,
		})
		button.LayoutOrder = order
		return button
	end

	local phoneBuyButton =
		makePhoneAction("PhoneBuyButton", eggContent(Config.sourceOrder[1] or ""), { r = 62, g = 138, b = 70 }, 1)
	local phoneRaidButton = makePhoneAction("PhoneRaidButton", glyphContent("raid"), { r = 150, g = 66, b = 72 }, 2)
	local phoneMergeButton = makePhoneAction("PhoneMergeButton", glyphContent("merge"), { r = 104, g = 72, b = 178 }, 3)
	local phoneStoreButton = makePhoneAction("PhoneStoreButton", glyphContent("store"), { r = 120, g = 82, b = 178 }, 4)

	local coinsPill = Instance.new("Frame")
	coinsPill.Name = "CoinsPill"
	coinsPill.AnchorPoint = Vector2.new(1, 0)
	coinsPill.Position = UDim2.new(1, -8, 0, 8)
	coinsPill.Size = UDim2.fromOffset(150, 40)
	coinsPill.BackgroundColor3 = Color3.fromRGB(theme.colors.panel.r, theme.colors.panel.g, theme.colors.panel.b)
	coinsPill.BorderSizePixel = 0
	coinsPill.Visible = false
	coinsPill.ZIndex = 30
	coinsPill.Parent = safeArea

	local pillCorner = Instance.new("UICorner")
	pillCorner.CornerRadius = UDim.new(1, 0)
	pillCorner.Parent = coinsPill

	local pillStroke = Instance.new("UIStroke")
	pillStroke.Color = Color3.fromRGB(theme.colors.muted.r, theme.colors.muted.g, theme.colors.muted.b)
	pillStroke.Thickness = 1
	pillStroke.Parent = coinsPill

	local pillIcon = makeImage(iconContent("coin", Icons.coin(ICON_PX)), 22)
	if pillIcon ~= nil then
		pillIcon.Position = UDim2.new(0, 9, 0.5, 0)
		pillIcon.AnchorPoint = Vector2.new(0, 0.5)
		pillIcon.ZIndex = 31
		pillIcon.Parent = coinsPill
	end

	local pillCoinsLabel = Instance.new("TextLabel")
	pillCoinsLabel.Name = "Coins"
	pillCoinsLabel.Size = UDim2.new(1, -44, 1, 0)
	pillCoinsLabel.Position = UDim2.fromOffset(38, 0)
	pillCoinsLabel.BackgroundTransparency = 1
	pillCoinsLabel.Font = (Enum.Font :: any)[theme.font]
	pillCoinsLabel.TextSize = 17
	pillCoinsLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
	pillCoinsLabel.TextXAlignment = Enum.TextXAlignment.Left
	pillCoinsLabel.Text = Copy.coinsLabel("0")
	pillCoinsLabel.ZIndex = 31
	pillCoinsLabel.Parent = coinsPill

	local buySheet = Components.modalSheet(theme, { name = "BuySheet", title = Copy.buyEggsTitle, parent = screenGui })
	local mergeSheet =
		Components.modalSheet(theme, { name = "MergeSheet", title = Copy.mergeTitle, parent = screenGui })
	local raidSheet =
		Components.modalSheet(theme, { name = "RaidSheet", title = Copy.raidQuestsTitle, parent = screenGui })
	local storeSheet =
		Components.modalSheet(theme, { name = "StoreSheet", title = Copy.storeTitle, parent = screenGui })

	local incubatorHeader = Components.label(theme, {
		text = Copy.incubatorsHeader,
		size = UDim2.new(1, 0, 0, 20),
		textSize = 14,
		color = theme.colors.muted,
		parent = buySheet.scroll,
	})
	incubatorHeader.Name, incubatorHeader.LayoutOrder = "IncubatorsHeader", 99

	local oddsHeader = Components.label(theme, {
		text = Copy.hatchOddsHeader,
		size = UDim2.new(1, 0, 0, 20),
		textSize = 14,
		color = theme.colors.muted,
		parent = buySheet.scroll,
	})
	oddsHeader.Name, oddsHeader.LayoutOrder = "HatchOddsHeader", 199

	local function closePhoneSheets()
		buySheet.frame.Visible = false
		mergeSheet.frame.Visible = false
		raidSheet.frame.Visible = false
		storeSheet.frame.Visible = false
		phoneBackdrop.Visible = false
	end

	local function openPhoneSheet(sheet: Components.ModalSheet)
		local wasOpen = sheet.frame.Visible
		closePhoneSheets()
		if not wasOpen then
			sheet.frame.Visible = true
			phoneBackdrop.Visible = true
		end
	end

	phoneBackdrop.Activated:Connect(closePhoneSheets)
	buySheet.close.Activated:Connect(closePhoneSheets)
	mergeSheet.close.Activated:Connect(closePhoneSheets)
	raidSheet.close.Activated:Connect(closePhoneSheets)
	storeSheet.close.Activated:Connect(closePhoneSheets)

	local tutorialLabel: TextLabel? = nil
	local applyContentMode: ((boolean) -> ())? = nil

	local function applyLayout()
		local viewport = workspace.CurrentCamera.ViewportSize
		local layoutViewport = { x = viewport.X, y = viewport.Y }
		local phone = Layout.isPhone(layoutViewport)
		local small = (viewport.X < 900 or UserInputService.TouchEnabled) and not phone
		-- ScreenInsets = CoreUISafeInsets already insets this ScreenGui's contents, so
		-- the raw GuiInset must not be applied a second time.
		local topInset, bottomInset = 0, 0
		local hint = tutorialLabel

		if phone then
			frame.Visible = false
			toggleButton.Visible = false
			phoneBar.Visible = true
			coinsPill.Visible = true
			positionPhoneBar(bottomInset)
			coinsPill.Position = UDim2.new(1, -8, 0, topInset + 6)
			local sheet = Layout.sheetSize(layoutViewport)
			local sheetSize = UDim2.fromOffset(sheet.x, sheet.y)
			buySheet.frame.Size = sheetSize
			mergeSheet.frame.Size = sheetSize
			raidSheet.frame.Size = sheetSize
			storeSheet.frame.Size = sheetSize
			if hint ~= nil then
				local hintWidth = math.clamp(math.floor(viewport.X * 0.5), 120, math.max(120, viewport.X - 176))
				hint.Size = UDim2.fromOffset(hintWidth, 28)
				hint.Position = UDim2.fromOffset(12, topInset + 8)
				hint.AnchorPoint = Vector2.new(0, 0)
				hint.TextScaled = true
			end
		else
			phoneBar.Visible = false
			coinsPill.Visible = false
			closePhoneSheets()
			toggleButton.Visible = small
			local width = if small then math.min(HUD_WIDTH, math.floor(viewport.X * 0.46)) else HUD_WIDTH
			if small then
				frame.Size = UDim2.fromOffset(width, math.max(120, viewport.Y - 60 - 110))
				frame.Position = UDim2.new(1, -8, 0, 60)
			else
				frame.Size = UDim2.fromOffset(width, math.max(200, viewport.Y - 60))
				frame.Position = UDim2.new(1, -20, 0, 20)
			end
			frame.Visible = not (small and collapsed)
			if hint ~= nil then
				hint.Size = UDim2.fromOffset(if small then math.floor(viewport.X * 0.5) else 520, 30)
				hint.Position = if small then UDim2.fromOffset(12, topInset + 8) else UDim2.new(0.5, 0, 1, -24)
				hint.AnchorPoint = if small then Vector2.new(0, 0) else Vector2.new(0.5, 1)
				hint.TextScaled = small
			end
		end

		if applyContentMode ~= nil then
			applyContentMode(phone)
		end
	end
	toggleButton.Activated:Connect(function()
		collapsed = not collapsed
		applyLayout()
	end)

	local function makeLabel(
		parent: Instance,
		name: string,
		height: number,
		text: string,
		color: Color3,
		size: number
	): TextLabel
		local label = Instance.new("TextLabel")
		label.Name = name
		label.Size = UDim2.new(1, 0, 0, height)
		label.Text = text
		label.TextColor3 = color
		label.TextSize = size
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.BackgroundTransparency = 1
		label.Parent = parent
		return label
	end

	-- Generated 2D icons (pure Pixels/Icons painted through ImageAdapter) are
	-- requested through makeIcon so a nil icon keeps the original text-only layout.
	local function makeIconRow(name: string, height: number, parent: Instance?): Frame
		local row = Instance.new("Frame")
		row.Name = name
		row.Size = UDim2.new(1, 0, 0, height)
		row.BackgroundTransparency = 1
		row.Parent = parent or frame
		local rowLayout = Instance.new("UIListLayout")
		rowLayout.FillDirection = Enum.FillDirection.Horizontal
		rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		rowLayout.Padding = UDim.new(0, 6)
		rowLayout.Parent = row
		return row
	end

	-- Panels must render in creation order (layout order), never alphabetical order by Name.
	local layoutOrder = 0
	local function withOrder(inst: GuiObject): ()
		layoutOrder += 1
		inst.LayoutOrder = layoutOrder
	end

	local coinsLabel = makeLabel(frame, "CoinsLabel", 28, Copy.coinsLabel("0"), Color3.fromRGB(255, 215, 0), 18)
	do
		local coinIcon = makeIcon("coin", Icons.coin(ICON_PX))
		if coinIcon ~= nil then
			local coinsRow = makeIconRow("CoinsLabel", ICON_SIZE)
			coinsLabel.Name = "CoinsText"
			coinsLabel.LayoutOrder = 2
			coinsLabel.Size = UDim2.new(1, -(ICON_SIZE + 6), 1, 0)
			coinsLabel.Parent = coinsRow
			coinIcon.LayoutOrder = 1
			coinIcon.Parent = coinsRow
		end
	end
	local creaturesLabel =
		makeLabel(frame, "KaijuLabel", 22, Copy.creaturesOwnedLabel(0), Color3.fromRGB(255, 255, 255), 14)

	-- Creature inventory: a portrait grid of the distinct owned creatures, sitting
	-- right under the owned counter. It is created immediately after the owned
	-- counter so the column's LayoutOrder ties resolve to child order and keep
	-- them adjacent, and it is parked/restored together with it when the phone
	-- sheets take over the column.
	local creatureInventory = Instance.new("Frame")
	creatureInventory.Name = "KaijuInventory"
	creatureInventory.Size = UDim2.fromScale(1, 0)
	creatureInventory.AutomaticSize = Enum.AutomaticSize.Y
	creatureInventory.BackgroundTransparency = 1
	creatureInventory.Parent = frame

	local creatureGrid = Instance.new("Frame")
	creatureGrid.Name = "Grid"
	creatureGrid.Size = UDim2.fromScale(1, 0)
	creatureGrid.AutomaticSize = Enum.AutomaticSize.Y
	creatureGrid.BackgroundTransparency = 1
	creatureGrid.Visible = false
	creatureGrid.Parent = creatureInventory

	local creatureGridLayout = Instance.new("UIGridLayout")
	creatureGridLayout.CellSize = UDim2.fromOffset(64, 80)
	creatureGridLayout.CellPadding = UDim2.fromOffset(4, 4)
	creatureGridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	creatureGridLayout.Parent = creatureGrid

	local creatureEmptyHint = Instance.new("TextLabel")
	creatureEmptyHint.Name = "EmptyHint"
	creatureEmptyHint.Size = UDim2.new(1, 0, 0, 20)
	creatureEmptyHint.BackgroundTransparency = 1
	creatureEmptyHint.Font = (Enum.Font :: any)[theme.font]
	creatureEmptyHint.TextSize = 13
	creatureEmptyHint.TextColor3 = Color3.fromRGB(180, 180, 180)
	creatureEmptyHint.TextXAlignment = Enum.TextXAlignment.Left
	creatureEmptyHint.Text = Copy.emptyInventoryHint
	creatureEmptyHint.Parent = creatureInventory

	local function creatureRarityRank(id: string): number
		local config = Config.creatures[id]
		if config == nil then
			return 0
		end
		return opts.rarityRank[config.rarity] or 0
	end

	local function creatureDisplayName(id: string): string
		local config = Config.creatures[id]
		return if config ~= nil then config.displayName else id
	end

	local lastCreatureKey: string? = nil

	local function renderCreatureInventory(ids: { string }): ()
		for _, child in creatureGrid:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		local counts: { [string]: number } = {}
		local distinct: { string } = {}
		for _, id in ids do
			if type(id) == "string" then
				local seen = counts[id]
				if seen == nil then
					counts[id] = 1
					table.insert(distinct, id)
				else
					counts[id] = seen + 1
				end
			end
		end

		if #distinct == 0 then
			creatureGrid.Visible = false
			creatureEmptyHint.Visible = true
			return
		end

		creatureGrid.Visible = true
		creatureEmptyHint.Visible = false

		table.sort(distinct, function(a: string, b: string): boolean
			local rankA = creatureRarityRank(a)
			local rankB = creatureRarityRank(b)
			if rankA ~= rankB then
				return rankA < rankB
			end
			local nameA = creatureDisplayName(a)
			local nameB = creatureDisplayName(b)
			if nameA ~= nameB then
				return nameA < nameB
			end
			return a < b
		end)

		for index, id in distinct do
			local cell = Instance.new("Frame")
			cell.Name = "Inv_" .. id
			cell.BackgroundTransparency = 1
			cell.LayoutOrder = index
			cell.Parent = creatureGrid

			local portrait = makeImage(creatureContent(id), 48)
			if portrait ~= nil then
				portrait.Name = "Portrait"
				portrait.AnchorPoint = Vector2.new(0.5, 0)
				portrait.Position = UDim2.fromScale(0.5, 0)
				portrait.ZIndex = 1
				portrait.Parent = cell
			end

			local config = Config.creatures[id]
			local rarity = if config ~= nil then config.rarity else "Common"
			local badge = makeImage(rarityContent(rarity), 16)
			if badge ~= nil then
				badge.Name = "Rarity"
				badge.AnchorPoint = Vector2.new(1, 0)
				badge.Position = UDim2.new(1, -2, 0, 2)
				badge.ZIndex = 2
				badge.Parent = cell
			end

			local count = Instance.new("TextLabel")
			count.Name = "Count"
			count.Size = UDim2.fromOffset(26, 16)
			count.AnchorPoint = Vector2.new(1, 1)
			count.Position = UDim2.new(1, -2, 0, 46)
			count.BackgroundTransparency = 1
			count.Font = (Enum.Font :: any)[theme.font]
			count.TextSize = 12
			count.TextColor3 = Color3.fromRGB(255, 255, 255)
			count.TextXAlignment = Enum.TextXAlignment.Right
			count.TextYAlignment = Enum.TextYAlignment.Bottom
			count.Text = "x" .. tostring(counts[id] or 0)
			count.ZIndex = 2
			count.Parent = cell

			local nameLabel = Instance.new("TextLabel")
			nameLabel.Name = "Name"
			nameLabel.Size = UDim2.new(1, 0, 0, 26)
			nameLabel.AnchorPoint = Vector2.new(0.5, 0)
			nameLabel.Position = UDim2.new(0.5, 0, 0, 50)
			nameLabel.BackgroundTransparency = 1
			nameLabel.Font = (Enum.Font :: any)[theme.font]
			nameLabel.TextScaled = true
			nameLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
			nameLabel.Text = creatureDisplayName(id)
			nameLabel.ZIndex = 1
			nameLabel.Parent = cell

			local sizeConstraint = Instance.new("UITextSizeConstraint")
			sizeConstraint.MaxTextSize = 12
			sizeConstraint.Parent = nameLabel
		end
	end

	-- The grid only changes when the owned multiset changes, so a sorted joined
	-- key gates the (cell-rebuilding) re-render on every StateChanged snapshot.
	local function creatureMultisetKey(ids: { string }): string
		local copy: { string } = {}
		for _, id in ids do
			if type(id) == "string" then
				table.insert(copy, id)
			end
		end
		table.sort(copy)
		return table.concat(copy, ",")
	end

	local siegeLabel =
		makeLabel(frame, "SiegeLabel", 26, Copy.nextSiegeLabel("--:--"), Color3.fromRGB(255, 170, 80), 16)
	local vaultLabel =
		makeLabel(frame, "VaultLabel", 22, Copy.vaultCountsLabel(opts.teamNames, {}), Color3.fromRGB(160, 200, 255), 14)
	local vaultedLabel = makeLabel(frame, "VaultedLabel", 22, Copy.vaultedLabel(0), Color3.fromRGB(200, 180, 255), 14)

	local raidButton = Components.iconButton(theme, {
		-- QA click targets address this Instance by exact Name (see qa-scenarios/*.yml).
		name = "raid-target",
		text = Copy.raidButtonText,
		size = UDim2.new(1, 0, 0, 44),
		baseColor = { r = 150, g = 66, b = 72 },
		icon = glyphContent("raid"),
		iconSize = 24,
		parent = frame,
	})
	raidButton.Active = false

	local raidActive = false
	raidButton.Activated:Connect(function()
		if not raidActive then
			return
		end
		local okRaid, result = Raid:InvokeServer()
		if not okRaid then
			local reason = if type(result) == "string" and result ~= "" then result else "unavailable"
			LocalNotifyEvent:Fire(Copy.raidResultText(reason))
		elseif result == 0 then
			LocalNotifyEvent:Fire(Copy.raidResultText(Copy.raidNothingReason))
		else
			Fx.play("raid")
			Fx.flash(screenGui, Color3.fromRGB(255, 60, 60))
		end
	end)

	local mergeButtons: { TextButton } = {}

	for index, family in Config.mergeFamilies do
		local mergeButton = Components.iconButton(theme, {
			name = "Merge_" .. family.id,
			text = Copy.mergeButtonText(family.displayName),
			size = UDim2.new(1, 0, 0, 44),
			baseColor = { r = 104, g = 72, b = 178 },
			icon = glyphContent("merge"),
			iconSize = 24,
			parent = frame,
		})
		mergeButtons[index] = mergeButton
		mergeButton.Activated:Connect(function()
			MergeRemote:InvokeServer(index)
		end)
	end

	local buyButtons: { [string]: TextButton } = {}

	for sourceIndex, sourceId in Config.sourceOrder do
		local sourceConfig = Config.sources[sourceId]
		if sourceConfig then
			local btn = Components.iconButton(theme, {
				-- QA scenarios target the first egg's buy button by this stable Name;
				-- every later source keeps its own Buy_<id> Name since scenarios never
				-- need to click those directly.
				name = if sourceIndex == 1 then "buy-egg-button" else "Buy_" .. sourceId,
				text = Copy.buyButtonText(sourceConfig.id, sourceConfig.price),
				size = UDim2.new(1, 0, 0, 44),
				baseColor = { r = 62, g = 138, b = 70 },
				icon = eggContent(sourceId),
				iconSize = 24,
				parent = frame,
			})
			buyButtons[sourceId] = btn

			btn.Activated:Connect(function()
				local okBuy = BuyEgg:InvokeServer(sourceId)
				Fx.play(if okBuy then "coin" else "error", 0.4)
			end)
		end
	end

	local storeButton = Components.iconButton(theme, {
		name = "StoreButton",
		text = Copy.storeTitle,
		size = UDim2.new(1, 0, 0, 44),
		baseColor = { r = 120, g = 82, b = 178 },
		icon = glyphContent("store"),
		iconSize = 24,
		parent = frame,
	})

	local oddsButton = Components.iconButton(theme, {
		name = "OddsButton",
		text = Copy.hatchOddsHeader,
		size = UDim2.new(1, 0, 0, 44),
		baseColor = { r = 62, g = 108, b = 150 },
		icon = glyphContent("odds"),
		iconSize = 24,
		parent = frame,
	})

	local inviteButton = Components.iconButton(theme, {
		name = "InviteButton",
		text = Copy.inviteButtonText,
		size = UDim2.new(1, 0, 0, 44),
		baseColor = { r = 120, g = 82, b = 178 },
		icon = glyphContent("invite"),
		iconSize = 24,
		parent = frame,
	})

	inviteButton.Activated:Connect(function()
		local SocialService = game:GetService("SocialService")
		local okCan, canInvite = pcall(function()
			return SocialService:CanSendGameInviteAsync(player)
		end)
		if okCan and canInvite then
			pcall(function()
				SocialService:PromptGameInvite(player)
			end)
		else
			Components.toast(theme, screenGui, Copy.invitesUnavailableText, "info", 3)
		end
	end)

	local questHeader = makeLabel(frame, "QuestHeader", 22, Copy.dailyQuestsHeader, Color3.fromRGB(255, 255, 255), 15)

	local questFrame = Instance.new("Frame")
	questFrame.Name = "Quests"
	questFrame.Size = UDim2.new(1, 0, 0, 108)
	questFrame.BackgroundTransparency = 1
	questFrame.Parent = frame

	local questLayout = Instance.new("UIListLayout")
	questLayout.Padding = UDim.new(0, 4)
	questLayout.Parent = questFrame

	local incubatorFrame = Instance.new("Frame")
	incubatorFrame.Name = "Incubators"
	incubatorFrame.Size = UDim2.fromScale(1, 0)
	incubatorFrame.AutomaticSize = Enum.AutomaticSize.Y
	incubatorFrame.BackgroundTransparency = 1
	incubatorFrame.Parent = frame

	local incLayout = Instance.new("UIListLayout")
	incLayout.Padding = UDim.new(0, 4)
	incLayout.Parent = incubatorFrame

	-- Store and odds panels sit top-right, left of the main panel, clear of the chat.
	local function makePanel(name: string, width: number, rightOffset: number, header: string): Frame
		local panel = Components.panel(theme, {
			name = name,
			size = UDim2.fromOffset(width, 0),
			position = UDim2.new(1, -rightOffset, 0, 20),
			header = header,
		})
		panel.AnchorPoint = Vector2.new(1, 0)
		panel.AutomaticSize = Enum.AutomaticSize.Y
		panel.Visible = false

		local panelLayout = Instance.new("UIListLayout")
		panelLayout.Padding = UDim.new(0, 6)
		panelLayout.SortOrder = Enum.SortOrder.LayoutOrder
		panelLayout.Parent = panel

		panel.Parent = safeArea
		return panel
	end

	local storePanel = makePanel("StorePanel", 260, 380, Copy.storeTitle)

	-- Status label: only shows the unpublished notice after an id == 0 item is clicked.
	local storeStatus: TextLabel

	local function makeStoreButton(entry: CatalogEntry, isPass: boolean): ()
		local iconKind = opts.storeIcons[entry.key]
		local button = Components.iconButton(theme, {
			name = "Store_" .. entry.key,
			text = Copy.storeButtonText(entry.name, entry.price),
			size = UDim2.new(1, 0, 0, 44),
			baseColor = if entry.id > 0 then { r = 62, g = 138, b = 70 } else { r = 80, g = 80, b = 92 },
			icon = if iconKind ~= nil then glyphContent(iconKind) else nil,
			iconSize = 24,
			parent = storePanel,
		})
		button.Activated:Connect(function()
			if entry.id > 0 then
				if isPass then
					MarketplaceService:PromptGamePassPurchase(player, entry.id)
				else
					MarketplaceService:PromptProductPurchase(player, entry.id)
				end
			else
				storeStatus.Text = Copy.storeUnpublishedText
				storeStatus.Visible = true
			end
		end)
		withOrder(button)
	end

	withOrder(makeLabel(storePanel, "PassesHeader", 20, Copy.gamePassesHeader, Color3.fromRGB(200, 200, 255), 14))
	for _, entry in Catalog.gamepasses do
		makeStoreButton(entry, true)
	end

	withOrder(makeLabel(storePanel, "ProductsHeader", 20, Copy.devProductsHeader, Color3.fromRGB(200, 200, 255), 14))
	for _, entry in Catalog.products do
		makeStoreButton(entry, false)
	end

	storeStatus = makeLabel(storePanel, "StoreStatus", 20, "", Color3.fromRGB(255, 140, 140), 13)
	storeStatus.Visible = true
	withOrder(storeStatus)

	local oddsPanel = makePanel("OddsPanel", 240, 650, Copy.hatchOddsHeader)

	local oddsList = Instance.new("Frame")
	oddsList.Name = "OddsList"
	oddsList.Size = UDim2.fromScale(1, 0)
	oddsList.AutomaticSize = Enum.AutomaticSize.Y
	oddsList.BackgroundTransparency = 1
	oddsList.Parent = oddsPanel
	withOrder(oddsList)

	local oddsListLayout = Instance.new("UIListLayout")
	oddsListLayout.Padding = UDim.new(0, 4)
	oddsListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	oddsListLayout.Parent = oddsList

	local lastSnapshot: any = nil

	-- Buy buttons reflect the server's scaled price; fall back to the base price.
	local function renderSourcePrices(snapshot: any): ()
		local sourcePrices = snapshot.sourcePrices or {}
		for _, sourceId in Config.sourceOrder do
			local btn: TextButton? = buyButtons[sourceId]
			local sourceConfig = Config.sources[sourceId]
			if btn ~= nil and sourceConfig ~= nil then
				local price = sourcePrices[sourceId]
				btn.Text =
					Copy.buyButtonText(sourceConfig.id, if type(price) == "number" then price else sourceConfig.price)
			end
		end
	end

	local function renderOdds(snapshot: any): ()
		for _, child in oddsList:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		local odds = snapshot.odds or {}
		for _, sourceId in Config.sourceOrder do
			local sourceConfig = Config.sources[sourceId]
			if sourceConfig ~= nil then
				withOrder(
					makeLabel(
						oddsList,
						"OddsEgg_" .. sourceId,
						20,
						sourceConfig.displayName,
						Color3.fromRGB(255, 255, 255),
						14
					)
				)
				local sourceOdds = odds[sourceId] or {}
				for _, poolEntry in sourceConfig.pool do
					local creatureConfig = Config.creatures[poolEntry.id]
					local creatureName = if creatureConfig ~= nil then creatureConfig.displayName else poolEntry.id
					local rarity = if creatureConfig ~= nil then creatureConfig.rarity else "Common"
					local chance = (sourceOdds[poolEntry.id] or 0) * 100
					local row = makeIconRow("Odds_" .. sourceId .. "_" .. poolEntry.id, 20, oddsList)
					local badge = makeImage(rarityContent(rarity), 16)
					if badge ~= nil then
						badge.Parent = row
					end
					local portrait = makeImage(creatureContent(poolEntry.id), 18)
					if portrait ~= nil then
						portrait.Parent = row
					end
					local text = makeLabel(
						row,
						"OddsText",
						18,
						string.format("%s %.1f%%", creatureName, chance),
						Color3.fromRGB(200, 200, 200),
						13
					)
					text.Size = UDim2.new(1, -46, 1, 0)
					withOrder(row)
				end
			end
		end
	end

	storeButton.Activated:Connect(function()
		storePanel.Visible = not storePanel.Visible
		if storePanel.Visible then
			StoreOpen:FireServer()
		end
	end)

	oddsButton.Activated:Connect(function()
		oddsPanel.Visible = not oddsPanel.Visible
		if oddsPanel.Visible and lastSnapshot ~= nil then
			renderOdds(lastSnapshot)
		end
	end)

	-- Bottom-center tutorial hint, clear of the top-right panels and top-left chat.
	tutorialLabel = Instance.new("TextLabel")
	local hintLabel = tutorialLabel :: TextLabel
	-- QA click targets this Instance by exact Name (see qa-scenarios/*.yml).
	hintLabel.Name = "tutorial-prompt"
	hintLabel.Size = UDim2.fromOffset(520, 30)
	hintLabel.Position = UDim2.new(0.5, 0, 1, -24)
	hintLabel.AnchorPoint = Vector2.new(0.5, 1)
	hintLabel.BackgroundColor3 = Color3.fromRGB(50, 45, 70)
	hintLabel.BackgroundTransparency = 0.2
	hintLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	hintLabel.TextSize = 15
	hintLabel.Visible = false
	hintLabel.Parent = safeArea
	-- The hint scales to its own bar, so it must be capped: with no constraint the
	-- glyphs grow to the 30px bar height and fill it. Every HUD module that scales
	-- text is held to this by the shared text-scale gate (core/ui-kit/genre/HudScale).
	local hintFit = Instance.new("UITextSizeConstraint")
	hintFit.Name, hintFit.MinTextSize, hintFit.MaxTextSize = "ForgeTextFit", 10, 15
	hintFit.Parent = hintLabel

	-- Move the existing content into (or out of) the phone sheets so the same
	-- button instances keep their handlers and live state in both layouts.
	local desktopHome: { [GuiObject]: { parent: Instance, order: number } } = {}
	local contentMode: boolean? = nil

	local function park(item: GuiObject, target: Instance, order: number)
		if desktopHome[item] == nil then
			local home: Instance? = item.Parent
			if home ~= nil then
				desktopHome[item] = { parent = home, order = item.LayoutOrder }
			end
		end
		item.LayoutOrder = order
		item.Parent = target
	end

	local function restore(item: GuiObject)
		local home = desktopHome[item]
		if home ~= nil and item.Parent ~= nil then
			item.Parent = home.parent
			item.LayoutOrder = home.order
		end
	end

	local function setContentMode(phone: boolean)
		if contentMode == phone then
			return
		end
		contentMode = phone

		if phone then
			storePanel.Visible = false
			oddsPanel.Visible = false
			closePhoneSheets()
			park(creaturesLabel, buySheet.scroll, 1)
			park(creatureInventory, buySheet.scroll, 2)
			park(vaultedLabel, buySheet.scroll, 3)
			for index, sourceId in Config.sourceOrder do
				local button: TextButton? = buyButtons[sourceId]
				if button ~= nil then
					park(button, buySheet.scroll, 10 + index)
				end
			end
			park(incubatorFrame, buySheet.scroll, 100)
			park(oddsList, buySheet.scroll, 200)
			for index, button in mergeButtons do
				park(button, mergeSheet.scroll, index)
			end
			park(siegeLabel, raidSheet.scroll, 1)
			park(vaultLabel, raidSheet.scroll, 2)
			park(raidButton, raidSheet.scroll, 3)
			park(questHeader, raidSheet.scroll, 10)
			park(questFrame, raidSheet.scroll, 11)
			local storeOrder = 0
			for _, child in storePanel:GetChildren() do
				if child:IsA("GuiObject") then
					local gui = child :: GuiObject
					if gui.LayoutOrder ~= -1 then
						storeOrder += 1
						park(gui, storeSheet.scroll, storeOrder)
					end
				end
			end
			park(inviteButton, storeSheet.scroll, storeOrder + 10)
		else
			for item in desktopHome do
				restore(item)
			end
		end
	end
	applyContentMode = setContentMode

	phoneBuyButton.Activated:Connect(function()
		local opening = not buySheet.frame.Visible
		openPhoneSheet(buySheet)
		if opening and lastSnapshot ~= nil then
			renderOdds(lastSnapshot)
		end
	end)

	phoneRaidButton.Activated:Connect(function()
		openPhoneSheet(raidSheet)
	end)

	phoneMergeButton.Activated:Connect(function()
		openPhoneSheet(mergeSheet)
	end)

	phoneStoreButton.Activated:Connect(function()
		local opening = not storeSheet.frame.Visible
		openPhoneSheet(storeSheet)
		if opening then
			StoreOpen:FireServer()
		end
	end)

	local touchAssertQueued = false
	local function scheduleTouchAssert()
		if touchAssertQueued then
			return
		end
		touchAssertQueued = true
		RunService.RenderStepped:Once(function()
			touchAssertQueued = false
			Components.assertTouchTargets(screenGui)
		end)
	end

	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyLayout)
	applyLayout()

	-- Roblox creates the touch jump button after this script runs, so re-layout the
	-- phone bar whenever it appears and whenever its geometry/visibility changes.
	local observedJumpButtons: { [GuiObject]: true } = {}
	local function observeJumpButton(jump: GuiObject): ()
		if observedJumpButtons[jump] then
			return
		end
		observedJumpButtons[jump] = true
		jump:GetPropertyChangedSignal("AbsolutePosition"):Connect(applyLayout)
		jump:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout)
		jump:GetPropertyChangedSignal("Visible"):Connect(applyLayout)
	end

	playerGui.DescendantAdded:Connect(function(child: Instance)
		if child.Name == "JumpButton" and child:IsA("GuiObject") then
			observeJumpButton(child)
			applyLayout()
		end
	end)

	task.delay(1, function()
		local jump = findJumpButton()
		if jump ~= nil then
			observeJumpButton(jump)
		end
		applyLayout()
	end)

	scheduleTouchAssert()

	TutorialState.OnClientEvent:Connect(function(info: any)
		if type(info) ~= "table" then
			return
		end
		local hint = info.hint
		if type(hint) == "string" and hint ~= "" then
			hintLabel.Text = Copy.tutorialPrefix .. hint
			hintLabel.Visible = true
		else
			hintLabel.Text = ""
			hintLabel.Visible = false
		end
	end)

	-- Toast: transient overlay for Notify events (ui-kit).
	Notify.OnClientEvent:Connect(function(text: any)
		if type(text) ~= "string" then
			return
		end
		Components.toast(theme, screenGui, text, "info", 5)
		if Copy.isRareHatchNotify(text) then
			Fx.play("rare", 0.6)
		end
	end)

	local function formatClock(seconds: number): string
		local total = math.max(0, math.floor(seconds))
		return string.format("%d:%02d", math.floor(total / 60), total % 60)
	end

	SiegeState.OnClientEvent:Connect(function(info: any)
		if type(info) ~= "table" then
			return
		end

		raidActive = info.phase == "active"
		if raidActive then
			siegeLabel.Text = Copy.siegeActiveLabel(formatClock(info.secondsLeft or 0))
			siegeLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
			raidButton.Active = true
			Components.setIconButtonColor(raidButton, { r = 200, g = 66, b = 66 })
		else
			siegeLabel.Text = Copy.nextSiegeLabel(formatClock(info.secondsLeft or 0))
			siegeLabel.TextColor3 = Color3.fromRGB(255, 170, 80)
			raidButton.Active = false
			Components.setIconButtonColor(raidButton, { r = 150, g = 66, b = 72 })
		end

		local counts = info.vaultCounts or {}
		vaultLabel.Text = Copy.vaultCountsLabel(opts.teamNames, counts)
	end)

	local function renderQuests(quests: any): ()
		for _, child in questFrame:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		for _, quest in quests do
			local progress = quest.progress or 0
			local target = quest.target or 0
			local complete = progress >= target

			local row = Instance.new("Frame")
			row.Name = "Quest_" .. tostring(quest.id)
			row.Size = UDim2.new(1, 0, 0, 44)
			row.BackgroundTransparency = 1
			row.Parent = questFrame

			local label = Instance.new("TextLabel")
			label.Size = UDim2.new(1, -96, 1, 0)
			label.Text = Copy.questRowText(tostring(quest.id), progress, target, quest.reward or 0)
			label.TextColor3 = if quest.claimed then Color3.fromRGB(140, 140, 140) else Color3.fromRGB(230, 230, 230)
			label.TextSize = 13
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.BackgroundTransparency = 1
			label.Parent = row

			local base = if complete and not quest.claimed
				then { r = 62, g = 150, b = 80 }
				else { r = 70, g = 70, b = 82 }
			if quest.claimed then
				base = { r = 70, g = 70, b = 70 }
			end
			local claim = Components.iconButton(theme, {
				name = "Claim",
				text = if quest.claimed then Copy.claimedButtonText else Copy.claimButtonText,
				size = UDim2.new(0, 92, 1, 0),
				position = UDim2.new(1, -92, 0, 0),
				baseColor = base,
				icon = glyphContent("quest"),
				iconSize = 20,
				parent = row,
			})
			claim.Active = complete and not quest.claimed
			claim.Activated:Connect(function()
				if complete and not quest.claimed then
					ClaimQuest:InvokeServer(quest.id)
				end
			end)
		end
	end

	StateChanged.OnClientEvent:Connect(function(snapshot: any)
		if type(snapshot) ~= "table" then
			return
		end

		local coins = Layout.formatNumber(snapshot.coins or 0)
		coinsLabel.Text = Copy.coinsLabel(coins)
		pillCoinsLabel.Text = Copy.coinsLabel(coins)
		local creatureIds = snapshot.creatures or {}
		creaturesLabel.Text = Copy.creaturesOwnedLabel(#creatureIds)
		local creatureKey = creatureMultisetKey(creatureIds)
		if creatureKey ~= lastCreatureKey then
			lastCreatureKey = creatureKey
			renderCreatureInventory(creatureIds)
		end
		vaultedLabel.Text = Copy.vaultedLabel(snapshot.vaulted or 0)
		lastSnapshot = snapshot
		renderSourcePrices(snapshot)
		if oddsPanel.Visible or buySheet.frame.Visible then
			renderOdds(snapshot)
		end
		renderQuests(snapshot.quests or {})

		for _, child in incubatorFrame:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		local incubators = snapshot.incubators or {}
		for i, inc in incubators do
			local remaining = math.ceil(inc.remaining or 0)
			if remaining <= 0 then
				local hatchBtn = Components.iconButton(theme, {
					name = "Hatch_" .. tostring(i),
					text = Copy.hatchButtonText(i),
					size = UDim2.new(1, 0, 0, 44),
					baseColor = { r = 200, g = 140, b = 40 },
					icon = eggContent(inc.sourceId or ""),
					iconSize = 24,
					parent = incubatorFrame,
				})

				hatchBtn.Activated:Connect(function()
					local okHatch, result = HatchEgg:InvokeServer(i)
					if okHatch then
						Fx.play("hatch")
						local character = player.Character
						local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
						if root then
							Fx.burst(root.Position + Vector3.new(0, 3, 0), Color3.fromRGB(255, 200, 80), 60)
						end
						Fx.popText(screenGui, Copy.hatchedPopText(tostring(result)), Color3.fromRGB(255, 220, 120))
					else
						Fx.play("error", 0.3)
					end
				end)
			else
				local status = Instance.new("TextLabel")
				status.Size = UDim2.new(1, 0, 0, 24)
				status.Text = Copy.slotStatusText(i, inc.sourceId or "", Layout.formatDuration(remaining))
				status.TextColor3 = Color3.fromRGB(180, 180, 180)
				status.BackgroundTransparency = 1
				status.Parent = incubatorFrame
			end
		end
		scheduleTouchAssert()
	end)
end

return Hud
