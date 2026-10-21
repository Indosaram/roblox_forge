--!strict
local Clan = require("../../../core/domain/settlement/Clan")
local Data = require("../../../core/domain/genre/SerializedData")
local Session = require("../../../core/infra/genre/Session")
local Schema = require("../../../core/infra/net/Schema")
local M = {}

function M.actions(): { any }
	local id = Schema.string({ maxLen = 128, pattern = ".+" })
	local revision = Schema.number({ min = 0, max = 2 ^ 53 - 2, integer = true })
	local definitions: any = {
		invite = { target = id },
		join = {},
		leave = {},
		role = { target = id, role = id },
		capability = { target = id, enabled = Schema.boolean() },
		transfer = { target = id },
		deposit = { amount = Schema.number({ min = 1, max = 2 ^ 31, integer = true }) },
		withdraw = { amount = Schema.number({ min = 1, max = 2 ^ 31, integer = true }) },
		contribute = {},
		["research-start"] = { id = id },
		["research-complete"] = { jobId = id },
		["research-cancel"] = { jobId = id },
		relocate = { territory = id },
		dissolve = {},
	}
	local actions = {}
	table.insert(actions, {
		id = "clan-create",
		args = { id },
		origin = "client",
		rate = { capacity = 2, refillPerSecond = 1 },
	})
	for operation, fields in definitions do
		fields.expectedRevision = Schema.optional(revision)
		table.insert(actions, {
			id = "clan-" .. operation,
			args = { id, Schema.object(fields) },
			origin = if operation == "contribute" then "server" else "client",
			rate = { capacity = 50, refillPerSecond = 10 },
		})
	end
	table.sort(actions, function(a: any, b: any): boolean
		return a.id < b.id
	end)
	return actions
end

function M.aggregate(config: any, domain: any, prefix: string, actions: { string }): any
	local store = config.store()
	local tokens: any = {}
	local departed: any = {}
	local extension: any = { id = prefix }
	local function open(id: string): (any?, string?)
		local token, reason
		if tokens[id] then
			token, reason = store:refresh(tokens[id])
		else
			token, reason = store:acquire(prefix .. ":" .. id, function(data: any): any
				return if next(data) == nil then domain.new(id, config.owner(id)) else data
			end)
		end
		tokens[id] = token
		return token, reason
	end
	function extension.handles(action: string): boolean
		if action == "survival-coop:clan-create" and prefix == "clan" and config.create then
			return true
		end
		local normalized = string.gsub(action, "^survival%-coop:" .. prefix .. "%-", "")
		return table.find(actions, normalized) ~= nil
	end
	function extension.command(actor: string, action: string, args: any, context: any, origin: string, admit: any): any
		if departed[actor] or context.actorId ~= actor then
			return { ok = false, reason = "ACTOR_LEFT_OR_FORBIDDEN" }
		end
		if not extension.handles(action) then
			return { ok = false, reason = "UNKNOWN_ACTION" }
		end
		local admitted = admit()
		if not admitted.ok then
			return admitted
		end
		local operation = string.gsub(action, "^survival%-coop:" .. prefix .. "%-", "")
		if operation == "create" then
			return config.create(actor, args[1], context)
		end
		local id = config.identity(actor, args[1])
		if not id then
			return { ok = false, reason = "WRONG_IDENTITY" }
		end
		local token, reason = open(id)
		if not token then
			return { ok = false, reason = reason }
		end
		local receipt = actor .. ":" .. tostring(context.sessionEpoch) .. ":" .. context.requestId
		if (operation == "deposit" or operation == "withdraw") and config.wallet then
			local result = config.wallet(actor, operation, args[2], context, token)
			if result.token then
				tokens[id] = result.token
			end
			return result.result
		end
		local facts = config.facts(actor, id, operation, args[2] or {}, origin)
		local result: any = nil
		local committed, err = store:update(token, function(data: any): any
			local nextState, refused = domain.apply(data, actor, operation, args[2] or {}, receipt, config.now(), facts)
			result =
				{ ok = nextState ~= nil, reason = refused, data = if nextState then { operationId = receipt } else nil }
			return nextState or data
		end)
		if not committed then
			return { ok = false, reason = err }
		end
		tokens[id] = committed
		return result
	end
	function extension.snapshot(actor: string): (any?, string?)
		if departed[actor] then
			return nil, "ACTOR_LEFT"
		end
		local id = config.identity(actor, nil)
		if not id then
			return nil, "WRONG_IDENTITY"
		end
		local token, reason = open(id)
		if not token then
			return nil, reason
		end
		if config.visible and not config.visible(token.data, actor) then
			return nil, "FORBIDDEN"
		end
		return Data.clone(token.data), nil
	end
	function extension.releaseActor(actor: string): any
		for id, token in tokens do
			local ok, reason = store:release(token)
			if not ok then
				return { ok = false, reason = reason }
			end
			tokens[id] = nil
		end
		departed[actor] = true
		return { ok = true }
	end
	function extension.resumeActor(actor: string): any
		departed[actor] = nil
		return { ok = true }
	end
	function extension.drain(_actor: string): any
		return { ok = true }
	end
	function extension.recover(actor: string, maximum: number): any
		local id = config.identity(actor, nil)
		if not id then
			return { status = "confirmed", pending = 0 }
		end
		local token, reason = open(id)
		if not token then
			return { status = "recovering", pending = 1, reason = reason }
		end
		local pending, driven = 0, 0
		-- Research input and completion share the clan fence.
		if prefix == "clan" then
			local facts = config.facts(actor, id, "research-complete", {}, "server")
			local completed, err = store:update(token, function(data: any): any
				for jobId, job in data.jobs do
					if job.status == "pending" and config.now() >= job.finishAt then
						local nextState = domain.apply(
							data,
							data.owner,
							"research-complete",
							{ jobId = jobId },
							"research-recovery:" .. jobId,
							config.now(),
							facts
						)
						if nextState then
							data = nextState
						end
					end
				end
				return data
			end)
			if not completed then
				return { status = "recovering", pending = 1, reason = err }
			end
			token, tokens[id] = completed, completed
		end
		for _, row in token.data.walletOperations or {} do
			if config.wallet and row.request.actor == actor and not row.result then
				if driven < maximum then
					driven += 1
					local request = row.request
					local result = config.wallet(
						actor,
						request.operation,
						{ amount = request.amount },
						{},
						token,
						request
					)
					token = result.token or token
					tokens[id] = token
					if not result.result.ok then
						pending += 1
					end
				else
					pending += 1
				end
			end
		end
		return { status = if pending == 0 then "confirmed" else "recovering", pending = pending }
	end
	function extension.close(): any
		for id, token in tokens do
			local ok, reason = store:release(token)
			if not ok then
				return { ok = false, reason = reason }
			end
			tokens[id] = nil
		end
		return { ok = true }
	end
	return Session.registerLifecycle(extension)
end

function M.new(config: any): any
	return M.aggregate(config, Clan, "clan", {
		"invite",
		"join",
		"leave",
		"role",
		"capability",
		"transfer",
		"deposit",
		"withdraw",
		"contribute",
		"research-start",
		"research-complete",
		"research-cancel",
		"relocate",
		"dissolve",
	})
end

function M.factory(ctx: any): any
	return if ctx.world and ctx.world.clan then M.new(ctx.world.clan) else nil
end

return M
