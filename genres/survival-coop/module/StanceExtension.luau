--!strict
-- Combat stance selector (catalog ui.combat: six-stance selector, 2 s cooldown, windup lock).
-- `stance-set <id|none>` validates against Stance rules and the actor's learned nodes and writes
-- the personal slice's `stance` in one atomic personal update. Wildlife strikes read it for the
-- outgoing scale, CraftingAdapter for incoming damage and movement speed.
local Shared = require("../../../core/domain/genre/Contract")
local Stance = require("./Stance")
local Data = require("../../../core/domain/genre/SerializedData")

local M = {}
M.ACTION = "survival-coop:stance-set"
local GENRE = "survival-coop"

function M.actions(): { any }
	local Schema = require("../../../core/infra/net/Schema")
	local ids = table.clone(Stance.IDS)
	table.insert(ids, "none")
	return {
		-- Ranged PvE shot (served by WildlifeBridge, like attack): target id only.
		{
			id = "attack-ranged",
			args = { Schema.string({ maxLen = 128, pattern = ".+" }) },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "stance-set",
			args = { Schema.enum(ids) },
			origin = "client",
			rate = { capacity = 2, refillPerSecond = 1 },
		},
	}
end

--- Pure transition on a personal slice at `now` (milliseconds).
function M.apply(slice: any, stance: string, now: number): (any?, string?)
	local combat = slice.combat or {}
	-- nextAttack holds windup + recovery; only the windup part locks a switch.
	local windupUntil = combat.windupUntil or 0
	local nextState, reason = Stance.select(slice.stance, slice.progression, stance, now, windupUntil)
	if not nextState then
		return nil, reason
	end
	local result = table.clone(slice)
	result.stance = nextState
	return result, nil
end

function M.factory(ctx: any): (Shared.Extension & { close: (() -> Shared.Result)? })?
	if not ctx.content.progressionPolicy or not ctx.content.progressionPolicy.combat then
		return nil
	end
	return {
		id = "stance",
		handles = function(action: string): boolean
			return action == M.ACTION
		end,
		command = function(actor, _action, args, _context, _origin, admit): Shared.Result
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local port = ctx.personalTransfer(actor)
			if not port then
				return { ok = false, reason = "PERSONAL_UNAVAILABLE" }
			end
			local now = math.floor(ctx.now() * 1000)
			local outcome: Shared.Result = { ok = false, reason = "STANCE_FAILED" }
			local token, err = port.personal:update(port.profile(), function(view)
				local work = Data.clone(view)
				local genre = work.envelope.genres[GENRE]
				local nextSlice, reason = M.apply(genre.data, args[1], now)
				if not nextSlice then
					outcome = { ok = false, reason = reason }
					return view
				end
				genre.data = nextSlice
				outcome = { ok = true, data = { stance = nextSlice.stance.id } }
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
			local unlocked = {}
			for _, id in Stance.IDS do
				local node = Stance.NODES[id]
				unlocked[id] = slice.progression ~= nil and slice.progression.paid[node] ~= nil
			end
			return {
				current = if slice.stance then slice.stance.id else "none",
				changedAt = if slice.stance then slice.stance.changedAt else nil,
				cooldownMillis = Stance.SWITCH_MILLIS,
				unlocked = unlocked,
			} :: any,
				nil
		end,
	} :: any
end

return M
