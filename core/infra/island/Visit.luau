--!strict
-- Visit: a friend visiting another player's home island (plan 7). A visitor may
-- only read the island and run registered help actions; taking is impossible by
-- construction: there is no take operation, help handlers never see the
-- visitor's inventory, and every help candidate is refused if any host item
-- count decreases. Friendship comes from a trusted server port (for example a
-- Players:IsFriendsWithAsync cache), never from the request. Time is a parameter.
local M = {}

export type Island = { hostId: string, version: number, items: { [string]: number }, data: { [string]: any } }
-- Pure, non-yielding; returns a candidate island or a refusal reason.
export type Help = (island: Island, visitorId: string, args: { any }) -> (Island?, string?)
export type Config = {
	isFriend: (hostId: string, visitorId: string) -> boolean,
	help: { [string]: Help },
	durationSeconds: number,
}
export type Pass = { hostId: string, visitorId: string, expiresAt: number }
export type Visit = {
	open: (hostId: string, visitorId: string, now: number) -> (Pass?, string?),
	read: (pass: Pass, island: Island, now: number) -> (Island?, string?),
	help: (pass: Pass, island: Island, action: string, args: { any }, now: number) -> (Island?, string?),
}

local MAX_CLOCK = 2 ^ 53 - 1

local function integer(value: any, minimum: number, maximum: number): boolean
	return type(value) == "number" and value == value and value >= minimum and value <= maximum and value % 1 == 0
end

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

function M.new(config: Config): Visit
	assert(integer(config.durationSeconds, 1, 86400), "invalid visit duration")
	for name, handler in config.help do
		assert(type(name) == "string" and name ~= "" and type(handler) == "function", "invalid help action")
	end
	local visit = {} :: Visit

	local function valid(pass: Pass, island: Island, now: number): string?
		if not integer(now, 0, MAX_CLOCK) then
			return "INVALID_CLOCK"
		elseif island.hostId ~= pass.hostId then
			return "WRONG_ISLAND"
		elseif now >= pass.expiresAt then
			return "VISIT_EXPIRED"
		elseif not config.isFriend(pass.hostId, pass.visitorId) then
			return "NOT_FRIEND"
		end
		return nil
	end

	function visit.open(hostId, visitorId, now)
		if not integer(now, 0, MAX_CLOCK - config.durationSeconds) then
			return nil, "INVALID_CLOCK"
		elseif hostId == "" or visitorId == "" then
			return nil, "INVALID_IDENTITY"
		elseif hostId == visitorId then
			return nil, "OWN_ISLAND"
		elseif not config.isFriend(hostId, visitorId) then
			return nil, "NOT_FRIEND"
		end
		return { hostId = hostId, visitorId = visitorId, expiresAt = now + config.durationSeconds }, nil
	end

	-- A detached copy: mutating it never reaches the host's island.
	function visit.read(pass, island, now)
		local err = valid(pass, island, now)
		if err then
			return nil, err
		end
		return copy(island), nil
	end

	function visit.help(pass, island, action, args, now)
		local err = valid(pass, island, now)
		if err then
			return nil, err
		end
		local handler = config.help[action]
		if handler == nil then
			return nil, "ACTION_NOT_ALLOWED"
		end
		local candidate, reason = handler(copy(island), pass.visitorId, copy(args))
		if candidate == nil then
			return nil, reason or "HELP_REFUSED"
		end
		if candidate.hostId ~= island.hostId then
			return nil, "WRONG_ISLAND"
		end
		for item, quantity in island.items do
			local after = candidate.items[item]
			if after == nil or not integer(after, quantity, MAX_CLOCK) then
				return nil, "TAKE_FORBIDDEN"
			end
		end
		local result = copy(candidate) :: Island
		result.version = island.version + 1
		return result, nil
	end

	return visit
end

return M
