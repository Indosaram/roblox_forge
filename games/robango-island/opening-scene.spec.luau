--!strict
-- C1 opening (opening-script.md, beats 0-7): the server-owned step machine and its director on
-- the live onboarding role. Beat order, skip, the returning-player bypass, the scripted boar
-- never damaging, and one `opening_step` event per step (including bone-knife).
local Scene = require("./src/shared/OpeningScene")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Fixture = require("./PackText.fixture")

local function facts(over: any?): Scene.Facts
	local value: any = {
		tutorialIndex = 1,
		tutorialComplete = false,
		items = {},
		nearFord = false,
		nearMarit = false,
		windbreak = false,
		dodgeAt = nil,
	}
	for key, data in over or {} do
		value[key] = data
	end
	return value
end

local function recorder(): ({ string }, (string, number, number) -> ())
	local events: { string } = {}
	return events, function(step: string)
		table.insert(events, step)
	end
end

-- Drives a fresh player through the whole opening on server facts; returns the emitted steps.
local function playThrough(dodge: (charge: Scene.Charge) -> number?): ({ string }, Scene.State)
	local now = 1000
	local state = Scene.new(now)
	local events, emit = recorder()
	local f = facts()
	local function step(ms: number?)
		now += ms or 0
		Scene.advance(state, f, now, emit)
	end
	step()
	assert(state.index == Scene.INDEX.arrive, "waits on arrival")
	f.tutorialIndex = 2
	assert(Scene.coldOpenDone(state), "cold open ends")
	step()
	assert(Scene.current(state).id == "dodge", "beat 1 starts")
	assert(Scene.pull(state, 1, now) and Scene.pull(state, 2, now), "two stakes before the boar")
	assert(state.charge and state.charge.slow, "the 2nd stake sends a slowed charge")
	assert(not Scene.pull(state, 3, now), "third stake waits for the dodge beat")
	local guard = 0
	while Scene.current(state).id == "dodge" do
		guard += 1
		assert(guard < 10, "dodge beat terminates")
		local charge = assert(state.charge, "charge pending")
		f.dodgeAt = dodge(charge)
		now = charge.strikeAt + Scene.GRACE_MILLIS
		step()
	end
	assert(Scene.pull(state, 3, now), "last stake")
	step()
	assert(Scene.current(state).id == "mirror", "beat 2")
	step(Scene.MIRROR_MILLIS)
	assert(Scene.current(state).id == "bone", "mirror card auto-advances after 6 s")
	f.items = { bone = 1 }
	step()
	f.items = { bone = 1, fiber = 3 }
	step()
	f.items = { ["bone-knife"] = 1, fiber = 1 }
	f.tutorialIndex = 3
	step()
	f.items = { ["bone-knife"] = 1, flint = 3 }
	step()
	f.items = { ["bone-knife"] = 1, ["stone-axe"] = 1, flint = 1 }
	f.tutorialIndex = 4
	step()
	f.nearFord = true
	step()
	f.items.wood = 7
	step()
	f.nearMarit = true
	step()
	f.tutorialIndex = 5
	step()
	f.tutorialIndex = 6
	step()
	f.tutorialIndex, f.tutorialComplete = 7, true
	step()
	f.windbreak = true
	step()
	assert(not Scene.board(state, now), "cannot board before the beacon")
	assert(Scene.lightBeacon(state, now), "beacon lit")
	step()
	assert(not Scene.board(state, now), "the Gannet is not in yet")
	step(Scene.BOAT_MILLIS)
	assert(Scene.board(state, now), "board after the fly-in")
	step()
	return events, state
end

