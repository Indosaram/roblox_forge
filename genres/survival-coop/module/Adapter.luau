--!strict
local Shared = require("../../../core/domain/genre/Contract")
local Wallet = require("../../../core/domain/economy/Wallet")
local SurvivalCoop = require("./SurvivalCoop")
export type Config = SurvivalCoop.Config & {
	currency: string,
	baseDefense: number,
	upgradeCost: number,
	upgradePower: number,
	winReward: number,
	startingBalance: number,
}
export type Save = { upgradeLevel: number, balance: number? }
export type WalletPort = {
	balance: (Shared.PlayerId) -> number,
	debit: (Shared.PlayerId, number) -> boolean,
	credit: (Shared.PlayerId, number) -> (),
}
type Player = { upgradeLevel: number, wallet: Wallet.Wallet? }
local Adapter = {}
local LIMIT = 1e9
local function bounded(value: any, minimum: number, maximum: number, integer: boolean): boolean
	return type(value) == "number"
		and value == value
		and value >= minimum
		and value <= maximum
		and (not integer or value % 1 == 0)
end
function Adapter.validateConfig(data: Shared.ConfigData): { string }
	local errors = {}
	local fields = {
		"waveInterval",
		"baseEnemies",
		"growth",
		"baseDefense",
		"upgradeCost",
		"upgradePower",
		"winReward",
		"startingBalance",
	}
	local allowed: { [string]: boolean } = { currency = true }
	for _, key in fields do
		allowed[key] = true
		local minimum = if key == "baseEnemies" or key == "upgradeCost" then 1 else 0
		if
			not bounded(data[key], minimum, if key == "waveInterval" then 86400 else LIMIT, key ~= "waveInterval")
			or (key == "waveInterval" and data[key] == 0)
		then
			table.insert(errors, key .. ": invalid bounded number")
		end
	end
	if data.currency ~= "Coins" then
		table.insert(errors, "currency: expected Coins")
	end
	for key in data do
		if not allowed[key] then
			table.insert(errors, key .. ": unknown config key")
		end
	end
	table.sort(errors)
	return errors
end
function Adapter.validateSave(data: Shared.StateData): { string }
	local errors = {}
	if not bounded(data.upgradeLevel, 0, LIMIT, true) then
		table.insert(errors, "upgradeLevel: invalid integer")
	end
	if data.balance ~= nil and not bounded(data.balance, 0, LIMIT, true) then
		table.insert(errors, "balance: invalid integer")
	end
	for key in data do
		if key ~= "upgradeLevel" and key ~= "balance" then
			table.insert(errors, key .. ": unknown save key")
		end
	end
	table.sort(errors)
	return errors
