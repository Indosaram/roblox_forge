--!strict
local Runtime = require("./LateEquipmentRuntime")
local Data = require("../../../core/domain/genre/SerializedData")
local Late = require("../../../core/domain/survival/LateEquipment")
local M = {}

-- equipment-quote {operationId, "preview"|"acknowledge"}: the technical-support quote read from
-- the authored tier row; acknowledge records the level gate in late-equipment state (g18).
function M.actions(): { any }
	local Schema = require("../../../core/infra/net/Schema")
	return {
		{
			id = "equipment-quote",
			args = { Schema.string({ maxLen = 128, pattern = ".+" }), Schema.enum({ "preview", "acknowledge" }) },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
	}
end

local function quote(content: any, aggregate: any, id: string): any?
	local row = Late.operation(content, id)
	if not row or row.kind ~= "support-tier" then
		return nil
	end
	local level = (row.gates or {}).characterLevel or 1
	return {
		id = id,
		tier = row.tier,
		level = level,
		levelMet = (aggregate.tree.level or 1) >= level,
		cost = row.cost or 0,
		inputs = Data.clone(row.inputs),
		effects = Data.clone(row.effects),
		station = row.station,
		seconds = row.seconds,
	}
end

function M.factory(ctx: any): any
	if not ctx.content.progressionPolicy or not ctx.world.lateEquipment then
		return nil
	end
	local ports = ctx.world.lateEquipment
	return {
		id = "late-equipment",
		handles = function(action: string): boolean
			return table.find({
				"survival-coop:equipment-start",
				"survival-coop:equipment-complete",
				"survival-coop:equipment-cancel",
				"survival-coop:equipment-quote",
			}, action) ~= nil
		end,
		command = function(actor: string, action: string, args: any, context: any, _origin: string, admit: any): any
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local port = ctx.personalTransfer(actor)
			if not port then
				return { ok = false, reason = "PERSONAL_UNAVAILABLE" }
			end
			local token = port.profile()
			local envelope = Data.clone(token.data.envelope)
			local slice = envelope.genres["survival-coop"].data
			local aggregate, facts = ports.read(actor, slice, args[1])
			if not aggregate then
				return { ok = false, reason = "PROGRESSION_UNAVAILABLE" }
			end
			if action == "survival-coop:equipment-quote" then
				local row = quote(ctx.content, aggregate, args[1])
				if not row then
					return { ok = false, reason = "UNKNOWN_OPERATION" }
				elseif args[2] == "preview" then
					return { ok = true, data = row }
				end
				local state = Data.clone(aggregate.lateEquipment or Late.new())
				state.acknowledged = state.acknowledged or {}
				state.acknowledged[args[1]] = row.level
				local written = table.clone(aggregate)
				written.lateEquipment = state
				ports.write(slice, written)
				local saved, failed = port.personal:commit(token, token.data.stateRevision, envelope, nil)
				if not saved or failed then
					return { ok = false, reason = failed or "SAVE_FAILED" }
				end
				port.install(saved)
				return { ok = true, data = row }
			end
			local operation = assert(string.match(action, "equipment%-(.+)$"), "INVALID_EQUIPMENT_ACTION")
			local body = if operation == "start"
				then { id = args[1], target = if args[2] ~= "research" then args[2] else nil, slot = args[3] }
				else { jobId = args[1] }
			local receipt = tostring(context.sessionEpoch) .. ":" .. context.requestId
			local nextState, reason = Runtime.apply(ctx.content, aggregate, operation, body, receipt, ctx.now(), facts)
			if not nextState then
				return { ok = false, reason = reason }
			end
			ports.write(slice, nextState)
			local committed, err = port.personal:commit(token, token.data.stateRevision, envelope, nil)
			if not committed or err then
				return { ok = false, reason = err or "SAVE_FAILED" }
			end
			port.install(committed)
			return { ok = true, data = { jobId = if operation == "start" then receipt else args[1] } }
		end,
		snapshot = function(actor: string): (any?, string?)
			local port = ctx.personalTransfer(actor)
			if not port then
				return nil, "PERSONAL_UNAVAILABLE"
			end
			local aggregate = ports.read(actor, port.profile().data.envelope.genres["survival-coop"].data)
			return if aggregate then Data.clone(aggregate.lateEquipment or {}) else nil, nil
		end,
	}
end

return M
