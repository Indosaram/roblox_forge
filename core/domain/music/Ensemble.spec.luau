--!strict
local Score = require("./Score")
local Ensemble = require("./Ensemble")
local Library = require("./Library")
local Rules = require("./TestCatalog")
return {
	["six players share absolute start and seventh refusal is mutation proved"] = function()
		local value: any = { version = 1, tempo = 120, parts = {} }
		for _ = 1, 6 do
			table.insert(value.parts, {
				instrumentId = "piano",
				notes = { { startTick = 0, durationTicks = 480, pitch = 60, velocity = 100 } },
			})
		end
		local near = true
		local room = Ensemble.new(Rules, {
			load = function()
				return value
			end,
			inRange = function()
				return near
			end,
		})
		for i = 1, 6 do
			assert(room.join(tostring(i), "s", 1, i), "Ensemble.spec.luau: invariant failed")
			assert(room.ready(tostring(i), true), "Ensemble.spec.luau: invariant failed")
		end
		local before = room.snapshot()
		local admitted, reason = room.join("7", "s", 1, 1)
		assert(not admitted and reason == "ensemble.full", "capacity checked before part collision")
		assert(room.snapshot().members["7"] == nil, "Ensemble.spec.luau: invariant failed")
		assert(not room.start("2", 10), "Ensemble.spec.luau: invariant failed")
		near = false
		assert(not room.start("1", 10), "Ensemble.spec.luau: invariant failed")
		assert(room.snapshot().startAt == nil, "Ensemble.spec.luau: invariant failed")
		near = true
		assert(room.start("1", 10), "Ensemble.spec.luau: invariant failed")
		local playing = room.snapshot()
		assert(playing.startAt == 12, "Ensemble.spec.luau: invariant failed")
		for _, event in playing.events do
			assert(math.abs(event.at - 12) <= 0.1, "Ensemble.spec.luau: invariant failed")
		end
		value.parts[1].notes[1].pitch = 99
		assert(playing.score.parts[1].notes[1].pitch == 60, "Ensemble.spec.luau: invariant failed")
		assert(before.members["1"].ready, "Ensemble.spec.luau: invariant failed")
		assert(room.leave("2"), "Ensemble.spec.luau: invariant failed")
		assert(room.join("2", "s", 1, 2), "Ensemble.spec.luau: invariant failed")
		assert(room.snapshot().startAt == 12, "Ensemble.spec.luau: invariant failed")
		assert(not room.join("other", "s", 2, 2), "Ensemble.spec.luau: invariant failed")
		room.advance(12.5)
		assert(room.snapshot() == nil, "Ensemble.spec.luau: invariant failed")
	end,
	["immutable score revisions share read access but never write ownership"] = function()
		local states: any = {}
		local library = Library.new({
			read = function(actor)
				return Score.copy(states[actor])
			end,
			write = function(actor, version, state)
				assert(
					version == (if states[actor] then states[actor].version else 0),
					"Ensemble.spec.luau: invariant failed"
				)
				states[actor] = Score.copy(state)
				return true
			end,
		})
		local saved = library.save("owner", nil, { tempo = 120 })
		local id = saved.data.scoreId
		assert(not library.canRead("friend", id, 1), "Ensemble.spec.luau: invariant failed")
		assert(not library.share("friend", id, 1, "third").ok, "Ensemble.spec.luau: invariant failed")
		assert(library.share("owner", id, 1, "friend").ok, "Ensemble.spec.luau: invariant failed")
		assert(library.canRead("friend", id, 1), "Ensemble.spec.luau: invariant failed")
		assert(not library.save("friend", id, {}).ok, "Ensemble.spec.luau: invariant failed")
		assert(library.save("owner", id, { tempo = 140 }).data.revision == 2, "Ensemble.spec.luau: invariant failed")
		assert(not library.canRead("friend", id, 2), "sharing pins the selected immutable revision")
		local original = library.load(id, 1)
		assert(original.tempo == 120, "Ensemble.spec.luau: invariant failed")
		original.tempo = 1
		assert(library.load(id, 1).tempo == 120, "Ensemble.spec.luau: invariant failed")
	end,
}
