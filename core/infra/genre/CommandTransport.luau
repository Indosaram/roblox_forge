--!strict
-- Shared by the real RemoteFunction ingress and starter client request owner.
local M = {}
function M.durable(policy: any, action: any): boolean
	return policy ~= nil and type(action) == "string" and table.find(policy.actions, action) ~= nil
end
function M.invoke(session: any, policy: any, actor: string, action: any, args: any): (any, any?)
	if action == "command" then
		return session.command(actor, args)
	end
	if M.durable(policy, action) then
		return { ok = false, reason = "DURABLE_COMMAND_REQUIRED" }
	end
	return session.dispatch(actor, action, args)
end
function M.request(previous: any, action: string, args: { any }, epoch: number, newId: () -> string): any
	if previous ~= nil then
		return previous
	end
	return { requestId = newId(), sessionEpoch = epoch, action = action, args = table.clone(args) }
end
function M.settle(previous: any, result: any): any
	-- Only a persisted outcome or an explicit expired epoch ends this request.
	-- Transport errors and transient refusals must never allocate another ID.
	if type(result) == "table" and (result.stateVersion ~= nil or result.reason == "REQUEST_EXPIRED") then
		return nil
	end
	return previous
end
return M
