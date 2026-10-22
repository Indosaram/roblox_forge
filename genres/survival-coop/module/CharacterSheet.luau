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

function M.data(extensions: any, packet: any): any
	local snapshots = (packet or {}).snapshots or {}
	return {
		survival = snapshots["survival-coop"],
		character = (extensions or {}).character,
		late = (extensions or {})["late-equipment"],
	}
end

--- What pressing a row does, without Instances: returns the status text to show
--- ("" on success without a message). `send` is ctx.send.
function M.activate(locale: string, row: Row, send: (string, { any }) -> any): string
	if row.focus ~= nil then
		M.focus.item = row.focus
	end
	if row.open then
		local handle = handles[row.open]
		if handle then
			handle.open()
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
	spec: { id: string, title: string, order: number, menu: boolean, model: (string, any) -> { Row } }
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
							status = M.activate(ctx.locale, row, ctx.send)
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
