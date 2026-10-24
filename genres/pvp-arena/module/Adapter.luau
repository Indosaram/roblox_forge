--!strict
local Types = require("../../../core/domain/genre/Contract")
local Matchmaking = require("./Matchmaking")
local Rank = require("./Rank")
local Round = require("./Round")
local Adapter = {}
export type Config = {
	Round: Round.Config,
	maxDelta: number,
	initialRating: number,
	k: number,
	startingHealth: number,
	attackDamage: number,
	attackCooldown: number,
}
type Player = { rating: number, health: number, lastAttack: number?, queued: boolean, match: number? }
type Match = { id: number, a: string, b: string, round: Round.Round, settled: boolean }
local function finite(value: any, min: number, max: number, integer: boolean): boolean
	return type(value) == "number"
		and value == value
		and value >= min
		and value <= max
		and (not integer or value % 1 == 0)
end
local function keys(data: Types.StateData, allowed: { [string]: boolean }, errors: { string })
	for key in data do
		if not allowed[key] then
			table.insert(errors, "unknown key: " .. tostring(key))
		end
	end
end
function Adapter.validateConfig(data: Types.ConfigData): { string }
	local errors: { string } = {}
	keys(data, {
		Round = true,
		maxDelta = true,
		initialRating = true,
		k = true,
		startingHealth = true,
		attackDamage = true,
		attackCooldown = true,
	}, errors)
	for _, key in { "maxDelta", "initialRating", "k", "startingHealth", "attackDamage", "attackCooldown" } do
		local min = if key == "maxDelta" or key == "initialRating" then 0 else 0.000001
		local max = if key == "attackCooldown" then 86400 else 1000000
		if not finite(data[key], min, max, key == "startingHealth" or key == "attackDamage") then
			table.insert(errors, "invalid " .. key)
		end
	end
	if type(data.Round) ~= "table" then
		table.insert(errors, "invalid Round")
	else
		keys(data.Round, { minPlayers = true, countdown = true, duration = true, intermission = true }, errors)
		if data.Round.minPlayers ~= 2 then
			table.insert(errors, "Round.minPlayers must be 2")
		end
		for _, key in { "countdown", "duration", "intermission" } do
			if not finite(data.Round[key], 0.000001, 86400, false) then
				table.insert(errors, "invalid Round." .. key)
			end
		end
	end
	table.sort(errors)
	return errors
end
function Adapter.validateSave(data: Types.StateData): { string }
	local errors: { string } = {}
	keys(data, { rating = true }, errors)
	if not finite(data.rating, 0, 1000000, false) then
		table.insert(errors, "invalid rating")
	end
	table.sort(errors)
	return errors
