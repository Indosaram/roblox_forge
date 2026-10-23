--!strict
-- Server half of the finished expedition screens: travel identity/reconciliation, results
-- ledger + contribution, worn protection, and party travel to one reserved server.
local Extension = require("./ExpeditionExtension")
local Rewards = require("./MissionRewards")
local Bootstrap = require("./IslandBootstrap")
local Party = require("../../../core/domain/island/Party")
-- Host-only spec (Lune): the generated robango content is not mounted in every pack's place.
local _host = require("@lune/process")
local Content: any = require("../../../games/robango-island/src/shared/SurvivalContent")

local READY = { level = 30, developmentRank = 2, instabilityAccess = 1 }

local function harness(onExpedition: boolean): any
	local h: any = { travels = {}, extras = {}, documents = {}, personal = {}, worn = {}, claims = {} }
	h.extension = Extension.new({
		content = Content,
		now = function()
			return 100
		end,
		facts = function()
			return READY
		end,
		document = function(actor)
			return h.documents[actor]
		end,
		personal = function(actor)
			return h.personal[actor]
		end,
		worn = function(actor)
			return h.worn[actor] or {}
		end,
		layoutId = function()
			return h.layout
		end,
		position = function()
			return h.position
		end,
		online = function()
			return true
		end,
		onExpedition = function()
			return onExpedition
		end,
		token = function()
			return "tok"
		end,
		claim = function(actor, id)
			local ok, reason = Rewards.claim(h.documents[actor], id)
			return { ok = ok, reason = reason }
		end,
		travel = function(actor: string, destination: string, _route: any, extra: any)
			table.insert(h.travels, actor .. ">" .. destination)
			h.extras[actor] = extra
			return { ok = true }
		end,
	})
	h.send = function(actor: string, verb: string, arg: string?): any
		return h.extension.command(actor, Extension.ACTION, { verb, arg or "" }, {}, "client", function()
			return { ok = true }
		end)
	end
	return h
end

local function trip(party: any?, progress: number, status: string?): any
	return {
		archipelago = {
			id = "trip",
			revision = "v2",
			index = 1,
			templateId = "rw.a1",
			stage = 2,
			status = status or "active",
			expiresAt = 1800,
			completed = {},
			progress = { ["rw.a1.s2.x"] = progress },
			party = party,
			departure = { items = 5, coins = 40 },
			questCargo = { item = "crate", quantity = 2, slots = 1 },
		},
	}
end

