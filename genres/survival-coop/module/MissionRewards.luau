--!strict
-- A durable expedition outbox is acknowledged only after the personal fenced
-- aggregate records the reward and its receipt in the same update.
local SkillTree = require("../../../core/domain/progression/SkillTree")
local Journal = require("../../../core/domain/command/Journal")
local Inventory = require("../../../core/domain/inventory/Inventory")
local ItemCatalog = require("../../../core/domain/inventory/ItemCatalog")
local Job = require("../../../core/domain/crafting/Job")
local M = {}

-- A mission pays once when every one of its objectives is complete in an
-- expedition (never once per objective). The document is the player's own
-- expedition record, so the outbox key (expedition, revision, mission) is
-- idempotent per player and mission run. The first clear of a mission
-- definition pays the full catalog reward; later clears in new expeditions pay
-- REPEAT_PERMILLE (20%) of xp, coins and reputation, floored. Development is
-- once per definition and owned by ArchipelagoExtension, which records it in
-- development.definitions after this runs, so that ledger marks a prior clear.
M.REPEAT_PERMILLE = 200

--- Mid-game XP for a repeat clear: missionPolicy.repeatXPPerLevel per character level while
--- the level is inside [repeatXPMinLevel, repeatXPMaxLevel]; 0 outside it or when unset.
--- Read at settlement from the committed level, so a replay settles nothing new.
function M.repeatBonus(content: any, level: number): number
	local policy = content.missionPolicy or {}
	local perLevel = policy.repeatXPPerLevel or 0
	if level < (policy.repeatXPMinLevel or 1) or level > (policy.repeatXPMaxLevel or 0) then
		return 0
	end
	return perLevel * level
end

local function share(rewards: any, permille: number): any
	if permille == 1000 then
		return rewards
	end
	local reputation = {}
	for _, entry in rewards.reputation or {} do
		local scaled = table.clone(entry)
		scaled.value = (entry.value * permille) // 1000
		table.insert(reputation, scaled)
	end
	return {
		xp = ((rewards.xp or 0) * permille) // 1000,
		coins = ((rewards.coins or 0) * permille) // 1000,
		reputation = reputation,
	}
end

-- Guide completion rewards (xp, coins, items) ride the same outbox: one entry per guide
-- definition keyed "guide:<id>", settled under the personal receipt of that id, so a
-- replayed or re-enqueued guide pays nothing. Items land in the personal bag in the same
-- personal write as the xp/coins receipt.
function M.guideId(guideId: string): string
	return "guide:" .. guideId
end

function M.enqueueGuide(document: any, guide: any)
	local rewards = guide.rewards or {}
	local items = {}
	for _, stack in rewards.items or {} do
		if stack.quantity > 0 then
			table.insert(items, { item = stack.item, quantity = stack.quantity })
		end
	end
	if (rewards.xp or 0) == 0 and (rewards.coins or 0) == 0 and #items == 0 then
		return
	end
	document.missionRewards = document.missionRewards or {}
	local id = M.guideId(guide.id)
	if document.missionRewards[id] == nil then
		document.missionRewards[id] = {
			rewards = { xp = rewards.xp or 0, coins = rewards.coins or 0, reputation = {}, items = items },
			mission = guide.id,
			repeatClear = false,
			settled = false,
		}
	end
end

function M.enqueue(document: any, content: any)
	local state = document.archipelago
	if not state then
		return
	end
	document.missionRewards = document.missionRewards or {}
	local cleared = if document.development then document.development.definitions else {}
	for _, mission in content.missions do
		local completed = #mission.objectives > 0
		for _, objective in mission.objectives do
			completed = completed and state.completed[objective.id] == true
		end
		local id = "mission:" .. Journal.fnv1a64(state.id .. ":" .. state.revision .. ":" .. mission.id)
		if completed and mission.rewards and not document.missionRewards[id] then
			local repeatClear = cleared[mission.id] == true
			document.missionRewards[id] = {
				rewards = share(mission.rewards, if repeatClear then M.REPEAT_PERMILLE else 1000),
				mission = mission.id,
				repeatClear = repeatClear,
				settled = false,
			}
		end
	end
end

-- Results ledger (inbox-compatible): one entry per finished expedition with the totals its
-- missions paid. Settlement above already applies the rewards; Claim acknowledges the entry.
M.LEDGER_LIMIT = 10
function M.ledger(document: any, content: any)
	local state = document.archipelago
	if not state or state.status == "active" then
		return
	end
	local ledger = document.resultsLedger or {}
	document.resultsLedger = ledger
	if ledger[state.id] then
		return
	end
	local coins, xp = 0, 0
	for _, mission in content.missions do
		local entry = (document.missionRewards or {})["mission:" .. Journal.fnv1a64(
			state.id .. ":" .. state.revision .. ":" .. mission.id
		)]
		if entry then
			coins += entry.rewards.coins or 0
			xp += entry.rewards.xp or 0
		end
	end
	local count = 0
	for id, row in ledger do
		count += 1
		if count >= M.LEDGER_LIMIT and row.claimed then
			ledger[id] = nil
		end
	end
	ledger[state.id] = {
		id = state.id,
		source = "expedition:" .. state.templateId,
		items = {},
		coins = coins,
		xp = xp,
		claimed = false,
	}
end

