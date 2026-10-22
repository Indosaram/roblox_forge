--!strict
-- Character/progression sheets (ui.character, ui.skill-reset, ui.island-rank, ui.personal-research,
-- ui.technical-support, ui.modify, ui.equipment): every row of each screen's real model fits the
-- fitted sheet at PC 1280x720, portrait 360x640 and short landscape 640x339, in EN and KO, and the
-- row press sends the real command and shows the localized refusal.
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local HudFit = require("../../core/ui-kit/genre/HudFit")
local Tree = require("../../core/domain/progression/SkillTree")
local Sheet = require("../../genres/survival-coop/module/CharacterSheet")
local Text = require("../../genres/survival-coop/module/CharacterText")
local Panels = require("../../genres/survival-coop/module/CharacterPanels")
local Content: any = require("./src/shared/SurvivalContent")
local EntityNames = require("./src/shared/EntityNames")

local SCREENS = {
	character = require("../../genres/survival-coop/module/CharacterPanel"),
	["skill-reset"] = require("../../genres/survival-coop/module/SkillResetPanel"),
	["island-rank"] = require("../../genres/survival-coop/module/IslandRankPanel"),
	["personal-research"] = require("../../genres/survival-coop/module/PersonalResearchPanel"),
	["technical-support"] = require("../../genres/survival-coop/module/TechnicalSupportPanel"),
	modify = require("../../genres/survival-coop/module/ModifyPanel"),
	equipment = require("../../genres/survival-coop/module/EquipmentPanel"),
}
local VIEWPORTS = { { 1280, 720, false }, { 360, 640, true }, { 640, 339, true } }
local LOCALES = { "en-us", "ko-kr" }

local function item(id: string, catalogId: string): any
	return {
		itemId = id,
		catalogId = catalogId,
		quantity = 1,
		qualityMilli = 1000,
		durabilityMilli = 100000,
		attributes = {},
	}
end

-- A rich state that exercises every row kind: learned nodes, a running research job,
-- worn gear with a support tier and one modification, and spare gear to compare.
local function data(locale: string, level: number): any
	local policy = Content.progressionPolicy.tree
	local tree: any = Tree.level(Tree.new(Content, policy), policy, level)
	tree.paid, tree.sp = { gathering_1 = 2, tailoring_1 = 2 }, tree.sp - 4
	local bag = { items = {}, reservations = {} }
	for _, entry in
		{ item("a", "axe-t1"), item("b", "crossbow-t3"), item("c", "temperate-top"), item("d", "cold-gloves") }
	do
		bag.items[entry.itemId] = entry
	end
	local Rules = require("../../genres/survival-coop/module/CharacterRules")
	local gear: any = {
		equipped = { weapon = "a", top = "c" },
		equipment = { a = Rules.record(bag.items.a), c = Rules.record(bag.items.c) },
	}
	gear.equipment.a.support, gear.equipment.a.completed = "support-tier-1", { ["support-tier-1"] = true }
	gear.equipment.c.modifications = { ["1"] = { { id = "insulation", value = 2 } } }
	return {
		content = Content,
		names = EntityNames(locale),
		survival = { balance = 1234, progression = tree, inventory = { bag = bag } },
		character = { gear = gear, points = 340, definitions = { ["rw.m1.gather"] = true }, now = 10 },
		late = {
			version = 1,
			completed = { ["research-light-1"] = true },
			receipts = {},
			jobs = { j1 = { id = "research-life-1", status = "running", cost = 100, finishAt = 60 } },
		},
	}
end

local function fits(text: string, width: number, height: number, label: string)
	assert(text ~= "", label .. " blank")
	assert(not string.find(text, "%%[ds]"), label .. " unformatted: " .. text)
	for size = 15, 11, -1 do
		local lines = 0
		for _, line in string.split(text, "\n") do
			lines += math.max(1, math.ceil(HudFit.textWidth(line, size) / (width - HudFit.PADDING * 2)))
		end
		if lines * size * 1.2 <= height then
			return
		end
	end
	error(string.format("%s overflows %dx%d: %q", label, width, height, text))
