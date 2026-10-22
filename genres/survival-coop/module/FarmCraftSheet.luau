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

function M.new(ctx: any, options: { id: string, title: string, order: number, hidden: boolean? }): any
	local Instance = ctx.instance or env.Instance
	local Enum = ctx.enum or env.Enum
	local UDim2 = ctx.udim2 or env.UDim2
	local game = ctx.game or env.game
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
	local dock = if ctx.dock
		then ctx.dock({
			id = options.id,
			label = options.title,
			order = options.order,
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
	end
	local function holder(): any
		order += 1
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
