--!strict
local ItemIcons = require("./ItemIcons")

local function resolver()
	return ItemIcons.new({
		items = { { id = "berry", name = "Berry" }, { id = "cord" } },
		materials = { { id = "berry-profile", item = "berry" } },
		recipes = { { id = "berry-meal" } },
	}, {
		["item-icon-berry"] = 123,
		["item-icon-berry-profile"] = 456,
		["item-icon-cord"] = 0,
		["recipe-icon-berry-meal"] = 789,
		["item-icon-unknown"] = 999,
	})
end

return {
	["catalog IDs resolve independent item material and recipe keys"] = function()
		local icons = resolver()
		assert(icons.item("berry").image == "rbxassetid://123", "ItemIcons invariant failed")
		assert(icons.item("berry-profile").key == "item.icon.berry-profile", "ItemIcons invariant failed")
		assert(icons.item("berry-profile").image == "rbxassetid://456", "ItemIcons invariant failed")
		assert(icons.recipe("berry-meal").key == "recipe.icon.berry-meal", "ItemIcons invariant failed")
		assert(icons.recipe("berry-meal").image == "rbxassetid://789", "ItemIcons invariant failed")
	end,
	["unpublished and absent assets retain text without an invalid image"] = function()
		local icons = resolver()
		assert(icons.item("cord").key == "item.icon.cord", "ItemIcons invariant failed")
		assert(icons.item("cord").image == nil, "ItemIcons invariant failed")
		assert(icons.item("cord").text == "cord", "ItemIcons invariant failed")
		assert(icons.item("unknown").key == nil, "ItemIcons invariant failed")
		assert(icons.item("unknown").image == nil, "ItemIcons invariant failed")
		assert(icons.item("unknown").text == "unknown", "ItemIcons invariant failed")
		assert(icons.recipe("unknown", "Localized label").text == "Localized label", "ItemIcons invariant failed")
	end,
	["material profiles preserve the item fallback and localized labels win"] = function()
		local icons = resolver()
		assert(icons.item("berry-profile").text == icons.item("berry").text, "ItemIcons invariant failed")
		assert(icons.item("berry", "Localized label").text == "Localized label", "ItemIcons invariant failed")
	end,
	["catalogs without material profiles and missing publications are supported"] = function()
		local icons = ItemIcons.new({ items = { { id = "wood" } }, recipes = { { id = "plank" } } }, {})
		assert(icons.item("wood").key == "item.icon.wood", "ItemIcons invariant failed")
		assert(icons.item("wood").image == nil, "ItemIcons invariant failed")
		assert(icons.recipe("plank").image == nil, "ItemIcons invariant failed")
	end,
	["generated asset strings accept published IDs and reject local-only paths"] = function()
		local catalog = { items = { { id = "wood" }, { id = "cord" }, { id = "stone" } }, recipes = {} }
		local icons = ItemIcons.new(catalog, {
			["item-icon-wood"] = "rbxassetid://123",
			["item-icon-cord"] = "rbxasset://forge/robango-island/cord.png",
			["item-icon-stone"] = "rbxassetid://0",
		})
		assert(icons.item("wood").image == "rbxassetid://123", "published image must resolve")
		assert(icons.item("cord").image == nil, "local paths must retain text fallback")
		assert(icons.item("stone").image == nil, "zero IDs must retain text fallback")
	end,
}
