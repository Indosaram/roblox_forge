--!strict
-- Fake platform only; real Session shop commands and real fenced receipt persistence.
local Monetization = require("../../../../genres/survival-coop/module/MonetizationExtension")
local Catalog = require("../../../../games/robango-island/src/shared/MonetizationCatalog")
local Marketplace = require("../../../../core/infra/monetization/MarketplacePort")
local Policy = require("../../../../core/infra/monetization/PolicyPort")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Selection = require("../../../../genres/survival-coop/module/SkinSelection")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local M = {}
M.operations = {
	entitle_select = function(ctx: any, step: any): string?
		local result = ctx.fixture.select(ctx.playerOf(step), step.skin)
		ctx.results[ctx.playerOf(step)] = result
		return if (step.expect == "refused") == result.ok then "unexpected skin result" else nil
	end,
	entitle_verify = function(ctx: any, _step: any): string?
		return ctx.fixture.verify()
	end,
}
function M.new(ctx: any): any
	local platform = Marketplace.fake()
	platform.redeliveries = 5
	local capacities: { [string]: number } = {}
	local rendered: { [string]: string } = {}
	local document = serde.decode("yaml", fs.readFile("games/robango-island/game.yml"))
	local listings: Monetization.Listings = document.monetization
	Monetization.configure({
		catalog = listings,
		marketplace = platform.port,
		policy = Policy.fake({ ["1"] = true }),
		hooks = {
			skinSupported = function(skin)
				return skin == Catalog.products[1].grant.cosmeticSetId
					or skin == Catalog.subscriptions[1].grant.cosmeticSetId
			end,
			warehouseSlots = function(actor, bonus)
				capacities[actor] = 20 + bonus
			end,
		},
	})
	local extension: any = assert(Monetization.factory({
		store = function()
			return Fenced.new(ctx.backend, { sessionId = "entitle-fixture", now = ctx.now, leaseSeconds = 120 })
		end,
		now = ctx.now,
	}))
	local selector = Selection.new({
		supported = function(skin)
			return skin == Catalog.products[1].grant.cosmeticSetId
		end,
		owns = function(actor, skin)
			local snapshot = extension.snapshot(actor)
			return snapshot and snapshot.skins[skin] == true
		end,
		apply = function(actor, skin)
			rendered[actor] = skin
			return true
		end,
		clear = function(actor)
			rendered[actor] = nil
			return true
		end,
	})
	local port = table.clone(extension)
	port.close = nil
	return {
		services = { survivalExtensions = { port } },
		select = selector.select,
		verify = function(): string?
			local snapshot = extension.snapshot("1")
			assert(snapshot.grants == 1 and #platform.decisions == 5, "duplicate receipt granted more than once")
			assert(capacities["1"] == 45, "home capacity not applied")
			assert(rendered["1"] == Catalog.products[1].grant.cosmeticSetId, "appearance port not applied")
			return nil
		end,
		snapshot = function()
			return { capacities = capacities, rendered = rendered }
		end,
		close = function()
			local result = extension.close()
			Monetization.configure(nil)
			return result
		end,
	}
end
return M
