--!strict
-- Shared docked sheet for the farming and crafting screens: one ScreenGui + modalSheet
-- fitted by ExtensionPanels, 48px rows, row splits (scale x, scale width) and a status
-- line that shows localized refusals. Engine globals are injectable for Lune specs.
local Text = require("./FarmCraftText")
local env: any = getfenv()
local M = {}
export type Cell = { name: string, text: string, click: () -> () }
M.ROW = 48
M.SPLIT2 = { { 0, 0.62 }, { 0.64, 0.36 } }
M.SPLIT3 = { { 0, 0.32 }, { 0.34, 0.32 }, { 0.68, 0.32 } }
-- sheets4: seed tray chip (square px) and the growth row's time pill width.
M.SEED = 52
M.TIME_PILL = 84

-- Plot card rows in card px for a body text size: the 72 px bed at the left; beside it the title,
-- the growth row (4 steps, stage name, clock pill), the detail line and the 44 px action row. The
-- seed tray (empty plots) runs under all of it across the card.
function M.plotLayout(body: number, tray: boolean): any
	local title = 10
	local stage = title + body + 2 + 4 + 4
	local detail = stage + body + 4 + 4
	local actions = detail + body + 4 + 6
	local base = math.max(10 + 72, actions + 44) + 10
	return {
		bed = 10,
		text = 94,
		title = title,
		stage = stage,
		detail = detail,
		actions = actions,
		tray = base,
		height = base + (if tray then M.SEED + 6 + 10 else 0),
	}
end

