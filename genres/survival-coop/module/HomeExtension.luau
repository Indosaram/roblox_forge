--!strict
local Home = require("../../../core/domain/home/HomeState")
local HomeContent = require("../../../core/domain/home/HomeContent")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Session = require("../../../core/infra/genre/Session")
local Schema = require("../../../core/infra/net/Schema")
local HomeTransfer = require("./HomeTransfer")
local HomeMove = require("../../../core/domain/home/HomeMove")
local Spoilage = require("../../../core/domain/survival/Spoilage")
local Clock = require("../../../core/infra/genre/Clock")
local M = {}

-- Client actions this extension adds beyond the base contract list.
function M.actions(): { any }
	local id = Schema.string({ maxLen = 128, pattern = ".+" })
	local mode = Schema.enum({ "owner", "friend", "clan", "none" })
	local rate = { capacity = 5, refillPerSecond = 2 }
	return {
		{
			id = "home-permissions",
			args = {
				id,
				Schema.object({
					permissions = Schema.object({
						visit = mode,
						cooperate = mode,
						grants = Schema.optional(Schema.object({ use = mode, build = mode, recover = mode })),
						clanId = Schema.string({ maxLen = 128 }),
						offlineCoop = Schema.boolean(),
						anyFriend = Schema.optional(Schema.boolean()),
					}),
				}),
			},
			origin = "client",
			rate = rate,
		},
		{ id = "home-move", args = { id, Schema.object({ destination = id }) }, origin = "client", rate = rate },
	}
end

