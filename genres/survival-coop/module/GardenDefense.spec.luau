--!strict
local Shared = require("../../../core/domain/genre/Contract")
local Executor = require("../../../core/domain/genre/Executor")
local GardenDefense = require("./GardenDefense")
local Grow = require("../../grow-harvest/module/Contract")
local Survival = require("./Contract")
local GrowFixture = require("../../grow-harvest/module/Adapter.fixture")
local SurvivalFixture = require("./Adapter.fixture")
local function configs(): { [string]: Shared.ConfigData }
	local grow = GrowFixture.config()
	grow.startingBalance = 0
	local survival = table.clone(SurvivalFixture.config)
	survival.startingBalance = 0
	return { [Grow.id] = grow :: any, [Survival.id] = survival :: any }
end
local function setup(saved: Shared.SaveEnvelope?)
	local now = 0
	local events: { Shared.Event } = {}
	local executor = Executor.new({
		api = 1,
		order = { Grow.id, Survival.id },
		configs = configs(),
		recipe = "garden-defense-v1",
	}, { Grow, Survival }, {
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
	assert(executor.join("p", saved).ok, "join through Executor")
	local function advance(epoch: number)
		now = epoch
		executor.advance(epoch)
	end
	return executor, advance, events
end
local function action(executor: Executor.Executor, id: string, args: { any }, accepted: boolean)
	local result = executor.dispatchClient("p", id, args)
	assert(result.ok == accepted, id .. ": " .. tostring(result.reason))
end
local function funded()
	local executor, advance, events = setup(nil)
	advance(0)
	action(executor, "survival-coop:buy-defense", {}, false)
	action(executor, "grow-harvest:plant", { 1, "carrot" }, true)
	action(executor, "grow-harvest:harvest", { 1 }, false)
	advance(2)
	local state = executor.snapshot("p")
	assert(
		state[Grow.id].plots[1].ready and state[Survival.id].activeWave.enemies == 3,
		"equal-time readiness and native spawn"
	)
	action(executor, "grow-harvest:harvest", { 1 }, true)
	assert(executor.snapshot("p")[Grow.id].inventory.carrot == 1, "harvest holds crop, does not pay")
	action(executor, "grow-harvest:sell-held", { "carrot" }, true)
	assert(executor.snapshot("p")[Grow.id].balance == 10, "native sale funds wallet")
	action(executor, "grow-harvest:sell-held", { "carrot" }, false)
	action(executor, "survival-coop:buy-defense", {}, true)
	action(executor, "survival-coop:buy-defense", {}, false)
	state = executor.snapshot("p")
	assert(state[Grow.id].balance == 0 and state[Survival.id].defensePower == 4, "native debit and upgrade")
	return executor, advance, events
end
local function count(events: { Shared.Event }, name: string): number
	local total = 0
	for _, event in events do
		if event.name == name then
			total += 1
		end
	end
	return total
end
return {
	["canonical recipe metadata and config ownership preflight"] = function()
		assert(Survival.recipe ~= nil and Survival.recipe.id == "garden-defense-v1", "declared recipe")
		assert(
			#Survival.recipe.partners == 2
				and Survival.recipe.partners[1] == Grow.id
				and Survival.recipe.partners[2] == Survival.id,
			"exact canonical partners"
		)
		assert(#GardenDefense.validateConfig(configs()) == 0, "valid composition")
		local bad = configs()
		bad[Survival.id].startingBalance = 10
		assert(#GardenDefense.validateConfig(bad) > 0, "duplicate currency rejected")
		bad = configs()
		bad[Survival.id].currency = "Gems"
		assert(#GardenDefense.validateConfig(bad) > 0, "currency mismatch rejected")
		bad = configs()
		bad[Grow.id].unexpected = true
		assert(#GardenDefense.validateConfig(bad) > 0, "schema remains explicit")
	end,
	["bad composition rejects before constructor clock or event mutation"] = function()
		local calls = 0
		local services: Shared.Services = {
			now = function()
				calls += 1
				return 0
			end,
			roll = function()
				calls += 1
				return 0
			end,
			emit = function(_)
				calls += 1
			end,
		}
		local cases = { configs(), configs(), configs(), configs(), configs() }
		cases[1][Survival.id].startingBalance = 1
		cases[2][Grow.id].currency = "Gems"
		cases[3]["unknown"] = {}
		cases[4][Survival.id] = nil
		cases[5][Grow.id].crops.carrot.growthSeconds = 0
		for _, bad in cases do
			assert(not pcall(GardenDefense.create, bad, services), "invalid recipe rejected")
			assert(calls == 0, "neither adapter constructed before preflight")
		end
	end,
	["native baseline loses while farm sale upgrade wins and rewards once"] = function()
		local baseline, tick, baselineEvents = setup(nil)
		tick(0)
		tick(2)
		action(baseline, "survival-coop:defend-active", {}, true)
		local state = baseline.snapshot("p")
		assert(
			state[Survival.id].lastWaveWon == false and state[Grow.id].balance == 0,
			"defense one loses against three"
		)
		assert(count(baselineEvents, "OnWaveResolved") == 1, "one native baseline resolution")
		local executor, _, events = funded()
		action(executor, "survival-coop:defend-active", {}, true)
		state = executor.snapshot("p")
		assert(
			state[Survival.id].lastWaveWon == true and state[Survival.id].lastResolvedWave == 1,
			"native first wave won"
		)
		assert(
			state[Grow.id].balance == 5 and state[Survival.id].balance == 5 and state[Grow.id].inventory.carrot == 0,
			"one shared reward and consumed inventory"
		)
		action(executor, "survival-coop:defend-active", {}, false)
		assert(executor.snapshot("p")[Grow.id].balance == 5, "duplicate reward refused")
		assert(
			count(events, "OnPlant") == 1
				and count(events, "OnHarvest") == 1
				and count(events, "CropSold") == 1
				and count(events, "DefenseBought") == 1
				and count(events, "OnWaveSpawn") == 1
				and count(events, "OnWaveResolved") == 1,
			"one lifecycle and each successful mutation hook once"
		)
	end,
	["one balance slice survives same server and fresh server rejoin without reward replay"] = function()
		local executor, _, events = funded()
		action(executor, "survival-coop:defend-active", {}, true)
		local saved = executor.save("p")
		assert(
			saved.version == 1 and saved.genres[Grow.id].version == 1 and saved.genres[Survival.id].version == 1,
			"versioned envelope"
		)
		assert(
			saved.genres[Grow.id].data.balance == 5
				and saved.genres[Survival.id].data.balance == nil
				and saved.genres[Survival.id].data.upgradeLevel == 1,
			"one persisted balance owner"
		)
		local slices = 0
		for _ in saved.genres do
			slices += 1
		end
		assert(slices == 2 and #Executor.validateSave(saved, { Grow, Survival }) == 0, "exact two valid slices")
		executor.leave("p")
		executor.leave("p")
		assert(executor.join("p", saved).ok and not executor.join("p", saved).ok, "one lifecycle per membership")
		action(executor, "survival-coop:defend-active", {}, false)
		assert(
			executor.snapshot("p")[Grow.id].balance == 5 and count(events, "OnWaveResolved") == 1,
			"same server no replay"
		)
		local fresh, _, restoredEvents = setup(saved)
		local state = fresh.snapshot("p")
		assert(
			state[Grow.id].balance == 5
				and state[Grow.id].inventory.carrot == 0
				and state[Survival.id].upgradeLevel == 1,
			"persisted economy and defense"
		)
		assert(
			state[Survival.id].waveIndex == 0 and state[Survival.id].activeWave == nil and #restoredEvents == 0,
			"server wave state is ephemeral"
		)
		action(fresh, "survival-coop:defend-active", {}, false)
		assert(fresh.snapshot("p")[Grow.id].balance == 5, "fresh server no reward replay")
		saved.genres[Survival.id].data.balance = 5
		executor.leave("p")
		assert(not executor.join("p", saved).ok, "second persisted balance rejected")
		assert(executor.join("p", nil).ok, "failed join rolls back farm lifecycle")
	end,
	["Executor rejects malicious intents and unsupported recipe metadata without economic mutation"] = function()
		local executor, _, events = funded()
		local before = executor.save("p")
		for _, args in { { 99 }, { 4, 1 }, { 0 / 0 }, { math.huge }, { [2] = 1 }, { power = 999 } } do
			action(executor, "survival-coop:defend-active", args, false)
		end
		assert(
			not executor.dispatchServer("p", "survival-coop:defend-active", {}).ok,
			"client action cannot change origin"
		)
		assert(
			not executor.dispatchClient("forged", "survival-coop:defend-active", {}).ok,
			"server membership enforced"
		)
		assert(
			executor.save("p").genres[Grow.id].data.balance == before.genres[Grow.id].data.balance
				and count(events, "OnWaveResolved") == 0,
			"bad ingress leaves wave and wallet untouched"
		)
		for _, recipe in { "unknown", "garden-defense-v2" } do
			assert(
				not pcall(
					Executor.new,
					{ api = 1, order = { Grow.id, Survival.id }, configs = configs(), recipe = recipe },
					{ Grow, Survival },
					{
						now = function()
							return 0
						end,
						roll = function()
							return 0
						end,
						emit = function(_)
							error("unexpected mutation")
						end,
					}
				),
				"undeclared recipe rejected"
			)
		end
	end,
}
