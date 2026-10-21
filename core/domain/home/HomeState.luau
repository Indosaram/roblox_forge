--!strict
-- Personal ownership is actor-fixed. Clan space remains the camp aggregate;
-- clan membership grants only the explicitly persisted cooperative permission.
local Inventory = require("../inventory/Inventory")
local CapacityPolicy = require("../survival/CapacityPolicy")
local Rng = require("../random/Rng")
local M = {}

function M.copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in value do
		out[key] = M.copy(child)
	end
	return out
end

function M.identity(actor: string): string
	assert(type(actor) == "string" and #actor > 0 and #actor <= 32 and not string.find(actor, "%c"), "INVALID_ACTOR")
	return "home:" .. actor
end

function M.new(actor: string, rules: any, seed: number): any
	local id = M.identity(actor)
	assert(rules.baseSlots <= CapacityPolicy.forVersion(2).homeSlots, "HOME_CAPACITY")
	return {
		schemaVersion = 1,
		revision = 0,
		homeId = id,
		owner = actor,
		seed = seed,
		developmentRank = 1,
		landRank = 1,
		dock = M.copy(rules.dock),
		permissions = { visit = "owner", cooperate = "none", friends = {}, clanId = "", offlineCoop = false },
		structures = {},
		plots = {},
		plantSequence = 0,
		storageSlots = rules.baseSlots,
		storage = Inventory.save(Inventory.new(id, {
			kind = "home",
			contentVersion = 2,
			slots = rules.baseSlots,
			softWeightMilli = 90000,
			hardWeightMilli = 90000,
		})),
	}
end

function M.load(saved: any, owner: string, catalog: any): any
	assert(saved.schemaVersion == 1 and saved.homeId == M.identity(owner) and saved.owner == owner, "WRONG_HOME")
	local out = M.copy(saved)
	out.storage = Inventory.save(Inventory.fromSave(out.storage, catalog))
	return out
end

function M.allowed(state: any, actor: string, operation: string, facts: any): boolean
	if actor == state.owner then
		return true
	end
	local acl = state.permissions
	local mode = if operation == "visit" then acl.visit else acl.cooperate
	local member = (mode == "friend" and acl.friends[actor] == true and facts.friend == true)
		or (mode == "clan" and acl.clanId ~= "" and facts.clanId == acl.clanId)
	if operation == "visit" then
		return member
	end
	return member and (facts.ownerOnline == true or acl.offlineCoop == true)
end

local function take(storage: any, catalog: any, catalogId: string, count: number): (any?, string?)
	local bag = Inventory.fromSave(storage, catalog)
	local ids = {}
	for id, item in bag.items do
		if item.catalogId == catalogId then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	for _, id in ids do
		local amount = math.min(Inventory.available(bag, id), count)
		if amount > 0 then
			local nextBag, reason = Inventory.consume(bag, id, amount, bag.version)
			if not nextBag then
				return nil, reason
			end
			bag = nextBag
			count -= amount
		end
	end
	return if count == 0 then Inventory.save(bag) else nil, if count == 0 then nil else "INSUFFICIENT_ITEMS"
end

-- Facts, content definitions and entitlements are trusted server ports, never
-- command arguments. All crop inputs and outputs settle in this ONE aggregate.
function M.apply(state: any, actor: string, homeId: string, action: string, args: any, ctx: any): (any?, string?)
	if homeId ~= state.homeId then
		return nil, "WRONG_HOME_TOKEN"
	end
	local ownerOnly = action == "permissions" or action == "expand" or action == "rank" or action == "capacity"
	if (ownerOnly and actor ~= state.owner) or not M.allowed(state, actor, "cooperate", ctx.facts) then
		return nil, "FORBIDDEN"
	end
	local out = M.copy(state)
	if action == "permissions" then
		local acl = args.permissions
		local modes = { owner = true, friend = true, clan = true, none = true }
		if
			type(acl) ~= "table"
			or not modes[acl.visit]
			or not modes[acl.cooperate]
			or type(acl.friends) ~= "table"
			or type(acl.clanId) ~= "string"
			or type(acl.offlineCoop) ~= "boolean"
		then
			return nil, "INVALID_PERMISSIONS"
		end
		for id, enabled in acl.friends do
			if type(id) ~= "string" or enabled ~= true then
				return nil, "INVALID_PERMISSIONS"
			end
		end
		out.permissions = M.copy(acl)
	elseif action == "rank" then
		if
			not ctx.developmentRank
			or ctx.developmentRank < state.developmentRank
			or not ctx.rules.landSizes[ctx.developmentRank]
		then
			return nil, "RANK_LOCKED"
		end
		out.developmentRank = ctx.developmentRank
	elseif action == "expand" then
		if args.atDock ~= true or state.landRank >= state.developmentRank then
			return nil, "EXPANSION_LOCKED"
		end
		out.landRank = state.developmentRank
	elseif action == "capacity" then
		local slots = ctx.rules.baseSlots
		for id, extra in ctx.rules.storageGrants do
			if ctx.entitlements[id] == true then
				slots += extra
			end
		end
		if slots > CapacityPolicy.forVersion(2).homeSlots then
			return nil, "HOME_CAPACITY"
		end
		-- Keep a loadable overflow container on entitlement expiry, but block new
		-- credits against storageSlots until the owner removes the overflow.
		local occupied = 0
		for _ in out.storage.items do
			occupied += 1
		end
		out.storageSlots = slots
		out.storage.limits.slots = math.max(slots, occupied)
	elseif action == "place" then
		local definition = ctx.structures[args.kind]
		local position = args.position
		local half = ctx.rules.landSizes[state.landRank] / 2
		if
			not definition
			or type(args.id) ~= "string"
			or args.id == ""
			or state.structures[args.id]
			or not position
		then
			return nil, "INVALID_STRUCTURE"
		end
		if
			math.abs(position.x) + definition.halfSize > half
			or math.abs(position.z) + definition.halfSize > half
			or not table.find(ctx.rules.floors, position.y)
			or state.developmentRank < definition.rank
		then
			return nil, "OUTSIDE_LAND"
		end
		for _, placed in state.structures do
			local other = ctx.structures[placed.kind]
			if
				placed.position.y == position.y
				and math.abs(placed.position.x - position.x) < other.halfSize + definition.halfSize
				and math.abs(placed.position.z - position.z) < other.halfSize + definition.halfSize
			then
				return nil, "OCCUPIED"
			end
		end
		local storage, reason = take(out.storage, ctx.catalog, definition.kit, 1)
		if not storage then
			return nil, reason
		end
		out.storage = storage
		out.structures[args.id] = { kind = args.kind, position = M.copy(position), owner = actor }
	elseif action == "plant" then
		local crop = ctx.crops[args.crop]
		if not crop or not ctx.rules.plots[args.plot] then
			return nil, "UNKNOWN_CROP_OR_PLOT"
		end
		if state.plots[args.plot] ~= nil then
			return nil, "PLOT_OCCUPIED"
		end
		for _, node in crop.nodes do
			if ctx.nodes[node] ~= true then
				return nil, "SKILL_LOCKED"
			end
		end
		local seedItem = out.storage.items[args.seedItem]
		if
			not seedItem
			or seedItem.catalogId ~= crop.seed
			or Inventory.available(Inventory.fromSave(out.storage, ctx.catalog), args.seedItem) < 1
		then
			return nil, "WRONG_SEED"
		end
		local level = seedItem.attributes.level
		if type(level) ~= "number" or level < 1 then
			return nil, "SEED_LEVEL_REQUIRED"
		end
		local bag, seedError =
			Inventory.consume(Inventory.fromSave(out.storage, ctx.catalog), args.seedItem, 1, out.storage.version)
		if not bag then
			return nil, seedError
		end
		out.storage = Inventory.save(bag)
		for _, input in crop.inputs do
			if input.item ~= crop.seed then
				local storage, reason = take(out.storage, ctx.catalog, input.item, input.quantity)
				if not storage then
					return nil, reason
				end
				out.storage = storage
			end
		end
		out.plantSequence += 1
		local rng = Rng.new(state.seed):fork(args.plot .. ":" .. tostring(out.plantSequence))
		out.plots[args.plot] = {
			crop = args.crop,
			plantedAt = ctx.now,
			readyAt = ctx.now + crop.seconds,
			level = level,
			quantity = crop.quantity,
			roll = rng:nextU32(),
			sequence = out.plantSequence,
		}
	elseif action == "harvest" then
		local planted = state.plots[args.plot]
		if not planted then
			return nil, "EMPTY_PLOT"
		end
		if ctx.now < planted.readyAt then
			return nil, "NOT_GROWN"
		end
		local occupied = 0
		for _ in out.storage.items do
			occupied += 1
		end
		if occupied >= state.storageSlots then
			return nil, "FULL_SLOTS"
		end
		local crop = ctx.crops[planted.crop]
		local bag = Inventory.fromSave(out.storage, ctx.catalog)
		local added, reason = Inventory.add(bag, ctx.catalog, {
			itemId = state.homeId .. ":crop:" .. tostring(planted.sequence),
			catalogId = crop.output,
			quantity = planted.quantity,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = { level = planted.level, origin = state.homeId, roll = planted.roll },
		}, bag.version)
		if not added then
			return nil, reason
		end
		out.storage = Inventory.save(added)
		out.plots[args.plot] = nil
	elseif action == "recover" then
		local placed = state.structures[args.id]
		if not placed then
			return nil, "UNKNOWN_STRUCTURE"
		end
		local occupied = 0
		for _ in out.storage.items do
			occupied += 1
		end
		if occupied >= state.storageSlots then
			return nil, "FULL_SLOTS"
		end
		local bag = Inventory.fromSave(out.storage, ctx.catalog)
		local definition = ctx.structures[placed.kind]
		local added, reason = Inventory.add(bag, ctx.catalog, {
			itemId = state.homeId .. ":recover:" .. tostring(state.revision),
			catalogId = definition.kit,
			quantity = 1,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = {},
		}, bag.version)
		if not added then
			return nil, reason
		end
		out.storage = Inventory.save(added)
		out.structures[args.id] = nil
	else
		return nil, "UNKNOWN_ACTION"
	end
	out.revision += 1
	return out, nil
end

return M
