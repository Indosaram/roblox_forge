--!strict
-- ContractsExtension: durable contract board + trust + first-session tutorial.
--
-- Plugs genre/survival-coop module/Contracts (pure board) and SurvivalTutorial
-- (pure step machine) into the running Session through the extension seam.
--
-- * State lives in its own Fenced aggregate `contracts:<actor>` with explicit
--   `version`; the personal inventory is only ever changed through the personal
--   aggregate's inventory lens.
-- * A delivery or bundle claim is crash-safe across the two aggregates: the
--   contract transition is committed first together with a `pending` record,
--   the bag exchange is applied exactly once through a marker receipt in the
--   personal `itemTransfers`, and only then is `pending` cleared. `recover`
--   resumes an interrupted exchange.
-- * An optional contract `coins` reward is credited to the persisted soft-currency balance
--   (envelope genres["survival-coop"].data.balance, the same wallet the Market settles) in the
--   SAME atomic personal write as the bag exchange and its marker receipt, so a retried or
--   crash-resumed delivery grants items and coins exactly once.
-- * Tutorial steps are never client claims. Gather/craft/settlement steps are
--   observed from real settled Session command results (`observe`); only the
--   arrival skip and the contract steps are direct commands.
-- * Time comes from the injected `ctx.nowMillis`; the board's randomness is the
--   Rng stream inside Contracts (seed = player hash + day key).
local Contracts = require("./Contracts")
local SurvivalTutorial = require("./SurvivalTutorial")
local Tutorial = require("../../../core/domain/progression/Tutorial")
local Inventory = require("../../../core/domain/inventory/Inventory")
local ItemCatalog = require("../../../core/domain/inventory/ItemCatalog")
local Job = require("../../../core/domain/crafting/Job")
local Ledger = require("../../../core/domain/command/Ledger")
local Shared = require("../../../core/domain/genre/Contract")
local Fenced = require("../../../core/infra/data/FencedStore")

local Session = require("../../../core/infra/genre/Session")
local M = {}
M.SAVE_VERSION = 1

local PREFIX = "survival-coop:"
local MAX_OUTCOMES = 32
local MAX_REQUEST_ID = 100
local ACTIONS: { [string]: boolean } = {
	["contract-accept"] = true,
	["contract-deliver"] = true,
	["contract-swap"] = true,
	["contract-claim"] = true,
	["tutorial-skip-arrival"] = true,
}

local function fail(reason: string): Shared.Result
	return { ok = false, reason = reason }
end

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

local function fresh(actor: string): any
	return {
		version = M.SAVE_VERSION,
		contracts = Contracts.toSave(Contracts.new(actor)),
		tutorial = SurvivalTutorial.save(SurvivalTutorial.resume(nil, function() end)),
		outcomes = {},
		order = {},
	}
end

--- Pure bag exchange: consumes `consume` (by catalog id, lowest item id first)
--- then adds one stack set per reward. Idempotent through `marker`: a view that
--- already carries the marker receipt is returned unchanged.
function M.exchange(
	view: any,
	catalog: ItemCatalog.Catalog,
	consume: { any },
	reward: { any },
	marker: string
): (any?, string?)
	if view.itemTransfers.receipts[marker] ~= nil then
		return view, nil
	end
	local bag, loadError = pcall(Inventory.fromSave, view.inventory, catalog)
	if not bag then
		return nil, tostring(loadError)
	end
	local inventory = loadError :: Inventory.State
	for _, need in consume do
		local remaining = need.quantity
		local ids: { string } = {}
		for itemId, item in inventory.items do
			if item.catalogId == need.item then
				table.insert(ids, itemId)
			end
		end
		table.sort(ids)
		for _, itemId in ids do
			if remaining == 0 then
				break
			end
			local take = math.min(Inventory.available(inventory, itemId), remaining)
			if take > 0 then
				local nextInventory, err = Inventory.consume(inventory, itemId, take, inventory.version)
				if not nextInventory then
					return nil, err
				end
				inventory = nextInventory
				remaining -= take
			end
		end
		if remaining > 0 then
			return nil, "INSUFFICIENT_ITEMS"
		end
	end
	for index, granted in reward do
		local definition = catalog[granted.item]
		if not definition then
			return nil, "UNKNOWN_ITEM"
		end
		local remaining, part = granted.quantity, 0
		while remaining > 0 do
			part += 1
			local count = math.min(definition.stackMax, remaining)
			local added, err = Inventory.add(inventory, catalog, {
				itemId = string.format("%s:%d:%d", marker, index, part),
				catalogId = granted.item,
				quantity = count,
				qualityMilli = 1000,
				durabilityMilli = ItemCatalog.durabilityCeiling(definition, 1000),
				attributes = { origin = "contract" },
			}, inventory.version)
			if not added then
				return nil, err
			end
			inventory = added
			remaining -= count
		end
	end
	local out = copy(view)
	out.inventory = Inventory.save(inventory)
	out.itemTransfers.receipts[marker] = { phase = "CONTRACT" }
	return out, nil