return {
	["fresh player: every step completes in beat order and emits once"] = function()
		local events, state = playThrough(function(charge)
			return charge.startAt + 100
		end)
		assert(Scene.finished(state), "finished")
		assert(#events == #Scene.STEPS, "one event per step, got " .. #events)
		local lastBeat = 0
		for index, id in events do
			assert(id == Scene.STEPS[index].id, "order " .. index .. ": " .. id)
			assert(Scene.STEPS[index].beat >= lastBeat, "beats never go back")
			lastBeat = Scene.STEPS[index].beat
		end
		assert(table.find(events, "bone-knife"), "bone-knife is a tracked step")
		assert(state.dodges == 2 and state.tries == 2, "two clean dodges")
	end,
	["missed charges never damage and the dodge beat auto-passes after 4 tries"] = function()
		local events, state = playThrough(function()
			return nil
		end)
		assert(state.tries == Scene.MAX_TRIES and state.dodges == 0, "4 misses then auto-pass")
		assert(Scene.finished(state) and #events == #Scene.STEPS, "the opening still completes")
		-- The scripted boar has no damage path: its view carries timing only.
		local view = Scene.view(Scene.new(0), facts())
		for key in view do
			assert(not string.find(string.lower(key), "damage"), "no damage field: " .. key)
		end
	end,
	["first charge is slowed to 0.35 for 1.2 s; later charges are not"] = function()
		local first = Scene.charge(0, true)
		local later = Scene.charge(0, false)
		assert(later.strikeAt == Scene.CHARGE_MILLIS, "real-time charge")
		assert(first.strikeAt - later.strikeAt == math.floor(1200 * 0.65 + 0.5), "slow window delays the strike")
	end,
	["skip: the cold open ends on skip, or by itself after its budget"] = function()
		local state = Scene.new(0)
		local events, emit = recorder()
		Scene.advance(state, facts({ tutorialIndex = 2 }), 10, emit)
		assert(#events == 0, "arrival needs the cinematic end or skip")
		assert(Scene.coldOpenDone(state), "skip")
		Scene.advance(state, facts({ tutorialIndex = 2 }), 20, emit)
		assert(events[1] == "arrive", "skip completes arrival")
		local idle = Scene.new(0)
		Scene.advance(idle, facts({ tutorialIndex = 2 }), Scene.COLD_OPEN_MILLIS, emit)
		assert(Scene.current(idle).id == "dodge", "budget fallback")
		local early = Scene.new(0)
		assert(Scene.coldOpenDone(early), "early skip")
		Scene.advance(early, facts({ tutorialIndex = 1 }), 10, emit)
		assert(Scene.current(early).id == "arrive", "the server's tutorial arrival is still required")
	end,
	["returning players (tutorial done, no record) are bypassed and never staged"] = function()
		local state = Scene.resume(nil, 7, true, 0)
		assert(state.bypass and Scene.finished(state) and Scene.current(state) == nil, "bypass")
		local events, emit = recorder()
		assert(not Scene.advance(state, facts({ tutorialIndex = 7, tutorialComplete = true }), 5, emit), "no advance")
		assert(#events == 0, "no events")
		assert(not Scene.view(state, facts()).active, "no view")
		assert(not Scene.pull(state, 1, 0) and not Scene.coldOpenDone(state), "no beat input accepted")
		-- A saved record wins: a player mid-opening resumes where it stopped.
		local saved = Scene.save(Scene.resume({ index = Scene.INDEX.wood, pulled = { true, true, true } }, 4, false, 0))
		local resumed = Scene.resume(saved, 4, false, 0)
		assert(Scene.current(resumed).id == "wood" and not resumed.bypass, "resume mid-opening")
		-- Past the arrival and gather without a record: skip the scripted beats, keep the tracker.
		local legacy = Scene.resume(nil, 3, false, 0)
		assert(Scene.current(legacy).id == "bone", "legacy mid-tutorial player starts at the bone heap")
	end,
	["tracker lines come from the pack strings, KO and EN"] = function()
		for _, locale in { "en-us", "ko-kr" } do
			local function text(key: string): string
				return assert(Fixture.packText(locale, key), "missing string " .. key)
			end
			local state = Scene.new(0)
			assert(Scene.tracker(Scene.view(state, facts()), text) == nil, "beat 0 hides the tracker")
			state.index = Scene.INDEX.dodge
			state.pulled = { true, true, false }
			state.dodges = 1
			local title, lines = Scene.tracker(Scene.view(state, facts()), text)
			assert(title == text("opening.tumble.title") and #lines == 2, "beat 1 card")
			assert(string.find(lines[1], "1/2", 1, true) and string.find(lines[2], "2/3", 1, true), "counts")
			for index = 1, #Scene.STEPS do
				state.index = index
				local t = Scene.tracker(Scene.view(state, facts()), text)
				assert(Scene.STEPS[index].beat == 0 or t ~= nil, "title for " .. Scene.STEPS[index].id)
			end
		end
	end,
	["director on the live onboarding role: stakes, events, camp origin, set-piece tags"] = function()
		local engine = Engine.new(nil, true)
		local now = 5000
		local world = engine.role.build(Content, Source, Policy, function()
			return now
		end, "rw.onboarding", 1776)
		local layout = world.layout
		local plot
		for _, anchor in layout.anchors do
			plot = if anchor.id == "station.campfire.t1" then anchor.position else plot
		end
		local origin = world.roleSource.tribe.origin
		assert(origin.x == plot.x and origin.z == plot.z, "camp grid starts at the camp plot anchor")
		local opening = assert(world.opening, "onboarding builds the opening director")
		local tags = engine.game:GetService("CollectionService")
		local pieces = {}
		for _, model in tags:GetTagged("ForgeSetPiece") do
			pieces[model:GetAttribute("ForgeSetPieceId")] = true
		end
		assert(pieces["town.beacon-tower"] and pieces["town.boat"], "set pieces tagged for B3")
		local ACTOR = "11734795308"
		engine.move(ACTOR, { x = 10, y = 5, z = 64 })
		local tutorial, items, document = 1, {}, {}
		local events: { string } = {}
		local damaged = 0
		opening.bind({
			tutorial = function()
				return tutorial, tutorial > 6
			end,
			items = function()
				return items
			end,
			dodgeAt = function()
				return nil
			end,
			position = function()
				return nil
			end,
			near = function()
				return true
			end,
			store = {
				snapshot = function()
					return document
				end,
				transaction = function(_, transform)
					return transform(document)
				end,
			},
			analytics = function(_, step)
				table.insert(events, step)
			end,
			travel = function()
				return true
			end,
			spawn = function(fn)
				fn()
			end,
		})
		local function tick(ms: number?)
			now += ms or 0
			opening.tick({ ACTOR }, now)
		end
		tick() -- loads (fresh: no record, tutorial at arrive)
		assert(opening.state(ACTOR) and not opening.state(ACTOR).bypass, "fresh player staged")
		tutorial = 2
		assert(opening.intent(ACTOR, "cold-open-done"), "cold open intent")
		tick()
		engine.interact(ACTOR, "OpeningStake1")
		engine.interact(ACTOR, "OpeningStake2")
		local state = assert(opening.state(ACTOR))
		assert(state.charge ~= nil, "server sent the scripted charge")
		for _ = 1, Scene.MAX_TRIES do
			tick(Scene.CHARGE_MILLIS + Scene.SLOW_MILLIS + Scene.GRACE_MILLIS + Scene.NEXT_CHARGE_MILLIS)
		end
		engine.interact(ACTOR, "OpeningStake3")
		tick()
		local wildlife = 0
		for _, spawn in world.roleWildlife.spawns do
			wildlife += if spawn.catalogId == "boar" and string.find(spawn.id, "opening") then 1 else 0
		end
		assert(wildlife == 0 and damaged == 0, "the scripted boar is never a wildlife entity")
		assert(events[1] == "arrive" and events[2] == "dodge" and events[3] == "tumble", table.concat(events, ","))
		assert(document.opening and document.opening.index == Scene.INDEX.mirror, "progress persisted")
		assert(opening.intent(ACTOR, "mirror-dismiss"), "mirror dismiss")
		items = { bone = 1, fiber = 3 }
		tick()
		items = { ["bone-knife"] = 1 }
		tick()
		assert(table.find(events, "bone-knife"), "bone-knife opening_step event: " .. table.concat(events, ","))
		local view = world.opening.extension.snapshot(ACTOR)
		assert(view.active and view.step == "flint", "published view")
		-- A returning player: tutorial complete and no record.
		local RETURNING = "2001"
		tutorial, document = 7, {}
		engine.move(RETURNING, { x = 0, y = 5, z = 60 })
		opening.tick({ RETURNING }, now)
		assert(opening.state(RETURNING).bypass, "returning player bypassed")
		assert(opening.extension.snapshot(RETURNING).active == false, "no beats for a returning player")
		assert(not opening.intent(RETURNING, "cold-open-done"), "no beat input")
		world.destroy()
	end,
}
