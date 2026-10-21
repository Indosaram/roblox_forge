--!strict
local Match = require("../../../core/domain/brawl/Match")
local Data = require("../../../core/domain/genre/SerializedData")
local M = {}
-- match.transaction serializes and durably publishes a candidate only on ok.
-- facts/positions/combat are trusted server ports, never remote-supplied stats.
function M.new(env: any): any
	local function change(transform: any): any
		return env.match.transaction(transform)
	end
	return {
		command = function(actor: string, action: string, args: any): any
			if action == "brawl-reward" then
				local state = env.match.snapshot()
				return env.personal.transaction(actor, function(document)
					return Match.reward(document, state, actor, env.utc())
				end)
			end
			return change(function(state): any
				local ok, reason
				if action == "brawl-queue" then
					ok, reason = Match.join(state, actor, env.facts(actor))
				elseif action == "brawl-leave" then
					ok, reason = Match.leave(state, actor)
				elseif action == "brawl-action" then
					local fact = env.action(actor, args[1], state)
					if not fact then
						return { ok = false, reason = "UNVERIFIED_ACTION" }
					end
					local allowed = Match.action(state, actor, fact.kind, fact.range, env.now())
					if not allowed.ok then
						return allowed
					end
					return env.apply(state, actor, fact, allowed)
				else
					return { ok = false, reason = "UNKNOWN_ACTION" }
				end
				return { ok = ok, reason = reason }
			end)
		end,
		start = function(): any
			return change(function(state)
				local ok, reason = Match.start(state, env.now())
				return { ok = ok, reason = reason }
			end)
		end,
		tick = function(): any
			return change(function(state)
				local positions, damage = env.frame(Data.clone(state))
				local ok, reason = Match.tick(state, env.now(), positions, damage)
				return { ok = ok, reason = reason }
			end)
		end,
		snapshot = function(): any
			return Data.clone(env.match.snapshot())
		end,
	}
end

function M.factory(ctx: any): any
	if not ctx.content.brawlPolicy or not ctx.world or not ctx.world.brawl then
		return nil
	end
	local runtime = assert(ctx.world.brawl.controller, "BRAWL_CONTROLLER_REQUIRED")
	local extension = {
		id = "brawl",
		handles = function(action: string): boolean
			return table.find({
				"survival-coop:brawl-queue",
				"survival-coop:brawl-leave",
				"survival-coop:brawl-action",
				"survival-coop:brawl-reward",
			}, action) ~= nil
		end,
		command = function(actor: string, action: string, args: any, _context: any, _origin: string, admit: any): any
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			return runtime.command(actor, string.sub(action, #"survival-coop:" + 1), args)
		end,
		snapshot = function(): any
			return runtime.snapshot()
		end,
		recover = function(actor: string): any
			local state = runtime.snapshot()
			if state.phase == "queue" then
				if #state.order >= state.policy.minimumPlayers then
					return runtime.start()
				end
				return { ok = true }
			elseif state.phase == "finished" then
				local claimed = runtime.claim(actor)
				if not claimed.ok then
					return claimed
				end
				return runtime.finish()
			end
			local result = runtime.tick()
			return if result.reason == "STALE_TICK" then { ok = true } else result
		end,
		drain = function(): any
			return { ok = true }
		end,
		releaseActor = function(actor: string): any
			local state = runtime.snapshot()
			return if state.actors[actor] and state.phase ~= "finished"
				then runtime.disconnect(actor)
				else { ok = true }
		end,
		resumeActor = function(): any
			return { ok = true }
		end,
		close = runtime.release,
	}
	return require("../../../core/infra/genre/Session").registerLifecycle(extension)
end
return M