return {
	["depart hands every member one party token and a carried summary"] = function()
		local h = harness(false)
		h.personal.a =
			{ balance = 40, inventory = { bag = { items = { x = { quantity = 3 }, y = { quantity = 2 } } } } }
		assert(h.send("a", "invite", "b").ok and h.send("b", "accept", "a").ok, "b joins")
		assert(h.send("a", "depart", "1").ok, "party departs")
		local a, b = h.extras.a, h.extras.b
		assert(a.party.token == "tok" and b.party.token == "tok", "shared token for every member")
		assert(a.party.leader == "a" and #a.party.members == 2, "leader and crew recorded")
		assert(a.departure.items == 5 and a.departure.coins == 40, "what left is recorded")
		local solo = harness(false)
		assert(solo.send("s", "depart", "1").ok and solo.extras.s.party == nil, "solo travel carries no token")
	end,
	["arrival restores identity crew and reconciles left versus arrived"] = function()
		local crew = { token = "tok", leader = "a", members = { "b", "a" } }
		local h = harness(true)
		h.documents.a, h.documents.b = trip(crew, 3), trip(crew, 1)
		h.personal.b = { balance = 55, inventory = { bag = { items = { x = { quantity = 5 } } } } }
		local snap = h.extension.snapshot("b")
		assert(snap.arrival.id == "trip" and snap.arrival.stage == 2, "restored expedition identity")
		assert(snap.arrival.left.coins == 40 and snap.arrival.arrived.coins == 55, "left and arrived shown")
		assert(snap.party.id == "tok" and snap.party.leader == "b", "crew re-formed; first arrival leads meanwhile")
		assert(h.extension.snapshot("a").party.leader == "a", "leader restored on arrival")
		local joined = h.extension.snapshot("b").party
		assert(#joined.members == 2 and joined.leader == "a", "both members in one party under the leader")
		assert(snap.cargo.item == "crate", "retained cargo published")
		local home = harness(false)
		home.documents.b = trip(crew, 1)
		assert(home.extension.snapshot("b").party.id == nil, "refused: no restore off the expedition server")
	end,
	["results list each crew member's contribution and claim the ledger once"] = function()
		local crew = { token = "tok", leader = "a", members = { "b", "a" } }
		local h = harness(true)
		h.documents.a, h.documents.b = trip(crew, 3, "complete"), trip(crew, 1, "complete")
		Rewards.ledger(h.documents.a, Content)
		local results = h.extension.snapshot("a").results
		assert(results.contributors[1].id == "a" and results.contributors[1].points == 3, "top contributor first")
		assert(results.contributors[2].id == "b", "every crew member listed")
		local row = results.ledger
		assert(row.id == "trip" and row.source == "expedition:rw.a1" and row.claimed == false, "ledger row shape")
		assert(type(row.items) == "table" and row.coins == 0 and row.xp == 0, "ledger totals")
		assert(h.send("a", "claim", "trip").ok, "claim")
		assert(h.documents.a.resultsLedger.trip.claimed, "claimed durably")
		local again = h.send("a", "claim", "trip")
		assert(not again.ok and again.reason == "ledger_claimed", "refused: second claim")
		assert(h.send("a", "claim", "other").reason == "ledger_missing", "refused: unknown entry")
		local doc: any = trip(nil, 0)
		Rewards.ledger(doc, Content)
		assert(doc.resultsLedger == nil, "an active expedition writes no ledger row")
	end,
	["hazard counts only worn protection and follows the current zone"] = function()
		local h = harness(true)
		h.layout, h.position = "rw.a5.s1", { x = 300, y = 4, z = 300 }
		local bare = h.extension.snapshot("a").hazard
		assert(bare.volcano.health == 1 and bare.boots == false, "refused: owned-but-unworn boots do not protect")
		h.worn.a = { "lava-protection-boots" }
		local shod = h.extension.snapshot("a").hazard
		assert(shod.boots and shod.volcano.health == 0.5 and shod.volcano.fatigue == 1, "worn boots halve heat")
		assert(shod.layout == "rw.a5.s1", "banner tagged with the current zone")
		local worn = Extension.worn(Content, { "cold-shoes", "cold-top", "temperate-bag" })
		assert(worn.cold == 5 and worn.heat == 1 and not worn.boots, "worn climate resistance sums")
		h.layout = "rw.a1.s1"
		assert(h.extension.snapshot("a").hazard == nil, "leaving the zone clears the banner")
	end,
	["party members departing together share one reserved server"] = function()
		local reserved, teleports = 0, {}
		local env: any = {
			roles = { harbor = 1, home = 2, archipelago = 3, frontier60 = 4 },
			placeId = 1,
			privateServerId = "",
			isStudio = false,
			players = {},
			facts = function()
				return { level = 60 }
			end,
			admitExpedition = function()
				return true
			end,
			now = function()
				return 10
			end,
			prepareHandoff = function()
				return { ok = true }
			end,
			resumeHandoff = function()
				return { ok = true }
			end,
			completeHandoff = function()
				return { ok = true }
			end,
			newTeleportOptions = function()
				return {}
			end,
			teleportService = {
				ReserveServerAsync = function(_self, id: number)
					reserved += 1
					return "code-" .. id .. "-" .. reserved
				end,
				TeleportAsync = function(_self, _id, players, options)
					teleports[players[1].UserId] = options.ReservedServerAccessCode or "public"
				end,
			},
		}
		local routing = Bootstrap.start(env)
		local moved, why = routing.travel({ UserId = 1 }, "archipelago", "tok:1")
		assert(moved, "member travels: " .. tostring(why))
		assert(routing.travel({ UserId = 2 }, "archipelago", "tok:1"), "leader travels")
		assert(reserved == 1 and teleports[1] == teleports[2] and teleports[1] == "code-3-1", "same reserved server")
		assert(routing.travel({ UserId = 3 }, "archipelago"), "solo travel")
		assert(teleports[3] == "public", "solo travel is not routed to the party server")
		env.teleportService.ReserveServerAsync = function()
			error("quota")
		end
		local failed = Bootstrap.start(env)
		local ok, reason = failed.travel({ UserId = 4 }, "archipelago", "tok:2")
		assert(not ok and reason == "party_reservation_failed" and teleports[4] == nil, "refused: reservation failure")
		assert(Party.restore(Party.new(), "t", "a", "a"), "restore creates a crew")
	end,
}
