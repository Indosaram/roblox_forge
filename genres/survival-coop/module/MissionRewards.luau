--!strict
-- A durable expedition outbox is acknowledged only after the personal fenced
-- aggregate records the reward and its receipt in the same update.
local SkillTree = require("../../../core/domain/progression/SkillTree")
local Journal = require("../../../core/domain/command/Journal")
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

-- Guide completion rewards (xp, coins) ride the same outbox: one entry per guide
-- definition keyed "guide:<id>", settled under the personal receipt of that id, so a
-- replayed or re-enqueued guide pays nothing. Guide items are not paid here.
function M.guideId(guideId: string): string
	return "guide:" .. guideId
end

function M.enqueueGuide(document: any, guide: any)
	local rewards = guide.rewards or {}
	if (rewards.xp or 0) == 0 and (rewards.coins or 0) == 0 then
		return
	end
	document.missionRewards = document.missionRewards or {}
	local id = M.guideId(guide.id)
	if document.missionRewards[id] == nil then
		document.missionRewards[id] = {
			rewards = { xp = rewards.xp or 0, coins = rewards.coins or 0, reputation = {} },
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
