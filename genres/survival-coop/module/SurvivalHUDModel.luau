--!strict
-- Presentation state only. All mutations go through the existing command ingress.
local Transport = require("../../../core/infra/genre/CommandTransport")
local Settlement = require("../../../core/domain/settlement/Settlement")
local M = {}

function M.new(actor: string, newId: () -> string): any
	local model: any = {
		actor = actor,
		snapshot = {},
		durable = nil,
		revision = -1,
		pending = nil,
		busy = false,
		status = "loading",
		reason = nil,
	}
	function model.receive(packet: any): boolean
		if packet.revision and packet.revision < model.revision then
			return false
		end
		if packet.durable then
			model.durable = packet.durable
		end
		if packet.snapshots and packet.snapshots["survival-coop"] then
			model.snapshot = table.clone(packet.snapshots["survival-coop"])
			local shared = packet.snapshots.survivalSettlement
			if shared then
				model.snapshot.settlement, model.snapshot.warehouse = shared.settlement, shared.warehouse
			end
			model.revision = packet.revision or model.revision
			if model.status == "loading" then
				model.status = "ready"
			end
		end
		return true
	end
	function model.begin(verb: string, args: { any }): any
		if model.busy or model.pending then
			return nil
		end
		local action = "survival-coop:" .. verb
		local policy = model.durable
		local epoch = if policy and policy.epochs
			then policy.epochs[action]
			else if policy then policy.sessionEpoch else nil
		if not Transport.durable(policy, action) or type(epoch) ~= "number" then
			model.status, model.reason = "conflict", "HANDSHAKE_FAILED"
			return nil
		end
		local request = Transport.request(nil, action, args, epoch, newId)
		table.freeze(request.args)
		table.freeze(request)
		model.pending, model.busy, model.status, model.reason = request, true, "pending", nil
		return request
	end
	function model.retry(): any
		if model.busy or not model.pending then
			return nil
		end
		model.busy, model.status = true, "pending"
		return model.pending
	end
	function model.finish(ok: boolean, result: any)
		model.busy = false
		if not ok or type(result) ~= "table" then
			model.status, model.reason = "pending", "TRANSPORT_FAILED"
			return
		end
		model.pending = Transport.settle(model.pending, result)
		-- Transfer completes in another durable owner and exposes its phase instead.
		if result.ok and result.data and result.data.status == "confirmed" then
			model.pending = nil
		end
		model.reason = result.reason
		if result.ok and result.data and result.data.notificationError then
			model.reason = "SETTLEMENT_PUBLICATION_FAILED"
		end
		model.status = if model.pending then "pending" elseif result.ok then "confirmed" else "conflict"
		if result.reason == "REQUEST_EXPIRED" then
			model.durable = nil
		end
	end
	return model
end

function M.bag(snapshot: any): any
	for _, bag in snapshot.inventory or {} do
		if bag.kind == "carried" then
			return bag
		end
	end
	return nil
end

function M.items(bag: any): { any }
	local rows = {}
	if not bag then
		return rows
	end
	for id, item in bag.items do
		local reserved = 0
		for _, amounts in bag.reservations do
			reserved += amounts[id] or 0
		end
		table.insert(rows, { item = item, reserved = reserved, available = item.quantity - reserved })
	end
	table.sort(rows, function(a, b)
		return a.item.itemId < b.item.itemId
	end)
	return rows
end

function M.jobs(snapshot: any, actor: string): { any }
	local rows = {}
	local workshop = snapshot.workshop
	if workshop and workshop.actorId == actor then
		for id, entry in workshop.entries do
			if entry.job.state ~= "Committed" and entry.job.state ~= "Cancelled" then
				table.insert(rows, { id = id, job = entry.job })
			end
		end
	end
	table.sort(rows, function(a, b)
		return a.id < b.id
	end)
	return rows
end

function M.ingredients(bag: any, recipe: any): { any }
	local rows = {}
	for _, input in recipe.inputs do
		local available = 0
		for _, row in M.items(bag) do
			if row.item.catalogId == input.item then
				available += row.available
			end
		end
		table.insert(rows, { id = input.item, needed = input.quantity, available = available })
	end
	return rows
end

function M.placements(settlement: any, actor: string): { any }
	local rows = {}
	for id, placement in settlement.reservations do
		if placement.actorId == actor then
			table.insert(rows, { id = id, placement = placement })
		end
	end
	table.sort(rows, function(a, b)
		return a.id < b.id
	end)
	return rows
end

-- The HUD's top-right stack ends here: vitals 0..36, tabs 40..88, status 92..128 and
-- the rest control 132..180. A sheet whose top starts any higher overlaps the last
-- control, which the capture geometry contract rejects, so the sheet never starts
-- above this line.
M.STACK_BOTTOM = 180

function M.sheetBounds(width: number, height: number): (number, number, number)
	local portrait = height > width
	local top = if height < 500
		then 0
		elseif portrait then math.max(M.STACK_BOTTOM, math.floor(height * 0.58))
		else M.STACK_BOTTOM
	return math.min(400, width), math.max(0, height - top - 60), top
end

function M.buildArgs(snapshot: any, definition: any, x: number, z: number, rotation: number): ({ any }?, string?)
	local state, warehouse = snapshot.settlement, snapshot.warehouse
	if not state or not warehouse then
		return nil, "SETTLEMENT_UNAVAILABLE"
	end
	return { definition.id, x, z, rotation, state.version, warehouse.version, state.membershipRevision }, nil
end

function M.preview(
	snapshot: any,
	actor: string,
	definition: any,
	x: number,
	z: number,
	rotation: number
): (any, string?)
	local state = snapshot.settlement
	if not state then
		return nil, "SETTLEMENT_UNAVAILABLE"
	end
	-- Reuse authoritative pure footprint/entry rules, without publishing the candidate.
	local id = "hud-preview"
	while state.usedIds[id] do
		id ..= "-"
	end
	local candidate, reason = Settlement.reserve(
		state,
		actor,
		state.version,
		state.membershipRevision,
		{ id = id, definition = definition, x = x, z = z, rotation = rotation }
	)
	return if candidate then candidate.reservations[id] else nil, reason
end

function M.capacity(bag: any): (number, number, number, number)
	local count = 0
	for _ in bag.items do
		count += 1
	end
	return count, bag.limits.slots, bag.weightMilli or 0, bag.limits.hardWeightMilli
end

return M
