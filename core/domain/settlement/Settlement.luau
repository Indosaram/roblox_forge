--!strict
-- Pure candidates only: publish alongside inventory and receipts in one durable commit.
local Settlement = {}

export type Cell = { x: number, z: number }
export type Cost = { item: string, quantity: number }
export type Definition = { id: string, footprintX: number, footprintZ: number, cost: { Cost } }
export type Config = { tribeId: string, width: number, depth: number, cellStuds: number, maxMembers: number }
export type Placement = {
	id: string,
	actorId: string,
	membershipRevision: number,
	definition: Definition,
	x: number,
	z: number,
	rotation: number,
	cells: { Cell },
	entry: Cell,
}
export type State = {
	version: number,
	membershipRevision: number,
	config: Config,
	ownerId: string,
	roles: { [string]: string },
	reservations: { [string]: Placement },
	structures: { [string]: Placement },
	usedIds: { [string]: boolean },
	-- Membership clock (seconds, caller supplied). Absent in legacy saves.
	joinedAt: { [string]: number },
	departedAt: { [string]: number },
}
export type Request = { id: string, definition: Definition, x: number, z: number, rotation: number }

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

local function integer(value: number, minimum: number, maximum: number): boolean
	return value == value and value >= minimum and value <= maximum and value % 1 == 0
end

--- Plan 7.1-4: a departed account (leave or revoke) cannot be re-invited before
--- this many seconds pass, so camps cannot rotate alt accounts through a slot.
Settlement.REJOIN_COOLDOWN_SECONDS = 86400
--- Plan 7.1-4: siege league registration floor for every current member.
Settlement.LEAGUE_POLICY = { minAccountAgeDays = 7, minMembershipSeconds = 7 * 86400 }
export type LeaguePolicy = { minAccountAgeDays: number, minMembershipSeconds: number }
export type LeagueFailure = { actorId: string, reason: string }

local MAX_CLOCK = 2 ^ 53 - 1

function Settlement.new(config: Config, ownerId: string, now: number?): State
	assert(config.tribeId ~= "" and ownerId ~= "", "identity required")
	assert(integer(config.width, 1, 32) and integer(config.depth, 1, 32), "grid exceeds bounds")
	assert(integer(config.cellStuds, 1, 128) and integer(config.maxMembers, 1, 4), "invalid policy")
	local created = now or 0
	assert(integer(created, 0, MAX_CLOCK), "invalid clock")
	return {
		version = 0,
		membershipRevision = 0,
		config = copy(config),
		ownerId = ownerId,
		roles = { [ownerId] = "owner" },
		reservations = {},
		structures = {},
		usedIds = {},
		joinedAt = { [ownerId] = created },
		departedAt = {},
	}
end

function Settlement.snapshot(state: State): State
	return copy(state)
end

local function access(state: State, actorId: string, version: number, revision: number?): string?
	if state.roles[actorId] == nil then
		return "FORBIDDEN"
	elseif version ~= state.version then
		return "STALE_VERSION"
	elseif revision ~= nil and revision ~= state.membershipRevision then
		return "STALE_MEMBERSHIP"
	end
	return nil
end

