--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Extension = require("./ContractsExtension")
local Content = require("../../../core/domain/survival/Content")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Job = require("../../../core/domain/crafting/Job")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Fenced = require("../../../core/infra/data/FencedStore")
local PersonalAggregate = require("../../../core/infra/data/PersonalAggregate")

local function content(): any
	local document = serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
	local canonical, errors = Content.canonicalize(document)
	return assert(canonical, table.concat(errors, "; "))
end

local function bagWith(document: any, items: { { string | number } }): any
	local catalog = Job.catalog(document)
	local bag = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	for index, entry in items do
		local definition = catalog[entry[1] :: string]
		bag = assert(Inventory.add(bag, catalog, {
			itemId = "seed-" .. index,
			catalogId = entry[1] :: string,
			quantity = entry[2] :: number,
			qualityMilli = 1000,
			durabilityMilli = if definition.maxDurabilityMilli then definition.maxDurabilityMilli else 0,
			attributes = {},
		}, bag.version))
	end
	return { inventory = Inventory.save(bag), itemTransfers = { version = 1, receipts = {} } }
end

local function quantityOf(view: any, catalogId: string): number
	local total = 0
	for _, item in view.inventory.items do
		if item.catalogId == catalogId then
			total += item.quantity
		end
	end
	return total
end

local PATH = { "genres", "survival-coop", "data", "inventory", "bag" }
local budget = {
	encode = function(value: any): string
		return serde.encode("json", value)
	end,
}

-- Real ContractsExtension over a real PersonalAggregate on one MemoryBackend. `faults.next`
-- injects one failure on the next personal write: "fail" (nothing written) or "lost" (written,
-- acknowledgement lost). `reopen()` simulates a server restart (fresh extension and leases).
local function harness(balance: number)
	local document = content()
	local backend = Memory.new()
	local clock = { millis = 0 }
	local now = function()
		return clock.millis // 1000
	end
	local personal = PersonalAggregate.new(backend, {
		namespace = "personal",
		inventoryPath = PATH,
		validateEnvelope = function(value)
			return type(value) == "table" and value.version == 1
		end,
		store = { sessionId = "players", leaseSeconds = 120, now = now, budget = budget },
	})
	local start = bagWith(document, { { "wood", 6 } }).inventory
	local token: any = assert(personal:load("1", function()
		return {
			version = 1,
			genres = { ["survival-coop"] = { version = 1, data = { balance = balance, inventory = { bag = start } } } },
		}
	end))
	local faults: { next: string? } = { next = nil }
	local port = {
		personal = {
			inventoryLens = function(_self)
				return personal:inventoryLens()
			end,
			inventoryPath = function(_self)
				return personal:inventoryPath()
			end,
			refresh = function(_self, current)
				return personal:refresh(current)
			end,
			update = function(_self, current, transform): (any, string?)
				local fault = faults.next
				faults.next = nil
				if fault == "fail" then
					return nil, "throttled"
				end
				local updated, err = personal:update(current, transform)
				if fault == "lost" then
					token = updated or token
					return nil, "throttled"
				end
				return updated, err
			end,
		},
		profile = function()
			return token
		end,
		install = function(next)
			token = next
		end,
	}
	local self: any = { clock = clock, faults = faults }
	function self.reopen(sessionId: string)
		self.extension = assert(Extension.factory({
			content = document,
			store = function()
				return Fenced.new(backend, { sessionId = sessionId, leaseSeconds = 120, now = now, budget = budget })
			end,
			nowMillis = function()
				return clock.millis
			end,
			members = function()
				return { "1" }
			end,
			personalTransfer = function()
				return port
			end,
		}))
		return self.extension
	end
	function self.command(action: string, args: { any }, requestId: string): any
		return self.extension.command(
			"1",
			"survival-coop:" .. action,
			args,
			{
				actorId = "1",
				requestId = requestId,
				sessionEpoch = 0,
			},
			"client",
			function()
				return { ok = true }
			end
		)
	end
	function self.balance(): number
		return token.data.envelope.genres["survival-coop"].data.balance
	end
	function self.held(catalogId: string): number
		local total = 0
		for _, item in token.data.envelope.genres["survival-coop"].data.inventory.bag.items do
			if item.catalogId == catalogId then
				total += item.quantity
			end
		end
		return total
	end
	return self
