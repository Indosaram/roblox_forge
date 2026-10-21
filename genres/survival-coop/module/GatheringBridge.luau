--!strict
local Runtime = require("./GatheringRuntime")
local Shared = require("../../../core/domain/genre/Contract")
local M = {}
export type Config = {
	-- Registry owns one runtime per stable source key, shared by all actors.
	resolve: (string) -> Runtime.Runtime?,
}
function M.new(config: Config)
	local bridge = {}
	local busy: { [Runtime.Runtime]: boolean } = {}
	local function locked(runtime: Runtime.Runtime, run: () -> any): any
		if busy[runtime] then
			return { status = "recovering", error = "SOURCE_BUSY", transfers = {} }
		end
		busy[runtime] = true
		local ok, result = pcall(run)
		busy[runtime] = nil
		if not ok then
			error(result)
		end
		return result
	end
	function bridge.handles(action: string): boolean
		return action == "survival-coop:gather"
	end
	function bridge.receipt(actor: string, epoch: number, requestId: string): Shared.StateData?
		local runtime = config.resolve(actor)
		if not runtime or busy[runtime] then
			return nil
		end
		return locked(runtime, function()
			return runtime.receipt(actor, epoch, requestId)
		end)
	end
	function bridge.command(
		actor: string,
		args: { any },
		context: Shared.CommandContext,
		expiresAt: number,
		admit: () -> Shared.Result
	): Shared.Result
		if actor ~= context.actorId then
			return { ok = false, reason = "UNAUTHORIZED", data = { status = "rejected" } }
		end
		local runtime = config.resolve(actor)
		if not runtime then
			return { ok = false, reason = "GATHERING_UNAVAILABLE", data = { status = "recovering" } }
		end
		local result = locked(runtime, function()
			local admission = admit()
			if not admission.ok then
				return { status = "rejected", error = admission.reason }
			end
			return runtime.command({
				actorId = actor,
				sessionEpoch = context.sessionEpoch,
				requestId = context.requestId,
				nodeId = args[1],
				nodeVersion = args[2],
				expiresAt = expiresAt,
			})
		end)
		return { ok = result.status == "confirmed", reason = result.error, data = { status = result.status } }
	end
	function bridge.recover(actor: string, maximum: number): any
		local runtime = config.resolve(actor)
		return if runtime
			then locked(runtime, function()
				return runtime.recover(actor, maximum)
			end)
			else { status = "pending", error = "GATHERING_UNAVAILABLE" }
	end
	function bridge.snapshot(actor: string): (Shared.StateData?, string?)
		local runtime = config.resolve(actor)
		if not runtime or busy[runtime] then
			return nil, "GATHERING_UNAVAILABLE"
		end
		local result = locked(runtime, function()
			local data, err = runtime.snapshot()
			return { data = data, error = err }
		end)
		return if result.data then result.data.nodes else nil, result.error
	end
	return bridge
end
return M
