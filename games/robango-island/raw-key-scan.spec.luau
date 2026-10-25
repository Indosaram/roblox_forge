--!strict
-- p120 (Studio QA p115 D1, D2, D5): the player-visible text of the clan panel, clan roles, the guide
-- panel and the craft skill refusal never shows a raw identifier: no dotted locale keys
-- (clan.relocate), no layout/target ids (rw.home-demo), no skill node ids (processing_1) and no
-- bare numeric user ids. Every surface is rendered in both locales from the shipped strings.csv.
local Fixture = require("./PackText.fixture")
local Content = require("./src/shared/SurvivalContent")
local Clan = require("../../core/domain/settlement/Clan")
local ClanPanel = require("../../genres/survival-coop/module/ClanPanel")
local Screens = require("../../genres/survival-coop/module/RecoveredScreens")
local ScreenText = require("../../genres/survival-coop/module/ScreenText")
local GuidePanel = require("../../genres/survival-coop/module/GuidePanel")
local HudLocale = require("../../genres/survival-coop/module/SurvivalHUDLocale")
ScreenText.use(Fixture.screenText)

local LOCALES = { "en-us", "ko-kr" }
local OWNER, MEMBER, OFFLINE = "11734795308", "2001002", "3003003"

-- The raw identifier in `text`, or nil.
local function raw(text: string): string?
	for _, pattern in
		{
			"%f[%w][%a][%w_%-]*%.[%a][%w_%-%.]*", -- dotted key or id: clan.relocate, rw.home-demo
			"%f[%w][%a]+_%d+%f[%W]", -- skill node: processing_1
			"%f[%w]%a+%-%a+%-[%w%-]+", -- hyphenated content id: clan-research-advanced-capture
			"%f[%d]%d%d%d%d%d%d+%f[%D]", -- bare user id (6+ digits; amounts and levels stay shorter)
		}
	do
		local hit = string.match(text, pattern)
		if hit then
			return hit
		end
	end
	return nil
end

local function scan(label: string, lines: { string }, allowed: { [string]: boolean }?)
	assert(#lines > 0, label .. ": nothing rendered")
	for _, line in lines do
		assert(line ~= "", label .. ": empty line")
		local hit = raw(line)
		assert(hit == nil or (allowed and allowed[hit]), label .. ": raw id '" .. tostring(hit) .. "' in: " .. line)
	end
end

local function clan(): any
	local state = Clan.new("tide", OWNER)
	state.members[MEMBER] = { role = "officer", withdraw = true }
	state.members[OFFLINE] = { role = "member", withdraw = false }
	state.drafts = { ["4004004"] = { role = "visitor", at = 0 } }
	state.level, state.funds, state.territory = 9, 50, "rw.harbor"
	state.jobs = {
		j1 = { definition = "clan-research-combat", status = "pending", finishAt = 90, cost = 400, jobId = "j1" },
	}
	return state
end

-- The real ClanPanel renderer on injected widgets with the client's text lookup (cli.* rows).
local function clanPanel(locale: string, state: any): { string }
	local lines: { string } = {}
	local callback: any = nil
	local function widget(_theme: any, props: any): any
		table.insert(lines, props.text)
		return {}
	end
	local node: any = {
		GetChildren = function(): any
			return {}
		end,
	}
	local client = Fixture.packText
	ClanPanel.factory({
		locale = locale,
		ui = {
			components = {
				modalSheet = function(): any
					return { frame = {}, scroll = node, close = { Activated = { Connect = function() end } } }
				end,
				label = widget,
				button = widget,
			},
			theme = { default = {} },
		},
		playerGui = {},
		actorId = OWNER,
		content = Content,
		instance = {
			new = function(): any
				return { Destroy = function() end }
			end,
		},
		udim2 = {
			new = function(): any
				return {}
			end,
			fromOffset = function(): any
				return {}
			end,
		},
		vector2 = {
			new = function(): any
				return {}
			end,
		},
		fitSheet = function() end,
		onSnapshot = function(listener: any): any
			callback = listener
			return function() end
		end,
		dock = function() end,
		icons = {
			ui = function(): any
				return {}
			end,
		},
		text = function(key: string): string
			return client(locale, "cli." .. key) or key
		end,
		encode = function(value: any): string
			return tostring(value)
		end,
		serverNow = function(): number
			return 30
		end,
	})
	table.clear(lines)
	callback({ clan = state }, { roster = { { id = OWNER, name = "Indo" }, { id = MEMBER, name = "Ari" } } })
	return lines
end

local function texts(rows: { any }): { string }
	local out = {}
	for _, row in rows do
		table.insert(out, row.text)
	end
	return out
end

return {
	["the scan itself flags every raw pattern Studio QA saw"] = function()
		for _, seen in
			{
				"clan.relocate",
				"clan-research-advanced-capture / 5000",
				"11734795308 / owner",
				"Visit rw.home-demo: 0 / 1 (tap)",
				"Learn the processing_1 skill first (Skills tab)",
			}
		do
			assert(raw(seen), "pattern misses: " .. seen)
		end
		assert(raw("Level: 9 / Funds: 50") == nil, "plain numbers pass")
	end,
	["clan panel and clan roles show no raw keys, ids or user ids in either locale"] = function()
		for _, locale in LOCALES do
			scan("clan panel " .. locale, clanPanel(locale, clan()))
			local names = { [OWNER] = "Indo", [MEMBER] = "Ari" }
			for _, actor in { OWNER, MEMBER } do
				local rows = Screens.rolesRows(locale, { clan = clan(), actorId = actor, names = names }, {})
				scan("clan roles " .. actor .. " " .. locale, texts(rows))
			end
			scan("clan roles none " .. locale, texts(Screens.rolesRows(locale, { actorId = "9" }, {})))
		end
	end,
	["guide panel objectives name places, skills and targets, never their ids"] = function()
		for _, locale in LOCALES do
			local rows = GuidePanel.model(locale, {
				content = Content,
				names = Fixture.names(locale),
				character = { level = 100, points = 1000, definitions = {}, progress = {} },
			})
			scan("guides " .. locale, texts(rows))
		end
	end,
	["craft skill refusal names the skill, never its node id"] = function()
		for _, locale in LOCALES do
			local lines = {}
			for _, detail in Content.recipeDetails or {} do
				for _, node in detail.skillNodes or {} do
					table.insert(lines, HudLocale.refusal(locale, "SKILL_NODE_GATE", HudLocale.skillName(locale, node)))
				end
			end
			scan("skill refusal " .. locale, lines)
		end
	end,
}
