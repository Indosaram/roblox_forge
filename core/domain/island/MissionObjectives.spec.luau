--!strict
local Missions = require("./MissionObjectives")
local Archipelago = require("./Archipelago")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Content: any = luau.load(fs.readFile("games/robango-island/src/shared/SurvivalContent.luau"))()
local function open(stage: number): any
	local state = assert(
		Archipelago.open(
			Content,
			{ id = "trip", actor = "owner", revision = "v2", index = 1, seed = 12, ttl = 1000, entryBuffer = 30 },
			{ level = 60, developmentRank = 10, instabilityAccess = 5 },
			0
		)
	)
	state.stage = stage
	return state
end
local function anchors(state)
	for _, layout in Content.layouts do
		if layout.id == Archipelago.layout(state) then
			local result = {}
			for _, row in layout.anchors do
				result[row.id] = row.position
			end
			return result
		end
	end
	error("layout")
end
return {
	["survey requires a continuous two second hold and distinct server markers"] = function()
		local state = open(1)
		local layout: any = nil
		for _, row in Content.layouts do
			layout = if row.id == Archipelago.layout(state) then row else layout
		end
		local position = require("./ArchipelagoTerrain").survey(layout, 1)
		local marker = "rw.a1.s1.survey.1"
		assert(not Missions.apply(state, Content, "survey-start", "foreign", position, 1), "foreign marker refused")
		assert(Missions.apply(state, Content, "survey-start", marker, position, 1))
		Missions.tick(state, Content, position, 2)
		assert(not state.completed["rw.a1.s1.survey"], "early hold cannot complete")
		Missions.tick(state, Content, { x = position.x + 9, y = position.y, z = position.z }, 2)
		Missions.tick(state, Content, position, 3)
		assert(not state.completed["rw.a1.s1.survey"] and state.surveyHold == nil, "leaving range cancels hold")
		assert(Missions.apply(state, Content, "survey-start", marker, position, 4))
		Missions.tick(state, Content, position, 6)
		assert(state.completed["rw.a1.s1.survey"], "continuous hold completes")
		assert(not Missions.apply(state, Content, "survey-start", marker, position, 7), "marker cannot repeat")
	end,
	["escort is speed bounded stops out of range and cannot complete on treatment"] = function()
		local state = open(2)
		local origin = anchors(state).objective
		local offset = Content.missionPolicy.bandageOffset
		local ok, reason = Missions.apply(state, Content, "rescue-treat", "", origin, 1)
		assert(not ok and reason == "BANDAGE_REQUIRED", "treatment requires bandage")
		assert(
			Missions.apply(
				state,
				Content,
				"bandage-claim",
				"",
				{ x = origin.x + offset.x, y = origin.y + offset.y, z = origin.z + offset.z },
				1
			)
		)
		assert(Missions.apply(state, Content, "rescue-treat", "", origin, 1))
		assert(
			state.bandage == 0 and state.treated and not state.completed["rw.a1.s2.rescue"],
			"treatment consumes reserve"
		)
		Missions.tick(state, Content, { x = origin.x - 24, y = origin.y, z = origin.z }, 2)
		assert(math.abs(state.escort.position.x - origin.x) == 10, "speed ten per second")
		local before = state.escort.position.x
		Missions.tick(state, Content, { x = origin.x - 100, y = origin.y, z = origin.z }, 20)
		assert(state.escort.position.x == before, "far actor stops escort")
		Archipelago.recover(state, 21, "disconnect")
		assert(state.treated and state.bandage == 0 and state.escort == nil, "disconnect preserves treatment")
	end,
	["escort completes when the castaway keeps up with the player standing at the entry"] = function()
		local state = open(2)
		local points = anchors(state)
		local origin, entry = points.objective, points.entry
		local offset = Content.missionPolicy.bandageOffset
		assert(
			Missions.apply(
				state,
				Content,
				"bandage-claim",
				"",
				{ x = origin.x + offset.x, y = origin.y + offset.y, z = origin.z + offset.z },
				1
			)
		)
		assert(Missions.apply(state, Content, "rescue-treat", "", origin, 1))
		-- Walk the player from the objective toward the entry in short legs and stop 1.6 studs short of
		-- it on the approach (as journey6h did); the castaway trails followStuds behind.
		local now = 1
		local dx, dy, dz = entry.x - origin.x, entry.y - origin.y, entry.z - origin.z
		local length = math.sqrt(dx * dx + dy * dy + dz * dz)
		local stopAt = (length - 1.6) / length
		local legs = math.ceil(length / 4)
		for leg = 1, legs do
			now += 1
			local f = stopAt * leg / legs
			Missions.tick(state, Content, { x = origin.x + dx * f, y = origin.y + dy * f, z = origin.z + dz * f }, now)
		end
		local stand = { x = origin.x + dx * stopAt, y = origin.y + dy * stopAt, z = origin.z + dz * stopAt }
		for _ = 1, 4 do
			now += 1
			Missions.tick(state, Content, stand, now)
		end
		local trail = math.sqrt(
			(state.escort.position.x - entry.x) ^ 2
				+ (state.escort.position.y - entry.y) ^ 2
				+ (state.escort.position.z - entry.z) ^ 2
		)
		assert(trail > Content.missionPolicy.followStuds, "the castaway trails short of the entry: " .. trail)
		assert(state.completed["rw.a1.s2.rescue"], "escort completes with the player on the entry")
	end,
	["escort does not complete when the player reaches the entry without the castaway"] = function()
		local state = open(2)
		local points = anchors(state)
		local origin, entry = points.objective, points.entry
		local offset = Content.missionPolicy.bandageOffset
		assert(
			Missions.apply(
				state,
				Content,
				"bandage-claim",
				"",
				{ x = origin.x + offset.x, y = origin.y + offset.y, z = origin.z + offset.z },
				1
			)
		)
		assert(Missions.apply(state, Content, "rescue-treat", "", origin, 1))
		Missions.tick(state, Content, entry, 1)
		Missions.tick(state, Content, entry, 1)
		assert(not state.completed["rw.a1.s2.rescue"], "the castaway is still at the objective")
	end,
	["cargo has one complete separate slot and expiry clears only unsettled cargo"] = function()
		local state = open(3)
		local points = anchors(state)
		assert(not Missions.apply(state, Content, "cargo-deliver", "", points.objective, 1), "missing cargo refused")
		assert(Missions.apply(state, Content, "cargo-claim", "", points.resources, 2))
		assert(state.questCargo.slots == 1 and state.questCargo.quantity == 5, "complete bundle in separate slot")
		assert(not Missions.apply(state, Content, "cargo-claim", "", points.resources, 3), "slot cannot double claim")
		state.questCargo.quantity = 4
		assert(not Missions.apply(state, Content, "cargo-deliver", "", points.objective, 4), "partial bundle refused")
		state.questCargo.quantity = 5
		assert(Missions.apply(state, Content, "cargo-deliver", "", points.objective, 5))
		assert(state.questCargo == nil and state.completed["rw.a1.s3.transport"], "delivery consumes bundle")
		assert(not Missions.apply(state, Content, "cargo-deliver", "", points.objective, 6), "delivery cannot repeat")
		Archipelago.recover(state, 1000, "reconnect")
		assert(state.completed["rw.a1.s3.transport"], "expiry preserves checkpoint")
	end,
}
