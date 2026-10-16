--!strict
-- Crafting upgrades: tag slots, mastery cap, craft-crit/latent rolls, workbench
-- tiers, repair, and QA-BM-02 (rolls independent of game-pass ownership).
local Job = require("./Job")
local Content = require("../survival/Content")
local Inventory = require("../inventory/Inventory")
local Catalog = require("../inventory/ItemCatalog")
local Workshop = require("../../../genres/survival-coop/module/Workshop")
local serde = require("@lune/serde")

local function document(): Content.Document
	local raw: any = {
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		tags = { "hide", "sturdy", "keen" },
		structures = {
			{
				id = "bench",
				footprintX = 1,
				footprintZ = 1,
				station = true,
				tier = 1,
				cost = { { item = "hide", quantity = 1 } },
			},
			{
				id = "forge",
				footprintX = 2,
				footprintZ = 2,
				station = true,
				tier = 2,
				cost = { { item = "hide", quantity = 1 } },
			},
		},
		items = {
			{ id = "hide", name = "Hide", stackMax = 100, weightMilli = 10, tags = { "hide" } },
			{ id = "pelt", name = "Pelt", stackMax = 100, weightMilli = 10, tags = { "hide" } },
			{ id = "vest", name = "Vest", stackMax = 1, weightMilli = 10, maxDurabilityMilli = 1000, tags = {} },
		},
		recipes = {
			{
				id = "vest",
				craftMillis = 1000,
				inputs = {},
				slots = { { tag = "hide", minGrade = 2, quantity = 2 } },
				outputs = { { item = "vest", quantity = 1 } },
				station = "bench",
				latents = { "sturdy", "keen" },
			},
			{
				id = "fine-vest",
				craftMillis = 1000,
				inputs = { { item = "pelt", quantity = 1 } },
				slots = { { tag = "hide", minGrade = 1, quantity = 1 } },
				outputs = { { item = "vest", quantity = 1 } },
				station = "forge",
				tier = 2,
			} :: any,
		},
	}
	local content, errors = Content.canonicalize(raw)
	assert(content, table.concat(errors, "; "))
	return content
end

local function bag(content: Content.Document, items: { { string | number } }): Inventory.State
	local state = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	for _, entry in items do
		local added, err = Inventory.add(state, Job.catalog(content), {
			itemId = entry[1] :: string,
			catalogId = entry[2] :: string,
			quantity = entry[3] :: number,
			qualityMilli = entry[4] :: number,
			durabilityMilli = 0,
			attributes = {},
		}, state.version)
		assert(added, err)
		state = added
	end
	return state
end

-- Canonical text of a craft result sequence, hashed for comparison.
local function sequenceHash(seed: number, entitlements: { [string]: any }?): (string, number, number)
	local content = document()
	local inventory = bag(content, { { "h", "hide", 100, 3500 } })
	local lines: { string } = {}
	local crits, latents = 0, 0
	for index = 1, 40 do
		local job, nextBag, err = Job.reserve(
			inventory,
			content,
			"rev",
			"vest",
			"job-" .. tostring(index),
			0,
			{ seed = seed, masteryCapMilli = 3000, entitlements = entitlements }
		)
		assert(job and nextBag, err)
		local released = Inventory.release(nextBag, job.id, nextBag.version)
		assert(released, "release")
		inventory = released
		local output = job.outputs[1]
		crits += if job.critical then 1 else 0
		latents += if output.latent then 1 else 0
		table.insert(
			lines,
			string.format("%s|%d|%s|%s", job.id, output.qualityMilli, tostring(job.critical), tostring(output.latent))
		)
	end
	return serde.hash("sha256", table.concat(lines, "\n")), crits, latents
end

