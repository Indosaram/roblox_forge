--!strict
local Data = require("../genre/SerializedData")
local M = {}

local roles = { owner = true, officer = true, member = true, visitor = true }
local management = { invite = true, research = true, territory = true }
local construction = { build = true, deposit = true }

function M.new(id: string, owner: string): any
	return {
		schemaVersion = 1,
		revision = 0,
		clanId = id,
		owner = owner,
		members = { [owner] = { role = "owner", withdraw = false } },
		invites = {},
		funds = 0,
		level = 1,
		experience = 0,
		contributions = {},
		jobs = {},
		research = {},
		territory = "",
		journal = {},
		receipts = {},
		dissolved = false,
	}
end

function M.allowed(state: any, actor: string, capability: string): boolean
	local member = state.members[actor]
	if state.dissolved or not member then
		return false
	end
	if capability == "withdraw" then
		return member.withdraw == true
	elseif capability == "govern" then
		return member.role == "owner"
	elseif management[capability] then
		return member.role == "owner" or member.role == "officer"
	elseif construction[capability] then
		return member.role ~= "visitor"
	end
	return capability == "view"
end

function M.effect(state: any, actor: string, effect: string, now: number, outpost: any): boolean
	if not M.allowed(state, actor, "build") or not state.research[effect] then
		return false
	end
	if effect == "advanced-capture" then
		return outpost ~= nil and outpost.owner == state.clanId and now < outpost.expiresAt
	end
	return true
end

-- Caller supplies authoritative facts and a receipt derived from the Session context.
-- No item/player balance is credited here: transfer ports must settle the ledger atomically.
function M.apply(
	state: any,
	actor: string,
	operation: string,
	args: any,
	receipt: string,
	now: number,
	ctx: any
): (any?, string?)
	if operation ~= "join" then
		if not M.allowed(state, actor, "view") then
			return nil, "NOT_MEMBER"
		end
	end
	if state.receipts[receipt] then
		return Data.clone(state), nil
	end
	if args.expectedRevision ~= nil and args.expectedRevision ~= state.revision then
		return nil, "REVISION_CONFLICT"
	end
	local out = Data.clone(state)
	if operation == "invite" then
		if not M.allowed(state, actor, "invite") then
			return nil, "FORBIDDEN"
		end
		if type(args.target) ~= "string" or args.target == "" or state.members[args.target] then
			return nil, "INVALID_TARGET"
		end
		out.invites[args.target] = true
	elseif operation == "join" then
		if state.dissolved or not state.invites[actor] or state.members[actor] then
			return nil, "NOT_INVITED"
		end
		local count = 0
		for _ in state.members do
			count += 1
		end
		if count >= ctx.rules.maxMembers then
			return nil, "CLAN_FULL"
		end
		out.members[actor] = { role = "member", withdraw = false }
		out.invites[actor] = nil
	elseif operation == "role" or operation == "capability" or operation == "transfer" then
		if not M.allowed(state, actor, "govern") then
			return nil, "FORBIDDEN"
		end
		if not state.members[args.target] then
			return nil, "NOT_MEMBER"
		end
		if operation == "transfer" then
			if args.target == actor or state.members[args.target].role == "visitor" then
				return nil, "INVALID_SUCCESSOR"
			end
			out.members[actor].role = "officer"
			out.members[args.target].role = "owner"
			out.owner = args.target
		elseif operation == "role" then
			if not roles[args.role] or args.role == "owner" or args.target == state.owner then
				return nil, "INVALID_ROLE"
			end
			out.members[args.target].role = args.role
			-- A demotion cannot retain an old withdrawal grant.
			out.members[args.target].withdraw = false
		else
			if type(args.enabled) ~= "boolean" or state.members[args.target].role == "visitor" then
				return nil, "INVALID_CAPABILITY"
			end
			out.members[args.target].withdraw = args.enabled
		end
	elseif operation == "leave" then
		if actor == state.owner then
			return nil, "SUCCESSOR_REQUIRED"
		end
		out.members[actor] = nil
	elseif operation == "deposit" or operation == "withdraw" then
		if not M.allowed(state, actor, operation) then
			return nil, "FORBIDDEN"
		end
		if not Data.finite(args.amount) or args.amount % 1 ~= 0 or args.amount <= 0 then
			return nil, "INVALID_AMOUNT"
		end
		if not ctx.transferAuthorized then
			return nil, "TRANSFER_REQUIRED"
		end
		if operation == "withdraw" and state.funds < args.amount then
			return nil, "INSUFFICIENT_FUNDS"
		end
		out.funds += if operation == "deposit" then args.amount else -args.amount
	elseif operation == "contribute" then
		if not ctx.contribution or state.contributions[ctx.contribution] then
			return nil, "INVALID_CONTRIBUTION"
		end
		out.contributions[ctx.contribution] = true
		out.experience += ctx.rules.missionExperience
		while out.level < ctx.rules.maxLevel and out.experience >= ctx.rules.levelExperience * out.level do
			out.experience -= ctx.rules.levelExperience * out.level
			out.level += 1
		end
	elseif operation == "research-start" then
		if not M.allowed(state, actor, "research") then
			return nil, "FORBIDDEN"
		end
		local definition = ctx.operations[args.id]
		if not definition or definition.kind ~= "clan-research" then
			return nil, "UNKNOWN_RESEARCH"
		end
		if state.level < definition.gates.clanLevel or not ctx.hall then
			return nil, "RESEARCH_GATE"
		end
		for _, job in state.jobs do
			if job.definition == args.id and job.status ~= "cancelled" then
				return nil, "RESEARCH_EXISTS"
			end
		end
		if state.funds < definition.cost then
			return nil, "INSUFFICIENT_FUNDS"
		end
		out.funds -= definition.cost
		out.jobs[receipt] = {
			jobId = receipt,
			definition = args.id,
			finishAt = now + definition.seconds,
			cost = definition.cost,
			status = "pending",
		}
	elseif operation == "research-complete" or operation == "research-cancel" then
		if not M.allowed(state, actor, "research") then
			return nil, "FORBIDDEN"
		end
		local job = out.jobs[args.jobId]
		if not job or job.status ~= "pending" then
			return nil, "JOB_SETTLED"
		end
		if operation == "research-cancel" then
			if now >= job.finishAt then
				return nil, "ALREADY_FINISHED"
			end
			job.status = "cancelled"
			out.funds += math.floor(job.cost * ctx.rules.cancelRefund)
		else
			if now < job.finishAt then
				return nil, "NOT_READY"
			end
			job.status = "completed"
			for _, effect in ctx.operations[job.definition].effects do
				out.research[effect.id] = effect.value
			end
		end
	elseif operation == "relocate" then
		if not M.allowed(state, actor, "territory") then
			return nil, "FORBIDDEN"
		end
		if not ctx.territoryAllowed then
			return nil, "INVALID_TERRITORY"
		end
		table.insert(out.journal, { operationId = receipt, from = state.territory, to = args.territory, at = now })
		out.territory = args.territory
	elseif operation == "dissolve" then
		if not M.allowed(state, actor, "govern") then
			return nil, "FORBIDDEN"
		end
		if state.funds ~= 0 or ctx.hasProperty then
			return nil, "PROPERTY_REMAINS"
		end
		for _, job in state.jobs do
			if job.status == "pending" then
				return nil, "PROPERTY_REMAINS"
			end
		end
		out.dissolved = true
	else
		return nil, "UNKNOWN_ACTION"
	end
	out.revision += 1
	out.receipts[receipt] = true
	return out, nil
end

return M
