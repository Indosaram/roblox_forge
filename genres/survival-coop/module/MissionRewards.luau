--!strict
-- A durable expedition outbox is acknowledged only after the personal fenced
-- aggregate records the reward and its receipt in the same update.
local SkillTree = require("../../../core/domain/progression/SkillTree")
local Journal = require("../../../core/domain/command/Journal")
local M = {}
function M.enqueue(document: any, content: any)
	local state = document.archipelago
	if not state then
		return
	end
	document.missionRewards = document.missionRewards or {}
	for _, mission in content.missions do
		for _, objective in mission.objectives do
			local id = "mission:" .. Journal.fnv1a64(state.id .. ":" .. state.revision .. ":" .. objective.id)
			if state.completed[objective.id] and not document.missionRewards[id] then
				document.missionRewards[id] = { rewards = mission.rewards, objective = objective.id, settled = false }
			end
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
				local xp = (progression.xp or 0) + (rewards.xp or 0)
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
