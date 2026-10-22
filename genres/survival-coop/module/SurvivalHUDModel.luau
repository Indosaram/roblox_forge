--!strict
local Transport = require("../../../core/infra/genre/CommandTransport")
local Settlement = require("../../../core/domain/settlement/Settlement")
local Job = require("../../../core/domain/crafting/Job")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local M = {}

-- The CoreGui tool hotbar (bottom 70px) wins input over every PlayerGui DisplayOrder.
M.PLACEMENT_BOTTOM = 152

function M.stationTarget(position: any, size: any): any
	return { x = position.x, y = position.y + size.y / 2 + 2, z = position.z }
end

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
			-- A policy ends a handshake failure from a server swap (else the banner stuck all session).
			if model.status == "conflict" and model.reason == "HANDSHAKE_FAILED" then
				model.status, model.reason = if model.pending then "pending" else "ready", nil
			end
		end
		if packet.snapshots and packet.snapshots["survival-coop"] then
			model.snapshot = table.clone(packet.snapshots["survival-coop"])
			model.snapshot.contracts = packet.snapshots.survivalExtensions
				and packet.snapshots.survivalExtensions.contracts
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
		-- Transfer settles in another owner and exposes its phase. A rejected grant is final
		-- (a replay refuses again); keeping it pending locked every HUD action (2026-10-18).
		if
			result.data
			and (
				(result.ok and result.data.status == "confirmed")
				or (not result.ok and result.data.status == "rejected")
			)
		then
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

function M.repairCost(item: any, content: any): number?
	for _, op in content.operations or {} do
		for _, def in if op.kind == "repair" then content.items else {} do
			if def.id == item.catalogId and item.durabilityMilli < Catalog.maxDurability(def, item) then
				return Job.repairCost(op, item.catalogId)
			end
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

function M.missingMaterials(bag: any, inputs: { any }): { any }
	local missing = {}
	for _, ingredient in M.ingredients(bag, { inputs = inputs }) do
		if ingredient.available < ingredient.needed then
			table.insert(missing, ingredient)
		end
	end
	return missing
end

function M.pointerCell(hitX: number, hitZ: number, originX: number, originZ: number, config: any): (number, number)
	return math.clamp(math.floor((hitX - originX) / config.cellStuds), 0, config.width - 1),
		math.clamp(math.floor((hitZ - originZ) / config.cellStuds), 0, config.depth - 1)
end

function M.overPlacementBar(x: number, y: number, p: any, s: any): boolean
	return x >= p.X - 12 and x <= p.X + s.X + 12 and y >= p.Y - 12 and y <= p.Y + s.Y + 12
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

M.STACK_BOTTOM = 180

function M.recipeOrder(
	bag: any,
	recipes: { any },
	stationAvailable: (string) -> boolean,
	items: { any }?,
	filter: any?
): { any }
	local rows = {}
	for _, recipe in recipes do
		local stationReady = recipe.station == nil or stationAvailable(recipe.station)
		local ready, complete, held = stationReady, true, false
		for _, ingredient in M.ingredients(bag, recipe) do
			complete = complete and ingredient.available >= ingredient.needed
			held = held or ingredient.available > 0
		end
		ready = ready and complete
		if recipe.requiredToolTag then
			local tool = false
			for _, row in M.items(bag) do
				for _, definition in (items or {}) :: { any } do
					tool = tool
						or (
							definition.id == row.item.catalogId
							and row.available > 0
							and row.item.durabilityMilli > 0
							and table.find(definition.tags, recipe.requiredToolTag) ~= nil
						)
				end
			end
			ready = ready and tool
		end
		if
			not filter
			or filter.all
			or recipe.id == filter.pin
			or (filter.jobs and filter.jobs[recipe.id])
			or complete
			-- Station recipes surface in range only once an input is held; bare hand recipes never do.
			or (recipe.station ~= nil and stationReady and held)
		then
			table.insert(
				rows,
				{ recipe = recipe, ready = ready, stationReady = stationReady, station = recipe.station or "" }
			)
		end
	end
	table.sort(rows, function(a, b)
		if filter and (a.recipe.id == filter.pin) ~= (b.recipe.id == filter.pin) then
			return a.recipe.id == filter.pin
		end
		if a.station ~= b.station then
			return a.station < b.station
		end
		if a.ready ~= b.ready then
			return a.ready
		end
		return a.recipe.id < b.recipe.id
	end)
	return rows