-- store is the existing FencedStore factory. Trusted ports provide ownership,
-- world reachability, node purchases, entitlements and development; no GUI/API calls.
function M.new(config: any): any
	local store = config.store()
	local catalog = Catalog.new(config.content.items)
	local crops = HomeContent.crops(config.content)
	local tokens: any = {}
	local departed: any = {}
	local attached: any = {}
	local extension: any = { id = "home" }
	local function open(owner: string): (any?, string?)
		local held = tokens[owner]
		if held then
			local refreshed, reason = store:refresh(held)
			if not refreshed then
				tokens[owner] = nil
				return nil, reason
			end
			tokens[owner] = refreshed
			return refreshed, nil
		end
		local token, reason = store:acquire(Home.identity(owner), function(data)
			if next(data) == nil then
				local state = Home.new(owner, config.rules, config.seed(owner))
				if config.initialStorage then
					state.storage = config.initialStorage(owner, state.storage)
				end
				return { home = state, receipts = {} }
			end
			Home.load(data.home, owner, catalog)
			return data
		end)
		tokens[owner] = token
		return token, reason
	end
	local transfer = if config.personal
		then HomeTransfer.new({
			catalog = catalog,
			now = config.now,
			spoilage = Spoilage.policy(config.content),
			nowMillis = function()
				return Clock.millis(config.now())
			end,
			personal = config.personal,
			open = open,
			update = function(actor, transform)
				local token, reason = open(actor)
				if not token then
					return nil, reason
				end
				local updated, err = store:update(token, transform)
				if updated then
					tokens[actor] = updated
				end
				return updated, err
			end,
		})
		else nil
	function extension.handles(action: string): boolean
		action = string.gsub(action, "^survival%-coop:", "")
		return table.find({
			"home-permissions",
			"home-rank",
			"home-expand",
			"home-capacity",
			"home-preset",
			"home-place",
			"home-recover",
			"home-plant",
			"home-harvest",
			"home-deposit",
			"home-withdraw",
			"home-fertilize",
			"home-area",
			"home-specialize",
			"home-move",
		}, action) ~= nil
	end
	function extension.command(actor: string, action: string, args: any, context: any, origin: string, admit: any): any
		action = string.gsub(action, "^survival%-coop:", "")
		if departed[actor] or context.actorId ~= actor then
			return { ok = false, reason = "ACTOR_LEFT_OR_FORBIDDEN" }
		end
		if not extension.handles(action) then
			return { ok = false, reason = "UNKNOWN_ACTION" }
		end
		local operation = string.sub(action, 6)
		if (operation == "rank" or operation == "capacity") and origin ~= "server" then
			return { ok = false, reason = "SERVER_ONLY" }
		end
		if operation == "deposit" or operation == "withdraw" then
			if not transfer or args[1] ~= Home.identity(actor) then
				return { ok = false, reason = "WRONG_HOME_TOKEN" }
			end
			local home = extension.snapshot(actor)
			if not home or not config.facts(actor, actor, operation, {}).reachable then
				return { ok = false, reason = "OUT_OF_RANGE" }
			end
			return transfer.command(actor, operation == "deposit", args[2].itemId, args[2].quantity, context, admit)
		end
		if transfer then
			local recovered = transfer.recover(actor)
			if not recovered.ok then
				return recovered
			end
		end
		local admitted = admit()
		if not admitted.ok then
			return admitted
		end
		local owner = config.ownerOf(actor, args[1])
		if not owner or Home.identity(owner) ~= args[1] then
			return { ok = false, reason = "WRONG_HOME_TOKEN" }
		end
		local facts = config.facts(actor, owner, operation, args[2] or {})
		if not facts.reachable then
			return { ok = false, reason = "OUT_OF_RANGE" }
		end
		local token, reason = open(owner)
		if not token then
			return { ok = false, reason = reason }
		end
		local receipt = actor .. ":" .. tostring(context.sessionEpoch) .. ":" .. context.requestId
		local result: any = nil
		local now = config.now()
		local body = Home.copy(args[2] or {})
		-- Dock admission is authoritative spatial evidence, not a client boolean.
		body.atDock = facts.atDock == true
		local committed, err = store:update(token, function(data)
			if data.receipts[receipt] then
				result = data.receipts[receipt]
				return data
			end
			local nextHome: any, refused: string?
			if operation == "move" then
				local pending = 0
				for _, request: any in data.transfers or {} do
					if not request.result then
						pending += 1
					end
				end
				nextHome, refused = HomeMove.apply(
					data.home,
					actor,
					args[1],
					body,
					{ rules = config.rules, now = now, pendingTransfers = pending }
				)
			else
				nextHome, refused = Home.apply(data.home, actor, args[1], operation, body, {
					now = now,
					facts = facts,
					rules = config.rules,
					catalog = catalog,
					crops = crops,
					structures = config.structures,
					-- Learned nodes arrive as SkillTree.paid (node -> SP cost); Home gates test `== true`.
					nodes = (function()
						local learned = {}
						for node, value in facts.nodes or {} do
							learned[node] = value ~= nil and value ~= false
						end
						return learned
					end)(),
					entitlements = facts.entitlements or {},
					developmentRank = facts.developmentRank,
				})
			end
			result = { ok = nextHome ~= nil, reason = refused }
			if not nextHome then
				return data
			end
			local out = Home.copy(data)
			out.home = nextHome
			out.receipts[receipt] = result
			return out
		end)
		if not committed then
			return { ok = false, reason = err }
		end
		tokens[owner] = committed
		attached[actor] = owner
		if result.ok and config.publish then
			config.publish(owner, Home.copy(committed.data.home))
		end
		return result
	end
	function extension.snapshot(actor: string): (any?, string?)
		if departed[actor] then
			return nil, "ACTOR_LEFT"
		end
		local owner = attached[actor] or actor
		local token, reason = open(owner)
		if not token then
			return nil, reason
		end
		local facts = config.facts(actor, owner)
		if not Home.allowed(token.data.home, actor, "visit", facts) then
			return nil, "FORBIDDEN"
		end
		if actor == owner then
			local slots = config.rules.baseSlots
			for id, extra in config.rules.storageGrants do
				if (facts.entitlements or {})[id] == true then
					slots += extra
				end
			end
			local presets = Home.presetSlots(config.rules, facts.entitlements)
			local stored = token.data.home
			if slots ~= stored.storageSlots or presets ~= (stored.presetSlots or config.rules.basePresetSlots or 1) then
				local updated, updateError = store:update(token, function(data)
					local home, capacityError = Home.apply(data.home, actor, Home.identity(owner), "capacity", {}, {
						rules = config.rules,
						facts = facts,
						entitlements = facts.entitlements or {},
					})
					assert(home, capacityError)
					data.home = home
					return data
				end)
				if not updated then
					return nil, updateError
				end
				token = updated
				tokens[owner] = updated
			end
		end
		attached[actor] = owner
		if config.publish then
			config.publish(owner, Home.copy(token.data.home))
		end
		return Home.copy(token.data.home), nil
	end
	function extension.recover(_actor: string, _maximum: number): any
		-- Growth is represented by readyAt; reconnect never ticks or rerolls crops.
		if transfer then
			local result = transfer.recover(_actor)
			return {
				status = if result.ok then "confirmed" else "pending",
				pending = if result.ok then 0 else 1,
				reason = result.reason,
			}
		end
		return { status = "confirmed", pending = 0 }
	end
	function extension.drain(_actor: string): any
		return if transfer then transfer.recover(_actor) else { ok = true }
	end
	function extension.releaseActor(actor: string): any
		local owner = attached[actor] or actor
		for other, target in attached do
			if other ~= actor and target == owner and not departed[other] then
				departed[actor] = true
				attached[actor] = nil
				return { ok = true }
			end
		end
		local token = tokens[owner]
		if token then
			local released, reason = store:release(token)
			if not released then
				return { ok = false, reason = reason }
			end
			tokens[owner] = nil
		end
		departed[actor] = true
		attached[actor] = nil
		return { ok = true }
	end
	function extension.resumeActor(actor: string): any
		departed[actor] = nil
		local token, reason = open(actor)
		attached[actor] = actor
		return { ok = token ~= nil, reason = reason }
	end
	function extension.close(): any
		for owner, token in tokens do
			local released, reason = store:release(token)
			if not released then
				return { ok = false, reason = reason }
			end
			tokens[owner] = nil
		end
		return { ok = true }
	end
	return Session.registerLifecycle(extension)
end

function M.factory(ctx: any): any
	if not ctx.home then
		return nil
	end
	local config = table.clone(ctx.home)
	config.content, config.store, config.now = ctx.content, ctx.store, ctx.now
	return M.new(config)
end
return M
