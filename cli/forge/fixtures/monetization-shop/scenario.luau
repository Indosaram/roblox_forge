--!strict
-- Native authority for the shop-receipt-storm scenario: the real MonetizationExtension over the
-- scenario's durable backend, a fake marketplace that redelivers every receipt five times and
-- a fake PolicyService where only player "1" may buy a subscription. All commands and
-- assertions stay in qaharness.
local Fenced = require("../../../../core/infra/data/FencedStore")
local MarketplacePort = require("../../../../core/infra/monetization/MarketplacePort")
local PolicyPort = require("../../../../core/infra/monetization/PolicyPort")
local Contract = require("../../../../core/domain/genre/Contract")
local Monetization = require("../../../../genres/survival-coop/module/MonetizationExtension")
local ProfileStore = require("../../../../core/infra/data/ProfileStore")
local serde = require("@lune/serde")
local M = {}
function M.new(_config: Contract.PackConfig, backend: ProfileStore.Backend, now: () -> number)
	local marketplace = MarketplacePort.fake()
	marketplace.redeliveries = 5
	Monetization.configure({
		catalog = {
			gamepasses = {
				{
					key = "wideWarehouse",
					name = "Wide Warehouse",
					price = 199,
					id = 9001,
					grant = { kind = "storageSlots", amount = 10 },
				},
			},
			products = {
				{
					key = "skinReefRunner",
					name = "Reef Runner Skin",
					price = 99,
					id = 9101,
					grant = { kind = "cosmeticSet", cosmeticSetId = "reef-runner" },
				},
				{
					key = "skinUnregistered",
					name = "Unregistered Skin",
					price = 99,
					id = 0,
					grant = { kind = "cosmeticSet", cosmeticSetId = "unregistered" },
				},
			},
			subscriptions = {
				{
					key = "voyagerMonthly",
					name = "Voyager Monthly",
					price = 99,
					id = 9201,
					grant = { kind = "subscriptionMonthly", cosmeticSetId = "voyager-monthly", storageSlots = 5 },
				},
			},
		},
		marketplace = marketplace.port,
		policy = PolicyPort.fake({ ["1"] = true }),
	})
	local extension = assert(Monetization.factory({
		store = function()
			return Fenced.new(backend, {
				sessionId = "qa-shop",
				leaseSeconds = 120,
				now = now,
				budget = {
					encode = function(value: any): string
						return serde.encode("json", value)
					end,
				},
			})
		end,
		now = now,
	}))
	-- Like SurvivalBootstrap, keep close out of the session port.
	local port: any = table.clone(extension)
	port.close = nil
	return {
		services = { survivalExtensions = { port } },
		bind = function() end,
		close = function(): Contract.Result
			local closed = (extension :: any).close()
			Monetization.configure(nil)
			return closed
		end,
	}
end
return M
