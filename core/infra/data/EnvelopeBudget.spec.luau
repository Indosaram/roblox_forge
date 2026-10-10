--!strict
local Budget = require("./EnvelopeBudget")
local FencedStore = require("./FencedStore")
local Content = require("../../domain/survival/Content")
local Inventory = require("../../domain/inventory/Inventory")
local Job = require("../../domain/crafting/Job")
local Workshop = require("../../../genres/survival-coop/module/Workshop")
local serde = require("@lune/serde")

local function encode(value: any): string
	return serde.encode("json", value)
end

local specs: { [string]: () -> () } = {
	["actual JSON byte budget accepts exact and below and rejects above"] = function()
		for _, maximum in { 31, Budget.DEFAULT_MAX_BYTES, Budget.MAX_BYTES } do
			for _, delta in { -1, 0, 1 } do
				local value = string.rep("x", maximum - 2 + delta)
				local result = Budget.check(value, encode, maximum)
				assert(result.byteCount == maximum + delta, "JSON quotes are included in exact byte count")
				assert(result.accepted == (delta <= 0), "budget boundary must be inclusive")
				assert(
					result.errorCode == (if delta > 0 then "PERSISTED_VALUE_TOO_LARGE" else nil),
					"structured rejection"
				)
			end
		end
		assert(Budget.check({}, encode).maxBytes == Budget.DEFAULT_MAX_BYTES, "default policy applied")
	end,
	["UTF8 counts encoded bytes rather than codepoints"] = function()
		local text = utf8.char(0xAC00, 0x1F980)
		assert(#text == 7 and utf8.len(text) == 2, "fixture has seven bytes and two codepoints")
		local json = encode({ text = text })
		local exact = Budget.check({ text = text }, encode, #json)
		local short = Budget.check({ text = text }, encode, #json - 1)
		assert(exact.accepted and exact.byteCount == #json and not short.accepted, "use actual encoded UTF8 length")
	end,
	["JSON encoding failures propagate and invalid policies reject"] = function()
		local ok = pcall(function()
			Budget.check({ unsupported = function() end }, encode)
		end)
		assert(not ok, "unsupported JSON values must not become accepted or size failures")
		for _, maximum in { 0, -1, 1.5, math.huge, 0 / 0, Budget.MAX_BYTES + 1 } do
			assert(not pcall(function()
				Budget.check({}, encode, maximum)
			end), "invalid budget rejected")
		end
	end,
	["full FencedStore wrapper and receipts participate in the same budget"] = function()
		local envelope = { inventory = {}, workshop = {} }
		local data =
			{ version = 1, stateRevision = 0, envelope = envelope, itemTransfers = { version = 1, receipts = {} } }
		local persisted: any = nil
		local backend = {
			update = function(_key: string, transform: (any) -> any): (boolean, any)
				local candidate = transform(persisted)
				local checked = Budget.check(candidate, encode, #encode(data))
				assert(
					not checked.accepted and checked.byteCount > #encode(data),
					"actual wrapper exceeds data-only budget"
				)
				persisted = candidate
				return true, candidate
			end,
		}
		local store = FencedStore.new(backend, {
			sessionId = "server",
			leaseSeconds = 60,
			now = function()
				return 1790899200
			end,
		})
		assert(
			store:acquire("personal:alice", function()
				return data
			end),
			"capture actual FencedStore wrapper"
		)
		local limit = #encode(persisted)
		assert(Budget.check(persisted, encode, limit).accepted, "whole wrapper exact threshold")
		persisted.data.itemTransfers.receipts.transfer = { phase = "committed", quantity = 1 }
		assert(not Budget.check(persisted, encode, limit).accepted, "receipt overhead cannot escape budget")
		assert(Budget.check(envelope, encode, limit).accepted, "envelope alone would miss receipt overflow")
	end,
	["maximum catalog and 64 actual retained jobs obey total aggregate budget"] = function()
		local raw: any = {
			survival_content = 1,
			rules = table.clone(Content.RULES),
			limits = table.clone(Content.DEFAULT_LIMITS),
			items = {},
			recipes = {},
		}
		for index = 1, Content.CAPS.list do
			table.insert(
				raw.items,
				{ id = "item-" .. index, name = string.rep("N", Content.CAPS.name), stackMax = 1000, weightMilli = 1 }
			)
			table.insert(raw.recipes, {
				id = "recipe-" .. index,
				craftMillis = 1,
				inputs = { { item = "item-1", quantity = 1 } },
				outputs = { { item = "item-2", quantity = 1 } },
			})
		end
		local content, errors = Content.canonicalize(raw)
		assert(content, table.concat(errors, "; "))
		local bag = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		bag = assert(Inventory.add(bag, Job.catalog(content), {
			itemId = "input",
			catalogId = "item-1",
			quantity = 1,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = {},
		}, bag.version))
		local jobs = Workshop.new("alice")
		for index = 1, Workshop.MAX_RETAINED do
			local context = { actorId = "alice", sessionEpoch = 0, requestId = "reserve-" .. index }
			local reserved, err = Workshop.reserve(
				jobs,
				bag,
				context,
				content,
				"revision",
				"recipe-1",
				1790899200000,
				{ carriedContainer = "bag", inReach = true }
			)
			assert(reserved, err)
			local cancelled, cancelError =
				Workshop.transition(reserved.jobs, reserved.inventory, context, reserved.jobId, "cancel", 1790899200000)
			assert(cancelled, cancelError)
			jobs, bag = cancelled.jobs, cancelled.inventory
		end
		local saved = Workshop.save(jobs)
		local restored = Workshop.fromSave(serde.decode("json", encode(saved)), "alice", { bag = bag })
		local count = 0
		for _ in restored.entries do
			count += 1
		end
		assert(count == 64, "actual retained jobs roundtrip")
		local full = {
			version = 1,
			generation = 1,
			revision = 1,
			lease = { sessionId = "server", expiresAt = 1790899260 },
			data = {
				version = 1,
				stateRevision = 1,
				envelope = { inventory = { bag = Inventory.save(bag) }, workshop = saved },
				itemTransfers = { version = 1, receipts = {} },
			},
		}
		local measured = Budget.check(full, encode)
		assert(measured.byteCount == #encode(full), "all pinned content and wrapper bytes measured")
		assert(
			not measured.accepted,
			"valid maximum-count catalog repeated across 64 jobs exceeds policy and must reject"
		)
		print("maximum-catalog 64-job full aggregate bytes=" .. measured.byteCount)
	end,
}

-- Direct native entry point without a separate fixture file; ordinary spec
-- discovery still receives the same table and does not execute it twice.
if table.find(require("@lune/process").args, "--run-envelope-budget") then
	local names: { string } = {}
	for name in specs do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		specs[name]()
		print("PASS " .. name)
	end
	print(tostring(#names) .. " passed, 0 failed")
end

return specs
