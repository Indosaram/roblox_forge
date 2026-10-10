--!strict
-- Voting: 1-5 star fashion votes with one vote per voter per target and no
-- self-votes; results rank by average stars, then by vote count.

export type Result = {
	target: string,
	average: number,
	votes: number,
}

export type State = {
	votes: { [string]: { [string]: number } },
}

local Voting = {}

local function checkId(value: string, label: string): ()
	if type(value) ~= "string" or value == "" then
		error("invalid " .. label)
	end
end

function Voting.new(): State
	return { votes = {} }
end

-- Casts one 1-5 star vote. Returns (false, reason) for "self vote",
-- "invalid stars", or "already voted".
function Voting.cast(state: State, voter: string, target: string, stars: number): (boolean, string?)
	checkId(voter, "voter")
	checkId(target, "target")
	if voter == target then
		return false, "self vote"
	end
	if type(stars) ~= "number" or stars ~= stars or stars % 1 ~= 0 or stars < 1 or stars > 5 then
		return false, "invalid stars"
	end
	local targetVotes = state.votes[target]
	if targetVotes == nil then
		targetVotes = {}
		state.votes[target] = targetVotes
	end
	if targetVotes[voter] ~= nil then
		return false, "already voted"
	end
	targetVotes[voter] = stars
	return true, nil
end

-- Returns (total stars, vote count) for a target.
function Voting.score(state: State, target: string): (number, number)
	checkId(target, "target")
	local targetVotes = state.votes[target]
	if targetVotes == nil then
		return 0, 0
	end
	local total = 0
	local count = 0
	for _, stars in targetVotes do
		total += stars
		count += 1
	end
	return total, count
end

function Voting.average(state: State, target: string): number
	local total, count = Voting.score(state, target)
	if count == 0 then
		return 0
	end
	return total / count
end

-- Targets ranked by average stars (descending), then vote count (descending),
-- then target name (ascending) so the order is stable.
function Voting.results(state: State): { Result }
	local results: { Result } = {}
	for target, targetVotes in state.votes do
		local total = 0
		local count = 0
		for _, stars in targetVotes do
			total += stars
			count += 1
		end
		table.insert(results, { target = target, average = total / count, votes = count })
	end
	table.sort(results, function(a, b)
		if a.average ~= b.average then
			return a.average > b.average
		end
		if a.votes ~= b.votes then
			return a.votes > b.votes
		end
		return a.target < b.target
	end)
	return results
end

return Voting
