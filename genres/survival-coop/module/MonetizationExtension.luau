--!strict
-- Monetization runtime for survival-coop (plan 8.1/8.2, ADR-07): deterministic Robux items only.
-- A pack calls `configure` once (catalog from its generated MonetizationConfig, engine ports,
-- optional grant hooks); with no configuration the factory stays disabled. Receipts go through
-- core Receipts (idempotent grant + durable commit), subscription prompts through core
-- Subscription (PolicyService gate before any prompt), and every grant persists in a per-actor
-- Fenced profile with an explicit save version. Nothing here rolls dice or reads a wall clock.
local Shared = require("../../../core/domain/genre/Contract")
local Fenced = require("../../../core/infra/data/FencedStore")
local Catalog = require("../../../core/infra/monetization/Catalog")
local MarketplacePort = require("../../../core/infra/monetization/MarketplacePort")
local PolicyPort = require("../../../core/infra/monetization/PolicyPort")
local Receipts = require("../../../core/infra/monetization/Receipts")
local Subscription = require("../../../core/infra/monetization/Subscription")

local M = {}

M.SAVE_VERSION = 1
local PROMPT = "survival-coop:shop-prompt"
local SYNC = "survival-coop:shop-sync"

export type Listing = { key: string, name: string, price: number, id: any, grant: Catalog.Grant }
export type Listings = { gamepasses: { Listing }?, products: { Listing }?, subscriptions: { Listing }? }
export type Hooks = {
	-- Total extra warehouse slots the actor is entitled to (pass + subscription); re-applied on load.
	warehouseSlots: ((actor: string, bonus: number) -> ())?,
	-- A cosmetic skin id (a Mounts skin id) the actor now owns; re-applied on load.
	skinUnlocked: ((actor: string, skinId: string) -> ())?,
}
export type Config = {
	catalog: Listings,
	marketplace: MarketplacePort.Port,
	policy: PolicyPort.Port,
	hooks: Hooks?,
}
type Context = { store: () -> Fenced.Store, now: () -> number }
type State = {
	saveVersion: number,
	version: number,
	purchases: { [string]: string },
	grants: number,
	skins: { [string]: boolean },
	passes: { [string]: boolean },
	subscription: { active: boolean, setId: string?, slots: number },
}
type Entry = { profile: Fenced.Profile, state: State, prompts: number }

local configured: Config? = nil
local NO_LISTINGS: { Listing } = {}
local NO_HOOKS: Hooks = {}

