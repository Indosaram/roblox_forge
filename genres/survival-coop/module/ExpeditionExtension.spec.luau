--!strict
local Extension = require("./ExpeditionExtension")
local Contract = require("./Contract")
local Content: any = require("../../../games/robango-island/src/shared/SurvivalContent")
local fs = require("@lune/fs")

local ACTION = Extension.ACTION

local function harness(facts: { [string]: any }, now: number?, onExpedition: boolean?, documents: any?): any
	-- h.away: actors on another server (their document lease is not ours).
	local h: any = { travels = {}, now = now or 0, documents = documents, away = {} }
	h.extension = Extension.new({
		content = Content,
		now = function()
			return h.now
		end,
		facts = function(actor)
			return facts[actor] or { level = 1, developmentRank = 0, instabilityAccess = 1 }
		end,
		document = function(actor)
			return if h.away[actor] then nil else h.documents and h.documents[actor]
		end,
		transaction = function(actor, transform)
			if h.away[actor] then
				return { ok = false, reason = "locked" }
			end
			h.documents = h.documents or {}
			local document = table.clone(h.documents[actor] or {})
			local result = transform(document)
			if result.ok then
				h.documents[actor] = document
			end
			return result
		end,
		layoutId = function()
			return h.layout
		end,
		position = function()
			return h.position
		end,
		online = function(actor)
			return actor ~= "offline" and not h.away[actor]
		end,
		onExpedition = function()
			return onExpedition == true
		end,
		role = function()
			return h.role
		end,
		travel = function(actor: string, destination: string, route: any)
			table.insert(h.travels, actor .. ">" .. destination .. ":" .. tostring(route))
			return { ok = true }
		end,
	})
	h.send = function(actor: string, verb: string, arg: string?): any
		return h.extension.command(actor, ACTION, { verb, arg or "" }, {}, "client", function()
			return { ok = true }
		end)
	end
	return h
end

local READY = { level = 30, developmentRank = 2, instabilityAccess = 1 }

