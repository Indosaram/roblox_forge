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
			skinSupported = function(_skin)
				return true
			end,
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
	return extension :: any, fake, slots, skins, store
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
	["failed receipt commit never acknowledges a local marker and redelivery grants once"] = function()
		for _, lost in { false, true } do
			local memory = Memory.new()
			local failAt = 0
			local backend = {
				update = function(key, transform)
					if failAt > 0 then
						failAt -= 1
						if failAt > 0 then
							return memory.update(key, transform)
						end
						if lost then
							memory.update(key, transform)
						end
						return false, "RECEIPT_COMMIT_FAILED"
					end
					return memory.update(key, transform)
				end,
			}
			local extension, fake = build(listings(11, 22), { ["7"] = true }, backend)
			assert(extension.snapshot("7").grants == 0, "load receipt owner")
			local handler: any
			-- The configured marketplace owns the real handler. Capture it by
			-- replacing only its registration port before rebuilding the extension.
			assert(extension.close().ok, "release initial owner")
			Monetization.configure({
				catalog = listings(11, 22),
				marketplace = {
					onReceipt = function(callback)
						handler = callback
					end,
				} :: any,
				policy = PolicyPort.fake({ ["7"] = true }),
			})
			extension = assert(Monetization.factory({
				store = function()
					return Fenced.new(backend, {
						sessionId = "receipt",
						leaseSeconds = 120,
						now = function()
							return 0
						end,
					})
				end,
				now = function()
					return 0
				end,
			})) :: any
			assert(extension.snapshot("7").grants == 0, "fresh owner")
			local receipt = { PlayerId = 7, ProductId = 11, PurchaseId = "commit-barrier" }
			failAt = 2 -- authoritative renew, then receipt commit
			assert(handler(receipt) == "NotProcessedYet", "failed commit stays pending")
			assert(handler(receipt) == "PurchaseGranted", "redelivery resolves durable grant")
			local before = serde.encode("json", extension.snapshot("7"))
			assert(handler(receipt) == "PurchaseGranted", "duplicate acknowledges committed receipt")
			assert(
				serde.encode("json", extension.snapshot("7")) == before,
				"duplicate receipt preserves grants skins and version"
			)
			assert(extension.snapshot("7").grants == 1 and #fake.prompts == 0, "one grant and no platform prompt")
			assert(extension.close().ok, "close")
		end
	end,
	["actor release defers late receipts and explicit resume grants duplicate zero extra"] = function()
		local extension, fake = build(listings(11, 22), { ["7"] = true })
		assert(command(extension, "survival-coop:shop-prompt", { "skinReefRunner" }).ok, "first grant")
		assert(extension.snapshot("7").grants == 1, "one committed grant")
		assert(extension.drain("7").ok and extension.releaseActor("7").ok, "drain and release")
		assert(extension.releaseActor("7").ok, "duplicate actor release")
		fake.port.promptProduct(7, 11)
		assert(fake.decisions[#fake.decisions] == "NotProcessedYet", "late receipt must not reacquire departed actor")
		assert(extension.snapshot("7") == nil, "snapshot cannot reacquire departed actor")
		assert(extension.resumeActor("7").ok, "explicit origin recovery")
		assert(extension.snapshot("7").grants == 1, "late callback granted zero extra")
		assert(extension.close().ok, "close")
	end,
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
		assert(
			snapshot.eligibleSkins["voyager-monthly"] == true and snapshot.subscription.active,
			"subscription cosmetic"
		)
		assert(snapshot.skins["voyager-monthly"] == nil, "subscription does not grant permanent ownership")
		fake.subscribed["7:22"] = false
		assert(command(extension, "survival-coop:shop-sync", {}).ok, "expired subscription sync")
		local expired = extension.snapshot("7")
		assert(expired.eligibleSkins["voyager-monthly"] == nil, "expired cosmetic access revoked")
		assert(slots["7"] == 10, "subscription storage revoked but pass retained")
		local selected = command(extension, "survival-coop:skin-select", { "voyager-monthly" })
		assert(not selected.ok and selected.reason == "SKIN_NOT_OWNED", "expired skin selection refused")
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