--- Pack wiring: validates the catalog against the ADR-07 rules and enables the factory.
function M.configure(config: Config?)
	if config ~= nil then
		local ok, reason = Catalog.validate(config.catalog)
		assert(ok, reason)
		local violations = Catalog.lint(config.catalog)
		assert(#violations == 0, table.concat(violations, "; "))
	end
	configured = config
end

local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = clone(item)
	end
	return copy
end

local function fresh(): State
	return {
		saveVersion = M.SAVE_VERSION,
		version = 0,
		purchases = {},
		grants = 0,
		skins = {},
		passes = {},
		subscription = { active = false, setId = nil, slots = 0 },
	}
end

local function isConfigured(id: any): boolean
	return id ~= nil and id ~= 0 and id ~= ""
end

function M.migrate(data: Fenced.Data): Fenced.Data
	if next(data) == nil then
		return fresh() :: any
	end
	assert(data.saveVersion == M.SAVE_VERSION, "UNSUPPORTED_MONETIZATION_SAVE")
	assert(type(data.purchases) == "table" and type(data.skins) == "table", "INVALID_MONETIZATION_SAVE")
	return data
end

local function sections(catalog: Listings): { { name: string, kind: string, list: { Listing } } }
	return {
		{ name = "gamepasses", kind = "pass", list = (catalog.gamepasses or NO_LISTINGS) :: { Listing } },
		{ name = "products", kind = "product", list = (catalog.products or NO_LISTINGS) :: { Listing } },
		{ name = "subscriptions", kind = "subscription", list = catalog.subscriptions or NO_LISTINGS },
	}
end

function M.factory(ctx: Context): (Shared.Extension & { close: (() -> Shared.Result)? })?
	local config = configured
	if config == nil then
		return nil
	end
	local catalog, marketplace, policy = config.catalog, config.marketplace, config.policy
	local hooks: Hooks = config.hooks or NO_HOOKS
	local store = ctx.store()
	local entries: { [string]: Entry } = {}
	local closed = false

	local function find(key: any): (Listing?, string?)
		for _, section in sections(catalog) do
			for _, listing in section.list do
				if listing.key == key then
					return listing, section.kind
				end
			end
		end
		return nil, nil
	end
	local function storageBonus(state: State): number
		local total = 0
		for _, listing in (catalog.gamepasses or NO_LISTINGS) :: { Listing } do
			if state.passes[listing.key] and listing.grant.kind == "storageSlots" then
				total += listing.grant.amount or 0
			end
		end
		if state.subscription.active then
			total += state.subscription.slots
		end
		return total
	end
	local function announce(actor: string, state: State)
		if hooks.warehouseSlots then
			hooks.warehouseSlots(actor, storageBonus(state))
		end
		if hooks.skinUnlocked then
			for skin in state.skins do
				hooks.skinUnlocked(actor, skin)
			end
		end
	end
	local function load(actor: string): Entry?
		local existing = entries[actor]
		if existing then
			return existing
		end
		if closed then
			return nil
		end
		local profile = store:acquire("mon:" .. actor, M.migrate)
		if not profile then
			return nil
		end
		local entry: Entry = { profile = profile, state = clone(profile.data), prompts = 0 }
		entries[actor] = entry
		announce(actor, entry.state)
		return entry
	end
	local function persist(entry: Entry): boolean
		entry.state.version += 1
		local snapshot = clone(entry.state)
		local updated = store:update(entry.profile, function(_data)
			return snapshot
		end)
		if not updated then
			return false
		end
		entry.profile = updated
		return true
	end
	-- Deterministic product grants only: a fixed cosmetic skin id, never a pool or a roll.
	local function applyProduct(state: State, listing: Listing): boolean
		local grant = listing.grant
		if grant.kind == "cosmeticSet" and grant.cosmeticSetId ~= nil then
			state.skins[grant.cosmeticSetId] = true
			state.grants += 1
			return true
		end
		return false
	end
	local function productFor(productId: number): Listing?
		for _, listing in (catalog.products or NO_LISTINGS) :: { Listing } do
			if isConfigured(listing.id) and listing.id == productId then
				return listing
			end
		end
		return nil
	end

	marketplace.onReceipt(function(receipt)
		local actor = tostring(receipt.PlayerId)
		local entry = load(actor)
		local listing = productFor(receipt.ProductId)
		if entry == nil or listing == nil then
			return "NotProcessedYet"
		end
		-- One processor per receipt, bound to the owning actor's staged state.
		local processor = Receipts.new({
			grant = function(_userId, _key)
				return applyProduct(entry.state, listing)
			end,
			hasProcessed = function(purchaseId)
				return entry.state.purchases[purchaseId] ~= nil
			end,
			markProcessed = function(purchaseId)
				entry.state.purchases[purchaseId] = listing.key
			end,
			productKeyFor = function(_productId)
				return listing.key
			end,
			commit = function(_userId)
				local committed = persist(entry)
				if committed then
					announce(actor, entry.state)
				end
				return committed
			end,
		})
		return processor:process(receipt)
	end)

	local function view(entry: Entry): { [string]: any }
		local rows: { any } = {}
		for _, section in sections(catalog) do
			for _, listing in section.list do
				local owned = if section.kind == "pass"
					then entry.state.passes[listing.key] == true
					elseif section.kind == "subscription" then entry.state.subscription.active
					else listing.grant.cosmeticSetId ~= nil and entry.state.skins[listing.grant.cosmeticSetId] == true
				table.insert(rows, {
					key = listing.key,
					kind = section.kind,
					name = listing.name,
					price = listing.price,
					configured = isConfigured(listing.id),
					owned = owned,
				})
			end
		end
		return {
			saveVersion = entry.state.saveVersion,
			skins = clone(entry.state.skins),
			passes = clone(entry.state.passes),
			subscription = clone(entry.state.subscription),
			storageBonus = storageBonus(entry.state),
			grants = entry.state.grants,
			promptsIssued = entry.prompts,
			catalog = rows,
		}
	end

	local extension = {
		id = "monetization",
		handles = function(action: string): boolean
			return action == PROMPT or action == SYNC
		end,
		command = function(actor, action, args, _context, _origin, admit): Shared.Result
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local userId = tonumber(actor)
			local entry = load(actor)
			if userId == nil or entry == nil then
				return { ok = false, reason = "SHOP_UNAVAILABLE" }
			end
			if action == SYNC then
				local ok = pcall(function()
					for _, listing in (catalog.gamepasses or NO_LISTINGS) :: { Listing } do
						if isConfigured(listing.id) and marketplace.ownsGamePass(userId, listing.id) then
							entry.state.passes[listing.key] = true
						end
					end
					local subscription = ((catalog.subscriptions or NO_LISTINGS) :: { Listing })[1]
					if subscription and isConfigured(subscription.id) then
						local active = marketplace.subscriptionActive(userId, tostring(subscription.id))
						entry.state.subscription = {
							active = active,
							setId = subscription.grant.cosmeticSetId,
							slots = subscription.grant.storageSlots or 0,
						}
						if active and subscription.grant.cosmeticSetId ~= nil then
							entry.state.skins[subscription.grant.cosmeticSetId] = true
						end
					end
				end)
				if not ok then
					return { ok = false, reason = "MARKETPLACE_UNAVAILABLE" }
				end
				if not persist(entry) then
					return { ok = false, reason = "SAVE_FAILED" }
				end
				announce(actor, entry.state)
				return {
					ok = true,
					stateVersion = entry.state.version,
					data = { storageBonus = storageBonus(entry.state) },
				}
			end
			local listing, kind = find(args[1])
			if listing == nil then
				return { ok = false, reason = "UNKNOWN_PRODUCT" }
			end
			if not isConfigured(listing.id) then
				return { ok = false, reason = "PRODUCT_NOT_CONFIGURED" }
			end
			if kind == "subscription" then
				local result = Subscription.promptIfEligible(policy, {
					prompt = function(player: any, subscriptionId: string)
						marketplace.promptSubscription(player, subscriptionId)
					end,
				}, userId, tostring(listing.id))
				if result == "ineligible" then
					return { ok = false, reason = "SUBSCRIPTION_INELIGIBLE" }
				elseif result == "policyError" then
					return { ok = false, reason = "POLICY_UNAVAILABLE" }
				end
			elseif kind == "pass" then
				if entry.state.passes[listing.key] then
					return { ok = false, reason = "ALREADY_OWNED" }
				end
				marketplace.promptGamePass(userId, listing.id)
			else
				local skin = listing.grant.cosmeticSetId
				if skin ~= nil and entry.state.skins[skin] then
					return { ok = false, reason = "ALREADY_OWNED" }
				end
				marketplace.promptProduct(userId, listing.id)
			end
			entry.prompts += 1
			return { ok = true, stateVersion = entry.state.version, data = { prompted = listing.key } }
		end,
		snapshot = function(actor: string): (Shared.StateData?, string?)
			local entry = load(actor)
			if entry == nil then
				return nil, "SHOP_UNAVAILABLE"
			end
			return view(entry) :: any, nil
		end,
		close = function(): Shared.Result
			closed = true
			for actor, entry in entries do
				local released, err = store:release(entry.profile)
				if not released then
					return { ok = false, reason = err or "RELEASE_FAILED" }
				end
				entries[actor] = nil
			end
			return { ok = true }
		end,
	}
	return extension :: any
end

return M