-- Invite is the authoritative accepted invitation, not a client-controlled role assignment.
-- now is the server clock in seconds; departures and joins are stamped with it.
function Settlement.membership(
	state: State,
	actorId: string,
	version: number,
	revision: number,
	action: string,
	targetId: string,
	now: number
): (State?, string?)
	if not integer(now, 0, MAX_CLOCK) then
		return nil, "INVALID_CLOCK"
	end
	local err = access(state, actorId, version, revision)
	if action == "rejoin" and actorId == state.ownerId and next(state.roles) == nil then
		err = if version ~= state.version
			then "STALE_VERSION"
			elseif revision ~= state.membershipRevision then "STALE_MEMBERSHIP"
			else nil
	end
	if err then
		return nil, err
	end
	local count = 0
	for _ in state.roles do
		count += 1
	end
	if targetId == "" then
		return nil, "INVALID_TARGET"
	elseif action == "invite" then
		if actorId ~= state.ownerId then
			return nil, "FORBIDDEN"
		elseif state.roles[targetId] ~= nil then
			return nil, "ALREADY_MEMBER"
		elseif count >= state.config.maxMembers then
			return nil, "TRIBE_FULL"
		elseif
			state.departedAt[targetId] ~= nil
			and now < state.departedAt[targetId] + Settlement.REJOIN_COOLDOWN_SECONDS
		then
			return nil, "REJOIN_COOLDOWN"
		end
	elseif action == "revoke" or action == "leave" then
		if (action == "revoke" and actorId ~= state.ownerId) or (action == "leave" and targetId ~= actorId) then
			return nil, "FORBIDDEN"
		elseif state.roles[targetId] == nil then
			return nil, "NOT_MEMBER"
		elseif targetId == state.ownerId and (count > 1 or action == "revoke") then
			return nil, "OWNER_TRANSFER_REQUIRED"
		end
	elseif action == "transferOwner" then
		if actorId ~= state.ownerId then
			return nil, "FORBIDDEN"
		elseif state.roles[targetId] ~= "member" then
			return nil, "NOT_MEMBER"
		end
	elseif action == "rejoin" then
		if actorId ~= state.ownerId or targetId ~= actorId or count ~= 0 then
			return nil, "FORBIDDEN"
		end
	else
		return nil, "INVALID_ACTION"
	end
	local result = copy(state) :: State
	if action == "invite" or action == "rejoin" then
		-- The sole owner reclaiming an empty settlement rotates no one, so it is exempt.
		result.roles[targetId] = if action == "invite" then "member" else "owner"
		result.joinedAt[targetId] = now
		result.departedAt[targetId] = nil
	elseif action == "transferOwner" then
		result.roles[actorId] = "member"
		result.roles[targetId] = "owner"
		result.ownerId = targetId
	else
		result.roles[targetId] = nil
		result.joinedAt[targetId] = nil
		-- Expired departures carry no cooldown; drop them so the map stays bounded.
		for departed, at in result.departedAt do
			if now >= at + Settlement.REJOIN_COOLDOWN_SECONDS then
				result.departedAt[departed] = nil
			end
		end
		result.departedAt[targetId] = now
	end
	result.version += 1
	result.membershipRevision += 1
	return result, nil
end

-- Siege league registration floor. accountAgeDays is trusted server data
-- (Player.AccountAge) keyed by member id; a member missing from it fails.
function Settlement.leagueEligibility(
	state: State,
	now: number,
	accountAgeDays: { [string]: number },
	policy: LeaguePolicy?
): (boolean, { LeagueFailure })
	assert(integer(now, 0, MAX_CLOCK), "invalid clock")
	local floor = policy or Settlement.LEAGUE_POLICY
	local failures: { LeagueFailure } = {}
	local members: { string } = {}
	for actor in state.roles do
		table.insert(members, actor)
	end
	table.sort(members)
	if #members == 0 then
		return false, { { actorId = "", reason = "NO_MEMBERS" } }
	end
	for _, actor in members do
		local age = accountAgeDays[actor]
		local joined = state.joinedAt[actor]
		local reason: string? = nil
		if type(age) ~= "number" or not integer(age, 0, MAX_CLOCK) then
			reason = "ACCOUNT_AGE_UNKNOWN"
		elseif age < floor.minAccountAgeDays then
			reason = "ACCOUNT_TOO_NEW"
		elseif joined == nil then
			reason = "MEMBERSHIP_UNKNOWN"
		elseif now - joined < floor.minMembershipSeconds then
			reason = "MEMBERSHIP_TOO_SHORT"
		end
		if reason then
			table.insert(failures, { actorId = actor, reason = reason })
		end
	end
	return #failures == 0, failures
end

local function rotate(x: number, z: number, rotation: number): Cell
	if rotation == 1 then
		return { x = -z, z = x }
	elseif rotation == 2 then
		return { x = -x, z = -z }
	elseif rotation == 3 then
		return { x = z, z = -x }
	end
	return { x = x, z = z }
end

local function same(a: Cell, b: Cell): boolean
	return a.x == b.x and a.z == b.z
end

local function blocked(placement: Placement, other: Placement): boolean
	for _, cell in placement.cells do
		if same(cell, other.entry) then
			return true
		end
		for _, occupied in other.cells do
			if same(cell, occupied) then
				return true
			end
		end
	end
	for _, occupied in other.cells do
		if same(placement.entry, occupied) then
			return true
		end
	end
	return false
end

