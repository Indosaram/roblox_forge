--!strict
local Contract = require("../../../core/domain/genre/Contract")
local Stats = require("./Stats")
local Regions = require("./Regions")
local Quests = require("./Quests")
local BossSpawner = require("./BossSpawner")
export type BossDef = { health: number, rewardXp: number }
export type Config = {
	stats: Stats.Config,
	regions: { Regions.RegionDef },
	schedules: BossSpawner.Config,
	bosses: { [string]: BossDef },
	strikeDamage: number,
	quests: { Quests.QuestDef },
	startingBalance: number,
}
export type Save = {
	level: number,
	xp: number,
	points: number,
	balance: number,
	progress: { [string]: { number } },
	claimed: { [string]: boolean },
	unlocked: { [string]: boolean },
}
local M = {}
local LIMIT = 1e9
local function number(value: any, min: number, max: number, integer: boolean?): boolean
	return type(value) == "number"
		and value == value
		and value >= min
		and value <= max
		and value ~= math.huge
		and (not integer or value % 1 == 0)
end
local function id(value: any): boolean
	return type(value) == "string"
		and #value <= 64
		and string.match(value, "^[a-z][a-z0-9%-]*$") ~= nil
		and string.sub(value, -1) ~= "-"
		and string.find(value, "--", 1, true) == nil
end
local function object(value: any, keys: { string }): boolean
	if type(value) ~= "table" then
		return false
	end
	local allowed: { [string]: boolean } = {}
	for _, key in keys do
		allowed[key] = true
	end
	for key in value do
		if not allowed[key] then
			return false
		end
	end
	return true
end
local function array(value: any, min: number, max: number): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for key in value do
		if not number(key, 1, max, true) then
			return false
		end
		count += 1
	end
	return count >= min and count <= max and count == #value
end
local function map(value: any, check: (any) -> boolean): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for key, item in value do
		count += 1
		if count > 64 or not id(key) or not check(item) then
			return false
		end
	end
	return true
end
function M.validateConfig(data: Contract.ConfigData): { string }
	local errors: { string } = {}
	local function check(ok: boolean, path: string)
		if not ok then
			table.insert(errors, path)
		end
	end
	check(
		object(data, { "stats", "regions", "schedules", "bosses", "strikeDamage", "quests", "startingBalance" }),
		"config: unknown keys"
	)
	local stats = data.stats
	check(
		object(stats, { "base", "exp", "pointsPerLevel" })
			and number(stats.base, 1, LIMIT)
			and number(stats.exp, 0.01, 100)
			and number(stats.pointsPerLevel, 0, LIMIT, true),
		"stats"
	)
	check(number(data.strikeDamage, 1, LIMIT), "strikeDamage")
	check(number(data.startingBalance, 0, LIMIT, true), "startingBalance")
	local regionIds: { [string]: boolean } = {}
	if array(data.regions, 1, 64) then
		for _, region in data.regions do
			local valid = object(region, { "id", "name", "requiredLevel" })
				and id(region.id)
				and type(region.name) == "string"
				and #region.name > 0
				and #region.name <= 256
				and number(region.requiredLevel, 1, 1000, true)
				and not regionIds[region.id]
			check(valid, "regions")
			if valid then
				regionIds[region.id] = true
			end
		end
	else
		check(false, "regions")
	end
	check(
		map(data.bosses, function(boss)
			return object(boss, { "health", "rewardXp" })
				and number(boss.health, 1, LIMIT)
				and number(boss.rewardXp, 0, LIMIT)
		end),
		"bosses"
	)
	local bossIds: { [string]: boolean } = {}
	local scheduled: { [string]: boolean } = {}
	if object(data.schedules, { "regions" }) and array(data.schedules.regions, 1, 64) then
		for _, schedule in data.schedules.regions do
			local valid = object(schedule, { "region", "interval", "bossIds" })
				and id(schedule.region)
				and regionIds[schedule.region] == true
				and not scheduled[schedule.region]
				and number(schedule.interval, 0.001, 86400)
				and array(schedule.bossIds, 1, 64)
			check(valid, "schedules")
			if valid then
				scheduled[schedule.region] = true
				for _, bossId in schedule.bossIds do
					local exists = id(bossId)
						and not bossIds[bossId]
						and type(data.bosses) == "table"
						and data.bosses[bossId] ~= nil
					check(exists, "schedules.bossIds")
					if exists then
						bossIds[bossId] = true
					end
				end
			end
		end
	else
		check(false, "schedules")
	end
	if type(data.bosses) == "table" then
		for bossId in data.bosses do
			check(bossIds[bossId] == true, "bosses: unscheduled")
		end
	end
	local questIds: { [string]: boolean } = {}
	if array(data.quests, 1, 64) then
		for _, quest in data.quests do
			local valid = object(quest, { "id", "requirements", "reward" })
				and id(quest.id)
				and not questIds[quest.id]
				and array(quest.requirements, 1, 64)
				and object(quest.reward, { "coins", "xp" })
				and (quest.reward.coins == nil or number(quest.reward.coins, 0, LIMIT, true))
				and (quest.reward.xp == nil or number(quest.reward.xp, 0, LIMIT))
			check(valid, "quests")
			if valid then
				questIds[quest.id] = true
				for _, req in quest.requirements do
					check(
						object(req, { "kind", "target", "count" })
							and req.kind == "defeat"
							and id(req.target)
							and bossIds[req.target] == true
							and number(req.count, 1, LIMIT, true),
						"quests.requirements"
					)
				end
			end
		end
	else
		check(false, "quests")
	end
	table.sort(errors)
	return errors
end
function M.validateSave(data: Contract.StateData): { string }
	if
		not object(data, { "level", "xp", "points", "balance", "progress", "claimed", "unlocked" })
		or not number(data.level, 1, LIMIT, true)
		or not number(data.xp, 0, LIMIT)
		or not number(data.points, 0, LIMIT, true)
		or not number(data.balance, 0, LIMIT, true)
		or not map(data.progress, function(values)
			if not array(values, 1, 64) then
				return false
			end
			for _, value in values do
				if not number(value, 0, LIMIT, true) then
					return false
				end
			end
			return true
		end)
		or not map(data.claimed, function(value)
			return type(value) == "boolean"
		end)
		or not map(data.unlocked, function(value)
			return value == true
		end)
	then
		return { "invalid RPG save" }
	end
	return {}
end
M.number = number
M.id = id
M.array = array
return M
