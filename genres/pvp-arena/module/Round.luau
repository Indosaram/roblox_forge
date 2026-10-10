--!strict
-- Round: pvp-arena round state machine (lobby -> countdown -> active -> ended -> lobby).

local Round = {}
Round.__index = Round

export type Config = {
	minPlayers: number,
	countdown: number,
	duration: number,
	intermission: number,
}

export type Hooks = {
	OnRoundStart: (() -> ())?,
	OnRoundEnd: (() -> ())?,
}

export type Phase = "lobby" | "countdown" | "active" | "ended"

export type Round = typeof(setmetatable(
	{} :: {
		config: Config,
		hooks: Hooks,
		phase: Phase,
		countdownStart: number?,
		roundStart: number?,
		endedAt: number?,
	},
	Round
))

local function checkNumber(value: any, name: string): ()
	if type(value) ~= "number" or value ~= value then
		error("invalid " .. name)
	end
end

local function checkConfig(config: Config): ()
	checkNumber(config.minPlayers, "minPlayers")
	checkNumber(config.countdown, "countdown")
	checkNumber(config.duration, "duration")
	checkNumber(config.intermission, "intermission")
end

function Round.new(config: Config, hooks: Hooks?): Round
	checkConfig(config)
	local self = setmetatable({
		config = config,
		hooks = hooks or {},
		phase = "lobby" :: Phase,
		countdownStart = nil,
		roundStart = nil,
		endedAt = nil,
	}, Round)
	return self
end

-- Advances the machine for a single tick at time `now` with `playerCount` waiting
-- players. At most one transition happens per tick; the resulting phase is returned.
function Round.tick(self: Round, now: number, playerCount: number): Phase
	if self.phase == "lobby" then
		if playerCount >= self.config.minPlayers then
			self.phase = "countdown"
			self.countdownStart = now
		end
	elseif self.phase == "countdown" then
		if playerCount < self.config.minPlayers then
			self.phase = "lobby"
			self.countdownStart = nil
		elseif now >= (self.countdownStart or now) + self.config.countdown then
			self.phase = "active"
			self.roundStart = now
			local hook = self.hooks.OnRoundStart
			if hook then
				hook()
			end
		end
	elseif self.phase == "active" then
		if now >= (self.roundStart or now) + self.config.duration then
			self.phase = "ended"
			self.endedAt = now
			local hook = self.hooks.OnRoundEnd
			if hook then
				hook()
			end
		end
	elseif self.phase == "ended" then
		if now >= (self.endedAt or now) + self.config.intermission then
			self.phase = "lobby"
			self.endedAt = nil
		end
	end
	return self.phase
end

function Round.state(self: Round): Phase
	return self.phase
end

return Round
