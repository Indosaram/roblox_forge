--!strict
-- p134 v73 phone acceptance (SM-N981N, ko-kr) defects.
local Content = require("./src/shared/SurvivalContent")
local Text = require("../../genres/survival-coop/module/CharacterText")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local HudLocale = require("../../genres/survival-coop/module/SurvivalHUDLocale")
local Spoilage = require("../../core/domain/survival/Spoilage")
local Harness = require("./PanelHarness.fixture")
local roblox: any = require("@lune/roblox")
require("./PackText.fixture") -- installs the strings.csv lookup the genre text tables read

local NAMES = { fiber = "고사리 섬유", ["axe-t1"] = "도끼" }

-- A key named in a hint: a lone capital E/C/B (the PC verbs), or "키" / "key".
local function namesKey(line: string): boolean
	return string.find(line, "%f[%w]E%f[%W]") ~= nil
		or string.find(line, "%f[%w]C%f[%W]") ~= nil
		or string.find(line, "%f[%w]B%f[%W]") ~= nil
		or string.find(line, "키", 1, true) ~= nil
		or string.find(string.lower(line), "key", 1, true) ~= nil
end

return {
	["v73 #1: on touch the first-gather HUD line names no key; PC keeps the E hint"] = function()
		local ch = { level = 3, points = 50, definitions = {}, progress = {} }
		local phone = assert(Text.guideObjective("ko-kr", Content, ch, NAMES, true, true), "a guide line")
		assert(string.find(phone, "고사리 섬유", 1, true), phone)
		assert(not namesKey(phone), "touch line names a key: " .. phone)
		assert(string.find(phone, "누르기", 1, true), "touch wording: " .. phone)
		local en = assert(Text.guideObjective("en-us", Content, ch, NAMES, true, true))
		assert(not namesKey(en), "touch en line names a key: " .. en)
		local pc = assert(Text.guideObjective("ko-kr", Content, ch, NAMES, true))
		assert(string.find(pc, "(다가가서 E)", 1, true), "PC wording unchanged: " .. pc)
		-- Every guide step verb that names a key on PC has a key-free touch row.
		for _, action in { "gather", "craft", "place" } do
			for _, locale in { "en-us", "ko-kr" } do
				local touch = Text.text(locale, "guide_go_" .. action .. "_touch")
				assert(touch ~= "guide_go_" .. action .. "_touch", "touch row for " .. action)
				assert(not namesKey(string.format(touch, "x")), locale .. " " .. action .. ": " .. touch)
			end
		end
	end,
	["v73 #3: the hunger tip never says eat a stack at freshness 0, and its freshness line says spoiled"] = function()
		local policy = assert(Spoilage.policy(Content), "food-spoilage policy")
		local now = policy.limitMillis + 5000
		local stale = { catalogId = "berry", quantity = 1, attributes = { freshAt = 0, freshAge = 0 } }
		local fresh = { catalogId = "berry", quantity = 1, attributes = { freshAt = now, freshAge = 0 } }
		local function spoiled(item: any): boolean
			return Spoilage.freshness(item, policy, now, false) == 0
		end
		local function snapshot(...: any): any
			local bag = {}
			for index, item in { ... } do
				bag["i" .. index] = item
			end
			return { vitals = { hungerMilli = 16000 }, inventory = { bag = { items = bag } } }
		end
		local only = Model.hungerHint(snapshot(stale), Content.items, spoiled)
		assert(only == "hungry_find", "only a spoiled berry: find food, got " .. tostring(only))
		assert(Model.hungerHint(snapshot(stale, fresh), Content.items, spoiled) == "hungry", "a fresh berry: eat")
		local line = HudLocale.freshness("ko-kr", 0)
		assert(not string.find(line, "곧 먹", 1, true) and string.find(line, "상함", 1, true), line)
		assert(
			HudLocale.freshness("ko-kr", 200) == "신선도 20% - 곧 먹거나 냉장고에 넣으세요",
			"spoiling unchanged"
		)
	end,
	["v73 #2: at the harbor the guide gather step points the waypoint and 'show the way' at a fiber node"] = function()
		local harbor: any = nil
		for _, layout in Content.layouts do
			harbor = if layout.id == "rw.harbor" then layout else harbor
		end
		local fiber: any = nil
		for _, node in harbor.resourceNodes do
			fiber = if node.item == "fiber" then node.position else fiber
		end
		assert(fiber, "the harbor has a fiber node")
		local h = Harness.harness({ width = 800, height = 360, realHud = true })
		local world = h.new("Folder", "ForgeRoleWorld")
		world:SetAttribute("ForgeLayoutId", "rw.harbor")
		world.Parent = h.workspace
		local character = h.new("Model", "Character")
		local root = h.new("Part", "HumanoidRootPart")
		root.Position, root.Parent = roblox.Vector3.new(fiber.x + 60, fiber.y, fiber.z + 40), character
		character.Parent = h.workspace
		h.player.Character = character
		-- A returning account off the opening: no opening view, the HUD line is the first-gather guide.
		h.publish({
			contracts = { tutorial = { step = "declare-settlement", hint = "tutorial.declare-settlement" } },
			character = { level = 3, points = 50, definitions = {}, progress = {} },
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
		assert(string.find(line, "고사리 섬유", 1, true), "the HUD line is the gather guide: " .. line)
		local beam = assert(find("WaypointBeam") or h.workspace:FindFirstChild("WaypointBeam", true), "beam")
		assert(beam.Parent ~= nil, "a beam marks the gather target")
		local at = beam.CFrame.Position
		assert(math.abs(at.X - fiber.x) < 0.01 and math.abs(at.Z - fiber.z) < 0.01, "beam on the fiber node")
		local tap = assert(find("OpeningTrackerTap"), "quest card tap")
		assert(tap.Visible, "the quest card offers the walk")
		h.click(tap)
		assert(assert(find("OpeningShowWay"), "show the way").Visible, "'show the way' after a card tap")
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
}
