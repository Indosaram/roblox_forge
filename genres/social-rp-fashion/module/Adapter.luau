--!strict
local Types = require("../../../core/domain/genre/Contract")
local Outfit = require("./Outfit")
local ThemeRound = require("./ThemeRound")
local Voting = require("./Voting")
local Wallet = require("../../../core/domain/economy/Wallet")
export type Config = {
	round: ThemeRound.Config,
	themes: { string },
	catalog: { Outfit.ItemDef },
	startingOwned: { string },
	resultReward: number,
}
export type Save = { owned: { string }, equipped: { [Outfit.Slot]: string }, balance: number }
type Player = { outfit: Outfit.State, wallet: Wallet.Wallet }
local Adapter = {}
local Schema = require("./Schema")
Adapter.validateConfig = Schema.validateConfig
Adapter.validateSave = Schema.validateSave

function Adapter.create(data: Types.ConfigData, services: Types.Services): Types.Instance
	local errors = Adapter.validateConfig(data)
	assert(#errors == 0, table.concat(errors, "; "))
	local config = table.clone(data) :: Config
	config.round = table.clone(config.round)
	config.themes = table.clone(config.themes)
	config.startingOwned = table.clone(config.startingOwned)
	config.catalog = {}
	for _, item in data.catalog do
		table.insert(config.catalog, table.clone(item))
	end
	local players: { [string]: Player } = {}
	local roster: { string } = {}
	local enrolled: { [string]: boolean } = {}
	local voting = Voting.new()
	local ranking: { Voting.Result } = {}
	local settlement: Types.Result? = nil
	local roundId, settled = 0, 0
	local function emit(name: string, playerId: string?, eventData: Types.StateData)
		services.emit({ genre = "social-rp-fashion", name = name, playerId = playerId, data = eventData })
	end
	local round = ThemeRound.new(config.round, config.themes, function(count)
		return math.floor(services.roll() * count) + 1
	end, {
		OnThemeStart = function(theme)
			roundId += 1
			roster = {}
			enrolled = {}
			for playerId in players do
				table.insert(roster, playerId)
				enrolled[playerId] = true
			end
			table.sort(roster)
			voting = Voting.new()
			ranking = {}
			settlement = nil
			emit("OnThemeStart", nil, { theme = theme, roundId = roundId, roster = table.clone(roster) })
		end,
		OnResults = function(theme)
			if settled == roundId then
				return
			end
			local results = Voting.results(voting)
			local winner = results[1]
			local player = if winner then players[winner.target] else nil
			local rewardDue = player ~= nil and enrolled[winner.target] == true and config.resultReward > 0
			local outcome: Types.Result = { ok = true }
			if rewardDue and player and player.wallet:balance("Coins") > 1e9 - config.resultReward then
				outcome = { ok = false, reason = "reward exceeds balance limit" }
			end
			-- Finalize either outcome once. A failed settlement never partially pays
			-- the promised reward or mutates persistent player state.
			settled = roundId
			ranking = results
			settlement = outcome
			if outcome.ok and rewardDue and player then
				player.wallet:credit("Coins", config.resultReward)
			end
			local copy: { Voting.Result } = {}
			for _, entry in ranking do
				table.insert(copy, table.clone(entry))
			end
			emit(
				"OnResults",
				nil,
				{ theme = theme, roundId = roundId, ranking = copy, settlement = table.clone(outcome) }
			)
		end,
	})
	local function settleDeadlines(now: number)
		while round:state() == "dressing" or round:state() == "voting" do
			local duration = if round:state() == "dressing"
				then config.round.dressingSeconds
				else config.round.votingSeconds
			local deadline = (round.phaseStart :: number) + duration
			if now < deadline then
				break
			end
			round:tick(deadline, #roster)
		end
	end
	return {
		join = function(playerId, saved)
			if players[playerId] then
				return { ok = false, reason = "already joined" }
			end
			if saved and #Adapter.validateSave(saved) > 0 then
				return { ok = false, reason = "invalid save" }
			end
			local state: Save = if saved
				then saved :: Save
				else { owned = config.startingOwned, equipped = {}, balance = 0 }
			local catalog: { [string]: Outfit.ItemDef } = {}
			for _, item in config.catalog do
				catalog[item.id] = item
			end
			for _, itemId in state.owned do
				if not catalog[itemId] then
					return { ok = false, reason = "unknown owned item" }
				end
			end
			for slot, itemId in state.equipped do
				if not catalog[itemId] or catalog[itemId].slot ~= slot then
					return { ok = false, reason = "invalid equipped slot" }
				end
			end
			local outfit = Outfit.new(config.catalog, state.owned)
			for _, itemId in state.equipped do
				assert(Outfit.equip(outfit, itemId))
			end
			players[playerId] = { outfit = outfit, wallet = Wallet.new({ Coins = state.balance }) }
			return { ok = true }
		end,
		prepareLeave = function(_playerId)
			settleDeadlines(services.now())
		end,
		leave = function(playerId)
			settleDeadlines(services.now())
			players[playerId] = nil
			enrolled[playerId] = nil -- Reconnect cannot recover the old round's eligibility.
		end,
		dispatch = function(playerId, action, args)
			local player = players[playerId]
			if not player then
				return { ok = false, reason = "not joined" }
			end
			settleDeadlines(services.now())
			local phase = round:state()
			if action == "equip" then
				if phase ~= "lobby" and phase ~= "dressing" then
					return { ok = false, reason = "not dressing" }
				end
				if phase == "dressing" and not enrolled[playerId] then
					return { ok = false, reason = "not enrolled" }
				end
				if #args ~= 1 or type(args[1]) ~= "string" then
					return { ok = false, reason = "invalid item" }
				end
				local ok, reason = Outfit.equip(player.outfit, args[1])
				if ok then
					emit("OutfitEquipped", playerId, { itemId = args[1], equipped = Outfit.equipped(player.outfit) })
				end
				return { ok = ok, reason = reason }
			elseif action == "vote" then
				if phase ~= "voting" then
					return { ok = false, reason = "not voting" }
				end
				local target = args[1]
				if
					#args ~= 2
					or type(target) ~= "string"
					or not enrolled[playerId]
					or not enrolled[target]
					or not players[target]
				then
					return { ok = false, reason = "not enrolled" }
				end
				local ok, reason = Voting.cast(voting, playerId, target, args[2])
				if ok then
					emit("VoteCast", playerId, { targetId = target, stars = args[2] })
				end
				return { ok = ok, reason = reason }
			end
			return { ok = false, reason = "unknown action" }
		end,
		advance = function(now)
			local previous = round:state()
			settleDeadlines(now)
			local count = 0
			for _ in players do
				count += 1
			end
			if round:state() == previous then
				round:tick(now, count)
			end
			if round:state() == "lobby" then
				roster = {}
				enrolled = {}
				voting = Voting.new()
				ranking = {}
				settlement = nil
			end
		end,
		snapshot = function(playerId)
			local player = players[playerId]
			local copy: { Voting.Result } = {}
			for _, entry in ranking do
				table.insert(copy, table.clone(entry))
			end
			return {
				phase = round:state(),
				theme = round:currentTheme(),
				roundId = roundId,
				roster = table.clone(roster),
				ranking = copy,
				settlement = if settlement then table.clone(settlement) else nil,
				equipped = if player then Outfit.equipped(player.outfit) else {},
				balance = if player then player.wallet:balance("Coins") else 0,
				enrolled = enrolled[playerId] == true,
			}
		end,
		save = function(playerId)
			local player = players[playerId]
			assert(player, "not joined")
			local owned: { string } = {}
			for itemId, isOwned in player.outfit.owned do
				if isOwned then
					table.insert(owned, itemId)
				end
			end
			table.sort(owned)
			return { owned = owned, equipped = Outfit.equipped(player.outfit), balance = player.wallet:balance("Coins") }
		end,
	}
end
return Adapter
