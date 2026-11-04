--!strict
-- p134 v74 phone acceptance (SM-N981N, ko-kr, touch, 2400x1080 landscape) defects.
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Scene = require("./src/shared/OpeningScene")
local Harness = require("./PanelHarness.fixture")
local PackText = require("./PackText.fixture")
local roblox: any = require("@lune/roblox")
local Vector3 = roblox.Vector3

-- The live onboarding role (RoleWorld + OpeningDirector) on the headless engine.
local function onboarding(): (any, any)
	local engine = Engine.new(nil, true)
	local world = engine.role.build(Content, Source, Policy, function()
		return 0
	end, "rw.onboarding", 1776)
	return engine, world
end

local function prompts(engine: any, name: string): { any }
	local out = {}
	for _, item in engine.parts do
		if item.ClassName == "ProximityPrompt" and item.Name == name and not item.destroyed then
			table.insert(out, item)
		end
	end
	return out
end

return {
	-- #2: tapping the stake's 'Pull' did nothing (a hidden hold; SurvivalHUD's interact token only
	-- fires HoldDuration 0 prompts on a tap), and after a pull the token greyed out until the player
	-- walked: the next stake (8-9 studs on) was outside the 8-stud prompt reach.
	["v74 #2: a tap pulls a stake, and from a pulled stake the next one is in reach"] = function()
		local engine, world = onboarding()
		local stakes = prompts(engine, "ForgeOpeningStake")
		assert(#stakes == 3, "three stake prompts, got " .. #stakes)
		for _, prompt in stakes do
			assert(prompt.HoldDuration == 0, "a tap pulls (no hidden hold): " .. tostring(prompt.HoldDuration))
		end
		local farthest = 0
		for index, stake in world.opening.stakes do
			local nearestOther = math.huge
			for other, part in world.opening.stakes do
				if other ~= index then
					nearestOther = math.min(nearestOther, (part.Position - stake.Position).Magnitude)
				end
			end
			farthest = math.max(farthest, nearestOther)
		end
		for _, prompt in stakes do
			assert(
				prompt.MaxActivationDistance >= farthest + 1,
				string.format("next stake %.1f studs on, reach %s", farthest, tostring(prompt.MaxActivationDistance))
			)
			-- The server still accepts a pull from there (SurvivalWorld.nearPart: 12 studs).
			assert(prompt.MaxActivationDistance <= 12, "inside the server reach")
		end
		world.destroy()
	end,
	-- #5: '켜기' at the tower was a no-op: a 2 s hold the token never fires on a tap, and the server's
	-- reach (nearPart: a ray to the pole top) crossed the tower's own deck and basket. With Marit
	-- near, her talk prompt won the token and opened her dialog.
	["v74 #5: a tap at the tower foot lights the beacon"] = function()
		local engine, world = onboarding()
		local beacon = prompts(engine, "ForgeOpeningBeacon")
		assert(#beacon == 1 and beacon[1].HoldDuration == 0, "the beacon lights on a tap")
		local ACTOR = "11734795308"
		local pole = world.opening.beacon.PrimaryPart
		local at = pole.Position + Vector3.new(3, -3, 0)
		engine.move(ACTOR, { x = at.X, y = at.Y, z = at.Z })
		local document = {}
		world.opening.bind({
			tutorial = function()
				return 7, true
			end,
			items = function()
				return {}
			end,
			dodgeAt = function()
				return nil
			end,
			position = function()
				return at
			end,
			-- The phone case: the ray to the pole top hits the tower's deck.
			near = function()
				return false
			end,
			store = {
				snapshot = function()
					return document
				end,
				transaction = function(_, transform)
					return transform(document)
				end,
			},
			analytics = function() end,
			travel = function()
				return true
			end,
			spawn = function(fn)
				fn()
			end,
		})
		document.opening = { v = 1, index = Scene.INDEX.beacon, pulled = { true, true, true } }
		world.opening.tick({ ACTOR }, 1000)
		local state = assert(world.opening.state(ACTOR), "staged")
		assert(Scene.current(state).id == "beacon", "at the beacon step")
		engine.interact(ACTOR, "Pole")
		assert(state.beaconAt ~= nil, "lit: " .. tostring(world.opening.refusal(ACTOR)))
		world.destroy()
	end,
	["v74 #5: Marit's talk prompt rests during the beacon step and the lit beacon answers on the card"] = function()
		local h = Harness.harness({ width = 800, height = 360, realHud = true })
		local world = h.new("Folder", "ForgeRoleWorld")
		world:SetAttribute("ForgeLayoutId", "rw.onboarding")
		world.Parent = h.workspace
		local marit = h.new("Part", "npc.marit")
		marit.Parent = world
		local talk = h.new("ProximityPrompt", "ProximityPrompt")
		talk.Enabled, talk.Parent = true, marit
		local character = h.new("Model", "Character")
		local root = h.new("Part", "HumanoidRootPart")
		root.Position, root.Parent = roblox.Vector3.new(8, 2, -46), character
		character.Parent = h.workspace
		h.player.Character = character
		h.publish({ opening = { active = true, beat = 7, step = "beacon", pulled = { true, true, true } } })
		assert(talk.Enabled == false, "Marit's prompt does not take the beacon's token")
		h.publish({
			opening = { active = true, beat = 7, step = "board", beaconAt = 1, boatAt = 4001, pulled = { true, true, true } },
		})
		assert(talk.Enabled == true, "Marit talks again once the beacon is lit")
		local card = assert(h.playerGui:FindFirstChild("OpeningCard", true), "opening card")
		assert(card.Visible and card.Text == PackText.packText("ko-kr", "opening.beacon.farewell"), card.Text)
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
	-- #3: the opening quest card was capped at its slot (~78 px on the phone), so the title and three
	-- wrapped lines ended in '...'. It now grows down to just above the action cluster.
	["v74 #3: the opening quest card has room for its title and wrapped lines on phone sizes"] = function()
		-- OpeningClient reads engine services at load: load it on the panel harness engine.
		local Client = Harness.harness({ width = 800, height = 360 }).load("games/robango-island/src/shared/OpeningClient")
		local HudShell = require("../../genres/survival-coop/module/HudShell")
		local ko = function(key: string): string
			return assert(PackText.packText("ko-kr", key), key)
		end
		local state = Scene.new(0)
		state.index = Scene.INDEX.fiber
		local title, lines = Scene.tracker(Scene.view(state, { items = {} } :: any), ko)
		assert(title and #lines == 3, "beat 3 card")
		local size = HudShell.QUEST_TEXT.touch
		-- SM-N981N landscape (914x411 dp, with and without the 58 px top bar) and a larger phone.
		for _, screen in { { 914, 411, 58 }, { 914, 411, 0 }, { 1000, 450, 58 } } do
			local r = HudShell.regions(screen[1], screen[2], screen[3], true)
			local perLine = math.max(1, math.floor(r.quest.width / size)) -- Hangul: ~1 em per glyph
			local rows = 0
			for _, line in { title :: string, table.unpack(lines) } do
				rows += math.ceil(utf8.len(line) / perLine)
			end
			local need = rows * size + 12 -- LineHeight 1, 6 px padding top and bottom
			assert(r.quest.height < need, "the slot alone cuts the card (the v74 '...')")
			local limit = assert(Client.questLimit(r.quest.height, r), "a cap")
			assert(limit >= need, string.format("%dx%d: %d rows need %d px, cap %d", screen[1], screen[2], rows, need, limit))
			assert(r.quest.y + limit <= r.cluster.y, "the card stays above the action cluster")
		end
	end,
}
