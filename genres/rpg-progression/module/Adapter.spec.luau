--!strict
local Adapter = require("./Adapter")
local Fixture = require("./Adapter.fixture")
local Types = require("../../../core/domain/genre/Contract")
local Executor = require("../../../core/domain/genre/Executor")
local Runtime = require("./Contract")
local function setup()
	local now = 0
	local events: { Types.Event } = {}
	local services: Types.Services = {
		now = function()
			return now
		end,
		roll = function()
			return 0
		end,
		emit = function(event)
			table.insert(events, event)
		end,
	}
	local instance = Adapter.create(Fixture :: any, services)
	assert(instance.join("a", nil).ok, "RPG invariant: 22")
	return instance, function(time: number)
		now = time
	end, events
end
local function equal(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end
local function rejectUnchanged(instance: Types.Instance, action: string, args: { any })
	local before = instance.snapshot("a")
	assert(not instance.dispatch("a", action, args).ok, "RPG invariant: 48")
	assert(equal(before, instance.snapshot("a")), "rejection mutated state")
end
return {
	["native boss health cooldown defeat level gates and claim once"] = function()
		local instance, clock, events = setup()
		assert(next(instance.snapshot("a").activeBosses) == nil, "RPG invariant: 54")
		instance.advance(0)
		instance.advance(1.999)
		assert(next(instance.snapshot("a").activeBosses) == nil, "RPG invariant: 57")
		instance.advance(2)
		clock(2)
		assert(instance.snapshot("a").activeBosses.slime == 2, "RPG invariant: 60")
		assert(instance.snapshot("a").activeBosses.golem == nil, "RPG invariant: 61")
		rejectUnchanged(instance, "strike-boss", { "golem" })
		rejectUnchanged(instance, "claim-quest", { "first-boss" })
		assert(instance.dispatch("a", "strike-boss", { "slime" }).ok, "RPG invariant: 64")
		assert(
			instance.snapshot("a").activeBosses.slime == 1 and instance.snapshot("a").level == 1,
			"RPG invariant: 65"
		)
		clock(2.999)
		rejectUnchanged(instance, "strike-boss", { "slime" })
		clock(3)
		assert(instance.dispatch("a", "strike-boss", { "slime" }).ok, "RPG invariant: 69")
		local state = instance.snapshot("a")
		assert(
			state.activeBosses.slime == nil and state.level == 2 and state.xp == 0 and state.points == 1,
			"RPG invariant: 71"
		)
		assert(state.regions[2] == "ridge" and state.quests.progress["first-boss"][1] == 1, "RPG invariant: 72")
		rejectUnchanged(instance, "strike-boss", { "slime" })
		assert(instance.dispatch("a", "claim-quest", { "first-boss" }).ok, "RPG invariant: 74")
		assert(instance.snapshot("a").balance == 5, "RPG invariant: 75")
		rejectUnchanged(instance, "claim-quest", { "first-boss" })
		instance.advance(3)
		instance.advance(5)
		assert(instance.snapshot("a").activeBosses.golem == 4, "RPG invariant: 79")
		local counts: { [string]: number } = {}
		for _, event in events do
			counts[event.name] = (counts[event.name] or 0) + 1
		end
		assert(
			counts.OnBossDefeated == 1 and counts.LevelChanged == 1 and counts.QuestClaimed == 1,
			"RPG invariant: 84"
		)
	end,
	["malicious tuples clock and unknown actions cannot mutate"] = function()
		local instance, clock, events = setup()
		instance.advance(0)
		instance.advance(2)
		clock(2)
		local invalid: { { any } } = {
			{},
			{ "slime", 999 },
			{ [2] = "slime" },
			{ [1] = "slime", damage = 999 },
			{ 0 / 0 },
			{ math.huge },
			{ "missing" },
		}
		for _, args in invalid do
			rejectUnchanged(instance, "strike-boss", args :: any)
		end
		rejectUnchanged(instance, "defeat", { "slime" })
		clock(0 / 0)
		rejectUnchanged(instance, "strike-boss", { "slime" })
		clock(math.huge)
		rejectUnchanged(instance, "strike-boss", { "slime" })
		clock(1)
		rejectUnchanged(instance, "strike-boss", { "slime" })
		assert(#events == 1, "RPG invariant: 111")
		assert(not pcall(function()
			instance.advance(1)
		end), "RPG invariant: 112")
		assert(instance.snapshot("a").activeBosses.slime == 2, "RPG invariant: 115")
	end,
	["validated saves clone state and reset boss sessions without rewards"] = function()
		local instance, clock = setup()
		instance.advance(0)
		instance.advance(2)
		clock(2)
		assert(instance.dispatch("a", "strike-boss", { "slime" }).ok, "RPG invariant: 122")
		clock(3)
		assert(instance.dispatch("a", "strike-boss", { "slime" }).ok, "RPG invariant: 124")
		assert(instance.dispatch("a", "claim-quest", { "first-boss" }).ok, "RPG invariant: 125")
		local save = instance.save("a")
		assert(#Adapter.validateSave(save) == 0 and save.health == nil and save.lastStrike == nil, "RPG invariant: 127")
		instance.leave("a")
		assert(instance.join("a", save).ok, "RPG invariant: 129")
		assert(
			next(instance.snapshot("a").activeBosses) == nil and instance.snapshot("a").balance == 5,
			"RPG invariant: 130"
		)
		save.balance = 99
		save.progress["first-boss"][1] = 0
		save.claimed["first-boss"] = false
		assert(
			instance.snapshot("a").balance == 5 and instance.snapshot("a").quests.claimed["first-boss"],
			"RPG invariant: 134"
		)
		rejectUnchanged(instance, "claim-quest", { "first-boss" })
		local exported = instance.snapshot("a")
		exported.quests.claimed["first-boss"] = false
		assert(instance.snapshot("a").quests.claimed["first-boss"], "RPG invariant: 138")
		instance.advance(3)
		instance.advance(4.999)
		assert(next(instance.snapshot("a").activeBosses) == nil, "RPG invariant: 141")
		instance.advance(5)
		assert(instance.snapshot("a").activeBosses.slime == 2, "RPG invariant: 143")
	end,
	["invalid save joins leave membership and events unchanged"] = function()
		local instance, _, events = setup()
		local valid = instance.save("a")
		for _, edit in
			{
				function(s: any)
					s.balance = math.huge
				end,
				function(s: any)
					s.level = 0
				end,
				function(s: any)
					s.version = 2
				end,
				function(s: any)
					s.xp = 10
				end,
				function(s: any)
					s.progress["unknown"] = { 1 }
				end,
				function(s: any)
					s.progress["first-boss"] = { 2 }
				end,
				function(s: any)
					s.claimed["first-boss"] = true
				end,
				function(s: any)
					s.unlocked.unknown = true
				end,
			}
		do
			local bad = Executor.clone(valid)
			edit(bad)
			assert(not instance.join("b", bad).ok and next(instance.snapshot("b")) == nil, "RPG invariant: 178")
		end
		local unlocked = Executor.clone(valid)
		unlocked.unlocked.ridge = true
		assert(instance.join("b", unlocked).ok and instance.snapshot("b").regions[2] == "ridge", "RPG invariant: 182")
		assert(#events == 0 and instance.snapshot("a").balance == 0, "RPG invariant: 183")
	end,
	["config rejects unknown fields duplicate bosses references and nonfinite values"] = function()
		assert(#Adapter.validateConfig(Fixture :: any) == 0, "RPG invariant: 186")
		for _, edit in
			{
				function(c: any)
					c.damage = 100
				end,
				function(c: any)
					c.strikeDamage = 0 / 0
				end,
				function(c: any)
					c.bosses.slime.health = math.huge
				end,
				function(c: any)
					c.schedules.regions[2].bossIds = { "slime" }
				end,
				function(c: any)
					c.quests[1].requirements[1].target = "unknown"
				end,
				function(c: any)
					c.regions[2].requiredLevel = 1001
				end,
				function(c: any)
					c.regions[3] = c.regions[2]
				end,
			}
		do
			local bad = Executor.clone(Fixture)
			edit(bad)
			assert(#Adapter.validateConfig(bad) > 0, "RPG invariant: 214")
		end
	end,
	["actual Executor rejects forged authority and future slices"] = function()
		local now = 0
		local executor = Executor.new(
			{ api = 1, order = { "rpg-progression" }, configs = { ["rpg-progression"] = Fixture :: any } },
			{ Runtime },
			{
				now = function()
					return now
				end,
				roll = function()
					return 0
				end,
				emit = function() end,
			},
			nil
		)
		assert(executor.join("a", nil).ok, "RPG invariant: 233")
		executor.advance(0)
		now = 2
		executor.advance(2)
		assert(
			not executor.dispatchClient("a", "rpg-progression:strike-boss", { "slime", 999 }).ok,
			"RPG invariant: 237"
		)
		assert(
			not executor.dispatchClient("forged", "rpg-progression:strike-boss", { "slime" }).ok,
			"RPG invariant: 238"
		)
		assert(executor.dispatchClient("a", "rpg-progression:strike-boss", { "slime" }).ok, "RPG invariant: 239")
		now = 3
		assert(executor.dispatchClient("a", "rpg-progression:strike-boss", { "slime" }).ok, "RPG invariant: 241")
		assert(executor.dispatchClient("a", "rpg-progression:claim-quest", { "first-boss" }).ok, "RPG invariant: 242")
		local save = executor.save("a")
		executor.leave("a")
		save.genres["rpg-progression"].version = 2
		assert(not executor.join("a", save).ok, "RPG invariant: 246")
		save.genres["rpg-progression"].version = 1
		assert(
			executor.join("a", save).ok and executor.snapshot("a")["rpg-progression"].balance == 5,
			"RPG invariant: 248"
		)
	end,
}
