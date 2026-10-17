--!strict
-- Native authority for the zone-death scenario: the real DeathZoneExtension over the Session's own
-- personal aggregate. Commands, deaths and assertions stay in qaharness; the real CraftingAdapter
-- decides every drop through Vitals.deathPolicy. This fixture only wires the extension to the Session.
local DeathZone = require("../../../../genres/survival-coop/module/DeathZoneExtension")
local Contract = require("../../../../core/domain/genre/Contract")
local Clock = require("../../../../core/infra/genre/Clock")

local M = {}
function M.new(now: () -> number)
	local active: any = nil
	local extension = assert(DeathZone.factory({
		personalTransfer = function(actor: string)
			return if active then active.personalTransfer(actor) else nil
		end,
		nowMillis = function()
			return Clock.millis(now())
		end,
	}))
	local port: any = {
		id = extension.id,
		handles = extension.handles,
		command = extension.command,
		snapshot = extension.snapshot,
	}
	return {
		services = { survivalExtensions = { port } },
		bind = function(session: any)
			active = session
		end,
		close = function(): Contract.Result
			active = nil
			return { ok = true }
		end,
	}
end
return M
