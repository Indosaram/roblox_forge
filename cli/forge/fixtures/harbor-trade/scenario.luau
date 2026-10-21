--!strict
local Extension = require("../../../../genres/survival-coop/module/CrossServerMarketExtension")
local Project = require("../../../../genres/survival-coop/module/CrossServerMarketProject")
local Data = require("../../../../core/domain/genre/SerializedData")
local M = {}
M.operations = {
	trade_roundtrip = function(ctx, step): string?
		local actor = ctx.playerOf(step)
		local function command(owner: string, action: string, args: { any }, id: string): any
			return ctx.session.command(
				owner,
				{ requestId = id, sessionEpoch = ctx.session.commandEpoch(owner, action), action = action, args = args }
			)
		end
		local listed = command(actor, "survival-coop:market-list", { "twig", 2, 21 }, "list")
		if not listed.ok then
			return listed.reason
		end
		local buyer = ctx.playerOf({ player = "buyer" })
		local bought = command(buyer, "survival-coop:market-buy", { actor .. ":list", 21 }, "purchase")
		if not bought.ok then
			return bought.reason
		end
		local repeated = command(buyer, "survival-coop:market-buy", { actor .. ":list", 21 }, "purchase")
		if not repeated.ok then
			return repeated.reason
		end
		local sellerRecord = ctx.fixture.records["player:" .. actor]
		local buyerRecord = ctx.fixture.records["player:" .. buyer]
		if buyerRecord.coins ~= 79 or sellerRecord.market.claims[buyer .. ":purchase:1"].coins ~= 20 then
			return "currency conservation"
		end
		if buyerRecord.market.claims[buyer .. ":purchase:0"].item.quantity ~= 2 then
			return "bundle duplicated or missing"
		end
		ctx.results[actor] = { ok = true, data = { escrowSettled = true, fee = 1 } }
		return nil
	end,
	trade_project = function(ctx, _step): string?
		local result = Project.complete({
			id = "native-project",
			contributions = {
				seller = { units = 2, escrowCommitted = true },
				buyer = { units = 1, escrowCommitted = true },
			},
		}, { plank = 5 })
		ctx.fixture.project = result
		return if result.claims["native-project:seller"].items.plank
					+ result.claims["native-project:buyer"].items.plank
				== 5
			then nil
			else "project reward multiplication"
	end,
}
function M.new(ctx): any
	local records = {}
	for _, name in { "seller", "buyer" } do
		local actor = ctx.playerOf({ player = name })
		records["player:" .. actor] = { coins = 100, items = { twig = { catalogId = "branch", quantity = 2 } } }
	end
	local index = {}
	local extension = Extension.new({
		update = function(key, transform)
			local value = transform(Data.clone(records[key]))
			records[key] = Data.clone(value)
			return true, Data.clone(value)
		end,
		index = function(key, value)
			index[key] = Data.clone(value)
		end,
		search = function(key)
			return if index[key] then { Data.clone(index[key]) } else {}
		end,
	}, ctx.now)
	return {
		records = records,
		services = { survivalExtensions = { extension } },
		snapshot = function()
			return { records = records }
		end,
	}
end
return M
