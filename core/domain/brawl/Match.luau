--!strict
-- Explicit seconds; callers serialize each match update and submit all damage
-- for a simulation tick together so iteration order cannot choose a winner.
local Data = require("../genre/SerializedData")
local M = {}
function M.new(id: string, policy: any): any
	return { id = id, policy = policy, phase = "queue", actors = {}, order = {}, lastTick = 0 }
end
function M.join(state: any, actor: string, facts: any): (boolean, string?)
	if state.phase ~= "queue" then
		return false, "QUEUE_CLOSED"
	elseif state.actors[actor] then
		return false, "ALREADY_QUEUED"
	elseif facts.level < state.policy.minimumLevel then
		return false, "LEVEL_REQUIRED"
	elseif #state.order >= state.policy.maximumPlayers then
		return false, "QUEUE_FULL"
	end
	state.actors[actor] = {
		equipment = Data.clone(facts.equipment),
		health = facts.maxHealth,
		maxHealth = facts.maxHealth,
		alive = true,
	}
	table.insert(state.order, actor)
	return true, nil
end
function M.start(state: any, now: number): (boolean, string?)
	if state.phase ~= "queue" or #state.order < state.policy.minimumPlayers then
		return false, "NOT_READY"
	end
	state.phase, state.startsAt = "preparing", now + state.policy.preparationSeconds
	state.lastTick = state.startsAt
	return true, nil
end
function M.weather(state: any, now: number): any
	local elapsed = math.max(0, now - state.startsAt)
	local selected = state.policy.weather[1]
	for _, weather in state.policy.weather do
		if elapsed >= weather.at then
			selected = weather
		end
	end
	return selected
end
function M.action(state: any, actor: string, action: string, range: number, now: number): any
	local player = state.actors[actor]
	if
		state.phase == "finished"
		or not state.startsAt
		or now < state.startsAt
		or now >= state.startsAt + state.policy.durationSeconds
	then
		return { ok = false, reason = "NOT_ACTIVE" }
	elseif not player or not player.alive then
		return { ok = false, reason = "ELIMINATED" }
	end
	local weather = M.weather(state, now)
	if action == "mount" and weather.noMount then
		return { ok = false, reason = "WEATHER_MOUNT" }
	elseif action == "ranged" and weather.rangeCap and range > weather.rangeCap then
		return { ok = false, reason = "WEATHER_RANGE" }
	end
	return { ok = true, staminaMultiplier = if action == "sprint" then weather.sprintMultiplier or 1 else 1 }
end
function M.tick(state: any, now: number, positions: any, damage: any): (boolean, string?)
	if state.phase == "finished" then
		return true, nil
	elseif not state.startsAt or now < state.startsAt then
		return false, "NOT_ACTIVE"
	elseif now < state.lastTick or (state.ticked and now == state.lastTick) then
		return false, "STALE_TICK"
	end
	local deadline = state.startsAt + state.policy.durationSeconds
	local untilTime = math.min(now, deadline)
	local collapse = state.startsAt + state.policy.collapseAt
	local survivors = {}
	for _, actor in state.order do
		local player = state.actors[actor]
		if player.alive then
			local loss = damage[actor] or 0
			assert(type(loss) == "number" and loss >= 0 and loss < math.huge, "INVALID_DAMAGE")
			local position = positions[actor]
			if position then
				local distance = math.sqrt(position.x ^ 2 + position.z ^ 2)
				if distance > 0 then
					local crossedAt = deadline
						- math.min(1, distance / state.policy.initialRadius) * (deadline - collapse)
					local outsideSeconds = math.max(0, untilTime - math.max(state.lastTick, collapse, crossedAt))
					loss += player.maxHealth * state.policy.outsideDamageFraction * outsideSeconds
				end
			end
			player.health = math.max(0, player.health - loss)
			player.alive = player.health > 0
			if player.alive then
				table.insert(survivors, actor)
			end
		end
	end
	state.lastTick, state.phase, state.ticked = untilTime, "active", true
	if #survivors <= 1 or now >= deadline then
		state.phase, state.finishedAt = "finished", untilTime
		state.winner = if #survivors == 1 then survivors[1] else nil
	end
	return true, nil
end
function M.leave(state: any, actor: string): (boolean, string?)
	local player = state.actors[actor]
	if not player or state.phase == "finished" then
		return false, "NOT_PARTICIPATING"
	end
	if state.phase == "queue" then
		state.actors[actor] = nil
		table.remove(state.order, assert(table.find(state.order, actor)))
	else
		player.alive, player.health, player.deserted = false, 0, true
	end
	return true, nil
end
-- Must run inside the same actor transaction as its wallet update. Receipt and
-- quota live with that wallet, not in the ephemeral arena or a client request.
function M.reward(document: any, state: any, actor: string, utc: number): any
	if state.phase ~= "finished" or not state.actors[actor] then
		return { ok = false, reason = "NOT_FINISHED" }
	end
	local ledger = document.brawl or { receipts = {}, days = {} }
	if ledger.receipts[state.id] then
		return { ok = true, amount = 0 }
	end
	local day = tostring(math.floor(utc / state.policy.daySeconds))
	local count = ledger.days[day] or 0
	local amount = 0
	if count < state.policy.dailySettlements then
		amount = state.policy.participationReward + (if state.winner == actor then state.policy.winReward else 0)
	end
	if document.balance + amount > state.policy.maximumBalance then
		return { ok = false, reason = "WALLET_FULL" }
	end
	ledger.receipts[state.id] = true
	ledger.days[day] = count + 1
	document.balance += amount
	document.brawl = ledger
	return { ok = true, amount = amount }
end
return M
