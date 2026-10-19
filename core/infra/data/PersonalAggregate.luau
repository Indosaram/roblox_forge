--!strict
-- Opt-in namespace only. A full envelope is the sole owner of personal inventory.
local FencedStore = require("./FencedStore")
local MemoryBackend = require("./MemoryBackend")
local Catalog = require("../../domain/inventory/ItemCatalog")

export type Options = {
	namespace: string,
	store: FencedStore.Options,
	validateEnvelope: (any) -> boolean,
	inventoryPath: { string },
}
export type Replay = { epoch: number, requestId: string, binding: string }
export type Lens = {
	update: (Lens, FencedStore.Profile, FencedStore.Transform) -> (FencedStore.Profile?, string?),
	acquire: (Lens, string, FencedStore.Transform) -> (FencedStore.Profile?, string?),
}
local M = {}
M.__index = M
export type Store = typeof(setmetatable(
	{} :: {
		_store: FencedStore.Store,
		_options: Options,
	},
	M
))
local MAX = 9007199254740991

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in value do
		result[key] = copy(item)
	end
	return result
end
local function equal(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end
local function validate(self: Store, data: any)
	assert(type(data) == "table" and data.version == 1, "UNSUPPORTED_PERSONAL_VERSION")
	assert(Catalog.integer(data.stateRevision, 0, MAX), "INVALID_PERSONAL_REVISION")
	assert(self._options.validateEnvelope(data.envelope), "INVALID_PERSONAL_ENVELOPE")
	assert(
		type(data.itemTransfers) == "table"
			and data.itemTransfers.version == 1
			and type(data.itemTransfers.receipts) == "table",
		"INVALID_TRANSFER_SAVE"
	)
	for key in data do
		assert(
			key == "version" or key == "stateRevision" or key == "envelope" or key == "itemTransfers",
			"UNKNOWN_PERSONAL_FIELD"
		)
	end
end
local function owns(self: Store, key: string): boolean
	return string.sub(key, 1, #self._options.namespace + 1) == self._options.namespace .. ":"
end
local function bump(data: any)
	assert(data.stateRevision < MAX, "PERSONAL_REVISION_EXHAUSTED")
	data.stateRevision += 1
end

function M.new(backend: MemoryBackend.Backend, options: Options): Store
	assert(options.store.budget ~= nil, "PERSONAL_BYTE_BUDGET_REQUIRED")
	assert(
		type(options.namespace) == "string"
			and #options.namespace > 0
			and #options.namespace <= 24
			and string.match(options.namespace, "^[%w_-]+$"),
		"INVALID_PERSONAL_NAMESPACE"
	)
	assert(#options.inventoryPath > 0 and #options.inventoryPath <= 12, "INVALID_INVENTORY_PATH")
	for _, key in options.inventoryPath do
		assert(Catalog.identity(key), "INVALID_INVENTORY_PATH")
	end
	local opts = table.clone(options)
	opts.inventoryPath = table.clone(options.inventoryPath)
	return setmetatable({ _store = FencedStore.new(backend, options.store), _options = opts }, M)
end

function M.load(self: Store, id: string, initialize: () -> any): (FencedStore.Profile?, string?)
	if not Catalog.identity(id) then
		return nil, "INVALID_PERSONAL_ID"
	end
	return self._store:acquire(self._options.namespace .. ":" .. id, function(data)
		if next(data) == nil then
			data = {
				version = 1,
				stateRevision = 0,
				envelope = initialize(),
				itemTransfers = { version = 1, receipts = {} },
			}
		end
		validate(self, data)
		return data
	end)
end

-- Known durable outcomes are checked BEFORE CAS. Replay returns actual current
-- data and result; callers must hydrate it, never apply their obsolete stage.
function M.commit(
	self: Store,
	token: FencedStore.Profile,
	expected: number,
	envelope: any,
	replay: Replay?
): (FencedStore.Profile?, string?, any, boolean)
	if not owns(self, token.key) then
		return nil, "PERSONAL_NAMESPACE", nil, false
	end
	if not Catalog.integer(expected, 0, MAX) then
		return nil, "INVALID_PERSONAL_REVISION", nil, false
	end
	local candidate, binding = copy(envelope), copy(replay)
	local reason: string? = nil
	local outcome: any = nil
	local committed = false
	local profile, err = self._store:update(token, function(data)
		reason, outcome, committed = nil, nil, false
		validate(self, data)
		if binding then
			local ledger = data.envelope.commands
			local epoch = ledger and ledger.epochs[tostring(binding.epoch)]
			local known = epoch and epoch.outcomes[binding.requestId]
			if known then
				if self._options.store.now() >= known.expiresAt then
					reason = "REQUEST_EXPIRED"
				elseif known.binding ~= binding.binding then
					reason = "REQUEST_CONFLICT"
				else
					outcome = copy(known.result)
				end
				return data
			end
		end
		if data.stateRevision ~= expected then
			reason = "STALE_PERSONAL_REVISION"
			return data
		end
		assert(self._options.validateEnvelope(candidate), "INVALID_PERSONAL_ENVELOPE")
		if binding then
			local ledger = candidate.commands
			local epoch = ledger and ledger.epochs[tostring(binding.epoch)]
			local record = epoch and epoch.outcomes[binding.requestId]
			if not record or record.binding ~= binding.binding then
				reason = "MISSING_COMMAND_OUTCOME"
				return data
			end
			outcome = copy(record.result)
		end
		if not equal(data.envelope, candidate) then
			data.envelope = copy(candidate)
			bump(data)
			committed = true
		end
		return data
	end)
	if not profile then
		return nil, err, nil, false
	end
	return profile, reason, outcome, committed
end

-- Read-through refresh: returns the current committed aggregate so the caller stages
-- against fresh state. It must never publish an identity candidate: the per-frame
-- command drain calls this before every command, and an identity publish would turn
-- each read into a durable CAS write on the personal key.
function M.refresh(self: Store, token: FencedStore.Profile): (FencedStore.Profile?, string?)
	if not owns(self, token.key) then
		return nil, "PERSONAL_NAMESPACE"
	end
	return self._store:refresh(token, function(data)
		validate(self, data)
		return data
	end)
end
function M.renew(self: Store, token: FencedStore.Profile): (FencedStore.Profile?, string?)
	if not owns(self, token.key) then
		return nil, "PERSONAL_NAMESPACE"
	end
	return self._store:renew(token)
end
-- Preserve current data; final envelope capture must first pass commit's CAS.
function M.release(self: Store, token: FencedStore.Profile): (FencedStore.Profile?, string?)
	if not owns(self, token.key) then
		return nil, "PERSONAL_NAMESPACE"
	end
	return self._store:release(token)
end
function M.releaseLock(self: Store, token: FencedStore.Profile): (FencedStore.Profile?, string?)
	return self:release(token)
end

-- Inventory path inside the envelope (callers that edit the bag through `update`).
function M.inventoryPath(self: Store): { string }
	return table.clone(self._options.inventoryPath)
end

-- Full-envelope mutation for extensions that move value across fields in one atomic write
-- (bag + soft currency + a durable receipt). The transform receives a detached
-- `{ envelope, itemTransfers }` view and returns it; a changed view bumps the revision and
-- must still pass envelope validation. Returns the real (unprojected) fenced token.
function M.update(
	self: Store,
	token: FencedStore.Profile,
	transform: FencedStore.Transform
): (FencedStore.Profile?, string?)
	if not owns(self, token.key) then
		return nil, "PERSONAL_NAMESPACE"
	end
	return self._store:update(token, function(data)
		validate(self, data)
		local before = { envelope = copy(data.envelope), itemTransfers = copy(data.itemTransfers) }
		local after = transform(copy(before))
		for key in after do
			assert(key == "envelope" or key == "itemTransfers", "UNKNOWN_PERSONAL_VIEW_FIELD")
		end
		if not equal(before, after) then
			data.envelope = copy(after.envelope)
			data.itemTransfers = copy(after.itemTransfers)
			bump(data)
			validate(self, data)
		end
		return data
	end)
end

-- Lens tokens still carry the actual fenced key/session/generation. data is only
-- a transient projected view; FencedStore never uses it as the durable input.
function M.inventoryLens(self: Store): Lens
	local function view(data: any): any
		local inventory = data.envelope
		for _, key in self._options.inventoryPath do
			inventory = inventory[key]
		end
		return { inventory = copy(inventory), itemTransfers = copy(data.itemTransfers) }
	end
	local function transformData(transform: FencedStore.Transform): FencedStore.Transform
		return function(data)
			validate(self, data)
			local before = view(data)
			local after = transform(copy(before))
			for key in after do
				assert(key == "inventory" or key == "itemTransfers", "UNKNOWN_LENS_FIELD")
			end
			if not equal(before, after) then
				local parent = data.envelope
				local path = self._options.inventoryPath
				for index = 1, #path - 1 do
					parent = parent[path[index]]
				end
				parent[path[#path]] = copy(after.inventory)
				data.itemTransfers = copy(after.itemTransfers)
				bump(data)
				validate(self, data)
			end
			return data
		end
	end
	local function projected(profile: FencedStore.Profile?, err: string?): (FencedStore.Profile?, string?)
		if not profile then
			return nil, err
		end
		local result = table.clone(profile)
		result.data = view(profile.data)
		return result, err
	end
	local lens: Lens
	lens = {
		update = function(_lens, token, transform)
			if not owns(self, token.key) then
				return nil, "PERSONAL_NAMESPACE"
			end
			return projected(self._store:update(token, transformData(transform)))
		end,
		acquire = function(_lens, key, transform)
			if not owns(self, key) then
				return nil, "PERSONAL_NAMESPACE"
			end
			return projected(self._store:acquire(key, transformData(transform)))
		end,
	}
	return lens
end

return M
