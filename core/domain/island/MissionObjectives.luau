--!strict
-- Mission-only reserves never enter the tradeable bag. Positions and clocks
-- are supplied by the authoritative world; remote arguments name an operation.
local Archipelago = require("./Archipelago")
local Terrain = require("./ArchipelagoTerrain")
local M = {}
local function copy(point: any): any
	return { x = point.x, y = point.y, z = point.z }
end
local function distance(a: any, b: any): number
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end
local function definition(state: any, content: any, action: string): any
	for _, stage in content.stages do
		if stage.layout == Archipelago.layout(state) then
			for _, objective in stage.objectives do
				if objective.action == action then
					return objective
				end
			end
		end
	end
	return nil
end
local function geometry(state: any, content: any): any
	for _, layout in content.layouts do
		if layout.id == Archipelago.layout(state) then
			local anchors = {}
			for _, anchor in layout.anchors do
				anchors[anchor.id] = anchor.position
			end
			return anchors
		end
	end
	return nil
end
local function layoutOf(state: any, content: any): any
	for _, layout in content.layouts do
		if layout.id == Archipelago.layout(state) then
			return layout
		end
	end
	return nil
end
local function receipt(state: any, objective: any, suffix: string): any
	return {
		id = state.id .. ":" .. objective.id .. ":" .. suffix,
		actor = state.actor,
		expedition = state.id,
		revision = state.revision,
		objective = objective.id,
		action = objective.action,
		target = objective.target,
		quantity = objective.quantity,
	}
end

function M.apply(
	state: any,
	content: any,
	operation: string,
	target: string,
	position: any,
	now: number
): (boolean, string?)
	if now >= state.expiresAt then
		return false, "route_expired"
	end
	if state.status ~= "active" or not position then
		return false, "expedition_inactive"
	end
	local policy = content.missionPolicy
	local anchors = geometry(state, content)
	local near = function(point)
		return distance(point, position) <= policy.interactionStuds
	end
	if operation == "survey-start" then
		local objective = definition(state, content, "survey")
		if not objective then
			return false, "objective_mismatch"
		end
		local marker: any = nil
		for index = 1, objective.quantity do
			if target == objective.id .. "." .. tostring(index) then
				marker = Terrain.survey(layoutOf(state, content), index)
			end
		end
		if not marker or not near(marker) then
			return false, "OUT_OF_RANGE"
		end
		if state.receipts[state.id .. ":survey:" .. target] then
			return false, "duplicate_receipt"
		end
		state.surveyHold = { marker = target, position = marker, startedAt = now, objective = objective }
		return true, nil
	elseif operation == "bandage-claim" or operation == "rescue-treat" then
		local objective = definition(state, content, "rescue")
		if not objective or state.completed[objective.id] then
			return false, "objective_mismatch"
		end
		if operation == "bandage-claim" then
			local origin, offset = anchors.objective, policy.bandageOffset
			if not near({ x = origin.x + offset.x, y = origin.y + offset.y, z = origin.z + offset.z }) then
				return false, "OUT_OF_RANGE"
			end
			if state.bandageClaimed then
				return false, "already_claimed"
			end
			state.bandageClaimed, state.bandage = true, 1
		else
			if not near(anchors.objective) then
				return false, "OUT_OF_RANGE"
			end
			if state.treated then
				return false, "already_treated"
			end
			if state.bandage ~= 1 then
				return false, "BANDAGE_REQUIRED"
			end
			state.bandage, state.treated = 0, true
			state.escort = { position = copy(anchors.objective), lastAt = now }
		end
		return true, nil
	elseif operation == "cargo-claim" or operation == "cargo-deliver" then
		local objective = definition(state, content, "transport")
		if not objective or state.completed[objective.id] then
			return false, "objective_mismatch"
		end
		if operation == "cargo-claim" then
			if not near(anchors.resources) then
				return false, "OUT_OF_RANGE"
			end
			if state.questCargo or state.cargoClaimed then
				return false, "MISSION_SLOT_FULL"
			end
			state.cargoClaimed = true
			state.questCargo = { item = objective.target, quantity = objective.quantity, slots = policy.cargoSlots }
		else
			if not near(anchors.objective) then
				return false, "OUT_OF_RANGE"
			end
			if
				not state.questCargo
				or state.questCargo.quantity ~= objective.quantity
				or state.questCargo.item ~= objective.target
			then
				return false, "COMPLETE_CARGO_REQUIRED"
			end
			local ok, reason = Archipelago.record(state, content, receipt(state, objective, "cargo"), now)
			if not ok then
				return false, reason
			end
			state.questCargo = nil
		end
		return true, nil
	end
	return false, "UNKNOWN_ACTION"
end

function M.tick(state: any, content: any, position: any, now: number): boolean
	if state.status ~= "active" or now >= state.expiresAt or not position then
		state.surveyHold = nil
		return false
	end
	local changed = false
	local policy = content.missionPolicy
	local hold = state.surveyHold
	if hold then
		if distance(hold.position, position) > policy.interactionStuds then
			state.surveyHold = nil
			changed = true
		elseif now - hold.startedAt >= policy.surveySeconds then
			local event = receipt(state, hold.objective, "unused")
			event.id, event.quantity = state.id .. ":survey:" .. hold.marker, 1
			Archipelago.record(state, content, event, now)
			state.surveyHold = nil
			changed = true
		end
	end
	local objective = definition(state, content, "rescue")
	if objective and state.treated and not state.completed[objective.id] then
		local anchors = geometry(state, content)
		local escort = state.escort or { position = copy(anchors.objective), lastAt = now }
		local length = distance(escort.position, position)
		local step =
			math.min(math.max(0, now - escort.lastAt) * policy.escortSpeed, math.max(0, length - policy.followStuds))
		if length <= policy.stopStuds and step > 0 then
			for _, axis in { "x", "y", "z" } do
				escort.position[axis] += (position[axis] - escort.position[axis]) * step / length
			end
			state.escortAtStart = false
		end
		escort.lastAt, state.escort = now, escort
		if
			distance(escort.position, anchors.entry) <= policy.followStuds
			and distance(position, anchors.entry) <= policy.interactionStuds
		then
			Archipelago.record(state, content, receipt(state, objective, "arrival"), now)
		end
		changed = true
	end
	return changed
end
return M