return {
	["QA-BM-02 same seed gives identical result hash regardless of entitlements"] = function()
		local free, crits, latents = sequenceHash(42, nil)
		local passes = { "vip", "double-craft", "premium-bench" }
		for _, owned in { {}, { vip = true }, { vip = true, ["double-craft"] = true, ["premium-bench"] = true } } do
			local hash = sequenceHash(42, owned)
			assert(hash == free, "entitlements changed craft results: " .. table.concat(passes, ","))
		end
		-- The sequence must actually exercise both rolls to mean anything.
		assert(crits > 0 and crits < 40 and latents > 0 and latents < 40, "rolls not exercised")
		-- Negative: a different seed must change the hash, or the check is vacuous.
		assert(sequenceHash(43, { vip = true }) ~= free, "seed does not drive rolls")
	end,
	["quality is the material average capped by mastery with crit bonus after the cap"] = function()
		local content = document()
		local inventory = bag(content, { { "a", "hide", 1, 2000 }, { "b", "pelt", 1, 5000 } })
		for index = 1, 30 do
			local job = Job.reserve(
				inventory,
				content,
				"rev",
				"vest",
				"q-" .. tostring(index),
				0,
				{ seed = 7, masteryCapMilli = 2500 }
			)
			assert(job, "reserve")
			local expected = if job.critical then 3500 else 2500
			assert(job.outputs[1].qualityMilli == expected, "mastery cap or crit bonus")
		end
		-- Without recorded rolls the legacy average rule is unchanged.
		local plain = Job.reserve(inventory, content, "rev", "vest", "plain", 0)
		assert(plain and plain.outputs[1].qualityMilli == 3500 and plain.critical == nil, "legacy average")
	end,
	["tag slots require the minimum grade and fixed inputs combine with slots"] = function()
		local content = document()
		local low = bag(content, { { "a", "hide", 5, 1999 } })
		local _, _, err = Job.reserve(low, content, "rev", "vest", "low", 0)
		assert(err == "MISSING_INPUTS", "grade 1 must not fill a grade 2 slot")
		local mixed = bag(content, { { "a", "hide", 1, 1000 }, { "b", "pelt", 1, 2000 } })
		local job, reserved = Job.reserve(mixed, content, "rev", "fine-vest", "mixed", 0, { seed = 1 })
		assert(job and reserved and #job.inputs == 2, "fixed pelt plus hide slot")
		assert(reserved.reservations.mixed.a == 1 and reserved.reservations.mixed.b == 1, "reservation")
		local restored = Job.fromSave(serde.decode("json", serde.encode("json", Job.save(job))), reserved)
		assert(restored.critical == job.critical and restored.roll and restored.roll.seed == 1, "v2 save roll")
		local tampered = Job.save(job)
		tampered.critical = not job.critical
		assert(not pcall(Job.fromSave, tampered, reserved), "tampered crit must be refused")
		local reseeded = Job.save(job)
		reseeded.roll.seed = 2
		reseeded.critical = job.critical
		local ok = pcall(Job.fromSave, reseeded, reserved)
		local rerolled = Job.reserve(mixed, content, "rev", "fine-vest", "mixed", 0, { seed = 2 })
		assert(rerolled, "reroll")
		assert(
			ok == (rerolled.critical == job.critical and rerolled.outputs[1].latent == job.outputs[1].latent),
			"roll fields are re-derived on load"
		)
	end,
	["workbench tier gates recipes"] = function()
		local content = document()
		local inventory = bag(content, { { "a", "hide", 1, 1000 }, { "b", "pelt", 1, 2000 } })
		local context = { actorId = "alice", sessionEpoch = 1, requestId = "r" }
		local low =
			{ carriedContainer = "bag", stationId = "f1", stationKind = "forge", stationTier = 1, inReach = true }
		local _, err = Workshop.reserve(Workshop.new("alice"), inventory, context, content, "rev", "fine-vest", 0, low)
		assert(err == "STATION_TIER", "tier 1 forge must refuse a tier 2 recipe")
		local declared = { carriedContainer = "bag", stationId = "f1", stationKind = "forge", inReach = true }
		local candidate, reason =
			Workshop.reserve(Workshop.new("alice"), inventory, context, content, "rev", "fine-vest", 0, declared)
		assert(candidate, reason)
		local bad = table.clone(content.recipes[1])
		local raw: any = {
			survival_content = 1,
			rules = table.clone(Content.RULES),
			limits = table.clone(Content.DEFAULT_LIMITS),
			items = content.items,
			recipes = { bad },
		}
		bad.tier = 2
		bad.station = nil
		bad.slots = nil
		bad.latents = nil
		bad.inputs = { { item = "hide", quantity = 1 } }
		local _, errors = Content.canonicalize(raw)
		local found = false
		for _, message in errors do
			found = found or string.find(message, "tier", 1, true) ~= nil
		end
		assert(found, "tier without a station must be rejected")
	end,
	["repair permanently lowers max durability"] = function()
		local content = document()
		local catalog = Job.catalog(content)
		local inventory = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		local added = Inventory.add(inventory, catalog, {
			itemId = "v",
			catalogId = "vest",
			quantity = 1,
			qualityMilli = 2000,
			durabilityMilli = 500,
			attributes = {},
		}, 0)
		assert(added, "add")
		local repaired, err = Job.repair(added, catalog, "v", added.version)
		assert(repaired, err)
		assert(repaired.items.v.maxDurabilityMilli == 1800 and repaired.items.v.durabilityMilli == 1800, "first repair")
		assert(added.items.v.maxDurabilityMilli == nil, "copy on write")
		local _, full = Job.repair(repaired, catalog, "v", repaired.version)
		assert(full == "NOTHING_TO_REPAIR", "full item")
		local worn = Inventory.snapshot(repaired)
		worn.items.v.durabilityMilli = 0
		local again = Job.repair(worn, catalog, "v", worn.version)
		assert(again and again.items.v.maxDurabilityMilli == 1620, "second repair lowers again")
		local restored = Inventory.fromSave(serde.decode("json", serde.encode("json", Inventory.save(again))), catalog)
		assert(restored.items.v.maxDurabilityMilli == 1620, "persisted max")
		local overfull = Inventory.save(again)
		overfull.items.v.durabilityMilli = 1700
		assert(not pcall(Inventory.fromSave, overfull, catalog), "durability above repaired max refused")
		assert(Catalog.grade(999) == 1 and Catalog.grade(3500) == 3 and Catalog.grade(5000) == 5, "grades")
	end,
}
