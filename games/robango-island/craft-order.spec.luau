--!strict
-- Staging (SM-N981N, ko-kr, touch): in the craft sheet the tester tapped the Flint Hatchet row twice
-- and the second tap crafted a capture bola. Crafting changed the bag, the next snapshot re-sorted the
-- list (ready rows first, rows whose inputs ran out dropped), so the row under the finger changed
-- between taps. The order is fixed when the sheet opens (or its filter/category changes); a crafted
-- row stays in place. This runs the shipped SurvivalHUD on the panel harness.
local harness = require("./PanelHarness.fixture").harness

local function stack(id: string, catalogId: string, quantity: number): any
	return { itemId = id, catalogId = catalogId, quantity = quantity, qualityMilli = 1000, durabilityMilli = 1000 }
end

local function packet(revision: number, items: { [string]: any }): any
	local actions = {}
	for _, verb in { "craft-reserve", "recipe-mark" } do
		table.insert(actions, "survival-coop:" .. verb)
	end
	return {
		revision = revision,
		durable = { actions = actions, epochs = {} },
		snapshots = {
			["survival-coop"] = {
				balance = 0,
				vitals = { healthMilli = 90000, hungerMilli = 70000, fatigueMilli = 20000 },
				progression = { level = 2, sp = 0, xp = 0, paid = {}, version = 1 },
				inventory = {
					{
						kind = "carried",
						items = items,
						reservations = {},
						limits = { slots = 20, softWeightMilli = 40000, hardWeightMilli = 60000 },
						weightMilli = 1000,
					},
				},
			},
			survivalExtensions = {},
		},
	}
end

-- Recipe row ids in the list, top to bottom.
local function rows(frame: any): { string }
	local list = frame:FindFirstChild("PanelPanes"):FindFirstChild("ItemList")
	local found = {}
	for _, child in list:GetChildren() do
		if child.ClassName == "TextButton" and string.sub(child.Name, 1, 7) == "Recipe-" then
			table.insert(found, child)
		end
	end
	table.sort(found, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	local ids = {}
	for _, child in found do
		table.insert(ids, string.sub(child.Name, 8))
	end
	return ids
end

return {
	["a crafted recipe keeps its row while the craft sheet stays open"] = function()
		local h = harness({ width = 850, height = 411, inset = 58, touch = true, realHud = true })
		h.packet(packet(1, { a = stack("a", "flint", 2), b = stack("b", "fiber", 12) }))
		local gui = assert(h.playerGui:FindFirstChild("ForgeSurvivalHUD"), "survival hud gui")
		local frame = gui:FindFirstChild("SafeArea"):FindFirstChild("SurvivalSheet")
		h.hud.open("craft")
		h.step()
		local before = rows(frame)
		local axe = table.find(before, "stone-axe")
		assert(axe and table.find(before, "capture-bola"), "axe and bola listed: " .. table.concat(before, ","))
		-- The hatchet is crafted: its flint is spent and the axe is in the bag.
		h.packet(packet(2, { b = stack("b", "fiber", 12), c = stack("c", "stone-axe", 1) }))
		local after = rows(frame)
		assert(
			after[axe] == "stone-axe",
			string.format(
				"row %d moved under the finger: %s -> %s",
				axe,
				table.concat(before, ","),
				table.concat(after, ",")
			)
		)
		for index, id in before do
			assert(
				after[index] == id,
				"row " .. index .. " changed: " .. tostring(after[index]) .. " (was " .. id .. ")"
			)
		end
		-- Reopening the sheet sorts afresh: the spent hatchet (no flint held) leaves the short list.
		h.hud.open("craft")
		h.hud.open("craft")
		h.step()
		local reopened = rows(frame)
		assert(
			reopened[1] ~= nil and not table.find(reopened, "stone-axe"),
			"reopened order: " .. table.concat(reopened, ",")
		)
		assert(#h.errors == 0, table.concat(h.errors, "\n"))
	end,
}
