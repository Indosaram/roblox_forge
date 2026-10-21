--!strict
-- documents is the authoritative PERSONAL ActorDocumentStore, not a second ledger.
-- Its document contains journal, progression, balance and missionItems together.
local Data = require("../../../core/domain/genre/SerializedData")
local M = {}

-- Bridge the live Session personal fence to the ActorDocumentStore interface.
-- Never create a second actor namespace for balance/progression/inventory.
function M.personal(session: any): any
	return {
		transaction = function(actor: string, transform: any): any
			local port = session.personalTransfer(actor)
			if not port then
				return { ok = false, reason = "PERSONAL_UNAVAILABLE" }
			end
			local outcome: any = nil
			local token, reason = port.personal:update(port.profile(), function(raw)
				local candidate = Data.clone(raw)
				outcome = transform(candidate.envelope.genres["survival-coop"].data)
				return if outcome.ok then candidate else raw
			end)
			if not token then
				return { ok = false, reason = reason }
			end
			port.install(token)
			return outcome
		end,
		snapshot = function(actor: string): (any?, string?)
			local port = session.personalTransfer(actor)
			return if port then Data.clone(port.profile().data.envelope.genres["survival-coop"].data) else nil,
				if port then nil else "PERSONAL_UNAVAILABLE"
		end,
	}
end

function M.new(documents: any, content: any): any
	local policy = assert(content.progressionPolicy.tree, "PROGRESSION_POLICY_REQUIRED")
	return {
		update = function(actor: string, transform: any): (boolean, string?)
			local result = documents.transaction(actor, function(document)
				local candidate = Data.clone(transform(document))
				for key in document do
					document[key] = nil
				end
				for key, value in candidate do
					document[key] = value
				end
				return { ok = true }
			end)
			return result.ok, result.reason
		end,
		read = documents.snapshot,
		level = function(document: any): number
			return document.progression.level
		end,
		grant = function(document: any, rewards: any, chapter: string): string?
			local found: any = nil
			for _, row in content.chapters do
				if row.id == chapter then
					found = row
				end
			end
			if not found then
				return "UNKNOWN_CHAPTER"
			end
			-- Never trust a caller's reward payload; the generated catalog owns it.
			local reward = found.rewards
			if rewards.coins ~= reward.coins or rewards.xp ~= reward.xp then
				return "REWARD_CONFLICT"
			end
			document.journalGrants = document.journalGrants or {}
			if document.journalGrants[chapter] then
				return nil
			elseif document.balance + reward.coins > 1e9 then
				return "WALLET_FULL"
			end
			local progression = Data.clone(document.progression)
			local xp = (progression.xp or 0) + reward.xp
			while progression.level < policy.maxLevel do
				local required = policy.xpBase + policy.xpStep * progression.level
				if xp < required then
					break
				end
				xp -= required
				progression.sp += policy.spPerLevel
				progression.level += 1
			end
			progression.xp = xp
			progression.version += 1
			document.progression = progression
			document.balance += reward.coins
			-- Quest seals are nontradeable mission-ledger items, never bag stock.
			document.missionItems = document.missionItems or {}
			for _, item in reward.items do
				document.missionItems[item.item] = (document.missionItems[item.item] or 0) + item.quantity
			end
			document.journalGrants[chapter] = true
			return nil
		end,
		evidence = function(): any
			-- JournalObjectiveFeed owns committed events; RPC arguments prove nothing.
			return nil
		end,
	}
end

return M
