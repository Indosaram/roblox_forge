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
local Vector3, UDim2 = roblox.Vector3, roblox.UDim2

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
			opening = {
				active = true,
				beat = 7,
				step = "board",
				beaconAt = 1,
				boatAt = 4001,
				pulled = { true, true, true },
			},
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
		local Client = Harness.harness({ width = 800, height = 360 })
			.load("games/robango-island/src/shared/OpeningClient")
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
			assert(
				limit >= need,
				string.format("%dx%d: %d rows need %d px, cap %d", screen[1], screen[2], rows, need, limit)
			)
			assert(r.quest.y + limit <= r.cluster.y, "the card stays above the action cluster")
		end
	end,
	-- #11: the hunger tip sat under the drift-isle timer pill and over sheet title bars; the landscape
	-- welcome sheet's 4th copy line was clipped by its pinned Continue.
	["v74 #11: the hunger tip clears the drift-isle timer and waits under sheets"] = function()
		local h = Harness.harness({ width = 914, height = 411, inset = 58, realHud = true })
		local hud = assert(h.playerGui:FindFirstChild("ForgeSurvivalHUD"), "survival hud gui")
		-- The drift-isle timer pill (SeaChart: top-centre, tagged ForgeHudPill), on its own gui.
		local pillGui = h.new("ScreenGui", "ForgeSeaChartHud")
		pillGui.Parent = h.playerGui
		local pill = h.new("TextLabel", "DriftTimer")
		local HudShell = h.load("genres/survival-coop/module/HudShell")
		local regions = HudShell.regions(914, 411, 0, true)
		local lane = regions.banner
		pill.Size = UDim2.fromOffset(200, 30)
		pill.Position = UDim2.fromOffset(lane.x + lane.width / 2 - 100, lane.y)
		pill.Parent = pillGui
		local tagged = { ForgeHudPill = { pill } } -- HudShell.HUD_PILL_TAG
		h.game:GetService("CollectionService").GetTagged = function(_, tag)
			return tagged[tag] or {}
		end
		h.packet({
			revision = 1,
			durable = { actions = { "survival-coop:food" }, epochs = {} },
			snapshots = {
				["survival-coop"] = {
					vitals = { healthMilli = 90000, hungerMilli = 10000, fatigueMilli = 0 },
					progression = { level = 2, sp = 0, xp = 0, paid = {}, version = 1 },
					inventory = {},
				},
				survivalExtensions = {},
			},
		})
		h.step()
		local status = assert(hud:FindFirstChild("Status"), "status line")
		assert(status.Visible and string.find(status.Text, "배가 고파요", 1, true), "hunger tip: " .. status.Text)
		local a, b = h.rect(status), h.rect(pill)
		local hit = a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
		assert(not hit, string.format("hunger tip (%d,%d %dx%d) under the timer pill", a.x, a.y, a.width, a.height))
		-- A sheet open: the tip waits (it drew over sheet title bars).
		h.hud.open("craft")
		h.step()
		assert(not status.Visible, "the hunger tip is hidden under an open sheet")
		h.hud.close()
		h.step()
		assert(status.Visible, "and comes back when it closes")
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
	["v74 #11: every copy line of the landscape welcome sheet shows above Continue"] = function()
		local Screens = require("../../genres/survival-coop/module/RecoveredScreens")
		local Sheet = require("../../genres/survival-coop/module/SocialSheet")
		local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
		local Theme = require("../../core/ui-kit/Theme")
		require("../../genres/survival-coop/module/ScreenText").use(PackText.screenText)
		local S = Theme.sheet.space
		-- A fresh account on the phone: the opening runs past the arrival step (no Skip).
		for _, tutorial in { { step = "gather" }, { step = "arrive" } } do
			local rows = Screens.arrivalRows("ko-kr", { tutorial = tutorial, objective = "x", touch = true }, {})
			for _, screen in { { 914, 353 } } do -- SM-N981N landscape under the 58 px top bar
				local _, _, w, h = Panels.shellSheet(screen[1], screen[2], true)
				local room = h - Sheet.HEADER - Sheet.footerHeight(rows)
				local used = 2 * S.pad
				for _, row in rows do
					if not row.pin then
						local width = Sheet.contentWidth(w) - (S.marker + 3 * S.gap)
						used += Sheet.rowHeight(row.text, width) + S.gap
					end
				end
				assert(
					used - S.gap <= room,
					string.format(
						"%s %dx%d: copy %d px in a %d px scroller",
						tutorial.step,
						screen[1],
						screen[2],
						used,
						room
					)
				)
			end
		end
	end,
	-- #12: near the beacon tower the play camera snapped into an extreme close-up: its collision cast
	-- (QuarterView) shortens the arm on any untagged solid hit, and the tower's legs, deck and basket
	-- were untagged. Tagged ForgeCameraOccluder, the camera ignores them for collision and fades them.
	["v74 #12: the beacon tower (and every opening set piece) is a camera occluder, not a camera wall"] = function()
		local engine, world = onboarding()
		local tags = engine.game:GetService("CollectionService")
		for _, model in { world.opening.beacon, world.opening.boat } do
			assert(tags:HasTag(model, "ForgeCameraOccluder"), model.Name .. " tagged ForgeCameraOccluder")
		end
		-- QuarterView: a hit on a part inside the tagged tower keeps the full arm.
		local Fixture = require("../../core/infra/camera/QuarterView.fixture")
		local f = Fixture.new()
		local tower = { Parent = f.world }
		local leg = f.part(0, tower)
		f.tags[tower] = "ForgeCameraOccluder"
		local api = f.module.start()
		f.hit = { Distance = 2, Instance = leg }
		f.step(0)
		local camera = f.world.CurrentCamera
		local arm = (camera.CFrame.Position - camera.Focus.Position).Magnitude
		assert(arm > 80, string.format("the arm keeps its length through the tower: %.2f", arm))
		api.stop()
		world.destroy()
	end,
	-- #13: the 연습과 악기 sheet opened on an empty bullet (the empty status line, row 0) and Make gave
	-- no feedback (its line went to that top row, scrolled out of view under the last row).
	["v74 #13: the practice sheet has no empty row and Make says what it made under the row"] = function()
		local h = Harness.harness({ width = 914, height = 411, inset = 58, realHud = true })
		local sent = 0
		h.game:GetService("ReplicatedStorage"):WaitForChild("ForgeAction").InvokeServer = function(_self, kind, body)
			assert(kind == "command" and body.action == "survival-coop:operation-run", tostring(body.action))
			sent += 1
			return { ok = true, stateVersion = 2 }
		end
		h.packet({
			revision = 1,
			durable = { actions = { "survival-coop:operation-run" }, epochs = { ["survival-coop:operation-run"] = 1 } },
			snapshots = {
				survivalExtensions = {
					operations = {
						operations = {
							{
								id = "practice-sewing",
								inputs = { { item = "fiber", quantity = 2 } },
								outputs = { { item = "practice-sewing", quantity = 1 } },
							},
							{
								id = "instrument-drum",
								station = "workbench",
								inputs = { { item = "wood", quantity = 6 } },
								outputs = { { item = "instrument-drum", quantity = 1 } },
								reason = "CHARACTER_LEVEL_GATE",
							},
						},
					},
				},
			},
		})
		local gui = assert(h.playerGui:FindFirstChild("ForgeOperations"), "operations gui")
		local scroll = gui:FindFirstChild("OperationsSheet", true):FindFirstChild("Content")
		local function visibleRows(): { any }
			local rows = {}
			for _, item in scroll:GetChildren() do
				if (item.ClassName == "TextLabel" or item.ClassName == "TextButton") and item.Visible then
					table.insert(rows, item)
				end
			end
			table.sort(rows, function(a, b)
				return a.LayoutOrder < b.LayoutOrder
			end)
			return rows
		end
		for _, row in visibleRows() do
			assert(row.Text ~= "", "an empty row on the sheet: " .. row.Name)
		end
		local make = assert(scroll:FindFirstChild("Make-practice-sewing"), "Make on the open row")
		h.click(make)
		h.step()
		assert(sent == 1, "Make sends operation-run")
		local rows = visibleRows()
		local at = table.find(rows, make)
		local line = rows[(at :: number) + 1]
		assert(line and line.Name == "OperationStatus", "the result line sits right under Make")
		assert(string.find(line.Text, PackText.packText("ko-kr", "operation_done"), 1, true), line.Text)
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
	["v75: the opening Dodge button names no keyboard key on a touch phone"] = function()
		local h = Harness.harness({ width = 914, height = 411, inset = 58, realHud = true, touch = true })
		local dodge = assert(h.playerGui:FindFirstChild("OpeningDodge", true), "the opening Dodge button")
		assert(not string.find(dodge.Text, "[", 1, true), "touch Dodge shows a key hint: " .. dodge.Text)
		assert(dodge.Text ~= "", "the Dodge button keeps its label")
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
}
