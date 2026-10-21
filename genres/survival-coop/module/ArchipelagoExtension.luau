--!strict
local Archipelago = require("../../../core/domain/island/Archipelago")
local M = {}

-- store.transaction(actor, transform) must fence the actor lease and durably
-- commit before returning. verify resolves an opaque operation ID, not remote
-- supplied facts. returnHome uses Session's durable handoff, leaving bag intact.
function M.new(env: any): any
	local function change(actor: string, transform: any): any
		return env.store.transaction(actor, transform)
	end
	return {
		open = function(actor: string, options: any): any
			return change(actor, function(document): any
				if document.archipelago and document.archipelago.status == "active" then
					return { ok = false, reason = "expedition_active" }
				end
				local input = table.clone(options)
				input.actor = actor
				local state, reason = Archipelago.open(env.content, input, env.facts(actor), env.now())
				if state then
					document.archipelago = state
				end
				return { ok = state ~= nil, reason = reason }
			end)
		end,
		objective = function(actor: string, operationId: string): any
			return change(actor, function(document): any
				local receipt = env.verify(actor, operationId)
				if not receipt then
					return { ok = false, reason = "unverified_objective" }
				end
				if not document.archipelago then
					return { ok = false, reason = "missing_expedition" }
				end
				local ok, reason = Archipelago.record(document.archipelago, env.content, receipt, env.now())
				return { ok = ok, reason = reason }
			end)
		end,
		nextIsland = function(actor: string): any
			return change(actor, function(document): any
				if not document.archipelago then
					return { ok = false, reason = "missing_expedition" }
				end
				local ok, reason =
					Archipelago.advance(document.archipelago, env.content, env.facts(actor), env.now(), env.entryBuffer)
				return { ok = ok, reason = reason }
			end)
		end,
		recover = function(actor: string, cause: string): any
			local result = change(actor, function(document): any
				if not document.archipelago then
					return { ok = false, reason = "missing_expedition" }
				end
				return { ok = true, destination = Archipelago.recover(document.archipelago, env.now(), cause) }
			end)
			if result.ok and result.destination == "home" then
				return env.returnHome(actor)
			end
			return result
		end,
	}
end
return M
