--!strict
-- Down-and-rescue commands (Robango plan C6, G19; ui-spec 6.5). Opt-in: the factory returns nil
-- unless the host world carries a `rescue` port, so packs without one keep the immediate respawn.
--   rescue-choose <rift|camp|rescue|get-up>   a downed actor picks a way back (or sends a flare)
--   rescue-revive <actorId>                  a nearby living player helps a flaring actor up
-- The rules live in Rescue (explicit clock); this module only reads trusted server facts (durable
-- vitals, live root positions, the role) and installs `world.downHold` so SurvivalWorld holds the
-- downed character until a choice lands. Nothing here touches inventory: penalties stay with the
-- existing death-zone rules in CraftingAdapter.
local Shared = require("../../../core/domain/genre/Contract")
local Rescue = require("./Rescue")

local M = {}
M.CHOOSE = "survival-coop:rescue-choose"
M.REVIVE = "survival-coop:rescue-revive"
local OPTIONS = { "rift", "camp", "rescue", "get-up" }

-- Trusted world facts the host supplies as `world.rescue`.
export type Port = {
	-- Live root position of a member, or nil when it has no character in the world.
	position: (actor: string) -> { x: number, y: number, z: number }?,
	-- Durable health of a member (milli), or nil when not joined.
	health: (actor: string) -> number?,
	-- True in roles where only "get-up" is offered (town, home).
	safe: () -> boolean,
	-- Where "camp" wakes the actor (nearest camp fire); nil falls back to the spawn.
	camp: (actor: string) -> any?,
	-- Display name for the flare line.
	name: (actor: string) -> string,
	policy: Rescue.Policy?,
	-- false: no flare card (single-player mode: nobody else can answer one). Default true.
	flares: boolean?,
}

function M.actions(): { any }
	local Schema = require("../../../core/infra/net/Schema")
	return {
		{
			id = "rescue-choose",
			args = { Schema.enum(OPTIONS) },
			origin = "client",
			rate = { capacity = 4, refillPerSecond = 1 },
		},
		{
			id = "rescue-revive",
			args = { Schema.string({ maxLen = 32, pattern = "^%d+$" }) },
			origin = "client",
			rate = { capacity = 4, refillPerSecond = 1 },
		},
	}
end

--- The cards a downed actor sees: Rescue.options without the flare when the port turns flares off.
function M.options(port: Port): { string }
	local options = Rescue.options(port.safe())
	if port.flares == false then
		local index = table.find(options, "rescue")
		if index then
			table.remove(options, index)
		end
	end
	return options
end

--- Builds the extension over a trusted port and a millisecond clock. Also returns the
--- SurvivalWorld down-hold callbacks (assigned to `world.downHold`; wake points are { x, y, z }).
function M.new(port: Port, nowMillis: () -> number, members: () -> { string }): (any, any)
	local state = Rescue.new(port.policy)
	local function down(actor: string): boolean
		return port.health(actor) == 0
	end
	local extension = {
		id = "rescue",
		handles = function(action: string): boolean
			return action == M.CHOOSE or action == M.REVIVE
		end,
		command = function(actor, action, args, _context, _origin, admit): Shared.Result
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local now = nowMillis()
			if action == M.CHOOSE and args[1] == "rescue" and port.flares == false then
				return { ok = false, reason = "INVALID_OPTION" }
			end
			if action == M.CHOOSE then
				local ok, reason =
					Rescue.choose(state, actor, args[1], down(actor), port.safe(), port.position(actor), now)
				return if ok then { ok = true, data = { option = args[1] } } else { ok = false, reason = reason }
			end
			local target = args[1]
			if type(target) ~= "string" or not table.find(members(), target) then
				return { ok = false, reason = "NO_REQUEST" }
			end
			local health = port.health(actor)
			local ok, reason = Rescue.revive(
				state,
				actor,
				target,
				port.position(actor),
				health ~= nil and health > 0,
				down(target),
				now
			)
			return if ok then { ok = true, data = { revived = target } } else { ok = false, reason = reason }
		end,
		snapshot = function(actor: string): (Shared.StateData?, string?)
			local now = nowMillis()
			Rescue.expire(state, now)
			local flares = {}
			for _, flare in Rescue.flares(state, actor, port.position(actor), now) do
				table.insert(flares, {
					id = flare.id,
					name = port.name(flare.id),
					x = math.floor(flare.position.x + 0.5),
					y = math.floor(flare.position.y + 0.5),
					z = math.floor(flare.position.z + 0.5),
					remainingMillis = flare.remainingMillis,
					reachable = flare.distance <= state.policy.reviveStuds,
				})
			end
			local choice = state.choices[actor]
			return {
				down = down(actor),
				options = M.options(port),
				choice = if choice then choice.option else nil,
				waitingMillis = Rescue.waiting(state, actor, now),
				windowMillis = state.policy.windowMillis,
				flares = flares,
			},
				nil
		end,
	}
	-- SurvivalWorld down hold: hold while undecided, then wake at the chosen place.
	local hold = {
		-- Extension entries may only carry callbacks (Options.validateExtensions); specs read state here.
		state = state,
		holdSeconds = math.ceil((state.policy.idleMillis + state.policy.windowMillis) / 1000) + 60,
		decide = function(actor: string): { at: any? }?
			local now = nowMillis()
			for _, id in Rescue.actors(state) do
				if not table.find(members(), id) then
					Rescue.settle(state, id)
				end
			end
			local choice = Rescue.decide(state, actor, now, port.safe())
			if not choice then
				return nil
			end
			if choice.option == "revive" and choice.position then
				return { at = choice.position }
			elseif choice.option == "camp" then
				return { at = port.camp(actor) }
			end
			return { at = nil }
		end,
		settle = function(actor: string)
			Rescue.settle(state, actor)
		end,
	}
	return extension, hold
end

--- Registry factory: active only when the host world exposes a `rescue` port.
function M.factory(ctx: any): any
	local world = ctx.world
	local port = if world then world.rescue else nil
	if type(port) ~= "table" then
		return nil
	end
	local extension, hold = M.new(port, ctx.nowMillis, ctx.members)
	world.downHold = hold
	return extension
end

return M
