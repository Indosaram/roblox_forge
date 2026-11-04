--!strict
-- p134 v74 phone acceptance (SM-N981N, ko-kr, touch) defects: fresh-player HUD flow.
local Content = require("./src/shared/SurvivalContent")
local Text = require("../../genres/survival-coop/module/CharacterText")
local GuideEvents = require("../../genres/survival-coop/module/GuideEvents")
local Harness = require("./PanelHarness.fixture")
local roblox: any = require("@lune/roblox")
require("./PackText.fixture") -- installs the strings.csv lookup the genre text tables read

local NAMES = { fiber = "고사리 섬유", creature = "동물" }

-- A fresh player off the opening: the four grade-paying start guides done (grade 2, level 4), the
-- first capture (band 0, pays no grade) still open.
local function offOpening(): any
	return {
		level = 4,
		points = 200,
		definitions = {
			["rw.g01.first-gather"] = true,
			["rw.g02.first-axe"] = true,
			["rw.g03.first-contract"] = true,
			["rw.g04.camp-donation"] = true,
		},
		progress = {},
	}
end

local function find(h: any, name: string): any
	for _, item in h.playerGui:GetDescendants() do
		if item.Name == name then
			return item
		end
	end
	return nil
end

-- journey6h @80.4: L38, the rank-6 band open (g13 laboratory at the harbor, g14 taming whose
-- capture happens on the Route 1 drift isles); every earlier guide done.
local function rankSix(): any
	local definitions = {}
	for _, g in GuideEvents.visible(Content, true) do
		if ((g.gates or {}).characterLevel or 1) < 38 then
			definitions[g.id] = true
		end
	end
	return { level = 38, points = 650, definitions = definitions, progress = {} }
end

