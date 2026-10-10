--!strict
local Job = require("./Job")
local Content = require("../survival/Content")
local Inventory = require("../inventory/Inventory")
local serde = require("@lune/serde")

local function fixture(slots: number?): (Content.Document, Inventory.State)
	local content = Content.canonicalize({
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		items = {
			{ id = "fiber", name = "Fiber", stackMax = 100, weightMilli = 100 },
			{ id = "rope", name = "Rope", stackMax = 1, weightMilli = 200, maxDurabilityMilli = 1000 },
		},
		recipes = {
			{
				id = "rope",
				craftMillis = 1000,
				inputs = { { item = "fiber", quantity = 3 } },
				outputs = { { item = "rope", quantity = 2 } },
			},
		},
	})
	assert(content, "crafting assertion 16")
	local catalog = Job.catalog(content)
	local bag = Inventory.new("bag", { slots = slots or 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	local items: { Inventory.Item } = {
		{
			itemId = "a",
			catalogId = "fiber",
			quantity = 2,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = { common = true, origin = "a" },
		},
		{
			itemId = "b",
			catalogId = "fiber",
			quantity = 2,
			qualityMilli = 2000,
			durabilityMilli = 0,
			attributes = { common = true, origin = "b" },
		},
	}
	for _, item in items do
		local added = Inventory.add(bag, catalog, item, bag.version)
		assert(added, "crafting assertion 25")
		bag = added
	end
	return content, bag
end

local function reserve(content: Content.Document, bag: Inventory.State): (Job.Job, Inventory.State)
	local job, nextBag, err = Job.reserve(bag, content, "revision-one", "rope", "job-one", 0)
	assert(job and nextBag and not err, "crafting assertion 33")
	return job, nextBag
end

local function reconnect(job: Job.Job, bag: Inventory.State): (Job.Job, Inventory.State)
	local restored =
		Inventory.fromSave(serde.decode("json", serde.encode("json", Inventory.save(bag))), Job.catalog(job.content))
	return Job.fromSave(serde.decode("json", serde.encode("json", Job.save(job))), restored), restored
end

return {
	["quantity weighted inheritance pins inputs catalog rules and deterministic IDs"] = function()
		local content, original = fixture()
		local job, bag = reserve(content, original)
		assert(original.reservations["job-one"] == nil and original.items.a.quantity == 2, "crafting assertion 46")
		assert(
			job.inputs[1].itemId == "a" and job.inputs[1].quantity == 2 and job.inputs[2].quantity == 1,
			"crafting assertion 47"
		)
		assert(job.outputs[1].qualityMilli == 1333 and job.outputs[1].durabilityMilli == 1333, "crafting assertion 48")
		assert(
			job.outputs[1].attributes.common == true and job.outputs[1].attributes.origin == nil,
			"crafting assertion 49"
		)
		assert(
			job.outputs[1].itemId == "job-one:output:1" and job.outputs[2].itemId == "job-one:output:2",
			"crafting assertion 50"
		)
		content.recipes[1].craftMillis = 9000
		content.items[2].maxDurabilityMilli = 9000
		content.rules.inheritance = "future-rule"
		job, bag = reconnect(job, bag)
		job = Job.start(job, 100)
		assert(job.finishAt == 1100 and job.catalogRevision == "revision-one", "crafting assertion 56")
		job, bag = reconnect(job, bag)
		local running, unchanged, early = Job.complete(job, bag, 1099)
		assert(
			running.state == "Running" and early == "NOT_READY" and unchanged.version == bag.version,
			"crafting assertion 59"
		)
		local done, completed, err = Job.complete(job, bag, 900000)
		assert(
			not err and done.state == "Committed" and completed.items.a == nil and completed.items.b.quantity == 1,
			"crafting assertion 61"
		)
		assert(completed.items["job-one:output:1"].durabilityMilli == 1333, "crafting assertion 62")
		done, completed = reconnect(done, completed)
		for _ = 1, 100 do
			local repeated, sameBag, repeatError = Job.complete(done, completed, 900000)
			assert(
				not repeatError and sameBag.version == completed.version and repeated.state == "Committed",
				"crafting assertion 66"
			)
		end
		local _, _, cancelError = Job.cancel(done, completed)
		assert(cancelError == "ALREADY_COMMITTED", "crafting assertion 69")
	end,
	["ready capacity refusal retains inputs and retry exchanges once"] = function()
		local content, original = fixture(2)
		local job, bag = reserve(content, original)
		job = Job.start(job, 0)
		local ready, full, err = Job.complete(job, bag, 1000)
		assert(
			err == "FULL_SLOTS" and ready.state == "Ready" and full.items.a.quantity == 2 and full.items.b.quantity == 2,
			"crafting assertion 76"
		)
		assert(full.version == bag.version and full.reservations["job-one"].a == 2, "crafting assertion 77")
		ready, full = reconnect(ready, full)
		local freed = Inventory.consume(full, "b", 1, full.version)
		assert(freed, "crafting assertion 80")
		local done, output, finishError = Job.complete(ready, freed, 1000)
		assert(
			not finishError and done.state == "Committed" and output.items.a == nil and output.items.b == nil,
			"crafting assertion 82"
		)
		assert(
			output.items["job-one:output:1"].quantity + output.items["job-one:output:2"].quantity == 2,
			"crafting assertion 83"
		)
	end,
	["cancel from each precommit phase releases once across restart"] = function()
		for _, phase in { "Reserved", "Running", "Ready" } do
			local content, original = fixture()
			local job, bag = reserve(content, original)
			if phase ~= "Reserved" then
				job = Job.start(job, 0)
			end
			if phase == "Ready" then
				job = Job.advance(job, 1000)
			end
			job, bag = reconnect(job, bag)
			local cancelled, restored, err = Job.cancel(job, bag)
			assert(
				not err
					and cancelled.state == "Cancelled"
					and restored.items.a.quantity == 2
					and restored.items.b.quantity == 2,
				"crafting assertion 97"
			)
			cancelled, restored = reconnect(cancelled, restored)
			local _, repeated, again = Job.cancel(cancelled, restored)
			assert(
				not again and repeated.version == restored.version and Inventory.available(repeated, "a") == 2,
				"crafting assertion 100"
			)
			local _, _, completeError = Job.complete(cancelled, restored, 1000)
			assert(completeError == "NOT_READY", "crafting assertion 102")
		end
	end,
	["reservation ownership recovery agreement and snapshot isolation"] = function()
		local content, original = fixture()
		local job, bag = reserve(content, original)
		local duplicate, _, duplicateError = Job.reserve(bag, content, "revision-one", "rope", "job-one", 0)
		assert(not duplicate and duplicateError, "crafting assertion 109")
		local stolen = Inventory.snapshot(bag)
		stolen.reservations.other = stolen.reservations["job-one"]
		stolen.reservations["job-one"] = nil
		assert(not pcall(Job.fromSave, Job.save(job), stolen), "crafting assertion 113")
		local _, _, wrong = Job.complete(Job.start(job, 0), stolen, 1000)
		assert(wrong == "RESERVATION_MISMATCH", "crafting assertion 115")
		local saved = Job.save(job)
		saved.outputs[1].qualityMilli = 5000
		assert(not pcall(Job.fromSave, saved, bag), "crafting assertion 118")
		local snapshot = Job.snapshot(job)
		snapshot.inputs[1].attributes.common = false
		snapshot.content.items[1].weightMilli = 0
		assert(
			job.inputs[1].attributes.common == true and job.content.items[1].weightMilli == 100,
			"crafting assertion 122"
		)
		assert(job.state == "Reserved" and bag.items.a.quantity == 2, "crafting assertion 123")
	end,
}
