--!strict
-- Shared intent -> personal CAS charge -> shared applied/mint -> personal result.
-- Only the personal envelope owns its bag. Shared intents retain scalar effects,
-- never a bag snapshot; an NPC is locked until its accepted intent resolves.
local Wildlife = require("./Wildlife")
local GatheringRuntime = require("./GatheringRuntime")
local Content = require("../../../core/domain/survival/Content")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Job = require("../../../core/domain/crafting/Job")
local Ledger = require("../../../core/domain/command/Ledger")
local Shared = require("../../../core/domain/genre/Contract")
local Fenced = require("../../../core/infra/data/FencedStore")
local Transfer = require("../../../core/infra/data/ItemTransfer")
local M = {}
export type Request = { actorId: string, sessionEpoch: number, requestId: string, targetId: string, expiresAt: number }
export type Config = {
	key: string,
	content: Content.Document,
	catalog: Wildlife.Catalog,
	initial: { [string]: Wildlife.State },
	carriedContainer: string,
	maxReceipts: number,
	now: () -> number,
	nowMillis: () -> number,
	resolvePersonal: (string) -> GatheringRuntime.PersonalPort?,
	access: (string, string) -> Wildlife.Access?,
}
local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for k, v in value do
		result[k] = copy(v)
	end
	return result
end
local function pending(reason: string?): Shared.Result
	return { ok = false, reason = reason or "COMBAT_PENDING", data = { status = "pending" } }
end
local function rejected(reason: string): Shared.Result
	return { ok = false, reason = reason, data = { status = "rejected" } }
