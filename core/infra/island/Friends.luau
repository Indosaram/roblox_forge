--!strict
-- Friends: trusted friendship source for Visit (plan 7). Wraps Player:IsFriendsWith
-- behind the same service-availability guard style as IslandBootstrap: Studio, placeId 0
-- or a missing Players service yields a source that answers false for everyone; an
-- engine error answers false for that call and is never cached. Positive and negative
-- answers are cached for ttlSeconds on the injected clock, so the yielding engine call
-- happens at most once per pair per window. Friendship never comes from a request.
local M = {}

M.TTL_SECONDS = 60

export type Env = {
	players: any?,
	isStudio: boolean,
	placeId: number,
	-- Wall clock in seconds.
	now: () -> number,
	ttlSeconds: number?,
}
export type Source = (hostId: string, visitorId: string) -> boolean

local function never(): boolean
	return false
end

local function userId(value: string): number?
	local id = tonumber(value)
	if id == nil or id <= 0 or id % 1 ~= 0 then
		return nil
	end
	return id
end

function M.source(env: Env): Source
	if env.isStudio or env.placeId == 0 or env.players == nil then
		return never
	end
	local ttl = env.ttlSeconds or M.TTL_SECONDS
	local cache: { [string]: { value: boolean, expiresAt: number } } = {}
	return function(hostId, visitorId)
		local host, visitor = userId(hostId), userId(visitorId)
		if host == nil or visitor == nil or host == visitor then
			return false
		end
		local key = hostId .. "|" .. visitorId
		local known = cache[key]
		local now = env.now()
		if known and now < known.expiresAt then
			return known.value
		end
		local ok, answer = pcall(function(): any
			local player = (env.players :: any):GetPlayerByUserId(visitor)
			if player == nil then
				return false
			end
			return player:IsFriendsWith(host)
		end)
		if not ok or type(answer) ~= "boolean" then
			return false
		end
		cache[key] = { value = answer, expiresAt = now + ttl }
		return answer
	end
end

return M
