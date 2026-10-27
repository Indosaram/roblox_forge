--!strict
-- Saltmeadow plot runtime (C5a): durable claim and build over TownPlots, engine-free.
-- Each plot is one fenced document under TownPlots.key(townId, plotId) and each account has one
-- claim record under TownPlots.accountKey(actor), so a second plot anywhere is refused. Every
-- write is acquire -> update -> release on a FencedStore, so one write owner per key at a time.
-- A build pays from the personal bag through a durable bag reservation named after the plot
-- reservation: reserve plot -> reserve bag -> commit plot -> consume bag. recover() settles a
-- crash at any step: a committed structure consumes its bag lock, an open one releases it.
local TownPlots = require("./TownPlots")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local M = {}

export type Result = { ok: boolean, reason: string?, data: any? }
-- transform returns (next bag, nil) to write, (nil, reason) to refuse, (nil, nil) for no change.
export type BagPort = (string, (any) -> (any?, string?)) -> (boolean, string?)
export type Config = {
	layout: TownPlots.Layout,
	townId: string,
	definitions: { [string]: TownPlots.Definition },
	catalog: any,
	store: any,
	now: () -> number,
	rank: (string) -> number,
	bag: BagPort,
	publish: ((string, TownPlots.Doc?) -> ())?,
	-- Trusted reach port: true when the actor stands on (or at the edge of) the plot.
	reach: ((string, TownPlots.Plot) -> boolean)?,
}

local function fail(reason: string?): Result
	return { ok = false, reason = reason or "TOWN_UNAVAILABLE" }
end

