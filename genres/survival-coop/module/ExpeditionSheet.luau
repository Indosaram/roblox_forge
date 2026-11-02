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
	local shell: any
	local dock = if ctx.dock and options.dock
		then ctx.dock({
			id = options.dock,
			label = options.title,
			order = options.order or 9,
			setOpen = function(open: boolean)
				local opening = open and not gui.Enabled
				gui.Enabled = open
				-- A tile open starts from the panel's home view (shell.onOpen, optional).
				if opening and shell.onOpen then
					shell.onOpen()
				end
			end,
			isOpen = function()
				return gui.Enabled
			end,
		})
		else nil
	shell = { gui = gui, sheet = sheet, dock = dock, onClose = nil, onOpen = nil }
	sheet.close.Activated:Connect(function()
		gui.Enabled = false
		-- The header X is a real dismissal: the panel acknowledges whatever it was showing.
		if shell.onClose then
			shell.onClose()
		end
	end)
	local lastKey = ""
	local lastShape = ""
	local built: { any } = {}
	local handlers: { [any]: (() -> ())? } = {}
	function shell.render(title: string, items: { Item })
		local key, shape = title, ""
		for index, item in items do
			key ..= "|" .. item.kind .. ":" .. item.text
			shape ..= "|" .. item.kind .. ":" .. (item.name or ("Row" .. index)) .. ":" .. item.height
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
		-- p134 v58/v59 memory: a route countdown changes every second; rebuilding every row of a
		-- hidden sheet per push churned ~170 instances/s. Same rows: update text and handlers only.
		if shape == lastShape and #built == #items then
			for index, item in items do
				built[index].Text = item.text
				handlers[built[index]] = item.onClick
			end
			return
		end
		lastShape = shape
		table.clear(built)
		table.clear(handlers)
		for _, child in sheet.scroll:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		for index, item in items do
			local size = UDim2.new(1, 0, 0, item.height)
			local node: any
			if item.kind == "button" then
				node = ui.components.button(theme, {
					text = item.text,
					size = size,
					onClick = function()
						local handler = handlers[node]
						if handler then
							handler()
						end
					end,
				})
			else
				node = ui.components.label(theme, { text = item.text, size = size })
			end
			handlers[node] = item.onClick
			node.Name, node.LayoutOrder = item.name or ("Row" .. index), index
			node.TextWrapped = true
			node.Parent = sheet.scroll
			built[index] = node
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
