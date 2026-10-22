--!strict
local Text = require("./MusicText")
local env: any = getfenv()
local game: any = env.game
local Instance: any = env.Instance
local Enum: any = env.Enum
local UDim2: any = env.UDim2
local Color3: any = env.Color3
local M = {}

M.ROW = 48

function M.mount(ctx: any, id: string, titleKey: string, hidden: boolean, order: number): any
	local ui = ctx.ui
	local theme = ui.theme.default
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeMusic-" .. id, false, 22, false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = ctx.playerGui or game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local sheet = ui.components.modalSheet(theme, { name = id, title = Text.text(ctx.locale, titleKey), parent = gui })
	sheet.frame.Visible = true
	if ctx.fitSheet then
		ctx.fitSheet(sheet.frame)
	end
	local opened: { () -> () } = {}
	local handle = ctx.dock({
		id = id,
		label = Text.text(ctx.locale, titleKey),
		order = order,
		hidden = hidden,
		setOpen = function(open: boolean)
			gui.Enabled = open
			if open then
				for _, callback in opened do
					callback()
				end
			end
		end,
		isOpen = function()
			return gui.Enabled
		end,
	})
	sheet.close.Activated:Connect(function()
		gui.Enabled = false
	end)
	local count = 0
	local api: any = { gui = gui, sheet = sheet, handle = handle, opened = opened }
	local function place(item: any, name: string): any
		count += 1
		item.Name, item.LayoutOrder, item.Parent = name, count, sheet.scroll
		return item
	end
	function api.label(name: string, text: string?): any
		local label = ui.components.label(theme, { text = text or "", size = UDim2.new(1, 0, 0, 48) })
		return place(label, name)
	end
	function api.button(name: string, text: string, onClick: () -> ()): any
		local button = ui.components.button(theme, { text = text, size = UDim2.new(1, 0, 0, 48), onClick = onClick })
		return place(button, name)
	end
	function api.box(name: string, placeholder: string, height: number?): any
		local box = Instance.new("TextBox")
		box.Size = UDim2.new(1, 0, 0, height or 48)
		box.ClearTextOnFocus, box.TextWrapped, box.MultiLine = false, true, (height or 48) > 48
		box.TextXAlignment, box.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
		box.PlaceholderText, box.Text, box.TextSize = placeholder, "", 15
		box.BackgroundColor3, box.TextColor3 = Color3.fromRGB(18, 28, 26), Color3.fromRGB(240, 244, 240)
		return place(box, name)
	end
	return api
end

return M