function Settlement.reserve(
	state: State,
	actorId: string,
	version: number,
	revision: number,
	request: Request
): (State?, string?)
	local err = access(state, actorId, version, revision)
	if err then
		return nil, err
	end
	local definition = request.definition
	if request.id == "" or state.usedIds[request.id] then
		return nil, "RESERVATION_ID_USED"
	elseif not integer(request.rotation, 0, 3) then
		return nil, "INVALID_ROTATION"
	elseif not integer(request.x, 0, state.config.width - 1) or not integer(request.z, 0, state.config.depth - 1) then
		return nil, "OUT_OF_BOUNDS"
	elseif
		definition.id == ""
		or not integer(definition.footprintX, 1, 32)
		or not integer(definition.footprintZ, 1, 32)
	then
		return nil, "INVALID_DEFINITION"
	end
	local items: { [string]: boolean } = {}
	for _, cost in definition.cost do
		if cost.item == "" or items[cost.item] or not integer(cost.quantity, 1, 1000000000) then
			return nil, "INVALID_COST"
		end
		items[cost.item] = true
	end
	local cells: { Cell } = {}
	for x = 0, definition.footprintX - 1 do
		for z = 0, definition.footprintZ - 1 do
			local cell = rotate(x, z, request.rotation)
			cell.x += request.x
			cell.z += request.z
			table.insert(cells, cell)
		end
	end
	-- Entry is one cell before the local origin, rotated with the structure.
	local entry = rotate(0, -1, request.rotation)
	entry.x += request.x
	entry.z += request.z
	local bounds = table.clone(cells)
	table.insert(bounds, entry)
	for _, cell in bounds do
		if cell.x < 0 or cell.z < 0 or cell.x >= state.config.width or cell.z >= state.config.depth then
			return nil, "OUT_OF_BOUNDS"
		end
	end
	local placement: Placement = {
		id = state.config.tribeId .. ":" .. request.id,
		actorId = actorId,
		membershipRevision = revision,
		definition = copy(definition),
		x = request.x,
		z = request.z,
		rotation = request.rotation,
		cells = cells,
		entry = entry,
	}
	for _, group in { state.reservations, state.structures } do
		for _, other in group do
			if blocked(placement, other) then
				return nil, "COLLISION"
			end
		end
	end
	local result = copy(state) :: State
	result.reservations[request.id] = placement
	result.usedIds[request.id] = true
	result.version += 1
	return result, nil
end

function Settlement.commit(state: State, actorId: string, version: number, reservationId: string): (State?, string?)
	local placement = state.reservations[reservationId]
	local err = access(state, actorId, version, if placement then placement.membershipRevision else nil)
	if err then
		return nil, err
	elseif placement == nil then
		return nil, "NOT_RESERVED"
	elseif placement.actorId ~= actorId then
		return nil, "FORBIDDEN"
	end
	local result = copy(state) :: State
	result.structures[placement.id] = result.reservations[reservationId]
	result.reservations[reservationId] = nil
	result.version += 1
	return result, nil
end

function Settlement.cancel(state: State, actorId: string, version: number, reservationId: string): (State?, string?)
	local err = access(state, actorId, version, nil)
	local placement = state.reservations[reservationId]
	if err then
		return nil, err
	elseif placement == nil then
		return nil, "NOT_RESERVED"
	elseif placement.actorId ~= actorId and actorId ~= state.ownerId then
		return nil, "FORBIDDEN"
	end
	local result = copy(state) :: State
	result.reservations[reservationId] = nil
	result.version += 1
	return result, nil
end

-- Caller must atomically fit/credit these items with this candidate; never publish first.
function Settlement.demolish(
	state: State,
	actorId: string,
	version: number,
	revision: number,
	structureId: string
): (State?, string?, { Cost }?)
	local err = access(state, actorId, version, revision)
	if err then
		return nil, err, nil
	end
	local placement = state.structures[structureId]
	if placement == nil then
		return nil, "NOT_BUILT", nil
	end
	local refund: { Cost } = {}
	for _, cost in placement.definition.cost do
		local quantity = math.floor(cost.quantity / 2)
		if quantity > 0 then
			table.insert(refund, { item = cost.item, quantity = quantity })
		end
	end
	local result = copy(state) :: State
	result.structures[structureId] = nil
	result.version += 1
	return result, nil, refund
end

