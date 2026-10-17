--!strict
-- Death-zone command for survival-coop. The server validates a request to enter or leave the
-- "danger" zone and records it in the actor's saved Vitals through the personal aggregate, the same
-- route transfers use. CraftingAdapter then reads `Vitals.deathPolicy` at death, so "safe" keeps the
-- existing rule and "danger" takes the DeathBundle drop path. This module owns no death logic.
local Shared = require("../../../core/domain/genre/Contract")
local Vitals = require("../../../core/domain/survival/Vitals")

local M = {}

local SET = "survival-coop:zone-set"
local GENRE = "survival-coop"

local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = clone(item)
	end
	return copy
end

local function vitalsOf(envelope: any): any
	local slice = if type(envelope) == "table" and type(envelope.genres) == "table" then envelope.genres[GENRE] else nil
	return if slice and type(slice.data) == "table" then slice.data.vitals else nil
end

function M.factory(ctx: { personalTransfer: (string) -> any? }): (Shared.Extension & { close: (() -> Shared.Result)? })?
	local extension = {
		id = "death-zone",
		handles = function(action: string): boolean
			return action == SET
		end,
		command = function(actor, _action, args, _context, _origin, admit): Shared.Result
			local zone = args[1]
			if zone ~= "safe" and zone ~= "danger" then
				return { ok = false, reason = "INVALID_ZONE" }
			end
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local port = ctx.personalTransfer(actor)
			if not port then
				return { ok = false, reason = "ZONE_UNAVAILABLE" }
			end
			local token = port.profile()
			local vitals = vitalsOf(token.data.envelope)
			if type(vitals) ~= "table" or vitals.zone == nil then
				return { ok = false, reason = "ZONE_NOT_CONFIGURED" }
			end
			if vitals.healthMilli == 0 or vitals.online ~= true then
				return { ok = false, reason = "NOT_ALIVE" }
			end
			if vitals.zone == zone then
				return { ok = true, data = { zone = zone } }
			end
			local changed, next = pcall(Vitals.setZone, clone(vitals), zone)
			if not changed then
				return { ok = false, reason = "NOT_ALIVE" }
			end
			local candidate = clone(token.data.envelope)
			candidate.genres[GENRE].data.vitals = next
			local committed, reason = port.personal:commit(token, token.data.stateRevision, candidate, nil)
			if not committed or reason then
				return { ok = false, reason = reason or "SAVE_FAILED" }
			end
			local current = port.personal:refresh(committed)
			if not current then
				return { ok = false, reason = "SAVE_FAILED" }
			end
			port.install(current)
			return { ok = true, data = { zone = zone } }
		end,
		snapshot = function(actor: string): (Shared.StateData?, string?)
			local port = ctx.personalTransfer(actor)
			if not port then
				return nil, "ZONE_UNAVAILABLE"
			end
			local vitals = vitalsOf(port.profile().data.envelope)
			if type(vitals) ~= "table" or vitals.zone == nil then
				return nil, "ZONE_NOT_CONFIGURED"
			end
			return { zone = vitals.zone, alive = vitals.healthMilli > 0 }, nil
		end,
	}
	return extension :: any
end

return M
