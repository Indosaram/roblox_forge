--!strict
-- operation-run: executes content operations of an executable kind (practice, instrument) on the
-- personal slice in one atomic write. Gates (character level, skill nodes) come from the
-- operation row, the station from the server spatial port, never from the client. Inputs are
-- consumed, outputs added, and every skill category whose entryActions name the operation (or
-- whose nodes gate it) is awarded once per command receipt.
local Shared = require("../../../core/domain/genre/Contract")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Job = require("../../../core/domain/crafting/Job")
local Tree = require("../../../core/domain/progression/SkillTree")
local Data = require("../../../core/domain/genre/SerializedData")

local M = {}
M.RUN = "survival-coop:operation-run"
-- Operation kinds this executor runs. contentgraph requires every entry action that names an
-- operation to name one of these kinds.
M.KINDS = table.freeze({ practice = true, instrument = true }) :: { [string]: boolean }
local GENRE = "survival-coop"

function M.actions(): { any }
	local Schema = require("../../../core/infra/net/Schema")
	local id = Schema.string({ maxLen = 128, pattern = ".+" })
	return {
		{ id = "operation-run", args = { id, id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
	}
end

--- Executable operation rows in content order.
function M.operations(content: any): { any }
	local rows = {}
	for _, row in content.operations or {} do
		if M.KINDS[row.kind] then
			table.insert(rows, row)
		end
	end
	return rows
end

local function find(content: any, id: any): any
	for _, row in M.operations(content) do
		if row.id == id then
			return row
		end
	end
	return nil
end

-- A tiered station key "station.<kind>.tN" serving `row`, reachable for `actor`.
local function stationReady(ctx: any, actor: string, row: any, key: any): boolean
	if not row.station then
		return true
	end
	local tier = if type(key) == "string" then tonumber(string.match(key, "^station%.[^.]+%.t(%d+)$")) else nil
	local spatial = ctx.world and ctx.world.services and ctx.world.services.survivalSpatial
	if not tier or tier < (row.stationTier or 1) or not spatial or not spatial.station then
		return false
	end
	local found = spatial.station(actor, key)
	return found ~= nil and found.kind == row.station and found.reachable == true
end

-- Debits `quantity` units of `catalogId` from the lowest item ids first; nil when short.
local function debit(bag: any, catalogId: string, quantity: number): any?
	local ids = {}
	for id, item in bag.items do
		if item.catalogId == catalogId then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	for _, id in ids do
		local take = math.min(quantity, Inventory.available(bag, id))
		if take > 0 then
			bag = assert(Inventory.consume(bag, id, take, bag.version))
			quantity -= take
		end
	end
	return if quantity == 0 then bag else nil
end

-- Adds a fresh output stack and merges it into an existing compatible stack when it fits.
local function credit(bag: any, catalog: any, catalogId: string, quantity: number, itemId: string): (any?, string?)
	local definition = catalog[catalogId]
	local item = {
		itemId = itemId,
		catalogId = catalogId,
		quantity = quantity,
		qualityMilli = 1000,
		durabilityMilli = Catalog.durabilityCeiling(definition, 1000),
		attributes = {},
	}
	local added, err = Inventory.add(bag, catalog, item, bag.version)
	if not added then
		return nil, err
	end
	local ids = {}
	for id, other in added.items do
		if id ~= itemId and Inventory.compatible(other, item) and other.quantity + quantity <= definition.stackMax then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	if ids[1] then
		return assert(Inventory.merge(added, catalog, itemId, ids[1], quantity, added.version)), nil
	end
	return added, nil
end

local function award(content: any, progression: any, row: any, receipt: string): any
	local policy = content.progressionPolicy.tree
	for _, category in content.skillCategories or {} do
		local matches = table.find(category.entryActions, row.id) ~= nil
		for _, node in (row.gates or {}).skillNodes or {} do
			matches = matches or string.match(node, "^(.*)_%d+$") == category.id
		end
		if matches then
			progression = Tree.award(progression, policy, category.id, receipt .. ":" .. category.id)
		end
	end
	return progression
end

function M.factory(ctx: any): (Shared.Extension & { close: (() -> Shared.Result)? })?
	if not ctx.content.progressionPolicy or #M.operations(ctx.content) == 0 then
		return nil
	end
	local catalog = Job.catalog(ctx.content)
	return {
		id = "operations",
		handles = function(action: string): boolean
			return action == M.RUN
		end,
		command = function(actor, _action, args, context, _origin, admit): Shared.Result
			local row = find(ctx.content, args[1])
			if not row then
				return { ok = false, reason = "UNKNOWN_OPERATION" }
			end
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local port = ctx.personalTransfer(actor)
			if not port then
				return { ok = false, reason = "PERSONAL_UNAVAILABLE" }
			end
			local receipt = "operation:" .. tostring(context.sessionEpoch) .. ":" .. tostring(context.requestId)
			local outcome: Shared.Result = { ok = false, reason = "OPERATION_FAILED" }
			local token, err = port.personal:update(port.profile(), function(view)
				local work = Data.clone(view)
				local slice = work.envelope.genres[GENRE].data
				local saved = slice.inventory and slice.inventory.bag
				if not slice.progression or type(saved) ~= "table" then
					outcome = { ok = false, reason = "PROGRESSION_UNAVAILABLE" }
					return view
				end
				local refused = Tree.gate(slice.progression, row.gates or {})
				if not refused and not stationReady(ctx, actor, row, args[2]) then
					refused = "STATION_GATE"
				end
				local bag: any = if refused then nil else Inventory.fromSave(saved, catalog)
				for _, input in if bag then row.inputs else {} do
					bag = debit(bag, input.item, input.quantity)
					if not bag then
						refused = "INSUFFICIENT_ITEMS"
						break
					end
				end
				for index, output in if bag then row.outputs else {} do
					bag, refused = credit(bag, catalog, output.item, output.quantity, receipt .. ":" .. index)
					if not bag then
						break
					end
				end
				if refused or not bag then
					outcome = { ok = false, reason = refused or "OPERATION_FAILED" }
					return view
				end
				slice.inventory.bag = Inventory.save(bag)
				slice.progression = award(ctx.content, slice.progression, row, receipt)
				outcome = { ok = true, data = { operationId = row.id } }
				return work
			end)
			if not token then
				return { ok = false, reason = err or "SAVE_FAILED" }
			end
			port.install(token)
			return outcome
		end,
		snapshot = function(actor: string): (Shared.StateData?, string?)
			local port = ctx.personalTransfer(actor)
			if not port then
				return nil, "PERSONAL_UNAVAILABLE"
			end
			local progression = port.profile().data.envelope.genres[GENRE].data.progression
			local rows = {}
			for _, row in M.operations(ctx.content) do
				table.insert(rows, {
					id = row.id,
					kind = row.kind,
					station = row.station,
					stationTier = row.stationTier,
					inputs = Data.clone(row.inputs),
					outputs = Data.clone(row.outputs),
					reason = if progression then Tree.gate(progression, row.gates or {}) else "PROGRESSION_UNAVAILABLE",
				})
			end
			return { operations = rows } :: any, nil
		end,
	} :: any
end

return M
