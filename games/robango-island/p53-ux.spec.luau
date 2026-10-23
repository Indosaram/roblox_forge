--!strict
-- p51 Studio journey minor findings (p53): HUD objective leads to the start guides then the route
-- gate, donation and delivery show a success line, the guide tile is on the first menu row, and a
-- hand craft is one click (reserve -> start -> collect chained by the HUD).
local fs = require("@lune/fs")
local Content = require("./src/shared/SurvivalContent")
local Text = require("../../genres/survival-coop/module/CharacterText")
local Contracts = require("../../genres/survival-coop/module/ContractsPanel")
local Camp = require("../../genres/survival-coop/module/CampPanelModel")
local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
local HUDModel = require("../../genres/survival-coop/module/SurvivalHUDModel")
local Locale = require("../../genres/survival-coop/module/SurvivalHUDLocale")

local MODULE = "genres/survival-coop/module/"
local FIBER = { fiber = "Fiber" }

return {
	["after the axe the HUD objective names the next start guide, then the route gate"] = function()
		local after = { tutorial = { step = "declare-settlement", hint = "tutorial.declare-settlement" } }
		local steps: { { any } } = {
			{ { definitions = {}, progress = { ["rw.g01.first-gather.1"] = 1 } }, "Fiber", "E", "1/3" },
			{ { points = 50, definitions = { ["rw.g01.first-gather"] = true } }, "any axe", "Craft", "0/1" },
			{
				{ points = 100, definitions = { ["rw.g01.first-gather"] = true, ["rw.g02.first-axe"] = true } },
				"contract",
				"Contracts",
				"0/1",
			},
			{
				{
					points = 150,
					definitions = {
						["rw.g01.first-gather"] = true,
						["rw.g02.first-axe"] = true,
						["rw.g03.first-contract"] = true,
					},
				},
				"camp",
				"Camp",
				"0/1",
			},
		}
		for _, step in steps do
			local guide = Text.guideObjective("en-us", Content, step[1], FIBER)
			local view = Contracts.model("en-us", after, {}, guide)
			for index = 2, 4 do
				assert(
					string.find(view.objective, step[index], 1, true),
					"missing " .. step[index] .. ": " .. view.objective
				)
			end
			assert(not string.find(view.objective, "settlement", 1, true), "no settlement build: " .. view.objective)
			local ko = Text.guideObjective("ko-kr", Content, step[1], FIBER)
			assert(ko and string.find(ko, "메뉴", 1, true) or string.find(ko :: string, "E", 1, true), tostring(ko))
		end
		local graded = Text.guideObjective("ko-kr", Content, { level = 5, points = 200 }, FIBER)
		assert(
			string.find(graded :: string, "레벨 30", 1, true) and string.find(graded :: string, "항로", 1, true),
			tostring(graded)
		)
		local open = Text.guideObjective("en-us", Content, { level = 30, points = 200 }, FIBER)
		assert(open == Text.text("en-us", "guide_route_open"), tostring(open))
		-- The first steps keep their own hints (gather tracker, pinned axe).
		local early = Contracts.model(
			"en-us",
			{ tutorial = { step = "craft-stone-axe", hint = "tutorial.craft-stone-axe" } },
			{},
			"x"
		)
		assert(early.objective == Contracts.text("en-us", "tutorial.craft-stone-axe"), early.objective)
	end,
	["a donation and a delivery show a success line, and a newly finished guide is announced"] = function()
		local row: any = { id = "p", label = "p", delivered = 0, need = 70, locked = false, costs = {} }
		assert(Camp.given("en-us", "Fiber", 1, "Signal pile", row) == "Gave Fiber x1: Signal pile 1/70", "en")
		assert(Camp.given("ko-kr", "섬유", 2, "신호 더미", row) == "섬유 2개 기부: 신호 더미 2/70", "ko")
		local seen = {}
		assert(Text.newGuides("en-us", seen, { definitions = { ["rw.g01.first-gather"] = true } }) == nil, "baseline")
		local line = Text.newGuides(
			"en-us",
			seen,
			{ definitions = { ["rw.g01.first-gather"] = true, ["rw.g04.camp-donation"] = true } }
		)
		assert(line == "Guide complete: Camp donation", tostring(line))
		local camp, contracts = fs.readFile(MODULE .. "CampPanel.luau"), fs.readFile(MODULE .. "ContractsPanel.luau")
		assert(
			string.find(camp, "Model.given(", 1, true) and string.find(camp, "Text.newGuides(", 1, true),
			"camp wires both"
		)
		assert(string.find(contracts, '"contracts_delivered"', 1, true), "delivery success line")
		local csv = fs.readFile("games/robango-island/locale/strings.csv")
		for _, key in
			{
				"camp_given",
				"ct_contracts_delivered",
				"guide_complete",
				"guide_next",
				"guide_route_level",
				"guide_route_open",
				"guide_go_gather",
				"guide_go_craft",
				"guide_go_deliver",
				"guide_go_donate",
				"hud_make",
			}
		do
			assert(string.find(csv, "\n" .. key .. ",", 1, true), key .. " missing from strings.csv")
		end
	end,
	["the guide tile is the first menu tile and on the first row at 1076x632, 1280x700 and 360x640"] = function()
		local source = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		local ids: { { any } } = {}
		local factories = fs.readFile(MODULE .. "ExtensionPanels.luau") .. fs.readFile(MODULE .. "CharacterPanels.luau")
		for name in string.gmatch(factories, 'require%("%./(%u%w+)"%)') do
			local text = fs.readFile(MODULE .. name .. ".luau")
			for id, order in string.gmatch(text, 'id = "([%w-]+)",[^}]-order = (%d+)') do
				table.insert(ids, { id, tonumber(order) })
			end
		end
		for id in string.gmatch(source, '\n\t\t{\n\t\t\tid = "([%w-]+)"') do
			table.insert(ids, { id, 1 })
		end
		-- Positional mounts (navigator "메뉴" tile, music screens): Sheet.mount(ctx, id, title, hidden, order).
		for _, name in { "NavigatorPanel", "MusicScreens" } do
			local text = fs.readFile(MODULE .. name .. ".luau")
			for id, order in string.gmatch(text, 'Sheet%.mount%(ctx, "([%w-]+)", "[%w_]+", %a+, (%-?%d+)%)') do
				table.insert(ids, { id, tonumber(order) })
			end
		end
		local navigator = false
		for _, entry in ids do
			navigator = navigator or entry[1] == "navigator"
		end
		assert(#ids > 20 and navigator, "tile ids parsed: " .. #ids)
		local guides = string.match(fs.readFile(MODULE .. "GuidePanel.luau"), 'id = "guides",[^}]-order = (%-?%d+)')
		local guide = Panels.tileOrder("guides", assert(tonumber(guides), "guide order"))
		-- The guide tile is the first tile: strictly lower LayoutOrder than every other tile.
		for _, entry in ids do
			assert(
				entry[1] == "guides" or Panels.tileOrder(entry[1], entry[2]) > guide,
				`{entry[1]} tile sorts at or before the guide tile`
			)
		end
		local before = 0
		for _, viewport in { { 1076, 632, false }, { 1280, 700, false }, { 360, 640, true } } do
			local width, height = viewport[1], viewport[2] - (if viewport[3] then 56 else 0)
			local x, y, w, h, columns, tile = Panels.menuRect(width, height, viewport[3])
			h = select(4, HUDModel.chatSafe(width, height, x, y, w, h))
			local row = before // columns
			assert(
				(row + 1) * (tile + Panels.MENU_GAP) <= h,
				`guide row {row} below the fold at {viewport[1]}x{viewport[2]}`
			)
		end
	end,
	["a hand craft is one click: reserve chains start, start chains collect; station crafts do not"] = function()
		local hand = {}
		local recipes = { { id = "cord", craftMillis = 3000 } }
		local reserve = { action = "survival-coop:craft-reserve", args = { "cord", "hand" } }
		local verb, args, wait = HUDModel.handChain(reserve, { ok = true, data = { jobId = "j" } }, hand, recipes)
		assert(verb == "craft-start" and args and args[1] == "j" and wait == 0, "start chained")
		local start = { action = "survival-coop:craft-start", args = { "j" } }
		verb, args, wait = HUDModel.handChain(start, { ok = true }, hand, recipes)
		assert(verb == "craft-complete" and wait and wait >= 3, "collect after craftMillis")
		local complete = { action = "survival-coop:craft-complete", args = { "j" } }
		assert(
			HUDModel.handChain(complete, { ok = false, reason = "NOT_READY" }, hand, recipes) == "craft-complete",
			"retry early"
		)
		assert(HUDModel.handChain(complete, { ok = true }, hand, recipes) == nil and hand.j == nil, "done")
		local station = { action = "survival-coop:craft-reserve", args = { "cord", "station-1" } }
		assert(
			HUDModel.handChain(station, { ok = true, data = { jobId = "s" } }, hand, recipes) == nil,
			"station stays manual"
		)
		assert(HUDModel.handChain(start, { ok = true }, {}, recipes) == nil, "a manual start is not chained")
		local hud = fs.readFile(MODULE .. "SurvivalHUD.luau")
		assert(string.find(hud, "Model.handChain(request", 1, true), "HUD chains results")
		assert(Locale.text("ko-kr", "make") ~= "make", "make label")
	end,
}