-- `hidden` locks the entry (opened only by its owner); `menu = false` keeps it openable by id
-- (navigator, ctx.openPanel) without a tile on the menu grid.
function M.new(ctx: any, options: { id: string, title: string, order: number, hidden: boolean?, menu: boolean? }): any
	local Instance = ctx.instance or env.Instance
	local Enum = ctx.enum or env.Enum
	local UDim2 = ctx.udim2 or env.UDim2
	local game = ctx.game or env.game
	local Color3, UDim, Vector2 = env.Color3, env.UDim, env.Vector2
	local theme, components = ctx.ui.theme.default, ctx.ui.components
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.Enabled, gui.DisplayOrder = "Forge-" .. options.id, false, false, 20
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local sheet = components.modalSheet(theme, { name = options.id, title = options.title, parent = gui })
	sheet.frame.Visible = true
	if ctx.fitSheet then
		ctx.fitSheet(sheet.frame)
	end
	local api: any = { status = "", gui = gui, locale = ctx.locale }
	local shown: { any } = {}
	local order = 0
	local plotGrid: any = nil
	local dock = if ctx.dock
		then ctx.dock({
			id = options.id,
			label = options.title,
			order = options.order,
			hidden = options.menu == false,
			setOpen = function(open: boolean)
				gui.Enabled = open
				if open and api.render then
					api.render()
				end
			end,
			isOpen = function(): boolean
				return gui.Enabled
			end,
		})
		else nil
	if dock and options.hidden then
		dock.setAvailable(false)
	end
	local closeConnection = sheet.close.Activated:Connect(function()
		gui.Enabled = false
	end)
	function api.open()
		if dock then
			dock.open()
		else
			gui.Enabled = true
		end
		if api.render then
			api.render()
		end
	end
	function api.close()
		gui.Enabled = false
	end
	-- Every hub sheet rebuilds its rows on each state push (clear, rows, footer). Destroying the rows
	-- shrank the canvas and the scroll snapped to the top, so on the v61 phone a finger scroll below
	-- the first cards bounced back and the lower rows were unreachable. clear() keeps the reading
	-- position and footer() (the end of every render) puts it back, again after the next layout pass.
	local kept: any = nil
	function api.clear()
		kept = kept or sheet.scroll.CanvasPosition
		for _, child in shown do
			child:Destroy()
		end
		table.clear(shown)
		order = 0
		plotGrid = nil
	end
	-- AutomaticCanvasSize grows the canvas back only on the next layout pass, so a position past the
	-- still-short canvas is clamped: hold it as `pending` and apply it again when the canvas grows.
	local pending: any = nil
	local canvasConnection = if sheet.scroll.GetPropertyChangedSignal
		then sheet.scroll:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(function()
			if pending ~= nil then
				sheet.scroll.CanvasPosition = pending
				if sheet.scroll.CanvasPosition == pending then
					pending = nil
				end
			end
		end)
		else nil
	local function restore()
		local at = kept
		kept = nil
		if at == nil then
			return
		end
		sheet.scroll.CanvasPosition = at
		pending = if sheet.scroll.CanvasPosition == at then nil else at
	end
	local function holder(): any
		order += 1
		-- A row ends the current card grid: cards after it start a new grid below the row.
		plotGrid = nil
		local frame = Instance.new("Frame")
		frame.Name, frame.LayoutOrder, frame.BackgroundTransparency = "Row" .. order, order, 1
		frame.Size = UDim2.new(1, 0, 0, M.ROW)
		frame.Parent = sheet.scroll
		table.insert(shown, frame)
		return frame
	end
	function api.label(text: string): any
		local row = holder()
		local label = components.label(theme, { text = text, size = UDim2.fromScale(1, 1), parent = row })
		label.TextWrapped = true
		return label
	end
	-- An item row: the item's icon (ItemIcons via ctx.icons) left of a title/detail label and, with
	-- `action`, one button on the right. The icon is a row sibling so the shell styler's label
	-- padding never moves it; spec engines (ctx.instance) get a plain "ItemIcon" node on the label.
	function api.item(catalogId: string?, text: string, action: Cell?): any
		local row = holder()
		local width = if action then 0.66 else 1
		local icon = if ctx.icons and catalogId then ctx.icons.item(catalogId) else nil
		local label = components.label(theme, { text = text, size = UDim2.fromScale(width, 1), parent = row })
		label.Name, label.TextWrapped = "ItemText", true
		if icon and ctx.instance ~= nil then
			local art = Instance.new("ImageLabel")
			art.Name, art.Image, art.Parent = "ItemIcon", icon.image or "", label
		elseif icon then
			label.Size, label.Position = UDim2.new(width, -44, 1, 0), UDim2.fromOffset(44, 0)
			local art = require("../../../core/ui-kit/IconFallback").mount(
				row,
				icon.category or "item",
				UDim2.fromOffset(36, 36),
				UDim2.new(0, 2, 0.5, -18),
				if icon.image and icon.image ~= "" then icon.image else nil,
				"ItemIcon"
			)
			art.BackgroundTransparency = 1
		end
		if action then
			local button = components.button(theme, {
				text = action.text,
				size = UDim2.fromScale(0.32, 1),
				position = UDim2.fromScale(0.68, 0),
				parent = row,
				onClick = action.click,
			})
			button.Name = action.name
		end
		return row
	end
	-- U6: SheetCards empty state (spec engines with ctx.instance keep the label).
	function api.empty(title: string, hint: string?, icon: string?): any
		if ctx.instance ~= nil then
			return api.label(if hint then title .. "\n" .. hint else title)
		end
		order += 1
		local size = if ctx.sheetText then ctx.sheetText("body") else 15
		local card = require("./SheetCards").empty(sheet.scroll, {
			name = "EmptyState",
			order = order,
			icon = if ctx.icons and icon then ctx.icons.ui(icon) else nil,
			title = title,
			hint = hint,
			size = size,
		})
		table.insert(shown, card)
		return card
	end
	-- sheets3 plot card (Durango R06/R12 farmland), sheets4 look: crop or seed art on a soil bed, the
	-- plot line, a 4-step growth bar with the stage name and a clock pill for the time left, the
	-- detail line and the plot's actions. An empty plot lightens its bed and fades the picked seed on
	-- it (an open invitation) and shows a seed tray under the card: one chip per seed with its icon
	-- and the stored count, the picked seed rimmed. Cards stack in one column. Spec engines
	-- (ctx.instance) get the same text and buttons as flat rows.
	function api.plot(spec: {
		name: string,
		catalogId: string?,
		text: string,
		detail: string?,
		stage: number?,
		stageText: string?,
		time: string?,
		ready: boolean?,
		empty: boolean?,
		seeds: { { name: string, catalogId: string, count: number, selected: boolean, click: () -> () } }?,
		cells: { Cell },
	}): any
		local seeds: { any } = spec.seeds or {}
		if ctx.instance ~= nil then
			local row = api.item(spec.catalogId, spec.text)
			row.Name = spec.name
			if spec.detail then
				api.label(spec.detail)
			end
			if spec.stageText then
				local stage = api.label(spec.stageText .. (if spec.time then "  " .. spec.time else ""))
				stage.Name = "Stage"
				stage.Parent.Name = spec.name .. "-Stage"
				stage.stage = spec.stage or 0
			end
			-- Seed chips four to a row (each keeps 44 px on a 360 px portrait sheet).
			for first = 1, #seeds, 4 do
				local splits, cells = {}, {}
				for index = first, math.min(#seeds, first + 3) do
					local seed = seeds[index]
					table.insert(splits, { (index - first) * 0.25, 0.23 })
					table.insert(cells, { name = seed.name, text = tostring(seed.count), click = seed.click })
				end
				for index, button in api.row(splits, cells) do
					local seed = seeds[first + index - 1]
					local icon = if ctx.icons then ctx.icons.item(seed.catalogId) else nil
					button.seed, button.selected = seed.catalogId, seed.selected
					button.icon = if icon then icon.image else nil
				end
			end
			if #spec.cells == 1 then
				api.button(spec.cells[1].name, spec.cells[1].text, spec.cells[1].click)
			elseif #spec.cells > 1 then
				api.row(M.SPLIT2, spec.cells)
			end
			return row
		end
		local IconFallback = require("../../../core/ui-kit/IconFallback")
		local body = if ctx.sheetText then ctx.sheetText("body") else 15
		if not plotGrid or plotGrid.Parent == nil then
			order += 1
			plotGrid = Instance.new("Frame")
			plotGrid.Name, plotGrid.LayoutOrder, plotGrid.BackgroundTransparency = "Plots", order, 1
			plotGrid.Size, plotGrid.AutomaticSize = UDim2.new(1, -6, 0, 0), Enum.AutomaticSize.Y
			local list = Instance.new("UIListLayout")
			list.Name, list.SortOrder, list.Padding = "Grid", Enum.SortOrder.LayoutOrder, UDim.new(0, 8)
			list.Parent = plotGrid
			plotGrid.Parent = sheet.scroll
			table.insert(shown, plotGrid)
		end
		local layout = M.plotLayout(body, #seeds > 0)
		local card = Instance.new("Frame")
		card.Name, card.LayoutOrder, card.BorderSizePixel = spec.name, #plotGrid:GetChildren(), 0
		card.Size = UDim2.new(1, 0, 0, layout.height)
		card.BackgroundColor3 = Color3.fromRGB(222, 208, 178)
		local round = Instance.new("UICorner")
		round.CornerRadius, round.Parent = UDim.new(0, 10), card
		local rim = Instance.new("UIStroke")
		rim.Thickness = if spec.ready then 2 else 1.5
		rim.Color = if spec.ready then Color3.fromRGB(58, 128, 118) else Color3.fromRGB(122, 92, 62)
		rim.Transparency, rim.Parent = if spec.ready then 0 else 0.45, card
		-- Soil bed behind the art: a dark tilled square with the crop / seed on it.
		local bed = Instance.new("Frame")
		bed.Name, bed.BorderSizePixel, bed.BackgroundColor3 = "Bed", 0, Color3.fromRGB(92, 66, 44)
		bed.Position, bed.Size = UDim2.fromOffset(layout.bed, layout.bed), UDim2.fromOffset(72, 72)
		local bedRound = Instance.new("UICorner")
		bedRound.CornerRadius, bedRound.Parent = UDim.new(0, 8), bed
		local furrows = Instance.new("UIGradient")
		furrows.Rotation, furrows.Parent = 90, bed
		if spec.empty then
			bed.BackgroundColor3 = Color3.fromRGB(128, 98, 70)
			local open = Instance.new("UIStroke")
			open.Color, open.Thickness, open.Transparency = Color3.fromRGB(246, 238, 220), 2, 0.2
			open.Parent = bed
		end
		bed.Parent = card
		local icon = if ctx.icons and spec.catalogId then ctx.icons.item(spec.catalogId) else nil
		local art = IconFallback.mount(
			bed,
			if icon then icon.category or "seed" else "seed",
			UDim2.fromOffset(56, 56),
			UDim2.fromOffset(8, 8),
			if icon and icon.image and icon.image ~= "" then icon.image else nil,
			"PlotArt"
		)
		art.BackgroundTransparency = 1
		local asset = art:FindFirstChild("Asset")
		if asset and spec.empty then
			asset.ImageTransparency = 0.45
		end
		if spec.ready and ctx.icons then
			local tick = ctx.icons.ui("success")
			local badge = IconFallback.mount(
				bed,
				"item",
				UDim2.fromOffset(24, 24),
				UDim2.new(1, -20, 0, -6),
				if tick.image and tick.image ~= "" then tick.image else nil,
				"ReadyBadge"
			)
			badge.BackgroundTransparency = 1
		end
		local function line(name: string, text: string, size: number, y: number, bold: boolean, muted: boolean)
			local label = Instance.new("TextLabel")
			label.Name, label.Text, label.BackgroundTransparency = name, text, 1
			label.Font = if bold then Enum.Font.BuilderSansBold else Enum.Font.BuilderSans
			label.TextSize, label.TextXAlignment = size, Enum.TextXAlignment.Left
			label.TextColor3 = if muted then Color3.fromRGB(92, 76, 60) else Color3.fromRGB(38, 30, 24)
			label.TextTruncate, label.TextWrapped = Enum.TextTruncate.AtEnd, false
			label.Position = UDim2.fromOffset(layout.text, y)
			label.Size = UDim2.new(1, -layout.text - 10, 0, size + 4)
			label:SetAttribute("ForgeShellKeep", true)
			label.Parent = card
			return label
		end
		line("PlotText", spec.text, body + 2, layout.title, true, false)
		-- Growth row: four stage steps (seed, sprout, growing, ripe), the stage name and a clock pill.
		local growth = Instance.new("Frame")
		growth.Name, growth.BackgroundTransparency = "Growth", 1
		growth.Position = UDim2.fromOffset(layout.text, layout.stage)
		growth.Size = UDim2.new(1, -layout.text - 10, 0, body + 4)
		growth:SetAttribute("ForgePlotStage", spec.stage or 0)
		growth.Parent = card
		for index = 1, 4 do
			local step = Instance.new("Frame")
			step.Name, step.BorderSizePixel = "Step" .. index, 0
			step.Position = UDim2.fromOffset((index - 1) * 26, math.floor((body + 4) / 2) - 5)
			step.Size = UDim2.fromOffset(22, 10)
			local lit = (spec.stage or 0) >= index
			step.BackgroundColor3 = if not lit
				then Color3.fromRGB(196, 186, 166)
				elseif spec.ready then Color3.fromRGB(58, 128, 118)
				else Color3.fromRGB(122, 160, 72)
			local stepRound = Instance.new("UICorner")
			stepRound.CornerRadius, stepRound.Parent = UDim.new(0, 4), step
			step.Parent = growth
		end
		local pillWidth = if spec.time then M.TIME_PILL else 0
		if spec.stageText then
			local name = Instance.new("TextLabel")
			name.Name, name.Text, name.BackgroundTransparency = "StageText", spec.stageText, 1
			name.Font, name.TextSize = Enum.Font.BuilderSansBold, body
			name.TextColor3 = if spec.ready then Color3.fromRGB(42, 104, 96) else Color3.fromRGB(38, 30, 24)
			name.TextXAlignment, name.TextTruncate = Enum.TextXAlignment.Left, Enum.TextTruncate.AtEnd
			name.Position, name.Size = UDim2.fromOffset(110, 0), UDim2.new(1, -110 - pillWidth - 4, 1, 0)
			name:SetAttribute("ForgeShellKeep", true)
			name.Parent = growth
		end
		if spec.time then
			local pill = Instance.new("Frame")
			pill.Name, pill.BorderSizePixel, pill.BackgroundColor3 = "TimeLeft", 0, Color3.fromRGB(74, 52, 36)
			pill.AnchorPoint, pill.Position = Vector2.new(1, 0), UDim2.fromScale(1, 0)
			pill.Size = UDim2.new(0, pillWidth, 1, 0)
			local pillRound = Instance.new("UICorner")
			pillRound.CornerRadius, pillRound.Parent = UDim.new(0.5, 0), pill
			local clock = if ctx.icons then ctx.icons.ui("clock") else nil
			local glyph = IconFallback.mount(
				pill,
				"item",
				UDim2.fromOffset(body, body),
				UDim2.fromOffset(6, 2),
				if clock and clock.image and clock.image ~= "" then clock.image else nil,
				"Clock"
			)
			glyph.BackgroundTransparency = 1
			local time = Instance.new("TextLabel")
			time.Name, time.Text, time.BackgroundTransparency = "TimeText", spec.time, 1
			time.Font, time.TextSize, time.TextColor3 = Enum.Font.BuilderSansBold, body, Color3.fromRGB(246, 238, 220)
			time.TextXAlignment, time.TextTruncate = Enum.TextXAlignment.Left, Enum.TextTruncate.AtEnd
			time.Position, time.Size = UDim2.fromOffset(body + 10, 0), UDim2.new(1, -body - 14, 1, 0)
			time:SetAttribute("ForgeShellKeep", true)
			time.Parent = pill
			pill.Parent = growth
		end
		line("PlotDetail", spec.detail or "", body, layout.detail, false, true)
		local actions = Instance.new("Frame")
		actions.Name, actions.BackgroundTransparency = "Actions", 1
		actions.Position = UDim2.fromOffset(layout.text, layout.actions)
		actions.Size, actions.Parent = UDim2.new(1, -layout.text - 10, 0, 44), card
		local count = #spec.cells
		for index, cell in spec.cells do
			-- The first of two cells is the picker (fertilizer): a chip; the last is the action.
			local button = components.button(theme, {
				text = cell.text,
				size = UDim2.new(1 / count, if count > 1 then -4 else 0, 1, 0),
				position = UDim2.new((index - 1) / count, if index > 1 then 4 else 0, 0, 0),
				parent = actions,
				onClick = cell.click,
			})
			button.Name = cell.name
			if count > 1 and index < count then
				-- A parchment chip with ink text (the shell styler leaves ForgeShellKeep text alone).
				button:SetAttribute("ForgeShellKeep", true)
				button.BackgroundColor3, button.BackgroundTransparency = Color3.fromRGB(246, 238, 220), 0
				button.TextColor3, button.TextSize = Color3.fromRGB(38, 30, 24), body
				button.Font, button.TextTruncate = Enum.Font.BuilderSansBold, Enum.TextTruncate.AtEnd
				local chipRim = Instance.new("UIStroke")
				chipRim.ApplyStrokeMode, chipRim.Color = Enum.ApplyStrokeMode.Border, Color3.fromRGB(122, 92, 62)
				chipRim.Transparency, chipRim.Parent = 0.4, button
			end
		end
		if #seeds > 0 then
			-- Seed tray: icon chips with the stored count; scrolls sideways when the seeds outgrow the card.
			local tray = Instance.new("ScrollingFrame")
			tray.Name, tray.BackgroundTransparency, tray.BorderSizePixel = "SeedTray", 1, 0
			tray.Position, tray.Size = UDim2.fromOffset(10, layout.tray), UDim2.new(1, -20, 0, M.SEED + 6)
			tray.ScrollingDirection, tray.ScrollBarThickness = Enum.ScrollingDirection.X, 3
			tray.CanvasSize, tray.AutomaticCanvasSize = UDim2.new(), Enum.AutomaticSize.X
			tray:SetAttribute("ForgeShellKeep", true)
			local flow = Instance.new("UIListLayout")
			flow.FillDirection, flow.Padding, flow.SortOrder =
				Enum.FillDirection.Horizontal, UDim.new(0, 6), Enum.SortOrder.LayoutOrder
			flow.Parent = tray
			for index, seed in seeds do
				local chip = Instance.new("TextButton")
				chip.Name, chip.Text, chip.LayoutOrder, chip.AutoButtonColor = seed.name, "", index, true
				chip.Size, chip.BorderSizePixel = UDim2.fromOffset(M.SEED, M.SEED), 0
				chip.BackgroundColor3 = if seed.selected
					then Color3.fromRGB(246, 238, 220)
					else Color3.fromRGB(236, 226, 203)
				chip:SetAttribute("ForgeShellKeep", true)
				chip:SetAttribute("ForgeSeed", seed.catalogId)
				chip:SetAttribute("ForgeSelected", seed.selected)
				local chipRound = Instance.new("UICorner")
				chipRound.CornerRadius, chipRound.Parent = UDim.new(0, 8), chip
				local edge = Instance.new("UIStroke")
				edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				edge.Color = if seed.selected then Color3.fromRGB(58, 128, 118) else Color3.fromRGB(122, 92, 62)
				edge.Thickness, edge.Transparency = if seed.selected then 3 else 1, if seed.selected then 0 else 0.5
				edge.Parent = chip
				local seedIcon = if ctx.icons then ctx.icons.item(seed.catalogId) else nil
				local seedArt = IconFallback.mount(
					chip,
					if seedIcon then seedIcon.category or "seed" else "seed",
					UDim2.fromOffset(M.SEED - 14, M.SEED - 14),
					UDim2.fromOffset(4, 3),
					if seedIcon and seedIcon.image and seedIcon.image ~= "" then seedIcon.image else nil,
					"ItemIcon"
				)
				seedArt.BackgroundTransparency = 1
				local seedAsset = seedArt:FindFirstChild("Asset")
				if seedAsset and seed.count <= 0 then
					seedAsset.ImageTransparency = 0.5
				end
				local badge = Instance.new("TextLabel")
				badge.Name, badge.Text, badge.BorderSizePixel = "SeedCount", tostring(seed.count), 0
				badge.Font, badge.TextSize = Enum.Font.BuilderSansBold, 14
				badge.TextColor3 = Color3.fromRGB(246, 238, 220)
				badge.BackgroundColor3 = if seed.count > 0
					then Color3.fromRGB(58, 96, 88)
					else Color3.fromRGB(176, 72, 52)
				badge.AnchorPoint, badge.Position = Vector2.new(1, 1), UDim2.new(1, -2, 1, -2)
				badge.Size = UDim2.fromOffset(if seed.count >= 10 then 26 else 20, 18)
				badge:SetAttribute("ForgeShellKeep", true)
				local badgeRound = Instance.new("UICorner")
				badgeRound.CornerRadius, badgeRound.Parent = UDim.new(0.5, 0), badge
				badge.Parent = chip
				chip.Activated:Connect(seed.click)
				chip.Parent = tray
			end
			tray.Parent = card
		end
		card.Parent = plotGrid
		return card
	end
	-- One row of buttons: { name, text, onClick } per split.
	function api.row(splits: { { number } }, cells: { Cell }): { any }
		local row = holder()
		local out = {}
		for index, cell in cells do
			local split = splits[index]
			local button = components.button(theme, {
				text = cell.text,
				size = UDim2.fromScale(split[2], 1),
				position = UDim2.fromScale(split[1], 0),
				parent = row,
				onClick = cell.click,
			})
			button.Name = cell.name
			table.insert(out, button)
		end
		return out
	end
	function api.button(name: string, text: string, onClick: () -> ()): any
		return api.row({ { 0, 1 } }, { { name = name, text = text, click = onClick } })[1]
	end
	-- Sends a durable command; a refusal stays visible in the status line.
	function api.send(action: string, args: { any }): any
		local result = ctx.send("survival-coop:" .. action, args)
		api.status = if result.ok then Text.text(ctx.locale, "ok") else Text.refusal(ctx.locale, result.reason)
		if api.render then
			api.render()
		end
		return result
	end
	function api.footer()
		if api.status ~= "" then
			api.label(api.status).Name = "Status"
		end
		restore()
	end
	function api.destroy()
		closeConnection:Disconnect()
		if canvasConnection then
			canvasConnection:Disconnect()
		end
		gui:Destroy()
	end
	return api
end

return M
