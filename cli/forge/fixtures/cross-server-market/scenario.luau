--!strict
local Session = require("../../../../core/infra/genre/Session")
local Personal = require("../../../../core/infra/data/CrossServerMarketPersonal")
local Extension = require("../../../../genres/survival-coop/module/CrossServerMarketExtension")
local Contract = require("../../../../genres/survival-coop/module/Contract")
local Content: any = require("../../../../games/robango-island/src/shared/SurvivalContent")
local Config = require("../../../../games/robango-island/src/shared/GenreConfig")
local Policy = require("../../../../games/robango-island/src/shared/GenreDurable")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Job = require("../../../../core/domain/crafting/Job")
local Data = require("../../../../core/domain/genre/SerializedData")
local serde = require("@lune/serde")
local M = {}
M.operations = {
	market_servers = function(ctx, _step): string?
		return ctx.fixture.run()
	end,
}
function M.new(ctx: any): any
	local records: any = {}
	local index: any = {}
	local clock = ctx.now
	local time = clock()
	local function now(): number
		return time
	end
	local pending = {}
	local function server(owner: string): any
		local session: any = nil
		local personal = Personal.new({
			personalTransaction = function(actor, transform)
				return session.personalTransaction(actor, transform)
			end,
			personalTransfer = function(actor)
				return session.personalTransfer(actor)
			end,
		}, Content.items, { "wood" })
		local extension = Extension.new(
			{
				update = function(key, transform)
					if string.sub(key, 1, 7) == "player:" then
						return personal.update(string.sub(key, 8), transform)
					end
					local value = transform(Data.clone(records[key]))
					records[key] = Data.clone(value)
					if string.sub(key, 1, 8) == "listing:" and value then
						pending[value.id] = true
					end
					return true, Data.clone(value)
				end,
				index = function(key, listing)
					index[key] = index[key] or {}
					index[key][listing.id] = Data.clone(listing)
				end,
				search = function(key)
					local result = {}
					for _, listing in index[key] or {} do
						if listing.state == "ACTIVE" then
							table.insert(result, Data.clone(listing))
						end
					end
					return result
				end,
				pending = function()
					local result = {}
					for id in pending do
						table.insert(result, id)
					end
					table.sort(result)
					return result
				end,
			} :: any,
			now,
			personal,
			{ "wood" }
		)
		session = Session.new(
			{
				packConfig = Config,
				contracts = { Contract },
				controls = {},
				storeName = "cross-market",
				durable = Policy,
			},
			ctx.backend,
			{ sessionId = owner, lockTimeout = 120, retries = 0, now = now },
			{
				now = now,
				roll = function()
					return 0
				end,
				emit = function() end,
				encode = function(value)
					return serde.encode("json", value)
				end,
				survivalExtensions = { extension },
			},
			Policy
		)
		return { session = session, personal = personal, extension = extension }
	end
	local function command(host: any, actor: string, action: string, args: { any }, request: string): any
		action = "survival-coop:market-" .. action
		return host.session.command(actor, {
			requestId = request,
			sessionEpoch = host.session.commandEpoch(actor, action),
			action = action,
			args = args,
		})
	end
	local function requireOk(result: any)
		assert(result.ok, tostring(result.reason))
	end
	return {
		snapshot = function()
			return { records = records }
		end,
		run = function(): string?
			local a, b = server("simulated-job-A"), server("simulated-job-B")
			requireOk(a.session.join("seller"))
			requireOk(b.session.join("buyer"))
			for _, pair in { { a, "seller" }, { b, "buyer" } } do
				local ok, failure = pair[1].session.personalTransaction(pair[2], function(raw)
					local data = raw.envelope.genres["survival-coop"].data
					data.balance = 100
					if pair[2] == "seller" then
						local bag = Inventory.fromSave(data.inventory.bag, Job.catalog(Content))
						bag = assert(Inventory.add(bag, Job.catalog(Content), {
							itemId = "exact-wood",
							catalogId = "wood",
							quantity = 4,
							qualityMilli = 1000,
							durabilityMilli = 0,
							attributes = { provenance = "seed92" },
						}, bag.version))
						data.inventory.bag = Inventory.save(bag)
					end
					return raw
				end)
				assert(ok, tostring(failure))
			end
			requireOk(command(a, "seller", "list", { "exact-wood", 2, 21 }, "list"))
			requireOk(a.session.close("seller"))
			assert(#b.extension.snapshot("buyer").listings == 1, "cross-server browse")
			requireOk(command(b, "buyer", "buy", { "seller:list", 21 }, "buy"))
			requireOk(command(b, "buyer", "buy", { "seller:list", 21 }, "buy"))
			requireOk(command(b, "buyer", "claim", { "buyer:buy:0" }, "pickup"))
			requireOk(a.session.join("seller"))
			requireOk(command(a, "seller", "claim", { "buyer:buy:1" }, "proceeds"))
			local seller, buyer = a.personal.snapshot("seller", 1), b.personal.snapshot("buyer", 1)
			assert(seller.balance + buyer.balance + 1 == 200, "currency including fee conserved")
			assert(
				seller.items["exact-wood"].quantity + buyer.items["exact-wood"].quantity == 4,
				"exact item quantity conserved"
			)
			assert(buyer.items["exact-wood"].attributes.provenance == "seed92", "attributes preserved")
			requireOk(command(a, "seller", "list", { "exact-wood", 1, 10 }, "cancel-list"))
			requireOk(command(a, "seller", "cancel", { "seller:cancel-list" }, "cancel"))
			requireOk(command(a, "seller", "claim", { "seller:cancel-list:return:0" }, "cancel-pickup"))
			requireOk(command(a, "seller", "list", { "exact-wood", 1, 10 }, "expire-list"))
			-- Close the personal leases before the worker runs after a full day.
			requireOk(a.session.close("seller"))
			requireOk(b.session.close("buyer"))
			time += 86400
			local restarted = server("restarted-worker")
			restarted.extension.recover("seller")
			requireOk(restarted.session.join("seller"))
			requireOk(command(restarted, "seller", "claim", { "seller:expire-list:return:0" }, "expired-pickup"))
			assert(
				restarted.personal.snapshot("seller", 1).items["exact-wood"].quantity == 2,
				"cancel and expiry returned once"
			)
			requireOk(restarted.session.close("seller"))
			ctx.results[ctx.playerOf({ player = "seller" })] = { ok = true, data = { conserved = true } }
			return nil
		end,
	}
end
return M
