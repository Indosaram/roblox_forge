--!strict
local Contract = require("../../../core/domain/genre/Contract")
local Stats = require("./Stats")
local Regions = require("./Regions")
local Quests = require("./Quests")
local BossSpawner = require("./BossSpawner")
local Wallet = require("../../../core/domain/economy/Wallet")
local Schema = require("./Schema")
export type BossDef = Schema.BossDef
export type Config = Schema.Config
export type Save = Schema.Save
type Player = {
	stats: Stats.State,
	regions: Regions.Regions,
	quests: Quests.State,
	bosses: BossSpawner.BossSpawner,
	wallet: Wallet.Wallet,
	health: { [string]: number },
	lastStrike: number?,
}
local Adapter = {}
local LIMIT = 1e9
Adapter.validateConfig = Schema.validateConfig
Adapter.validateSave = Schema.validateSave
local number = Schema.number
local id = Schema.id
local array = Schema.array
local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = clone(item)
	end
	return copy
end
function Adapter.create(data: Contract.ConfigData, services: Contract.Services): Contract.Instance
	assert(#Adapter.validateConfig(data) == 0, "invalid RPG config")
	local config = clone(data) :: Config
	local players: { [string]: Player } = {}
	local bossRegions: { [string]: string } = {}
	for _, schedule in config.schedules.regions do
		for _, bossId in schedule.bossIds do
			bossRegions[bossId] = schedule.region
		end
	end
	local lastAdvance: number? = nil
	local function emit(playerId: string, name: string, payload: Contract.StateData)
		services.emit({ genre = "rpg-progression", name = name, playerId = playerId, data = payload })
	end
	local function addXp(playerId: string, player: Player, amount: number)
		local level, gained = Stats.addXp(player.stats, amount)
		if gained > 0 then
			emit(playerId, "LevelChanged", { level = level, gained = gained })
		end
	end
	local function canAddXp(player: Player, amount: number): boolean
		local trial = Stats.new(config.stats, player.stats.level)
		trial.xp, trial.points = player.stats.xp, player.stats.points
		Stats.addXp(trial, amount)
		return number(trial.level, 1, LIMIT, true)
			and number(trial.xp, 0, LIMIT)
			and number(trial.points, 0, LIMIT, true)
	end
	local instance: Contract.Instance = {
		join = function(playerId, saved)
			if players[playerId] then
				return { ok = false, reason = "already joined" }
			end
			local stats = Stats.new(config.stats)
			local regions = Regions.new(config.regions)
			local quests = Quests.new(config.quests)
			local balance = config.startingBalance
			if saved ~= nil then
				if #Adapter.validateSave(saved) > 0 then
					return { ok = false, reason = "invalid save" }
				end
				local save = saved :: Save
				if save.xp >= Stats.xpForLevel(config.stats, save.level) then
					return { ok = false, reason = "invalid residual xp" }
				end
				for questId in save.progress do
					if quests.quests[questId] == nil then
						return { ok = false, reason = "unknown quest" }
					end
				end
				for questId in save.claimed do
					if quests.quests[questId] == nil then
						return { ok = false, reason = "unknown quest" }
					end
				end
				for _, questId in quests.order do
					local progress = save.progress[questId]
					local def = quests.quests[questId]
					if progress == nil or #progress ~= #def.requirements or save.claimed[questId] == nil then
						return { ok = false, reason = "missing quest state" }
					end
					for index, req in def.requirements do
						if progress[index] > req.count or (save.claimed[questId] and progress[index] < req.count) then
							return { ok = false, reason = "invalid quest progress" }
						end
					end
				end
				for regionId in save.unlocked do
					if regions.byId[regionId] == nil then
						return { ok = false, reason = "unknown region" }
					end
				end
				stats.level, stats.xp, stats.points = save.level, save.xp, save.points
				quests.progress, quests.claimed = clone(save.progress), clone(save.claimed)
				for regionId in save.unlocked do
					Regions.unlock(regions, regionId)
				end
				balance = save.balance
			end
			players[playerId] = {
				stats = stats,
				regions = regions,
				quests = quests,
				bosses = BossSpawner.new(config.schedules),
				wallet = Wallet.new({ Coins = balance }),
				health = {},
				lastStrike = nil,
			}
			return { ok = true }
		end,
		leave = function(playerId)
			players[playerId] = nil
		end,
		dispatch = function(playerId, action, args)
			local player = players[playerId]
			if player == nil then
				return { ok = false, reason = "not joined" }
			end
			if not array(args, 1, 1) or not id(args[1]) then
				return { ok = false, reason = "invalid args" }
			end
			local target = args[1] :: string
			if action == "strike-boss" then
				local region = bossRegions[target]
				if region == nil or not Regions.isUnlocked(player.regions, region, player.stats.level) then
					return { ok = false, reason = "locked or unknown boss" }
				end
				if not player.bosses:isActive(target) then
					return { ok = false, reason = "inactive boss" }
				end
				local now = services.now()
				if
					not number(now, 0, math.huge)
					or (lastAdvance ~= nil and now < lastAdvance)
					or (player.lastStrike ~= nil and now < player.lastStrike + 1)
				then
					return { ok = false, reason = "strike cooldown or invalid clock" }
				end
				local health = math.max(0, player.health[target] - config.strikeDamage)
				if health == 0 and not canAddXp(player, config.bosses[target].rewardXp) then
					return { ok = false, reason = "xp limit" }
				end
				player.lastStrike, player.health[target] = now, health
				if health == 0 then
					assert(player.bosses:defeat(target), "active boss disappeared")
					player.health[target] = nil
					Quests.progress(player.quests, { kind = "defeat", target = target, count = 1 })
					addXp(playerId, player, config.bosses[target].rewardXp)
					emit(playerId, "OnBossDefeated", { id = target, region = region })
				end
			elseif action == "claim-quest" then
				local quest = player.quests.quests[target]
				if quest == nil or player.quests.claimed[target] or not Quests.isComplete(player.quests, target) then
					return { ok = false, reason = "quest not claimable" }
				end
				if
					player.wallet:balance("Coins") + (quest.reward.coins or 0) > LIMIT
					or not canAddXp(player, quest.reward.xp or 0)
				then
					return { ok = false, reason = "reward limit" }
				end
				local reward = Quests.claim(player.quests, target)
				assert(reward ~= nil, "RPG invariant: 386")
				if (reward.coins or 0) > 0 then
					player.wallet:credit("Coins", reward.coins :: number)
				end
				addXp(playerId, player, reward.xp or 0)
				emit(playerId, "QuestClaimed", { id = target, coins = reward.coins or 0, xp = reward.xp or 0 })
			else
				return { ok = false, reason = "unknown action" }
			end
			return { ok = true }
		end,
		advance = function(now)
			assert(number(now, 0, math.huge) and (lastAdvance == nil or now >= lastAdvance), "invalid advance clock")
			lastAdvance = now
			local ids: { string } = {}
			for playerId in players do
				table.insert(ids, playerId)
			end
			table.sort(ids)
			for _, playerId in ids do
				local player = players[playerId]
				local spawned = player.bosses:tick(now, function(region)
					return Regions.isUnlocked(player.regions, region, player.stats.level)
				end)
				for _, bossId in spawned do
					player.health[bossId] = config.bosses[bossId].health
					emit(
						playerId,
						"OnBossSpawn",
						{ id = bossId, region = bossRegions[bossId], health = player.health[bossId], spawnedAt = now }
					)
				end
			end
		end,
		snapshot = function(playerId)
			local player = players[playerId]
			if player == nil then
				return {}
			end
			return {
				level = player.stats.level,
				xp = player.stats.xp,
				points = player.stats.points,
				balance = player.wallet:balance("Coins"),
				regions = Regions.unlockedIds(player.regions, player.stats.level),
				activeBosses = clone(player.health),
				quests = { progress = clone(player.quests.progress), claimed = clone(player.quests.claimed) },
			}
		end,
		save = function(playerId)
			local player = players[playerId]
			assert(player ~= nil, "not joined")
			return {
				level = player.stats.level,
				xp = player.stats.xp,
				points = player.stats.points,
				balance = player.wallet:balance("Coins"),
				progress = clone(player.quests.progress),
				claimed = clone(player.quests.claimed),
				unlocked = clone(player.regions.unlocked),
			}
		end,
	}
	return instance
end
return Adapter
