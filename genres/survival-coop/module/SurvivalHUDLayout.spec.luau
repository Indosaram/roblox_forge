--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
return {
	["ingredient output and build cost rows keep glyph name and counts separate"] = function()
		local source = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		local first = assert(string.find(source, "local function materialRow", 1, true))
		local last = assert(string.find(source, "local function selectedDefinition", first, true))
		local nodes: { any } = {}
		local function label(_theme: any, props: any): any
			local value: any = { Parent = props.parent }
			function value:FindFirstChild(name)
				for _, child in nodes do
					if child.Parent == self and child.Name == name then
						return child
					end
				end
			end
			table.insert(nodes, value)
			return value
		end
		local dimension = {
			new = function(xs, xo, ys, yo)
				return { X = { Scale = xs, Offset = xo }, Y = { Scale = ys, Offset = yo } }
			end,
			fromOffset = function(x, y)
				return { X = { Scale = 0, Offset = x }, Y = { Scale = 0, Offset = y } }
			end,
		}
		local row = luau.load(string.sub(source, first, last - 1) .. "return materialRow", {
			environment = {
				label = function()
					return label(nil, {})
				end,
				Components = { label = label },
				theme = {},
				options = {},
				name = function(id)
					return id
				end,
				itemIcon = function() end,
				fitText = function() end,
				UDim2 = dimension,
				Color3 = {
					fromRGB = function(...)
						return { ... }
					end,
				},
				Enum = { TextXAlignment = { Left = "Left", Right = "Right" } },
			},
		})()
		for _, viewport in { 360, 1920 } do
			local width = if viewport == 360 then 288 else 320
			for _, available in { 0, 12 } do
				local item = row("fiber", available, 6)
				local title, count = item:FindFirstChild("RowName"), item:FindFirstChild("RowCount")
				local contentWidth = width - 40
				local titleRight = title.Position.X.Offset + title.Size.X.Scale * contentWidth + title.Size.X.Offset
				local countLeft = count.Position.X.Scale * contentWidth + count.Position.X.Offset
				assert(titleRight <= countLeft and titleRight > 0, "name and count do not overlap")
				assert(countLeft + count.Size.X.Offset <= contentWidth, "right-aligned count fits")
				assert(count.TextXAlignment == "Right", "count alignment")
			end
		end
		local card = label(nil, {})
		local chip = row("wood", 12, 6, card)
		assert(chip == row("wood", 3, 6, card), "build card cost chip retains identity")
		assert(chip:FindFirstChild("RowCount").Text == "3/6", "build cost refreshes have/need")
	end,
}
