--!strict
-- Bag room (journey6h @124.5 min, L43): a full bag refused every gather and the bag sheet's
-- 'Drop 5' tapped eight times never emptied a stack, so no slot came free (a slot frees only when
-- the whole stack leaves). Drop now arms a confirm that drops every unreserved unit of the stack.
-- The 30-slot bag was full by L29 (~47 min) with 28 distinct kinds the guided path hands out, so
-- the free bag is 40 slots; paid capacity stays home storage only (Wide Warehouse).
local harness = require("./PanelHarness.fixture").harness
local Content: any = require("./src/shared/SurvivalContent")
local CapacityPolicy = require("../../core/domain/survival/CapacityPolicy")
local Locale = require("../../genres/survival-coop/module/SurvivalHUDLocale")

local function stack(id: string, catalogId: string, quantity: number): any
	return {
		itemId = id,
		catalogId = catalogId,
		quantity = quantity,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = {},
	}
end

local function find(root: any, name: string): any?
	for _, item in root:GetDescendants() do
		if item.Name == name then
			return item
		end
	end
	return nil
end

return {
	["Drop in the bag sheet asks once, then drops the whole unreserved stack so a slot frees"] = function()
		local sent = {}
		local h = harness({
			width = 1280,
			height = 720,
			realHud = true,
			locale = "ko-kr",
			invoke = function(_remote: any, kind: string, body: any)
				if kind == "command" then
					table.insert(sent, body)
				end
				return { ok = true, stateVersion = 2 }
			end,
		})
		h.packet({
			revision = 1,
			durable = {
				actions = { "survival-coop:item-drop", "survival-coop:transfer-deposit" },
				epochs = { ["survival-coop:item-drop"] = 1, ["survival-coop:transfer-deposit"] = 1 },
			},
			snapshots = {
				["survival-coop"] = {
					vitals = { healthMilli = 90000, hungerMilli = 90000, fatigueMilli = 0 },
					progression = { level = 36, sp = 0, xp = 0, paid = {}, version = 1 },
					inventory = {
						bag = {
							kind = "carried",
							-- 50 wood, 3 of them held by a craft reservation.
							items = { w = stack("w", "wood", 50) },
							reservations = { job = { w = 3 } },
							limits = { slots = 40, softWeightMilli = 60000, hardWeightMilli = 90000 },
							weightMilli = 25000,
						},
					},
				},
				survivalExtensions = {},
			},
		})
		h.hud.open("bag")
		h.step()
		local drop = assert(find(h.playerGui, "Drop-w"), "Drop on the selected stack")
		h.click(drop)
		assert(#sent == 0, "the first tap only asks: " .. #sent)
		local confirm = assert(find(h.playerGui, "DropConfirm-w"), "the confirm replaces Drop")
		assert(string.find(confirm.Text, "47", 1, true), "the confirm names the count: " .. confirm.Text)
		h.click(confirm)
		assert(#sent == 1, "the confirm sends one drop")
		assert(sent[1].action == "survival-coop:item-drop", tostring(sent[1].action))
		assert(sent[1].args[1] == "w" and sent[1].args[2] == 47, "every unreserved unit: " .. tostring(sent[1].args[2]))
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
	["the free bag holds what the first hours hand out, and paid capacity stays home storage"] = function()
		-- journey6h bag at L29 (47.9 min): 28 distinct kinds in 30 slots (two split stacks), 7 of them
		-- tools; more kinds arrive with every guide after it (temperate set, kiln, copper, bone work).
		assert(Content.limits.slots == 40, "free bag slots: " .. tostring(Content.limits.slots))
		assert(CapacityPolicy.forVersion(2).bagSlots >= Content.limits.slots, "the v2 policy admits the bag")
		-- Home storage (where the Wide Warehouse adds +10) keeps its own, separate ceiling.
		assert(CapacityPolicy.forVersion(2).homeSlots == 45, "home storage ceiling unchanged")
	end,
	["a craft collect that does not fit names the bag's Drop button as the way to make room"] = function()
		-- The finished job stays Ready (Workshop.spec); the refusal must point at the button that frees
		-- a slot anywhere, by its shipped label, not only at the warehouse.
		for _, locale in { "ko-kr", "en-us" } do
			local line, button = Locale.refusal(locale, "FULL_SLOTS"), Locale.text(locale, "drop")
			assert(button ~= "drop", "the Drop label ships in " .. locale)
			assert(string.find(line, button, 1, true), locale .. " refusal names '" .. button .. "': " .. line)
		end
	end,
}
