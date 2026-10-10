--!strict
-- Specs for Outfit: slot validation, ownership checks, and slot replacement.

local Outfit = require("./Outfit")

local function newOutfit(): Outfit.State
	return Outfit.new({
		{ id = "crown", slot = "hat" },
		{ id = "tee", slot = "top" },
		{ id = "jeans", slot = "bottom" },
		{ id = "sneakers", slot = "shoes" },
		{ id = "scarf", slot = "accessory" },
	}, { "crown", "tee", "sneakers" })
end

local function expectError(fn: () -> (), message: string): ()
	local ok = pcall(fn)
	assert(not ok, "expected error: " .. message)
end

return {
	["equipping an owned item fills its slot"] = function()
		local state = newOutfit()
		assert(Outfit.equip(state, "crown"), "an owned hat equips")
		assert(Outfit.get(state, "hat") == "crown", "the hat slot is filled")
		assert(Outfit.isOwned(state, "crown"), "ownership query")
	end,

	["equip refuses unknown and unowned items"] = function()
		local state = newOutfit()
		local unknownOk, unknownReason = Outfit.equip(state, "cape")
		assert(
			not unknownOk and unknownReason == "unknown item",
			"an unknown item is refused, got " .. tostring(unknownReason)
		)
		local unownedOk, unownedReason = Outfit.equip(state, "jeans")
		assert(
			not unownedOk and unownedReason == "not owned",
			"an unowned item is refused, got " .. tostring(unownedReason)
		)
		assert(Outfit.get(state, "bottom") == nil, "the slot stays empty")
	end,

	["equipping replaces the item already in the slot"] = function()
		local state = newOutfit()
		Outfit.equip(state, "sneakers")
		assert(Outfit.equip(state, "crown"), "the crown equips into the hat slot")
		assert(Outfit.get(state, "hat") == "crown", "the hat holds the crown")
		assert(Outfit.get(state, "shoes") == "sneakers", "the shoes are untouched")
		local replaced = Outfit.unequip(state, "hat")
		assert(replaced == "crown", "unequip returns the removed item")
		assert(Outfit.get(state, "hat") == nil, "the slot is now empty")
	end,

	["the catalog rejects invalid slots and duplicate ids"] = function()
		expectError(function()
			Outfit.new({ { id = "gloves", slot = "hands" :: any } })
		end, "unknown slot")
		expectError(function()
			Outfit.new({
				{ id = "crown", slot = "hat" },
				{ id = "crown", slot = "top" },
			})
		end, "duplicate item id")
		expectError(function()
			Outfit.new({ { id = "crown", slot = "hat" } }, { "crown", "ghost" })
		end, "an owned item must exist in the catalog")
	end,
}
