--!strict
-- ui.equipment: six clothing slots + weapon/tool, stats, tech tier and mods; equip with comparison delta, unequip, open modify/support.
local Rules = require("./CharacterRules")
local Text = require("./CharacterText")
local Sheet = require("./CharacterSheet")
local M = {}

M.EQUIP = "survival-coop:gear-equip"
M.UNEQUIP = "survival-coop:gear-unequip"

local function signed(value: number): string
	local rounded = math.floor(value * 100 + 0.5) / 100
	return (if rounded >= 0 then "+" else "") .. tostring(rounded)
end

local function tier(record: any): number
	local n = 0
	for id in record.completed or {} do
		n = math.max(n, tonumber(string.match(id, "(%d+)$")) or 0)
	end
	return n
end

function M.model(locale: string, data: any): { Sheet.Row }
	local content, survival, character = data.content, data.survival, data.character
	local bag = survival and survival.inventory and survival.inventory.bag
	if not content or not bag then
		return { { name = "Empty", text = Text.text(locale, "char_failed") } }
	end
	local names = data.names or {}
	local gear = (character and character.gear) or { equipped = {}, equipment = {} }
	local worn = Rules.worn(gear, bag)
	local rows: { Sheet.Row } = {}
	local total = { performance = 0, armor = 0, cold = 0, heat = 0 }
	for _, record in worn do
		local stats = Rules.stats(content, record)
		for key in total do
			total[key] += stats[key]
		end
	end
	table.insert(rows, {
		name = "Stats",
		text = Text.format(
			locale,
			"equip_stats",
			signed(total.performance),
			total.armor,
			signed(total.cold),
			signed(total.heat)
		),
	})
	for _, slot in Rules.SLOTS do
		local record = worn[slot]
		local label = Text.text(locale, "slot_" .. slot)
		table.insert(rows, {
			name = "Slot-" .. slot,
			text = Text.format(
				locale,
				"equip_slot",
				label,
				if record then names[record.catalogId] or record.catalogId else Text.text(locale, "modify_empty")
			),
		})
		if record then
			local mods = 0
			for _ in record.modifications or {} do
				mods += 1
			end
			table.insert(rows, { name = "Tier-" .. slot, text = Text.format(locale, "equip_tier", tier(record), mods) })
			table.insert(rows, {
				name = "Unequip-" .. slot,
				text = Text.format(locale, "equip_unequip", label),
				action = M.UNEQUIP,
				args = { slot },
			})
			table.insert(rows, {
				name = "Modify-" .. slot,
				text = Text.format(locale, "equip_modify", label),
				open = "modify",
				focus = record.itemId,
			})
			table.insert(rows, {
				name = "Support-" .. slot,
				text = Text.format(locale, "equip_support", label),
				open = "technical-support",
				focus = record.itemId,
			})
		end
	end
	local ids = {}
	for id, item in bag.items do
		if Rules.slotOf(item.catalogId) and gear.equipped[Rules.slotOf(item.catalogId) :: string] ~= id then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	for _, id in ids do
		local item = bag.items[id]
		local slot = Rules.slotOf(item.catalogId) :: string
		local candidate = gear.equipment[id] or Rules.record(item)
		local delta = Rules.compare(content, worn[slot], candidate)
		local main = if slot == "weapon" then signed(delta.performance) else signed(delta.armor)
		table.insert(rows, {
			name = "Equip-" .. id,
			text = Text.format(locale, "equip_button", names[item.catalogId] or item.catalogId, main),
			action = M.EQUIP,
			args = { id },
		})
	end
	return rows
end

function M.factory(ctx: any): any
	return Sheet.mount(ctx, {
		id = "equipment",
		title = "equip_title",
		order = 2,
		menu = true,
		model = function(l, d)
			d.content, d.names = ctx.content, ctx.names
			return M.model(l, d)
		end,
	})
end

return M
