--!strict
local Companion = require("./CombatCompanion")
local rules = {
	capacity = 8,
	feedItem = "feed",
	feedCount = 3,
	trainingMillis = 300000,
	maxSatiety = 100,
	feedSatiety = 30,
	hungerMillis = 60000,
	downMillis = 60000,
}
local function trained(): Companion.State
	local state = assert(Companion.capture(Companion.new({ feed = 4, saddle = 1 }, 0), "pet", "deer", rules))
	for index, action in { "place", "train", "feed", "feed", "feed", "claim", "saddle", "deploy", "mount" } do
		state = assert(Companion.command(state, "r" .. index, action, "pet", if index >= 6 then 300000 else 0, rules))
	end
	return state
end
return {
	["training consumes three feed and mount state survives a detached save"] = function()
		local state = trained()
		assert(state.materials.feed == 1 and state.materials.saddle == 0 and state.ride == "pet", "materials and mount")
		local again = assert(Companion.command(state, "r9", "mount", "pet", 300000, rules))
		assert(again == state, "receipt replay")
		assert(
			select(2, Companion.command(state, "r9", "feed", "pet", 300000, rules)) == "REQUEST_CONFLICT",
			"bound receipt"
		)
	end,
	["negative materials free feeding early claim duplicate capture and unsafe release are refused"] = function()
		assert(not pcall(Companion.new, { feed = -1 }, 0), "negative materials")
		local state = assert(Companion.capture(Companion.new({}, 0), "pet", "deer", rules))
		assert(select(2, Companion.capture(state, "pet", "deer", rules)) == "ALREADY_CAPTURED", "duplicate")
		state = assert(Companion.command(state, "p", "place", "pet", 0, rules))
		state = assert(Companion.command(state, "t", "train", "pet", 0, rules))
		assert(select(2, Companion.command(state, "f", "feed", "pet", 0, rules)) == "NO_FEED", "no free training")
		assert(
			select(2, Companion.command(state, "c", "claim", "pet", 300000, rules)) == "NOT_READY",
			"timer alone insufficient"
		)
		assert(
			select(2, Companion.command(state, "rel", "release:pet", "pet", 0, rules)) == "RELEASE_PHASE",
			"cancel training first"
		)
	end,
	["defeat retains cargo and empty stored release frees capacity without spawning rewards"] = function()
		local state = trained()
		state.pets.pet.cargo = 2
		state = assert(Companion.command(state, "down", "defeat", "pet", 300000, rules))
		assert(state.ride == nil and state.pets.pet.cargo == 2, "retains cargo")
		assert(
			select(2, Companion.command(state, "early", "recover", "pet", 359999, rules)) == "NOT_READY",
			"down window"
		)
		state = assert(Companion.command(state, "recover", "recover", "pet", 360000, rules))
		assert(
			select(2, Companion.command(state, "release", "release:pet", "pet", 360000, rules))
				== "RELEASE_CARGO_OR_INJURY",
			"cargo retained"
		)
		state.pets.pet.cargo = 0
		state = assert(Companion.command(state, "release", "release:pet", "pet", 360000, rules))
		assert(next(state.pets) == nil and state.materials.feed == 1, "one slot freed no reward")
	end,
	["only online deployed pets hunger and zero satiety blocks ride"] = function()
		local state = trained()
		state.lastMillis = 300000
		state = Companion.tick(state, 6300000, rules)
		assert(state.pets.pet.satiety == 0 and state.ride == nil, "hungry ride stops")
		assert(
			select(2, Companion.command(state, "hungry", "mount", "pet", 6300000, rules)) == "MOUNT_GATED",
			"hungry gate"
		)
	end,
}
