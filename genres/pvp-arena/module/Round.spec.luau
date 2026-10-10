--!strict
-- Specs for Round: lobby -> countdown -> active -> ended -> lobby transitions and hooks.

local Round = require("./Round")

local function newRound(hooks: Round.Hooks?)
	return Round.new({
		minPlayers = 2,
		countdown = 5,
		duration = 10,
		intermission = 3,
	}, hooks)
end

return {
	["fractional deadlines at nonzero origin transition once per tick"] = function()
		local ended = 0
		local r = Round.new({ minPlayers = 2, countdown = 0.1, duration = 0.1, intermission = 0.1 }, {
			OnRoundEnd = function()
				ended += 1
			end,
		})
		assert(r:tick(100, 2) == "countdown", "one transition into countdown")
		local activeAt = 100 + 0.1
		assert(r:tick(activeAt - 0.001, 2) == "countdown", "before countdown deadline")
		assert(r:tick(activeAt, 2) == "active", "exact countdown deadline")
		local endedAt = activeAt + 0.1
		assert(r:tick(endedAt - 0.001, 2) == "active", "before active deadline")
		assert(r:tick(endedAt, 2) == "ended", "exact active deadline")
		assert(ended == 1, "end notification once")
		assert(r:tick(endedAt + 0.1, 2) == "lobby", "exact intermission deadline")
		assert(r:tick(1000, 2) == "countdown", "delayed tick does not skip a phase")
	end,
	["lobby stays when not enough players"] = function()
		local started = 0
		local r = newRound({
			OnRoundStart = function()
				started += 1
			end,
		})
		assert(Round.tick(r, 0, 1) == "lobby", "below minimum stays in lobby")
		assert(Round.state(r) == "lobby", "state reads lobby")
		assert(started == 0, "no round start fired")
	end,

	["lobby transitions to countdown when enough players"] = function()
		local r = newRound()
		assert(Round.tick(r, 0, 2) == "countdown", "enough players starts countdown")
		assert(Round.state(r) == "countdown", "state reads countdown")
	end,

	["countdown aborts to lobby when players drop"] = function()
		local r = newRound()
		assert(Round.tick(r, 0, 2) == "countdown", "countdown entered")
		assert(Round.tick(r, 2, 1) == "lobby", "drop below minimum aborts")
		assert(Round.state(r) == "lobby", "state reads lobby")
	end,

	["countdown transitions to active and fires OnRoundStart"] = function()
		local started = 0
		local ended = 0
		local r = newRound({
			OnRoundStart = function()
				started += 1
			end,
			OnRoundEnd = function()
				ended += 1
			end,
		})
		assert(Round.tick(r, 0, 2) == "countdown", "countdown entered")
		assert(Round.tick(r, 4, 2) == "countdown", "still counting down")
		assert(Round.tick(r, 5, 2) == "active", "countdown elapsed starts round")
		assert(started == 1, "OnRoundStart fired once")
		assert(ended == 0, "round has not ended")
	end,

	["active transitions to ended and fires OnRoundEnd"] = function()
		local started = 0
		local ended = 0
		local r = newRound({
			OnRoundStart = function()
				started += 1
			end,
			OnRoundEnd = function()
				ended += 1
			end,
		})
		Round.tick(r, 0, 2)
		Round.tick(r, 5, 2)
		assert(Round.tick(r, 14, 2) == "active", "round still running")
		assert(ended == 0, "no end yet")
		assert(Round.tick(r, 15, 2) == "ended", "duration elapsed ends round")
		assert(ended == 1, "OnRoundEnd fired once")
		assert(started == 1, "start still fired once")
	end,

	["ended returns to lobby after the intermission"] = function()
		local r = newRound()
		Round.tick(r, 0, 2)
		Round.tick(r, 5, 2)
		Round.tick(r, 15, 2)
		assert(Round.tick(r, 17, 2) == "ended", "still in intermission")
		assert(Round.tick(r, 18, 2) == "lobby", "intermission elapsed returns to lobby")
		assert(Round.state(r) == "lobby", "state reads lobby")
	end,
}
