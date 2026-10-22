--!strict
-- Party: an expedition crew (plan C01/R04), distinct from a clan. A party owns no
-- property, storage or permissions; it only groups players who depart together.
-- Engine-free: the caller passes `now` (seconds) and the per-member gate facts.
local M = {}

M.CAPACITY = 8
M.INVITE_SECONDS = 120
-- No new entry inside a route's final ten minutes (catalog ui.depart-confirm).
M.FINAL_ENTRY_SECONDS = 600
M.ROUTES = 5
M.STAGES = 4

export type Invite = { party: string, from: string, route: number?, at: number, expiresAt: number }
export type PartyRecord = { id: string, leader: string, members: { string }, route: number? }
export type State = {
	parties: { [string]: PartyRecord },
	memberOf: { [string]: string },
	invites: { [string]: { [string]: Invite } },
	nextId: number,
}

function M.new(): State
	return { parties = {}, memberOf = {}, invites = {}, nextId = 0 }
end

function M.partyOf(state: State, actor: string): PartyRecord?
	local id = state.memberOf[actor]
	return if id then state.parties[id] else nil
end

function M.prune(state: State, now: number)
	for target, byFrom in state.invites do
		for from, invite in byFrom do
			if now >= invite.expiresAt or state.parties[invite.party] == nil then
				byFrom[from] = nil
			end
		end
		if next(byFrom) == nil then
			state.invites[target] = nil
		end
	end
end

local function pendingFor(state: State, partyId: string): number
	local count = 0
	for _, byFrom in state.invites do
		for _, invite in byFrom do
			if invite.party == partyId then
				count += 1
			end
		end
	end
	return count
end

function M.invite(state: State, from: string, target: string, now: number): (boolean, string?)
	M.prune(state, now)
	if from == target then
		return false, "party_self"
	end
	local party = M.partyOf(state, from)
	if party and party.leader ~= from then
		return false, "party_not_leader"
	end
	if state.memberOf[target] then
		return false, "party_member_busy"
	end
	if party and #party.members + pendingFor(state, party.id) >= M.CAPACITY then
		return false, "party_full"
	end
	if not party then
		state.nextId += 1
		local created: PartyRecord = { id = "party-" .. state.nextId, leader = from, members = { from }, route = nil }
		state.parties[created.id] = created
		state.memberOf[from] = created.id
		party = created
	end
	local record = party :: PartyRecord
	local byFrom = state.invites[target] or {}
	byFrom[from] =
		{ party = record.id, from = from, route = record.route, at = now, expiresAt = now + M.INVITE_SECONDS }
	state.invites[target] = byFrom
	return true, nil
end

local function takeInvite(state: State, actor: string, from: string): Invite?
	local byFrom = state.invites[actor]
	local invite = if byFrom then byFrom[from] else nil
	if byFrom and invite then
		byFrom[from] = nil
		if next(byFrom) == nil then
			state.invites[actor] = nil
		end
	end
	return invite
end

function M.accept(state: State, actor: string, from: string, now: number): (boolean, string?)
	local invite = takeInvite(state, actor, from)
	if not invite then
		return false, "invite_missing"
	end
	if now >= invite.expiresAt then
		return false, "invite_expired"
	end
	local party = state.parties[invite.party]
	if not party then
		return false, "invite_missing"
	end
	if state.memberOf[actor] then
		return false, "party_member_busy"
	end
	if #party.members >= M.CAPACITY then
		return false, "party_full"
	end
	table.insert(party.members, actor)
	state.memberOf[actor] = party.id
	return true, nil
end

function M.decline(state: State, actor: string, from: string): (boolean, string?)
	if takeInvite(state, actor, from) == nil then
		return false, "invite_missing"
	end
	return true, nil
end

local function drop(state: State, party: PartyRecord, actor: string)
	local index = table.find(party.members, actor)
	if index then
		table.remove(party.members, index)
	end
	state.memberOf[actor] = nil
	if #party.members == 0 then
		state.parties[party.id] = nil
		M.prune(state, -math.huge)
	elseif party.leader == actor then
		party.leader = party.members[1]
	end
end

function M.leave(state: State, actor: string): (boolean, string?)
	local party = M.partyOf(state, actor)
	if not party then
		return false, "party_none"
	end
	drop(state, party, actor)
	return true, nil
end

function M.remove(state: State, leader: string, target: string): (boolean, string?)
	local party = M.partyOf(state, leader)
	if not party then
		return false, "party_none"
	end
	if party.leader ~= leader then
		return false, "party_not_leader"
	end
	if target == leader then
		return false, "party_self"
	end
	if not table.find(party.members, target) then
		return false, "party_not_member"
	end
	drop(state, party, target)
	return true, nil
end

