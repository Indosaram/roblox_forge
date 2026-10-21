--!strict
-- A reusable touch/keyboard-selectable inventory grid. Detail text stays in the
-- caller's scroll flow instead of a hover-only tooltip outside the safe area.
local Components = require("./Components")
local IconFallback = require("./IconFallback")
local M = {}
function M.new(parent: Instance, theme: Components.Theme, selectItem: (string) -> ())
	local frame = Instance.new("Frame")
	frame.Name, frame.BackgroundTransparency = "InventoryGrid", 1
	frame.Size, frame.AutomaticSize = UDim2.new(1, -8, 0, 0), Enum.AutomaticSize.Y
	local layout = Instance.new("UIGridLayout")
	layout.CellSize, layout.CellPadding = UDim2.new(0.333, -6, 0, 92), UDim2.fromOffset(8, 8)
	layout.SortOrder, layout.Parent = Enum.SortOrder.LayoutOrder, frame
	frame.Parent = parent
	local buttons: { [string]: TextButton } = {}
	return {
		frame = frame,
		update = function(rows: { any }, selected: string?)
			local present: { [string]: boolean } = {}
			for index, row in rows do
				present[row.id] = true
				local button = buttons[row.id]
				if not button then
					local id = row.id
					button = Components.button(theme, {
						text = row.text,
						size = UDim2.fromOffset(140, 64),
						parent = frame,
						onClick = function()
							selectItem(id)
						end,
					})
					buttons[id] = button
				end
				button.Text = ""
				local caption = button:FindFirstChild("Caption") :: TextLabel?
				if not caption then
					local created = Instance.new("TextLabel")
					created.Name, created.BackgroundTransparency = "Caption", 1
					created.Size, created.Position = UDim2.new(1, -8, 0, 42), UDim2.fromOffset(4, 46)
					created.TextColor3, created.TextSize, created.TextWrapped = Color3.fromRGB(240, 244, 240), 12, true
					created.Parent = button
					caption = created
				end
				assert(caption, "SLOT_CAPTION_REQUIRED")
				caption.Text = row.text
				IconFallback.mount(button, row.category, UDim2.fromOffset(36, 36), UDim2.new(0.5, -18, 0, 6), row.image)
				local quantity = button:FindFirstChild("Quantity") :: TextLabel?
				if not quantity then
					local created = Instance.new("TextLabel")
					created.Name, created.BackgroundTransparency = "Quantity", 0.1
					created.BackgroundColor3, created.TextColor3 =
						Color3.fromRGB(18, 28, 26), Color3.fromRGB(240, 244, 240)
					created.Size, created.Position = UDim2.fromOffset(32, 20), UDim2.new(1, -34, 0, 6)
					created.Parent = button
					quantity = created
				end
				assert(quantity, "SLOT_QUANTITY_REQUIRED")
				quantity.Text = tostring(row.quantity or "")
				button.Name, button.LayoutOrder = row.id, index
				button.TextWrapped, button.TextSize = true, 12
				button.BackgroundTransparency = if row.id == selected then 0 else 0.4
			end
			for id, button in buttons do
				if not present[id] then
					button:Destroy()
					buttons[id] = nil
				end
			end
		end,
	}
end
return M
