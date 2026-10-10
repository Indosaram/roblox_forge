--!strict
-- ThemeRound: social-rp-fashion round state machine
-- (lobby -> dressing -> voting -> results -> lobby). The theme is chosen from a
-- theme list through a caller-supplied seeded `pickIndex(count)`.

export type Config = {
	minPlayers: number,
	dressingSeconds: number,
	votingSeconds: number,
	resultsSeconds: number,
}

export type Hooks = {
	OnThemeStart: ((string) -> ())?,
	OnResults: ((string) -> ())?,
}

export type Phase = "lobby" | "dressing" | "voting" | "results"

local ThemeRound = {}
ThemeRound.__index = ThemeRound

export type ThemeRound = typeof(setmetatable(
	{} :: {
		config: Config,
		themes: { string },
		pickIndex: (number) -> number,
		hooks: Hooks,
		phase: Phase,
		theme: string?,
		phaseStart: number?,
	},
	ThemeRound
))

local function checkNumber(value: number, name: string): ()
	if type(value) ~= "number" or value ~= value then
		error("invalid " .. name)
	end
end

local function checkConfig(config: Config): ()
	if type(config) ~= "table" then
		error("invalid config")
	end
	checkNumber(config.minPlayers, "minPlayers")
	checkNumber(config.dressingSeconds, "dressingSeconds")
	checkNumber(config.votingSeconds, "votingSeconds")
	checkNumber(config.resultsSeconds, "resultsSeconds")
end

local function chooseTheme(self: ThemeRound): string
	local index = self.pickIndex(#self.themes)
	if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #self.themes then
		error("pickIndex out of range")
	end
	return self.themes[index]
end

function ThemeRound.new(config: Config, themes: { string }, pickIndex: (number) -> number, hooks: Hooks?): ThemeRound
	checkConfig(config)
	if type(themes) ~= "table" or #themes == 0 then
		error("invalid themes")
	end
	local copy: { string } = {}
	for index, theme in themes do
		if type(theme) ~= "string" or theme == "" then
			error("invalid theme")
		end
		copy[index] = theme
	end
	if type(pickIndex) ~= "function" then
		error("invalid pickIndex")
	end
	return setmetatable({
		config = config,
		themes = copy,
		pickIndex = pickIndex,
		hooks = hooks or {},
		phase = "lobby" :: Phase,
		theme = nil,
		phaseStart = nil,
	}, ThemeRound)
end

-- Advances the machine for a single tick at time `now` with `playerCount`
-- players. At most one transition happens per tick; the resulting phase is
-- returned. Entering dressing picks the theme and fires OnThemeStart; entering
-- results fires OnResults.
function ThemeRound.tick(self: ThemeRound, now: number, playerCount: number): Phase
	checkNumber(now, "now")
	checkNumber(playerCount, "playerCount")
	if self.phase == "lobby" then
		if playerCount >= self.config.minPlayers then
			self.phase = "dressing"
			self.phaseStart = now
			local theme = chooseTheme(self)
			self.theme = theme
			local hook = self.hooks.OnThemeStart
			if hook ~= nil then
				hook(theme)
			end
		end
	elseif self.phase == "dressing" then
		if now >= (self.phaseStart or now) + self.config.dressingSeconds then
			self.phase = "voting"
			self.phaseStart = now
		end
	elseif self.phase == "voting" then
		if now >= (self.phaseStart or now) + self.config.votingSeconds then
			self.phase = "results"
			self.phaseStart = now
			local theme = self.theme
			local hook = self.hooks.OnResults
			if hook ~= nil and theme ~= nil then
				hook(theme)
			end
		end
	elseif self.phase == "results" then
		if now >= (self.phaseStart or now) + self.config.resultsSeconds then
			self.phase = "lobby"
			self.phaseStart = nil
			self.theme = nil
		end
	end
	return self.phase
end

function ThemeRound.state(self: ThemeRound): Phase
	return self.phase
end

function ThemeRound.currentTheme(self: ThemeRound): string?
	return self.theme
end

return ThemeRound
