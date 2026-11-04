--!strict
-- journey6h ~105 min: guide g13 'inspect laboratory' stalled at home. The step is a guide-sheet
-- acknowledgement the server accepts only within reach of station.laboratory.t1, which stands at the
-- harbor; the HUD line said only '(Menu > Guides)' and the row refused with the generic 'move
-- closer'. A place-bound step names its isle on the HUD and in the row's refusal, and in the isle
-- that holds the anchor the HUD guide step drives the waypoint to it. The g16 home storage steps
-- and the g20 bandage assembly are performed from their guide rows.
local roblox: any = require("@lune/roblox")
local Content: any = require("./src/shared/SurvivalContent")
local Text = require("../../genres/survival-coop/module/CharacterText")
local GuideEvents = require("../../genres/survival-coop/module/GuideEvents")
local GuidePanel = require("../../genres/survival-coop/module/GuidePanel")
local Sheet = require("../../genres/survival-coop/module/CharacterSheet")
local Harness = require("./PanelHarness.fixture")
local NAMES = require("./PackText.fixture").names

local function guide(id: string): any
	for _, g in Content.guides do
		if g.id == id then
			return g
		end
	end
	error(id)
end

-- Every guide before `id` (in HUD order) done: the HUD line is that guide's first open step.
local function at(id: string, progress: any?): any
	local definitions = {}
	for _, g in GuideEvents.visible(Content, true) do
		if g.id == id then
			break
		end
		definitions[g.id] = true
	end
	local gates = guide(id).gates
	return {
		level = gates.characterLevel,
		points = gates.developmentRank * 100,
		definitions = definitions,
		progress = progress or {},
	}
end

local function row(rows: { any }, name: string): any
	for _, entry in rows do
		if entry.name == name then
			return entry
		end
	end
	error("no row " .. name)
end

