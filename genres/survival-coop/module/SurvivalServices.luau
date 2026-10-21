--!strict
-- One tribe owner per key; Session remains the only personal aggregate owner.
local Settlement = require("./SettlementRuntime")
local SettlementBridge = require("./SettlementBridge")
local Transfer = require("./TransferRuntime")
local TransferBridge = require("./TransferBridge")
local Session = require("../../../core/infra/genre/Session")
local Options = require("../../../core/infra/genre/Options")
local Fenced = require("../../../core/infra/data/FencedStore")
local ProfileStore = require("../../../core/infra/data/ProfileStore")
local Shared = require("../../../core/domain/genre/Contract")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local CapacityPolicy = require("../../../core/domain/survival/CapacityPolicy")
local M = {}
export type Config = {
	tribes: { Settlement.Config },
	maxServerPlayers: number,
	maxPlots: number,
	maxReceipts: number,
	-- Trusted persistent routing, including former members with accepted recovery.
	tribeFor: (string) -> string?,
	authorize: (string, string, { any }, SettlementBridge.Origin) -> Shared.Result,
	-- Must verify accepted invitation consent, never merely trust server origin.
	consent: (string, string) -> boolean,
	proof: (string, string) -> any,
}
export type Factory = {
	services: Options.Services,
	bind: (Session.Session) -> (),
	close: () -> Shared.Result,
}
function M.new(config: Config, backend: ProfileStore.Backend, options: Fenced.Options): (Factory?, string?)
	assert(Catalog.integer(config.maxServerPlayers, 1, 8), "INVALID_SERVER_LIMIT")
	assert(Catalog.integer(config.maxPlots, 1, 4) and #config.tribes <= config.maxPlots, "INVALID_PLOT_LIMIT")
	assert(Catalog.integer(config.maxReceipts, 1, 4096), "INVALID_RECEIPT_LIMIT")
	assert(options.budget ~= nil, "TRIBE_BYTE_BUDGET_REQUIRED")
	local owners: { [string]: Settlement.Runtime } = {}
	local settings: { [string]: Settlement.Config } = {}
	local keys: { [string]: boolean } = {}
	for _, entry in config.tribes do
		local id = entry.initial.settlement.config.tribeId
		assert(not settings[id] and not keys[entry.key], "DUPLICATE_TRIBE_OWNER")
		assert(
			Catalog.integer(
				entry.initial.settlement.config.maxMembers,
				1,
				CapacityPolicy.forVersion(entry.initial.settlement.config.contentVersion).clanMembers
			),
			"INVALID_MEMBER_LIMIT"
		)
		settings[id], keys[entry.key] = entry, true
	end
	for _, entry in config.tribes do
		local owner, err = Settlement.new(entry, Fenced.new(backend, options))
		if not owner then
			for _, opened in owners do
				opened.close()
			end
			return nil, err
		end
		owners[entry.initial.settlement.config.tribeId] = owner
	end
	local active: Session.Session? = nil
	local closed = false
	local function resolve(actor: string): Settlement.Runtime?
		if closed then
			return nil
		end
		local id = config.tribeFor(actor)
		return if id then owners[id] else nil
	end
	-- A runtime is minted per call; this server-lifetime memo of grants seen FINALIZED keeps the
	-- heartbeat recovery sweep from re-advancing finished transfers on every tick.
	local finalized: { [string]: boolean } = {}
	local function transfer(actor: string): Transfer.Runtime?
		local session = active
		local tribe = resolve(actor)
		if not session or not tribe then
			return nil
		end
		local port = session.personalTransfer(actor)
		if not port then
			return nil
		end
		assert(#session.members() <= config.maxServerPlayers, "SERVER_PLAYER_LIMIT")
		local entry = settings[tribe.link().tribeId]
		assert(not keys[port.profile().key], "PERSONAL_TRIBE_KEY_COLLISION")
		return Transfer.new({
			personal = port.personal,
			profile = port.profile,
			install = port.install,
			tribe = tribe.transferStore(),
			catalog = entry.catalog,
			now = entry.now,
			maxReceipts = config.maxReceipts,
			finalized = finalized,
		})
	end
	local settlement = SettlementBridge.new({
		resolve = resolve,
		authorize = function(actor, action, args, origin)
			local result = config.authorize(actor, action, args, origin)
			if not result.ok then
				return result
			end
			if action == "survival-coop:settlement-invite" and not config.consent(actor, args[1]) then
				return { ok = false, reason = "CONSENT_REQUIRED" }
			end
			return result
		end,
	})
	local bridge = TransferBridge.new({
		resolve = transfer,
		epoch = function(actor)
			local tribe = resolve(actor)
			if not tribe then
				return nil, "SETTLEMENT_UNAVAILABLE"
			end
			return tribe.epoch(actor)
		end,
		request = function(actor, action, args, context, _origin)
			local tribe, runtime = resolve(actor), transfer(actor)
			local session = active
			local port = if session then session.personalTransfer(actor) else nil
			if not tribe or not runtime or not port then
				return nil, nil, nil, "TRANSFER_UNAVAILABLE"
			end
			local window = tribe.epochWindow(actor, context.sessionEpoch)
			local request, err = runtime.resolveRequest({
				actor = actor,
				epoch = context.sessionEpoch,
				requestId = context.requestId,
				direction = if action == "survival-coop:transfer-deposit" then "deposit" else "withdraw",
				itemId = args[1],
				quantity = args[2],
				personalKey = port.profile().key,
			}, if window then window.expiresAt else nil)
			local state = tribe.snapshot(actor)
			return request, if state then state.settlement.membershipRevision else 0, config.proof(actor, action), err
		end,
	})
	local api = { services = { survivalSettlement = settlement, survivalTransfer = bridge } }
	function api.bind(session: Session.Session)
		assert(not closed and active == nil, "SERVICES_ALREADY_BOUND_OR_CLOSED")
		active = session
	end
	function api.close(): Shared.Result
		if active and #active.members() > 0 then
			return { ok = false, reason = "PLAYERS_ACTIVE" }
		end
		for id, owner in owners do
			local result = owner.close()
			if not result.ok then
				return result
			end
			owners[id] = nil
		end
		closed = true
		return { ok = true }
	end
	return api, nil
end
return M
