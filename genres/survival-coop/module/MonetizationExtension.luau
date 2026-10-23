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
local Effects = require("./EntitlementEffects")

local Session = require("../../../core/infra/genre/Session")
local M = {}

M.SAVE_VERSION = 1
local PROMPT = "survival-coop:shop-prompt"
local SYNC = "survival-coop:shop-sync"
local SELECT = "survival-coop:skin-select"

export type Listing = { key: string, name: string, price: number, id: any, grant: Catalog.Grant }
export type Listings = { gamepasses: { Listing }?, products: { Listing }?, subscriptions: { Listing }? }
export type Hooks = {
	-- Total extra warehouse slots the actor is entitled to (pass + subscription); re-applied on load.
	warehouseSlots: ((actor: string, bonus: number) -> ())?,
	-- A cosmetic skin id (a Mounts skin id) the actor now owns; re-applied on load.
	skinUnlocked: ((actor: string, skinId: string) -> ())?,
	skinSupported: ((skinId: string) -> boolean)?,
	skinSelect: ((actor: string, skinId: string) -> Shared.Result)?,
	skinResync: ((actor: string) -> Shared.Result)?,
	-- Selection slot of a cosmetic (one selected cosmetic per slot); defaults to the id itself.
	skinSlot: ((skinId: string) -> string)?,
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
	-- Selected cosmetic per slot (absent in saves that never selected one).
	appearance: { [string]: string }?,
}
type Entry = { profile: Fenced.Profile, state: State, prompts: number }

local configured: Config? = nil
local wearers: { [any]: (string) -> { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any
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
	local subscriptions: { Listing } = if configured
		then configured.catalog.subscriptions or NO_LISTINGS
		else NO_LISTINGS
	for _, listing in subscriptions do
		local skin = listing.grant.cosmeticSetId
		if skin then
			data.skins[skin] = nil
		end
	end
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
	local function supported(listing: Listing): boolean
		return Effects.supported(listing, {
			warehouseSlots = hooks.warehouseSlots,
			skinSupported = hooks.skinSupported or function(_skin)
				return false
			end,
		})
	end
	local store = ctx.store()
	local entries: { [string]: Entry } = {}
	local departed: { [string]: boolean } = {}
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
		if hooks.skinResync then
			hooks.skinResync(actor)
		end
	end
	local function load(actor: string): Entry?
		if departed[actor] then
			return nil
		end
		local existing = entries[actor]
		if existing then
			-- Keep the lease alive (a no-op write while healthy); a lost lease reloads durable state.
			local renewed = store:renew(existing.profile)
			if renewed then
				existing.profile = renewed
				return existing
			end
			entries[actor] = nil
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
			-- A failed or ambiguous commit must not leave the in-memory purchase
			-- marker authoritative. Redelivery reloads the durable receipt before
			-- deciding whether to grant or acknowledge it.
			for actor, held in entries do
				if held == entry then
					entries[actor] = nil
				end
			end
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

	local function eligible(state: State, skin: string): boolean
		return state.skins[skin] == true or (state.subscription.active and state.subscription.setId == skin)
	end
	-- Selected cosmetics the actor may still wear: an expired subscription set drops out here.
	local function wearing(state: State): { [string]: boolean }
		local result = {}
		local selected: { [string]: string } = state.appearance or {}
		for _, skin in selected do
			if eligible(state, skin) then
				result[skin] = true
			end
		end
		return result
	end
	local function view(entry: Entry): { [string]: any }
		local eligibleSkins = clone(entry.state.skins)
		if entry.state.subscription.active and entry.state.subscription.setId then
			eligibleSkins[entry.state.subscription.setId] = true
		end
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
					effectImplemented = supported(listing),
					skin = listing.grant.cosmeticSetId,
					eligible = listing.grant.cosmeticSetId ~= nil
						and eligibleSkins[listing.grant.cosmeticSetId] == true,
					owned = owned,
				})
			end
		end
		local worn = wearing(entry.state)
		return {
			appearance = if next(worn) then worn else nil,
			saveVersion = entry.state.saveVersion,
			skins = clone(entry.state.skins),
			eligibleSkins = eligibleSkins,
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
			return action == PROMPT or action == SYNC or action == SELECT
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
			if action == SELECT then
				local skin = args[1]
				if type(skin) ~= "string" or not eligible(entry.state, skin) then
					return { ok = false, reason = "SKIN_NOT_OWNED" }
				end
				if hooks.skinSelect then
					return hooks.skinSelect(actor, skin)
				end
				if not (hooks.skinSupported and hooks.skinSupported(skin)) then
					return { ok = false, reason = "PRODUCT_EFFECT_UNAVAILABLE" }
				end
				-- The selection persists with the entitlements; renderers read it via `appearance`.
				local slot = if hooks.skinSlot then hooks.skinSlot(skin) else skin
				local appearance = table.clone(entry.state.appearance or {})
				appearance[slot] = skin
				entry.state.appearance = appearance
				if not persist(entry) then
					return { ok = false, reason = "SAVE_FAILED" }
				end
				return { ok = true, stateVersion = entry.state.version, data = { skin = skin } }
			end
			if action == SYNC then
				local ok = pcall(function()
					for _, listing in (catalog.gamepasses or NO_LISTINGS) :: { Listing } do
						if isConfigured(listing.id) then
							entry.state.passes[listing.key] = marketplace.ownsGamePass(userId, listing.id)
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
			if not supported(listing) then
				return { ok = false, reason = "PRODUCT_EFFECT_UNAVAILABLE" }
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
		drain = function(_actor: string): Shared.Result
			-- Receipts commit before returning PurchaseGranted; no local grant queue.
			return { ok = true }
		end,
		releaseActor = function(actor: string): Shared.Result
			local entry = entries[actor]
			if entry then
				local released, err = store:release(entry.profile)
				if not released and err ~= "lease lost" then
					return { ok = false, reason = err }
				end
			end
			entries[actor] = nil
			departed[actor] = true
			return { ok = true }
		end,
		resumeActor = function(actor: string): Shared.Result
			departed[actor] = nil
			return { ok = load(actor) ~= nil, reason = nil }
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
	-- Cosmetics the actor currently wears (selected and still owned), as a set of ids. Kept off the
	-- port (Session accepts only contract callbacks) and found through M.appearance.
	wearers[extension.command] = function(actor: string): { [string]: boolean }
		local entry = load(actor)
		return if entry then wearing(entry.state) else {}
	end
	return Session.registerLifecycle(extension)
end

--- The cosmetics `actor` wears according to a built monetization extension (or its port copy).
function M.appearance(extension: any, actor: string): { [string]: boolean }?
	local read = wearers[extension.command]
	return if read then read(actor) else nil
end

return M