function M.new(config: Config): any
	local layout, townId, store = config.layout, config.townId, config.store
	assert(string.match(townId, "^[%w%-]+$") and #townId <= 24, "INVALID_TOWN_ID")
	local docs: { [string]: TownPlots.Doc? } = {}
	local api = {}
	local function same(data: any): any
		return data
	end
	local function read(key: string): (any?, string?)
		local profile, err = store:acquire(key, same)
		if not profile then
			return nil, err
		end
		local released, releaseError = store:release(profile)
		if not released then
			return nil, releaseError
		end
		return profile.data, nil
	end
	-- transform(data) -> (next data, nil) | (nil, reason); a reason leaves the record unchanged.
	local function mutate(key: string, transform: (any) -> (any?, string?)): (any?, string?)
		local profile, err = store:acquire(key, same)
		if not profile then
			return nil, err
		end
		local reason: string? = nil
		local updated, updateError = store:update(profile, function(data)
			local nextData, why = transform(data)
			reason = why
			return if why or nextData == nil then data else nextData
		end)
		store:release(updated or profile)
		if not updated then
			return nil, updateError
		elseif reason then
			return nil, reason
		end
		return updated.data, nil
	end
	local function decode(data: any): TownPlots.Doc?
		return if type(data) == "table" and data.saveVersion == 1
			then TownPlots.fromSave(data, layout, townId, config.definitions)
			else nil
	end
	local function load(plotId: string): (TownPlots.Doc?, string?)
		local data, err = read(TownPlots.key(townId, plotId))
		if err then
			return nil, err
		end
		local doc = decode(data)
		docs[plotId] = doc
		return doc, nil
	end
	local function publish(plotId: string)
		if config.publish then
			config.publish(plotId, docs[plotId])
		end
	end
	-- Persists `nextDoc` only if the stored plot is still at `expected`'s settlement version.
	local function persist(plotId: string, expected: TownPlots.Doc, nextDoc: TownPlots.Doc): string?
		local _, err = mutate(TownPlots.key(townId, plotId), function(data)
			local stored = decode(data)
			if not stored or stored.ownerId ~= expected.ownerId then
				return nil, "PLOT_UNCLAIMED"
			elseif stored.settlement.version ~= expected.settlement.version then
				return nil, "STALE_VERSION"
			end
			return TownPlots.save(nextDoc), nil
		end)
		if err then
			return err
		end
		docs[plotId] = nextDoc
		publish(plotId)
		return nil
	end

	--- Loads every plot once (server start) and publishes it; returns the ids that failed.
	function api.start(): { string }
		local failed = {}
		for _, plot in layout.plots do
			local _, err = load(plot.id)
			if err then
				table.insert(failed, plot.id)
			end
			publish(plot.id)
		end
		return failed
	end
	function api.doc(plotId: string): TownPlots.Doc?
		return docs[plotId]
	end
	--- Plot table the client minimap and sea chart read: ids, owners and free count.
	function api.view(): any
		local plots, free = {}, 0
		for _, plot in layout.plots do
			local doc = docs[plot.id]
			table.insert(plots, { id = plot.id, owner = if doc then doc.ownerId else nil })
			if not doc then
				free += 1
			end
		end
		return { townId = townId, plots = plots, free = free, total = #layout.plots }
	end

	function api.claim(actor: string, plotId: string): Result
		if layout.byId[plotId] == nil then
			return fail("UNKNOWN_PLOT")
		elseif config.reach and not config.reach(actor, layout.byId[plotId]) then
			return fail("PLOT_UNREACHABLE")
		end
		local account, accountError = read(TownPlots.accountKey(actor))
		if accountError then
			return fail(accountError)
		end
		-- A record naming this town's plot that the actor no longer owns is stale (rolled-back claim).
		local claimed: string? = nil
		if type(account) == "table" and account.town then
			local mine = account.town == townId and account.plot ~= nil
			local held = if mine then docs[account.plot] else nil
			claimed = if mine and (held == nil or held.ownerId ~= actor)
				then nil
				else account.town .. ":" .. account.plot
		end
		local current, loadError = load(plotId)
		if loadError then
			return fail(loadError)
		end
		local doc, reason = TownPlots.claim(
			layout,
			townId,
			current,
			plotId,
			actor,
			{ developmentRank = config.rank(actor), claimed = claimed },
			config.now()
		)
		if not doc then
			return fail(reason)
		end
		local _, recordError = mutate(TownPlots.accountKey(actor), function(data)
			if data.town and not (claimed == nil and data.town == townId) then
				return nil, "ALREADY_CLAIMED"
			end
			return { town = townId, plot = plotId, at = doc.claimedAt }, nil
		end)
		if recordError then
			return fail(recordError)
		end
		local _, plotError = mutate(TownPlots.key(townId, plotId), function(data)
			if decode(data) then
				return nil, "PLOT_OWNED"
			end
			return TownPlots.save(doc), nil
		end)
		if plotError then
			mutate(TownPlots.accountKey(actor), function(data)
				return if data.town == townId and data.plot == plotId then {} else nil, nil
			end)
			load(plotId)
			return fail(plotError)
		end
		docs[plotId] = doc
		publish(plotId)
		return { ok = true, data = { plotId = plotId, townId = townId } }
	end

	local function lockOwner(plotId: string, reservationId: string): string
		return "town:" .. townId .. ":" .. plotId .. ":" .. reservationId
	end

	--- Settles bag locks a crash left between the plot reservation and the bag debit.
	function api.recover(actor: string): Result
		local prefix = "town:" .. townId .. ":"
		local locks: { string } = {}
		local ok, err = config.bag(actor, function(bag)
			for owner in bag.reservations do
				if string.sub(owner, 1, #prefix) == prefix then
					table.insert(locks, owner)
				end
			end
			return nil, nil
		end)
		if not ok then
			return fail(err)
		end
		table.sort(locks)
		for _, owner in locks do
			local plotId, reservationId = string.match(string.sub(owner, #prefix + 1), "^([^:]+):(.+)$")
			local doc = if plotId and layout.byId[plotId] then (load(plotId)) else nil
			local settlement = if doc then doc.settlement else nil
			local reservation = reservationId or ""
			local built = settlement ~= nil
				and settlement.structures[settlement.config.tribeId .. ":" .. reservation] ~= nil
			if doc and settlement and not built and settlement.reservations[reservation] then
				local cancelled = TownPlots.cancel(doc, settlement.ownerId, reservation)
				if cancelled then
					persist(plotId :: string, doc, cancelled)
				end
			end
			ok, err = config.bag(actor, function(bag)
				if bag.reservations[owner] == nil then
					return nil, nil
				end
				return if built
					then Inventory.exchange(bag, config.catalog, owner, {}, bag.version)
					else Inventory.release(bag, owner, bag.version)
			end)
			if not ok then
				return fail(err)
			end
		end
		return { ok = true }
	end

	function api.build(actor: string, plotId: string, request: TownPlots.Request): Result
		local recovered = api.recover(actor)
		if not recovered.ok then
			return recovered
		end
		local doc, loadError = load(plotId)
		if loadError then
			return fail(loadError)
		elseif not doc then
			return fail("PLOT_UNCLAIMED")
		elseif config.reach and not config.reach(actor, layout.byId[plotId]) then
			return fail("PLOT_UNREACHABLE")
		end
		local reserved, reason, reservationId, cost = TownPlots.reserve(layout, doc, actor, request, config.definitions)
		if not reserved then
			return fail(reason)
		end
		local id = reservationId :: string
		local err = persist(plotId, doc, reserved)
		if err then
			return fail(err)
		end
		local owner = lockOwner(plotId, id)
		local locked, lockError = config.bag(actor, function(bag)
			local quantities: { [string]: number } = {}
			local ids = {}
			for itemId in bag.items do
				table.insert(ids, itemId)
			end
			table.sort(ids)
			for _, entry in cost :: { any } do
				local remaining = entry.quantity
				for _, itemId in ids do
					local item = bag.items[itemId]
					if remaining > 0 and item.catalogId == entry.item then
						local take = math.min(remaining, Inventory.available(bag, itemId) - (quantities[itemId] or 0))
						if take > 0 then
							quantities[itemId] = (quantities[itemId] or 0) + take
							remaining -= take
						end
					end
				end
				if remaining > 0 then
					return nil, "MISSING_KIT"
				end
			end
			return Inventory.reserve(bag, owner, quantities, bag.version)
		end)
		if not locked then
			local cancelled = TownPlots.cancel(reserved, actor, id)
			if cancelled then
				persist(plotId, reserved, cancelled)
			end
			return fail(lockError)
		end
		local committed, commitError = TownPlots.commit(reserved, actor, id)
		if not committed then
			return fail(commitError)
		end
		err = persist(plotId, reserved, committed)
		if err then
			-- The bag lock stays; recover() releases it when the plot kept only the reservation.
			return fail(err)
		end
		local paid, payError = config.bag(actor, function(bag)
			if bag.reservations[owner] == nil then
				return nil, nil
			end
			return Inventory.exchange(bag, config.catalog, owner, {}, bag.version)
		end)
		if not paid then
			return fail(payError)
		end
		return {
			ok = true,
			data = { plotId = plotId, structureId = committed.settlement.config.tribeId .. ":" .. id },
		}
	end

	--- mission-action entry: "town-claim" <plotId> | "town-build" "<plotId>:<structure>:<x>:<z>:<rotation>".
	function api.command(actor: string, operation: string, target: string): Result
		if operation == "town-claim" then
			return api.claim(actor, target)
		elseif operation == "town-build" then
			local plotId, structure, x, z, rotation =
				string.match(target, "^([%w]+):([%w%-]+):(%-?%d+):(%-?%d+):([0-3])$")
			if not plotId then
				return fail("INVALID_TOWN_BUILD")
			end
			return api.build(actor, plotId :: string, {
				structure = structure :: string,
				x = tonumber(x) :: number,
				z = tonumber(z) :: number,
				rotation = tonumber(rotation) :: number,
			})
		end
		return fail("UNKNOWN_TOWN_ACTION")
	end
	return api
end

return M
