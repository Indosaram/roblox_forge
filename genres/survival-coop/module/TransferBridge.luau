--!strict
-- External Session route; keys, actor, revision and spatial proof are resolved
-- by the trusted host, never selected directly by a remote request.
local Runtime = require("./TransferRuntime")
local Transfer = require("../../../core/infra/data/ItemTransfer")
local Shared = require("../../../core/domain/genre/Contract")
local M = {}
export type Config = {
	resolve: (string) -> Runtime.Runtime?,
	epoch: (string) -> (number?, string?),
	request: (string, string, { any }, Shared.CommandContext, string) -> (Transfer.Request?, number?, any, string?),
}
function M.new(config: Config)
	local bridge = {}
	function bridge.handles(action: string): boolean
		return action == "survival-coop:transfer-deposit" or action == "survival-coop:transfer-withdraw"
	end
	function bridge.epoch(actor: string, _action: string): (number?, string?)
		return config.epoch(actor)
	end
	function bridge.command(
		actor: string,
		action: string,
		args: { any },
		context: Shared.CommandContext,
		origin: "client" | "server",
		admit: (() -> Shared.Result)?
	): Shared.Result
		if not bridge.handles(action) or context.actorId ~= actor then
			return { ok = false, reason = "INVALID_TRANSFER_ROUTE" }
		end
		local runtime = config.resolve(actor)
		if not runtime then
			return { ok = false, reason = "TRANSFER_UNAVAILABLE" }
		end
		local request, revision, proof, err = config.request(actor, action, args, context, origin)
		if not request or revision == nil then
			return { ok = false, reason = err or "INVALID_TRANSFER_REQUEST" }
		end
		local result = runtime.command(
			request,
			revision,
			proof,
			origin,
			if admit
				then function(): boolean
					return admit().ok
				end
				else nil
		)
		return {
			ok = result.status == "confirmed",
			stateVersion = result.stateVersion,
			reason = result.error or (if result.status ~= "confirmed" then "TRANSFER_PENDING" else nil),
			data = { id = result.id, status = result.status, phase = result.phase, version = result.version },
		}
	end
	function bridge.recover(actor: string, maximum: number): { Runtime.RecoveryResult }
		local runtime = config.resolve(actor)
		if not runtime then
			return {
				{
					version = 1,
					status = "recovering",
					phase = "DISCOVERY",
					error = "TRANSFER_UNAVAILABLE",
				},
			}
		end
		return runtime.recover(maximum)
	end
	return bridge
end
return M
