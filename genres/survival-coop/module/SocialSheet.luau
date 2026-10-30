--!strict
-- Shared renderer for the social/home/trade sheets. A screen supplies a pure
-- `rows(locale, state, act)` list of { text, onClick? }; this module mounts the rows in a
-- docked modal sheet, sizes each row to its wrapped text (min 48 px touch target) and
-- re-renders on snapshot changes. Service-free under Lune through injected ctx.instance/udim2.
local M = {}

-- `empty` (U6): ItemIcons.ui id of a SheetCards empty card for this row.
-- `pin` (D2c R03): an action row drawn in a footer under the scroller, so it is always on screen
-- (the arrival card's Continue sat below the fold on an 800x360 phone).
export type Row = {
	text: string,
	onClick: (() -> ())?,
	icon: string?,
	empty: string?,
	hint: string?,
	pin: boolean?,
}

M.TEXT_SIZE = 15
M.MIN_ROW = 48
-- A row with an `icon` (ItemIcons.ui id) reserves this left strip for a 28px image.
M.ICON_INSET = 40
M.ICON_SIZE = 28
-- Header bar height (ui-kit modalSheet) and the pinned footer's padding.
M.HEADER = 44
M.FOOTER_PAD = 8

--- Height of the pinned footer for `rows` (0 when no row is pinned): one MIN_ROW strip of buttons.
function M.footerHeight(rows: { Row }): number
	for _, row in rows do
		if row.pin then
			return M.MIN_ROW + 2 * M.FOOTER_PAD
		end
	end
	return 0
end

-- Content width of a fitted sheet: frame minus 8 px padding each side and the 6 px scroll bar.
function M.contentWidth(sheetWidth: number): number
	return sheetWidth - 16 - 6
end

M.PADDING = 10
-- Over-estimated advance width (same rule as ui-kit HudFit.textWidth, which this place does
-- not ship): wide CJK/Hangul glyphs one em, Latin letters and digits 0.62 em, others less.
function M.textWidth(text: string, size: number): number
	local width = 0
	for _, code in utf8.codes(text) do
		if code >= 0x1100 then
			width += size
		elseif code == 32 then
			width += size * 0.3
		elseif (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) then
			width += size * 0.62
		else
			width += size * 0.35
		end
	end
	return width
end

-- Height a row needs so its wrapped text (1.2 line height plus 12 px inset) is never clipped.
function M.rowHeight(text: string, width: number): number
	local lines = 0
	for _, line in string.split(text, "\n") do
		lines += math.max(1, math.ceil(M.textWidth(line, M.TEXT_SIZE) / math.max(1, width - M.PADDING * 2)))
	end
	return math.max(M.MIN_ROW, math.ceil(lines * M.TEXT_SIZE * 1.2) + 12)
end

-- ctx: ui, dock, fitSheet, onSnapshot, locale. spec: id, title, order, rows(state) -> {Row},
-- select(extensions, packet) -> state, autoOpen(state)? -> boolean.
function M.mount(ctx: any, spec: any): any
	local env: any = getfenv()
	local components, theme = ctx.ui.components, ctx.ui.theme.default
	local udim2 = ctx.udim2 or env.UDim2
	local gui = (ctx.instance or env.Instance).new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "Forge" .. spec.name, false, spec.displayOrder or 20
	gui.Parent = ctx.playerGui or env.game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local sheet = components.modalSheet(theme, { name = spec.name, title = spec.title, parent = gui })
	sheet.frame.Visible = false
	if ctx.fitSheet then
		ctx.fitSheet(sheet.frame)
	end
	local state: any = nil
	local shown: { any } = {}
	local lastKey: string? = nil
	local render: (boolean?) -> ()
	local api: any = {}
	local footer: any = nil
	local pinnedBefore = false
	local function width(): number
		local size = sheet.frame.AbsoluteSize
		return M.contentWidth(if size and size.X > 0 then size.X else 320)
	end
	function render(force: boolean?)
		if not sheet.frame.Visible and not force then
			return
		end
		local rows: { Row } = spec.rows(state, api)
		local parts = {}
		for _, row in rows do
			table.insert(parts, row.text .. (if row.onClick then "!" else "") .. (row.icon or ""))
		end
		local key = table.concat(parts, "\n") .. "@" .. tostring(width())
		if key == lastKey and not force then
			return
		end
		lastKey = key
		for _, child in shown do
			child:Destroy()
		end
		table.clear(shown)
		local w = width()
		local make = ctx.instance or env.Instance
		local udim = ctx.udim or env.UDim
		-- Pinned action rows live in a footer strip under the scroller; the scroller ends above it.
		local footerHeight = M.footerHeight(rows)
		local pinned = 0
		for _, row in rows do
			pinned += if row.pin then 1 else 0
		end
		if footerHeight > 0 and footer == nil then
			footer = make.new("Frame")
			footer.Name, footer.BackgroundTransparency, footer.BorderSizePixel = "Footer", 1, 0
			footer.Parent = sheet.frame
		end
		if footer then
			footer.Visible = footerHeight > 0
			footer.Position = udim2.new(0, M.FOOTER_PAD, 1, -(footerHeight - M.FOOTER_PAD))
			footer.Size = udim2.new(1, -2 * M.FOOTER_PAD, 0, M.MIN_ROW)
		end
		if footerHeight > 0 or pinnedBefore then
			sheet.scroll.Size = udim2.new(1, 0, 1, -(M.HEADER + footerHeight))
		end
		pinnedBefore = footerHeight > 0
		local slot = 0
		for index, row in rows do
			if row.pin and footer then
				local props = {
					text = row.text,
					size = udim2.new(1 / pinned, if pinned > 1 then -4 else 0, 0, M.MIN_ROW),
					parent = footer,
					onClick = row.onClick,
				}
				local widget = if row.onClick then components.button(theme, props) else components.label(theme, props)
				widget.Position = udim2.new(slot / pinned, if slot > 0 then 4 else 0, 0, 0)
				widget.TextWrapped, widget.Name = true, "Row" .. index
				slot += 1
				table.insert(shown, widget)
				continue
			end
			if row.empty and ctx.instance == nil and not row.onClick then
				local size = if ctx.sheetText then ctx.sheetText("body") else 15
				local card = require("./SheetCards").empty(sheet.scroll, {
					name = "Row" .. index,
					order = index,
					icon = if ctx.icons then ctx.icons.ui(row.empty) else nil,
					title = row.text,
					hint = row.hint,
					size = size,
				})
				table.insert(shown, card)
				continue
			end
			local inset = if row.icon then M.ICON_INSET else 0
			local props = {
				text = row.text,
				size = udim2.new(1, 0, 0, M.rowHeight(row.text, w - inset)),
				parent = sheet.scroll,
				onClick = row.onClick,
			}
			local widget = if row.onClick then components.button(theme, props) else components.label(theme, props)
			widget.LayoutOrder, widget.TextWrapped, widget.Name = index, true, "Row" .. index
			if row.icon then
				local pad = make.new("UIPadding")
				pad.PaddingLeft, pad.Parent = udim.new(0, inset), widget
				local resolved = if ctx.icons then ctx.icons.ui(row.icon) else nil
				if resolved and resolved.image then
					local image = make.new("ImageLabel")
					image.Name, image.BackgroundTransparency, image.Image = "RowIcon", 1, resolved.image
					image.Size = udim2.new(0, M.ICON_SIZE, 0, M.ICON_SIZE)
					-- UIPadding shifts children too: -inset + 6 puts the icon 6px inside the row edge.
					image.Position = udim2.new(0, 6 - inset, 0.5, -M.ICON_SIZE / 2)
					image.Parent = widget
				end
			end
			table.insert(shown, widget)
		end
	end
	api.render = function()
		render(true)
	end
	-- Re-reads the rows and rebuilds only when their text changed (clock-driven screens).
	api.refresh = function()
		render()
	end
	api.open = function()
		sheet.frame.Visible = true
		render(true)
	end
	api.close = function()
		sheet.frame.Visible = false
	end
	api.isOpen = function(): boolean
		return sheet.frame.Visible == true
	end
	sheet.close.Activated:Connect(api.close)
	local handle = if ctx.dock
		then ctx.dock({
			id = spec.id,
			label = spec.title,
			order = spec.order,
			-- Context screens (NPC talk, pending settlement, match arrival/end) have no menu
			-- tile: their trigger opens them, so the menu never shows them without context.
			hidden = spec.hidden,
			setOpen = function(open: boolean)
				if open then
					api.open()
				else
					api.close()
				end
			end,
			isOpen = api.isOpen,
		})
		else nil
	api.show = function()
		if handle then
			handle.open()
		else
			api.open()
		end
	end
	local unsubscribe = ctx.onSnapshot(function(extensions: any, packet: any)
		state = spec.select(extensions or {}, packet or {}, api)
		if spec.autoOpen and spec.autoOpen(state, api) and not api.isOpen() then
			api.show()
		end
		render()
	end)
	api.destroy = function()
		unsubscribe()
		gui:Destroy()
	end
	api.state = function(): any
		return state
	end
	api.sheet = sheet
	return api
end

return M