return {
	["a place-bound guide-sheet step names its isle on the HUD and in the row's refusal"] = function()
		for _, case in
			{
				{ "rw.g13.lab", "물결 항구", "Tide Harbor", "rw.g13.lab.1" },
				{ "rw.g20.rescue-preparation", "물결 항구", "Tide Harbor", "rw.g20.rescue-preparation.2" },
				{ "rw.g16.refrigeration", "나의 섬", "Home isle", "rw.g16.refrigeration.1" },
			}
		do
			local progress = {}
			for _, o in guide(case[1]).objectives do
				if o.id == case[4] then
					break
				end
				progress[o.id] = o.quantity
			end
			local ch = at(case[1], progress)
			local ko, objective = Text.guideObjective("ko-kr", Content, ch, NAMES("ko-kr"), true)
			assert(objective and objective.id == case[4], case[1] .. ": " .. tostring(ko))
			assert(ko and string.find(ko, case[2], 1, true), "ko HUD names the isle: " .. tostring(ko))
			local en = Text.guideObjective("en-us", Content, ch, NAMES("en-us"), true)
			assert(en and string.find(en, case[3], 1, true), "en HUD names the isle: " .. tostring(en))
		end
		-- The g13 row: tapping it away from the harbor shows where to go, not 'move closer'.
		local rows = GuidePanel.model("ko-kr", { content = Content, character = at("rw.g13.lab"), solo = true })
		local lab = row(rows, "Objective-rw.g13.lab.1")
		assert(lab.action == GuideEvents.ACT, "the row sends guide-act")
		local status = Sheet.activate("ko-kr", lab, function(): any
			return { ok = false, reason = "OUT_OF_RANGE" }
		end)
		assert(string.find(status, "물결 항구", 1, true), "refusal names the harbor: " .. status)
		assert(status ~= Text.refusal("ko-kr", "OUT_OF_RANGE"), "not the generic refusal")
		assert(GuideEvents.where(Content, "inspect", "laboratory") == "rw.harbor", "the laboratory is at the harbor")
		assert(GuideEvents.where(Content, "activate", "rw.harbor.rescue-beacon") == "rw.harbor", "beacon")
		assert(GuideEvents.where(Content, "inspect-rate", "refrigerator") == nil, "the fridge rate: anywhere")
		assert(GuideEvents.where(Content, "deposit", "berry") == "rw.home", "home storage")
	end,
	["the g16 storage rows run the home transfer and g20's assembly opens the Practice sheet"] = function()
		local home = {
			homeId = "home:1",
			storage = { items = { s1 = { itemId = "s1", catalogId = "berry", quantity = 1 } } },
		}
		local bag = {
			kind = "carried",
			items = { b1 = { itemId = "b1", catalogId = "berry", quantity = 2 } },
			reservations = {},
		}
		local data = {
			content = Content,
			character = at("rw.g16.refrigeration"),
			home = home,
			survival = { inventory = { bag } },
			solo = true,
		}
		local rows = GuidePanel.model("en-us", data)
		local deposit = row(rows, "Objective-rw.g16.refrigeration.1")
		assert(deposit.action == "survival-coop:home-deposit", tostring(deposit.action))
		assert(deposit.args[1] == "home:1" and deposit.args[2].itemId == "b1", "the bag berry goes home")
		data.character.progress = { ["rw.g16.refrigeration.1"] = 1, ["rw.g16.refrigeration.2"] = 1 }
		local retrieve = row(GuidePanel.model("en-us", data), "Objective-rw.g16.refrigeration.3")
		assert(retrieve.action == "survival-coop:home-withdraw" and retrieve.args[2].itemId == "s1", "take out")
		local status = Sheet.activate("en-us", retrieve, function(): any
			return { ok = false, reason = "OUT_OF_RANGE" }
		end)
		assert(string.find(status, "Home isle", 1, true), "refusal names home: " .. status)
		local g20 = row(
			GuidePanel.model("en-us", { content = Content, character = at("rw.g20.rescue-preparation"), solo = true }),
			"Objective-rw.g20.rescue-preparation.1"
		)
		assert(g20.open == "operations", "assemble opens the Practice sheet")
		local en = Text.guideObjective("en-us", Content, at("rw.g20.rescue-preparation"), NAMES("en-us"), true)
		assert(en and string.find(en, "Make", 1, true), "HUD names Make: " .. tostring(en))
	end,
	["at the harbor the g13 HUD step points the waypoint at the laboratory"] = function()
		local anchorId = "station.laboratory.t1"
		local lab: any = nil
		for _, layout in Content.layouts do
			for _, anchor in if layout.id == "rw.harbor" then layout.anchors else {} do
				lab = if anchor.id == anchorId then anchor.position else lab
			end
		end
		assert(lab, "the harbor laboratory anchor")
		local h = Harness.harness({ width = 800, height = 360, realHud = true })
		local world = h.new("Folder", "ForgeRoleWorld")
		world:SetAttribute("ForgeLayoutId", "rw.harbor")
		world.Parent = h.workspace
		local character = h.new("Model", "Character")
		local root = h.new("Part", "HumanoidRootPart")
		root.Position, root.Parent = roblox.Vector3.new(lab.x + 60, lab.y, lab.z + 40), character
		character.Parent = h.workspace
		h.player.Character = character
		h.publish({
			contracts = { tutorial = { step = "declare-settlement", hint = "tutorial.declare-settlement" } },
			character = at("rw.g13.lab"),
		})
		local function find(name: string): any
			for _, item in h.playerGui:GetDescendants() do
				if item.Name == name then
					return item
				end
			end
			return nil
		end
		local line = assert(find("ObjectiveTracker"), "HUD tracker").Text
		assert(string.find(line, "물결 항구", 1, true), "the HUD line is the g13 step: " .. line)
		local beam = assert(find("WaypointBeam") or h.workspace:FindFirstChild("WaypointBeam", true), "beam")
		assert(beam.Parent ~= nil, "a beam marks the laboratory")
		local p = beam.CFrame.Position
		assert(math.abs(p.X - lab.x) < 0.01 and math.abs(p.Z - lab.z) < 0.01, "beam on the laboratory")
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
	-- journey6h 102.7 min: g14's first HUD step read 'place-training dodo' to a player whose only dodo
	-- was tamed in g41 (nothing to put in the pen, and the line fell back to '(Menu > Guides)': the
	-- hyphenated action never matched its guide_go_place_training row). g14 now starts with the
	-- capture, names the species and where it roams, then the pen step reads its own row.
	["g14 taming names the capture first, the species by name and the pen step's own sheet"] = function()
		local g14 = guide("rw.g14.taming")
		assert(g14.objectives[1].action == "capture", "g14 starts with the capture")
		local species = g14.objectives[1].target
		assert(g14.objectives[2].action == "place-training" and g14.objectives[2].target == species, "same species")
		for _, case in
			{
				{ "ko-kr", "콤프소그나투스", "항로 1", "메뉴 > 길들이기" },
				{ "en-us", "Compsognathus", "Route 1", "Menu > Taming" },
			}
		do
			local line = Text.guideObjective(case[1], Content, at("rw.g14.taming"), NAMES(case[1]), true)
			assert(
				line and string.find(line, case[2], 1, true),
				"the capture line names the species: " .. tostring(line)
			)
			assert(string.find(line, case[3], 1, true), "the capture line names where it roams: " .. line)
			local pen = Text.guideObjective(
				case[1],
				Content,
				at("rw.g14.taming", { [g14.objectives[1].id] = 1 }),
				NAMES(case[1]),
				true
			)
			assert(pen and string.find(pen, case[2], 1, true), "the pen line names the species: " .. tostring(pen))
			assert(string.find(pen, case[4], 1, true), "the pen line opens the taming sheet: " .. pen)
		end
	end,
}
