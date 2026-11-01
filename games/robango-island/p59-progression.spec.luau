--!strict
-- p59 progression guidance: after the start guides a fresh player is about level 5. Route 1 now
-- opens at level 2 (Robango redesign, route p134); the waypoint walk below is kept against the
-- former level 30 gate (oldGate). Every level from 4 up to that gate must have an authored next
-- step (a guide or chapter, a support region at the harbor departure post, or the gate) within
-- contentgraph.STEP_GAP levels, and the HUD objective must name that step, not only the gate.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local graph = require("../../cli/forge/lib/contentgraph")
local Content = require("./src/shared/SurvivalContent")
local Text = require("../../genres/survival-coop/module/CharacterText")
require("./PackText.fixture") -- installs the strings.csv lookup the genre text tables read (client: Strings table)

local NAMES = { spear = "Spear", hazelnut = "Hazelnut", clam = "Clam" }

local function load(): any
	return serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
end

-- The pre-redesign route 1 gate (level 30, grade 2) on a decoded content document.
local function oldGate(document: any): any
	for _, stage in document.stages do
		if string.match(stage.id, "^rw%.a1%.") then
			stage.gates.characterLevel = 30
			stage.gates.developmentRank = 2
		end
	end
	return document
end

local function start(): { [string]: boolean }
	local done = {}
	for _, guide in Content.guides do
		if (guide.gates.developmentRank or 0) == 0 then
			done[guide.id] = true
		end
	end
	return done
end

return {
	["every level from 4 to the route 1 gate has an authored next step within the gap budget"] = function()
		assert(#graph.stepGaps(load(), 1, 1) == 0, "live route 1 gate is within the gap budget")
		local gaps = graph.stepGaps(oldGate(load()), 4, 1)
		local text = {}
		for _, gap in gaps do
			table.insert(text, string.format("L%d -> %s", gap.level, tostring(gap.next)))
		end
		assert(#gaps == 0, "levels with no next step: " .. table.concat(text, ", "))
	end,
	["the gap walk fails when only the support regions and the gate remain"] = function()
		local document = oldGate(load())
		local kept = {}
		for _, guide in document.guides do
			if guide.gates.developmentRank ~= 2 or guide.gates.characterLevel >= 30 then
				table.insert(kept, guide)
			end
		end
		document.guides, document.chapters = kept, {}
		local gaps = graph.stepGaps(document, 4, 1)
		assert(#gaps > 0 and gaps[1].level == 4 and gaps[1].next == 10, serde.encode("json", gaps))
	end,
	["the route gate stays reachable with the waypoint guides"] = function()
		for _, gate in graph.levelReachability(load()) do
			assert(gate.ok, "gate L" .. gate.gate .. " reached L" .. gate.reached .. " in " .. gate.runs .. " runs")
		end
	end,
	["after grade 2 the HUD objective names the next guide or the harbor post, never only the gate"] = function()
		local done = start()
		-- Live content: route 1 is already open at level 5 after the start guides.
		local live = Text.guideObjective("en-us", Content, { level = 5, points = 200, definitions = done }, NAMES)
		assert(live == Text.text("en-us", "guide_route_open"), tostring(live))
		local old = oldGate(load())
		-- Level 5: no waypoint is open yet; the gate line names the next guide's level.
		local five = Text.guideObjective("en-us", old, { level = 5, points = 200, definitions = done }, NAMES)
		assert(string.find(five :: string, "level 30", 1, true), tostring(five))
		assert(string.find(five :: string, "Next: guide Daily contracts at level 6", 1, true), tostring(five))
		local ko = Text.guideObjective("ko-kr", old, { level = 5, points = 200, definitions = done }, NAMES)
		assert(
			string.find(ko :: string, "레벨 30", 1, true) and string.find(ko :: string, "다음", 1, true),
			tostring(ko)
		)
		-- Level 8: the open waypoint is the objective.
		local eight = Text.guideObjective("en-us", old, { level = 8, points = 200, definitions = done }, NAMES)
		assert(
			string.find(eight :: string, "Daily contracts", 1, true) and string.find(eight :: string, "0/1", 1, true),
			tostring(eight)
		)
		-- Waypoints up to level 9 finished: the next step is the level 10 harbor departure post.
		local nine = table.clone(done)
		nine["rw.g21.daily-board"], nine["rw.g22.wilds-spear"] = true, true
		local post = Text.guideObjective("en-us", old, { level = 9, points = 200, definitions = nine }, NAMES)
		assert(string.find(post :: string, "level 10 opens Harbor > departure post", 1, true), tostring(post))
		-- Level 10: a gather objective only found in the wilds names the departure post and its level.
		local ten = Text.guideObjective("en-us", old, { level = 10, points = 200, definitions = nine }, NAMES)
		assert(
			string.find(ten :: string, "Hazelnut", 1, true)
				and string.find(ten :: string, "Harbor > departure post, level 10 area", 1, true),
			tostring(ten)
		)
		-- Every level 5..29 yields a line that is more than the bare gate.
		local gateOnly = {}
		for level = 5, 29 do
			local line = Text.guideObjective("en-us", old, { level = level, points = 200, definitions = done }, NAMES)
			if line == Text.format("en-us", "guide_route_level", 2, 30, level) then
				table.insert(gateOnly, level)
			end
		end
		assert(#gateOnly == 0, "bare gate at levels " .. table.concat(gateOnly, ","))
		local open = Text.guideObjective("en-us", old, { level = 30, points = 200, definitions = done }, NAMES)
		assert(open == Text.text("en-us", "guide_route_open"), tostring(open))
	end,
}
