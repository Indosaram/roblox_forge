--!strict
local Topology = require("../../../core/domain/settlement/Multistorey")
local Data = require("../../../core/domain/genre/SerializedData")
local Ledger = require("../../../core/domain/command/Ledger")
local M = {}

function M.policy(content: any): any
	local home = content.homePolicy
	local building = assert(content.buildingPolicy, "BUILDING_POLICY_REQUIRED")
	return {
		floors = #home.floors,
		baseY = home.dock.y + home.floors[1],
		floorHeight = home.floors[2] - home.floors[1],
		cellStuds = building.cellStuds,
		stairSteps = building.stairSteps,
	}
end

-- exchange(document, consume, grant, receipt) is a pure personal inventory lens.
-- facts is read INSIDE the fenced transform; no cached client permission/position.
function M.new(documents: any, content: any, facts: any, exchange: any): any
	local policy = M.policy(content)
	return {
		command = function(actor: string, request: string, operation: string, body: any): any
			local binding = Ledger.canonical({ operation = operation, body = body })
			return documents.transaction(actor, function(document)
				document.buildOutcomes = document.buildOutcomes or {}
				local known = document.buildOutcomes[request]
				if known then
					return if known.binding == binding
						then Data.clone(known.result)
						else { ok = false, reason = "REQUEST_CONFLICT" }
				end
				local authority = facts(actor, document, operation, body)
				if not authority.allowed then
					return { ok = false, reason = "BUILD_PERMISSION" }
				elseif not authority.inBounds or not authority.reachable then
					return { ok = false, reason = "BUILD_BOUNDARY" }
				end
				local state = document.multistorey or Topology.new()
				local nextState, refusal
				local consume, grant = {}, {}
				if operation == "place" then
					local kit = content.buildingPolicy.kits[body.part.kind]
					if not kit then
						return { ok = false, reason = "UNKNOWN_PART" }
					end
					nextState, refusal = Topology.place(state, policy, body.part, body.version)
					table.insert(consume, { item = kit, quantity = 1 })
				elseif operation == "remove" then
					if authority.occupied then
						return { ok = false, reason = "OCCUPIED_STORAGE" }
					end
					nextState, refusal = Topology.remove(state, body.id, body.version)
					if nextState then
						table.insert(
							grant,
							{ item = content.buildingPolicy.kits[state.parts[body.id].kind], quantity = 1 }
						)
					end
				else
					return { ok = false, reason = "UNKNOWN_OPERATION" }
				end
				if not nextState then
					return { ok = false, reason = refusal }
				end
				local denied = exchange(document, consume, grant, "build:" .. request)
				if denied then
					return { ok = false, reason = denied }
				end
				document.multistorey = nextState
				local result = { ok = true, data = Data.clone(nextState) }
				document.buildOutcomes[request] = { binding = binding, result = result }
				return result
			end)
		end,
		geometry = function(state: any): any
			local boxes = {}
			for _, part in state.parts do
				for _, box in Topology.geometry(policy, part, state) do
					table.insert(boxes, box)
				end
			end
			return boxes
		end,
	}
end

return M
