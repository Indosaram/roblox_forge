--!strict
-- The appearance port must apply the actual saddle/trim or cloak/banner, not an ownership flag.
local M = {}
function M.new(config: any): any
	local selected: { [string]: string } = {}
	local api = {}
	function api.select(actor: string, skin: any): any
		if type(skin) ~= "string" or not config.supported(skin) then
			return { ok = false, reason = "SKIN_UNSUPPORTED" }
		end
		if not config.owns(actor, skin) then
			return { ok = false, reason = "SKIN_NOT_OWNED" }
		end
		local applied, reason = config.apply(actor, skin)
		if not applied then
			return { ok = false, reason = reason or "APPEARANCE_UNAVAILABLE" }
		end
		selected[actor] = skin
		return { ok = true, data = { skin = skin } }
	end
	function api.resync(actor: string): any
		local skin = selected[actor]
		if skin == nil then
			return { ok = true }
		end
		if not config.owns(actor, skin) then
			local cleared, reason = config.clear(actor)
			if not cleared then
				return { ok = false, reason = reason or "APPEARANCE_UNAVAILABLE" }
			end
			selected[actor] = nil
			return { ok = true }
		end
		return api.select(actor, skin)
	end
	function api.snapshot(actor: string): any
		return { skin = selected[actor] }
	end
	return api
end
return M
