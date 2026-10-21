--!strict
-- The personal store must be the authoritative wallet aggregate, not a side ledger.
local Match = require("../../../core/domain/brawl/Match")
local Data = require("../../../core/domain/genre/SerializedData")
local M = {}

function M.new(env: any): any
	local api = {}
	function api.transaction(actor: string, transform: any): any
		local result: any = nil
		local ok, saved = pcall(function()
			return env.store:UpdateAsync(env.key(actor), function(old: any): any
				result = nil
				if not old then
					result = { ok = false, reason = "PROFILE_MISSING" }
					return nil
				end
				if not env.authorize(old, actor) then
					result = { ok = false, reason = "PERSONAL_LOCKED" }
					return nil
				end
				local candidate = Data.clone(old)
				-- select returns the survival slice inside the existing personal envelope.
				result = transform(env.select(candidate))
				return if result.ok then candidate else nil
			end)
		end)
		if not ok then
			return { ok = false, reason = "PERSONAL_COMMIT_FAILED" }
		end
		if not result or (result.ok and not saved) then
			return { ok = false, reason = "PERSONAL_UNCONFIRMED" }
		end
		return result
	end
	function api.claim(actor: string, match: any, utc: number): any
		return api.transaction(actor, function(document: any): any
			return Match.reward(document, match, actor, utc)
		end)
	end
	return api
end

return M
