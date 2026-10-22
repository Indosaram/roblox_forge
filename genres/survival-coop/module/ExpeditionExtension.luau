--!strict
-- Expedition crew and departure command (catalog ui.routes / ui.party / ui.route-invite /
-- ui.depart-confirm / ui.expedition-results). Party rules live in core/domain/island/Party;
-- this extension only reads authoritative facts and hands a validated departure to the
-- server's travel port. A party is server-local and owns no property or permissions.
local Party = require("../../../core/domain/island/Party")
local Journal = require("../../../core/domain/command/Journal")
local Archipelago = require("../../../core/domain/island/Archipelago")
local Volcano = require("../../../core/domain/survival/Volcano")
local M = {}

M.ACTION = "survival-coop:party-action"
M.TTL = 1800
local VERBS = {
	invite = true,
	accept = true,
	decline = true,
	leave = true,
	remove = true,
	share = true,
	depart = true,
	next = true,
	home = true,
	claim = true,
}

-- Declared through Contract's trailing action loop, so existing durable indices never shift.
function M.actions(): { any }
	local Schema = require("../../../core/infra/net/Schema")
	local id = Schema.string({ maxLen = 128, pattern = ".+" })
	return {
		{ id = "party-action", args = { id, id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
	}
end

-- Mission rewards of the actor's latest expedition, keyed exactly as MissionRewards.enqueue keys them.
function M.results(content: any, document: any?): any?
	local state = if document then document.archipelago else nil
	if not state then
		return nil
	end
	local rows = {}
	for _, mission in content.missions do
		local id = "mission:" .. Journal.fnv1a64(state.id .. ":" .. state.revision .. ":" .. mission.id)
		local entry = if document and document.missionRewards then document.missionRewards[id] else nil
		if entry then
			local trust = 0
			for _, row in entry.rewards.reputation or {} do
				trust += row.value
			end
			table.insert(rows, {
				mission = mission.id,
				xp = entry.rewards.xp or 0,
				coins = entry.rewards.coins or 0,
				trust = trust,
				repeatClear = entry.repeatClear == true,
				delivered = entry.settled == true,
			})
		end
	end
	local ledger = document and document.resultsLedger and document.resultsLedger[state.id]
	return {
		id = state.id,
		index = state.index,
		stage = state.stage,
		status = state.status,
		rows = rows,
		ledger = ledger,
	}
end

-- Carried summary (ui.travel reconciliation): total bag quantity and coins.
function M.carried(data: any?): any?
	if not data then
		return nil
	end
	local items = 0
	for _, item in (data.inventory and data.inventory.bag.items) or {} do
		items += item.quantity or 1
	end
	return { items = items, coins = data.balance or 0 }
end

-- Objective points per party member present on this server who shares the travel token.
function M.contributors(token: string?, members: { string }, documentOf: (string) -> any?): { any }
	local rows = {}
	for _, member in members do
		local document = documentOf(member)
		local own = document and document.archipelago
		if own and token and own.party and own.party.token == token then
			local points = 0
			for _, count in own.progress do
				points += count
			end
			table.insert(rows, { id = member, points = points })
		end
	end
	table.sort(rows, function(a, b)
		return if a.points == b.points then a.id < b.id else a.points > b.points
	end)
	return rows
end

-- Worn protection: only items equipped right now count, never items merely owned.
function M.worn(content: any, items: { string }): any
	local policy = content.progressionPolicy
	local boots, cold, heat = false, 0, 0
	for _, id in items do
		boots = boots or (policy.volcano ~= nil and id == policy.volcano.bootsItem)
		local climate = policy.clothing and policy.clothing[id]
		if climate then
			cold += climate.cold
			heat += climate.heat
		end
	end
	return { boots = boots, cold = cold, heat = heat }
end

local CLIMATE = { heat = "heat", steam = "heat", lava = "heat", cold = "cold", whiteout = "cold", ice = "cold" }

-- Current-stage objectives of an active expedition (catalog ui.expedition).
function M.tracker(content: any, document: any?): any?
	local state = if document then document.archipelago else nil
	if not state or state.status ~= "active" then
		return nil
	end
	local objectives, done = {}, true
	for _, stage in content.stages do
		if stage.layout == Archipelago.layout(state) then
			for _, objective in stage.objectives do
				local complete = state.completed[objective.id] == true
				done = done and complete
				table.insert(objectives, {
					id = objective.id,
					action = objective.action,
					target = objective.target,
					progress = if complete then objective.quantity else state.progress[objective.id] or 0,
					quantity = objective.quantity,
				})
			end
		end
	end
	return {
		route = state.index,
		stage = state.stage,
		expiresAt = state.expiresAt,
		objectives = objectives,
		unlocked = done,
	}
end

-- Hazard under the actor (catalog ui.hazard): authored hazard radius plus the volcano policy.
function M.hazard(content: any, layoutId: string?, position: any?, worn: any?): any?
	if not layoutId or not position then
		return nil
	end
	local layout = nil
	for _, candidate in content.layouts do
		if candidate.id == layoutId then
			layout = candidate
		end
	end
	if not layout then
		return nil
	end
	local found = nil
	for _, hazard in layout.hazards do
		local dx, dz = position.x - hazard.position.x, position.z - hazard.position.z
		if dx * dx + dz * dz <= hazard.radius * hazard.radius then
			found = { kind = hazard.kind, intensity = hazard.intensity }
		end
	end
	local policy = content.progressionPolicy and content.progressionPolicy.volcano
	local zone = Volcano.zone(layout, position)
	local volcanic = table.find(layout.biomes, "volcano") ~= nil and policy ~= nil
	if volcanic and zone.exposed and not found then
		found = { kind = "heat", intensity = 1 }
	end
	if not found then
		return nil
	end
	found.refuge = not zone.exposed or zone.spring
	found.layout = layoutId
	local protection = worn or { boots = false, cold = 0, heat = 0 }
	if volcanic then
		local factor = if protection.boots then policy.bootsMultiplier else 1
		found.volcano = { health = policy.healthPerSecond * factor, fatigue = policy.fatiguePerSecond * factor }
		found.boots = protection.boots
	end
	local climate = CLIMATE[found.kind]
	if climate then
		found.resist = protection[climate]
		found.exposure = math.max(0, found.intensity - found.resist)
	end
	return found
end

function M.new(env: any): any
	local state = Party.new()
	local ttl = env.ttl or M.TTL
	local function depart(actor: string, route: number): any
		local party = Party.partyOf(state, actor)
		if party and party.leader ~= actor then
			return { ok = false, reason = "party_not_leader" }
		end
		local members: { string } = {}
		local crew: { string } = if party then party.members else {}
		for _, member in crew do
			if member ~= actor then
				table.insert(members, member)
			end
		end
		table.sort(members)
		-- The actor travels last: a departing server may stop answering after its own handoff.
		table.insert(members, actor)
		for _, member in members do
			local ok, reason = Party.routeGate(env.content, route, env.facts(member))
			if not ok then
				return { ok = false, reason = if member == actor then reason else "party_not_ready" }
			end
		end
		if env.onExpedition() then
			return { ok = false, reason = "expedition_active" }
		end
		local now = env.now()
		local open, reason = Party.entry(Party.window(now, ttl), now)
		if not open then
			return { ok = false, reason = reason }
		end
		local result: any = { ok = true }
		-- One party-shared token routes every member to the same reserved expedition server.
		local crewInfo = if party
			then {
				token = if env.token then env.token() else party.id .. ":" .. now,
				leader = actor,
				members = table.clone(members),
			}
			else nil
		for _, member in members do
			local departure = M.carried(if env.personal then env.personal(member) else nil)
			local moved = env.travel(member, "archipelago", route, { party = crewInfo, departure = departure })
			if member == actor then
				result = moved
			end
		end
		return { ok = result.ok, reason = result.reason, data = { route = route, members = #members } }
	end
	return {
		id = "expedition",
		handles = function(action: string): boolean
			return action == M.ACTION
		end,
		command = function(actor, _action, args, _context, _origin, admit): any
			local verb, arg = args[1], args[2]
			if type(verb) ~= "string" or not VERBS[verb] then
				return { ok = false, reason = "INVALID_VERB" }
			end
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local now = env.now()
			local ok, reason
			if verb == "invite" then
				if not env.online(arg) then
					return { ok = false, reason = "player_offline" }
				end
				ok, reason = Party.invite(state, actor, arg, now)
			elseif verb == "accept" then
				ok, reason = Party.accept(state, actor, arg, now)
			elseif verb == "decline" then
				ok, reason = Party.decline(state, actor, arg)
			elseif verb == "leave" then
				ok, reason = Party.leave(state, actor)
			elseif verb == "remove" then
				ok, reason = Party.remove(state, actor, arg)
			elseif verb == "share" then
				ok, reason = Party.share(state, actor, tonumber(arg) or 0)
			elseif verb == "claim" then
				return env.claim(actor, arg)
			elseif verb == "next" or verb == "home" then
				if not env.onExpedition() then
					return { ok = false, reason = "missing_expedition" }
				end
				return env.travel(actor, if verb == "next" then "next-island" else "home", nil)
			else
				return depart(actor, tonumber(arg) or 0)
			end
			return { ok = ok, reason = reason }
		end,
		snapshot = function(actor: string): any
			local now = env.now()
			Party.prune(state, now)
			local document = env.document(actor)
			local trip = document and document.archipelago
			-- Arrival: re-form the crew from the durable travel token on this server.
			if
				trip
				and trip.status == "active"
				and trip.party
				and env.onExpedition()
				and not Party.partyOf(state, actor)
			then
				Party.restore(state, trip.party.token, trip.party.leader, actor)
			end
			local view = Party.view(state, actor, now)
			local party = Party.partyOf(state, actor)
			if party then
				view.roster = Party.readiness(env.content, party, party.route, env.facts)
			end
			local results = M.results(env.content, document)
			if results and trip then
				results.contributors = M.contributors(
					trip.party and trip.party.token,
					if trip.party then trip.party.members else { actor },
					env.document
				)
			end
			local data = env.personal and env.personal(actor)
			return {
				arrival = if trip and trip.status == "active"
					then {
						id = trip.id,
						route = trip.index,
						stage = trip.stage,
						party = trip.party,
						left = trip.departure,
						arrived = M.carried(data),
					}
					else nil,
				cargo = if trip and trip.status == "active" then trip.questCargo else nil,
				now = now,
				tracker = M.tracker(env.content, document),
				hazard = M.hazard(
					env.content,
					env.layoutId(),
					env.position(actor),
					M.worn(env.content, if env.worn then env.worn(actor) else {})
				),
				party = view,
				routes = Party.routes(env.content, env.facts(actor), now, ttl),
				results = results,
			}
		end,
		releaseActor = function(actor: string): any
			Party.leave(state, actor)
			return { ok = true }
		end,
	}
end

return M
