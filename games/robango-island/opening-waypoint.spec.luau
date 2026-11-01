--!strict
-- p134 c1 dead end 2: the ridge-camp leg ('개울을 따라 올라가기' / '바람등성이 캠프 도착') had no
-- on-screen direction, at night. Every opening step after the stakes names a waypoint target that
-- resolves to a world position on the onboarding layout, and the client draws the arrow (with the
-- distance), the minimap pin and the beam for the current step, reusing one set of instances.
local fs = require("@lune/fs")
local roblox: any = require("@lune/roblox")
local Scene = require("./src/shared/OpeningScene")
local Content = require("./src/shared/SurvivalContent")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local HudShell = require("../../genres/survival-coop/module/HudShell")
local Fixture = require("./PackText.fixture")

local function onboarding(): any
	for _, layout in Content.layouts do
		if layout.id == "rw.onboarding" then
			return layout
		end
	end
	error("rw.onboarding layout")
end

local function loadWaypoint(engine: any): any
	return engine.load("games/robango-island/src/shared/Waypoint.luau", {
		["../../../../genres/survival-coop/module/HudShell"] = HudShell,
	}, nil)
end

return {
	["every opening step after the stakes has a waypoint target on the onboarding layout"] = function()
		local engine = Engine.new()
		local Waypoint = loadWaypoint(engine)
		local layout = onboarding()
		for index = Scene.INDEX.mirror, #Scene.STEPS do
			local step = Scene.STEPS[index]
			local id = Scene.target({ active = true, step = step.id })
			assert(id ~= nil, "no waypoint target for step " .. step.id)
			assert(Waypoint.resolve(layout, id) ~= nil, step.id .. " target " .. id .. " is not on the layout")
		end
		-- The ridge leg the c1 tester could not find: the ford, then Marit's camp.
		local ford = Waypoint.resolve(layout, Scene.target({ active = true, step = "stream" }))
		local camp = Waypoint.resolve(layout, Scene.target({ active = true, step = "camp" }))
		assert(ford.X == -10 and ford.Z == 20, "stream points at opening.ford")
		assert(camp.X == 0 and camp.Z == -48, "camp points at npc.marit")
		assert(
			Scene.target(nil) == nil and Scene.target({ active = false, step = "camp" }) == nil,
			"no view, no target"
		)
	end,
	["arrow, minimap pin and beam for the current step, hidden within 8 studs"] = function()
		local engine = Engine.new()
		local Waypoint = loadWaypoint(engine)
		local playerGui = engine.newInstance("PlayerGui")
		local stage = engine.newInstance("Folder")
		local minimap = engine.newInstance("Frame")
		minimap.AbsoluteSize = roblox.Vector2.new(120, 120)
		local camera = {
			ViewportSize = roblox.Vector2.new(1000, 500),
			CFrame = roblox.CFrame.lookAt(roblox.Vector3.new(0, 40, 40), roblox.Vector3.zero),
			-- Everything projects to the far right, in front: the arrow clamps to the right edge.
			WorldToViewportPoint = function(_, _at)
				return roblox.Vector3.new(5000, 250, 10), false
			end,
		}
		local way = Waypoint.start({
			playerGui = playerGui,
			stage = stage,
			camera = function()
				return camera
			end,
			minimap = function()
				return minimap
			end,
			label = function(meters: number): string
				return meters .. " m"
			end,
		})
		local layout = onboarding()
		local target = Waypoint.resolve(layout, assert(Scene.target({ active = true, step = "camp" })))
		local root = roblox.Vector3.new(-10, 2, 20) -- standing at the ford
		way.step(root, target)
		assert(way.beam.Parent == stage, "beam at the target")
		assert(way.beam.Material == roblox.Enum.Material.Neon and way.beam.Size.X >= 60, "tall neon beam")
		assert(way.beam.CFrame.Position.X == 0 and way.beam.CFrame.Position.Z == -48, "beam on npc.marit")
		assert(way.beam.CanCollide == false and way.beam.CanQuery == false, "beam is not physical")
		assert(way.arrow.Visible and way.gui.Parent == playerGui, "screen arrow shown")
		local metres = math.floor(math.sqrt(10 ^ 2 + 68 ^ 2) + 0.5)
		assert(way.arrow:FindFirstChild("Distance").Text == metres .. " m", "distance in metres")
		assert(way.arrow.Position.X.Offset == 1000 - Waypoint.EDGE_MARGIN, "off-screen arrow on the edge")
		assert(way.pin.Parent == minimap and way.pin.Visible, "minimap pin")
		local beam = way.beam
		way.step(roblox.Vector3.new(0, 2, -42), target)
		assert(not way.arrow.Visible and not way.pin.Visible and way.beam.Parent == nil, "hidden within 8 studs")
		way.step(root, nil)
		assert(way.beam.Parent == nil and not way.arrow.Visible, "no target hides it")
		way.step(root, target)
		assert(way.beam == beam and way.beam.Parent == stage, "instances are reused")
		way.destroy()
	end,
	["edge arrow and minimap pin geometry"] = function()
		local engine = Engine.new()
		local Waypoint = loadWaypoint(engine)
		local x, y, rotation, inside = Waypoint.edge(500, 250, 10, 1000, 500)
		assert(inside and x == 500 and y == 250 and rotation == 180, "on screen: on the target, pointing down")
		x, y, rotation, inside = Waypoint.edge(500, -900, 10, 1000, 500)
		assert(not inside and y == Waypoint.EDGE_MARGIN and math.abs(rotation) < 1e-6, "above: top edge, up")
		x, y, rotation, inside = Waypoint.edge(500, -900, -10, 1000, 500)
		assert(not inside and y == 500 - Waypoint.EDGE_MARGIN, "behind the camera mirrors")
		-- North-up map (camera looking -z): a far target due north pins on the top rim.
		local px, py, rim = Waypoint.pin(0, -500, 120, 0, -1)
		assert(rim and math.abs(px - 60) < 1e-6 and py < 10, "far target on the rim toward it")
		px, py, rim = Waypoint.pin(20, 0, 120, 0, -1)
		assert(not rim and px > 60 and math.abs(py - 60) < 1e-6, "near target inside the map")
	end,
	["opening client draws the waypoint and offers the walk from the tracker"] = function()
		local source = fs.readFile("games/robango-island/src/shared/OpeningClient.luau")
		assert(string.find(source, "Waypoint.start(", 1, true), "client starts the waypoint")
		assert(string.find(source, "Scene.target(view)", 1, true), "target follows the current step")
		assert(string.find(source, "way.step(", 1, true), "waypoint updated per frame")
		assert(string.find(source, "ctx.walkTo(", 1, true), "show the way walks there")
		local inactive = assert(string.find(source, "if not active then", 1, true))
		local stop = assert(string.find(source, "return", inactive, true))
		assert(
			string.find(string.sub(source, inactive, stop), "way.step(nil, nil)", 1, true),
			"hidden after the opening"
		)
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(client, "scoped.walkTo", 1, true), "the client passes the tap router walk")
		for _, locale in { "en-us", "ko-kr" } do
			for _, key in { "opening.way.show", "opening.way.meters" } do
				local line = Fixture.packText(locale, key)
				assert(line and line ~= key, locale .. " " .. key)
			end
			assert(
				string.format(Fixture.packText(locale, "opening.way.meters") :: string, 42):find("42"),
				"metres format"
			)
		end
	end,
}