return {
	["party-action is declared, published and handled"] = function()
		assert(table.find(Contract.extensionActions :: { string }, "party-action"), "extension action declared")
		local durable = fs.readFile("games/robango-island/src/shared/GenreDurable.luau")
		assert(string.find(durable, '"survival-coop:party-action"', 1, true), "durable policy publishes it")
		local h = harness({})
		assert(
			h.extension.handles(ACTION) and not h.extension.handles("survival-coop:zone-set"),
			"handles only its own"
		)
		assert(h.send("1", "bogus").reason == "INVALID_VERB", "unknown verb refused")
	end,
	["fxB: off the harbor every open route card says so and a depart is refused before travel"] = function()
		local h = harness({ a = READY })
		h.role = "home"
		local cards = h.extension.snapshot("a").routes
		assert(cards[1].ok == false and cards[1].reason == "transition_not_allowed", "home: route 1 harbor-only")
		local refused = h.send("a", "depart", "1")
		assert(not refused.ok and refused.reason == "transition_not_allowed", tostring(refused.reason))
		assert(#h.travels == 0, "no travel and no trip opened")
		local low = harness({})
		low.role = "home"
		local gated = low.extension.snapshot("x").routes[5]
		assert(gated.reason == "level_gate", "a level lock keeps naming the level")
		h.role = "harbor"
		assert(h.extension.snapshot("a").routes[1].ok, "harbor: route 1 open")
		assert(h.send("a", "depart", "1").ok and #h.travels == 1, "harbor departs")
	end,
	["fxB: untargeted verbs take an empty arg, targeted verbs refuse it"] = function()
		local h = harness({ a = READY })
		assert(h.send("a", "invite", "").reason == "INVALID_TARGET", "invite needs a target")
		assert(h.send("a", "leave", "").reason ~= "INVALID_TARGET", "leave takes none")
		assert(h.send("a", "home", "").reason == "missing_expedition", "home reaches its own check")
	end,
	["depart refuses a gated member and moves the whole ready party leader last"] = function()
		local facts = { a = READY, b = { level = 1, developmentRank = 2, instabilityAccess = 1 }, c = READY }
		local h = harness(facts)
		assert(h.send("a", "invite", "b").ok and h.send("b", "accept", "a").ok, "b joins")
		local refused = h.send("a", "depart", "1")
		assert(not refused.ok and refused.reason == "party_not_ready", "gated member blocks departure")
		assert(#h.travels == 0, "nobody travelled")
		assert(h.send("a", "remove", "b").ok, "leader removes b")
		assert(h.send("a", "invite", "c").ok and h.send("c", "accept", "a").ok, "c joins")
		local member = h.send("c", "depart", "1")
		assert(not member.ok and member.reason == "party_not_leader", "member cannot depart the party")
		local ok = h.send("a", "depart", "1")
		assert(ok.ok and ok.data.members == 2, "party departs")
		assert(h.travels[1] == "c>archipelago:1" and h.travels[2] == "a>archipelago:1", "leader travels last")
	end,
	["depart late in a clock window still departs; refused while already on an expedition"] = function()
		-- Fun-first: the trip runs a full window from departure, so no "next route opens in 9:59".
		local late = harness({ a = READY }, 1800 - 600)
		local departed = late.send("a", "depart", "1")
		assert(departed.ok and late.travels[1] == "a>archipelago:1", "late departure travels at once")
		local away = harness({ a = READY }, 0, true)
		assert(away.send("a", "depart", "1").reason == "expedition_active", "already on an expedition")
		assert(away.send("a", "next").ok and away.travels[1] == "a>next-island:nil", "next island uses travel")
		local home = harness({ a = READY })
		assert(home.send("a", "home").reason == "missing_expedition", "return needs an expedition")
	end,
	["route-invite accept and revoke persist in the owner's route record and keep member gates"] = function()
		local facts = {
			a = { level = 35, developmentRank = 4, instabilityAccess = 2 },
			b = { level = 35, developmentRank = 4, instabilityAccess = 1 },
			c = { level = 1, developmentRank = 0, instabilityAccess = 1 },
		}
		local h = harness(facts)
		assert(h.send("a", "route-invite", "b").ok and h.send("a", "route-invite", "c").ok, "invites")
		local share = h.documents.a.routeShare
		assert(share.route == 2 and share.members.b == "invited", "the owner's open route is shared")
		local low = h.send("c", "route-accept", "a")
		assert(not low.ok and low.reason == "level_gate", "the member's own gate refuses")
		local accepted = h.send("b", "route-accept", "a")
		assert(accepted.ok and accepted.data.status == "member", "b accepts")
		assert(h.extension.snapshot("a").routeShare.members.b == "member", "snapshot shows the roster")
		-- p111: the invited player's snapshot lists the pending share; an accepted one drops out.
		local pending = h.extension.snapshot("c").routeInvites
		assert(#pending == 1 and pending[1].owner == "a" and pending[1].route == 2, "pending invite listed")
		assert(#h.extension.snapshot("b").routeInvites == 0, "accepted share is no longer pending")
		assert(h.send("a", "invite", "b").ok and h.send("b", "accept", "a").ok, "b joins the crew")
		local departed = h.send("a", "depart", "2")
		assert(departed.ok and #h.travels == 2, "shared member departs: " .. tostring(departed.reason))
		assert(h.send("a", "route-revoke", "b").ok and h.documents.a.routeShare.members.b == nil, "revoked")
		assert(h.send("a", "route-revoke", "b").reason == "invite_missing", "revoking twice is refused")
		assert(h.send("b", "route-accept", "a").reason == "invite_missing", "a revoked member cannot accept")
	end,
	["pending route shares live in the invitee's document across a restart or another server"] = function()
		local facts = {
			a = { level = 35, developmentRank = 4, instabilityAccess = 2 },
			b = { level = 35, developmentRank = 4, instabilityAccess = 1 },
		}
		local h = harness(facts)
		assert(h.send("a", "route-invite", "b").ok, "invite")
		assert(h.documents.b.routeInvites.a == 2, "invitee pointer persisted")
		-- A fresh server over the same documents, where the owner is not present.
		local moved = harness(facts, 0, false, h.documents)
		moved.away.a = true
		local pending = moved.extension.snapshot("b").routeInvites
		assert(#pending == 1 and pending[1].owner == "a" and pending[1].route == 2, "listed on another server")
		assert(moved.send("b", "route-accept", "a").reason == "locked", "owner's record stays with its server")
		assert(moved.documents.b.routeInvites.a == 2, "a failed accept keeps the pointer")
		-- Revoke while the invitee is elsewhere leaves a stale pointer; accept settles and clears it.
		h.away.b = true
		assert(h.send("a", "route-revoke", "b").ok, "revoke")
		moved.away.a = nil
		assert(#moved.extension.snapshot("b").routeInvites == 0, "owner here: a revoked share is not listed")
		assert(moved.send("b", "route-accept", "a").reason == "invite_missing", "withdrawn share refused")
		assert(moved.documents.b.routeInvites == nil, "stale pointer cleared")
		-- Same server: accept and revoke both clear the pointer.
		h.away.b = nil
		assert(h.send("a", "route-invite", "b").ok and h.send("b", "route-accept", "a").ok, "accepted")
		assert(h.documents.b.routeInvites == nil, "accept clears")
		assert(h.send("a", "route-revoke", "b").ok and h.send("a", "route-invite", "b").ok, "re-invite")
		assert(h.send("a", "route-revoke", "b").ok and h.documents.b.routeInvites == nil, "revoke clears")
		assert(h.send("a", "route-invite", "a").reason == "party_self", "self invite writes nothing")
		assert(h.documents.a.routeInvites == nil, "no self pointer")
	end,
	["snapshot carries routes party invites tracker hazard and results"] = function()
		local h = harness({ a = READY, b = READY }, 100)
		assert(h.send("a", "invite", "b").ok, "invite")
		assert(h.send("a", "invite", "offline").reason == "player_offline", "offline invite refused")
		local snap = h.extension.snapshot("b")
		assert(#snap.routes == 5 and snap.routes[1].ok, "route cards")
		assert(snap.party.invites[1].from == "a" and snap.party.invites[1].expiresAt == 220, "received invite")
		h.documents = {
			a = {
				archipelago = {
					id = "trip",
					revision = "v2",
					index = 1,
					templateId = "rw.a1",
					stage = 1,
					status = "active",
					expiresAt = 1800,
					completed = { ["rw.a1.s1.gather"] = true },
					progress = { ["rw.a1.s1.gather"] = 5 },
				},
			},
		}
		local tracked = h.extension.snapshot("a")
		assert(#tracked.tracker.objectives == 2 and not tracked.tracker.unlocked, "two objectives, next locked")
		assert(tracked.party.roster[1].leader and tracked.party.roster[1].ready, "roster readiness")
		h.layout, h.position = "rw.a1.s1", { x = -280, y = 4, z = 0 }
		local hazard = h.extension.snapshot("a").hazard
		assert(hazard and hazard.kind == "brambles" and hazard.intensity == 1, "authored hazard under the actor")
		h.layout, h.position = "rw.a5.s1", { x = 300, y = 4, z = 300 }
		local heat = h.extension.snapshot("a").hazard
		assert(heat and heat.volcano and heat.volcano.health == 1 and heat.volcano.fatigue == 2, "volcano exposure")
		h.position = { x = 9999, y = 4, z = 9999 }
		h.layout = "rw.a1.s1"
		assert(h.extension.snapshot("a").hazard == nil, "no hazard outside")
	end,
}
