--!strict
-- Down-and-rescue rules (Robango plan C6, G19; ui-spec 6.5). Engine-free: every call takes the
-- server clock in milliseconds and positions as { x, y, z } studs, so the rules run under Lune.
-- A downed actor picks one way back:
--   "rift"   wake at the arrival rift (the world spawn),
--   "camp"   wake at the nearest camp fire,
--   "rescue" send up a flare and wait up to `windowMillis` for a nearby player to help them up,
--   "get-up" the only option in safe roles (town, home).
-- A revive is validated here: the request must be live, the rescuer alive, someone else, and
-- within `reviveStuds` of the flare. Penalties stay with the existing death-zone rules.
-- An actor that picks nothing for `idleMillis` (closed client, lost connection) wakes the
-- default way (rift, or get-up in safe roles), so nobody stays down forever.
local M = {}

export type Position = { x: number, y: number, z: number }
export type Policy = { windowMillis: number, reviveStuds: number, flareStuds: number, idleMillis: number }
export type Choice = { option: string, atMillis: number, position: Position? }
export type Request = { position: Position, atMillis: number, expiresMillis: number }
export type State = {
	policy: Policy,
	choices: { [string]: Choice },
	requests: { [string]: Request },
	downAt: { [string]: number },
}

M.POLICY = table.freeze({ windowMillis = 90000, reviveStuds = 10, flareStuds = 200, idleMillis = 120000 })
M.WILD = table.freeze({ "rift", "camp", "rescue" })
M.SAFE = table.freeze({ "get-up" })

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) <= 1000000
end

local function position(value: any): Position?
	if type(value) ~= "table" or not finite(value.x) or not finite(value.y) or not finite(value.z) then
		return nil
	end
	return { x = value.x, y = value.y, z = value.z }
end

local function distance(a: Position, b: Position): number
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.new(policy: Policy?): State
	local p = policy or M.POLICY
	assert(finite(p.windowMillis) and p.windowMillis > 0, "invalid rescue window")
	assert(finite(p.reviveStuds) and p.reviveStuds > 0, "invalid revive reach")
	assert(finite(p.flareStuds) and p.flareStuds >= p.reviveStuds, "invalid flare reach")
	assert(finite(p.idleMillis) and p.idleMillis > 0, "invalid idle limit")
	return { policy = p, choices = {}, requests = {}, downAt = {} }
end

--- The options a downed actor gets: one card in safe roles, three elsewhere.
function M.options(safe: boolean): { string }
	return table.clone(if safe then M.SAFE else M.WILD) :: { string }
end

--- Drops flares whose window ended at `now`; their owners pick again.
function M.expire(state: State, now: number)
	for actor, request in state.requests do
		if now >= request.expiresMillis then
			state.requests[actor] = nil
			local choice = state.choices[actor]
			if choice and choice.option == "rescue" then
				state.choices[actor] = nil
			end
		end
	end
end

--- Records a downed actor's choice. A flare needs the actor's position; choosing again
--- (e.g. giving up on a flare for the rift) replaces the earlier choice.
function M.choose(
	state: State,
	actor: string,
	option: string,
	down: boolean,
	safe: boolean,
	at: any,
	now: number
): (boolean, string?)
	if not table.find(M.options(safe), option) then
		return false, "INVALID_OPTION"
	end
	if not down then
		return false, "NOT_DOWN"
	end
	M.expire(state, now)
	local current = state.choices[actor]
	if current and current.option == "revive" then
		return false, "ALREADY_REVIVED"
	end
	if option == "rescue" then
		local where = position(at)
		if not where then
			return false, "POSITION_UNAVAILABLE"
		end
		local live = state.requests[actor]
		if not live then
			state.requests[actor] =
				{ position = where, atMillis = now, expiresMillis = now + state.policy.windowMillis }
		end
		state.choices[actor] = { option = "rescue", atMillis = now }
		return true, nil
	end
	state.requests[actor] = nil
	state.choices[actor] = { option = option, atMillis = now }
	return true, nil
end

--- A rescuer answers `target`'s flare. On success the target is revived where it fell.
function M.revive(
	state: State,
	rescuer: string,
	target: string,
	at: any,
	rescuerAlive: boolean,
	targetDown: boolean,
	now: number
): (boolean, string?)
	if rescuer == target then
		return false, "SELF_RESCUE"
	end
	local request = state.requests[target]
	if not request then
		return false, "NO_REQUEST"
	end
	if now >= request.expiresMillis then
		M.expire(state, now)
		return false, "REQUEST_EXPIRED"
	end
	if not targetDown then
		state.requests[target] = nil
		return false, "NOT_DOWN"
	end
	if not rescuerAlive then
		return false, "RESCUER_DOWN"
	end
	local where = position(at)
	if not where then
		return false, "POSITION_UNAVAILABLE"
	end
	if distance(where, request.position) > state.policy.reviveStuds then
		return false, "TOO_FAR"
	end
	state.requests[target] = nil
	state.choices[target] = { option = "revive", atMillis = now, position = request.position }
	return true, nil
end

--- What the world should do with a downed actor now: nil holds it down (the panel is open or
--- a flare is waiting); otherwise the chosen way back. The first call starts the idle clock.
function M.decide(state: State, actor: string, now: number, safe: boolean): Choice?
	M.expire(state, now)
	local since = state.downAt[actor]
	if since == nil then
		since = now
		state.downAt[actor] = now
	end
	local choice = state.choices[actor]
	if choice and choice.option ~= "rescue" then
		return choice
	end
	if not choice and now - since >= state.policy.idleMillis then
		return { option = if safe then "get-up" else "rift", atMillis = now }
	end
	return nil
end

--- Clears an actor once it is up again (or gone).
function M.settle(state: State, actor: string)
	state.choices[actor] = nil
	state.requests[actor] = nil
	state.downAt[actor] = nil
end

--- Actors with any rescue record (for clean-up of departed players).
function M.actors(state: State): { string }
	local seen: { [string]: boolean } = {}
	for _, map in { state.choices, state.requests, state.downAt } :: { { [string]: any } } do
		for actor in map do
			seen[actor] = true
		end
	end
	local out = {}
	for actor in seen do
		table.insert(out, actor)
	end
	table.sort(out)
	return out
end

--- Remaining flare time for `actor`, 0 when it has none.
function M.waiting(state: State, actor: string, now: number): number
	local request = state.requests[actor]
	return if request then math.max(0, request.expiresMillis - now) else 0
end

--- Live flares `viewer` can see from `at` (excluding its own), nearest first then by id.
function M.flares(
	state: State,
	viewer: string,
	at: any,
	now: number
): { { id: string, position: Position, remainingMillis: number, distance: number } }
	local out = {}
	local where = position(at)
	if not where then
		return out
	end
	for actor, request in state.requests do
		if actor ~= viewer and now < request.expiresMillis then
			local gap = distance(where, request.position)
			if gap <= state.policy.flareStuds then
				table.insert(out, {
					id = actor,
					position = table.clone(request.position),
					remainingMillis = request.expiresMillis - now,
					distance = gap,
				})
			end
		end
	end
	table.sort(out, function(a, b)
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.id < b.id
	end)
	return out
end

return M