-- Restore only against trusted, version-pinned definitions. Changing a pinned
-- definition requires an explicit migration/catalog version, never trusting save costs.
function Settlement.fromSave(raw: any, config: Config, definitions: { [string]: Definition }): State
	assert(type(raw) == "table" and raw.saveVersion == 1, "UNSUPPORTED_SETTLEMENT_SAVE")
	local function equal(a: any, b: any): boolean
		if type(a) ~= type(b) then
			return false
		end
		if type(a) ~= "table" then
			return a == b
		end
		for key, value in a do
			if not equal(value, b[key]) then
				return false
			end
		end
		for key in b do
			if a[key] == nil then
				return false
			end
		end
		return true
	end
	assert(equal(raw.config, config), "SETTLEMENT_CONFIG_MISMATCH")
	assert(type(raw.ownerId) == "string" and raw.ownerId ~= "", "INVALID_OWNER")
	local result = Settlement.new(config, raw.ownerId)
	assert(type(raw.version) == "number" and integer(raw.version, 0, 2 ^ 53 - 2), "INVALID_VERSION")
	assert(
		type(raw.membershipRevision) == "number" and integer(raw.membershipRevision, 0, raw.version),
		"INVALID_MEMBERSHIP_REVISION"
	)
	assert(
		type(raw.roles) == "table"
			and type(raw.reservations) == "table"
			and type(raw.structures) == "table"
			and type(raw.usedIds) == "table",
		"INVALID_SETTLEMENT_SAVE"
	)
	local members = 0
	for actor, role in raw.roles do
		members += 1
		assert(type(actor) == "string" and actor ~= "" and (role == "owner" or role == "member"), "INVALID_ROLE")
		assert((actor == raw.ownerId) == (role == "owner"), "INVALID_OWNER_ROLE")
	end
	assert(members <= config.maxMembers and (members == 0 or raw.roles[raw.ownerId] == "owner"), "INVALID_MEMBERSHIP")
	local occupied = {}
	for _, group in { "reservations", "structures" } do
		for key, placement in raw[group] do
			assert(
				type(key) == "string" and type(placement) == "table" and type(placement.definition) == "table",
				"INVALID_PLACEMENT"
			)
			local definition = definitions[placement.definition.id]
			assert(definition and equal(definition, placement.definition), "PINNED_DEFINITION_MISMATCH")
			local prefix = config.tribeId .. ":"
			assert(
				type(placement.id) == "string" and string.sub(placement.id, 1, #prefix) == prefix,
				"INVALID_STRUCTURE_ID"
			)
			local id = string.sub(placement.id, #prefix + 1)
			assert(id ~= "" and not occupied[id] and raw.usedIds[id] == true, "INVALID_USED_ID")
			assert(key == (if group == "reservations" then id else placement.id), "INVALID_PLACEMENT_KEY")
			assert(type(placement.actorId) == "string" and placement.actorId ~= "", "INVALID_PLACEMENT_ACTOR")
			assert(
				type(placement.membershipRevision) == "number"
					and integer(placement.membershipRevision, 0, raw.membershipRevision),
				"INVALID_PLACEMENT_REVISION"
			)
			-- Historical builder may have left. Use a temporary authorized builder
			-- solely to reconstruct geometry, then retain the validated historical actor.
			local rebuilt, err = Settlement.reserve(
				result,
				result.ownerId,
				result.version,
				result.membershipRevision,
				{ id = id, definition = definition, x = placement.x, z = placement.z, rotation = placement.rotation }
			)
			assert(rebuilt, err)
			assert(
				equal(rebuilt.reservations[id].cells, placement.cells)
					and equal(rebuilt.reservations[id].entry, placement.entry),
				"INVALID_OCCUPANCY"
			)
			result = rebuilt
			result.reservations[id].actorId = placement.actorId
			result.reservations[id].membershipRevision = placement.membershipRevision
			if group == "structures" then
				result.structures[placement.id] = result.reservations[id]
				result.reservations[id] = nil
			end
			occupied[id] = true
		end
	end
	for id, used in raw.usedIds do
		assert(type(id) == "string" and id ~= "" and used == true, "INVALID_USED_ID")
	end
	-- Legacy saves predate the membership clock: no join stamps (league-ineligible
	-- until rejoined) and no recorded departures.
	local joinedAt = if raw.joinedAt == nil then {} else raw.joinedAt
	local departedAt = if raw.departedAt == nil then {} else raw.departedAt
	assert(type(joinedAt) == "table" and type(departedAt) == "table", "INVALID_MEMBERSHIP_CLOCK")
	for actor, at in joinedAt do
		assert(raw.roles[actor] ~= nil and type(at) == "number" and integer(at, 0, MAX_CLOCK), "INVALID_JOINED_AT")
	end
	for actor, at in departedAt do
		assert(
			type(actor) == "string"
				and actor ~= ""
				and raw.roles[actor] == nil
				and type(at) == "number"
				and integer(at, 0, MAX_CLOCK),
			"INVALID_DEPARTED_AT"
		)
	end
	result.joinedAt, result.departedAt = copy(joinedAt), copy(departedAt)
	result.roles, result.usedIds = copy(raw.roles), copy(raw.usedIds)
	result.version, result.membershipRevision = raw.version, raw.membershipRevision
	return result
end

function Settlement.save(state: State): any
	local saved = copy(state)
	saved.saveVersion = 1
	return saved
end

return Settlement
