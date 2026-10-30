--!strict
-- Single-player mode (game.yml play_mode.solo): every guide, tip and help line a solo player can
-- reach reads without other players. Text resolves the way the client builds it: PackText.solo over
-- locale/strings.csv (a `<key>_solo` row replaces `<key>`), in en-us and ko-kr. Guides whose steps
-- need another player (GuideEvents.MULTIPLAYER) are not shown in solo, so they are not scanned.
local fs = require("@lune/fs")
local Strings = require("../../core/infra/localization/Strings")
local PackText = require("./src/shared/PackText")
local PlayMode = require("./src/shared/PlayMode")
local content = require("./src/shared/SurvivalContent") :: any
local GuideEvents = require("../../genres/survival-coop/module/GuideEvents")
local TitleFlow = require("./src/first/TitleFlow")
local TravelScreen = require("./src/first/TravelScreen")

local csv = PackText.fromCsvRows(Strings.parseCsv(fs.readFile("games/robango-island/locale/strings.csv")).rows)
local solo = PackText.lookup(PackText.solo(csv), "")
local LOCALES = { "en-us", "ko-kr" }

-- Wording that points a solo player at other players, parties, clans, visits or player trade.
local BANNED = {
	"other player",
	"another player",
	"others can",
	"party",
	"clan",
	"invit",
	"visitor",
	"together",
	"members",
	"its owner",
	"trading post and buy",
	"파티",
	"부족",
	"클랜",
	"초대",
	"함께 짓",
	"함께 지키",
	"함께 채집",
	"함께 도착",
	"구성원",
	"다른 사람",
	"집주인",
	"방문",
	"공동",
	"교역소에 팔고",
}

-- The old lines (en) a solo player saw before this change.
local OLD = {
	"Visit the public demonstration home. Its owner has already permitted visitors.",
	"A visit does not grant building or recovery permission.",
	"List this fiber for one Coin, cancel the listing, and collect it from returns.",
	"Inspect technical support. You may preview it now, but execution opens at level sixty.",
	"Treat first, escort along the safe route, and confirm arrival before leaving.",
	"Your camp holds up to four members. Build together, keep together.",
	"Gather, craft, build, explore together.",
	"Sell spare goods at the trading post and buy what your camp lacks.",
	"Danger zone: your bag dropped here. Others can take it after ten minutes.",
	"Your contribution is recorded. You can continue alone; clan research and outpost ownership remain separate choices.",
	"Clan research refunds part of its cost when cancelled. Cancelling taming returns the animal but not the feed.",
}

--- Every key whose text a solo player can see on a guide, tip, arrival or help surface.
local function reachable(): { string }
	local keys: { string } = {}
	local function add(key: string)
		table.insert(keys, key)
	end
	-- Objective lines are optional rows (the UI falls back to the guide verb and target).
	local function addIf(key: string)
		if solo("en-us", key) then
			add(key)
		end
	end
	for _, guide in GuideEvents.visible(content, true) do
		for _, key in guide.dialogueKeys or {} do
			add(key)
		end
		add("chr.guide_" .. assert(string.match(guide.id, "^rw%.(g%d+)"), guide.id))
		for _, objective in guide.objectives do
			addIf(objective.id .. ".text")
			add("chr.guide_act_" .. string.gsub(objective.action, "%-", "_"))
			if solo("en-us", "chr.guide_target_" .. objective.target) then
				add("chr.guide_target_" .. objective.target)
			end
		end
	end
	for _, mission in content.missions or {} do
		for _, key in mission.dialogueKeys or {} do
			add(key)
		end
		for _, objective in mission.objectives do
			addIf(objective.id .. ".text")
		end
	end
	for _, chapter in content.chapters or {} do
		for _, key in chapter.dialogueKeys or {} do
			add(key)
		end
		for _, objective in chapter.objectives do
			addIf(objective.id .. ".text")
		end
		add(chapter.id .. ".title")
		add(chapter.id .. ".summary")
	end
	for _, key in TitleFlow.TIP_KEYS do
		add(key)
	end
	for _, key in TravelScreen.TIP_KEYS do
		add(key)
	end
	for index = 1, 6 do
		add(string.format("tip_%02d", index))
	end
	for _, key in
		{
			"rw.g08.market.offer", -- the market station's guide line (DialoguePanel.GUIDES)
			"scr.arrival.together",
			"scr.arrival.premise",
			"scr.jobs.terms",
			"ko_danger",
			"chr.guide_how",
			"chr.rank_guide",
		}
	do
		add(key)
	end
	return keys
end

return {
	["the game ships solo, so this scan covers the shipped text"] = function()
		assert(PlayMode.solo == true, "PlayMode.solo")
	end,
	["solo hides the guides whose steps need another player"] = function()
		local shown: { [string]: boolean } = {}
		for _, guide in GuideEvents.visible(content, true) do
			shown[guide.id] = true
		end
		for _, id in
			{
				"rw.g08.market",
				"rw.g12.route-share",
				"rw.g15.clan",
				"rw.g17.snow-preparation",
				"rw.g19.volcano-preparation",
			}
		do
			assert(not shown[id], id .. " is shown in solo")
		end
		for _, id in { "rw.g06.visit", "rw.g18.technical-support", "rw.g20.rescue-preparation", "rw.g01.first-gather" } do
			assert(shown[id], id .. " is missing in solo")
		end
		assert(#GuideEvents.visible(content, false) == #content.guides, "multiplayer keeps every guide")
	end,
	["every guide and tip string reachable in solo reads without other players"] = function()
		local keys = reachable()
		assert(#keys >= 100, "scanned keys: " .. #keys)
		local failures: { string } = {}
		for _, key in keys do
			for _, locale in LOCALES do
				local text = solo(locale, key)
				if not text or text == "" then
					table.insert(failures, key .. " has no " .. locale .. " text")
					continue
				end
				local lower = string.lower(text)
				for _, word in BANNED do
					if string.find(lower, word, 1, true) then
						table.insert(failures, key .. " (" .. locale .. ") says '" .. word .. "': " .. text)
					end
				end
				for _, old in OLD do
					if text == old then
						table.insert(failures, key .. " still shows the old line: " .. old)
					end
				end
			end
		end
		assert(#failures == 0, table.concat(failures, "\n"))
	end,
	["multiplayer keeps its own text for every _solo row"] = function()
		local plain = PackText.lookup(csv, "")
		for _, row in csv do
			if string.sub(row.key, -5) == "_solo" then
				local base = string.sub(row.key, 1, -6)
				assert(plain("en-us", base), row.key .. " has no multiplayer row " .. base)
				assert(row.en ~= "" and row.ko ~= "", row.key .. " needs en and ko")
			end
		end
		assert(
			plain("en-us", "tip_06") == "Your camp holds up to four members. Build together, keep together.",
			"multiplayer tip_06 unchanged"
		)
	end,
}
