--!strict
-- Actor-scoped documents share the existing fenced backend, never the personal bag.
local Fenced = require("./FencedStore")
local Data = require("../../domain/genre/SerializedData")
local M = {}

function M.new(backend: any, options: Fenced.Options, namespace: string): any
	assert(string.match(namespace, "^[%w_-]+$") and #namespace <= 16, "INVALID_DOCUMENT_NAMESPACE")
	local store = Fenced.new(backend, options)
	local tokens: { [string]: Fenced.Profile? } = {}
	local busy: { [string]: boolean } = {}
	local departed: { [string]: boolean } = {}
	local api = {}
	local function open(actor: string): (Fenced.Profile?, string?)
		if departed[actor] then
			return nil, "ACTOR_LEFT"
		end
		if not string.match(actor, "^%-?%d+$") or #actor > 32 then
			return nil, "INVALID_ACTOR"
		end
		local token = tokens[actor]
		local current, reason
		if token then
			current, reason = store:refresh(token)
		else
			current, reason = store:acquire(namespace .. ":" .. actor, function(data)
				return data
			end)
		end
		tokens[actor] = current
		return current, reason
	end
	function api.drain(actor: string): any
		return if busy[actor] then { ok = false, reason = "DOCUMENT_BUSY" } else { ok = true }
	end
	function api.transaction(actor: string, transform: (any) -> any): any
		if busy[actor] then
			return { ok = false, reason = "DOCUMENT_BUSY" }
		end
		busy[actor] = true
		local ok, result = pcall(function()
			local token, reason = open(actor)
			if not token then
				return { ok = false, reason = reason }
			end
			local outcome: any = nil
			local committed, err = store:update(token, function(data)
				local candidate = Data.clone(data)
				outcome = transform(candidate)
				assert(type(outcome) == "table" and type(outcome.ok) == "boolean", "INVALID_DOCUMENT_RESULT")
				return if outcome.ok then candidate else data
			end)
			if not committed then
				return { ok = false, reason = err }
			end
			tokens[actor] = committed
			return outcome
		end)
		busy[actor] = nil
		if not ok then
			error(result, 0)
		end
		return result
	end
	function api.snapshot(actor: string): (any?, string?)
		if busy[actor] then
			return nil, "DOCUMENT_BUSY"
		end
		busy[actor] = true
		local ok, token, reason = pcall(open, actor)
		busy[actor] = nil
		if not ok then
			error(token, 0)
		end
		return if token then Data.clone(token.data) else nil, reason
	end
	function api.releaseActor(actor: string): any
		if busy[actor] then
			return { ok = false, reason = "DOCUMENT_BUSY" }
		end
		local token = tokens[actor]
		if token then
			local released, reason = store:release(token)
			if not released then
				return { ok = false, reason = reason }
			end
		end
		tokens[actor], departed[actor] = nil, true
		return { ok = true }
	end
	function api.resumeActor(actor: string): any
		departed[actor] = nil
		local snapshot, reason = api.snapshot(actor)
		return { ok = snapshot ~= nil, reason = reason }
	end
	function api.close(): any
		for actor in tokens do
			local result = api.releaseActor(actor)
			if not result.ok then
				return result
			end
		end
		return { ok = true }
	end
	return api
end

return M
