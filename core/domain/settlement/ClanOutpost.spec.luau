--!strict
local Outpost = require("./ClanOutpost")
local rules = { minTeam = 3, maxTeam = 8, matchSeconds = 600, captureSeconds = 180, ownershipSeconds = 86400 }
local teams = { { clanId = "alpha", actors = { "a", "b", "c" } }, { clanId = "beta", actors = { "d", "e", "f" } } }
local function facts(): any
	return {
		server = true,
		role = "team-outpost",
		rules = rules,
		teams = teams,
		occupants = {},
		eligible = function(): boolean
			return true
		end,
		optedIn = function(): boolean
			return true
		end,
	}
end
return {
	["queue records only authoritative clan members and blocks active participants"] = function()
		local state = Outpost.new("o", "")
		local ctx: any = {
			role = "team-outpost",
			clanId = "alpha",
			eligible = function(actor: string, clan: string): boolean
				return actor == "member" and clan == "alpha"
			end,
		}
		local queued = assert(Outpost.apply(state, "member", "queue", { enabled = true }, "q", 0, ctx), "member queues")
		assert(queued.queue.member == "alpha", "server membership is retained")
		local refused, reason = Outpost.apply(state, "intruder", "queue", { enabled = true }, "x", 0, ctx)
		assert(refused == nil and reason == "NOT_TEAM_MEMBER", "foreign actor cannot join team")
		local left = assert(
			Outpost.apply(queued, "member", "queue", { enabled = false }, "leave", 0, ctx),
			"member leaves queue"
		)
		assert(left.queue.member == nil, "opt out removes queue entry")
	end,
	["outpost requires opted in distinct clan teams and forbids personal home raiding"] = function()
		local state = Outpost.new("central", "")
		local ctx = facts()
		ctx.role = "personal-home"
		assert(
			not Outpost.apply(state, "a", "start", { matchId = "one", teams = teams }, "s", 0, ctx),
			"clan invariant: 13"
		)
		ctx.role = "team-outpost"
		ctx.server = false
		assert(
			not Outpost.apply(state, "a", "start", { matchId = "one", teams = teams }, "s", 0, ctx),
			"clan invariant: 16"
		)
		ctx.server = true
		ctx.optedIn = function(): boolean
			return false
		end
		assert(
			not Outpost.apply(state, "a", "start", { matchId = "one", teams = teams }, "s", 0, ctx),
			"clan invariant: 19"
		)
		ctx.optedIn = function(): boolean
			return true
		end
		ctx.eligible = function(): boolean
			return false
		end
		assert(
			not Outpost.apply(state, "a", "start", { matchId = "one", teams = teams }, "s", 0, ctx),
			"clan invariant: 22"
		)
		ctx.eligible = function(): boolean
			return true
		end
		ctx.teams = { teams[1], teams[1] }
		assert(not Outpost.apply(state, "a", "start", { matchId = "one" }, "s", 0, ctx), "clan invariant: 25")
		ctx.teams = { { clanId = "alpha", actors = { "a" } }, teams[2] }
		assert(not Outpost.apply(state, "a", "start", { matchId = "one" }, "s", 0, ctx), "clan invariant: 27")
	end,
	["outpost contested capture and duplicate settlement never extend ownership"] = function()
		local ctx = facts()
		local state = assert(
			Outpost.apply(Outpost.new("central", ""), "a", "start", { matchId = "one", teams = teams }, "start", 0, ctx),
			"clan invariant: 31"
		)
		assert(
			not Outpost.apply(state, "a", "start", { matchId = "two", teams = teams }, "start2", 0, ctx),
			"clan invariant: 32"
		)
		ctx.occupants = { "a", "d" }
		state = assert(
			Outpost.apply(state, "a", "advance", { matchId = "one" }, "contested", 100, ctx),
			"clan invariant: 34"
		)
		assert(state.matches.one.score[1] == 0 and state.matches.one.score[2] == 0, "clan invariant: 35")
		ctx.occupants = { "a", "b", "intruder" }
		state = assert(Outpost.apply(state, "a", "advance", { matchId = "one" }, "win", 280, ctx), "clan invariant: 37")
		assert(state.owner == "alpha" and state.expiresAt == 280 + rules.ownershipSeconds, "clan invariant: 38")
		local replay =
			assert(Outpost.apply(state, "a", "advance", { matchId = "one" }, "win", 500, ctx), "clan invariant: 39")
		assert(replay.expiresAt == state.expiresAt and replay.revision == state.revision, "clan invariant: 40")
		assert(not Outpost.apply(state, "a", "advance", { matchId = "one" }, "again", 500, ctx), "clan invariant: 41")
	end,
	["outpost timeout tie retains existing expiry and excludes departed participants"] = function()
		local ctx = facts()
		local state = Outpost.new("central", "")
		state.owner, state.expiresAt = "alpha", 30
		state = assert(
			Outpost.apply(state, "a", "start", { matchId = "one", teams = teams }, "start", 0, ctx),
			"clan invariant: 47"
		)
		ctx.occupants = { "a" }
		ctx.eligible = function(): boolean
			return false
		end
		state = assert(Outpost.apply(state, "a", "advance", { matchId = "one" }, "end", 600, ctx), "clan invariant: 50")
		assert(state.matches.one.status == "settled" and state.matches.one.winner == "", "clan invariant: 51")
		assert(state.owner == "alpha" and state.expiresAt == 30, "clan invariant: 52")
	end,
}
