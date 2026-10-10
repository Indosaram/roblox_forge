--!strict
local Shared = require("../../../core/domain/genre/Contract")
local M = {}
function M.new(config: { resolve: (string) -> any })
	local busy: { [any]: boolean } = {}
	local admissions: { [string]: string } = {}
	local function locked(runtime: any, run: () -> any): any
		if busy[runtime] then
			return { ok = false, reason = "SOURCE_BUSY", data = { status = "pending" } }
		end
		busy[runtime] = true
		local ok, result = pcall(run)
		busy[runtime] = nil
		if not ok then
			error(result)
		end
		return result
	end
	local bridge = {}
	function bridge.handles(action: string): boolean
		return action == "survival-coop:attack"
	end
	function bridge.command(
		actor: string,
		args: { any },
		context: Shared.CommandContext,
		expiresAt: number,
		admit: () -> Shared.Result
	): Shared.Result
		if actor ~= context.actorId then
			return { ok = false, reason = "UNAUTHORIZED" }
		end
		local runtime = config.resolve(actor)
		if not runtime then
			return { ok = false, reason = "WILDLIFE_UNAVAILABLE" }
		end
		return locked(runtime, function()
			local key = tostring(context.sessionEpoch) .. ":" .. context.requestId .. ":" .. tostring(args[1])
			local result = runtime.command({
				actorId = actor,
				sessionEpoch = context.sessionEpoch,
				requestId = context.requestId,
				targetId = args[1],
				expiresAt = expiresAt,
			}, function()
				if admissions[actor] then
					return {
						ok = admissions[actor] == key,
						reason = if admissions[actor] ~= key then "COMMAND_PENDING" else nil,
					}
				end
				local admission = admit()
				if admission.ok then
					admissions[actor] = key
				end
				return admission
			end)
			if result.stateVersion or (result.data and result.data.status == "rejected") then
				admissions[actor] = nil
			end
			return result
		end)
	end
	function bridge.recover(actor: string, maximum: number): any
		local runtime = config.resolve(actor)
		if not runtime then
			return { ok = false, reason = "WILDLIFE_UNAVAILABLE" }
		end
		return locked(runtime, function()
			local result = runtime.recover(actor, maximum)
			if result.ok then
				admissions[actor] = nil
			end
			return result
		end)
	end
	function bridge.snapshot(actor: string): (Shared.StateData?, string?)
		local runtime = config.resolve(actor)
		if not runtime or busy[runtime] then
			return nil, "WILDLIFE_UNAVAILABLE"
		end
		local result = locked(runtime, function()
			local data, err = runtime.snapshot()
			return { data = data, error = err }
		end)
		return result.data, result.error
	end
	return bridge
end
return M
