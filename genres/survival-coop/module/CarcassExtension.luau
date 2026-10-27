--!strict
-- Carcass picker (Robango plan C3, G12). After a kill the killer chooses which carcass outputs to
-- take, one output at a time. The offer is the species' content `dropReservoirs` (meat, hide,
-- bone, ...); each output can be taken once per corpse, only by the killer, only while standing
-- within REACH_STUDS of the body and only before the corpse expires. Everything is decided here on
-- the server against the confirmed wildlife state and the server's spatial access; the client
-- only shows the offer.
--
-- Opt-in: the genre registry (Extensions.luau) does not list this factory. A pack registers it
-- and leaves the reservoir outputs out of its automatic kill drops (Robango: SurvivalFactory,
-- WildlifePolicy, RoleWorld), so a pack without it keeps the old automatic loot unchanged.
local Shared = require("../../../core/domain/genre/Contract")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Job = require("../../../core/domain/crafting/Job")
local Data = require("../../../core/domain/genre/SerializedData")
local Award = require("./ProgressionExtension").award

local M = {}
M.ACTION = "survival-coop:carcass-take"
-- Seconds a corpse stays open after the kill (WildlifeRuntime stamps killedAt in seconds).
M.LIFETIME_SECONDS = 300
M.REACH_STUDS = 10
-- Open corpse records kept per player; the oldest expiry is dropped first.
M.MAX_RECORDS = 32
local GENRE = "survival-coop"

export type Output = { item: string, quantity: number }
export type Wild = { catalogId: string, healthMilli: number, killer: string?, killedAt: number? }
export type Record = { corpse: string, expiresAt: number, taken: { [string]: number } }
export type Records = { version: number, corpses: { [string]: Record } }