end

local GENRE = "survival-coop"
local MAX_BALANCE = 1e9

--- Pure: credits `coins` to the envelope's survival-coop balance in place. Returns a refusal.
function M.credit(envelope: any, coins: number): string?
	if coins == 0 then
		return nil
	end
	local genres = if type(envelope) == "table" then envelope.genres else nil
	local slice = if type(genres) == "table" then genres[GENRE] else nil
	local data = if type(slice) == "table" then slice.data else nil
	local balance = if type(data) == "table" then data.balance else nil
	if type(balance) ~= "number" or balance < 0 or balance % 1 ~= 0 then
		return "WALLET_UNAVAILABLE"
	end
	if balance + coins > MAX_BALANCE then
		return "WALLET_FULL"
	end
	data.balance = balance + coins
	return nil
end

--- Pure full-view step (`{ envelope, itemTransfers }`): bag exchange + coin credit under one
--- marker. A view that already carries the marker is returned unchanged.
function M.settle(
	view: any,
	path: { string },
	catalog: ItemCatalog.Catalog,
	consume: { any },
	reward: { any },
	coins: number,
	marker: string
): (any?, string?)
	if view.itemTransfers.receipts[marker] ~= nil then
		return view, nil
	end
	local parent = view.envelope
	for index = 1, #path - 1 do
		parent = parent[path[index]]
	end
	local lens = { inventory = parent[path[#path]], itemTransfers = view.itemTransfers }
	local out, err = M.exchange(lens, catalog, consume, reward, marker)
	if not out then
		return nil, err
	end
	local result = copy(view)
	local target = result.envelope
	for index = 1, #path - 1 do
		target = target[path[index]]
	end
	target[path[#path]] = out.inventory
	result.itemTransfers = out.itemTransfers
	local refused = M.credit(result.envelope, coins)
	if refused then
		return nil, refused
	end
	return result, nil
end

function M.factory(ctx: any): any
	local content = ctx.content
	if content.contracts == nil then
		return nil
	end
	local catalog = content.contracts :: Contracts.Catalog
	local itemCatalog = Job.catalog(content)
	local store = ctx.store() :: Fenced.Store
	local tokens: { [string]: Fenced.Profile } = {}
	local departed: { [string]: boolean } = {}

	local function load(actor: string): (Fenced.Profile?, string?)
		if departed[actor] then
			return nil, "ACTOR_LEFT"
		end
		local held = tokens[actor]
		if held then
			return held, nil
		end
		if #actor > 40 then
			return nil, "INVALID_ACTOR"
		end
		local token, err = store:acquire("contracts:" .. actor, function(data)
			if next(data) == nil then
				return fresh(actor)
			end
			assert(data.version == M.SAVE_VERSION and type(data.contracts) == "table", "INVALID_CONTRACTS_SAVE")
			return data
		end)
		if token then
			tokens[actor] = token
		end
		return token, err
	end

	local function update(actor: string, transform: Fenced.Transform): (Fenced.Profile?, string?)
		local token, err = load(actor)
		if not token then
			return nil, err
		end
		local updated, updateError = store:update(token, transform)
		if updated then
			tokens[actor] = updated
		end
		return updated, updateError
	end

	local function emitAll(emits: { any })
		if ctx.analytics then
			for _, event in emits do
				ctx.analytics:emit(event.name, event.fields)
			end
		end
	end

	-- Observes tutorial events inside a transform; buffers analytics for after
	-- the commit so a replayed or failed transform never emits.
	local function advance(data: any, events: { string }, emits: { any })
		local session = SurvivalTutorial.resume(data.tutorial, function(name, fields)
			table.insert(emits, { name = name, fields = fields })
		end)
		for _, event in events do
			SurvivalTutorial.observe(session, event)
		end
		-- Contract steps are state facts, not moments: a contract accepted or delivered
		-- before the player reaches that step still counts once the step is current.
		while true do
			local step = Tutorial.current(session.state)
			local contracts = data.contracts
			local satisfied = step ~= nil
				and (
					(step.event == "ContractAccepted" and (next(contracts.accepted) ~= nil or contracts.delivered > 0))
					or (step.event == "ContractDelivered" and contracts.delivered > 0)
				)
			if not satisfied then
				break
			end
			SurvivalTutorial.observe(session, (step :: Tutorial.Step).event)
		end
		data.tutorial = SurvivalTutorial.save(session)
	end

	local function remember(data: any, requestId: string, binding: string, result: any)
		data.outcomes[requestId] = { binding = binding, result = copy(result) }
		table.insert(data.order, requestId)
		while #data.order > MAX_OUTCOMES do
			data.outcomes[table.remove(data.order, 1) :: string] = nil
		end
	end

	local function bagOf(actor: string): (any?, any?, string?)
		local port = ctx.personalTransfer(actor)
		if not port then
			return nil, nil, "PERSONAL_UNAVAILABLE"
		end
		local current, err = port.personal:inventoryLens():update(port.profile(), function(view)
			return view
		end)
		if not current then
			return nil, nil, err or "PERSONAL_UNAVAILABLE"
		end
		return port, current.data, nil
	end

	-- Applies a recorded pending exchange to the bag (exactly once), then clears it.
	local function finish(actor: string): (boolean, string?)
		local token, err = load(actor)
		if not token then
			return false, err
		end
		local pending = token.data.pending
		if pending == nil then
			return true, nil
		end
		local port = ctx.personalTransfer(actor)
		if not port then
			return false, "PERSONAL_UNAVAILABLE"
		end
		local reason: string? = nil
		local path = port.personal:inventoryPath()
		local applied, applyError = port.personal:update(port.profile(), function(view)
			reason = nil
			local out, why =
				M.settle(view, path, itemCatalog, pending.consume, pending.reward, pending.coins or 0, pending.marker)
			if not out then
				reason = why or "EXCHANGE_FAILED"
				return view
			end
			return out
		end)
		if not applied then
			return false, applyError or "PERSONAL_UNAVAILABLE"
		end
		if reason then
			return false, reason
		end
		port.install(applied)
		local emits: { any } = {}
		local cleared, clearError = update(actor, function(data)
			emits = {}
			local record = data.pending
			if record == nil then
				return data
			end
			data.pending = nil
			remember(data, record.requestId, record.binding, record.result)
			advance(data, if record.event then { record.event } else {}, emits)
			return data
		end)
		if not cleared then
			return false, clearError
		end
		if pending.kind == "deliver" then
			table.insert(emits, { name = "quest_claim", fields = { questId = pending.contractId } })
		end
		emitAll(emits)
		return true, nil
	end

	local function command(
		actor: string,
		action: string,
		args: { any },
		context: Shared.CommandContext,
		_origin: string,
		admit: () -> Shared.Result
	): Shared.Result
		local name = string.sub(action, #PREFIX + 1)
		if #context.requestId > MAX_REQUEST_ID then
			return fail("INVALID_REQUEST")
		end
		local admission = admit()
		if not admission.ok then
			return admission
		end
		local requestId = context.requestId
		local binding = Ledger.canonical({ action = action, args = args })
		local token, loadError = load(actor)
		if not token then
			return fail(loadError or "CONTRACTS_UNAVAILABLE")
		end
		if token.data.pending ~= nil then
			local finished, finishError = finish(actor)
			if not finished then
				return fail(finishError or "CONTRACT_PENDING")
			end
			token = tokens[actor]
		end
		local known = token.data.outcomes[requestId]
		if known then
			if known.binding ~= binding then
				return fail("REQUEST_CONFLICT")
			end
			return copy(known.result)
		end
		local now = ctx.nowMillis()
		local reason: string? = nil
		local result: any = nil
		local emits: { any } = {}

		if name == "tutorial-skip-arrival" then
			local updated, err = update(actor, function(data)
				reason, emits = nil, {}
				advance(data, { "ArrivalDone" }, emits)
				result = { ok = true, data = { step = data.tutorial.index } }
				remember(data, requestId, binding, result)
				return data
			end)
			if not updated then
				return fail(err or "CONTRACTS_UNAVAILABLE")
			end
			emitAll(emits)
			return result
		end

		if name == "contract-accept" or name == "contract-swap" then
			local updated, err = update(actor, function(data)
				reason, emits, result = nil, {}, nil
				local state = Contracts.fromSave(data.contracts)
				if name == "contract-accept" then
					local ok, why = Contracts.accept(state, catalog, args[1], now)
					if not ok then
						reason = why or "REJECTED"
						return data
					end
					data.contracts = Contracts.toSave(state)
					advance(data, { "ContractAccepted" }, emits)
					result = { ok = true, data = { contractId = args[1] } }
				else
					local swapped, why = Contracts.swap(state, catalog, args[1], now)
					if not swapped then
						reason = why or "REJECTED"
						return data
					end
					result = { ok = true, data = { contractId = swapped } }
				end
				data.contracts = Contracts.toSave(state)
				remember(data, requestId, binding, result)
				return data
			end)
			if not updated then
				return fail(err or "CONTRACTS_UNAVAILABLE")
			end
			if reason then
				return fail(reason)
			end
			emitAll(emits)
			return result
		end

		-- deliver / claim: bag exchange across two aggregates.
		local port, view, bagError = bagOf(actor)
		if not port then
			return fail(bagError or "PERSONAL_UNAVAILABLE")
		end
		local bag = Inventory.fromSave(view.inventory, itemCatalog)
		local held: { [string]: number } = {}
		for itemId, item in bag.items do
			held[item.catalogId] = (held[item.catalogId] or 0) + Inventory.available(bag, itemId)
		end
		local marker = "ct:" .. requestId
		local pendingRecord: any = nil
		local updated, err = update(actor, function(data)
			reason, emits, result, pendingRecord = nil, {}, nil, nil
			local state = Contracts.fromSave(data.contracts)
			local consume: { any }, reward: { any } = {}, {}
			local coins = 0
			local event: string? = nil
			if name == "contract-deliver" then
				local delivery, why = Contracts.deliver(state, catalog, args[1], held, now)
				if not delivery then
					reason = why or "REJECTED"
					return data
				end
				consume, reward, event = delivery.consume, delivery.reward, "ContractDelivered"
				coins = delivery.coins
				result = {
					ok = true,
					data = {
						contractId = args[1],
						coins = coins,
						faction = delivery.faction,
						trust = delivery.trust,
						tierBefore = delivery.tierBefore,
						tierAfter = delivery.tierAfter,
						boardOpened = delivery.boardOpened,
					},
				}
			else
				local items, why = Contracts.claimBundle(state, catalog, args[1], args[2])
				if not items then
					reason = why or "REJECTED"
					return data
				end
				reward = items
				result = { ok = true, data = { faction = args[1], tier = args[2] } }
			end
			-- Dry-run the exchange so a full bag refuses before any state moves.
			local _, exchangeError = M.exchange(view, itemCatalog, consume, reward, marker)
			if exchangeError then
				reason = if exchangeError == "INSUFFICIENT_ITEMS" then exchangeError else "BAG_FULL"
				return data
			end
			data.contracts = Contracts.toSave(state)
			pendingRecord = {
				requestId = requestId,
				binding = binding,
				marker = marker,
				kind = if name == "contract-deliver" then "deliver" else "claim",
				contractId = args[1],
				consume = consume,
				reward = reward,
				coins = coins,
				event = event,
				result = result,
			}
			data.pending = copy(pendingRecord)
			return data
		end)
		if not updated then
			return fail(err or "CONTRACTS_UNAVAILABLE")
		end
		if reason then
			return fail(reason)
		end
		local finished, finishError = finish(actor)
		if not finished then
			return fail(finishError or "CONTRACT_PENDING")
		end
		return result
	end

	local function snapshot(actor: string): (Shared.StateData?, string?)
		local token, err = load(actor)
		if not token then
			return nil, err
		end
		local renewed = store:renew(token)
		if renewed then
			tokens[actor] = renewed
			token = renewed
		end
		local data = token.data
		local state = Contracts.fromSave(data.contracts)
		local now = ctx.nowMillis()
		local offers = {}
		for _, id in Contracts.offers(state, catalog, now) do
			for _, entry in catalog.entries do
				if entry.id == id then
					table.insert(offers, {
						id = id,
						faction = entry.faction,
						accepted = state.accepted[id] == true,
						deliver = copy(entry.deliver),
						reward = copy(entry.reward),
						coins = entry.coins,
						trust = entry.trust,
					})
				end
			end
		end
		local trust = {}
		for _, faction in catalog.factions do
			local value = state.trust[faction.id] or 0
			trust[faction.id] = { value = value, tier = Contracts.tier(catalog, faction.id, value) }
		end
		local session = SurvivalTutorial.resume(data.tutorial, function() end)
		local step = Tutorial.current(session.state)
		return {
			version = M.SAVE_VERSION,
			phase = state.phase,
			offers = offers,
			trust = trust,
			delivered = state.delivered,
			swapReadyAt = state.swapReadyAt,
			pending = data.pending ~= nil,
			tutorial = {
				complete = Tutorial.isComplete(session.state),
				index = session.state.index,
				step = if step then step.id else nil,
				hint = if step then step.hint else nil,
				total = #SurvivalTutorial.STEPS,
			},
		},
			nil
	end

	local function observe(actor: string, action: string, _args: { any }, result: Shared.Result)
		if not result.ok then
			return
		end
		local event: string? = nil
		if action == PREFIX .. "gather" then
			event = "Gathered"
		elseif action == PREFIX .. "settlement-place" then
			event = "SettlementDeclared"
		elseif action == PREFIX .. "craft-complete" or action == PREFIX .. "settlement-workshop-complete" then
			-- The real bag decides: the step needs an actual stone axe, not a claim.
			local port, view = bagOf(actor)
			if port and view then
				for _, item in view.inventory.items do
					if item.catalogId == "stone-axe" then
						event = "CraftedStoneAxe"
						break
					end
				end
			end
		end
		if event == nil then
			return
		end
		local token = load(actor)
		if not token or token.data.tutorial.completed then
			return
		end
		local emits: { any } = {}
		local updated = update(actor, function(data)
			emits = {}
			-- Any real gameplay event means the player is past the arrival scene.
			advance(data, { "ArrivalDone", event :: string }, emits)
			return data
		end)
		if updated then
			emitAll(emits)
		end
	end

	local function recover(actor: string, _maximum: number): any
		if departed[actor] then
			return { status = "confirmed", transfers = {} }
		end
		-- Release leases of actors who left so another server can take them over.
		local members = ctx.members()
		for held, token in tokens do
			if not table.find(members, held) then
				store:release(token)
				tokens[held] = nil
			end
		end
		if tokens[actor] == nil then
			-- A member of this server is loaded so an interrupted grant (e.g. after a restart)
			-- finishes on the recovery sweep instead of waiting for the next contract command.
			if not table.find(members, actor) or load(actor) == nil then
				return { status = "confirmed", transfers = {} }
			end
		end
		local finished, err = finish(actor)
		return if finished then { status = "confirmed", transfers = {} } else { status = "recovering", error = err }
	end

	return Session.registerLifecycle({
		id = "contracts",
		handles = function(action: string): boolean
			return string.sub(action, 1, #PREFIX) == PREFIX and ACTIONS[string.sub(action, #PREFIX + 1)] == true
		end,
		command = command,
		snapshot = snapshot,
		recover = recover,
		observe = observe,
		drain = function(actor: string): Shared.Result
			if tokens[actor] == nil then
				return { ok = true }
			end
			local finished, err = finish(actor)
			return { ok = finished == true, reason = err }
		end,
		releaseActor = function(actor: string): Shared.Result
			local token = tokens[actor]
			if token then
				local released, err = store:release(token)
				if not released and err ~= "lease lost" then
					return { ok = false, reason = err }
				end
			end
			tokens[actor] = nil
			departed[actor] = true
			return { ok = true }
		end,
		resumeActor = function(actor: string): Shared.Result
			departed[actor] = nil
			local token, err = load(actor)
			return { ok = token ~= nil, reason = err }
		end,
		close = function(): Shared.Result
			for actor, token in tokens do
				local released, err = store:release(token)
				if not released then
					return { ok = false, reason = err }
				end
				tokens[actor] = nil
			end
			return { ok = true }
		end,
	})
end

return M
