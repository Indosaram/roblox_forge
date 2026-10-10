--!strict
-- Specs for Voting: star validation, one vote per voter per target, no self-votes,
-- and result ordering.

local Voting = require("./Voting")

return {
	["a valid vote is recorded"] = function()
		local state = Voting.new()
		assert(Voting.cast(state, "alice", "bob", 5), "a valid vote is accepted")
		local total, count = Voting.score(state, "bob")
		assert(total == 5 and count == 1, "the score reflects the vote")
		assert(Voting.average(state, "bob") == 5, "the average of one vote")
	end,

	["a voter cannot vote twice for the same target"] = function()
		local state = Voting.new()
		assert(Voting.cast(state, "alice", "bob", 4), "the first vote is accepted")
		local ok, reason = Voting.cast(state, "alice", "bob", 1)
		assert(not ok and reason == "already voted", "the second vote is refused, got " .. tostring(reason))
		local total, count = Voting.score(state, "bob")
		assert(total == 4 and count == 1, "only the first vote counts")
	end,

	["self-votes and out-of-range stars are refused"] = function()
		local state = Voting.new()
		local selfOk, selfReason = Voting.cast(state, "alice", "alice", 5)
		assert(not selfOk and selfReason == "self vote", "a self-vote is refused, got " .. tostring(selfReason))
		local highOk, highReason = Voting.cast(state, "alice", "bob", 6)
		assert(not highOk and highReason == "invalid stars", "six stars is refused, got " .. tostring(highReason))
		local zeroOk, zeroReason = Voting.cast(state, "alice", "bob", 0)
		assert(not zeroOk and zeroReason == "invalid stars", "zero stars is refused, got " .. tostring(zeroReason))
		assert(Voting.cast(state, "alice", "bob", 3), "a legal vote still works")
	end,

	["results rank by average then by vote count"] = function()
		local state = Voting.new()
		Voting.cast(state, "a", "x", 5)
		Voting.cast(state, "b", "x", 5)
		Voting.cast(state, "g", "w", 5)
		Voting.cast(state, "c", "m", 4)
		Voting.cast(state, "d", "m", 4)
		Voting.cast(state, "e", "b", 4)
		Voting.cast(state, "h", "b", 4)
		local results = Voting.results(state)
		assert(#results == 4, "four scored targets")
		assert(results[1].target == "x", "the highest average ranks first")
		assert(results[2].target == "w", "a tied average breaks on vote count")
		assert(results[3].target == "b", "a tie on average and vote count breaks on target name")
		assert(results[4].target == "m", "a tie on average and vote count breaks on target name")
		assert(results[1].average == 5 and results[1].votes == 2, "result fields")
		assert(results[3].average == 4 and results[3].votes == 2, "b and m are tied on average and vote count")
		assert(results[4].average == 4 and results[4].votes == 2, "b and m are tied on average and vote count")
	end,

	["an empty state has no results"] = function()
		local state = Voting.new()
		assert(#Voting.results(state) == 0, "nothing to rank")
		assert(Voting.average(state, "nobody") == 0, "an unknown target averages zero")
	end,
}
