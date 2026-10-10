--!strict
local Adapter = require("./Adapter")
local Fixture = require("./Adapter.fixture")
local Types = require("../../../core/domain/genre/Contract")
local function setup(config: Adapter.Config?)
	local now = 0
	local events: { Types.Event } = {}
	local arena = Adapter.create(config or Fixture, {
		now = function()
			return now
		end,
		roll = function()
			return 0
		end,
		emit = function(event)
			table.insert(events, event)
		end,
	})
	local function advance(time: number)
		now = time
		arena.advance(time)
	end
	local function start()
		assert(arena.join("a", nil).ok and arena.join("b", nil).ok, "Adapter.spec.luau: invariant failed")
		assert(
			arena.dispatch("a", "enqueue", {}).ok and arena.dispatch("b", "enqueue", {}).ok,
			"Adapter.spec.luau: invariant failed"
		)
		advance(1)
	end
	return arena, advance, start, events
end
return {
	["caller config mutation cannot change an active arena"] = function()
		local config = table.clone(Fixture)
		config.Round = table.clone(Fixture.Round)
		local arena, advance, start = setup(config)
		config.attackDamage = 999
		config.k = 999
		config.Round.duration = 0.01
		start()
		assert(arena.dispatch("a", "attack", {}).ok, "original round remains active")
		assert(arena.snapshot("b").health == 2, "original damage is retained")
		advance(5)
		assert(arena.snapshot("a").rating == 1016, "original rank step is retained")
	end,

	["knockout uses cooldown damage and settles rank once"] = function()
		local arena, advance, start, events = setup()
		start()
		assert(arena.snapshot("a").rival == "b", "Adapter.spec.luau: invariant failed")
		assert(not arena.dispatch("a", "attack", { "b", 999 }).ok, "Adapter.spec.luau: invariant failed")
		assert(arena.snapshot("b").health == 3, "Adapter.spec.luau: invariant failed")
		assert(arena.dispatch("a", "attack", {}).ok, "Adapter.spec.luau: invariant failed")
		assert(not arena.dispatch("a", "attack", {}).ok, "Adapter.spec.luau: invariant failed")
		advance(2)
		assert(arena.dispatch("a", "attack", {}).ok, "Adapter.spec.luau: invariant failed")
		advance(3)
		assert(arena.dispatch("a", "attack", {}).ok, "Adapter.spec.luau: invariant failed")
		assert(
			arena.snapshot("a").rating == 1016 and arena.snapshot("b").rating == 984,
			"Adapter.spec.luau: invariant failed"
		)
		assert(#events == 3 and events[3].name == "MatchSettled", "Adapter.spec.luau: invariant failed")
		assert(not arena.dispatch("a", "attack", {}).ok, "Adapter.spec.luau: invariant failed")
		advance(4)
		advance(10)
		assert(#events == 3 and arena.snapshot("a").phase == "lobby", "Adapter.spec.luau: invariant failed")
		assert(arena.dispatch("a", "enqueue", {}).ok, "Adapter.spec.luau: invariant failed")
	end,
	["timeout compares health and equal health draws"] = function()
		local arena, advance, start, events = setup()
		start()
		assert(arena.dispatch("b", "attack", {}).ok, "Adapter.spec.luau: invariant failed")
		advance(5)
		assert(
			arena.snapshot("b").rating == 1016 and arena.snapshot("a").rating == 984,
			"Adapter.spec.luau: invariant failed"
		)
		advance(5)
		assert(#events == 3, "Adapter.spec.luau: invariant failed")
		local draw, tick, begin = setup()
		begin()
		tick(5)
		assert(
			draw.snapshot("a").rating == 1000 and draw.snapshot("b").rating == 1000,
			"Adapter.spec.luau: invariant failed"
		)
	end,
	["queued leave and countdown leave cancel without settlement"] = function()
		local arena, advance, _, events = setup()
		assert(arena.join("a", nil).ok and arena.join("b", nil).ok, "Adapter.spec.luau: invariant failed")
		assert(arena.dispatch("a", "enqueue", {}).ok, "Adapter.spec.luau: invariant failed")
		arena.leave("a")
		assert(arena.dispatch("b", "enqueue", {}).ok, "Adapter.spec.luau: invariant failed")
		advance(10)
		assert(arena.snapshot("b").queued, "Adapter.spec.luau: invariant failed")
		assert(arena.join("c", nil).ok and arena.dispatch("c", "enqueue", {}).ok, "Adapter.spec.luau: invariant failed")
		arena.leave("c")
		advance(20)
		assert(arena.snapshot("b").phase == "lobby" and #events == 0, "Adapter.spec.luau: invariant failed")
		assert(arena.dispatch("b", "enqueue", {}).ok, "Adapter.spec.luau: invariant failed")
	end,
	["disconnect forfeits once and rejoin restores rating only"] = function()
		local arena, advance, start, events = setup()
		start()
		arena.leave("b")
		assert(arena.snapshot("a").rating == 1016, "Adapter.spec.luau: invariant failed")
		arena.leave("b")
		advance(100)
		assert(#events == 3, "Adapter.spec.luau: invariant failed")
		local saved = arena.save("a")
		assert(saved.matchId == nil and saved.health == nil, "Adapter.spec.luau: invariant failed")
		arena.leave("a")
		assert(arena.join("a", saved).ok, "Adapter.spec.luau: invariant failed")
		saved.rating = 0
		assert(
			arena.snapshot("a").rating == 1016 and arena.snapshot("a").phase == "lobby",
			"Adapter.spec.luau: invariant failed"
		)
	end,
	["persisted rating controls pairing and duplicate enqueue is refused"] = function()
		local arena = setup()
		assert(
			arena.join("a", { rating = 2000 }).ok and arena.join("b", { rating = 1000 }).ok,
			"Adapter.spec.luau: invariant failed"
		)
		assert(arena.dispatch("a", "enqueue", {}).ok, "Adapter.spec.luau: invariant failed")
		assert(not arena.dispatch("a", "enqueue", {}).ok, "Adapter.spec.luau: invariant failed")
		assert(arena.dispatch("b", "enqueue", {}).ok, "Adapter.spec.luau: invariant failed")
		assert(arena.snapshot("a").queued and arena.snapshot("b").queued, "Adapter.spec.luau: invariant failed")
	end,
	["deadline intent cannot hit and config damage is authoritative"] = function()
		local config = table.clone(Fixture)
		config.attackDamage = 3
		local arena, _, start = setup(config)
		start()
		assert(
			arena.dispatch("a", "attack", {}).ok and arena.snapshot("b").health == 0,
			"Adapter.spec.luau: invariant failed"
		)
		local other, tick, begin = setup()
		begin()
		tick(5)
		assert(
			not other.dispatch("a", "attack", {}).ok and other.snapshot("b").health == 3,
			"Adapter.spec.luau: invariant failed"
		)
	end,
	["config and save reject extra keys nonfinite values and invalid bounds"] = function()
		assert(#Adapter.validateConfig(Fixture) == 0, "Adapter.spec.luau: invariant failed")
		for _, value in { 0 / 0, math.huge, -1 } do
			local bad = table.clone(Fixture)
			bad.attackCooldown = value
			assert(#Adapter.validateConfig(bad) > 0, "Adapter.spec.luau: invariant failed")
			assert(#Adapter.validateSave({ rating = value }) > 0, "Adapter.spec.luau: invariant failed")
		end
		assert(#Adapter.validateSave({ rating = 1000, matchId = 1 }) > 0, "Adapter.spec.luau: invariant failed")
	end,
}
