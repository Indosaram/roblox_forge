--!strict
local Extension = require("../../../../genres/survival-coop/module/HomeExtension")
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local Catalog = require("../../../../core/domain/inventory/ItemCatalog")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Fenced = require("../../../../core/infra/data/FencedStore")
local M = {}
M.operations = {
	home_action = function(ctx: any, step: any): string?
		local actor = ctx.playerOf(step)
		local result = ctx.fixture.command(actor, step.action, step.args or {}, step.token)
		ctx.results[actor] = result
		return if (step.expect == "refused") == result.ok then "unexpected home result" else nil
	end,
	home_reconnect = function(ctx: any, _step: any): string?
		return ctx.fixture.reconnect()
	end,
	home_assert = function(ctx: any, step: any): string?
		local saved = ctx.fixture.snapshot()
		if step.check == "planted" then
			return if saved.homeId == "home:owner"
					and saved.plots.p1
					and saved.structures.bench
				then nil
				else "home persistence lost"
		elseif step.check == "harvested" then
			local crop = saved.storage.items["home:owner:crop:1"]
			return if crop
					and crop.quantity == 3
					and crop.attributes.level == 30
					and not saved.plots.p1
				then nil
				else "harvest conservation"
		end
		return if saved.permissions.offlineCoop
				and saved.structures.bench
				and saved.plots.p1
			then nil
			else "permission refusal mutated home"
	end,
}
function M.new(ctx: any): any
	local definitions: { Catalog.Definition } = {}
	for _, item in Content.items do
		table.insert(definitions, {
			id = item.id,
			stackMax = item.stackMax,
			weightMilli = item.weightMilli,
			maxDurabilityMilli = item.maxDurabilityMilli,
		})
	end
	local catalog = Catalog.new(definitions)
	local generation = 0
	local request = 0
	local clock = ctx.now()
	local extension: any = nil
	local fixture: any = { services = {} }
	local function create(): any
		generation += 1
		return Extension.new({
			content = Content,
			rules = {
				baseSlots = 20,
				storageGrants = {},
				landSizes = { 64 },
				floors = { 2, 14, 26 },
				dock = { x = 0, y = 2, z = 144 },
				plots = { p1 = true },
			},
			structures = { workbench = { kit = "workbench-kit", halfSize = 4, rank = 1 } },
			now = function()
				return clock
			end,
			seed = function()
				return ctx.scenario.seed
			end,
			store = function()
				return Fenced.new(ctx.backend, {
					sessionId = "home-fixture-" .. tostring(generation),
					now = function()
						return clock
					end,
					leaseSeconds = 30,
				})
			end,
			ownerOf = function(_actor, token)
				return if token == "home:owner" then "owner" else nil
			end,
			facts = function(actor)
				return {
					reachable = true,
					friend = actor == "helper",
					ownerOnline = false,
					nodes = { farming_1 = true },
				}
			end,
			initialStorage = function(_actor, storage)
				local bag = Inventory.fromSave(storage, catalog)
				for _, item in { { "seed", "corn-seed" }, { "water", "water" }, { "kit", "workbench-kit" } } do
					bag = assert(Inventory.add(bag, catalog, {
						itemId = item[1],
						catalogId = item[2],
						quantity = 1,
						qualityMilli = 1000,
						durabilityMilli = 0,
						attributes = { level = 30 },
					}, bag.version))
				end
				return Inventory.save(bag)
			end,
		})
	end
	extension = create()
	function fixture.command(actor: string, action: string, args: any, token: string?): any
		request += 1
		return extension.command(
			actor,
			"home-" .. action,
			{ token or "home:owner", args },
			{ actorId = actor, requestId = tostring(request), sessionEpoch = generation },
			"server",
			function()
				return { ok = true }
			end
		)
	end
	function fixture.snapshot(): any
		return assert(extension.snapshot("owner"))
	end
	function fixture.reconnect(): string?
		local saved = fixture.snapshot()
		if not extension.close().ok then
			return "home close failed"
		end
		clock = saved.plots.p1.readyAt
		extension = create()
		return nil
	end
	function fixture.close(): any
		return extension.close()
	end
	return fixture
end
return M
