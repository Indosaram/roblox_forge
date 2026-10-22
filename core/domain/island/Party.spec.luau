--!strict
local Party = require("./Party")
-- Minimal authored content: first-stage gates per route and two stages per island.
local Content: any = { stages = {}, layouts = {} }
for route, gate in { { 2, 2 }, { 35, 4 }, { 40, 6 }, { 50, 8 }, { 60, 10 } } do
	for stage = 1, 4 do
		local layout = "rw.a" .. route .. ".s" .. stage
		table.insert(Content.layouts, { id = layout, biomes = { "grassland" } })
		for _, kind in { "a", "b" } do
			table.insert(Content.stages, {
				id = layout .. "." .. kind,
				layout = layout,
				gates = { characterLevel = gate[1], developmentRank = gate[2] },
			})
		end
	end
end

local READY = { level = 60, developmentRank = 10, instabilityAccess = 5 }

return {
	["invite accept leave keeps the party separate from any clan and capped at eight"] = function()
		local state = Party.new()
		assert(Party.invite(state, "a", "b", 0), "leader invites")
		assert((Party.partyOf(state, "a") :: any).leader == "a", "inviting creates a party led by the inviter")
		assert(Party.accept(state, "b", "a", 10), "accept within validity")
		assert(#(Party.partyOf(state, "a") :: any).members == 2, "two members")
		local ok, reason = Party.invite(state, "b", "c", 10)
		assert(not ok and reason == "party_not_leader", "only the leader invites")
		for i = 1, 6 do
			assert(Party.invite(state, "a", "p" .. i, 10), "invite " .. i)
		end
		local full, fullReason = Party.invite(state, "a", "p7", 10)
		assert(not full and fullReason == "party_full", "pending invites count toward capacity 8")
		assert(Party.leave(state, "a"), "leader leaves")
		assert((Party.partyOf(state, "b") :: any).leader == "b", "leadership passes on")
	end,
	["an expired or unknown invite is refused"] = function()
		local state = Party.new()
		assert(Party.invite(state, "a", "b", 0), "invite")
		local ok, reason = Party.accept(state, "b", "a", Party.INVITE_SECONDS)
		assert(not ok and reason == "invite_expired", "expired at the boundary")
		local again, missing = Party.accept(state, "b", "a", 1)
		assert(not again and missing == "invite_missing", "consumed invite cannot be replayed")
		assert(not Party.decline(state, "b", "a"), "nothing to decline")
	end,
	["remove and share are leader only and share updates pending invites"] = function()
		local state = Party.new()
		Party.invite(state, "a", "b", 0)
		Party.accept(state, "b", "a", 1)
		Party.invite(state, "a", "c", 1)
		local ok, reason = Party.remove(state, "b", "a")
		assert(not ok and reason == "party_not_leader", "member cannot remove")
		assert(Party.share(state, "a", 2), "leader shares route 2")
		assert(Party.view(state, "c", 2).invites[1].route == 2, "pending invite shows the shared route")
		local bad, badReason = Party.share(state, "a", 6)
		assert(not bad and badReason == "invalid_route", "route index bounded")
		assert(Party.remove(state, "a", "b"), "leader removes")
		assert(Party.partyOf(state, "b") == nil, "removed member has no party")
	end,
	["route gates follow authored first-stage definitions and the final ten minutes"] = function()
		local level, rank = Party.gates(Content, 2)
		assert(level == 35 and rank == 4, "route 2 gate from content")
		local ok: any, reason: any =
			Party.routeGate(Content, 2, { level = 34, developmentRank = 4, instabilityAccess = 2 })
		assert(not ok and reason == "level_gate", "level refusal")
		local open: any, why: any =
			Party.routeGate(Content, 2, { level = 35, developmentRank = 4, instabilityAccess = 1 })
		assert(not open and why == "instability_gate", "previous route required")
		assert(Party.routeGate(Content, 2, READY), "ready")
		local expires = Party.window(100, 1800)
		assert(expires == 1800, "window ends at the rotation boundary")
		local late, lateReason = Party.entry(expires, expires - Party.FINAL_ENTRY_SECONDS)
		assert(not late and lateReason == "expiry_imminent", "no entry inside the final ten minutes")
		assert(Party.entry(expires, expires - Party.FINAL_ENTRY_SECONDS - 1), "entry before the last ten minutes")
		local cards = Party.routes(Content, { level = 2, developmentRank = 2, instabilityAccess = 1 }, 0, 1800)
		assert(#cards == 5 and cards[1].ok and not cards[2].ok, "five cards, only route 1 open")
		assert(cards[1].stages == 4 and cards[1].missions == 8 and cards[1].capacity == 8, "card facts")
	end,
}
