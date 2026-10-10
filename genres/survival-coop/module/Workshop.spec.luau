--!strict
local Workshop = require("./Workshop")
local Job = require("../../../core/domain/crafting/Job")
local Content = require("../../../core/domain/survival/Content")
local Inventory = require("../../../core/domain/inventory/Inventory")
local serde = require("@lune/serde")

local context = { actorId = "alice", sessionEpoch = 1, requestId = "reserve" }
local access = { carriedContainer = "bag", stationId = "bench-1", stationKind = "bench", inReach = true }

local function fixture(slots: number?): (Content.Document, Inventory.State)
	local content, errors = Content.canonicalize({
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		tags = { "cut" },
		structures = {
			{
				id = "bench",
				footprintX = 1,
				footprintZ = 1,
				station = true,
				cost = { { item = "fiber", quantity = 1 } },
			},
		},
		items = {
			{ id = "fiber", name = "Fiber", stackMax = 100, weightMilli = 100 },
			{ id = "cord", name = "Cord", stackMax = 100, weightMilli = 100 },
			{
				id = "knife",
				name = "Knife",
				stackMax = 1,
				weightMilli = 100,
				maxDurabilityMilli = 1000,
				tags = { "cut" },
			},
		},
		recipes = {
			{
				id = "cord",
				craftMillis = 1000,
				inputs = { { item = "fiber", quantity = 3 } },
				outputs = { { item = "cord", quantity = 1 } },
				requiredToolTag = "cut",
				station = "bench",
			},
		},
	})
	assert(content, table.concat(errors, "; "))
	local bag = Inventory.new("bag", { slots = slots or 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	local items: { Inventory.Item } = {
		{
			itemId = "fiber",
			catalogId = "fiber",
			quantity = 30,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = { origin = "field" },
		},
		{
			itemId = "knife",
			catalogId = "knife",
			quantity = 1,
			qualityMilli = 1000,
			durabilityMilli = 1000,
			attributes = {},
		},
	}
	for _, item in items do
		local added, err = Inventory.add(bag, Job.catalog(content), item, bag.version)
		assert(added, err)
		bag = added
	end
	return content, bag
end

local function reserve(content: Content.Document, bag: Inventory.State): Workshop.Candidate
	local result, err = Workshop.reserve(Workshop.new("alice"), bag, context, content, "rev1", "cord", 0, access)
	assert(result, err)
	return result
end

local function step(candidate: Workshop.Candidate, action: string, now: number): Workshop.Candidate
	local result, err = Workshop.transition(candidate.jobs, candidate.inventory, context, candidate.jobId, action, now)
	assert(result, err)
	return result
end

local function reconnect(candidate: Workshop.Candidate): Workshop.Candidate
	local catalog = Job.catalog(candidate.jobs.entries[candidate.jobId].job.content)
	local bag =
		Inventory.fromSave(serde.decode("json", serde.encode("json", Inventory.save(candidate.inventory))), catalog)
	local jobs = Workshop.fromSave(
		serde.decode("json", serde.encode("json", Workshop.save(candidate.jobs))),
		"alice",
		{ bag = bag }
	)
	return { inventory = bag, jobs = jobs, jobId = candidate.jobId }
end

return {
	["initial Ledger epoch zero can reserve and restore"] = function()
		local content, bag = fixture()
		local candidate, err = Workshop.reserve(
			Workshop.new("alice"),
			bag,
			{ actorId = "alice", sessionEpoch = 0, requestId = "first" },
			content,
			"rev1",
			"cord",
			0,
			access
		)
		assert(candidate, err)
		local restored = reconnect(candidate)
		assert(restored.jobs.entries[candidate.jobId].epoch == 0, "initial durable epoch")
	end,
	["three fiber to one cord survives every phase and changed live recipe"] = function()
		local content, bag = fixture()
		local candidate = reconnect(reserve(content, bag))
		content.recipes[1].craftMillis = 99999
		content.recipes[1].outputs[1].quantity = 5
		candidate = reconnect(step(candidate, "start", 10))
		assert(candidate.jobs.entries[candidate.jobId].job.finishAt == 1010, "pinned deadline")
		candidate = reconnect(step(candidate, "complete", 1010))
		assert(candidate.inventory.items.fiber.quantity == 27, "consume exactly three")
		assert(candidate.inventory.items[candidate.jobId .. ":output:1"].quantity == 1, "one pinned cord")
		local _, err = Workshop.transition(
			candidate.jobs,
			candidate.inventory,
			{ actorId = "alice", sessionEpoch = 1, requestId = "new-complete" },
			candidate.jobId,
			"complete",
			1010
		)
		assert(err == "ALREADY_COMMITTED", "new identity refuses terminal completion")
	end,
	["repeated staging has no hidden mutation and cannot reserve a second time"] = function()
		local content, bag = fixture()
		local original = Workshop.new("alice")
		local first = reserve(content, bag)
		for _ = 1, 100 do
			local staged = Workshop.reserve(original, bag, context, content, "rev1", "cord", 0, access)
			assert(
				staged and staged.jobId == first.jobId and staged.inventory.version == first.inventory.version,
				"stable restaging"
			)
			local duplicate, err =
				Workshop.reserve(first.jobs, first.inventory, context, content, "rev1", "cord", 0, access)
			assert(not duplicate and err == "ALREADY_RESERVED", "one reservation")
		end
		assert(next(original.entries) == nil and next(bag.reservations) == nil, "source isolation")
		first.jobs.entries[first.jobId].job.content.items[1].name = "changed"
		assert(content.items[1].name ~= "changed", "content isolation")
	end,
	["full output remains Ready across JSON restart until slot freed"] = function()
		local content, bag = fixture(2)
		local candidate = step(reserve(content, bag), "start", 0)
		candidate = step(candidate, "complete", 1000)
		assert(
			candidate.reason == "FULL_SLOTS" and candidate.jobs.entries[candidate.jobId].job.state == "Ready",
			"ready refusal"
		)
		assert(candidate.inventory.items.fiber.quantity == 30, "no early consumption")
		candidate = reconnect(candidate)
		local freed = Inventory.consume(candidate.inventory, "knife", 1, candidate.inventory.version)
		assert(freed, "free one slot")
		candidate.inventory = freed
		candidate = step(candidate, "complete", 1000)
		assert(
			not candidate.reason and candidate.inventory.items.fiber.quantity == 27,
			"exchange once after freeing slot"
		)
	end,
	["cancelled jobs persist and epoch rotation never prunes active jobs"] = function()
		local content, bag = fixture()
		local cancelled = reconnect(step(reserve(content, bag), "cancel", 0))
		assert(Inventory.available(cancelled.inventory, "fiber") == 30, "reservation released")
		local rotated = Workshop.reserve(
			cancelled.jobs,
			cancelled.inventory,
			{ actorId = "alice", sessionEpoch = 2, requestId = "next" },
			content,
			"rev1",
			"cord",
			0,
			access
		)
		assert(rotated and rotated.jobs.entries[cancelled.jobId] ~= nil, "terminal retained across epoch")
		local _, err = Workshop.reserve(rotated.jobs, rotated.inventory, context, content, "rev1", "cord", 0, access)
		assert(err == "REQUEST_EXPIRED", "old terminal identity cannot recreate")
		local nextEpoch = Workshop.reserve(
			rotated.jobs,
			rotated.inventory,
			{ actorId = "alice", sessionEpoch = 3, requestId = "next" },
			content,
			"rev1",
			"cord",
			0,
			access
		)
		assert(nextEpoch and nextEpoch.jobs.entries[rotated.jobId], "active survives epoch")
	end,
	["actor container tools and station checks reject unauthorized reserve"] = function()
		local content, bag = fixture()
		local candidate = reserve(content, bag)
		local _, actorError = Workshop.transition(
			candidate.jobs,
			candidate.inventory,
			{ actorId = "bob", sessionEpoch = 1, requestId = "finish" },
			candidate.jobId,
			"start",
			0
		)
		assert(actorError == "WRONG_ACTOR", "actor ownership")
		local wrong = Inventory.snapshot(candidate.inventory)
		wrong.id = "other"
		local _, containerError = Workshop.transition(candidate.jobs, wrong, context, candidate.jobId, "start", 0)
		assert(containerError == "WRONG_CONTAINER", "container ownership")
		assert(
			not pcall(Workshop.fromSave, Workshop.save(candidate.jobs), "bob", { bag = candidate.inventory }),
			"saved owner"
		)
		bag.items.knife.durabilityMilli = 0
		local _, toolError = Workshop.reserve(Workshop.new("alice"), bag, context, content, "rev1", "cord", 0, access)
		assert(toolError == "TOOL_UNAVAILABLE", "broken tool")
		content.recipes[1].station = "bench"
		local _, stationError = Workshop.reserve(
			Workshop.new("alice"),
			bag,
			context,
			content,
			"rev1",
			"cord",
			0,
			{ carriedContainer = "bag", inReach = false }
		)
		assert(stationError == "STATION_UNAVAILABLE", "missing station")
		-- Existing jobs require neither current content nor a station port to finish.
		candidate = step(step(candidate, "start", 0), "complete", 1000)
		assert(not candidate.reason, "finish independently of removed station and tool")
	end,
	["queue and unambiguous identity limits are enforced"] = function()
		local content, bag = fixture()
		local state = Workshop.new("alice")
		for n = 1, Workshop.MAX_ACTIVE do
			local candidate = Workshop.reserve(
				state,
				bag,
				{ actorId = "alice", sessionEpoch = 1, requestId = tostring(n) },
				content,
				"rev1",
				"cord",
				0,
				access
			)
			assert(candidate, "queue slot")
			state, bag = candidate.jobs, candidate.inventory
		end
		local _, err = Workshop.reserve(state, bag, context, content, "rev1", "cord", 0, access)
		assert(err == "JOB_QUEUE_FULL", "bounded active queue")
		content, bag = fixture()
		state = Workshop.new("alice")
		for n = 1, Workshop.MAX_RETAINED do
			local ctx = { actorId = "alice", sessionEpoch = 1, requestId = tostring(n) }
			local candidate = Workshop.reserve(state, bag, ctx, content, "rev1", "cord", 0, access)
			assert(candidate, "terminal retention slot")
			local cancelled =
				Workshop.transition(candidate.jobs, candidate.inventory, ctx, candidate.jobId, "cancel", 0)
			assert(cancelled, "cancel retained job")
			state, bag = cancelled.jobs, cancelled.inventory
		end
		local _, retainedError = Workshop.reserve(state, bag, context, content, "rev1", "cord", 0, access)
		assert(retainedError == "JOB_QUEUE_FULL", "bounded terminal retention")
		local pruned = Workshop.prune(state, 2)
		assert(next(pruned.entries) == nil and next(state.entries) ~= nil, "detached safe cleanup")
		pruned =
			Workshop.fromSave(serde.decode("json", serde.encode("json", Workshop.save(pruned))), "alice", { bag = bag })
		local _, expired = Workshop.reserve(pruned, bag, context, content, "rev1", "cord", 0, access)
		assert(expired == "REQUEST_EXPIRED", "pruned identities never recreate")
		local renewed = Workshop.reserve(
			pruned,
			bag,
			{ actorId = "alice", sessionEpoch = 2, requestId = "renewed" },
			content,
			"rev1",
			"cord",
			0,
			access
		)
		assert(renewed, "safe cutoff frees capacity")
		assert(
			Workshop.identity({ actorId = "a:1", sessionEpoch = 2, requestId = "b" })
				~= Workshop.identity({ actorId = "a", sessionEpoch = 1, requestId = "2:b" }),
			"length framed identity"
		)
		assert(
			Workshop.identity({ actorId = "alice", sessionEpoch = 1, requestId = string.rep("x", 128) }) == nil,
			"oversized identity rejected"
		)
	end,
	["safe cutoff preserves old active jobs and newer completion receipts"] = function()
		local content, bag = fixture()
		local candidate = reserve(content, bag)
		candidate.jobs = Workshop.prune(candidate.jobs, 2)
		candidate = reconnect(candidate)
		assert(candidate.jobs.entries[candidate.jobId], "active old job retained")
		local current = { actorId = "alice", sessionEpoch = 2, requestId = "start-old" }
		local started = Workshop.transition(candidate.jobs, candidate.inventory, current, candidate.jobId, "start", 0)
		assert(started, "new request starts old active job")
		current.requestId = "finish-old"
		local done = Workshop.transition(started.jobs, started.inventory, current, candidate.jobId, "complete", 1000)
		assert(done and not done.reason, "new request completes old active job")
		done = reconnect(done)
		assert(Workshop.prune(done.jobs, 2).entries[done.jobId], "completion receipt still retained")
		assert(next(Workshop.prune(done.jobs, 3).entries) == nil, "expired completion receipt releases terminal")
		assert(not pcall(Workshop.prune, done.jobs, 1), "floor cannot regress")
		local forged = Workshop.save(done.jobs)
		forged.expiredBeforeEpoch = 3
		assert(not pcall(Workshop.fromSave, forged, "alice", { bag = done.inventory }), "floor exceeds epoch rejected")
		forged.epoch = 3
		assert(not pcall(Workshop.fromSave, forged, "alice", { bag = done.inventory }), "terminal below floor rejected")
		forged = Workshop.save(done.jobs)
		forged.entries[done.jobId].retainedThroughEpoch = 0
		assert(
			not pcall(Workshop.fromSave, forged, "alice", { bag = done.inventory }),
			"retention before creation rejected"
		)
	end,
}
