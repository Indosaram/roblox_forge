--!strict
-- A reusable touch/keyboard-selectable inventory grid. Detail text stays in the
-- caller's scroll flow instead of a hover-only tooltip outside the safe area.
local Components = require("./Components")
local M = {}
function M.new(parent: Instance, theme: Components.Theme, selectItem: (string) -> ())
	local frame = Instance.new("Frame")
	frame.Name, frame.BackgroundTransparency = "InventoryGrid", 1
	frame.Size, frame.AutomaticSize = UDim2.new(1, -8, 0, 0), Enum.AutomaticSize.Y
	local layout = Instance.new("UIGridLayout")
	layout.CellSize, layout.CellPadding = UDim2.new(0.5, -4, 0, 64), UDim2.fromOffset(8, 8)
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
				button.Text = row.text
				button.Name, button.LayoutOrder = row.id, index
				button.TextWrapped, button.TextSize = true, 15
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