function M.actions(): { any }
	local Schema = require("../../../core/infra/net/Schema")
	local id = Schema.string({ maxLen = 128, pattern = ".+" })
	return {
		{ id = "carcass-take", args = { id, id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
	}
end

--- The carcass outputs a species offers, in content order (empty for a species without reservoirs).
function M.outputs(content: any, catalogId: string): { Output }
	for _, species in content.wildlifeDetails or {} do
		if species.id == catalogId then
			local out: { Output } = {}
			for _, reservoir in species.dropReservoirs or {} do
				table.insert(out, { item = reservoir.item, quantity = reservoir.quantity })
			end
			return out
		end
	end
	return {}
end

function M.corpseId(wildId: string, killedAt: number): string
	return wildId .. ":" .. tostring(killedAt)
end

local function empty(): Records
	return { version = 1, corpses = {} }
end

--- Records without corpses that expired by `now`, capped at MAX_RECORDS (latest expiry kept).
function M.prune(records: Records?, now: number): Records
	local result = empty()
	local live: { { any } } = {}
	local corpses: { [string]: Record } = if records then records.corpses else {}
	for wildId, record in corpses do
		if record.expiresAt > now then
			table.insert(live, { wildId, record } :: { any })
		end
	end
	table.sort(live, function(a, b)
		if a[2].expiresAt ~= b[2].expiresAt then
			return a[2].expiresAt > b[2].expiresAt
		end
		return a[1] < b[1]
	end)
	for index = 1, math.min(#live, M.MAX_RECORDS) do
		result.corpses[live[index][1]] = Data.clone(live[index][2])
	end
	return result
end

--- Pure decision for one take. `distance` is the server-measured actor-to-body distance (nil when
--- the body is not reachable at all). Returns the next records and the quantity granted, or a
--- refusal reason with the records unchanged.
function M.take(
	records: Records?,
	actor: string,
	wildId: string,
	wild: Wild?,
	outputs: { Output },
	item: string,
	distance: number?,
	now: number
): (Records?, number, string?)
	if not wild then
		return nil, 0, "UNKNOWN_TARGET"
	end
	if wild.healthMilli > 0 or wild.killedAt == nil then
		return nil, 0, "NOT_DEAD"
	end
	if wild.killer ~= actor then
		return nil, 0, "NOT_YOURS"
	end
	local expiresAt = wild.killedAt + M.LIFETIME_SECONDS
	if now >= expiresAt then
		return nil, 0, "CORPSE_EXPIRED"
	end
	if distance == nil or distance > M.REACH_STUDS then
		return nil, 0, "OUT_OF_RANGE"
	end
	local quantity = 0
	for _, output in outputs do
		if output.item == item then
			quantity = output.quantity
		end
	end
	if quantity == 0 then
		return nil, 0, "NOT_OFFERED"
	end
	local nextRecords = M.prune(records, now)
	local corpse = M.corpseId(wildId, wild.killedAt)
	local record = nextRecords.corpses[wildId]
	if not record or record.corpse ~= corpse then
		record = { corpse = corpse, expiresAt = expiresAt, taken = {} }
	end
	if record.taken[item] then
		return nil, 0, "ALREADY_TAKEN"
	end
	record.taken[item] = quantity
	nextRecords.corpses[wildId] = record
	return M.prune(nextRecords, now), quantity, nil
end

--- Save shape check for the personal slice key `carcass` (CraftingAdapter.validateSave).
function M.valid(value: any): boolean
	if type(value) ~= "table" or value.version ~= 1 or type(value.corpses) ~= "table" then
		return false
	end
	local count = 0
	for wildId, record in value.corpses do
		count += 1
		if
			not Catalog.identity(wildId)
			or type(record) ~= "table"
			or type(record.corpse) ~= "string"
			or type(record.expiresAt) ~= "number"
			or type(record.taken) ~= "table"
		then
			return false
		end
	end
	return count <= M.MAX_RECORDS
end

local function distanceOf(access: any): number?
	if not access or not access.position or not access.targetPosition then
		return nil
	end
	local a, b = access.position, access.targetPosition
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

-- Adds a fresh output stack, merged into an existing compatible stack when it fits.
local function credit(bag: any, catalog: any, catalogId: string, quantity: number, itemId: string): (any?, string?)
	local definition = catalog[catalogId]
	if not definition then
		return nil, "UNKNOWN_ITEM"
	end
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

function M.factory(ctx: any): (Shared.Extension & { close: (() -> Shared.Result)? })?
	local offered = false
	for _, species in ctx.content.wildlifeDetails or {} do
		offered = offered or #(species.dropReservoirs or {}) > 0
	end
	if not offered or not ctx.wildlife then
		return nil
	end
	local catalog = Job.catalog(ctx.content)
	return {
		id = "carcass",
		handles = function(action: string): boolean
			return action == M.ACTION
		end,
		command = function(actor, _action, args, context, _origin, admit): Shared.Result
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local port = ctx.personalTransfer(actor)
			if not port then
				return { ok = false, reason = "PERSONAL_UNAVAILABLE" }
			end
			local wildId, item = args[1], args[2]
			local wild = ctx.wildlife(wildId)
			local access = if ctx.world and ctx.world.wildlifeAccess
				then ctx.world.wildlifeAccess(actor, wildId)
				else nil
			local now = ctx.now()
			local outputs = if wild then M.outputs(ctx.content, wild.catalogId) else {}
			local receipt = "carcass:" .. tostring(context.sessionEpoch) .. ":" .. tostring(context.requestId)
			local outcome: Shared.Result = { ok = false, reason = "CARCASS_FAILED" }
			local token, err = port.personal:update(port.profile(), function(view)
				local work = Data.clone(view)
				local slice = work.envelope.genres[GENRE].data
				local saved = slice.inventory and slice.inventory.bag
				if type(saved) ~= "table" then
					outcome = { ok = false, reason = "INVENTORY_UNAVAILABLE" }
					return view
				end
				local records, quantity, refused =
					M.take(slice.carcass, actor, wildId, wild, outputs, item, distanceOf(access), now)
				if refused or not records then
					outcome = { ok = false, reason = refused }
					return view
				end
				local bag, reason = credit(Inventory.fromSave(saved, catalog), catalog, item, quantity, receipt)
				if not bag then
					outcome = { ok = false, reason = reason or "CARCASS_FAILED" }
					return view
				end
				slice.inventory.bag = Inventory.save(bag)
				slice.carcass = records
				-- Butchering proficiency is earned on the carcass (its skill entry action), not on the kill.
				if slice.progression and ctx.content.skillCategories then
					slice.progression = Award(ctx.content, slice.progression, "carcass", receipt)
				end
				outcome = { ok = true, data = { wildId = wildId, item = item, quantity = quantity } }
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
			local slice = port.profile().data.envelope.genres[GENRE].data
			local corpses = {}
			for wildId, record in M.prune(slice.carcass, ctx.now()).corpses do
				corpses[wildId] = { corpse = record.corpse, expiresAt = record.expiresAt, taken = record.taken }
			end
			return { corpses = corpses, reachStuds = M.REACH_STUDS, lifetimeSeconds = M.LIFETIME_SECONDS } :: any, nil
		end,
	} :: any
end

return M