end

local function sent(): (any, (string, { any }) -> any)
	local log: any = {}
	return log,
		function(action: string, args: { any }): any
			table.insert(log, { action = action, args = args })
			return log.reply or { ok = true }
		end
end

local function find(rows: { any }, prefix: string): any
	for _, row in rows do
		if string.sub(row.name, 1, #prefix) == prefix then
			return row
		end
	end
	error("no row " .. prefix)
end

return {
	["every character screen row fits the fitted sheet at PC, portrait and landscape in EN and KO"] = function()
		for _, viewport in VIEWPORTS do
			local w, h, touch = viewport[1], viewport[2], viewport[3]
			local x, y, sw, sh = Model.contextSheet(w, h, touch)
			assert(x >= 0 and y >= 0 and x + sw <= w and y + sh <= h, "sheet clipped at " .. w)
			assert(sh >= 44 + 48, "header plus a row at " .. w .. "x" .. h)
			local rowWidth = sw - 16 - 6
			for _, locale in LOCALES do
				for level, _ in { [30] = true, [60] = true } do
					for id, screen in SCREENS do
						local rows = screen.model(locale, data(locale, level))
						assert(#rows >= 2, id .. " has content")
						local names = {}
						for _, row in rows do
							assert(not names[row.name], id .. " duplicate row " .. row.name)
							names[row.name] = true
							local at = string.format("%s/%s %s %dx%d", id, locale, row.name, w, h)
							assert(not string.find(row.text, "^[%u_]+$"), at .. " raw code")
							assert((row.height or 44) >= 44, at .. " under touch size")
							fits(row.text, rowWidth, row.height or 44, at)
						end
					end
				end
			end
		end
	end,
	["every character text key is localized in EN and KO"] = function()
		for _, key in Text.keys do
			local en, ko = Text.text("en-us", key), Text.text("ko-kr", key)
			assert(en ~= key and ko ~= key and en ~= "" and ko ~= "", key)
		end
		assert(#Panels.factories == 7, "seven screens registered")
	end,
	["skill reset confirm sends the quoted version; a stale quote shows a localized refusal"] = function()
		local d = data("ko-kr", 30)
		local confirm = find(SCREENS["skill-reset"].model("ko-kr", d), "Confirm")
		local log, send = sent()
		assert(Sheet.activate("ko-kr", confirm, send) == Text.text("ko-kr", "reset_done"), "success text")
		assert(
			log[1].action == "survival-coop:skill-reset" and log[1].args[1] == d.survival.progression.version,
			"version"
		)
		log.reply = { ok = false, reason = "STALE_QUOTE" }
		assert(Sheet.activate("ko-kr", confirm, send) == Text.text("ko-kr", "STALE_QUOTE"), "stale refusal")
		assert(find(SCREENS["skill-reset"].model("en-us", d), "Refund").text == "Refund: 4 SP", "refund shown")
		local fresh = data("en-us", 30)
		fresh.survival.progression.paid = {}
		local rows = SCREENS["skill-reset"].model("en-us", fresh)
		for _, row in rows do
			assert(row.action == nil, "nothing to reset, no confirm")
		end
	end,
	["equipment equips with comparison, unequips and opens modify/support on the worn item"] = function()
		local d = data("en-us", 60)
		local rows = SCREENS.equipment.model("en-us", d)
		local equip = find(rows, "Equip-b")
		assert(
			string.find(equip.text, "+9.75", 1, true),
			"crossbow t3 (15) vs supported axe t1 (5 x 1.05): " .. equip.text
		)
		local log, send = sent()
		Sheet.activate("en-us", equip, send)
		assert(log[1].action == "survival-coop:gear-equip" and log[1].args[1] == "b", "equip command")
		Sheet.activate("en-us", find(rows, "Unequip-top"), send)
		assert(log[2].action == "survival-coop:gear-unequip" and log[2].args[1] == "top", "unequip command")
		log.reply = { ok = false, reason = "ITEM_RESERVED" }
		assert(Sheet.activate("en-us", equip, send) == Text.text("en-us", "ITEM_RESERVED"), "refusal shown")
		Sheet.activate("en-us", find(rows, "Modify-top"), send)
		assert(Sheet.focus.item == "c", "modify focuses the worn top")
		assert(find(SCREENS.modify.model("en-us", d), "Slot-1").text == "Slot 1: +2 insulation", "slot reflected")
		Sheet.activate("en-us", find(rows, "Support-weapon"), send)
		assert(Sheet.focus.item == "a", "support focuses the worn axe")
	end,
	["research start, collect and cancel send the real job commands"] = function()
		local d = data("en-us", 30)
		local rows = SCREENS["personal-research"].model("en-us", d)
		assert(find(rows, "Line-light").text == "Light work: -2%", "current benefit")
		assert(find(rows, "R-research-life-1-cancel").text == "Cancel (refund 50)", "refund quote")
		local log, send = sent()
		Sheet.activate("en-us", find(rows, "R-research-heavy-1-start"), send)
		assert(
			log[1].action == "survival-coop:equipment-start"
				and log[1].args[1] == "research-heavy-1"
				and log[1].args[2] == "research",
			"start"
		)
		Sheet.activate("en-us", find(rows, "R-research-life-1-cancel"), send)
		assert(log[2].action == "survival-coop:equipment-cancel" and log[2].args[1] == "j1", "cancel")
		log.reply = { ok = false, reason = "STATION_GATE" }
		local refusal = Sheet.activate("ko-kr", find(rows, "R-research-heavy-1-start"), send)
		assert(refusal == Text.text("ko-kr", "STATION_GATE"), "station refusal KO")
	end,
	["technical support shows the level 60 gate and confirm targets the focused worn item"] = function()
		local low = data("en-us", 59)
		Sheet.focus.item = "a"
		local rows = SCREENS["technical-support"].model("en-us", low)
		assert(find(rows, "Gate").text == "Requires level 60 (you are 59)", "gate shown")
		assert(find(rows, "Current").text == "Current effect +5%", "current effect")
		local confirm = find(rows, "Tier-2-confirm")
		local log, send = sent()
		log.reply = { ok = false, reason = "CHARACTER_LEVEL_GATE" }
		assert(
			Sheet.activate("en-us", confirm, send) == Text.text("en-us", "CHARACTER_LEVEL_GATE"),
			"server refusal shown"
		)
		assert(
			log[1].action == "survival-coop:equipment-start"
				and log[1].args[1] == "support-tier-2"
				and log[1].args[2] == "a",
			"support start"
		)
	end,
	["modify apply sends operation, target and slot"] = function()
		local d = data("en-us", 30)
		Sheet.focus.item = "a"
		local rows = SCREENS.modify.model("en-us", d)
		assert(find(rows, "Warning").text == Text.text("en-us", "modify_warning"), "no-refund warning")
		local log, send = sent()
		Sheet.activate("en-us", find(rows, "Mod-modify-sharpness-2"), send)
		assert(log[1].action == "survival-coop:equipment-start", "modify start")
		assert(log[1].args[1] == "modify-sharpness" and log[1].args[2] == "a" and log[1].args[3] == 2, "args")
	end,
	["character and island rank reflect level, SP, rank and the award checklist"] = function()
		local d = data("en-us", 30)
		local rows = SCREENS.character.model("en-us", d)
		assert(find(rows, "Level").text == "Level 30 / 60", "level")
		assert(find(rows, "SP").text == "SP 86 available / 90 total", find(rows, "SP").text)
		assert(find(rows, "Rank").text == "Exploration rank 3 / 10", "rank")
		assert(find(rows, "OpenReset").open == "skill-reset", "reset reachable from character")
		local rank = SCREENS["island-rank"].model("en-us", d)
		assert(find(rank, "Next").text == "Next rank at 400", "next bound")
		assert(find(rank, "Lab").text == "Laboratory unlocked (rank 3)", "lab unlock")
		assert(string.find(find(rank, "Award-rw.m1.gather").text, "^Done: "), "earned award")
	end,
}
