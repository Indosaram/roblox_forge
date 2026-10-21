--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local luau = require("@lune/luau")
return {
	["content categories always render primitive glyphs without Latin icon text"] = function()
		local nodes: { any } = {}
		local function node(class: string): any
			local value: any = { ClassName = class }
			function value:FindFirstChild(name)
				for _, child in nodes do
					if child.Parent == self and child.Name == name then
						return child
					end
				end
			end
			function value:Destroy()
				self.Parent = nil
			end
			table.insert(nodes, value)
			return value
		end
		local dimension = {
			new = function(...)
				return { ... }
			end,
			fromScale = function(...)
				return { ... }
			end,
		}
		local module = luau.load(fs.readFile("core/ui-kit/IconFallback.luau"), {
			environment = {
				Instance = { new = node },
				UDim2 = dimension,
				UDim = dimension,
				Color3 = {
					fromRGB = function(...)
						return { ... }
					end,
				},
			},
		})()
		local content = serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
		for _, definition in content.items do
			local badge = module.mount(node("Frame"), module.category(definition), {}, {}, nil)
			local glyph = badge:FindFirstChild("Glyph")
			assert(glyph and glyph:FindFirstChild("Shape1"), definition.id .. " has primitive glyph")
		end
		for _, category in
			{
				"food",
				"fiber",
				"wood",
				"stone",
				"tool",
				"weapon",
				"armor",
				"seed",
				"medicine",
				"building",
				"creature",
				"item",
			}
		do
			local badge = module.mount(node("Frame"), category, {}, {}, nil)
			assert(badge:FindFirstChild("Glyph"):FindFirstChild("Shape1"), category)
		end
		for _, value in nodes do
			assert(value.ClassName ~= "TextLabel", "ko-kr icon slots never contain Latin text")
		end
	end,
}
