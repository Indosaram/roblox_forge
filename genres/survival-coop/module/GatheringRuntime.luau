--!strict
-- Server-only source owner. Acceptance is one fenced node+mint+grant commit.
-- Session supplies its sole personal owner port and serializes command/recovery.
local Gathering = require("./Gathering")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Content = require("../../../core/domain/survival/Content")
local Job = require("../../../core/domain/crafting/Job")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Ledger = require("../../../core/domain/command/Ledger")
local Transfer = require("../../../core/infra/data/ItemTransfer")
local Fenced = require("../../../core/infra/data/FencedStore")
local Personal = require("../../../core/infra/data/PersonalAggregate")
local Skills = require("./Skills")
local Events = require("../../../core/infra/analytics/Events")
local M = {}
export type PersonalPort = {
	personal: Personal.Store,
	profile: () -> Fenced.Profile,
	install: (Fenced.Profile) -> (),
}
export type Request = {
	actorId: string,
	sessionEpoch: number,
	requestId: string,
	nodeId: string,
	nodeVersion: number,
	expiresAt: number,
}
export type Config = {
	key: string,
	initial: Gathering.State,
	content: Content.Document,
	now: () -> number,
	nowMillis: () -> number,
	maxReceipts: number,
	resolvePersonal: (string) -> PersonalPort?,
	-- Must validate current actor/epoch and trusted equipment/reach at EACH
	-- source callback. bag is refreshed from the sole personal owner. Session's
	-- busy gate excludes local bag mutation; external lease takeover is checked
	-- again on destination credit. This is authorization, not a bag debit.
	access: (Request, Inventory.State, Fenced.Data) -> Gathering.Access?,
	-- Optional core analytics emitter: one gather event per newly accepted
	-- source commit (never for idempotent replays or rejections).
	analytics: Events.Emitter?,
}
export type Result = { status: string, error: string?, transfers: { Transfer.Result }, skillError: string? }
export type Runtime = {
	command: (Request) -> Result,
	recover: (string, number) -> Result,
	snapshot: () -> (Fenced.Data?, string?),
}
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
local function failed(err: string, status: string?): Result
	return { status = status or "rejected", error = err, transfers = {} }
end

