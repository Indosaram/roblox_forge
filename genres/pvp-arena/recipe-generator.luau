--!strict
local Types = require("../../cli/forge/lib/genrecontract")
local Executor = require("../../core/domain/genre/Executor")
local Bounty = require("./module/ArenaBounty")
local M = {}
-- The collect side starts at zero Coins: the arena is the only faucet into the hatch economy.
function M.normalize(configs: { [string]: any }): { [string]: any }
	local result = Executor.clone(configs)
	result["collect-raid"].startingCoins = 0
	return result
end
local function action(executor: Executor.Executor, player: string, id: string, args: { any }, expected: boolean)
	local result = executor.dispatchClient(player, id, args)
	assert(result.ok == expected, id .. ": " .. tostring(result.reason))
end
local function coins(executor: Executor.Executor, player: string): number
	return executor.snapshot(player)["collect-raid"].coins
end
-- One decided duel from `start`: both queue, the countdown elapses and `winner` lands three
-- one-second-apart hits, then the intermission returns both players to the lobby.
local function duel(executor: Executor.Executor, winner: string, loser: string, start: number)
	action(executor, winner, "pvp-arena:enqueue", {}, true)
	action(executor, loser, "pvp-arena:enqueue", {}, true)
	executor.advance(start + 1)
	for hit = 1, 3 do
		if hit > 1 then
			executor.advance(start + hit)
		end
		action(executor, winner, "pvp-arena:attack", {}, true)
	end
	executor.advance(start + 4)
end
local function run(executor: Executor.Executor, _input: Types.GenerateInput): { Types.Check }
	local a, b = "bounty-proof-a", "bounty-proof-b"
	assert(executor.join(a).ok and executor.join(b).ok, "bounty join")
	executor.advance(0)
	local unfunded = coins(executor, a) == 0
	action(executor, a, "collect-raid:buy-source", { "ember" }, false)
	duel(executor, a, b, 0)
	local paid = coins(executor, a) == Bounty.BOUNTY and coins(executor, b) == 0
	action(executor, a, "collect-raid:buy-source", { "ember" }, true)
	action(executor, a, "collect-raid:buy-source", { "ember" }, false)
	executor.advance(9)
	action(executor, a, "collect-raid:hatch", { 1 }, true)
	local hatched = executor.snapshot(a)["collect-raid"].creatures[1]
	-- A forfeit settles the rating but pays no bounty, so leaving a match mints nothing.
	action(executor, a, "pvp-arena:enqueue", {}, true)
	action(executor, b, "pvp-arena:enqueue", {}, true)
	executor.advance(10)
	local before = coins(executor, a)
	executor.leave(b)
	local forfeit = coins(executor, a) == before and executor.snapshot(a)["pvp-arena"].rating > 1016
	local saved = executor.save(a)
	executor.leave(a)
	assert(executor.join(a, saved).ok, "bounty restore")
	local state = executor.snapshot(a)
	return {
		{ name = "unfunded hatch economy refuses the first source", ok = unfunded },
		{ name = "decided duel pays the winner one bounty", ok = paid },
		{ name = "bounty funds a free-currency hatch", ok = hatched ~= nil },
		{ name = "forfeit pays no bounty", ok = forfeit },
		{
			name = "one wallet and rating survive rejoin",
			ok = state["collect-raid"].creatures[1] == hatched
				and state["pvp-arena"].rating == saved.genres["pvp-arena"].data.rating
				and saved.genres["pvp-arena"].data.coins == nil,
		},
	}
end
local function simulate(
	executor: Executor.Executor,
	_input: Types.GenerateInput,
	players: number,
	days: number
): Types.SimMetrics
	local metrics: Types.SimMetrics =
		{ balances = {}, sourceTotal = 0, sinkTotal = 0, acceptedActions = 0, rejectedActions = 0 }
	local ids: { string } = {}
	for i = 1, players do
		local id = "bounty-sim-" .. i
		table.insert(ids, id)
		assert(executor.join(id).ok, "bounty sim join")
	end
	executor.advance(0)
	local function dispatch(player: string, id: string, args: { any }): boolean
		local ok = executor.dispatchClient(player, id, args).ok
		if ok then
			metrics.acceptedActions += 1
		else
			metrics.rejectedActions += 1
		end
		return ok
	end
	local function total(): number
		local sum = 0
		for _, id in ids do
			sum += coins(executor, id)
		end
		return sum
	end
	local start = total()
	local epoch = 0
	for _day = 1, days do
		for _, id in ids do
			dispatch(id, "pvp-arena:enqueue", {})
		end
		executor.advance(epoch + 1)
		for hit = 1, 3 do
			if hit > 1 then
				executor.advance(epoch + hit)
			end
			for _, id in ids do
				local rival = executor.snapshot(id)["pvp-arena"].rival
				if rival ~= nil and id < rival then
					dispatch(id, "pvp-arena:attack", {})
				end
			end
		end
		executor.advance(epoch + 4)
		for _, id in ids do
			local before = coins(executor, id)
			if dispatch(id, "collect-raid:buy-source", { "ember" }) then
				metrics.sinkTotal += before - coins(executor, id)
			end
		end
		epoch += 9
		executor.advance(epoch)
		for _, id in ids do
			if #executor.snapshot(id)["collect-raid"].incubators > 0 then
				dispatch(id, "collect-raid:hatch", { 1 })
			end
		end
	end
	metrics.sourceTotal = total() - start + metrics.sinkTotal
	for _, id in ids do
		metrics.balances[id] = coins(executor, id)
	end
	return metrics
