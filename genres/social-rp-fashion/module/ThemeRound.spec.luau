--!strict
-- Specs for ThemeRound: the lobby -> dressing -> voting -> results -> lobby cycle,
-- seeded theme selection, and the theme hooks.

local ThemeRound = require("./ThemeRound")

local function newRound(hooks: ThemeRound.Hooks?): ThemeRound.ThemeRound
	return ThemeRound.new({
		minPlayers = 2,
		dressingSeconds = 5,
		votingSeconds = 10,
		resultsSeconds = 3,
	}, { "beach", "royal", "cyber" }, function()
		return 1
	end, hooks)
end

return {
	["fractional windows transition at absolute deadlines from nonzero origin"] = function()
		local results = 0
		local round = ThemeRound.new({
			minPlayers = 2,
			dressingSeconds = 0.1,
			votingSeconds = 0.1,
			resultsSeconds = 0.1,
		}, { "garden" }, function()
			return 1
		end, {
			OnResults = function()
				results += 1
			end,
		})
		assert(round:tick(100, 2) == "dressing", "round starts at nonzero origin")
		local dressingEnd = 100 + 0.1
		assert(round:tick(dressingEnd - 0.001, 2) == "dressing", "before dressing deadline")
		assert(round:tick(dressingEnd, 2) == "voting", "absolute dressing deadline")
		local votingEnd = dressingEnd + 0.1
		assert(round:tick(votingEnd - 0.001, 2) == "voting", "before voting deadline")
		assert(round:tick(votingEnd, 2) == "results", "absolute voting deadline")
		assert(results == 1, "one result notification")
		assert(round:tick(votingEnd + 0.1, 2) == "lobby", "absolute results deadline")
	end,
	["lobby stays below the player minimum"] = function()
		local started = 0
		local round = newRound({
			OnThemeStart = function()
				started += 1
			end,
		})
		assert(ThemeRound.tick(round, 0, 1) == "lobby", "one player stays in the lobby")
		assert(ThemeRound.state(round) == "lobby", "state reads lobby")
		assert(started == 0, "no theme started")
		assert(ThemeRound.currentTheme(round) == nil, "no theme chosen yet")
	end,

	["lobby picks a theme through pickIndex and fires OnThemeStart"] = function()
		local seenCount = 0
		local themes: { string } = {}
		local round = ThemeRound.new({
			minPlayers = 2,
			dressingSeconds = 5,
			votingSeconds = 10,
			resultsSeconds = 3,
		}, { "beach", "royal", "cyber" }, function(count)
			seenCount = count
			return 2
		end, {
			OnThemeStart = function(theme)
				table.insert(themes, theme)
			end,
		})
		assert(ThemeRound.tick(round, 0, 2) == "dressing", "enough players start dressing")
		assert(seenCount == 3, "pickIndex receives the theme count")
		assert(ThemeRound.currentTheme(round) == "royal", "pickIndex selects the theme")
		assert(#themes == 1 and themes[1] == "royal", "OnThemeStart fires with the theme")
	end,

	["dressing hands off to voting after its window"] = function()
		local results = 0
		local round = newRound({
			OnResults = function()
				results += 1
			end,
		})
		ThemeRound.tick(round, 0, 2)
		assert(ThemeRound.tick(round, 4, 2) == "dressing", "still dressing before the window ends")
		assert(ThemeRound.tick(round, 5, 2) == "voting", "the dressing window elapsed")
		assert(results == 0, "results have not fired")
		assert(ThemeRound.currentTheme(round) == "beach", "the theme persists into voting")
	end,

	["voting fires OnResults and results returns to the lobby"] = function()
		local themes: { string } = {}
		local round = newRound({
			OnResults = function(theme)
				table.insert(themes, theme)
			end,
		})
		ThemeRound.tick(round, 0, 2)
		ThemeRound.tick(round, 5, 2)
		assert(ThemeRound.tick(round, 14, 2) == "voting", "still voting")
		assert(#themes == 0, "no results yet")
		assert(ThemeRound.tick(round, 15, 2) == "results", "the voting window elapsed")
		assert(#themes == 1 and themes[1] == "beach", "OnResults fires with the theme")
		assert(ThemeRound.tick(round, 17, 2) == "results", "still showing results")
		assert(ThemeRound.tick(round, 18, 2) == "lobby", "the results window elapsed")
		assert(ThemeRound.currentTheme(round) == nil, "the theme is cleared in the lobby")
	end,

	["an out-of-range pickIndex errors"] = function()
		local round = ThemeRound.new({
			minPlayers = 1,
			dressingSeconds = 1,
			votingSeconds = 1,
			resultsSeconds = 1,
		}, { "beach" }, function()
			return 9
		end)
		local ok = pcall(function()
			ThemeRound.tick(round, 0, 1)
		end)
		assert(not ok, "an out-of-range theme index errors")
	end,
}
