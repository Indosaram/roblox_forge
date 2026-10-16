--!strict
-- Teleport: commit-before-teleport flow (plan §11.1, C39).
--
--   1. commit the player's state to DataStore (local data is discarded on hop)
--   2. TeleportAsync with TeleportOptions.ReservedServerAccessCode
--   3. retry with exponential backoff (default 3 attempts) via an injected sleep
--   4. still failing -> fall back: the player stays on the origin server
--
-- TeleportData is never sent and never trusted: the destination rebuilds state
-- from the committed DataStore record only (see Teleport.arrive). Services are
-- injected; teleportService(TeleportService) adapts the live engine API.

export type Port = {
	-- Returns ok plus an error string. Must not raise.
	teleport: (placeId: number, playerIds: { number }, accessCode: string) -> (boolean, string?),
}

export type Options = {
	port: Port,
	-- Durably commits the player's state before the hop; false aborts the teleport.
	commit: (playerId: number) -> (boolean, string?),
	-- Injected scheduler: task.wait in Studio, a fake clock in specs.
	sleep: (seconds: number) -> (),
	maxAttempts: number?,
	baseDelaySeconds: number?,
}

export type Result = {
	playerId: number,
	status: "arrived" | "fallback",
	attempts: number,
	reason: string?,
}

local Teleport = {}
Teleport.__index = Teleport

export type Teleport = typeof(setmetatable(
	{} :: {
		_opts: Options,
		_maxAttempts: number,
		_baseDelay: number,
	},
	Teleport
))

function Teleport.new(opts: Options): Teleport
	assert(type(opts.commit) == "function" and type(opts.sleep) == "function", "commit and sleep required")
	local maxAttempts = opts.maxAttempts or 3
	local baseDelay = opts.baseDelaySeconds or 1
	assert(maxAttempts >= 1 and maxAttempts % 1 == 0, "invalid attempt count")
	assert(baseDelay >= 0, "invalid base delay")
	return setmetatable({ _opts = opts, _maxAttempts = maxAttempts, _baseDelay = baseDelay }, Teleport)
end

-- Delay slept after the given failed attempt (1-based): base, 2*base, 4*base...
function Teleport.backoff(self: Teleport, attempt: number): number
	return self._baseDelay * 2 ^ (attempt - 1)
end

function Teleport.send(self: Teleport, playerId: number, placeId: number, accessCode: string): Result
	if type(accessCode) ~= "string" or #accessCode == 0 then
		return { playerId = playerId, status = "fallback", attempts = 0, reason = "missing access code" }
	end
	local committed, commitErr = self._opts.commit(playerId)
	if not committed then
		-- Never hop with uncommitted state: the destination would load stale data.
		return {
			playerId = playerId,
			status = "fallback",
			attempts = 0,
			reason = "commit failed: " .. tostring(commitErr),
		}
	end
	local lastErr: string? = nil
	for attempt = 1, self._maxAttempts do
		local ok, err = self._opts.port.teleport(placeId, { playerId }, accessCode)
		if ok then
			return { playerId = playerId, status = "arrived", attempts = attempt, reason = nil }
		end
		lastErr = err or "teleport failed"
		if attempt < self._maxAttempts then
			self._opts.sleep(self:backoff(attempt))
		end
	end
	return { playerId = playerId, status = "fallback", attempts = self._maxAttempts, reason = lastErr }
end

-- Destination-side entry: state comes only from the committed store record.
-- joinData (TeleportData / GetJoinData) is accepted but deliberately ignored.
function Teleport.arrive(load: (playerId: number) -> any, playerId: number, _joinData: any?): any
	return load(playerId)
end

-- Live adapter over TeleportService. TeleportOptions is created per call and
-- carries no TeleportData. The constructor is injected so this module never
-- touches engine globals at require time.
function Teleport.teleportService(teleportService: any, players: any, newOptions: () -> any): Port
	return {
		teleport = function(placeId: number, playerIds: { number }, accessCode: string): (boolean, string?)
			local targets = {}
			for _, id in playerIds do
				local player = players:GetPlayerByUserId(id)
				if player == nil then
					return false, "player left"
				end
				table.insert(targets, player)
			end
			local ok, err = pcall(function()
				local options = newOptions()
				options.ReservedServerAccessCode = accessCode
				teleportService:TeleportAsync(placeId, targets, options)
			end)
			return ok, if ok then nil else tostring(err)
		end,
	}
end

return Teleport