function M.share(state: State, leader: string, route: number): (boolean, string?)
	if route % 1 ~= 0 or route < 1 or route > M.ROUTES then
		return false, "invalid_route"
	end
	local party = M.partyOf(state, leader)
	if not party then
		return false, "party_none"
	end
	if party.leader ~= leader then
		return false, "party_not_leader"
	end
	party.route = route
	for _, byFrom in state.invites do
		for _, invite in byFrom do
			if invite.party == party.id then
				invite.route = route
			end
		end
	end
	return true, nil
end

-- Route gates come from the authored first-stage definitions of rw.a<index>.s1.
-- Re-forms a crew on the arrival server from the durable departure record; the id is the
-- party-shared travel token, so members landing one by one rejoin the same party.
function M.restore(state: State, token: string, leader: string, actor: string): (boolean, string?)
	if state.memberOf[actor] then
		return false, "party_member_busy"
	end
	local party = state.parties[token]
	if party and #party.members >= M.CAPACITY then
		return false, "party_full"
	end
	if not party then
		local created: PartyRecord = { id = token, leader = actor, members = {}, route = nil }
		state.parties[token] = created
		party = created
	end
	local record = party :: PartyRecord
	table.insert(record.members, actor)
	state.memberOf[actor] = token
	if actor == leader then
		record.leader = actor
	end
	return true, nil
end

function M.gates(content: any, route: number): (number, number)
	local layout = "rw.a" .. route .. ".s1"
	local level, rank = 1, 0
	for _, stage in content.stages do
		if stage.layout == layout then
			level = math.max(level, stage.gates.characterLevel or 1)
			rank = math.max(rank, stage.gates.developmentRank or 0)
		end
	end
	return level, rank
end

function M.routeGate(content: any, route: number, facts: any): (boolean, string?)
	if type(route) ~= "number" or route % 1 ~= 0 or route < 1 or route > M.ROUTES then
		return false, "invalid_route"
	end
	local level, rank = M.gates(content, route)
	if (facts.level or 1) < level then
		return false, "level_gate"
	end
	if (facts.developmentRank or 0) < rank then
		return false, "development_gate"
	end
	if (facts.instabilityAccess or 1) < route then
		return false, "instability_gate"
	end
	return true, nil
end

-- Expiry of a route opened at `now` (the same rotation window Expedition.open uses).
function M.window(now: number, ttl: number): number
	return (now // ttl + 1) * ttl
end

function M.entry(expiresAt: number, now: number): (boolean, string?)
	if now >= expiresAt then
		return false, "route_expired"
	end
	if expiresAt - now <= M.FINAL_ENTRY_SECONDS then
		return false, "expiry_imminent"
	end
	return true, nil
end

function M.routes(content: any, facts: any, now: number, ttl: number): { any }
	local cards = {}
	for route = 1, M.ROUTES do
		local level, rank = M.gates(content, route)
		local biome = nil
		local missions = 0
		for _, layout in content.layouts do
			if layout.id == "rw.a" .. route .. ".s1" then
				biome = layout.biomes[1]
			end
		end
		for _, stage in content.stages do
			if string.sub(stage.layout, 1, #("rw.a" .. route .. ".")) == "rw.a" .. route .. "." then
				missions += 1
			end
		end
		local expiresAt = M.window(now, ttl)
		local ok, reason = M.routeGate(content, route, facts)
		if ok then
			ok, reason = M.entry(expiresAt, now)
		end
		table.insert(cards, {
			route = route,
			biome = biome,
			level = level,
			rank = rank,
			stages = M.STAGES,
			missions = missions,
			capacity = M.CAPACITY,
			expiresAt = expiresAt,
			ok = ok,
			reason = reason,
		})
	end
	return cards
end

-- Per-member readiness for a route; `factsOf` reads each member's authoritative facts.
function M.readiness(content: any, party: PartyRecord, route: number?, factsOf: (string) -> any): ({ any }, boolean)
	local rows, all = {}, true
	for _, member in party.members do
		local ok, reason = true, nil
		if route then
			ok, reason = M.routeGate(content, route, factsOf(member))
		end
		all = all and ok
		table.insert(rows, { id = member, leader = member == party.leader, ready = ok, reason = reason })
	end
	return rows, all
end

function M.view(state: State, actor: string, now: number): any
	local party = M.partyOf(state, actor)
	local invites = {}
	local received: { [string]: Invite } = state.invites[actor] or {}
	for from, invite in received do
		if now < invite.expiresAt then
			local host = state.parties[invite.party]
			table.insert(invites, {
				from = from,
				route = invite.route,
				expiresAt = invite.expiresAt,
				members = if host then #host.members else 0,
				capacity = M.CAPACITY,
			})
		end
	end
	table.sort(invites, function(a, b)
		return a.from < b.from
	end)
	return {
		id = if party then party.id else nil,
		leader = if party then party.leader else nil,
		members = if party then table.clone(party.members) else {},
		route = if party then party.route else nil,
		pending = if party then pendingFor(state, party.id) else 0,
		capacity = M.CAPACITY,
		invites = invites,
	}
end

return M