end
-- `onDecided` (recipe bridge) hears the winner of every match decided in the arena - a
-- knockout or a timed health decision - exactly once. Forfeits and draws are not reported.
function Adapter.create(
	data: Types.ConfigData,
	services: Types.Services,
	onDecided: ((winner: string) -> ())?
): Types.Instance
	assert(#Adapter.validateConfig(data) == 0, "invalid pvp config")
	local config = table.clone(data) :: Config
	config.Round = table.clone(config.Round)
	local players: { [string]: Player } = {}
	local matches: { [number]: Match } = {}
	local queue = Matchmaking.new()
	local sequence = 0
	local function emit(name: string, match: Match, extra: Types.StateData?)
		services.emit({
			genre = "pvp-arena",
			name = name,
			data = extra or { matchId = match.id, players = { match.a, match.b } },
		})
	end
	local function settle(match: Match, score: number, now: number, decided: boolean?)
		if match.settled then
			return
		end
		if decided and onDecided and score ~= 0.5 then
			onDecided(if score == 1 then match.a else match.b)
		end
		match.settled = true
		local a, b = players[match.a], players[match.b]
		local ra, rb = Rank.update(a.rating, b.rating, score, config.k)
		a.rating, b.rating = math.min(1000000, ra), math.min(1000000, rb)
		match.round.phase, match.round.endedAt = "ended", now
		emit("OnRoundEnd", match)
		emit("MatchSettled", match, { matchId = match.id, scoreA = score, ratingA = a.rating, ratingB = b.rating })
	end
	local function cleanup(match: Match)
		for _, id in { match.a, match.b } do
			local player = players[id]
			if player and player.match == match.id then
				player.match = nil
				player.lastAttack = nil
				player.health = config.startingHealth
			end
		end
		matches[match.id] = nil
	end
	local instance: Types.Instance
	instance = {
		join = function(id, saved)
			if players[id] then
				return { ok = false, reason = "already joined" }
			end
			if saved and #Adapter.validateSave(saved) > 0 then
				return { ok = false, reason = "invalid save" }
			end
			players[id] = {
				rating = if saved then saved.rating else config.initialRating,
				health = config.startingHealth,
				queued = false,
			}
			return { ok = true }
		end,
		prepareLeave = function(id)
			local player = players[id]
			if not player then
				return
			end
			Matchmaking.remove(queue, id)
			local match = if player.match then matches[player.match] else nil
			if match then
				if Round.state(match.round) == "active" then
					local now = services.now()
					if now >= (match.round.roundStart :: number) + config.Round.duration then
						local ah, bh = players[match.a].health, players[match.b].health
						settle(match, if ah == bh then 0.5 elseif ah > bh then 1 else 0, now, true)
					else
						settle(match, if id == match.a then 0 else 1, now)
					end
				elseif Round.state(match.round) == "countdown" then
					Round.tick(match.round, services.now(), 1)
					cleanup(match)
				end
			end
		end,
		leave = function(id)
			local prepare = instance.prepareLeave
			assert(prepare, "arena departure preparation missing")
			prepare(id)
			players[id] = nil
		end,
		dispatch = function(id, action, args)
			local player = players[id]
			if not player then
				return { ok = false, reason = "not joined" }
			end
			if next(args) ~= nil then
				return { ok = false, reason = "unexpected arguments" }
			end
			local now = services.now()
			if action == "enqueue" then
				if player.match or player.queued then
					return { ok = false, reason = "already queued or matched" }
				end
				Matchmaking.enqueue(queue, id, player.rating, now)
				player.queued = true
				for _, pair in Matchmaking.pair(queue, config.maxDelta) do
					local a, b = tostring(pair[1]), tostring(pair[2])
					sequence += 1
					local match: Match =
						{ id = sequence, a = a, b = b, round = Round.new(config.Round), settled = false }
					matches[sequence] = match
					for _, pid in { a, b } do
						players[pid].queued = false
						players[pid].match = sequence
					end
					Round.tick(match.round, now, 2)
				end
				return { ok = true }
			elseif action == "attack" then
				local match = if player.match then matches[player.match] else nil
				if not match or match.settled or Round.state(match.round) ~= "active" then
					return { ok = false, reason = "not active" }
				end
				if now >= (match.round.roundStart :: number) + config.Round.duration then
					instance.advance(now)
					return { ok = false, reason = "round expired" }
				end
				if player.lastAttack and now - player.lastAttack < config.attackCooldown then
					return { ok = false, reason = "cooldown" }
				end
				local rival = players[if id == match.a then match.b else match.a]
				player.lastAttack = now
				rival.health = math.max(0, rival.health - config.attackDamage)
				if rival.health == 0 then
					settle(match, if id == match.a then 1 else 0, now, true)
				end
				return { ok = true }
			end
			return { ok = false, reason = "unknown action" }
		end,
		advance = function(now)
			local ids: { number } = {}
			for id in matches do
				table.insert(ids, id)
			end
			table.sort(ids)
			for _, id in ids do
				local match = matches[id]
				local before = Round.state(match.round)
				local phase = Round.tick(match.round, now, 2)
				if phase == "active" and before == "countdown" then
					emit("OnRoundStart", match)
				elseif phase == "ended" and not match.settled then
					local ah, bh = players[match.a].health, players[match.b].health
					settle(match, if ah == bh then 0.5 elseif ah > bh then 1 else 0, now, true)
				elseif phase == "lobby" then
					cleanup(match)
				end
			end
		end,
		snapshot = function(id)
			local player = players[id]
			if not player then
				return {}
			end
			local match = if player.match then matches[player.match] else nil
			return {
				rating = player.rating,
				health = player.health,
				queued = player.queued,
				phase = if match then Round.state(match.round) else "lobby",
				rival = if match then (if id == match.a then match.b else match.a) else nil,
				matchId = player.match,
			}
		end,
		save = function(id)
			local player = players[id]
			return if player then { rating = player.rating } else {}
		end,
	}
	return instance
end
return Adapter
