--!strict
local M = require("./Archipelago")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
-- Other packs do not mount Robango; this spec runs its catalog under Lune.
local Content: any = luau.load(fs.readFile("games/robango-island/src/shared/SurvivalContent.luau"))()
local facts = { level = 60, developmentRank = 10, instabilityAccess = 5 }
local function open(): any
	return assert(
		M.open(Content, {
			id = "trip",
			actor = "owner",
			revision = "v2",
			index = 1,
			seed = 74,
			ttl = 1000,
			entryBuffer = 30,
		}, facts, 0),
		"archipelago invariant"
	)
end
local function receipt(state: any, objective: any): any
	return {
		id = objective.id,
		actor = state.actor,
		expedition = state.id,
		revision = state.revision,
		objective = objective.id,
		action = objective.action,
		target = objective.target,
		quantity = objective.quantity,
	}
end
local function settle(state: any)
	for _, definition in Content.stages :: any do
		if definition.layout == M.layout(state) then
			for _, objective in definition.objectives do
				assert(M.record(state, Content, receipt(state, objective), 10), "archipelago invariant")
			end
		end
	end
end
return {
	["four islands require both server receipts at every departure"] = function()
		local state = open()
		for stage = 1, 4 do
			assert(state.stage == stage, "archipelago invariant")
			local ok, reason = M.advance(state, Content, facts, 10, 30)
			assert(not ok and reason == "mission_gate", "archipelago invariant")
			settle(state)
			assert(M.advance(state, Content, facts, 10, 30), "archipelago invariant")
		end
		assert(state.status == "complete" and state.stage == 4, "archipelago invariant")
		assert(not M.advance(state, Content, facts, 10, 30), "archipelago invariant")
	end,
	["access gates and expiry boundary reject entry"] = function()
		local state = open()
		for key, code in
			{ level = "level_gate", developmentRank = "development_gate", instabilityAccess = "instability_gate" }
		do
			local low = table.clone(facts)
			low[key] = 0
			local ok, reason = M.admit(state, Content, low, 0, 30)
			assert(not ok and reason == code, "archipelago invariant")
		end
		assert(M.admit(state, Content, facts, 969, 30), "archipelago invariant")
		local ok, reason = M.admit(state, Content, facts, 970, 30)
		assert(not ok and reason == "expiry_imminent", "archipelago invariant")
		local expired, expiredReason = M.admit(state, Content, facts, 1000, 0)
		assert(not expired and expiredReason == "route_expired", "archipelago invariant")
	end,
	["foreign stale duplicate and wrong target receipts cannot advance"] = function()
		local state = open()
		local objective = (Content.stages :: any)[1].objectives[1]
		for key, value in
			{
				actor = "intruder",
				expedition = "other",
				revision = "old",
				objective = "rw.a1.s2.craft",
				action = "capture",
				target = "stone",
				quantity = 0,
				id = "",
			}
		do
			local forged = receipt(state, objective)
			forged[key] = value
			assert(not M.record(state, Content, forged, 10), key)
			assert(next(state.progress) == nil, "archipelago invariant")
		end
		local valid = receipt(state, objective)
		assert(M.record(state, Content, valid, 10), "archipelago invariant")
		assert(not M.record(state, Content, valid, 10), "archipelago invariant")
		assert(not M.record(state, Content, valid, 1000), "archipelago invariant")
	end,
	["reconnect preserves delta treatment checkpoints and owned inventory"] = function()
		local state = open()
		settle(state)
		state.delta.wood = 2
		state.treated = true
		state.escortAtStart = false
		state.questCargo = { quantity = 5 }
		local bag = { { id = "pick", durability = 31, quantity = 1 } }
		assert(M.recover(state, 999, "disconnect") == "rw.a1.s1", "archipelago invariant")
		assert(state.treated and state.escortAtStart and state.questCargo.quantity == 5, "archipelago invariant")
		assert(M.recover(state, 1000, "reconnect") == "home", "archipelago invariant")
		assert(state.status == "expired" and state.questCargo == nil, "archipelago invariant")
		assert(state.delta.wood == 2 and state.completed["rw.a1.s1.gather"], "archipelago invariant")
		assert(bag[1].id == "pick" and bag[1].durability == 31 and bag[1].quantity == 1, "archipelago invariant")
		for _, cause in { "fail", "abandon", "return" } do
			local other = open()
			other.questCargo = { quantity = 5 }
			assert(M.recover(other, 0, cause) == "home" and other.questCargo == nil, "archipelago invariant")
			assert(not M.admit(other, Content, facts, 0, 30), "archipelago invariant")
		end
	end,
}
