--!strict
-- Shared sheet shell for the expedition-lane panels: a fitted modalSheet that renders a flat
-- list of label/button items produced by a pure panel model. Panels stay testable because
-- every decision lives in their model; this module only turns items into Instances.
local M = {}

export type Item = { kind: string, text: string, height: number, name: string?, onClick: (() -> ())? }

M.ROW = 44
M.LINE = 40

function M.mount(ctx: any, options: { name: string, title: string, dock: string?, order: number? }): any
	local ui = ctx.ui
	local theme = ui.theme.default
	local players = game:GetService("Players")
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = options.name, false, 16, false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local sheet =
		ui.components.modalSheet(theme, { name = options.name .. "Sheet", title = options.title, parent = gui })
	sheet.frame.Visible = true
	if ctx.fitSheet then
		ctx.fitSheet(sheet.frame)
	end
	local dock = if ctx.dock and options.dock
		then ctx.dock({
			id = options.dock,
			label = options.title,
			order = options.order or 9,
			setOpen = function(open: boolean)
				gui.Enabled = open
			end,
			isOpen = function()
				return gui.Enabled
			end,
		})
		else nil
	sheet.close.Activated:Connect(function()
		gui.Enabled = false
	end)
	local shell = { gui = gui, sheet = sheet, dock = dock }
	local lastKey = ""
	function shell.render(title: string, items: { Item })
		local key = title
		for _, item in items do
			key ..= "|" .. item.kind .. ":" .. item.text
		end
		if key == lastKey then
			return
		end
		lastKey = key
		local header = sheet.frame:FindFirstChild("Header")
		local label = header and header:FindFirstChild("Title")
		if label then
			label.Text = title
		end
		for _, child in sheet.scroll:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		for index, item in items do
			local size = UDim2.new(1, 0, 0, item.height)
			local node = if item.kind == "button"
				then ui.components.button(theme, { text = item.text, size = size, onClick = item.onClick })
				else ui.components.label(theme, { text = item.text, size = size })
			node.Name, node.LayoutOrder = item.name or ("Row" .. index), index
			node.TextWrapped = true
			node.Parent = sheet.scroll
		end
	end
	function shell.open(open: boolean)
		if open and dock then
			dock.open()
		else
			gui.Enabled = open
		end
	end
	return shell
end

return M
