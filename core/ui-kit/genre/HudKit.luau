--!strict
-- HudKit: the genre-agnostic HUD the declarative spec renders.
--
-- Three guarantees are structural, not conventions:
--
--   * Safe area by construction. The ScreenGui is created with
--     ScreenInsets = CoreUISafeInsets and one `SafeArea` frame carries every
--     element. There is no code path here that parents an element to the raw
--     ScreenGui.
--   * Stable instance identities. One control registry keyed by
--     `scope .. ":" .. id` creates each control once, then only mutates Text,
--     LayoutOrder, Active, Interactable and BackgroundTransparency. A control
--     that leaves the current section is hidden, never destroyed: QA and Studio
--     click targets address instances by exact stable Name, so identity
--     stability is a QA contract rather than a nicety.
--   * Player-facing text only. Every visible string comes from the spec's
--     declared display data through `HudText`, never from an id or a locale
--     key, and the string the HUD renders is the exact string the sweep's hud
--     check validates offline.
--
-- Reserved regions: the Roblox chat window owns the top-left corner on every
-- surface, and the touch jump button owns the bottom-right on phones. Nothing
-- this kit creates is anchored into either region: the resource row is
-- right-aligned at the top (clear of the chat), the objective sits under it,
-- the action row is bottom-centre on desktop (above the backpack hotbar) and
-- bottom-right on phones (above the jump button), and the inventory grid is
-- bottom-left. `M.CHAT_RESERVE` documents the desktop chat footprint the
-- layout keeps clear; the Studio driver measures the live chat frame and fails
-- a capture whose owned UI overlaps it. On a phone the top-right strip carries
-- only resource pills (narrower, and wrapping) so it keeps a wide margin from the
-- chat, and the sheet toggle rides the action row instead of a corner of its own.
--
-- The kit computes no game rule. It reads the spec's declared resources,
-- actions, loop and slots, subscribes to the state the server already pushes,
-- and dispatches the actions the spec names.

local Players = game:GetService("Players")

local Components = require("../Components")
local HudLoop = require("./HudLoop")
local HudText = require("./HudText")
local HudFit = require("./HudFit")
local Layout = require("../Layout")
local Theme = require("../Theme")

local M = {}

-- Phone geometry: the standard touch jump footprint is kept clear before the
-- button exists, so the action bar never covers the avatar. The numbers live in
-- HudFit, which `forge sweep` also measures the action labels against, so the
-- runtime layout and the gate can never disagree about the room a control has.
M.JUMP_GAP = HudFit.JUMP_GAP
M.PHONE_BAR_MARGIN = HudFit.BAR_MARGIN
M.JUMP_BUTTON_RESERVE = HudFit.JUMP_RESERVE
M.BUTTON_SIZE = 52
-- The top-left footprint the Roblox chat window occupies, kept clear by
-- construction: it is the reservation the layout is built around, and the Studio
-- driver measures the live chat frame itself rather than trusting this number.
M.CHAT_RESERVE = { width = 360, height = 240 }
-- Desktop: the backpack hotbar owns the bottom-centre strip, so the action row
-- is lifted above it rather than laid on top of it.
M.HOTBAR_RESERVE = 116
M.RESOURCE_HEIGHT = 44
-- One resource pill's width. On a phone the strip is narrower so the top-right row
-- keeps a wide margin from the chat window that owns the top-left corner.
M.RESOURCE_WIDTH = 150
M.RESOURCE_WIDTH_PHONE = 128
M.OBJECTIVE_HEIGHT = 28
M.OBJECTIVE_WIDTH = 320
-- Transient notices (a refused action, an unselected roster row) sit directly
-- under the reserved chat region: the one horizontal band that is clear of the
-- chat above it, of the resource strip and objective to its right, and of the
-- action row below it, on both surfaces.
M.NOTIFICATION_WIDTH = 320
-- One action-bar row: the natural control size, the gap the UIListLayout uses,
-- and the width a control may shrink to before it stops being a touch target.
-- All three come from HudFit, which the sweep's fit gate measures with.
M.ACTION_WIDTH = HudFit.NATURAL_WIDTH
M.ACTION_HEIGHT = HudFit.ACTION_HEIGHT
M.ACTION_GAP = HudFit.GAP
M.ACTION_MIN_WIDTH = HudFit.MIN_WIDTH