function M.claim(document: any, id: string): (boolean, string?)
	local row = if document and document.resultsLedger then document.resultsLedger[id] else nil
	if not row then
		return false, "ledger_missing"
	end
	if row.claimed then
		return false, "ledger_claimed"
	end
	row.claimed = true
	return true, nil
end

-- Adds reward stacks to the bag at `path` inside a personal view (copy-on-write).
-- Item ids derive from the receipt id, so one receipt can never mint the same stack twice.
local function grantItems(view: any, path: { string }, content: any, id: string, items: { any }): string?
	local parent = view.envelope
	for index = 1, #path - 1 do
		parent = parent[path[index]]
	end
	local catalog = Job.catalog(content)
	local loaded, bag = pcall(Inventory.fromSave, parent[path[#path]], catalog)
	if not loaded then
		return "BAG_UNAVAILABLE"
	end
	local inventory = bag :: Inventory.State
	for index, granted in items do
		local definition = catalog[granted.item]
		if not definition then
			return "UNKNOWN_ITEM"
		end
		local remaining, part = granted.quantity, 0
		-- Top up an existing plain stack first so a reward does not cost a bag slot it can share.
		local stackIds: { string } = {}
		for itemId, item in inventory.items do
			-- A plain stack (no material, latent or repair history) of the same item takes reward units.
			local plain = item.catalogId == granted.item
				and item.material == nil
				and item.latent == nil
				and item.maxDurabilityMilli == nil
				and (definition.maxDurabilityMilli or 0) == 0
			if
				plain
				and item.quantity < definition.stackMax
				and Inventory.available(inventory, itemId) == item.quantity
			then
				table.insert(stackIds, itemId)
			end
		end
		table.sort(stackIds)
		for _, stackId in stackIds do
			local room = math.min(definition.stackMax - inventory.items[stackId].quantity, remaining)
			if room > 0 then
				local topped = Inventory.snapshot(inventory)
				topped.items[stackId].quantity += room
				topped.version += 1
				inventory = topped
				remaining -= room
			end
		end
		while remaining > 0 do
			part += 1
			local count = math.min(definition.stackMax, remaining)
			local added, err = Inventory.add(inventory, catalog, {
				itemId = string.format("%s:%d:%d", id, index, part),
				catalogId = granted.item,
				quantity = count,
				qualityMilli = 1000,
				durabilityMilli = ItemCatalog.durabilityCeiling(definition, 1000),
				attributes = {},
			}, inventory.version)
			if not added then
				return if err == "INVALID_ITEM" or err == "DUPLICATE_ITEM_ID" then err else "BAG_FULL"
			end
			inventory = added
			remaining -= count
		end
	end
	parent[path[#path]] = Inventory.save(inventory)
	return nil
end

function M.settle(actor: string, env: any): any
	local document, reason = env.store.snapshot(actor)
	if not document then
		return { ok = false, reason = reason }
	end
	local pending = false
	for _, entry in document.missionRewards or {} do
		pending = pending or not entry.settled
	end
	if not pending then
		return { ok = true }
	end
	local port = env.personal(actor)
	if not port then
		return { ok = false, reason = "PERSONAL_UNAVAILABLE" }
	end
	local ids = {}
	for id in document.missionRewards or {} do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local entry = document.missionRewards[id]
		if not entry.settled then
			local refused: string? = nil
			local updated, err = port.personal:update(port.profile(), function(view)
				refused = nil
				if view.itemTransfers.receipts[id] then
					return view
				end
				local data: any = view.envelope.genres["survival-coop"].data
				local rewards: any = entry.rewards
				if data.balance + (rewards.coins or 0) > 1000000000 then
					refused = "WALLET_FULL"
					return view
				end
				if rewards.items and #rewards.items > 0 then
					-- The bag is written only after every stack fits, so a refusal keeps the view intact.
					refused = grantItems(view, port.personal:inventoryPath(), env.content, id, rewards.items)
					if refused then
						return view
					end
				end
				data.balance += rewards.coins or 0
				local progression = SkillTree.copy(data.progression)
				local policy = env.content.progressionPolicy.tree
				local bonus = if entry.repeatClear then M.repeatBonus(env.content, progression.level) else 0
				local xp = (progression.xp or 0) + (rewards.xp or 0) + bonus
				while progression.level < policy.maxLevel do
					local required = policy.xpBase + policy.xpStep * progression.level
					if xp < required then
						break
					end
					xp -= required
					progression.level += 1
					progression.sp += policy.spPerLevel
				end
				progression.xp, progression.version = xp, progression.version + 1
				data.progression = progression
				-- Reputation is an expedition-owned ledger, applied with the outbox
				-- acknowledgement below; it is not contract-board trust.
				view.itemTransfers.receipts[id] = { phase = "APPLIED" }
				return view
			end)
			if not updated then
				return { ok = false, reason = err }
			end
			port.install(updated)
			if refused then
				return { ok = false, reason = refused }
			end
			local result = env.store.transaction(actor, function(current)
				local reward: any = current.missionRewards[id]
				if not reward.settled then
					current.reputation = current.reputation or {}
					for _, reputation in reward.rewards.reputation or {} do
						current.reputation[reputation.id] = (current.reputation[reputation.id] or 0) + reputation.value
					end
					reward.settled = true
				end
				return { ok = true }
			end)
			if not result.ok then
				return result
			end
		end
	end
	return { ok = true }
end
return M
