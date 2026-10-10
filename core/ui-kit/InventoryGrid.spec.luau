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
			UDim2 = {
				new = function(...)
					return { ... }
				end,
				fromOffset = function(...)
					return { ... }
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
	f.grid.update({ { id = "spear", text = "Spear 100%" }, { id = "berry", text = "Berry x3" } }, "berry")
	local spear, berry = f.button("spear"), f.button("berry")
	assert(
		spear and berry and spear.BackgroundTransparency == 0.4 and berry.BackgroundTransparency == 0,
		"initial selection"
	)
	local callback = spear.callback
	f.down(spear)
	f.grid.update({ { id = "berry", text = "Berry x2" }, { id = "spear", text = "Spear 99%" } }, "spear")
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
