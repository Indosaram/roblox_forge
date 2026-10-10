--!strict
-- Rank: standard Elo rating updates with a zero floor.

local Rank = {}

local function expectedScore(ratingA: number, ratingB: number): number
	return 1 / (1 + 10 ^ ((ratingB - ratingA) / 400))
end

-- Applies one Elo update. `scoreA` is 1 for an A win, 0.5 for a draw, 0 for a
-- loss; `k` is the rating step. Both new ratings are floored at 0.
function Rank.update(ratingA: number, ratingB: number, scoreA: number, k: number): (number, number)
	local expectedA = expectedScore(ratingA, ratingB)
	local expectedB = 1 - expectedA
	local newA = ratingA + k * (scoreA - expectedA)
	local newB = ratingB + k * ((1 - scoreA) - expectedB)
	return math.max(0, newA), math.max(0, newB)
end

return Rank
