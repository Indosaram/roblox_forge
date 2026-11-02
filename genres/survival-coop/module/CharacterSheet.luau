--!strict
-- Shared scaffold for the character/progression sheets. Each screen module supplies a pure
-- `model(locale, data)` -> rows; this mounts it as a docked, fitted modal sheet, sends row
-- commands through ctx.send and shows localized refusals. `data` is assembled from the packet:
-- survival = snapshots["survival-coop"], character / late = survivalExtensions entries.
local Text = require("./CharacterText")
local M = {}

export type Row = {
	name: string,
	text: string,
	height: number?,
	action: string?,
	args: { any }?,
	open: string?,
	focus: any?,
	enabled: boolean?,
	success: string?,
}

-- Shared between screens: the item the equipment sheet hands to modify/support.
M.focus = {} :: { item: string? }
local handles: { [string]: any } = {}

--- Opens a mounted character sheet by id (the HUD's skill reset opens the quote dialog).
function M.open(id: string): boolean
	local handle = handles[id]
	if handle then
		handle.open()
	end
	return handle ~= nil
end

function M.data(extensions: any, packet: any): any
	local snapshots = (packet or {}).snapshots or {}
	return {
		survival = snapshots["survival-coop"],
		home = (extensions or {}).home,
		character = (extensions or {}).character,
		late = (extensions or {})["late-equipment"],
	}
end

--- What pressing a row does, without Instances: returns the status text to show
--- ("" on success without a message). `send` is ctx.send; `open` (ctx.open) opens a panel that
--- is not a character sheet (party, camp, clan roles).
function M.activate(locale: string, row: Row, send: (string, { any }) -> any, open: ((string) -> boolean)?): string
	if row.focus ~= nil then
		M.focus.item = row.focus
	end
	if row.open then
		local handle = handles[row.open]
		if handle then
			handle.open()
		elseif open then
			open(row.open)
		end
		if not row.action then
			return ""
		end
	end
	if not row.action then
		return ""
	end
	if row.enabled == false then
		return ""
	end
	local result = send(row.action, row.args or {})
	if type(result) ~= "table" or not result.ok then
		return Text.refusal(locale, if type(result) == "table" then result.reason else nil)
	end
	return if row.success then Text.text(locale, row.success) else ""
end

function M.mount(
	ctx: any,
	spec: {
		id: string,
		title: string,
		order: number,
		menu: boolean,
		model: (string, any) -> { Row },
		-- U6 SheetCards above the rows: key, row names they replace, builder (run on key change).
		cards: ((
			locale: string,
			data: any,
			size: number,
			width: number
		) -> (string, { [string]: boolean }, (Instance) -> ()))?,
	}
): { destroy: () -> () }?
	local ui = ctx.ui
	local theme = ui.theme.default
	local players = game:GetService("Players")
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "Forge-" .. spec.id, false, 20, false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local sheet = ui.components.modalSheet(theme, {
		name = spec.id .. "-sheet",
		title = Text.text(ctx.locale, spec.title),
		parent = gui,
	})
	sheet.frame.Visible = true
	if ctx.fitSheet then
		ctx.fitSheet(sheet.frame)
	end
	local data: any = {}
	local status = ""
	local shown: { Instance } = {}
	local lastKey = ""
	local function render(force: boolean?)
		if not gui.Enabled and not force then
			return
		end
		local rows = spec.model(ctx.locale, data)
		local hide: { [string]: boolean } = {}
		if spec.cards and ctx.icons then
			local holder = sheet.scroll:FindFirstChild("Cards")
			if not holder then
				holder = Instance.new("Frame")
				holder.Name, holder.BackgroundTransparency, holder.LayoutOrder = "Cards", 1, -1
				holder.Size, holder.AutomaticSize = UDim2.new(1, -6, 0, 0), Enum.AutomaticSize.Y
				local stack = Instance.new("UIListLayout")
				stack.SortOrder, stack.Padding, stack.Parent = Enum.SortOrder.LayoutOrder, UDim.new(0, 8), holder
				holder.Parent = sheet.scroll
			end
			local size = if ctx.sheetText then ctx.sheetText("body") else 15
			local width = math.max(240, sheet.frame.AbsoluteSize.X - 40)
			local cardKey, hidden, build = spec.cards(ctx.locale, data, size, width)
			hide = hidden
			cardKey ..= "@" .. size .. "x" .. width
			if holder:GetAttribute("ForgeCardKey") ~= cardKey then
				for _, old in holder:GetChildren() do
					if not old:IsA("UIListLayout") then
						old:Destroy()
					end
				end
				build(holder)
				holder:SetAttribute("ForgeCardKey", cardKey)
			end
			local kept = {}
			for _, row in rows do
				if not hide[row.name] then
					table.insert(kept, row)
				end
			end
			rows = kept
		end
		if status ~= "" then
			table.insert(rows, 1, { name = "Status", text = status, height = 44 })
		end
		local parts = {}
		for _, row in rows do
			table.insert(parts, row.name .. "=" .. row.text .. tostring(row.enabled))
		end
		local key = table.concat(parts, "|")
		if key == lastKey and not force then
			return
		end
		lastKey = key
		for _, item in shown do
			item:Destroy()
		end
		table.clear(shown)
		for index, row in rows do
			local size = UDim2.new(1, -6, 0, row.height or 44)
			local control: any
			if row.action or row.open then
				control = ui.components.button(theme, {
					text = row.text,
					size = size,
					onClick = function()
						status = Text.text(ctx.locale, "char_working")
						render(true)
						task.spawn(function()
							status = M.activate(ctx.locale, row, ctx.send, ctx.open)
							render(true)
						end)
					end,
				})
				if row.enabled == false then
					control.AutoButtonColor, control.BackgroundTransparency = false, 0.5
				end
			else
				control = ui.components.label(theme, { text = row.text, size = size })
			end
			control.Name, control.LayoutOrder, control.TextWrapped = row.name, index, true
			control.Parent = sheet.scroll
			table.insert(shown, control)
		end
	end
	local dock = if ctx.dock
		then ctx.dock({
			id = spec.id,
			label = Text.text(ctx.locale, spec.title),
			order = spec.order,
			setOpen = function(open: boolean)
				gui.Enabled = open
				if open then
					status = ""
					render(true)
				end
			end,
			isOpen = function()
				return gui.Enabled
			end,
		})
		else nil
	if dock then
		dock.setAvailable(spec.menu)
		handles[spec.id] = dock
	end
	sheet.close.Activated:Connect(function()
		gui.Enabled = false
	end)
	local unsubscribe = ctx.onSnapshot(function(extensions, packet)
		data = M.data(extensions, packet)
		render()
	end)
	return {
		destroy = function()
			handles[spec.id] = nil
			unsubscribe()
			gui:Destroy()
		end,
	}
end

return M
