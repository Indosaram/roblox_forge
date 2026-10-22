--!strict
-- Shared renderer for the social/home/trade sheets. A screen supplies a pure
-- `rows(locale, state, act)` list of { text, onClick? }; this module mounts the rows in a
-- docked modal sheet, sizes each row to its wrapped text (min 48 px touch target) and
-- re-renders on snapshot changes. Service-free under Lune through injected ctx.instance/udim2.
local M = {}

export type Row = { text: string, onClick: (() -> ())? }

M.TEXT_SIZE = 15
M.MIN_ROW = 48

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
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "Forge" .. spec.name, false, 20
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
			table.insert(parts, row.text .. (if row.onClick then "!" else ""))
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
		for index, row in rows do
			local props = {
				text = row.text,
				size = udim2.new(1, 0, 0, M.rowHeight(row.text, w)),
				parent = sheet.scroll,
				onClick = row.onClick,
			}
			local widget = if row.onClick then components.button(theme, props) else components.label(theme, props)
			widget.LayoutOrder, widget.TextWrapped, widget.Name = index, true, "Row" .. index
			table.insert(shown, widget)
		end
	end
	api.render = function()
		render(true)
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