end
export type Runtime = {
	command: (Request, () -> Shared.Result) -> Shared.Result,
	recover: (string, number) -> Shared.Result,
	snapshot: () -> (Fenced.Data?, string?),
}
function M.new(config: Config, store: Fenced.Store): (Runtime?, string?)
	assert(
		config.maxReceipts >= 1 and config.maxReceipts <= 4096 and config.maxReceipts % 1 == 0,
		"INVALID_RECEIPT_LIMIT"
	)
	local policy = Wildlife.catalog(config.content, config.catalog)
	local items = Job.catalog(config.content)
	local largestDrop = 0
	for _, species in policy.species do
		assert(#species.drops <= 20, "DROP_BUDGET")
		largestDrop = math.max(largestDrop, #species.drops)
		for _, drop in species.drops do
			assert(drop.quantity <= items[drop.item].stackMax, "DROP_STACK_LIMIT")
		end
	end
	assert(config.maxReceipts * largestDrop <= 4096, "COMBAT_MINT_BUDGET")
	local token, loadError = store:acquire(config.key, function(data)
		if next(data) == nil then
			return {
				version = 1,
				npcs = copy(config.initial),
				intents = {},
				locks = {},
				actors = {},
				itemTransfers = { version = 1, receipts = {} },
			}
		end
		assert(data.version == 1 and type(data.intents) == "table", "INVALID_WILDLIFE_SAVE")
		return data
	end)
	if not token then
		return nil, loadError
	end
	local source: Fenced.Profile = token
	local runtime = {}
	local function refresh(personal: GatheringRuntime.PersonalPort): (Fenced.Profile?, string?)
		local current, err = personal.personal:refresh(personal.profile())
		if current then
			personal.install(current)
		end
		return current, err
	end
	local function update(transform: Fenced.Transform): string?
		local updated, err = store:update(source, transform)
		if updated then
			source = updated
		end
		return if updated then nil else err or "SOURCE_UNKNOWN"
	end
	local function charge(id: string, personal: GatheringRuntime.PersonalPort): string?
		local intent = source.data.intents[id]
		local current, err = refresh(personal)
		if not current then
			return err or "PERSONAL_UNKNOWN"
		end
		local envelope = copy(current.data.envelope)
		local data = envelope.genres["survival-coop"].data
		local combat = data.combat or { version = 1, nextAttack = 0, receipts = {} }
		if combat.receipts[id] then
			return nil
		end
		local count = 0
		for _ in combat.receipts do
			count += 1
		end
		if count >= config.maxReceipts then
			return "PERSONAL_RECEIPT_LIMIT"
		end
		local bag = Inventory.fromSave(data.inventory[config.carriedContainer], items)
		local item = bag.items[intent.itemId]
		local reason: string? = nil
		if combat.nextAttack > intent.at then
			reason = "COOLDOWN"
		elseif
			not item
			or item.catalogId ~= intent.weaponId
			or item.durabilityMilli <= 0
			or Inventory.available(bag, intent.itemId) == 0
		then
			reason = "WEAPON_UNAVAILABLE"
		end
		if not reason then
			bag.items[intent.itemId].durabilityMilli =
				math.max(0, bag.items[intent.itemId].durabilityMilli - intent.wear)
			bag.version += 1
			data.inventory[config.carriedContainer] = Inventory.save(bag)
			combat.nextAttack = intent.at + intent.cooldown
		end
		combat.receipts[id] = { charged = reason == nil, reason = reason, binding = intent.binding }
		data.combat = combat
		local saved, commitError = personal.personal:commit(current, current.data.stateRevision, envelope, nil)
		if saved then
			personal.install(saved)
		end
		return if not saved then commitError or "PERSONAL_UNKNOWN" else commitError
	end
	local function progress(id: string, personal: GatheringRuntime.PersonalPort): Shared.Result
		local err = charge(id, personal)
		if err then
			return pending(err)
		end
		local receipt = personal.profile().data.envelope.genres["survival-coop"].data.combat.receipts[id]
		err = update(function(data)
			local intent = data.intents[id]
			if intent.phase ~= "INTENT" then
				return data
			end
			assert(receipt.binding == intent.binding, "CHARGE_BINDING_MISMATCH")
			if not receipt.charged then
				intent.phase, intent.reason = "REJECTED", receipt.reason
			else
				local npc = data.npcs[intent.request.targetId]
				assert(data.locks[npc.id] == id and npc.version == intent.npcVersion, "NPC_INTENT_OWNERSHIP")
				npc.healthMilli = math.max(0, npc.healthMilli - intent.damage)
				npc.version += 1
				intent.phase = "APPLIED"
				intent.mints = {}
				if npc.healthMilli == 0 then
					npc.mode, npc.killer = "dead", intent.request.actorId
					for index, drop in intent.drops do
						local mintId = id .. ":" .. tostring(index)
						local req = {
							id = mintId,
							actor = intent.request.actorId,
							epoch = tostring(intent.request.sessionEpoch),
							expiresAt = config.now() + 86400,
							source = config.key,
							destination = intent.destination,
							itemId = mintId,
							outputId = mintId,
							quantity = drop.quantity,
						}
						table.insert(intent.mints, {
							request = req,
							item = {
								itemId = mintId,
								catalogId = drop.item,
								quantity = drop.quantity,
								qualityMilli = 1000,
								durabilityMilli = items[drop.item].maxDurabilityMilli or 0,
								attributes = {},
							},
						})
					end
					if #intent.mints > 0 then
						local minted, mintError =
							Transfer.stageMint(data, items, config.key, intent.binding, intent.mints, {
								maxReceipts = math.min(4096, config.maxReceipts * 20),
								now = config.now,
								authorize = function()
									return true
								end,
							}, nil)
						assert(minted, mintError)
						data = minted
					end
				end
			end
			data.locks[intent.request.targetId] = nil
			return data
		end)
		if err then
			return pending(err)
		end
		local intent = source.data.intents[id]
		local lens = personal.personal:inventoryLens()
		local router: Transfer.StorePort = {
			update = function(_, expected, transform)
				if expected.key == config.key then
					local updated, reason = store:update(expected, transform)
					if updated then
						source = updated
					end
					return updated, reason
				end
				assert(expected.key == personal.profile().key, "WRONG_DESTINATION")
				local updated, reason = lens:update(expected, transform)
				if updated then
					local hydrated, hydrateError = refresh(personal)
					if not hydrated then
						return nil, hydrateError
					end
				end
				return updated, reason
			end,
			acquire = function()
				return nil, "MINT_RETAINED"
			end,
		}
		local coordinator = Transfer.new(router, items, {
			maxReceipts = math.min(4096, config.maxReceipts * 20),
			now = config.now,
			authorize = function()
				return false
			end,
		})
		for _, mint in intent.mints or {} do
			local outcome = coordinator:advance(source, personal.profile(), mint.request, nil)
			if outcome.status == "pending" and outcome.phase == "CREDITED" then
				outcome = coordinator:advance(source, personal.profile(), mint.request, nil)
			end
			if outcome.status ~= "confirmed" then
				return pending(outcome.error)
			end
		end
		local current, refreshError = refresh(personal)
		if not current then
			return pending(refreshError)
		end
		local envelope = copy(current.data.envelope)
		local ledger = envelope.commands
		local req = intent.request
		local epoch = ledger.epochs[tostring(req.sessionEpoch)]
		if not epoch then
			return pending("EPOCH_UNAVAILABLE")
		end
		local known = epoch.outcomes[req.requestId]
		if known then
			err = update(function(data)
				data.intents[id].phase = "FINALIZED"
				data.intents[id].result = copy(known.result)
				data.actors[req.actorId] = nil
				return data
			end)
			return if err then pending(err) else copy(known.result)
		end
		ledger.stateVersion += 1
		local result: Shared.Result = {
			ok = intent.phase ~= "REJECTED",
			reason = intent.reason,
			stateVersion = ledger.stateVersion,
			data = { status = if intent.phase == "REJECTED" then "rejected" else "confirmed", targetId = req.targetId },
		}
		epoch.outcomes[req.requestId] = {
			binding = intent.commandBinding,
			result = copy(result),
			createdAt = intent.acceptedAt,
			expiresAt = intent.acceptedAt + (epoch.expiresAt - epoch.createdAt),
		}
		local saved, commitError = personal.personal:commit(
			current,
			current.data.stateRevision,
			envelope,
			{ epoch = req.sessionEpoch, requestId = req.requestId, binding = intent.commandBinding }
		)
		if saved then
			personal.install(saved)
		end
		if not saved or commitError then
			return pending(commitError)
		end
		err = update(function(data)
			data.intents[id].phase = "FINALIZED"
			data.intents[id].result = copy(result)
			data.actors[req.actorId] = nil
			return data
		end)
		return if err then pending(err) else result
	end
	function runtime.command(request: Request, admit: () -> Shared.Result): Shared.Result
		local req = copy(request)
		local personal = config.resolvePersonal(req.actorId)
		if not personal then
			return pending("PERSONAL_UNAVAILABLE")
		end
		local current, err = refresh(personal)
		if not current then
			return pending(err)
		end
		local binding = Ledger.canonical({ action = "survival-coop:attack", args = { req.targetId } })
		local epoch = current.data.envelope.commands.epochs[tostring(req.sessionEpoch)]
		local known = epoch and epoch.outcomes[req.requestId]
		if known then
			if known.binding ~= binding then
				return rejected("REQUEST_CONFLICT")
			end
			err = update(function(data)
				local active = data.actors[req.actorId]
				local accepted = if active then data.intents[active] else nil
				if
					accepted
					and accepted.request.requestId == req.requestId
					and accepted.request.sessionEpoch == req.sessionEpoch
				then
					accepted.phase, accepted.result = "FINALIZED", copy(known.result)
					data.actors[req.actorId] = nil
				end
				return data
			end)
			if err then
				return pending(err)
			end
			return if config.now() < known.expiresAt then copy(known.result) else rejected("REQUEST_EXPIRED")
		end
		err = update(function(data)
			return data
		end)
		if err then
			return pending(err)
		end
		local id = string.format("w%d:%s:%d:%s", #req.actorId, req.actorId, req.sessionEpoch, req.requestId)
		if #id > 100 then
			return rejected("INVALID_COMBAT_ID")
		end
		local intent = source.data.intents[id]
		if intent then
			if intent.commandBinding ~= binding then
				return rejected("REQUEST_CONFLICT")
			end
			if intent.result then
				return if config.now() < intent.request.expiresAt
					then copy(intent.result)
					else rejected("REQUEST_EXPIRED")
			end
			return progress(id, personal)
		end
		if not epoch or config.now() >= epoch.expiresAt then
			return rejected("REQUEST_EXPIRED")
		end
		local count = 0
		for _ in epoch.outcomes do
			count += 1
		end
		if count >= config.maxReceipts then
			return rejected("REQUEST_WINDOW_FULL")
		end
		if source.data.actors[req.actorId] then
			return pending("COMBAT_PENDING")
		end
		local admission = admit()
		if not admission.ok then
			return admission
		end
		local refusal: string? = nil
		err = update(function(data)
			refusal = nil
			if data.intents[id] then
				return data
			end
			local size = 0
			for _ in data.intents do
				size += 1
			end
			if size >= config.maxReceipts then
				refusal = "RECEIPT_LIMIT"
				return data
			end
			if data.actors[req.actorId] or data.locks[req.targetId] then
				refusal = "COMBAT_PENDING"
				return data
			end
			local npc = data.npcs[req.targetId]
			if not npc then
				refusal = "UNKNOWN_TARGET"
				return data
			end
			local access = config.access(req.actorId, req.targetId)
			if not access or access.actorId ~= req.actorId then
				refusal = "UNAUTHORIZED"
				return data
			end
			local player = current.data.envelope.genres["survival-coop"].data
			local bag = Inventory.fromSave(player.inventory[config.carriedContainer], items)
			local at = config.nowMillis()
			local candidate, reason =
				Wildlife.attack(npc, bag, policy, at, if player.combat then player.combat.nextAttack else 0, access)
			if not candidate then
				refusal = reason
				return data
			end
			local itemId: string? = nil
			for key, item in candidate.inventory.items do
				if item.durabilityMilli ~= bag.items[key].durabilityMilli then
					itemId = key
					break
				end
			end
			local selected = bag.items[assert(itemId, "MISSING_WEAR")]
			local weapon = policy.weapons[selected.catalogId]
			data.intents[id] = {
				request = req,
				binding = id .. binding,
				commandBinding = binding,
				acceptedAt = config.now(),
				phase = "INTENT",
				destination = current.key,
				npcVersion = npc.version,
				at = at,
				itemId = selected.itemId,
				weaponId = selected.catalogId,
				damage = weapon.damageMilli,
				wear = weapon.wearMilli,
				cooldown = weapon.cooldownMillis,
				drops = copy(policy.species[npc.catalogId].drops),
			}
			data.locks[req.targetId], data.actors[req.actorId] = id, id
			return data
		end)
		if err then
			return pending(err)
		end
		if refusal then
			return rejected(refusal)
		end
		return progress(id, personal)
	end
	function runtime.recover(actor: string, maximum: number): Shared.Result
		assert(maximum >= 1 and maximum <= 64 and maximum % 1 == 0, "INVALID_RECOVERY_BOUND")
		-- `source` is this session's fenced profile and every write in this
		-- process flows through update(); the identity refresh this used to do
		-- cost one HttpService read per sweep for data that is already current.
		local id = source.data.actors[actor]
		if not id then
			return { ok = true, data = { status = "confirmed" } }
		end
		local personal = config.resolvePersonal(actor)
		return if personal then progress(id, personal) else pending("PERSONAL_UNAVAILABLE")
	end
	function runtime.snapshot(): (Fenced.Data?, string?)
		-- Same reasoning as recover(): no durable round-trip to read our own
		-- current profile.
		return copy(source.data.npcs), nil
	end
	return runtime, nil
end
return M