end
M.driver = { run = run, simulate = simulate }
-- The recipe's published native scenario: the native twin of `run`. The collect wallet starts
-- empty, so the first source is refused; a decided duel pays the winner the bounty into the
-- one collect-raid wallet (the loser gets none); the bounty buys a source that hatches on free
-- Coins; and the hatch, wallet and rating survive save, rejoin and restore. `partners` lets
-- this pvp-arena scenario dispatch collect-raid actions. `advance_elapsed` is absolute.
local qa: { name: string, players: { string }, goldenPath: { { [string]: any } } } = {
	name = "golden-path",
	players = { "1", "2" },
	goldenPath = {
		{ op = "begin_clock" },
		{ op = "join", player = "1" },
		{ op = "join", player = "2" },
		{ op = "expect_snapshot", player = "1", genre = "collect-raid", field = "coins", equals = 0 },
		{
			op = "dispatch",
			player = "1",
			action = "collect-raid:buy-source",
			args = { "ember" } :: { any },
			expect = "refused",
		},
		{ op = "dispatch", player = "1", action = "pvp-arena:enqueue", expect = "ok" },
		{ op = "dispatch", player = "2", action = "pvp-arena:enqueue", expect = "ok" },
		{ op = "advance_elapsed", seconds = 1 },
		{ op = "expect_snapshot", player = "1", genre = "pvp-arena", field = "phase", equals = "active" },
		{ op = "dispatch", player = "1", action = "pvp-arena:attack", expect = "ok" },
		{ op = "dispatch", player = "1", action = "pvp-arena:attack", expect = "refused" },
		{ op = "advance_elapsed", seconds = 2 },
		{ op = "dispatch", player = "1", action = "pvp-arena:attack", expect = "ok" },
		{ op = "expect_snapshot", player = "1", genre = "collect-raid", field = "coins", equals = 0 },
		{ op = "advance_elapsed", seconds = 3 },
		{ op = "dispatch", player = "1", action = "pvp-arena:attack", expect = "ok" },
		{ op = "expect_snapshot", player = "1", genre = "pvp-arena", field = "rating", equals = 1016 },
		{ op = "expect_snapshot", player = "1", genre = "collect-raid", field = "coins", equals = 50 },
		{ op = "expect_snapshot", player = "2", genre = "collect-raid", field = "coins", equals = 0 },
		{ op = "dispatch", player = "1", action = "pvp-arena:attack", expect = "refused" },
		{ op = "expect_snapshot", player = "1", genre = "collect-raid", field = "coins", equals = 50 },
		{
			op = "dispatch",
			player = "1",
			action = "collect-raid:buy-source",
			args = { "ember" } :: { any },
			expect = "ok",
		},
		{ op = "expect_snapshot", player = "1", genre = "collect-raid", field = "coins", equals = 0 },
		{ op = "dispatch", player = "1", action = "collect-raid:hatch", args = { 1 } :: { any }, expect = "refused" },
		{ op = "advance_elapsed", seconds = 8 },
		{ op = "dispatch", player = "1", action = "collect-raid:hatch", args = { 1 } :: { any }, expect = "ok" },
		{ op = "expect_snapshot", player = "1", genre = "collect-raid", field = "creatures.1", is_nil = false },
		{ op = "save", player = "1", label = "saved" },
		{ op = "leave", player = "1" },
		{ op = "join", player = "1" },
		{ op = "expect_snapshot", player = "1", genre = "collect-raid", field = "creatures.1", is_nil = false },
		{ op = "expect_snapshot", player = "1", genre = "pvp-arena", field = "rating", equals = 1016 },
		{ op = "restore", player = "1", from = "saved" },
		{ op = "expect_snapshot", player = "1", genre = "collect-raid", field = "creatures.1", is_nil = false },
		{ op = "expect_snapshot", player = "1", genre = "pvp-arena", field = "rating", equals = 1016 },
	},
}
M.qa = qa
return M
