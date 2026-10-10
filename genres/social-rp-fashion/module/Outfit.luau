--!strict
-- Outfit: avatar slot equipping for social-rp-fashion games. Outfits live in a
-- hat/top/bottom/shoes/accessory slot map; equip validates the slot and ownership.

export type Slot = "hat" | "top" | "bottom" | "shoes" | "accessory"

export type ItemDef = {
	id: string,
	slot: Slot,
}

export type State = {
	catalog: { [string]: ItemDef },
	owned: { [string]: boolean },
	equipped: { [Slot]: string },
}

local SLOTS: { Slot } = { "hat", "top", "bottom", "shoes", "accessory" }

local Outfit = {}

local function isSlot(value: string): boolean
	for _, slot in SLOTS do
		if slot == value then
			return true
		end
	end
	return false
end

function Outfit.new(catalog: { ItemDef }, owned: { string }?): State
	if type(catalog) ~= "table" then
		error("invalid catalog")
	end
	local items: { [string]: ItemDef } = {}
	for _, def in catalog do
		if type(def.id) ~= "string" or def.id == "" then
			error("invalid item id")
		end
		if type(def.slot) ~= "string" or not isSlot(def.slot) then
			error("invalid slot")
		end
		if items[def.id] ~= nil then
			error("duplicate item id: " .. def.id)
		end
		items[def.id] = { id = def.id, slot = def.slot }
	end

	local state: State = { catalog = items, owned = {}, equipped = {} }
	if owned ~= nil then
		for _, itemId in owned do
			local def: ItemDef? = items[itemId]
			if def == nil then
				error("unknown owned item: " .. itemId)
			end
			state.owned[itemId] = true
		end
	end
	return state
end

function Outfit.isOwned(state: State, itemId: string): boolean
	return state.owned[itemId] == true
end

-- Equips an owned item into its slot, replacing whatever was there. Returns
-- (false, reason) for "unknown item" or "not owned".
function Outfit.equip(state: State, itemId: string): (boolean, string?)
	local def: ItemDef? = state.catalog[itemId]
	if def == nil then
		return false, "unknown item"
	end
	if not state.owned[itemId] then
		return false, "not owned"
	end
	state.equipped[def.slot] = itemId
	return true, nil
end

function Outfit.unequip(state: State, slot: Slot): string?
	local itemId = state.equipped[slot]
	state.equipped[slot] = nil
	return itemId
end

function Outfit.get(state: State, slot: Slot): string?
	return state.equipped[slot]
end

-- Returns a copy of the equipped slot -> item id map.
function Outfit.equipped(state: State): { [Slot]: string }
	return table.clone(state.equipped)
end

return Outfit