end

function M.craftPanes(_width: number, height: number): any
	local h = math.max(0, height - 108)
	return { height = h, listHeight = math.floor(h * 0.4) }
end

function M.contextSheetBounds(width: number, height: number, touch: boolean): (number, number, number, number)
	local top = 64
	local bottom = if touch or width < 700 then 128 else 16
	if width < 600 and height > width then
		return width, math.max(44, height - top - 16), top, 0
	end
	return math.min(720, math.max(0, width - 16)), math.max(0, math.min(576, height - top - bottom)), top, 8
end

function M.chatSafe(
	width: number,
	height: number,
	x: number,
	y: number,
	w: number,
	h: number
): (number, number, number, number)
	if width >= 1000 and x < 540 and y < 320 then
		if width - 548 >= w then
			x = 548
		else
			y = 328
		end
		h = math.min(h, height - y - 8)
	end
	return x, y, w, h
end

-- Contextual sheet rect (SurvivalHUD, ExtensionPanels). Short touch landscape (320-430 tall)
-- takes the full height between the thumbstick and the jump button.
M.THUMB_GUTTER = 104
function M.contextSheet(width: number, height: number, touch: boolean): (number, number, number, number)
	if (touch or width < 700) and width > height and height < 480 then
		return M.THUMB_GUTTER, 64, width - 2 * M.THUMB_GUTTER, height - 72
	end
	local w, h, top, right = M.contextSheetBounds(width, height, touch)
	return M.chatSafe(width, height, width - right - w, top, w, h)
end

function M.contextHudBounds(width: number, _height: number?): any
	local w = math.min(216, width - 100)
	return {
		vitals = { x = width - w - 12, y = 64, width = w, height = 76 },
		objective = { x = width - w - 12, y = 144, width = w, height = 28 },
		menu = { x = width - w - 84, y = 64, width = 64, height = 44 },
		biome = { x = (width - 192) / 2, y = 24, width = 192, height = 32 },
		photo = { x = (width - math.min(520, width - 24)) / 2, y = 64, width = math.min(520, width - 24), height = 92 },
	}
end

function M.biomeToast(previous: string, current: string, remaining: number, dt: number): (number, number)
	local left = math.max(0, (if current ~= previous then 3 else remaining) - dt)
	return left, 1 - math.min(1, left)
end

function M.contextActions(policy: any, pending: any, modal: boolean, restTarget: any, attackTarget: any): any
	local function allowed(verb: string): boolean
		return not modal
			and pending == nil
			and policy ~= nil
			and table.find(policy.actions, "survival-coop:" .. verb) ~= nil
	end
	return {
		rest = restTarget ~= nil and allowed("rest"),
		attack = attackTarget ~= nil and allowed("attack"),
		dodge = attackTarget ~= nil and allowed("dodge"),
		guard = attackTarget ~= nil and allowed("guard"),
	}
end

function M.nearestGatherable(nodes: { any }): any
	local best = nil
	for _, node in nodes do
		if node.available and node.reachable ~= false and (best == nil or node.distance < best.distance) then
			best = node
		end
	end
	return best
end

function M.sheetBounds(width: number, height: number, stackWidth: number?): (number, number, number, number)
	local portrait = height > width
	if height < 500 and not portrait and stackWidth then
		local right = stackWidth + 8
		local room = width - right - 8
		return math.max(math.min(240, room), math.min(400, room - 160)), math.max(0, height - 60), 0, right
	end
	local top = if height < 500
		then 0
		elseif portrait then math.max(M.STACK_BOTTOM, math.floor(height * 0.58))
		else M.STACK_BOTTOM
	return math.min(400, width), math.max(0, height - top - 60), top, 0
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
	for _, placement in state.reservations do
		if
			placement.actorId == actor
			and placement.definition.id == definition.id
			and placement.x == x
			and placement.z == z
			and placement.rotation == rotation
		then
			return placement, nil
		end
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