return {
	["journey6h @80.4: a 'guide complete' flash rides under the next step, never replacing it"] = function()
		local h = Harness.harness({ width = 800, height = 360, realHud = true })
		local world = h.new("Folder", "ForgeRoleWorld")
		world:SetAttribute("ForgeLayoutId", "rw.home")
		world.Parent = h.workspace
		local before = rankSix()
		before.definitions["rw.g21.daily-board"] = nil
		local contracts = { tutorial = { step = "declare-settlement", hint = "tutorial.declare-settlement" } }
		h.publish({ contracts = contracts, character = before })
		-- g21 completes: the next snapshot flashes its completion.
		h.publish({ contracts = contracts, character = rankSix() })
		local line = assert(find(h, "ObjectiveTracker"), "HUD tracker").Text
		local done = Text.format("ko-kr", "guide_complete", Text.text("ko-kr", "guide_g21"))
		assert(string.find(line, done, 1, true), "the completion shows: " .. line)
		assert(string.find(line, "물결 항구", 1, true), "the next step (g13 at the harbor) stays: " .. line)
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
	["journey6h @80.5: on a drift isle the second line is the step done there, not the harbor laboratory"] = function()
		local h = Harness.harness({ width = 800, height = 360, realHud = true })
		h.workspace:SetAttribute("ForgeWorldRole", "archipelago")
		local world = h.new("Folder", "ForgeRoleWorld")
		world:SetAttribute("ForgeLayoutId", "rw.a1.s1")
		world.Parent = h.workspace
		local character = h.new("Model", "Character")
		local root = h.new("Part", "HumanoidRootPart")
		root.Parent = character
		character.Parent = h.workspace
		h.player.Character = character
		h.publish({
			archipelago = { status = "active", templateId = "rw.a1", stage = 1, progress = {}, completed = {} },
			character = rankSix(),
		})
		local line = assert(find(h, "ObjectiveTracker"), "HUD tracker").Text
		local second = assert(string.match(line, "\n(.+)$"), "a guide line under the stage: " .. line)
		assert(string.find(second, Text.text("ko-kr", "guide_g14"), 1, true), "g14's capture: " .. second)
		assert(not string.find(second, Text.text("ko-kr", "guide_g13"), 1, true), second)
		-- Without a layout, unlock order still leads with g13.
		local any = Text.guideStep("ko-kr", Content, rankSix(), NAMES, true, true)
		assert(any and string.find(any, Text.text("ko-kr", "guide_g13"), 1, true), tostring(any))
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
	["v74 #8: at the harbor the HUD names the still-open first capture, with route 1 on the next line"] = function()
		local ch = offOpening()
		local ko, objective = Text.guideObjective("ko-kr", Content, ch, NAMES, true, true)
		assert(ko, "a line")
		local first, second = string.match(ko :: string, "^([^\n]+)\n([^\n]+)$")
		assert(first and second, "two lines: " .. tostring(ko))
		assert(string.find(first, Text.text("ko-kr", "guide_g31"), 1, true), "first line is the capture: " .. first)
		assert(second == Text.text("ko-kr", "guide_route_open"), "route 1 on the second line: " .. second)
		assert(objective and objective.action == "capture", "the line's objective is the capture step")
		-- Once the capture is done the line moves on (route 1 or the next band), never back to it.
		ch.definitions["rw.g31.first-capture"] = true
		local after = Text.guideObjective("ko-kr", Content, ch, NAMES, true, true) :: string
		assert(not string.find(after, Text.text("ko-kr", "guide_g31"), 1, true), after)
		-- The opening order is untouched: a fresh player still reads the first gather first.
		local fresh = Text.guideObjective("ko-kr", Content, { level = 1, points = 0 }, NAMES, true, true) :: string
		assert(string.find(fresh, Text.text("ko-kr", "guide_g01"), 1, true), fresh)
	end,
	["v74 #8: on a drift isle the HUD keeps the stage objective and adds the next guide step"] = function()
		local delayed: { any } = {}
		local h = Harness.harness({ width = 800, height = 360, realHud = true, delayed = delayed })
		h.workspace:SetAttribute("ForgeWorldRole", "archipelago")
		local character = h.new("Model", "Character")
		local root = h.new("Part", "HumanoidRootPart")
		root.Parent = character
		character.Parent = h.workspace
		h.player.Character = character
		local ch = offOpening()
		h.publish({
			archipelago = { status = "active", templateId = "rw.a1", stage = 1, progress = {}, completed = {} },
			character = ch,
		})
		local line = assert(find(h, "ObjectiveTracker"), "HUD tracker").Text
		assert(string.find(line, "목표: ", 1, true), "the stage objective leads: " .. line)
		local second = string.match(line, "\n(.+)$")
		assert(second, "a second line under the stage objective: " .. line)
		assert(string.find(second, Text.text("ko-kr", "guide_g31"), 1, true), "the capture step: " .. second)
		-- After the capture the second line follows the next guide (the second pet at L12).
		ch.definitions["rw.g31.first-capture"] = true
		ch.level = 12
		h.publish({
			archipelago = { status = "active", templateId = "rw.a1", stage = 1, progress = {}, completed = {} },
			character = ch,
		})
		-- The 'guide complete' flash holds the tracker for a few seconds; run its expiry.
		for _, job in table.clone(delayed) do
			job.fn(table.unpack(job.args, 1, job.args.n))
		end
		h.step()
		local later = assert(find(h, "ObjectiveTracker"), "HUD tracker").Text
		assert(string.find(later, "\n", 1, true), "still a guide line: " .. later)
		assert(not string.find(later, Text.text("ko-kr", "guide_g31"), 1, true), later)
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
	["v74 #7: the drift-isle stage objective points the waypoint and 'show the way' at its fallen logs"] = function()
		local isle: any = nil
		for _, layout in Content.layouts do
			isle = if layout.id == "rw.a1.s1" then layout else isle
		end
		local wood: any = nil
		for _, node in isle.resourceNodes do
			wood = if node.item == "wood" then node.position else wood
		end
		assert(wood, "route 1 isle 1 has a wood node")
		local h = Harness.harness({ width = 800, height = 360, realHud = true })
		h.workspace:SetAttribute("ForgeWorldRole", "archipelago")
		local world = h.new("Folder", "ForgeRoleWorld")
		world:SetAttribute("ForgeLayoutId", "rw.a1.s1")
		world.Parent = h.workspace
		local character = h.new("Model", "Character")
		local root = h.new("Part", "HumanoidRootPart")
		root.Position, root.Parent = roblox.Vector3.new(wood.x + 60, wood.y, wood.z + 40), character
		character.Parent = h.workspace
		h.player.Character = character
		local ch = offOpening()
		ch.definitions["rw.g31.first-capture"] = true
		h.publish({
			archipelago = { status = "active", templateId = "rw.a1", stage = 1, progress = {}, completed = {} },
			character = ch,
		})
		local line = assert(find(h, "ObjectiveTracker"), "HUD tracker").Text
		assert(string.find(line, "0/5", 1, true), "the stage objective: " .. line)
		local beam = assert(find(h, "WaypointBeam") or h.workspace:FindFirstChild("WaypointBeam", true), "beam")
		assert(beam.Parent ~= nil, "a beam marks the stage target")
		local at = beam.CFrame.Position
		assert(math.abs(at.X - wood.x) < 0.01 and math.abs(at.Z - wood.z) < 0.01, "beam on the wood node")
		local tap = assert(find(h, "OpeningTrackerTap"), "quest card tap")
		assert(tap.Visible, "the stage card offers the walk")
		h.click(tap)
		assert(assert(find(h, "OpeningShowWay"), "show the way").Visible, "'show the way' after a card tap")
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
	["journey6h @253.3: a guide unlocked after the pinned one is named on the HUD, not hidden behind it"] = function()
		-- L50 grade 8: g45 bone work (L42, polish bone 5/6) still open and leading; g47 first ride (L43),
		-- g18 technical support and g20 rescue preparation (L50) are open too. Only g45 reached the HUD.
		local definitions = {}
		for _, g in GuideEvents.visible(Content, true) do
			if ((g.gates or {}).characterLevel or 1) < 42 or g.id == "rw.g46.t2-tool" then
				definitions[g.id] = true
			end
		end
		local ch = {
			level = 50,
			points = 800,
			definitions = definitions,
			progress = { ["rw.g45.bone-work.1"] = 1, ["rw.g45.bone-work.2"] = 5 },
		}
		local later = { "guide_g47", "guide_g18", "guide_g20" }
		-- Harbor / home tracker (ContractsPanel's line).
		local harbor = assert(Text.guideObjective("ko-kr", Content, ch, NAMES, true, true), "a line")
		assert(string.find(harbor, Text.text("ko-kr", "guide_g45"), 1, true), "g45 still leads: " .. harbor)
		for _, key in later do
			assert(string.find(harbor, Text.text("ko-kr", key), 1, true), key .. " on the HUD: " .. harbor)
		end
		-- Drift-isle tracker: stage objective, the step done here, then the other open guides.
		local h = Harness.harness({ width = 800, height = 360, realHud = true })
		h.workspace:SetAttribute("ForgeWorldRole", "archipelago")
		local world = h.new("Folder", "ForgeRoleWorld")
		world:SetAttribute("ForgeLayoutId", "rw.a1.s3")
		world.Parent = h.workspace
		local character = h.new("Model", "Character")
		local root = h.new("Part", "HumanoidRootPart")
		root.Parent = character
		character.Parent = h.workspace
		h.player.Character = character
		h.publish({
			archipelago = { status = "active", templateId = "rw.a1", stage = 3, progress = {}, completed = {} },
			character = ch,
		})
		local line = assert(find(h, "ObjectiveTracker"), "HUD tracker").Text
		assert(string.find(line, "목표: ", 1, true), "the stage objective leads: " .. line)
		local step = assert(string.match(line, "^[^\n]+\n([^\n]+)"), "a guide line under the stage: " .. line)
		assert(string.find(step, Text.text("ko-kr", "guide_g45"), 1, true), "the first open step: " .. step)
		for _, key in later do
			assert(string.find(line, Text.text("ko-kr", key), 1, true), key .. " on the drift isle: " .. line)
		end
		-- Guides sharing the leader's unlock level stay a sequence (v74: g13 then g14), never listed.
		local six = Text.guideStep("ko-kr", Content, rankSix(), NAMES, true, true) :: string
		assert(not string.find(six, "\n", 1, true), six)
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
	["v74 #6b: when the island grade blocks route 1 the HUD names that gate and the guide that raises it"] = function()
		-- Level 4 (route 1 opens at 2) but grade 0: the Routes card shows 'island grade 0/1 · Locked'.
		local ch = { level = 4, points = 0, definitions = {}, progress = {} }
		local ko = assert(Text.guideObjective("ko-kr", Content, ch, NAMES, true, true), "a line")
		assert(string.find(ko, "섬 개발 등급 1", 1, true), "names the grade gate: " .. ko)
		assert(string.find(ko, Text.text("ko-kr", "guide_g01"), 1, true), "and the guide that raises it: " .. ko)
		assert(ko ~= Text.text("ko-kr", "guide_route_open"), ko)
		-- Below the route level the opening line is unchanged (no gate text).
		local early = assert(Text.guideObjective("ko-kr", Content, { level = 1, points = 0 }, NAMES, true, true))
		assert(not string.find(early, "섬 개발 등급", 1, true), early)
	end,
}
