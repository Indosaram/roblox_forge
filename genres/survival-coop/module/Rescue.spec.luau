--!strict
local Rescue = require("./Rescue")

local HERE = { x = 0, y = 0, z = 0 }
local NEAR = { x = 6, y = 0, z = 0 }
local FAR = { x = 40, y = 0, z = 0 }

local function flaring(now: number?): any
	local state = Rescue.new()
	local ok, reason = Rescue.choose(state, "1", "rescue", true, false, HERE, now or 1000)
	assert(ok and reason == nil, "flare sent: " .. tostring(reason))
	return state
end

return {
	["wild roles offer three options and safe roles only get-up"] = function()
		local wild = Rescue.options(false)
		assert(#wild == 3 and wild[1] == "rift" and wild[2] == "camp" and wild[3] == "rescue", "three wild options")
		local safe = Rescue.options(true)
		assert(#safe == 1 and safe[1] == "get-up", "one safe option")
		local state = Rescue.new()
		assert(select(2, Rescue.choose(state, "1", "rift", true, true, HERE, 0)) == "INVALID_OPTION", "no rift in town")
		assert(
			select(2, Rescue.choose(state, "1", "get-up", true, false, HERE, 0)) == "INVALID_OPTION",
			"no get-up in the wild"
		)
		assert(select(2, Rescue.choose(state, "1", "fly", true, false, HERE, 0)) == "INVALID_OPTION", "unknown option")
	end,
	["a choice needs the actor down and a flare needs a position"] = function()
		local state = Rescue.new()
		assert(select(2, Rescue.choose(state, "1", "rift", false, false, HERE, 0)) == "NOT_DOWN", "alive cannot choose")
		local bad: { any } = { nil, { x = 0 / 0, y = 0, z = 0 }, { x = 1 } }
		for index = 1, 3 do
			local ok, reason = Rescue.choose(state, "1", "rescue", true, false, bad[index], 0)
			assert(not ok and reason == "POSITION_UNAVAILABLE", "bad position " .. index)
		end
		assert(next(state.requests) == nil, "no request recorded")
	end,
	["the world holds while undecided and wakes the chosen way"] = function()
		local state = Rescue.new()
		assert(Rescue.decide(state, "1", 0, false) == nil, "undecided holds")
		assert(Rescue.choose(state, "1", "camp", true, false, HERE, 10), "camp chosen")
		local choice = Rescue.decide(state, "1", 20, false)
		assert(choice and choice.option == "camp", "camp decided")
		Rescue.settle(state, "1")
		assert(next(state.choices) == nil and next(state.downAt) == nil, "settled clears records")
	end,
	["an idle actor wakes the default way after idleMillis"] = function()
		local state = Rescue.new()
		assert(Rescue.decide(state, "1", 0, false) == nil, "starts the idle clock")
		assert(Rescue.decide(state, "1", Rescue.POLICY.idleMillis - 1, false) == nil, "still holding")
		local wild = Rescue.decide(state, "1", Rescue.POLICY.idleMillis, false)
		assert(wild and wild.option == "rift", "idle wild wakes at the rift")
		local town = Rescue.new()
		Rescue.decide(town, "2", 0, true)
		local safe = Rescue.decide(town, "2", Rescue.POLICY.idleMillis, true)
		assert(safe and safe.option == "get-up", "idle safe gets up")
	end,
	["a nearby living rescuer revives the flaring actor where it fell"] = function()
		local state = flaring()
		assert(Rescue.decide(state, "1", 2000, false) == nil, "a flare holds the actor down")
		assert(Rescue.waiting(state, "1", 2000) == Rescue.POLICY.windowMillis - 1000, "countdown")
		local ok, reason = Rescue.revive(state, "2", "1", NEAR, true, true, 5000)
		assert(ok and reason == nil, "revived: " .. tostring(reason))
		local choice = Rescue.decide(state, "1", 5000, false)
		assert(
			choice and choice.option == "revive" and choice.position and choice.position.x == 0,
			"wakes at the flare"
		)
		assert(state.requests["1"] == nil, "request consumed")
		local again, twice = Rescue.revive(state, "3", "1", NEAR, true, true, 5001)
		assert(not again and twice == "NO_REQUEST", "a flare is answered once")
		assert(
			select(2, Rescue.choose(state, "1", "rift", true, false, HERE, 5002)) == "ALREADY_REVIVED",
			"revive sticks"
		)
	end,
	["NEGATIVE: a far rescuer is refused and the flare stays up"] = function()
		local state = flaring()
		local ok, reason = Rescue.revive(state, "2", "1", FAR, true, true, 2000)
		assert(not ok and reason == "TOO_FAR", "far refused: " .. tostring(reason))
		local edge = Rescue.POLICY.reviveStuds
		assert(
			select(2, Rescue.revive(state, "2", "1", { x = edge + 0.01, y = 0, z = 0 }, true, true, 2000)) == "TOO_FAR",
			"just outside reach refused"
		)
		assert(state.requests["1"] ~= nil, "flare still live")
		assert(
			Rescue.revive(state, "2", "1", { x = edge, y = 0, z = 0 }, true, true, 2000),
			"exactly at reach accepted"
		)
	end,
	["NEGATIVE: an expired request is refused and the actor picks again"] = function()
		local state = flaring(1000)
		local expiry = 1000 + Rescue.POLICY.windowMillis
		local ok, reason = Rescue.revive(state, "2", "1", NEAR, true, true, expiry)
		assert(not ok and reason == "REQUEST_EXPIRED", "expired refused: " .. tostring(reason))
		assert(state.requests["1"] == nil and state.choices["1"] == nil, "flare and choice cleared")
		assert(Rescue.waiting(state, "1", expiry) == 0, "no countdown left")
		assert(Rescue.choose(state, "1", "rift", true, false, HERE, expiry + 1), "picks again after expiry")
	end,
	["NEGATIVE: downed, self and stale rescues are refused"] = function()
		local state = flaring()
		assert(select(2, Rescue.revive(state, "2", "1", NEAR, false, true, 2000)) == "RESCUER_DOWN", "downed rescuer")
		assert(select(2, Rescue.revive(state, "1", "1", HERE, true, true, 2000)) == "SELF_RESCUE", "self rescue")
		assert(select(2, Rescue.revive(state, "2", "9", NEAR, true, true, 2000)) == "NO_REQUEST", "no flare")
		assert(
			select(2, Rescue.revive(state, "2", "1", nil, true, true, 2000)) == "POSITION_UNAVAILABLE",
			"no rescuer body"
		)
		assert(select(2, Rescue.revive(state, "2", "1", NEAR, true, false, 2000)) == "NOT_DOWN", "target already up")
		assert(state.requests["1"] == nil, "a stale flare is dropped")
	end,
	["flares list live requests in range nearest first and never the viewer's own"] = function()
		local state = Rescue.new()
		assert(Rescue.choose(state, "1", "rescue", true, false, { x = 30, y = 0, z = 0 }, 0), "far flare")
		assert(Rescue.choose(state, "2", "rescue", true, false, { x = 5, y = 0, z = 0 }, 0), "near flare")
		assert(Rescue.choose(state, "3", "rescue", true, false, { x = 500, y = 0, z = 0 }, 0), "out of range flare")
		local list = Rescue.flares(state, "1", HERE, 100)
		assert(#list == 1 and list[1].id == "2", "own flare hidden, out of range hidden")
		local other = Rescue.flares(state, "9", HERE, 100)
		assert(#other == 2 and other[1].id == "2" and other[2].id == "1", "nearest first")
		assert(#Rescue.flares(state, "9", HERE, Rescue.POLICY.windowMillis) == 0, "expired flares hidden")
	end,
	["a repeated flare keeps its original window"] = function()
		local state = flaring(1000)
		assert(Rescue.choose(state, "1", "rescue", true, false, NEAR, 50000), "flare again")
		assert(state.requests["1"].expiresMillis == 1000 + Rescue.POLICY.windowMillis, "window not extended")
		assert(state.requests["1"].position.x == 0, "position unchanged")
		assert(Rescue.choose(state, "1", "rift", true, false, HERE, 50001), "give up for the rift")
		assert(state.requests["1"] == nil, "flare withdrawn")
	end,
	["invalid policies are rejected"] = function()
		for _, policy in
			{
				{ windowMillis = 0, reviveStuds = 10, flareStuds = 200, idleMillis = 1 },
				{ windowMillis = 1, reviveStuds = 0, flareStuds = 200, idleMillis = 1 },
				{ windowMillis = 1, reviveStuds = 10, flareStuds = 5, idleMillis = 1 },
				{ windowMillis = 1, reviveStuds = 10, flareStuds = 200, idleMillis = 0 },
			}
		do
			assert(not pcall(Rescue.new, policy), "rejected")
		end
	end,
}
