--!strict
local Contract = require("../../../core/domain/genre/Contract")
local Executor = require("../../../core/domain/genre/Executor")
local Schema = require("./Schema")
local bounded, dense, id, keys = Schema.bounded, Schema.dense, Schema.id, Schema.keys
local M = {}
function M.validateConfig(config: Contract.ConfigData): { string }
	if not Executor.data(config) then
		return { "config: expected bounded JSON data" }
	end
	local errors: { string } = {}
	local function check(ok: boolean, name: string)
		if not ok then
			table.insert(errors, name .. ": invalid")
		end
	end
	check(
		keys(config, {
			"currency",
			"startingCoins",
			"maxIncubators",
			"pricing",
			"income",
			"passEffects",
			"sources",
			"sourceOrder",
			"creatures",
			"mergeFamilies",
			"siege",
			"offline",
			"dailyQuests",
			"tutorialSteps",
			"profile",
			"teams",
		}),
		"config"
	)
	check(type(config.currency) == "string" and #config.currency > 0, "currency")
	check(bounded(config.startingCoins, 0, 1e9, true), "startingCoins")
	check(bounded(config.maxIncubators, 1, 64, true), "maxIncubators")
	check(keys(config.pricing, { "growthPerOwned" }) and bounded(config.pricing.growthPerOwned, 0, 100), "pricing")
	check(keys(config.income, { "activeSlots" }) and bounded(config.income.activeSlots, 1, 64, true), "income")
	check(
		keys(config.passEffects, { "coins2xMultiplier", "vipSlotBonus" })
			and bounded(config.passEffects.coins2xMultiplier, 1, 100, true)
			and bounded(config.passEffects.vipSlotBonus, 1, 64, true),
		"passEffects"
	)
	check(keys(config.profile, { "version" }) and config.profile.version == 1, "profile")
	check(
		keys(config.siege, { "period", "duration", "maxTake" })
			and bounded(config.siege.period, 0.001, 86400)
			and bounded(config.siege.duration, 0.001, config.siege.period or 0)
			and config.siege.duration < config.siege.period
			and bounded(config.siege.maxTake, 0, 64, true),
		"siege"
	)
	check(
		keys(config.offline, { "maxSeconds", "efficiency" })
			and bounded(config.offline.maxSeconds, 0, 86400)
			and bounded(config.offline.efficiency, 0, 1)
			and config.offline.efficiency > 0,
		"offline"
	)
	for _, field in { "teams", "sourceOrder", "mergeFamilies", "dailyQuests", "tutorialSteps" } do
		check(dense(config[field], 64), field)
	end
	check(dense(config.teams, 64) and #config.teams >= 2, "teams")
	check(dense(config.sourceOrder, 64) and #config.sourceOrder > 0, "sourceOrder")
	if #errors > 0 then
		table.sort(errors)
		return errors
	end
	for _, field in { "teams", "sourceOrder" } do
		local seen = {}
		for _, value in config[field] do
			check(id(value) and not seen[value], field)
			if id(value) then
				seen[value] = true
			end
		end
	end
	check(type(config.creatures) == "table" and next(config.creatures) ~= nil, "creatures")
	check(type(config.sources) == "table" and next(config.sources) ~= nil, "sources")
	if #errors > 0 then
		table.sort(errors)
		return errors
	end
	local count = 0
	for key, creature in config.creatures do
		count += 1
		check(
			id(key)
				and keys(creature, { "id", "displayName", "rarity", "coinsPerSecond" })
				and creature.id == key
				and type(creature.displayName) == "string"
				and type(creature.rarity) == "string"
				and bounded(creature.coinsPerSecond, 0, 1e9),
			"creatures." .. tostring(key)
		)
	end
	check(count <= 64, "creatures")
	count = 0
	for key, source in config.sources do
		count += 1
		local valid = id(key)
			and table.find(config.sourceOrder, key) ~= nil
			and keys(source, { "id", "displayName", "price", "hatchSeconds", "pool" })
			and source.id == key
			and type(source.displayName) == "string"
			and bounded(source.price, 1, 1e9, true)
			and bounded(source.hatchSeconds, 0, 86400)
			and dense(source.pool, 64)
			and #source.pool > 0
		check(valid, "sources." .. tostring(key))
		if valid then
			local seen = {}
			for _, entry in source.pool do
				local entryOk = keys(entry, { "id", "weight" })
					and id(entry.id)
					and config.creatures[entry.id] ~= nil
					and not seen[entry.id]
					and bounded(entry.weight, 0.001, 1e9)
				check(entryOk, "pool")
				if entryOk then
					seen[entry.id] = true
				end
			end
		end
	end
	check(count == #config.sourceOrder and count <= 64, "sources")
	for _, sourceId in config.sourceOrder do
		check(config.sources[sourceId] ~= nil, "sourceOrder")
	end
	local families = {}
	for _, family in config.mergeFamilies do
		local valid = keys(family, { "id", "displayName", "rules" })
			and id(family.id)
			and not families[family.id]
			and config.sources[family.id] ~= nil
			and type(family.displayName) == "string"
			and dense(family.rules, 64)
		check(valid, "mergeFamilies")
		if valid then
			families[family.id] = true
			for _, rule in family.rules do
				check(
					keys(rule, { "from", "to", "count", "resultId" })
						and type(rule.from) == "string"
						and type(rule.to) == "string"
						and bounded(rule.count, 2, 64, true)
						and id(rule.resultId)
						and config.creatures[rule.resultId] ~= nil,
					"mergeRules"
				)
			end
		end
	end
	for _, field in { "dailyQuests", "tutorialSteps" } do
		local seen = {}
		for _, entry in config[field] do
			local valid = type(entry) == "table" and id(entry.id) and not seen[entry.id]
			if field == "dailyQuests" then
				valid = valid
					and keys(entry, { "id", "target", "reward" })
					and bounded(entry.target, 1, 1e9, true)
					and bounded(entry.reward, 1, 1e9, true)
			else
				valid = valid
					and keys(entry, { "id", "hint", "event" })
					and type(entry.hint) == "string"
					and type(entry.event) == "string"
			end
			check(valid, field)
			if valid then
				seen[entry.id] = true
			end
		end
	end
	table.sort(errors)
	return errors
end
return M
