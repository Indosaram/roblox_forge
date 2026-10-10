--!strict
-- Server-only routing; owns no player inventory, tribe state or command ledger.
local Runtime = require("./SettlementRuntime")
local Shared = require("../../../core/domain/genre/Contract")
local M = {}
local ACTIONS: { [string]: string } = {
	["survival-coop:settlement-workshop-reserve"] = "workshop-reserve",
	["survival-coop:settlement-workshop-start"] = "workshop-start",
	["survival-coop:settlement-workshop-complete"] = "workshop-complete",
	["survival-coop:settlement-workshop-cancel"] = "workshop-cancel",
	["survival-coop:settlement-invite"] = "invite",
	["survival-coop:settlement-leave"] = "leave",
	["survival-coop:settlement-kick"] = "kick",
	["survival-coop:settlement-transfer-owner"] = "transfer-owner",
	["survival-coop:settlement-rejoin"] = "rejoin",
	["survival-coop:settlement-reserve"] = "reserve",
	["survival-coop:settlement-place"] = "place",
	["survival-coop:settlement-cancel"] = "cancel",
	["survival-coop:settlement-demolish"] = "demolish",
}
export type Origin = "client" | "server"
export type Config = {
	-- Resolve only through server-owned player links, never request payloads.
	resolve: (string) -> Runtime.Runtime?,
	-- Shared Executor origin/schema validation and server spatial policy. This
	-- check is non-mutating; rate admission is supplied separately per command.
	authorize: (string, string, { any }, Origin) -> Shared.Result,
}
export type Bridge = {
	handles: (string) -> boolean,
	epoch: (string, string) -> (number?, string?),
	command: (string, string, { any }, Shared.CommandContext, Origin, (() -> Shared.Result)?) -> Shared.Result,
	snapshot: (string) -> (Shared.StateData?, string?),
	link: (string) -> { tribeId: string }?,
}
function M.new(config: Config): Bridge
	local bridge = {} :: Bridge
	function bridge.handles(action)
		return ACTIONS[action] ~= nil
	end
	function bridge.epoch(actor, action)
		if not bridge.handles(action) then
			return nil, "UNKNOWN_ACTION"
		end
		local runtime = config.resolve(actor)
		if not runtime then
			return nil, "SETTLEMENT_UNAVAILABLE"
		end
		return runtime.epoch(actor)
	end
	function bridge.command(actor, action, args, context, origin, admit)
		local mapped = ACTIONS[action]
		if not mapped then
			return { ok = false, reason = "UNKNOWN_ACTION" }
		end
		if context.actorId ~= actor then
			return { ok = false, reason = "FORBIDDEN" }
		end
		if origin ~= "client" and origin ~= "server" then
			return { ok = false, reason = "INVALID_ORIGIN" }
		end
		local authorized = config.authorize(actor, action, args, origin)
		if not authorized.ok then
			return authorized
		end
		local runtime = config.resolve(actor)
		if not runtime then
			return { ok = false, reason = "SETTLEMENT_UNAVAILABLE" }
		end
		return runtime.command(actor, mapped, args, context, { origin = origin, admit = admit })
	end
	function bridge.snapshot(actor)
		local runtime = config.resolve(actor)
		if not runtime then
			return nil, "SETTLEMENT_UNAVAILABLE"
		end
		local state, err = runtime.snapshot(actor)
		if not state then
			return nil, err
		end
		return {
			settlement = state.settlement,
			warehouse = state.warehouse,
			structureContents = state.structureContents,
			workshops = state.workshops,
		},
			nil
	end
	function bridge.link(actor)
		local runtime = config.resolve(actor)
		if not runtime then
			return nil
		end
		local state = runtime.snapshot(actor)
		if not state then
			return nil
		end
		return runtime.link()
	end
	return bridge
end
return M