export type Options = {
	spec: any,
	controls: { any },
	subscribe: (packet: any) -> (),
	dispatch: (action: string, args: { any }) -> any,
	locale: string?,
	-- The pack's locale table: `strings[<key>][<code>]`. Every rendered string is
	-- resolved through it, so a pack shows one language rather than the spec's
	-- source text beside a genre-owned HUD's translations.
	strings: { [string]: { [string]: string } }?,
	assets: { [string]: string }?,
	guiName: string?,
	theme: any?,
}

--- Reads a dotted snapshot field path (`inventory.carrot`, `plots.1.readyAt`).
local function field(source: any, path: string?): any
	if path == nil then
		return nil
	end
	local current = source
	for segment in string.gmatch(path, "[^%.]+") do
		if type(current) ~= "table" then
			return nil
		end
		local index = tonumber(segment)
		current = if index ~= nil then current[index] else current[segment]
	end
	return current
end

local function label(
	theme: any,
	parent: Instance,
	text: string,
	size: UDim2,
	position: UDim2?,
	chip: boolean?
): TextLabel
	local item = Components.label(theme, {
		text = text,
		size = size,
		position = position,
		parent = parent,
		textSize = 15,
		chip = chip,
	})
	item.TextXAlignment = Enum.TextXAlignment.Left
	return item
end

