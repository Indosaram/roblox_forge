--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local function fixture(source: string): any
	local created: { any } = {}
	local selected = {}
	local pressed: any = nil
	local function instance(className: string): any
		local value: any = { ClassName = className, destroyed = false }
		function value:Destroy()
			self.destroyed = true
			self.Parent = nil
		end
		function value:GetChildren()
			local children = {}
			for _, child in created do
				if child.Parent == self and not child.destroyed then
					table.insert(children, child)
				end
			end
			return children
		end
		function value:FindFirstChild(name: string): any
			for _, child in self:GetChildren() do
				if child.Name == name then
					return child
				end
			end
			return nil
		end
		table.insert(created, value)
		return value
	end
	local components = {
		button = function(_theme, config)
			local button = instance("TextButton")
			button.Text, button.Parent, button.callback = config.text, config.parent, config.onClick
			return button
		end,
	}
	local module = luau.load(source, {
		environment = {
			require = function(name)
				assert(name == "./Components", "only production Components dependency")
				return components
			end,
			Instance = { new = instance },
			UDim = {
				new = function(scale, offset)
					return { Scale = scale, Offset = offset }
				end,
			},
			UDim2 = {
				new = function(xs, xo, ys, yo)
					return { X = { Scale = xs, Offset = xo }, Y = { Scale = ys, Offset = yo } }
				end,
				fromOffset = function(x, y)
					return { X = { Scale = 0, Offset = x }, Y = { Scale = 0, Offset = y } }
				end,
			},
			Enum = { AutomaticSize = { Y = "Y" }, SortOrder = { LayoutOrder = "LayoutOrder" } },
		},
	})()
	local grid = module.new(instance("Frame"), {}, function(id)
		table.insert(selected, id)
	end)
	return {
		grid = grid,
		selected = selected,
		button = function(id)
			for _, value in grid.frame:GetChildren() do
				if value.ClassName == "TextButton" and value.Name == id then
					return value
				end
			end
			return nil
		end,
		down = function(button)
			assert(not button.destroyed and button.Parent == grid.frame, "press requires live attached button")
			pressed = button
		end,
		release = function(button): boolean
			local target = pressed
			pressed = nil
			if target ~= button or button.destroyed or button.Parent ~= grid.frame then
				return false
			end
			button.callback()
			return true
		end,
	}
end

local function regression(source: string): boolean
	local f = fixture(source)
	local rows: { { id: string, text: string, image: string? } } = {
		{ id = "spear", text = "Spear 100%", image = "rbxassetid://123" },
		{ id = "berry", text = "Berry x3" },
	}
	f.grid.update(rows, "berry")
	local spear, berry = f.button("spear"), f.button("berry")
	assert(
		spear and berry and spear.BackgroundTransparency == 0.4 and berry.BackgroundTransparency == 0,
		"initial selection"
	)
	local icon = spear:FindFirstChild("ItemIcon")
	assert(
		icon and icon.ClassName == "ImageLabel" and icon.Image == "rbxassetid://123" and icon.Visible,
		"item icon created"
	)
	assert(icon.Size.X.Offset == 36 and icon.Position.Y.Offset == 14, "icon dimensions")
	assert(spear:FindFirstChild("IconPadding").PaddingLeft.Offset == 44, "icon reserves text padding")
	assert(berry:FindFirstChild("ItemIcon") == nil, "imageless row needs no icon")
	local callback = spear.callback
	f.down(spear)
	f.grid.update({ { id = "berry", text = "Berry x2" }, { id = "spear", text = "Spear 99%" } }, "spear")
	assert(
		spear:FindFirstChild("ItemIcon") == icon and not icon.Visible and tostring(icon.Image) == "",
		"imageless update hides retained icon"
	)
	assert(spear:FindFirstChild("IconPadding").PaddingLeft.Offset == 0, "imageless update resets padding")
	assert(f.release(spear), "snapshot during press must activate the original live button")
	assert(f.button("spear") == spear and spear.callback == callback, "same identity preserves object and handler")
	assert(f.selected[1] == "spear" and #f.selected == 1, "press targets original item exactly once")
	assert(
		spear.Text == "Spear 99%" and spear.LayoutOrder == 2 and spear.BackgroundTransparency == 0,
		"text order and selection updated"
	)
	assert(
		f.button("berry") == berry and berry.Text == "Berry x2" and berry.BackgroundTransparency == 0.4,
		"other retained item updated"
	)
	f.down(spear)
	f.grid.update({ { id = "berry", text = "Berry x2" } }, nil)
	assert(spear.destroyed and f.button("spear") == nil, "missing item destroys button")
	assert(not f.release(spear) and #f.selected == 1, "destroyed press cannot activate")
	f.grid.update({ { id = "spear", text = "Replacement spear" } }, "spear")
	local replacement = f.button("spear")
	assert(
		replacement ~= spear and not replacement.destroyed and replacement.callback ~= callback,
		"readded item receives new live handler"
	)
	assert(berry.destroyed, "second missing item removed")
	f.down(replacement)
	assert(
		f.release(replacement) and f.selected[2] == "spear" and #f.selected == 2,
		"replacement click reaches correct item"
	)
	return true
end

local specs = {
	["inventory snapshot preserves live press identity and refreshes retained rows"] = function()
		regression(fs.readFile("core/ui-kit/InventoryGrid.luau"))
	end,
}
if process.args[1] == "--run" then
	specs["inventory snapshot preserves live press identity and refreshes retained rows"]()
	print("PASS current production InventoryGrid")
elseif process.args[1] == "--before" then
	local previous = process.exec("git", { "show", "821a380^:core/ui-kit/InventoryGrid.luau" })
	assert(previous.ok, previous.stderr)
	local ok, err = pcall(regression, previous.stdout)
	assert(
		not ok and string.find(tostring(err), "snapshot during press must activate the original live button", 1, true),
		"pre-fix production must fail at lost activation: " .. tostring(err)
	)
	print("EXPECTED_PRE_FIX_FAILURE " .. tostring(err))
end
return specs
