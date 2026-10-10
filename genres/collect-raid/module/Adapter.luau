--!strict
local Contract = require("../../../core/domain/genre/Contract")
local Executor = require("../../../core/domain/genre/Executor")
local Loop = require("./runtime/Loop")
local Native = require("./CollectRaid")
local Siege = require("../../../core/domain/state/Siege")
local M = {}
export type Config = Loop.Config & { teams: { string } }
type Token = { id: string, locked: boolean, owner: string, team: string }
M.validateConfig = require("./ConfigSchema").validateConfig
M.validateSave = require("./SaveSchema").validateSave
function M.create(raw: Contract.ConfigData, services: Contract.Services): Contract.Instance
	assert(#M.validateConfig(raw) == 0, "invalid collect config")
	local config = Executor.clone(raw) :: Config
	config.profile = {
		version = 1,
		defaults = function()
			return {}
		end,
	}
	local states: { [string]: Loop.PlayerState } = {}
	local accruedAt: { [string]: number } = {}
	local teams: { [string]: string } = {}
	local tokens: { Token } = {}
	local joined = 0
	local epoch = services.now()
	local start = epoch
	local restoring = false
	local function emit(name: string, data: Contract.StateData, playerId: string?)
		if not restoring then
			services.emit({ genre = "collect-raid", name = name, playerId = playerId, data = data })
		end
	end
	local native: Native.CollectRaid
	local function rebuild()
		native = Native.new({ teams = config.teams, siege = config.siege }, {
			OnCollect = function(ctx)
				emit("OnCollect", { team = ctx.team, itemId = ctx.itemId, raidable = ctx.raidable })
			end,
			OnRaid = function(ctx)
				emit("OnRaid", { attacker = ctx.attacker, defender = ctx.defender, moved = ctx.moved })
			end,
			OnSiegePhase = function(ctx)
				emit("OnSiegePhase", { phase = ctx.phase, secondsLeft = ctx.secondsLeft })
			end,
		})
		restoring = true
		for _, token in tokens do
			native:collect(token.team, token.id, not token.locked)
		end
		native:phase(epoch - start)
		restoring = false
	end
	rebuild()
	local function tokenCount(playerId: string): number
		local count = 0
		for _, token in tokens do
			if token.owner == playerId then
				count += 1
			end
		end
		return count
	end
	local function settle(playerId: string, now: number)
		Loop.tick(config, states[playerId], now - accruedAt[playerId], 1, now)
		accruedAt[playerId] = now
	end
	local instance: Contract.Instance = {} :: Contract.Instance
	function instance.join(playerId, saved)
		if states[playerId] then
			return { ok = false, reason = "already joined" }
		end
		if saved then
			if #M.validateSave(saved) > 0 or not table.find(config.teams, saved.team) then
				return { ok = false, reason = "invalid save" }
			end
			for _, field in { "creatures", "vaultedCreatures" } do
				for _, creature in saved.loop[field] do
					if config.creatures[creature] == nil then
						return { ok = false, reason = "unknown saved creature" }
					end
				end
			end
			for _, inc in saved.loop.incubators do
				if config.sources[inc.sourceId] == nil then
					return { ok = false, reason = "unknown saved source" }
				end
			end
			for _, token in saved.tokens do
				if config.creatures[token.id] == nil then
					return { ok = false, reason = "unknown saved token" }
				end
			end
			teams[playerId] = saved.team
			states[playerId] = Loop.fromSave(config, saved.loop, services.now())
			for _, token in saved.tokens do
				table.insert(tokens, { id = token.id, locked = token.locked, owner = playerId, team = saved.team })
			end
			rebuild()
		else
			joined += 1
			teams[playerId] = config.teams[(joined - 1) % #config.teams + 1]
			states[playerId] = Loop.newPlayer(config, services.now())
		end
		accruedAt[playerId] = services.now()
		return { ok = true }
	end
	function instance.leave(playerId)
		states[playerId], teams[playerId] = nil, nil
		accruedAt[playerId] = nil
		local kept: { Token } = {}
		for _, token in tokens do
			if token.owner ~= playerId then
				table.insert(kept, token)
			end
		end
		tokens = kept
		rebuild()
	end
	function instance.snapshot(playerId)
		local result = Loop.snapshot(config, states[playerId], services.now()) :: any
		result.team = teams[playerId]
		result.counts = native:counts()
		result.totalCounts = native:totalCounts()
		result.shieldUntil = states[playerId].shieldUntil
		return result
	end
	function instance.save(playerId)
		local now = services.now()
		settle(playerId, now)
		local savedTokens = {}
		for _, token in tokens do
			if token.owner == playerId then
				table.insert(savedTokens, { id = token.id, locked = token.locked })
			end
		end
		return {
			loop = Loop.toSave(config, states[playerId], now),
			team = teams[playerId],
			tokens = savedTokens,
		}
	end
	function instance.advance(now)
		for playerId in states do
			settle(playerId, now)
		end
		epoch = now
		native:phase(now - start)
	end
	function instance.dispatch(playerId, action, args)
		local state = states[playerId]
		if not state then
			return { ok = false, reason = "not joined" }
		end
		local now = services.now()
		local ok: boolean, reason: string? = false, "unknown action"
		if action == "buy-source" then
			settle(playerId, now)
			ok, reason = Loop.buySource(config, state, args[1], now)
			if ok then
				emit("SourceBought", { sourceId = args[1] }, playerId)
			end
		elseif action == "hatch" then
			if #state.creatures >= Loop.SAVE_CAPACITY then
				return { ok = false, reason = "creatures full" }
			end
			settle(playerId, now)
			local creature: string
			ok, creature = Loop.hatch(config, state, args[1], now, services.roll())
			reason = if ok then nil else creature
			if ok then
				emit("Hatched", { creatureId = creature }, playerId)
			end
		elseif action == "merge" then
			for _, family in config.mergeFamilies do
				if family.id == args[1] and family.rules[args[2]] then
					settle(playerId, now)
					local creature: string?
					ok, creature, reason = Loop.merge(config, state, family, family.rules[args[2]])
					if ok then
						emit("Merged", { creatureId = creature }, playerId)
					end
					break
				end
			end
		elseif action == "claim-quest" then
			if state.quest.quests[args[1]] == nil then
				return { ok = false, reason = "unknown quest" }
			end
			settle(playerId, now)
			ok = Loop.claimQuest(config, state, args[1])
			if ok then
				emit("QuestClaimed", { questId = args[1] }, playerId)
			end
		elseif action == "collect" then
			if config.creatures[args[1]] == nil then
				return { ok = false, reason = "unknown creature" }
			end
			if tokenCount(playerId) >= Loop.SAVE_CAPACITY then
				return { ok = false, reason = "tokens full" }
			end
			table.insert(tokens, { id = args[1], locked = args[2], owner = playerId, team = teams[playerId] })
			native:collect(teams[playerId], args[1], not args[2])
			ok = true
		elseif action == "raid" then
			local target = args[1]
			if not table.find(config.teams, target) then
				return { ok = false, reason = "unknown team" }
			end
			local shielded = false
			for defender, team in teams do
				if team == target and Loop.isShielded(states[defender], now) then
					shielded = true
				end
			end
			-- Mirror native FIFO movement before emitting its committed raid hook.
			local phase = Siege.phase(config.siege, now - start)
			if phase ~= "active" or shielded or target == teams[playerId] then
				return { ok = false, reason = "raid refused" }
			end
			local take = 0
			for _, token in tokens do
				if token.team == target and not token.locked then
					take += 1
				end
			end
			if tokenCount(playerId) + math.min(take, config.siege.maxTake) > Loop.SAVE_CAPACITY then
				return { ok = false, reason = "tokens full" }
			end
			settle(playerId, now)
			local remaining = config.siege.maxTake
			for _, token in tokens do
				if remaining > 0 and token.team == target and not token.locked then
					token.team, token.owner = teams[playerId], playerId
					remaining -= 1
				end
			end
			local moved: number
			moved, reason = native:raid(teams[playerId], target, now - start, shielded)
			ok = reason == nil and moved > 0
			if ok then
				Loop.recordQuest(state, "raid", 1)
			end
		end
		return { ok = ok, reason = if ok then nil else reason or "refused" }
	end
	return instance
end
return M
