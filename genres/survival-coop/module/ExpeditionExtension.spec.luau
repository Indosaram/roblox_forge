--!strict
local Extension = require("./ExpeditionExtension")
local Contract = require("./Contract")
local Content: any = require("../../../games/robango-island/src/shared/SurvivalContent")
local fs = require("@lune/fs")

local ACTION = Extension.ACTION

local function harness(facts: { [string]: any }, now: number?, onExpedition: boolean?): any
	local h: any = { travels = {}, now = now or 0 }
	h.extension = Extension.new({
		content = Content,
		now = function()
			return h.now
		end,
		facts = function(actor)
			return facts[actor] or { level = 1, developmentRank = 0, instabilityAccess = 1 }
		end,
		document = function(actor)
			return h.documents and h.documents[actor]
		end,
		layoutId = function()
			return h.layout
		end,
		position = function()
			return h.position
		end,
		online = function(actor)
			return actor ~= "offline"
		end,
		onExpedition = function()
			return onExpedition == true
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

local READY = { level = 2, developmentRank = 2, instabilityAccess = 1 }

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
	["depart refuses inside the final ten minutes and while already on an expedition"] = function()
		local late = harness({ a = READY }, 1800 - 600)
		local refused = late.send("a", "depart", "1")
		assert(not refused.ok and refused.reason == "expiry_imminent", "final ten minutes refused")
		local away = harness({ a = READY }, 0, true)
		assert(away.send("a", "depart", "1").reason == "expedition_active", "already on an expedition")
		assert(away.send("a", "next").ok and away.travels[1] == "a>next-island:nil", "next island uses travel")
		local home = harness({ a = READY })
		assert(home.send("a", "home").reason == "missing_expedition", "return needs an expedition")
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
