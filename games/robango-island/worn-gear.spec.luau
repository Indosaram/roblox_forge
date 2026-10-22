--!strict
-- Worn gear takes effect; the same gear only carried in the bag does not.
local Rules = require("../../genres/survival-coop/module/CharacterRules")
local Gathering = require("../../genres/survival-coop/module/Gathering")
local Content: any = require("./src/shared/SurvivalContent")
local Inventory = require("../../core/domain/inventory/Inventory")
local Catalog = require("../../core/domain/inventory/ItemCatalog")

local function item(id: string, catalogId: string): any
	return {
		itemId = id,
		catalogId = catalogId,
		quantity = 1,
		qualityMilli = 1000,
		durabilityMilli = 1000,
		attributes = {},
	}
end
local function bag(items: { any }): any
	local out: any = { id = "bag", items = {}, reservations = {} }
	for _, entry in items do
		out.items[entry.itemId] = entry
	end
	return out
end
local function wear(b: any, ...: string): any
	local state: any = { equipped = {}, equipment = {} }
	for _, id in { ... } do
		state = assert(Rules.equip(state, b, id))
	end
	return state
end
local CARRIED: any = { equipped = {}, equipment = {} }

return {
	["worn clothing feeds the climate exposure calculation; carried clothing does not"] = function()
		local b = bag({ item("t", "cold-top"), item("h", "cold-head") })
		local worn = wear(b, "t", "h")
		assert(Rules.resistanceMilli(Content, worn, b, "cold") > 0, "worn cold resistance")
		assert(Rules.resistanceMilli(Content, CARRIED, b, "cold") == 0, "carried gives none")
		assert(Rules.resistanceMilli(Content, worn, b, "heat") == 0, "cold gear is not heat gear")
		local vitals = { health = 100, fatigue = 0, buffs = {} }
		local bare = Rules.climate(Content, CARRIED, b, vitals, 0, 10, "cold", 5, false)
		local dressed = Rules.climate(Content, worn, b, vitals, 0, 10, "cold", 5, false)
		assert(dressed.health > bare.health and dressed.fatigue < bare.fatigue, "worn gear reduces exposure")
		b.items.t = nil
		assert(
			Rules.resistanceMilli(Content, worn, b, "cold")
				< Rules.resistanceMilli(
					Content,
					wear(bag({ item("t", "cold-top"), item("h", "cold-head") }), "t", "h"),
					bag({ item("t", "cold-top"), item("h", "cold-head") }),
					"cold"
				),
			"sold gear stops counting"
		)
	end,
	["worn armor reduces combat damage; carried armor does not"] = function()
		local b = bag({ item("t", "cold-top"), item("s", "cold-shoes") })
		local worn = wear(b, "t", "s")
		assert(Rules.mitigate(Content, CARRIED, b, 10000) == 10000, "carried: full damage")
		local reduced = Rules.mitigate(Content, worn, b, 10000)
		assert(reduced < 10000 and reduced >= 10000 - 10000 * Rules.MAX_ARMOR_PERMILLE // 1000, "worn: reduced, capped")
	end,
	["worn weapon adds its performance to combat damage; carried weapon does not"] = function()
		local b = bag({ item("a", "axe-t2"), item("k", "axe-t1") })
		local worn = wear(b, "a")
		assert(Rules.weaponDamage(Content, CARRIED, b, "a", 8000) == 8000, "carried base only")
		assert(Rules.weaponDamage(Content, worn, b, "a", 8000) > 8000, "worn adds performance")
		assert(Rules.weaponDamage(Content, worn, b, "k", 8000) == 8000, "other weapon is not the worn one")
	end,
	["worn tool satisfies a gather tool check; carried tool does not"] = function()
		-- Tool policy lives on the node instance; any catalog node with a declared tag works.
		local node: any = { id = Content.nodes[1].id, requiredToolTag = "cutting" }
		local tool: any = nil
		for _, definition in Content.items do
			if
				not tool
				and table.find(definition.tags, node.requiredToolTag)
				and Rules.slotOf(definition.id) == "weapon"
			then
				tool = definition
			end
		end
		assert(tool, "a wearable tool for " .. node.requiredToolTag)
		local b: any =
			Inventory.new("bag", { contentVersion = 2, slots = 30, softWeightMilli = 60000, hardWeightMilli = 90000 })
		b = assert(Inventory.add(b, Catalog.new(Content.items), {
			itemId = "x",
			catalogId = tool.id,
			quantity = 1,
			qualityMilli = 1000,
			durabilityMilli = 1000,
			attributes = {},
		}, b.version))
		local function gather(gear: any)
			local held = Rules.toolEvidence(gear, b, {})
			local state: any = {
				worldRevision = "w",
				version = 0,
				nodes = {
					n = {
						id = "n",
						catalogId = node.id,
						charges = 1,
						qualityMilli = 1000,
						requiredToolTag = node.requiredToolTag,
						position = { x = 0, y = 0, z = 0 },
					},
				},
			}
			local access: any = {
				actorId = "1",
				carriedContainer = "bag",
				worldRevision = "w",
				reachable = function()
					return true
				end,
				equipment = function()
					return held
				end,
			}
			return Gathering.gather(
				state,
				b,
				{ actorId = "1", sessionEpoch = 1, requestId = "g" },
				Content,
				"n",
				0,
				access
			)
		end
		local _, carried = gather(CARRIED)
		assert(carried == "TOOL_UNAVAILABLE", "carried tool refused: " .. tostring(carried))
		local _, worn = gather(wear(b, "x"))
		assert(worn ~= "TOOL_UNAVAILABLE", "worn tool accepted: " .. tostring(worn))
	end,
	["dressing plan attaches one light part per worn slot"] = function()
		local b = bag({ item("a", "axe-t1"), item("t", "cold-top") })
		local plan = Rules.dressing(wear(b, "a", "t"), b)
		assert(#plan == 2 and plan[1].slot == "top" and plan[2].slot == "weapon", "slot order")
		assert(plan[2].part == "RightHand" and plan[2].fallback == "Right Arm", "R15 with R6 fallback")
		assert(#Rules.dressing(CARRIED, b) == 0, "carried gear is not shown")
	end,
	["archipelago cells carry layout bounds and their stage rank gate"] = function()
		local cells = Rules.cells(Content, 2)
		assert(#cells >= 16, "one cell per archipelago stage layout")
		for _, cell in cells do
			assert(cell.width > 0 and cell.depth > 0, cell.id .. " bounds")
			assert(cell.bounds.max.x > cell.bounds.min.x, cell.id .. " ordered")
		end
		assert(cells[1].id == "rw.a1.s1" and cells[1].rank == 2 and cells[1].open, "first cell rank 2 open at rank 2")
		local locked = 0
		for _, cell in cells do
			locked += if cell.open then 0 else 1
		end
		assert(locked > 0, "later cells need a higher rank")
	end,
}
