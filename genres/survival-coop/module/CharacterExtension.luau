--!strict
-- Character extension: gear-equip / gear-unequip on the personal slice (one atomic write each)
-- and the read model behind the character, island-rank and equipment screens.
-- Development points come from an optional server-owned port (world.development); never the client.
local Shared = require("../../../core/domain/genre/Contract")
local Rules = require("./CharacterRules")
local Data = require("../../../core/domain/genre/SerializedData")

local M = {}
M.EQUIP = "survival-coop:gear-equip"
M.UNEQUIP = "survival-coop:gear-unequip"
local GENRE = "survival-coop"

function M.actions(): { any }
	local Schema = require("../../../core/infra/net/Schema")
	local id = Schema.string({ maxLen = 128, pattern = ".+" })
	return {
		{ id = "gear-equip", args = { id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "gear-unequip", args = { id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
	}
end

--- Pure transition on a personal slice (balance, inventory.bag, gear). Returns the new slice.
function M.apply(slice: any, action: string, arg: any): (any?, string?)
	if type(arg) ~= "string" or arg == "" then
		return nil, "INVALID_ARGUMENT"
	end
	local bag = slice.inventory and slice.inventory.bag
	if type(bag) ~= "table" then
		return nil, "BAG_UNAVAILABLE"
	end
	local gear = slice.gear or { equipped = {}, equipment = {} }
	local nextGear, reason
	if action == M.EQUIP then
		nextGear, reason = Rules.equip(gear, bag, arg)
	elseif action == M.UNEQUIP then
		nextGear, reason = Rules.unequip(gear, arg)
	else
		return nil, "UNKNOWN_ACTION"
	end
	if not nextGear then
		return nil, reason
	end
	local result = table.clone(slice)
	result.gear = nextGear
	return result, nil
end

function M.factory(ctx: any): (Shared.Extension & { close: (() -> Shared.Result)? })?
	if not ctx.content.progressionPolicy then
		return nil
	end
	local function development(actor: string): any
		local port = ctx.world and ctx.world.development
		return if port then port(actor) else nil
	end
	return {
		id = "character",
		handles = function(action: string): boolean
			return action == M.EQUIP or action == M.UNEQUIP
		end,
		command = function(actor, action, args, _context, _origin, admit): Shared.Result
			if type(args[1]) ~= "string" or args[1] == "" then
				return { ok = false, reason = "INVALID_ARGUMENT" }
			end
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local port = ctx.personalTransfer(actor)
			if not port then
				return { ok = false, reason = "PERSONAL_UNAVAILABLE" }
			end
			local outcome: Shared.Result = { ok = false, reason = "GEAR_FAILED" }
			local token, err = port.personal:update(port.profile(), function(view)
				local work = Data.clone(view)
				local genre = work.envelope.genres[GENRE]
				local nextSlice, reason = M.apply(genre.data, action, args[1])
				if not nextSlice then
					outcome = { ok = false, reason = reason }
					return view
				end
				genre.data = nextSlice
				outcome = { ok = true, data = { equipped = Data.clone(nextSlice.gear.equipped) } }
				return work
			end)
			if not token then
				return { ok = false, reason = err or "SAVE_FAILED" }
			end
			port.install(token)
			return outcome
		end,
		snapshot = function(actor: string): (Shared.StateData?, string?)
			local port = ctx.personalTransfer(actor)
			if not port then
				return nil, "PERSONAL_UNAVAILABLE"
			end
			local slice = port.profile().data.envelope.genres[GENRE].data
			local dev = development(actor) or {}
			return {
				gear = Data.clone(slice.gear or { equipped = {}, equipment = {} }),
				points = dev.points or 0,
				definitions = Data.clone(dev.definitions or {}),
				now = ctx.now(),
			} :: any,
				nil
		end,
	} :: any
end

return M
