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
	function api.clear()
		for _, child in shown do
			child:Destroy()
		end
		table.clear(shown)
		order = 0
		plotGrid = nil
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
	-- sheets3 plot card (Durango R06/R12 farmland): crop or seed art left, the plot line, a detail line,
	-- a growth bar and the plot's action buttons under them. Cards sit in a 1-2 column grid. Spec
	-- engines (ctx.instance) get the same text and buttons as flat rows.
	function api.plot(spec: {
		name: string,
		catalogId: string?,
		text: string,
		detail: string?,
		fraction: number?,
		ready: boolean?,
		cells: { Cell },
	}): any
		if ctx.instance ~= nil then
			local row = api.item(spec.catalogId, spec.text)
			row.Name = spec.name
			if spec.detail then
				api.label(spec.detail)
			end
			if #spec.cells == 1 then
				api.button(spec.cells[1].name, spec.cells[1].text, spec.cells[1].click)
			elseif #spec.cells > 1 then
				api.row(M.SPLIT2, spec.cells)
			end
			return row
		end
		local body = if ctx.sheetText then ctx.sheetText("body") else 15
		if not plotGrid or plotGrid.Parent == nil then
			order += 1
			plotGrid = Instance.new("Frame")
			plotGrid.Name, plotGrid.LayoutOrder, plotGrid.BackgroundTransparency = "Plots", order, 1
			plotGrid.Size, plotGrid.AutomaticSize = UDim2.new(1, -6, 0, 0), Enum.AutomaticSize.Y
			local grid = Instance.new("UIGridLayout")
			grid.Name, grid.SortOrder, grid.CellPadding = "Grid", Enum.SortOrder.LayoutOrder, UDim2.fromOffset(8, 8)
			grid.Parent = plotGrid
			plotGrid.Parent = sheet.scroll
			table.insert(shown, plotGrid)
		end
		local wide = sheet.scroll.AbsoluteSize.X >= 620
		-- Title, detail and growth bar beside the 72 px soil bed, the action row under the bar.
		local cardHeight = 22 + 2 * body + 6 + 8 + 8 + 44 + 10
		plotGrid.Grid.CellSize = UDim2.new(if wide then 0.5 else 1, -8, 0, cardHeight)
		local card = Instance.new("Frame")
		card.Name, card.LayoutOrder, card.BorderSizePixel = spec.name, #plotGrid:GetChildren(), 0
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
		bed.Position, bed.Size = UDim2.fromOffset(10, 10), UDim2.fromOffset(72, 72)
		local bedRound = Instance.new("UICorner")
		bedRound.CornerRadius, bedRound.Parent = UDim.new(0, 8), bed
		local furrows = Instance.new("UIGradient")
		furrows.Rotation, furrows.Parent = 90, bed
		bed.Parent = card
		local icon = if ctx.icons and spec.catalogId then ctx.icons.item(spec.catalogId) else nil
		local art = require("../../../core/ui-kit/IconFallback").mount(
			bed,
			if icon then icon.category or "seed" else "seed",
			UDim2.fromOffset(56, 56),
			UDim2.fromOffset(8, 8),
			if icon and icon.image and icon.image ~= "" then icon.image else nil,
			"PlotArt"
		)
		art.BackgroundTransparency = 1
		if spec.ready and ctx.icons then
			local tick = ctx.icons.ui("success")
			local badge = require("../../../core/ui-kit/IconFallback").mount(
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
			label.Position, label.Size = UDim2.fromOffset(94, y), UDim2.new(1, -104, 0, size + 4)
			label:SetAttribute("ForgeShellKeep", true)
			label.Parent = card
			return label
		end
		line("PlotText", spec.text, body + 2, 10, true, false)
		line("PlotDetail", spec.detail or "", body, 14 + body + 4, false, true)
		local track = Instance.new("Frame")
		track.Name, track.BorderSizePixel, track.BackgroundColor3 = "Growth", 0, Color3.fromRGB(196, 186, 166)
		track.Position, track.Size = UDim2.fromOffset(94, 22 + 2 * body + 6), UDim2.new(1, -104, 0, 8)
		local fill = Instance.new("Frame")
		fill.Name, fill.BorderSizePixel = "Fill", 0
		fill.BackgroundColor3 = if spec.ready then Color3.fromRGB(58, 128, 118) else Color3.fromRGB(122, 160, 72)
		fill.Size, fill.Parent = UDim2.fromScale(math.clamp(spec.fraction or 0, 0, 1), 1), track
		for _, bar in { track, fill } do
			local r = Instance.new("UICorner")
			r.CornerRadius, r.Parent = UDim.new(0, 4), bar
		end
		track.Parent = card
		local actions = Instance.new("Frame")
		actions.Name, actions.BackgroundTransparency = "Actions", 1
		actions.AnchorPoint, actions.Position = Vector2.new(0, 1), UDim2.new(0, 94, 1, -10)
		actions.Size, actions.Parent = UDim2.new(1, -104, 0, 44), card
		local count = #spec.cells
		for index, cell in spec.cells do
			-- The first of two cells is the picker (crop / fertilizer): a chip; the last is the action.
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
	end
	function api.destroy()
		closeConnection:Disconnect()
		gui:Destroy()
	end
	return api
end

return M
