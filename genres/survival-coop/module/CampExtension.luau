--!strict
-- Camp ladder + friend visit as a durable survival-coop extension (lane H2).
-- Tribe members deliver items from their bag to a shared project; completion raises
-- the camp rung and unlocks a facility. A friend with a time-boxed visitor pass may
-- help a host project (Visit) but can never take host items or complete a project.
--
-- Persistence: one Fenced aggregate per tribe (camp state, delivery receipts, visitor
-- passes). A delivery is a reserve / credit / consume sequence so a crash never loses
-- or duplicates items: the bag reservation is the durable lock, the camp receipt is the
-- commit point, and recover() settles whatever a crash left half-done. No randomness.
local Camp = require("./Camp")
local Settlement = require("../../../core/domain/settlement/Settlement")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Ledger = require("../../../core/domain/command/Ledger")
local Content = require("../../../core/domain/survival/Content")
local Shared = require("../../../core/domain/genre/Contract")
local Fenced = require("../../../core/infra/data/FencedStore")
local Session = require("../../../core/infra/genre/Session")
local Visit = require("../../../core/infra/island/Visit")
local M = {}

M.SAVE_VERSION = 1
M.VISIT_SECONDS = 600
M.MAX_RECEIPTS = 256
M.MAX_PASSES = 32
local RECEIPT_TTL = 86400
local PREFIX = "camp:"

local ACTIONS: { [string]: string } = {
	["survival-coop:camp-contribute"] = "contribute",
	["survival-coop:camp-complete"] = "complete",
	["survival-coop:camp-visit-open"] = "visit-open",
	["survival-coop:camp-visit-help"] = "visit-help",
}

export type Config = {
	content: Content.Document,
	store: () -> Fenced.Store,
	now: () -> number,
	-- Trusted settlement port: snapshot(actor) answers only for tribe members.
	settlement: { snapshot: (string) -> (Shared.StateData?, string?) },
	personalTransfer: (string) -> Session.PersonalTransfer?,
	-- Session roster, used only to list who a guest could visit.
	members: (() -> { string })?,
	-- Trusted friendship source (for example a Players:IsFriendsWithAsync cache).
	isFriend: ((string, string) -> boolean)?,
	visitSeconds: number?,
}
export type Built = Shared.Extension & { close: (() -> Shared.Result)? }

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

local function failure(reason: string): Shared.Result
	return { ok = false, reason = reason }
end

function M.ladder(content: Content.Document): Camp.Ladder?
	local camp = content.camp
	if camp == nil then
		return nil
	end
	local projects: { Camp.Project } = {}
	for _, project in camp.projects do
		table.insert(projects, { id = project.id, rung = project.rung, cost = copy(project.cost) })
	end
	local rungs: { Camp.Rung } = {}
	for _, rung in camp.rungs do
		table.insert(rungs, { rung = rung.rung, completions = rung.completions, facility = rung.facility })
	end
	return Camp.ladder(projects, rungs, camp.leagueRung)
end