end

return {
	["exchange consumes the delivery and grants the reward exactly once"] = function()
		local document = content()
		local catalog = Job.catalog(document)
		local view = bagWith(document, { { "wood", 5 } })
		local out, err = Extension.exchange(
			view,
			catalog,
			{ { item = "wood", quantity = 3 } },
			{ { item = "cord", quantity = 1 } },
			"ct:r1"
		)
		assert(out, tostring(err))
		assert(quantityOf(out, "wood") == 2 and quantityOf(out, "cord") == 1, "consumed and granted")
		local again = assert(
			Extension.exchange(
				out,
				catalog,
				{ { item = "wood", quantity = 3 } },
				{ { item = "cord", quantity = 1 } },
				"ct:r1"
			)
		)
		assert(quantityOf(again, "wood") == 2 and quantityOf(again, "cord") == 1, "marker makes a replay a no-op")
	end,
	["exchange refuses when the bag does not hold the delivery"] = function()
		local document = content()
		local catalog = Job.catalog(document)
		local out, err = Extension.exchange(
			bagWith(document, { { "wood", 1 } }),
			catalog,
			{ { item = "wood", quantity = 3 } },
			{},
			"ct:r2"
		)
		assert(out == nil and err == "INSUFFICIENT_ITEMS", tostring(err))
	end,
	["a pack without a contracts section leaves the extension disabled"] = function()
		local document = content()
		document.contracts = nil
		local built = Extension.factory({
			content = document,
			store = function()
				return nil :: any
			end,
		})
		assert(built == nil, "disabled without a catalog")
		assert(Memory.new() ~= nil, "backend constructible")
	end,
	["the extension handles exactly its declared actions"] = function()
		local document = content()
		local built = assert(Extension.factory({
			content = document,
			store = function()
				return { acquire = function() end } :: any
			end,
			nowMillis = function()
				return 0
			end,
			members = function()
				return {}
			end,
			personalTransfer = function()
				return nil
			end,
		}))
		for _, action in
			{ "contract-accept", "contract-deliver", "contract-swap", "contract-claim", "tutorial-skip-arrival" }
		do
			assert(built.handles("survival-coop:" .. action), action)
		end
		assert(not built.handles("survival-coop:gather") and not built.handles("contract-accept"), "foreign ids")
	end,
	["an escrowed pending gather advances the tutorial but a rejected one does not"] = function()
		local h = harness(0)
		h.reopen("srv-a")
		local ext = h.extension
		ext.observe("1", "survival-coop:gather", {}, { ok = false, data = { status = "rejected" } })
		assert(ext.snapshot("1").tutorial.step == "arrive", "rejected gather ignored")
		ext.observe("1", "survival-coop:gather", {}, { ok = false, data = { status = "pending" } })
		assert(ext.snapshot("1").tutorial.step == "craft-stone-axe", ext.snapshot("1").tutorial.step)
		assert(ext.close().ok, "close")
	end,
	["a contract coin reward is credited once under replay"] = function()
		local h = harness(5)
		h.reopen("srv-a")
		assert(h.command("tutorial-skip-arrival", {}, "skip").ok, "skip")
		assert(h.command("contract-accept", { "survey-driftwood" }, "a1").ok, "accept")
		local delivered = h.command("contract-deliver", { "survey-driftwood" }, "d1")
		assert(delivered.ok and delivered.data.coins == 10, tostring(delivered.reason))
		assert(h.balance() == 15 and h.held("wood") == 3 and h.held("cord") == 1, "coins + items granted")
		local replay = h.command("contract-deliver", { "survey-driftwood" }, "d1")
		assert(replay.ok and replay.data.coins == 10, "replay returns the stored outcome")
		assert(h.balance() == 15 and h.held("cord") == 1, "no second grant")
		local offers = h.extension.snapshot("1").offers
		local found = false
		for _, offer in offers do
			found = found or (offer.id == "guild-stone-axe" and offer.coins == 20)
		end
		assert(found, "offers carry their coin reward")
		assert(h.extension.close().ok, "close")
	end,
	["actor handoff drains pending contract consumption and releases recovery ownership"] = function()
		for _, fault in { "fail", "lost" } do
			local h = harness(0)
			h.reopen("origin")
			assert(h.command("tutorial-skip-arrival", {}, "skip").ok, "skip")
			assert(h.command("contract-accept", { "survey-driftwood" }, "accept").ok, "accept")
			h.faults.next = fault
			assert(not h.command("contract-deliver", { "survey-driftwood" }, "deliver").ok, "grant barrier")
			assert(h.extension.drain("1").ok, "pending consumption drained")
			assert(
				h.held("wood") + 2 == 5 and h.held("cord") == 1 and h.balance() == 10,
				"inventory plus consumption and rewards conserved"
			)
			assert(h.extension.releaseActor("1").ok, "release actor")
			assert(h.extension.releaseActor("1").ok, "duplicate release")
			assert(h.extension.recover("1", 8).status == "confirmed", "departed recovery idle")
			assert(h.extension.snapshot("1") == nil, "departed snapshot cannot reload")
			assert(h.extension.resumeActor("1").ok, "explicit origin resume")
			assert(h.command("contract-deliver", { "survey-driftwood" }, "deliver").ok, "receipt replay")
			assert(h.held("cord") == 1 and h.balance() == 10, "duplicate receipt grants zero extra")
			assert(h.extension.close().ok, "close")
		end
	end,
	["a crash between contract completion and the grant recovers exactly once"] = function()
		for _, fault in { "fail", "lost" } do
			local h = harness(0)
			h.reopen("srv-a")
			assert(h.command("tutorial-skip-arrival", {}, "skip").ok, "skip")
			assert(h.command("contract-accept", { "survey-driftwood" }, "a1").ok, "accept")
			h.faults.next = fault
			local first = h.command("contract-deliver", { "survey-driftwood" }, "d1")
			assert(not first.ok, fault .. ": grant write failed after the contract committed")
			assert(h.extension.snapshot("1").pending == true, fault .. ": completion recorded as pending")
			assert(h.extension.close().ok, "server stops")
			h.clock.millis += 1000
			h.reopen("srv-b")
			local recovered = h.extension.recover("1", 8)
			assert(recovered.status == "confirmed", fault .. ": " .. tostring(recovered.error))
			assert(
				h.balance() == 10 and h.held("cord") == 1 and h.held("wood") == 3,
				string.format(
					"%s: granted once (balance=%d cord=%d wood=%d)",
					fault,
					h.balance(),
					h.held("cord"),
					h.held("wood")
				)
			)
			assert(h.extension.recover("1", 8).status == "confirmed", "second sweep is a no-op")
			local replay = h.command("contract-deliver", { "survey-driftwood" }, "d1")
			assert(replay.ok and replay.data.coins == 10, fault .. ": original request gets the result")
			assert(h.balance() == 10 and h.held("cord") == 1, fault .. ": still once")
			assert(h.extension.snapshot("1").delivered == 1, fault .. ": completed once")
			assert(h.extension.close().ok, "close")
		end
	end,
	["coins validate as an optional positive integer"] = function()
		local document = serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
		document.contracts.entries[1].coins = 0
		assert(Content.canonicalize(document) == nil, "zero coins refused")
		document.contracts.entries[1].coins = nil
		assert(Content.canonicalize(document) ~= nil, "coins optional")
	end,
}