--- Starts the HUD. Returns the ScreenGui it created and owns.
function M.start(options: Options): ScreenGui
	local spec: any = options.spec or {}
	local theme = options.theme or Theme.default
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = options.guiName or "ForgeHud", false, 15
	gui.ScreenInsets, gui.ZIndexBehavior = Enum.ScreenInsets.CoreUISafeInsets, Enum.ZIndexBehavior.Sibling

	-- Every element is parented here; nothing is parented to `gui` directly.
	local safeArea = Instance.new("Frame")
	safeArea.Name, safeArea.BackgroundTransparency = "SafeArea", 1
	safeArea.Position, safeArea.Size, safeArea.Parent = UDim2.fromOffset(12, 8), UDim2.new(1, -24, 1, -16), gui

	local resourceBar = Instance.new("Frame")
	resourceBar.Name, resourceBar.BackgroundTransparency = "ResourceBar", 1
	resourceBar.Position, resourceBar.Size, resourceBar.Parent =
		UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 44), safeArea
	local resourceLayout = Instance.new("UIListLayout")
	resourceLayout.FillDirection, resourceLayout.Padding = Enum.FillDirection.Horizontal, UDim.new(0, 8)
	resourceLayout.SortOrder, resourceLayout.Parent = Enum.SortOrder.LayoutOrder, resourceBar

	local actionBar = Instance.new("Frame")
	actionBar.Name, actionBar.BackgroundTransparency = "ActionBar", 1
	actionBar.Position, actionBar.Size, actionBar.Parent = UDim2.fromOffset(0, 52), UDim2.new(1, 0, 0, 48), safeArea
	local actionLayout = Instance.new("UIListLayout")
	actionLayout.FillDirection, actionLayout.Padding = Enum.FillDirection.Horizontal, UDim.new(0, M.ACTION_GAP)
	actionLayout.SortOrder, actionLayout.Parent = Enum.SortOrder.LayoutOrder, actionBar

	local grid = Instance.new("Frame")
	grid.Name, grid.BackgroundTransparency = "InventoryGrid", 1
	grid.Position, grid.Size, grid.Parent = UDim2.fromOffset(0, 108), UDim2.new(1, 0, 0, 96), safeArea
	local gridLayout = Instance.new("UIListLayout")
	gridLayout.FillDirection, gridLayout.Padding = Enum.FillDirection.Horizontal, UDim.new(0, 6)
	gridLayout.SortOrder, gridLayout.Parent = Enum.SortOrder.LayoutOrder, grid

	local objective = Instance.new("Frame")
	objective.Name, objective.BackgroundTransparency = "Objective", 1
	objective.Position, objective.Size, objective.Parent = UDim2.fromOffset(0, 212), UDim2.new(1, 0, 0, 44), safeArea
	local objectiveLabel = label(theme, objective, "", UDim2.fromScale(1, 1), nil, true)
	objectiveLabel.Name = "ObjectiveText"
	-- The objective is the one HUD line drawn straight over the world, so it carries
	-- its own opaque chip: a near-white string on a bright backdrop was invisible.
	objectiveLabel.TextXAlignment = Enum.TextXAlignment.Right

	local notifications = Instance.new("Frame")
	notifications.Name, notifications.BackgroundTransparency = "Notifications", 1
	-- Centred horizontally and starting under the reserved chat region, so a notice
	-- is inside the safe area and clear of the chat, the resource strip and the
	-- action row on both surfaces.
	notifications.Position, notifications.Size, notifications.Parent =
		UDim2.new(0.5, 0, 0, M.CHAT_RESERVE.height + 8), UDim2.fromOffset(M.NOTIFICATION_WIDTH, 200), safeArea
	notifications.AnchorPoint = Vector2.new(0.5, 0)

	-- ---- state ------------------------------------------------------------
	local snapshot: any = nil
	local roster: { { id: string, name: string } } = {}
	local selected: string? = nil
	local stageIndex = 1
	local connected = false

	local resources: { any } = spec.resources or {}
	local stages: { any } = spec.loop or {}
	-- The action each declared control drives, so a committed world prompt - which
	-- names the control it came from, not the action - can advance the same chain a
	-- HUD control advances.
	local controlActions = HudLoop.controlActions(spec)
	local controls: { any } = options.controls or {}
	local declared: { any } = {}
	for _, control in controls do
		table.insert(declared, control)
	end
	local gridSpec: any = (spec.ui or {}).inventoryGrid

	-- ---- locale -----------------------------------------------------------
	-- Every string this HUD renders comes from the pack's locale table at the
	-- pack's own default locale (game.yml `locale.default`), never from the
	-- player's system locale: one capture shows one language, and a pack's
	-- translations stay consistent with the spec they were generated from.
	local strings = if type(options.strings) == "table" then options.strings else {}
	local locale = options.locale
	local function localized(key: any, fallback: any): string
		return HudText.localized(strings, locale, key, if type(fallback) == "string" then fallback else "")
	end
	-- The locale key of every declared control, so a rendered button label resolves
	-- through the table even though the runtime control list carries display text.
	local controlKeys: { [string]: string } = {}
	for _, row in (if type(spec) == "table" and type(spec.actions) == "table" then spec.actions else {}) do
		if type(row) == "table" and type(row.control) == "table" and type(row.control.labelKey) == "string" then
			controlKeys[tostring(row.control.id)] = row.control.labelKey
		end
	end

	-- ---- control registry -------------------------------------------------
	local registry: { [string]: any } = {}
	local present: { [string]: boolean } = {}

	local function control(key: string, create: () -> Instance): any
		local entry = registry[key]
		if entry == nil then
			entry = { item = create() }
			registry[key] = entry
		end
		present[key] = true
		return entry
	end

	local function ensureResource(resource: any): TextLabel
		local entry = control("resource:" .. tostring(resource.id), function()
			local item = Components.panel(theme, {
				name = "Resource-" .. tostring(resource.id),
				size = UDim2.fromOffset(M.RESOURCE_WIDTH, M.RESOURCE_HEIGHT),
				parent = resourceBar,
			})
			local asset = if type(resource.assetKey) == "string" and type(options.assets) == "table"
				then options.assets[resource.assetKey]
				else nil
			local textLeft = 12
			if type(asset) == "string" and string.sub(asset, 1, 8) == "rbxasset" then
				local icon = Instance.new("ImageLabel")
				icon.Name, icon.BackgroundTransparency = "Icon", 1
				icon.Size, icon.Position = UDim2.fromOffset(26, 26), UDim2.fromOffset(10, 9)
				icon.Image = asset
				icon.Parent = item
				textLeft = 44
			end
			local text = label(theme, item, "", UDim2.new(1, -textLeft - 10, 1, 0), UDim2.fromOffset(textLeft, 0))
			text.Name = "Value"
			return item
		end)
		entry.item.Name = "Resource-" .. tostring(resource.id)
		entry.item.LayoutOrder = if type(resource.hud) == "table" and type(resource.hud.order) == "number"
			then resource.hud.order
			else 1
		return (entry.item :: any):FindFirstChild("Value") :: TextLabel
	end

	--- Advances the objective chip one stage at a time. A loop that repeats an
	--- action (plant, harvest, plant, harvest) has several stages naming the same
	--- action, so "the last stage that names it" would jump the chip to the end of
	--- the chain on the first press. The chip instead moves to the next stage whose
	--- action this one is, and only an out-of-order completion jumps forward.
	---
	--- The rule itself lives in HudLoop, which is engine-free and tested on its own;
	--- this is only the HUD's call into it.
	local function advanceLoop(action: string): ()
		stageIndex = HudLoop.advance(stages, stageIndex, action)
	end

	local function activate(action: string, args: { any }): ()
		local result = options.dispatch(action, args)
		if type(result) == "table" and result.ok == false then
			Components.toast(theme, notifications, tostring(result.reason), "bad", 2)
		end
		if type(result) == "table" and result.ok == true then
			advanceLoop(action)
		end
	end

	local function ensureAction(declaredControl: any): Instance
		local key = "action:" .. tostring(declaredControl.id)
		-- The spec declares a display label for every control; the id is never a
		-- fallback, because a control with no declared text would then show one.
		local display = if type(declaredControl.label) == "string" and #declaredControl.label > 0
			then declaredControl.label
			else "Action"
		display = localized(controlKeys[tostring(declaredControl.id)], display)
		local entry = control(key, function()
			local item = Components.button(theme, {
				text = HudText.assertVisible(display),
				size = UDim2.fromOffset(M.ACTION_WIDTH, M.ACTION_HEIGHT),
				parent = actionBar,
				onClick = function()
					local args = table.clone(declaredControl.args or {})
					if declaredControl.kind == "player-button" then
						if selected == nil then
							Components.toast(
								theme,
								notifications,
								localized("hud_select_player", "Select a player first"),
								"bad",
								2
							)
							return
						end
						table.insert(args, 1, selected)
					end
					activate(declaredControl.action, args)
				end,
			})
			-- A narrow control shrinks; its label must not. The label scales down to
			-- `HudFit`'s floor and wraps inside the control, so a long label can never
			-- run past its button and over its neighbour.
			item.TextWrapped, item.TextScaled = true, true
			local constraint = Instance.new("UITextSizeConstraint")
			constraint.MinTextSize, constraint.MaxTextSize = HudFit.MIN_TEXT_SIZE, HudFit.TEXT_SIZE
			constraint.Parent = item
			return item
		end)
		local item = entry.item :: TextButton
		item.Name = tostring(declaredControl.id)
		item.Text = HudText.assertVisible(display)
		item.LayoutOrder = if type(declaredControl.ui) == "table"
				and type(declaredControl.ui.order) == "number"
			then declaredControl.ui.order
			else 1
		item.Visible = true
		return item
	end

	local function ensureCell(cellId: string, text: string, order: number): TextButton
		local key = "cell:" .. cellId
		local entry = control(key, function()
			return Components.button(theme, {
				text = text,
				size = UDim2.fromOffset(88, 88),
				parent = grid,
				onClick = function() end,
			})
		end)
		local item = entry.item :: TextButton
		item.Name = "Cell-" .. cellId
		-- The text is written only when it changed, but the cell is visited on every render, so an
		-- unchanged quantity re-marks the cell present instead of hiding it.
		if entry.text ~= text then
			entry.text = text
			item.Text = text
		end
		item.LayoutOrder = order
		item.Visible = true
		return item
	end

	-- The display name of every entity the spec declares, so an inventory cell
	-- shows "Carrot" rather than the raw entity id it is keyed by.
	local entityNames: { [string]: string } = {}
	for _, entity in (if type(spec.entities) == "table" then spec.entities else {}) do
		if type(entity) == "table" and type(entity.id) == "string" and type(entity.name) == "string" then
			entityNames[entity.id] = entity.name
		end
	end
	local function entityDisplay(id: any): string?
		local name = entityNames[tostring(id)]
		if type(name) == "string" and #name > 0 then
			return HudText.assertVisible(name)
		end
		return nil
	end

	--- The text of one grid cell, resolved per field shape. A snapshot map may be keyed by an
	--- entity id (an inventory: `carrot` -> quantity) or by a slot whose *value* names the entity
	--- (the social equipped map: `hat` -> `starter-hat`). Both resolve to a declared display name,
	--- so neither exposes a raw id in the cell.
	local function cellText(cellId: string, value: any): string
		local keyed = entityDisplay(cellId)
		if keyed ~= nil then
			return keyed .. "\n" .. tostring(value)
		end
		if type(value) == "string" then
			local worn = entityDisplay(value)
			if worn ~= nil then
				return worn
			end
		end
		return tostring(value)
	end

	local function hideAbsent()
		for key, entry in registry do
			if not present[key] then
				local item = entry.item
				if item:IsA("GuiObject") then
					item.Visible = false
				end
			end
		end
		table.clear(present)
	end

	-- ---- roster selector ---------------------------------------------------
	-- A `player-button` control dispatches with the roster player the local client selected, so
	-- the HUD must let the player pick one: with three or more players the first other member is
	-- not a choice, and the action would silently target whoever happened to be first. The strip
	-- lists the roster by display name and marks the current selection.
	local hasPlayerButton = false
	for _, row in declared do
		if type(row) == "table" and row.kind == "player-button" then
			hasPlayerButton = true
		end
	end
	local rosterPanel = Instance.new("Frame")
	rosterPanel.Name, rosterPanel.BackgroundTransparency = "Roster", 1
	-- Below the reserved chat region and the notifications band: the one left-hand column that is
	-- clear of the chat above it, the resource strip and objective to its right, and the action row
	-- and grid below.
	rosterPanel.Position = UDim2.fromOffset(0, M.CHAT_RESERVE.height + 8 + 200 + 8)
	rosterPanel.Size = UDim2.fromOffset(240, 0)
	rosterPanel.AutomaticSize = Enum.AutomaticSize.Y
	rosterPanel.Visible = false
	rosterPanel.Parent = safeArea
	local rosterLayout = Instance.new("UIListLayout")
	rosterLayout.Padding, rosterLayout.SortOrder = UDim.new(0, 4), Enum.SortOrder.LayoutOrder
	rosterLayout.Parent = rosterPanel

	local render: () -> ()
	local function renderRoster(): ()
		rosterPanel.Visible = hasPlayerButton
		if not hasPlayerButton then
			return
		end
		for index, member in roster do
			local entryText = if member.id == selected then "\u{2022} " .. member.name else member.name
			local item = control("roster:" .. member.id, function()
				return Components.button(theme, {
					text = entryText,
					size = UDim2.fromOffset(220, 32),
					parent = rosterPanel,
					onClick = function()
						selected = member.id
						render()
					end,
				})
			end).item :: TextButton
			item.Name = "Roster-" .. member.id
			item.Text = entryText
			item.LayoutOrder = index
			item.Visible = true
		end
		-- The player-button's own label names the selection, so the control a player presses says
		-- whose outfit it votes for rather than an anonymous "Vote".
		local chosen: string? = nil
		for _, member in roster do
			if member.id == selected then
				chosen = member.name
			end
		end
		for _, row in declared do
			if type(row) == "table" and row.kind == "player-button" then
				local actionEntry = registry["action:" .. tostring(row.id)]
				if actionEntry ~= nil and actionEntry.item ~= nil then
					local display = if type(row.label) == "string" and #row.label > 0 then row.label else "Action"
					local text = HudText.assertVisible(localized(controlKeys[tostring(row.id)], display))
					if type(chosen) == "string" and #chosen > 0 then
						text = HudText.assertVisible(text .. " \u{2192} " .. chosen)
					end
					(actionEntry.item :: any).Text = text
				end
			end
		end
	end

	-- ---- render -----------------------------------------------------------
	local lastObjective: string? = nil

	render = function()
		for _, resource in resources do
			local value = field(snapshot, tostring(resource.id))
			local text = ensureResource(resource)
			-- The declared display name, never the locale key or the id.
			local display = localized(
				resource.nameKey,
				if type(resource.name) == "string" and #resource.name > 0 then resource.name else "Value"
			)
			text.Text = HudText.assertVisible(HudText.resource(display, value or 0))
		end

		for _, declaredControl in declared do
			if declaredControl.kind ~= "prompt" then
				ensureAction(declaredControl)
			end
		end

		-- Cells are visited on EVERY render. `control` marks a cell present for this pass and
		-- `hideAbsent` hides anything not visited, so gating the whole grid on a key-only signature
		-- meant the next unchanged snapshot never re-visited the cells: a harvested item's cell
		-- vanished, and a quantity change under an existing key never updated. Instance allocation
		-- is still avoided - `control` reuses the entry, and the text is written only on a change.
		local items = if gridSpec == nil then nil else field(snapshot, gridSpec.field)
		if type(items) == "table" then
			local keys: { any } = {}
			for cellId in items do
				table.insert(keys, cellId)
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			for order, cellId in keys do
				ensureCell(tostring(cellId), cellText(tostring(cellId), items[cellId]), order)
			end
		end

		local stage: any = stages[stageIndex]
		local text = if type(stage) == "table"
			then HudText.assertVisible(
				HudText.objective(
					localized(
						stage.goalKey,
						if type(stage.goal) == "string" and #stage.goal > 0 then stage.goal else "Objective"
					),
					stageIndex,
					#stages
				)
			)
			else ""
		if text ~= lastObjective then
			lastObjective = text
			objectiveLabel.Text = text
		end

		renderRoster()
		hideAbsent()
	end

	-- ---- phone layout -----------------------------------------------------
	-- The sheet toggle is a sibling of the action row, never a child of it: inside the row it
	-- becomes one more laid-out item, the row grows past the bar's own width, and the layout
	-- pushes controls off the safe area. It is placed beside the row by `resize`.
	local sheet = Components.modalSheet(theme, { name = "HudSheet", title = "", parent = safeArea })
	sheet.frame.Visible = false
	local sheetToggle = Components.button(theme, {
		text = localized("hud_menu", "Menu"),
		size = UDim2.fromOffset(88, M.ACTION_HEIGHT),
		parent = safeArea,
		onClick = function()
			sheet.frame.Visible = not sheet.frame.Visible
		end,
	})
	sheetToggle.Name = "PhoneSheetToggle"

	local function findJumpButton(): GuiObject?
		local playerGui = player:FindFirstChild("PlayerGui")
		local touchGui = if playerGui ~= nil then playerGui:FindFirstChild("TouchGui") else nil
		local frame = if touchGui ~= nil then touchGui:FindFirstChild("TouchControlFrame") else nil
		local jump = if frame ~= nil then frame:FindFirstChild("JumpButton") else nil
		return if jump ~= nil and jump:IsA("GuiObject") then jump else nil
	end

	local function resize()
		local camera = workspace.CurrentCamera
		local viewport = if camera ~= nil then camera.ViewportSize else Vector2.new(1280, 720)
		local phone = Layout.isPhone(viewport)
		local size = Layout.sheetSize(viewport)
		sheet.frame.Position = UDim2.fromScale(0.5, 0.5)
		sheet.frame.Size = UDim2.fromOffset(size.x, size.y)
		sheetToggle.Visible = phone
		-- Width the action row has to live inside: the bar's own width on the
		-- desktop column, and the room left of the jump button's reserved
		-- footprint on the phone bar.
		-- The resource row and the objective own the top-right strip; the top-left
		-- corner stays clear for the chat window (M.CHAT_RESERVE). A phone strip is
		-- narrower and wraps, so extra pills stack below instead of growing left into
		-- the chat.
		resourceBar.Position, resourceBar.Size = UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, M.RESOURCE_HEIGHT)
		resourceLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		resourceLayout.Wraps = phone
		local pillWidth = if phone then M.RESOURCE_WIDTH_PHONE else M.RESOURCE_WIDTH
		for _, resource in resources do
			local entry = registry["resource:" .. tostring(resource.id)]
			if entry ~= nil and entry.item ~= nil then
				(entry.item :: any).Size = UDim2.fromOffset(pillWidth, M.RESOURCE_HEIGHT)
			end
		end
		objective.AnchorPoint, objective.Position = Vector2.new(1, 0), UDim2.new(1, 0, 0, M.RESOURCE_HEIGHT + 6)
		objective.Size = UDim2.fromOffset(M.OBJECTIVE_WIDTH, M.OBJECTIVE_HEIGHT)
		-- Width the action row has to live inside: the bar's own width on the
		-- desktop column, and the room left of the jump button's reserved
		-- footprint on the phone bar.
		local actionWidth: number
		-- Phone: the action bar sits bottom-right, left of the touch jump
		-- button's reserved footprint. Desktop: bottom-centre, lifted above the
		-- backpack hotbar that owns the bottom-centre strip.
		if phone then
			-- The row is left-anchored at a fixed margin and its width is fitted to the room left
			-- of the touch jump button's reserved footprint, computed from the viewport. A touch
			-- control that has not been laid out yet reports a position from the previous, wider
			-- resolution, so a measurement is only ever allowed to narrow the row: anchoring to it
			-- put the row past the right of the safe area (x = 1029) and then off the left (x = -83)
			-- in two live 390x844 captures.
			local rowRight = viewport.X - M.PHONE_BAR_MARGIN - M.JUMP_BUTTON_RESERVE - M.JUMP_GAP
			local jump = findJumpButton()
			if jump ~= nil and jump.Visible and jump.AbsoluteSize.X > 0 and jump.AbsoluteSize.Y > 0 then
				local jumpPos = jump.AbsolutePosition - gui.AbsolutePosition
				local jumpSize = jump.AbsoluteSize
				local inside = jumpPos.X + jumpSize.X <= viewport.X + 1 and jumpPos.Y + jumpSize.Y <= viewport.Y + 1
				if inside and jumpPos.X >= M.JUMP_BUTTON_RESERVE then
					rowRight = math.min(rowRight, jumpPos.X - M.JUMP_GAP)
				end
			end
			-- `bottomY` is relative to the safe area, so it comes from the safe area's own height:
			-- the viewport height is an absolute screen coordinate, and using it here put the row
			-- below the safe area's bottom edge (a live 390x844 capture caught it at y = 824).
			local bottomY = safeArea.AbsoluteSize.Y - M.PHONE_BAR_MARGIN
			local room = math.max(M.ACTION_MIN_WIDTH, rowRight)
			actionBar.AnchorPoint, actionBar.AutomaticSize = Vector2.new(0, 1), Enum.AutomaticSize.None
			actionBar.Size = UDim2.fromOffset(room, M.ACTION_HEIGHT)
			actionBar.Position = UDim2.fromOffset(M.PHONE_BAR_MARGIN, bottomY)
			actionLayout.SortOrder = Enum.SortOrder.LayoutOrder
			actionLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
			grid.Visible, objective.Visible = false, false
			actionWidth = room
		else
			actionBar.AnchorPoint, actionBar.AutomaticSize = Vector2.new(0.5, 1), Enum.AutomaticSize.XY
			actionBar.Size = UDim2.new()
			actionBar.Position = UDim2.new(0.5, 0, 1, -M.HOTBAR_RESERVE)
			actionLayout.SortOrder = Enum.SortOrder.LayoutOrder
			actionLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			-- The inventory grid takes the bottom-left corner, the one region no
			-- Roblox core UI claims on desktop.
			grid.AnchorPoint, grid.Position = Vector2.new(0, 1), UDim2.new(0, 0, 1, -8)
			grid.Visible, objective.Visible = true, true
			sheet.frame.Visible = false
			actionWidth = safeArea.AbsoluteSize.X
		end
		-- The bar holds the action controls in at most HudFit.MAX_ROWS rows, packed
		-- from the labels they must carry. A phone has far less room than the natural
		-- control width, and a control shrunk below its label's width is a control
		-- whose label spills over its neighbour: a live 390x844 capture of the
		-- rpg-progression HUD showed three 110px buttons with their text running past
		-- each other. A long label now grows its control and the bar wraps, so
		-- TextBounds never exceed the button that owns them.
		local labels: { string } = {}
		for _, declaredControl in declared do
			if declaredControl.kind ~= "prompt" then
				local entry = registry["action:" .. tostring(declaredControl.id)]
				local text = if entry ~= nil and entry.item ~= nil then (entry.item :: any).Text else nil
				table.insert(labels, if type(text) == "string" then text else "")
			end
		end
		local fitted = HudFit.plan(labels, actionWidth, M.ACTION_GAP, M.ACTION_WIDTH, M.ACTION_MIN_WIDTH)
		actionLayout.Wraps = fitted.rows > 1
		actionLayout.FillDirection = Enum.FillDirection.Horizontal
		for _, declaredControl in declared do
			if declaredControl.kind ~= "prompt" then
				local entry = registry["action:" .. tostring(declaredControl.id)]
				if entry ~= nil and entry.item ~= nil then
					(entry.item :: any).Size = UDim2.fromOffset(fitted.itemWidth, M.ACTION_HEIGHT)
				end
			end
		end
		local rowWidth = fitted.perRow * fitted.itemWidth + math.max(0, fitted.perRow - 1) * M.ACTION_GAP
		local barHeight = fitted.rows * M.ACTION_HEIGHT + math.max(0, fitted.rows - 1) * M.ACTION_GAP
		-- The bar is placed from the width that was actually applied: an explicit size
		-- and left edge at a fixed margin, so the first control can never start left of
		-- the safe area. It is bottom-anchored, so a second row grows upward over the
		-- avatar rather than off the screen.
		if phone then
			actionBar.Size = UDim2.fromOffset(rowWidth, barHeight)
			actionBar.Position = UDim2.fromOffset(M.PHONE_BAR_MARGIN, actionBar.Position.Y.Offset)
			actionLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		end
		-- The sheet toggle sits above the row: the one place on a phone that collides with
		-- neither the row nor the jump button's reserved footprint. It is placed whenever the
		-- phone layout is active, including for a pack that declares no button at all.
		if phone then
			sheetToggle.AnchorPoint = Vector2.new(0, 1)
			sheetToggle.Position =
				UDim2.fromOffset(M.PHONE_BAR_MARGIN, actionBar.Position.Y.Offset - barHeight - M.ACTION_GAP)
		end
	end

	local connections: { RBXScriptConnection } = {}
	table.insert(connections, safeArea:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize))
	local camera = workspace.CurrentCamera
	if camera ~= nil then
		table.insert(connections, camera:GetPropertyChangedSignal("ViewportSize"):Connect(resize))
	end

	-- A prompt control dispatches from the world prompt the world builder placed,
	-- and the *server* owns that dispatch: the world server's `WorldKit.start`
	-- wires every node prompt to the same `session.dispatch` a HUD button uses. The
	-- client must not also dispatch on `PromptTriggered`, or one trigger would run
	-- the action twice (a purchase charged twice, a vote counted twice).

	-- Subscribe before requesting initial state: no timer and no polling race.
	local function receive(packet: any)
		if type(packet) ~= "table" then
			return
		end
		if type(packet.roster) == "table" then
			roster = {}
			for _, entry in packet.roster do
				if type(entry) == "table" and tostring(entry.id) ~= tostring(player.UserId) then
					table.insert(roster, { id = tostring(entry.id), name = tostring(entry.name or entry.id) })
				end
			end
			local found = false
			for _, entry in roster do
				if entry.id == selected then
					found = true
				end
			end
			if not found then
				selected = if roster[1] ~= nil then roster[1].id else nil
			end
		end
		if type(packet.snapshots) == "table" and packet.snapshots[spec.id] ~= nil then
			snapshot = packet.snapshots[spec.id]
		end
		-- A world prompt's committed action is dispatched by the server, so the HUD
		-- never sees a click: the chip advances from the committed result the server
		-- publishes, which is the same outcome a HUD control produces. A HUD control's
		-- own invoke carries no control, so no action advances the chain twice.
		local committed = HudLoop.committedAction(packet, controlActions)
		if committed ~= nil then
			advanceLoop(committed)
		end
		render()
	end
	options.subscribe(receive)
	connected = true

	local function destroy()
		if not connected then
			return
		end
		connected = false
		for _, connection in connections do
			connection:Disconnect()
		end
		gui:Destroy()
	end
	table.insert(connections, gui.Destroying:Connect(destroy))

	gui.Parent = player:WaitForChild("PlayerGui")
	resize()
	render()
	-- The touch jump button is created by core UI after this frame; re-place the
	-- bar once it exists so its reserved footprint is measured, not guessed.
	task.defer(resize)
	return gui
end

return M