function M.new(config: Config): Built?
	local ladder = M.ladder(config.content)
	if ladder == nil then
		return nil
	end
	local items: { Catalog.Definition } = {}
	for _, item in config.content.items do
		table.insert(items, {
			id = item.id,
			stackMax = item.stackMax,
			weightMilli = item.weightMilli,
			maxDurabilityMilli = item.maxDurabilityMilli,
		})
	end
	local catalog = Catalog.new(items)
	local store = config.store()
	local tokens: { [string]: Fenced.Profile } = {}
	local visits: { [string]: string } = {}
	local isFriend = config.isFriend or function()
		return false
	end
	local duration = config.visitSeconds or M.VISIT_SECONDS
	local visit = Visit.new({
		isFriend = isFriend,
		durationSeconds = duration,
		help = {
			["camp-assist"] = function(island, visitorId, args)
				local state = Camp.fromSave(island.data.camp, ladder)
				local helped, reason = Camp.assist(state, ladder, visitorId, args[1], args[2], {
					item = args[3],
					quantity = args[4],
				})
				if not helped then
					return nil, reason
				end
				local candidate = copy(island)
				candidate.data.camp = Camp.save(helped)
				return candidate, nil
			end,
		},
	})

	local function keyFor(tribeId: string): string
		return string.sub(PREFIX .. tribeId, 1, 50)
	end
	local function initial(tribeId: string): any
		return {
			version = M.SAVE_VERSION,
			camp = Camp.save(Camp.new(tribeId)),
			receipts = {},
			passes = {},
		}
	end
	-- Fresh, lease-healthy token for a tribe's camp aggregate.
	local function open(tribeId: string): (Fenced.Profile?, string?)
		local held = tokens[tribeId]
		if held then
			local refreshed = store:refresh(held)
			if refreshed then
				tokens[tribeId] = refreshed
				return refreshed, nil
			end
			tokens[tribeId] = nil
		end
		local acquired, err = store:acquire(keyFor(tribeId), function(data)
			if next(data) == nil then
				return initial(tribeId)
			end
			assert(data.version == M.SAVE_VERSION, "UNSUPPORTED_CAMP_AGGREGATE")
			assert(Camp.fromSave(data.camp, ladder).tribeId == tribeId, "CAMP_TRIBE_MISMATCH")
			return data
		end)
		if not acquired then
			return nil, err or "CAMP_UNAVAILABLE"
		end
		tokens[tribeId] = acquired
		return acquired, nil
	end
	local function member(actor: string): Settlement.State?
		local state = config.settlement.snapshot(actor)
		return if state then (state :: any).settlement else nil
	end
	-- Session members that belong to a tribe, other than `actor`: the visit candidates.
	-- Friendship is deliberately not asked here (the engine call yields); camp-visit-open
	-- refuses a non-friend with NOT_FRIEND.
	local function candidates(actor: string): { [string]: boolean }
		local result: { [string]: boolean } = {}
		local roster: { string } = if config.members then (config.members :: () -> { string })() else {}
		for _, other in roster do
			if other ~= actor and member(other) ~= nil then
				result[other] = true
			end
		end
		return result
	end
	local function cooldowns(settlement: Settlement.State, now: number): { [string]: number }
		local result: { [string]: number } = {}
		for departed, at in settlement.departedAt do
			local remaining = at + Settlement.REJOIN_COOLDOWN_SECONDS - now
			if remaining > 0 then
				result[departed] = remaining
			end
		end
		return result
	end
	-- Passes are only swept when a new one is issued, so a late help still reports
	-- VISIT_EXPIRED (Visit's own verdict) instead of a vanished pass.
	local function prune(data: any, now: number, passes: boolean?)
		for id, receipt in data.receipts do
			if now >= receipt.at + RECEIPT_TTL then
				data.receipts[id] = nil
			end
		end
		if passes then
			for visitor, pass in data.passes do
				if now >= pass.expiresAt then
					data.passes[visitor] = nil
				end
			end
		end
	end

	-- Bag helpers: every call is one fenced lens update followed by the hydrate the
	-- gathering owner does, so the Session sees the change on its next snapshot.
	local function bagUpdate(
		personal: Session.PersonalTransfer,
		body: (Inventory.State) -> (Inventory.State?, string?)
	): (boolean, string?)
		local lens = personal.personal:inventoryLens()
		local reason: string? = nil
		local updated, err = lens:update(personal.profile(), function(data)
			reason = nil
			local bag = Inventory.fromSave(data.inventory, catalog)
			local changed, why = body(bag)
			if why then
				reason = why
			elseif changed then
				data.inventory = Inventory.save(changed)
			end
			return data
		end)
		if not updated then
			return false, err or "PERSONAL_UNAVAILABLE"
		end
		local current, refreshError = personal.personal:refresh(updated)
		if not current then
			return false, refreshError or "PERSONAL_UNAVAILABLE"
		end
		personal.install(current)
		return reason == nil, reason
	end
	local function consumeReserved(personal: Session.PersonalTransfer, id: string): (boolean, string?)
		return bagUpdate(personal, function(bag)
			if bag.reservations[id] == nil then
				return nil, nil
			end
			return Inventory.exchange(bag, catalog, id, {}, bag.version)
		end)
	end
	local function releaseReserved(personal: Session.PersonalTransfer, id: string): (boolean, string?)
		return bagUpdate(personal, function(bag)
			if bag.reservations[id] == nil then
				return nil, nil
			end
			return Inventory.release(bag, id, bag.version)
		end)
	end

	-- credit(data, settlementState, catalogId) -> (reason?) mutates data.camp on success.
	type Credit = (any, string) -> string?
	local function deliver(
		actor: string,
		tribeId: string,
		itemId: string,
		quantity: number,
		context: Shared.CommandContext,
		binding: string,
		credit: Credit
	): Shared.Result
		if string.find(tribeId, ":", 1, true) then
			return failure("INVALID_TRIBE")
		end
		local id = string.format("%s%s:%s:%s", PREFIX, tribeId, tostring(context.sessionEpoch), context.requestId)
		if #id > 128 then
			return failure("INVALID_REQUEST")
		end
		local personal = config.personalTransfer(actor)
		if not personal then
			return failure("PERSONAL_UNAVAILABLE")
		end
		local token, openError = open(tribeId)
		if not token then
			return failure(openError or "CAMP_UNAVAILABLE")
		end
		local known = token.data.receipts[id]
		if known then
			if known.binding ~= binding then
				return failure("REQUEST_CONFLICT")
			end
			local settled, settleError = consumeReserved(personal, id)
			if not settled then
				return failure(settleError or "SETTLE_FAILED")
			end
			return copy(known.result)
		end
		local catalogId: string? = nil
		local reserved, reserveError = bagUpdate(personal, function(bag)
			local stack = bag.items[itemId]
			if stack == nil then
				return nil, "UNKNOWN_ITEM"
			end
			catalogId = stack.catalogId
			if bag.reservations[id] ~= nil then
				return nil, nil
			end
			return Inventory.reserve(bag, id, { [itemId] = quantity }, bag.version)
		end)
		if not reserved or catalogId == nil then
			return failure(reserveError or "RESERVE_FAILED")
		end
		local reason: string? = nil
		local result: Shared.Result = { ok = true, data = { project = nil } }
		local committed, commitError = store:update(token, function(data)
			reason = nil
			local nextData = copy(data)
			prune(nextData, config.now())
			local count = 0
			for _ in nextData.receipts do
				count += 1
			end
			if nextData.receipts[id] ~= nil then
				reason = "RECEIPT_EXISTS"
				return data
			elseif count >= M.MAX_RECEIPTS then
				reason = "RECEIPT_LIMIT"
				return data
			end
			reason = credit(nextData, catalogId :: string)
			if reason then
				return data
			end
			result = { ok = true, data = { camp = nextData.camp.version } }
			nextData.receipts[id] = { binding = binding, actor = actor, at = config.now(), result = copy(result) }
			return nextData
		end)
		if not committed then
			-- The camp commit is unconfirmed: keep the reservation. The client retries the
			-- same request id and finds the receipt, or recover() releases an orphan.
			return failure(commitError or "CAMP_COMMIT_FAILED")
		end
		tokens[tribeId] = committed
		if reason then
			releaseReserved(personal, id)
			return failure(reason)
		end
		local consumed, consumeError = consumeReserved(personal, id)
		if not consumed then
			return failure(consumeError or "SETTLE_FAILED")
		end
		return result
	end

	local function authority(actor: string, settlement: Settlement.State): string?
		if settlement.roles[actor] == nil then
			return "FORBIDDEN"
		end
		return nil
	end

	local function contribute(actor: string, args: { any }, context: Shared.CommandContext): Shared.Result
		local settlement = member(actor)
		if settlement == nil then
			return failure("FORBIDDEN")
		end
		local tribeId = settlement.config.tribeId
		local binding = Ledger.canonical({ action = "contribute", actor = actor, args = args })
		return deliver(actor, tribeId, args[2], args[3], context, binding, function(data, catalogId)
			local state = Camp.fromSave(data.camp, ladder)
			local reason = authority(actor, settlement)
			if reason then
				return reason
			end
			local nextState, err = Camp.contribute(
				state,
				ladder,
				settlement,
				actor,
				args[4],
				args[1],
				{ item = catalogId, quantity = args[3] }
			)
			if not nextState then
				return err
			end
			data.camp = Camp.save(nextState)
			return nil
		end)
	end

	local function help(actor: string, args: { any }, context: Shared.CommandContext): Shared.Result
		local host = member(args[1])
		if host == nil then
			return failure("HOST_UNAVAILABLE")
		elseif host.roles[actor] ~= nil then
			return failure("ALREADY_MEMBER")
		end
		local tribeId = host.config.tribeId
		local binding = Ledger.canonical({ action = "visit-help", actor = actor, args = args })
		return deliver(actor, tribeId, args[3], args[4], context, binding, function(data, catalogId)
			local pass = data.passes[actor]
			if pass == nil or pass.hostId ~= args[1] then
				return "NO_PASS"
			end
			local island: Visit.Island = {
				hostId = args[1],
				version = data.camp.version,
				-- Host items are never offered to a help handler for editing; the Visit
				-- contract refuses any candidate that lowers a count.
				items = {},
				data = { camp = copy(data.camp) },
			}
			local helped, reason = visit.help(pass, island, "camp-assist", {
				args[5],
				args[2],
				catalogId,
				args[4],
			}, config.now())
			if not helped then
				return reason or "HELP_REFUSED"
			end
			data.camp = copy(helped.data.camp)
			return nil
		end)
	end

	local function open_visit(actor: string, args: { any }): Shared.Result
		local host = member(args[1])
		if host == nil then
			return failure("HOST_UNAVAILABLE")
		elseif host.roles[actor] ~= nil then
			return failure("ALREADY_MEMBER")
		end
		local now = config.now()
		local pass, reason = visit.open(args[1], actor, now)
		if not pass then
			return failure(reason or "VISIT_REFUSED")
		end
		local tribeId = host.config.tribeId
		local token, openError = open(tribeId)
		if not token then
			return failure(openError or "CAMP_UNAVAILABLE")
		end
		local refused: string? = nil
		local committed, err = store:update(token, function(data)
			refused = nil
			local nextData = copy(data)
			prune(nextData, now, true)
			local count = 0
			for _ in nextData.passes do
				count += 1
			end
			if nextData.passes[actor] == nil and count >= M.MAX_PASSES then
				refused = "PASS_LIMIT"
				return data
			end
			nextData.passes[actor] = { hostId = pass.hostId, visitorId = actor, expiresAt = pass.expiresAt }
			return nextData
		end)
		if not committed then
			return failure(err or "CAMP_COMMIT_FAILED")
		end
		tokens[tribeId] = committed
		if refused then
			return failure(refused)
		end
		visits[actor] = tribeId
		return { ok = true, data = { hostId = pass.hostId, expiresAt = pass.expiresAt } }
	end

	local function complete(actor: string, args: { any }, context: Shared.CommandContext): Shared.Result
		local settlement = member(actor)
		if settlement == nil then
			return failure("FORBIDDEN")
		end
		local tribeId = settlement.config.tribeId
		local token, openError = open(tribeId)
		if not token then
			return failure(openError or "CAMP_UNAVAILABLE")
		end
		local id = string.format("%scomplete:%s:%s", PREFIX, tostring(context.sessionEpoch), context.requestId)
		local binding = Ledger.canonical({ action = "complete", actor = actor, args = args })
		local known = token.data.receipts[id]
		if known then
			return if known.binding == binding then copy(known.result) else failure("REQUEST_CONFLICT")
		end
		local reason: string? = nil
		local result: Shared.Result = { ok = true }
		local committed, err = store:update(token, function(data)
			reason = nil
			local nextData = copy(data)
			prune(nextData, config.now())
			local state = Camp.fromSave(nextData.camp, ladder)
			local nextState, why = Camp.complete(state, ladder, settlement, actor, args[2], args[1])
			if not nextState then
				reason = why
				return data
			end
			nextData.camp = Camp.save(nextState)
			result = { ok = true, data = { camp = nextState.version, rung = Camp.rung(nextState, ladder) } }
			nextData.receipts[id] = { binding = binding, actor = actor, at = config.now(), result = copy(result) }
			return nextData
		end)
		if not committed then
			return failure(err or "CAMP_COMMIT_FAILED")
		end
		tokens[tribeId] = committed
		if reason then
			return failure(reason)
		end
		return result
	end

	local extension = {} :: Built
	extension.id = "camp"
	function extension.handles(action)
		return ACTIONS[action] ~= nil
	end
	function extension.command(actor, action, args, context, _origin, admit)
		local mapped = ACTIONS[action]
		if mapped == nil then
			return failure("UNKNOWN_ACTION")
		end
		if context.actorId ~= actor then
			return failure("FORBIDDEN")
		end
		local admitted = admit()
		if not admitted.ok then
			return admitted
		end
		if mapped == "contribute" then
			return contribute(actor, args, context)
		elseif mapped == "complete" then
			return complete(actor, args, context)
		elseif mapped == "visit-open" then
			return open_visit(actor, args)
		end
		return help(actor, args, context)
	end
	function extension.snapshot(actor)
		local now = config.now()
		local settlement = member(actor)
		local tribeId = if settlement then settlement.config.tribeId else visits[actor]
		if tribeId == nil then
			local hosts = candidates(actor)
			if next(hosts) == nil then
				return nil, nil
			end
			return { role = "guest", hosts = hosts } :: any, nil
		end
		local token, err = open(tribeId)
		if not token then
			return nil, err
		end
		local state = Camp.fromSave(token.data.camp, ladder)
		local view: { [string]: any } = {
			role = if settlement then "member" else "visitor",
			version = state.version,
			rung = Camp.rung(state, ladder),
			facilities = copy(state.facilities),
			completed = copy(state.completed),
			active = copy(state.active),
			ladder = { rungs = copy(ladder.rungs), projects = copy(ladder.projects), leagueRung = ladder.leagueRung },
		}
		if settlement then
			view.cooldowns = cooldowns(settlement, now)
			local passes: { [string]: any } = {}
			for visitor, pass in token.data.passes do
				if now < pass.expiresAt then
					passes[visitor] = { expiresAt = pass.expiresAt }
				end
			end
			view.passes = passes
		else
			local pass = token.data.passes[actor]
			view.pass = if pass and now < pass.expiresAt
				then { hostId = pass.hostId, expiresAt = pass.expiresAt }
				else nil
			view.hosts = candidates(actor)
		end
		return view :: any, nil
	end
	function extension.recover(actor, maximum)
		local personal = config.personalTransfer(actor)
		if not personal then
			return { status = "recovering", error = "PERSONAL_UNAVAILABLE" }
		end
		local lens = personal.personal:inventoryLens()
		local current = lens:update(personal.profile(), function(data)
			return data
		end)
		if not current then
			return { status = "recovering", error = "PERSONAL_UNAVAILABLE" }
		end
		local bag = Inventory.fromSave(current.data.inventory, catalog)
		local owners: { string } = {}
		for owner in bag.reservations do
			if string.sub(owner, 1, #PREFIX) == PREFIX then
				table.insert(owners, owner)
			end
		end
		table.sort(owners)
		local settled = 0
		for index = 1, math.min(#owners, maximum) do
			local owner = owners[index]
			local tribeId = string.match(owner, "^camp:([^:]+):")
			local token = if tribeId then open(tribeId) else nil
			if token == nil then
				return { status = "recovering", error = "CAMP_UNAVAILABLE" }
			end
			local ok, reason
			if token.data.receipts[owner] ~= nil then
				ok, reason = consumeReserved(personal, owner)
			else
				ok, reason = releaseReserved(personal, owner)
			end
			if not ok then
				return { status = "recovering", error = reason or "SETTLE_FAILED" }
			end
			settled += 1
		end
		return { status = "confirmed", settled = settled }
	end
	function extension.close()
		for tribeId, token in tokens do
			local released, err = store:release(token)
			if not released then
				return { ok = false, reason = err }
			end
			tokens[tribeId] = nil
		end
		return { ok = true }
	end
	return extension
end

-- Registry entry: the bootstrap context supplies every trusted port.
function M.factory(ctx: any): Built?
	return M.new({
		content = ctx.content,
		store = ctx.store,
		now = ctx.now,
		settlement = ctx.settlement,
		personalTransfer = ctx.personalTransfer,
		members = ctx.members,
		isFriend = if ctx.world then (ctx.world :: any).isFriend else nil,
	})
end

return M