function M.new(config: Config, store: Fenced.Store): (Runtime?, string?)
	assert(Catalog.integer(config.maxReceipts, 1, 4096), "INVALID_RECEIPT_LIMIT")
	local content = copy(config.content)
	local catalog = Job.catalog(content)
	-- Nil when the pack declares no skills section: gathering is then unchanged.
	local mastery = Skills.catalog(content)
	-- Awards a freshly accepted gather's node XP into the actor's personal
	-- crafting save. At most once: only the single CAS-won acceptance of a grant
	-- reaches this, and a replayed or recovered grant never does. A failed
	-- personal write forfeits the XP rather than risking a double award.
	local function awardSkill(personal: PersonalPort, grant: Content.SkillGrant, tools: Inventory.State): string?
		if not mastery then
			return nil
		end
		local current, err = personal.personal:refresh(personal.profile())
		if not current then
			return err or "PERSONAL_UNAVAILABLE"
		end
		local envelope = copy(current.data.envelope)
		local slice = envelope.genres and envelope.genres["survival-coop"]
		local data = slice and slice.data
		if type(data) ~= "table" or data.saveVersion == nil then
			return "SKILLS_UNAVAILABLE"
		end
		data.skills = (Skills.grantSaved(mastery, data.skills, grant, tools))
		local saved, commitError = personal.personal:commit(current, current.data.stateRevision, envelope, nil)
		if saved then
			personal.install(saved)
		end
		return if saved then commitError else commitError or "PERSONAL_UNKNOWN"
	end
	local function replenish(data: Fenced.Data)
		data.respawns = data.respawns or {}
		for id, node in data.nodes.nodes do
			local timer = data.respawns[id]
			if not timer then
				timer = { capacity = config.initial.nodes[id].charges }
				data.respawns[id] = timer
			end
			if timer.deadline and config.nowMillis() >= timer.deadline then
				node.charges = timer.capacity
				data.nodes.version += 1
				timer.deadline = nil
			end
		end
	end
	local token, loadError = store:acquire(config.key, function(data)
		if next(data) == nil then
			return {
				version = 1,
				nodes = Gathering.snapshot(config.initial),
				grants = {},
				itemTransfers = { version = 1, receipts = {} },
			}
		end
		assert(data.version == 1 and type(data.grants) == "table", "INVALID_GATHERING_SAVE")
		assert(data.nodes.worldRevision == config.initial.worldRevision, "WRONG_WORLD")
		return data
	end)
	if not token then
		return nil, loadError
	end
	local source: Fenced.Profile = token
	local function advance(personal: PersonalPort, grants: { any }): Result
		local lens = personal.personal:inventoryLens()
		local destinationKey = personal.profile().key
		assert(destinationKey ~= config.key, "SAME_OWNER")
		local router: Transfer.StorePort = {
			update = function(_self, expected, transform)
				if expected.key == config.key then
					local updated, err = store:update(expected, transform)
					if updated then
						source = updated
					end
					return updated, err
				end
				if expected.key ~= destinationKey then
					return nil, "WRONG_DESTINATION"
				end
				local updated, err = lens:update(expected, transform)
				if updated then
					local current, refreshError = personal.personal:refresh(updated)
					if not current then
						return nil, refreshError
					end
					personal.install(current)
				end
				return updated, err
			end,
			acquire = function()
				return nil, "MINT_RETAINED"
			end,
		}
		local coordinator = Transfer.new(router, catalog, {
			maxReceipts = config.maxReceipts,
			now = config.now,
			authorize = function()
				return false -- all accepted grants already entered irrevocable escrow
			end,
		})
		local result: Result = { status = "confirmed", transfers = {} }
		for _, grant in grants do
			for _, mint in grant.mints do
				local progressed = coordinator:advance(source, personal.profile(), mint.request, nil)
				table.insert(result.transfers, progressed)
				if progressed.status ~= "confirmed" then
					result.status = "pending"
					result.error = progressed.error or result.error
				end
			end
		end
		return result
	end
	local runtime = {} :: Runtime
	function runtime.command(request)
		local req: Request = copy(request)
		if
			not Catalog.identity(req.actorId)
			or not Catalog.identity(req.requestId)
			or not Catalog.identity(req.nodeId)
			or not Catalog.integer(req.sessionEpoch, 0, 2 ^ 53 - 1)
			or not Catalog.integer(req.nodeVersion, 0, 2 ^ 53 - 2)
			or not Catalog.integer(req.expiresAt, 0, 2 ^ 53 - 1)
		then
			return failed("INVALID_REQUEST")
		end
		local id =
			string.format("g%d:%s:%d:%d:%s", #req.actorId, req.actorId, req.sessionEpoch, #req.requestId, req.requestId)
		if #id > 100 then
			return failed("INVALID_GATHER_IDENTITY")
		end
		local personal = config.resolvePersonal(req.actorId)
		if not personal then
			return failed("PERSONAL_UNAVAILABLE", "recovering")
		end
		local lens = personal.personal:inventoryLens()
		local destinationKey = personal.profile().key
		assert(destinationKey ~= config.key, "SAME_OWNER")
		local binding = Ledger.canonical({ request = req, destination = destinationKey })
		local current, refreshError = lens:update(personal.profile(), function(data)
			return data
		end)
		if not current then
			return failed(refreshError or "PERSONAL_UNAVAILABLE", "recovering")
		end
		local bag = Inventory.fromSave(current.data.inventory, catalog)
		local reason: string? = nil
		local accepted: any = nil
		local fresh: { grant: Content.SkillGrant, tools: Inventory.State }? = nil
		local gathered: number? = nil
		local updated, err = store:update(source, function(data)
			reason, accepted, fresh, gathered = nil, nil, nil, nil
			local known = data.grants[id]
			if known then
				if known.binding ~= binding then
					reason = "REQUEST_CONFLICT"
				elseif config.now() >= req.expiresAt then
					reason = "REQUEST_EXPIRED"
				else
					accepted = copy(known)
				end
				return data
			end
			if req.expiresAt <= (data.expiredBefore or -1) or config.now() >= req.expiresAt then
				reason = "REQUEST_EXPIRED"
				return data
			end
			replenish(data)
			local count = 0
			for _ in data.grants do
				count += 1
			end
			if count >= config.maxReceipts then
				reason = "RECEIPT_LIMIT"
				return data
			end
			local access = config.access(copy(req), Inventory.snapshot(bag), data)
			if not access or access.actorId ~= req.actorId or access.carriedContainer ~= bag.id then
				reason = "UNAUTHORIZED"
				return data
			end
			-- Only equipped, available tools are transient evidence. Personal items
			-- are never persisted at source. Destination capacity is checked later.
			local staging = Inventory.new(bag.id, { slots = 20, softWeightMilli = 90000, hardWeightMilli = 90000 })
			local equipped = access.equipment(req.actorId)
			for itemId, item in bag.items do
				if equipped and equipped[itemId] and Inventory.available(bag, itemId) > 0 then
					staging.items[itemId] = copy(item)
				end
			end
			local candidate, gatherError =
				Gathering.gather(data.nodes, staging, req, content, req.nodeId, req.nodeVersion, access)
			if not candidate then
				reason = gatherError
				return data
			end
			local mints: { Transfer.Mint } = {}
			for _, itemId in candidate.itemIds do
				local item = candidate.inventory.items[itemId]
				table.insert(mints, {
					item = copy(item),
					request = {
						id = itemId,
						actor = req.actorId,
						epoch = tostring(req.sessionEpoch),
						expiresAt = req.expiresAt,
						source = config.key,
						destination = destinationKey,
						itemId = itemId,
						outputId = itemId,
						quantity = item.quantity,
					},
				})
			end
			local minted, mintError = Transfer.stageMint(data, catalog, config.key, binding, mints, {
				maxReceipts = config.maxReceipts,
				now = config.now,
				authorize = function()
					return true -- access and Gathering validated in this exact source callback
				end,
			}, nil)
			if not minted then
				reason = mintError
				return data
			end
			minted.nodes = candidate.nodes
			if candidate.nodes.nodes[req.nodeId].charges == 0 then
				for _, definition in content.nodes do
					if definition.id == candidate.nodes.nodes[req.nodeId].catalogId then
						minted.respawns[req.nodeId].deadline = config.nowMillis() + definition.respawnMillis
						break
					end
				end
			end
			accepted = { binding = binding, mints = mints, destination = destinationKey }
			local total = 0
			for _, mint in mints do
				total += mint.item.quantity
			end
			gathered = total
			minted.grants[id] = copy(accepted)
			if mastery then
				local catalogId = candidate.nodes.nodes[req.nodeId].catalogId
				for _, definition in content.nodes do
					if definition.id == catalogId and definition.skill then
						-- Tier comes from the trusted equipped tools staged above.
						fresh = { grant = copy(definition.skill), tools = Inventory.snapshot(staging) }
					end
				end
			end
			return minted
		end)
		if not updated then
			return failed(err or "SOURCE_UNKNOWN", "recovering")
		end
		source = updated
		if reason then
			return failed(reason, if reason == "REQUEST_CONFLICT" then "conflict" else nil)
		end
		local progressed = advance(personal, { accepted })
		if gathered and config.analytics then
			config.analytics:emit("gather", {
				actorId = req.actorId,
				nodeId = req.nodeId,
				quantity = gathered,
				atMillis = config.nowMillis(),
			})
		end
		if fresh then
			local skillError = awardSkill(personal, fresh.grant, fresh.tools)
			if skillError then
				progressed.skillError = skillError
			end
		end
		return progressed
	end
	function runtime.recover(actor, maximum)
		assert(Catalog.integer(maximum, 1, 64), "INVALID_RECOVERY_BOUND")
		local personal = config.resolvePersonal(actor)
		if not personal then
			return failed("PERSONAL_UNAVAILABLE", "pending")
		end
		local destinationKey = personal.profile().key
		-- Session-scoped key: this process's `source` is the complete, current
		-- view. Only pay for the durable scan when a respawn deadline has
		-- matured, timers are missing, or a grant actually waits for this
		-- member — the quiet-state sweep must cost zero requests.
		local sessionData = source.data
		local work = false
		for id in sessionData.nodes.nodes do
			local timer = if sessionData.respawns then sessionData.respawns[id] else nil
			if timer == nil or (timer.deadline and config.nowMillis() >= timer.deadline) then
				work = true
				break
			end
		end
		if not work and sessionData.cursors == nil then
			work = true
		end
		if not work then
			for _, grant in sessionData.grants do
				if grant.destination == destinationKey then
					for _, mint in grant.mints do
						local receipt = sessionData.itemTransfers.receipts[mint.request.id]
						if
							mint.request.actor == actor
							and (not receipt or receipt.phase ~= "FINALIZED" or config.now() >= mint.request.expiresAt)
						then
							work = true
							break
						end
					end
				end
				if work then
					break
				end
			end
		end
		if not work then
			-- Identical to scanning and finding nothing: advance with an empty
			-- batch touches no store at all.
			return advance(personal, {})
		end
		local selected: { any } = {}
		local retiring: { any } = {}
		local updated, err = store:update(source, function(data)
			selected = {}
			retiring = {}
			replenish(data)
			local ids: { string } = {}
			local byId: { [string]: Transfer.Mint } = {}
			local owners: { [string]: string } = {}
			for grantId, grant in data.grants do
				if grant.destination == destinationKey then
					for _, mint in grant.mints do
						local id = mint.request.id
						local receipt = data.itemTransfers.receipts[id]
						if
							mint.request.actor == actor
							and (not receipt or receipt.phase ~= "FINALIZED" or config.now() >= mint.request.expiresAt)
						then
							table.insert(ids, id)
							byId[id] = mint
							owners[id] = grantId
						end
					end
				end
			end
			table.sort(ids)
			data.cursors = data.cursors or {}
			local cursor = data.cursors[destinationKey]
			local start = 1
			if cursor then
				for index, id in ids do
					if id > cursor then
						start = index
						break
					end
				end
			end
			for offset = 0, math.min(maximum, #ids) - 1 do
				local id = ids[(start + offset - 1) % #ids + 1]
				local receipt = data.itemTransfers.receipts[id]
				if not receipt or (receipt.phase == "FINALIZED" and config.now() >= byId[id].request.expiresAt) then
					table.insert(retiring, { mint = copy(byId[id]), grantId = owners[id] })
				else
					table.insert(selected, { mints = { copy(byId[id]) } })
				end
				data.cursors[destinationKey] = id
			end
			return data
		end)
		if not updated then
			return failed(err or "SOURCE_UNKNOWN", "recovering")
		end
		source = updated
		local result = advance(personal, selected)
		for _, entry in retiring do
			local req = entry.mint.request
			local lens = personal.personal:inventoryLens()
			-- Fence every pre-cleanup destination writer before removing its receipt.
			local marked, markError = lens:acquire(destinationKey, function(data)
				return data
			end)
			if not marked then
				return failed(markError or "PERSONAL_UNAVAILABLE", "recovering")
			end
			local hydrated, hydrateError = personal.personal:refresh(marked)
			if not hydrated then
				return failed(hydrateError or "PERSONAL_UNAVAILABLE", "recovering")
			end
			personal.install(hydrated)
			local cleared, clearError = store:update(source, function(data)
				local receipt = data.itemTransfers.receipts[req.id]
				assert(not receipt or receipt.phase == "FINALIZED", "MINT_NOT_FINALIZED")
				data.expiredBefore = math.max(data.expiredBefore or -1, req.expiresAt)
				data.itemTransfers.receipts[req.id] = nil
				return data
			end)
			if not cleared then
				return failed(clearError or "SOURCE_UNKNOWN", "recovering")
			end
			source = cleared
			local removed, removeError = lens:update(personal.profile(), function(data)
				data.itemTransfers.receipts[req.id] = nil
				return data
			end)
			if not removed then
				return failed(removeError or "PERSONAL_UNAVAILABLE", "recovering")
			end
			local current, refreshError = personal.personal:refresh(removed)
			if not current then
				return failed(refreshError or "PERSONAL_UNAVAILABLE", "recovering")
			end
			personal.install(current)
			local retired, retireError = store:update(source, function(data)
				local grant = data.grants[entry.grantId]
				for index, mint in grant.mints do
					if mint.request.id == req.id then
						table.remove(grant.mints, index)
						break
					end
				end
				if #grant.mints == 0 then
					data.grants[entry.grantId] = nil
				end
				return data
			end)
			if not retired then
				return failed(retireError or "SOURCE_UNKNOWN", "recovering")
			end
			source = retired
		end
		return result
	end
	function runtime.snapshot()
		local updated, err = store:renew(source)
		if not updated then
			return nil, err
		end
		source = updated
		return copy(updated.data), nil
	end
	return runtime, nil
end
return M