end
function Adapter.new(config: Config, services: Shared.Services, suppliedWallet: WalletPort?): Shared.Instance
	assert(#Adapter.validateConfig(config :: any) == 0, "invalid survival config")
	config = table.clone(config)
	assert(suppliedWallet == nil or config.startingBalance == 0, "composition requires zero survival starting balance")
	local players: { [string]: Player } = {}
	local wallet: WalletPort = suppliedWallet
		or {
			balance = function(id)
				return (players[id].wallet :: Wallet.Wallet):balance(config.currency)
			end,
			debit = function(id, amount)
				return (players[id].wallet :: Wallet.Wallet):debit(config.currency, amount)
			end,
			credit = function(id, amount)
				(players[id].wallet :: Wallet.Wallet):credit(config.currency, amount)
			end,
		}
	local active: SurvivalCoop.Wave? = nil
	local participants: { [string]: Player } = {}
	local lastWaveWon: boolean? = nil
	local lastResolved = 0
	local lastAt = services.now()
	assert(type(lastAt) == "number" and lastAt == lastAt and math.abs(lastAt) < math.huge, "invalid initial clock")
	local function emit(name: string, id: string?, data: Shared.StateData)
		services.emit({ genre = "survival-coop", name = name, playerId = id, data = data })
	end
	local resolution: SurvivalCoop.Resolution? = nil
	local coop = SurvivalCoop.new(config, {
		OnWaveSpawn = function(wave)
			active = wave
			participants = table.clone(players)
			emit("OnWaveSpawn", nil, { index = wave.index, enemies = wave.enemies })
		end,
		OnWaveResolved = function(value)
			resolution = value
		end,
	})
	return {
		stageCommand = function(id, action, args)
			if action ~= "buy-defense" or suppliedWallet ~= nil or next(args) ~= nil then
				return nil
			end
			local player = players[id]
			if not player then
				return nil
			end
			local balance = wallet.balance(id)
			local affordable = player.upgradeLevel < LIMIT and balance >= config.upgradeCost
			local level = player.upgradeLevel + (if affordable then 1 else 0)
			local remaining = balance - (if affordable then config.upgradeCost else 0)
			return {
				result = if affordable then { ok = true } else { ok = false, reason = "cannot afford defense" },
				data = { upgradeLevel = level, balance = remaining },
				apply = function()
					if affordable then
						player.wallet = Wallet.new({ [config.currency] = remaining })
						player.upgradeLevel = level
						emit("DefenseBought", id, { upgradeLevel = level, balance = remaining })
					end
				end,
			}
		end,
		join = function(id, saved)
			if players[id] ~= nil then
				return { ok = false, reason = "already joined" }
			end
			if saved ~= nil then
				if
					#Adapter.validateSave(saved) > 0
					or (suppliedWallet == nil and saved.balance == nil)
					or (suppliedWallet ~= nil and saved.balance ~= nil)
				then
					return { ok = false, reason = "invalid save or currency owner" }
				end
			end
			players[id] = {
				upgradeLevel = if saved then saved.upgradeLevel else 0,
				wallet = if suppliedWallet
					then nil
					else Wallet.new({ [config.currency] = if saved then saved.balance else config.startingBalance }),
			}
			return { ok = true }
		end,
		leave = function(id)
			players[id] = nil
			participants[id] = nil
			if active ~= nil and next(participants) == nil then
				-- Abandoned waves are canceled silently, never defended or rewarded.
				active = nil
			end
		end,
		dispatch = function(id, action, args)
			local player = players[id]
			if player == nil then
				return { ok = false, reason = "not joined" }
			end
			if next(args) ~= nil then
				return { ok = false, reason = "expected empty tuple" }
			end
			if action == "buy-defense" then
				if player.upgradeLevel >= LIMIT or not wallet.debit(id, config.upgradeCost) then
					return { ok = false, reason = "cannot afford defense" }
				end
				player.upgradeLevel += 1
				emit("DefenseBought", id, { upgradeLevel = player.upgradeLevel, balance = wallet.balance(id) })
				return { ok = true }
			elseif action == "defend-active" then
				local wave = active
				if wave == nil or participants[id] ~= player then
					return { ok = false, reason = "no eligible active wave" }
				end
				local power = 0
				for participantId, enrolled in participants do
					if players[participantId] == enrolled then
						power += config.baseDefense + config.upgradePower * enrolled.upgradeLevel
					end
				end
				if power >= wave.enemies and config.winReward > 0 then
					for participantId, enrolled in participants do
						if
							players[participantId] == enrolled
							and wallet.balance(participantId) > LIMIT - config.winReward
						then
							return { ok = false, reason = "reward exceeds balance limit" }
						end
					end
				end
				-- Commit resolution before native callbacks and reward emission.
				active = nil
				lastResolved = wave.index
				lastWaveWon = coop:defend(wave.index, power)
				if lastWaveWon and config.winReward > 0 then
					for participantId, enrolled in participants do
						if players[participantId] == enrolled then
							wallet.credit(participantId, config.winReward)
						end
					end
				end
				local settled = resolution :: SurvivalCoop.Resolution
				emit("OnWaveResolved", id, {
					index = settled.index,
					enemies = settled.enemies,
					defensePower = settled.defensePower,
					won = settled.won,
				})
				participants = {}
				return { ok = true }
			end
			return { ok = false, reason = "unknown action" }
		end,
		advance = function(now)
			assert(bounded(now, lastAt, math.huge, false) and now < math.huge, "invalid authoritative time")
			lastAt = now
			if active == nil and next(players) ~= nil then
				coop:tick(now)
			end
		end,
		snapshot = function(id)
			local player = players[id]
			if player == nil then
				return {}
			end
			local roster = {}
			for participantId, enrolled in participants do
				if players[participantId] == enrolled then
					table.insert(roster, participantId)
				end
			end
			table.sort(roster)
			return {
				balance = wallet.balance(id),
				upgradeLevel = player.upgradeLevel,
				defensePower = config.baseDefense + config.upgradePower * player.upgradeLevel,
				activeWave = if active then { index = active.index, enemies = active.enemies } else nil,
				participants = roster,
				waveIndex = coop:waveIndex(),
				day = coop:waveIndex() + 1,
				lastWaveWon = lastWaveWon,
				lastResolvedWave = lastResolved,
				nextWaveAt = coop:nextWaveAt(),
			}
		end,
		save = function(id)
			local player = players[id]
			assert(player ~= nil, "player not joined")
			return { upgradeLevel = player.upgradeLevel, balance = if suppliedWallet then nil else wallet.balance(id) }
		end,
	}
end
return Adapter
