--!strict
local serde = require("@lune/serde")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Fenced = require("../../../core/infra/data/FencedStore")
local MarketplacePort = require("../../../core/infra/monetization/MarketplacePort")
local PolicyPort = require("../../../core/infra/monetization/PolicyPort")
local Monetization = require("./MonetizationExtension")

local function listings(productId: number, subscriptionId: number): any
	return {
		gamepasses = {
			{
				key = "wideWarehouse",
				name = "Wide Warehouse",
				price = 199,
				id = productId,
				grant = { kind = "storageSlots", amount = 10 },
			},
		},
		products = {
			{
				key = "skinReefRunner",
				name = "Reef Runner Skin",
				price = 99,
				id = productId,
				grant = { kind = "cosmeticSet", cosmeticSetId = "reef-runner" },
			},
		},
		subscriptions = {
			{
				key = "voyagerMonthly",
				name = "Voyager Monthly",
				price = 99,
				id = subscriptionId,
				grant = { kind = "subscriptionMonthly", cosmeticSetId = "voyager-monthly", storageSlots = 5 },
			},
		},
	}
end

local function build(catalog: any, eligible: { [string]: boolean }, backend: any?)
	local fake = MarketplacePort.fake()
	local slots: { [string]: number } = {}
	local skins: { string } = {}
	Monetization.configure({
		catalog = catalog,
		marketplace = fake.port,
		policy = PolicyPort.fake(eligible),
		hooks = {
			warehouseSlots = function(actor, bonus)
				slots[actor] = bonus
			end,
			skinUnlocked = function(_actor, skin)
				table.insert(skins, skin)
			end,
		},
	})
	local store = backend or Memory.new()
	local extension = assert(Monetization.factory({
		store = function()
			return Fenced.new(store, {
				sessionId = "mon",
				leaseSeconds = 120,
				now = function()
					return 0
				end,
				budget = {
					encode = function(value)
						return serde.encode("json", value)
					end,
				},
			})
		end,
		now = function()
			return 0
		end,
	}))
	return extension, fake, slots, skins, store
end
local function command(extension: any, action: string, args: { any }): any
	return extension.command(
		"7",
		action,
		args,
		{ actorId = "7", requestId = "r", sessionEpoch = 0 },
		"client",
		function()
			return { ok = true }
		end
	)
end

return {
	["factory stays disabled without configuration"] = function()
		Monetization.configure(nil)
		assert(Monetization.factory({
			store = function()
				error("unused")
			end,
			now = function()
				return 0
			end,
		}) == nil, "disabled")
	end,
	["configure refuses a catalog that breaks the ADR-07 rules"] = function()
		local bad = listings(1, 2)
		bad.products[1].grant = { kind = "random" }
		assert(not pcall(Monetization.configure, { catalog = bad } :: any), "paid random refused")
		Monetization.configure(nil)
	end,
	["product id 0 refuses the prompt cleanly"] = function()
		local extension, fake = build(listings(0, 0), { ["7"] = true })
		for _, key in { "wideWarehouse", "skinReefRunner", "voyagerMonthly" } do
			local result = command(extension, "survival-coop:shop-prompt", { key })
			assert(not result.ok and result.reason == "PRODUCT_NOT_CONFIGURED", tostring(result.reason))
		end
		assert(#fake.prompts == 0, "no prompt reached the marketplace")
		assert(command(extension, "survival-coop:shop-prompt", { "nope" }).reason == "UNKNOWN_PRODUCT", "unknown key")
		assert(extension.close().ok, "close")
	end,
	["a redelivered receipt grants once and persists across restart"] = function()
		local extension, fake, _slots, skins, backend = build(listings(11, 22), { ["7"] = true })
		fake.redeliveries = 5
		local result = command(extension, "survival-coop:shop-prompt", { "skinReefRunner" })
		assert(result.ok, tostring(result.reason))
		assert(#fake.decisions == 5, "five deliveries")
		for _, decision in fake.decisions do
			assert(decision == "PurchaseGranted", "every redelivery acknowledged")
		end
		local snapshot = extension.snapshot("7")
		assert(snapshot.grants == 1 and snapshot.skins["reef-runner"] == true, "granted exactly once")
		assert(snapshot.saveVersion == 1, "explicit save version")
		assert(extension.close().ok, "close")
		local restarted, _, _, restoredSkins = build(listings(11, 22), { ["7"] = true }, backend)
		local reloaded = restarted.snapshot("7")
		assert(reloaded.grants == 1 and reloaded.skins["reef-runner"] == true, "restart keeps state")
		assert(restoredSkins[1] == "reef-runner", "skin hook re-applied on load")
		assert(command(restarted, "survival-coop:shop-prompt", { "skinReefRunner" }).reason == "ALREADY_OWNED", "owned")
		assert(#skins >= 1 and skins[1] == "reef-runner", "first server announced the skin")
		assert(restarted.close().ok, "close")
	end,
	["ineligible subscription never prompts"] = function()
		local extension, fake = build(listings(11, 22), { ["7"] = false })
		local result = command(extension, "survival-coop:shop-prompt", { "voyagerMonthly" })
		assert(not result.ok and result.reason == "SUBSCRIPTION_INELIGIBLE", tostring(result.reason))
		assert(#fake.prompts == 0, "prompt never called")
		assert(extension.close().ok, "close")
	end,
	["sync grants pass and subscription perks to the warehouse hook"] = function()
		local extension, fake, slots = build(listings(11, 22), { ["7"] = true })
		assert(command(extension, "survival-coop:shop-prompt", { "wideWarehouse" }).ok, "pass prompt")
		assert(command(extension, "survival-coop:shop-prompt", { "voyagerMonthly" }).ok, "subscription prompt")
		assert(#fake.prompts == 2, "two prompts")
		assert(command(extension, "survival-coop:shop-sync", {}).ok, "sync")
		assert(slots["7"] == 15, "pass 10 + subscription 5 slots: " .. tostring(slots["7"]))
		local snapshot = extension.snapshot("7")
		assert(snapshot.skins["voyager-monthly"] == true and snapshot.subscription.active, "subscription cosmetic")
		assert(extension.close().ok, "close")
	end,
	["a refused admission never reaches the marketplace"] = function()
		local extension, fake = build(listings(11, 22), { ["7"] = true })
		local result = extension.command(
			"7",
			"survival-coop:shop-prompt",
			{ "skinReefRunner" },
			{
				actorId = "7",
				requestId = "r",
				sessionEpoch = 0,
			},
			"client",
			function()
				return { ok = false, reason = "RATE_LIMITED" }
			end
		)
		assert(result.reason == "RATE_LIMITED" and #fake.prompts == 0, "admission gate honoured")
		assert(extension.close().ok, "close")
	end,
}
