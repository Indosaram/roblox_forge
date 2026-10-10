--!strict
local Gathering = require("./Gathering")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Content = require("../../../core/domain/survival/Content")
local Job = require("../../../core/domain/crafting/Job")

local function fixture(slots: number?): (Content.Document, Gathering.State, Inventory.State, Gathering.Access)
	local content, errors = Content.canonicalize({
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		tags = { "cut" },
		items = {
			{ id = "fiber", name = "Fiber", stackMax = 100, weightMilli = 100 },
			{ id = "seed", name = "Seed", stackMax = 100, weightMilli = 100 },
			{
				id = "knife",
				name = "Knife",
				stackMax = 1,
				weightMilli = 100,
				maxDurabilityMilli = 1000,
				tags = { "cut" },
			},
		},
		nodes = {
			{
				id = "bush",
				respawnMillis = 1000,
				harvest = { { item = "fiber", quantity = 3 }, { item = "seed", quantity = 1 } },
			},
		},
	})
	assert(content, table.concat(errors, "; "))
	local nodes = Gathering.new("world-1", content, {
		{
			id = "bush-1",
			catalogId = "bush",
			position = { x = 4, y = 0, z = 2 },
			charges = 1,
			qualityMilli = 1500,
			requiredToolTag = "cut",
		},
	})
	local bag = Inventory.new("bag", { slots = slots or 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	local added, err = Inventory.add(bag, Job.catalog(content), {
		itemId = "knife",
		catalogId = "knife",
		quantity = 1,
		qualityMilli = 1000,
		durabilityMilli = 1000,
		attributes = {},
	}, bag.version)
	assert(added, err)
	local access: Gathering.Access = {
		actorId = "alice",
		carriedContainer = "bag",
		worldRevision = "world-1",
		equipment = function(actor)
			assert(actor == "alice", "trusted actor lookup")
			return { knife = true }
		end,
		reachable = function(actor, position)
			assert(actor == "alice" and position.x == 4 and position.z == 2, "server node position")
			return true
		end,
	}
	return content, nodes, added, access
end

local context = { actorId = "alice", sessionEpoch = 0, requestId = "gather" }

return {
	["durable harvest uses the native quality scaled maximum"] = function()
		local content, nodes, bag, access = fixture()
		content.nodes[1].harvest = { { item = "knife", quantity = 1 } }
		for _, quality in { 1, 1000, 1500, 5000 } do
			local instance = table.clone(nodes.nodes["bush-1"])
			instance.qualityMilli = quality
			local state = Gathering.new("world-1", content, { instance })
			local candidate, err = Gathering.gather(state, bag, context, content, "bush-1", 0, access)
			assert(candidate, err)
			local reward = candidate.inventory.items[candidate.itemIds[1]]
			assert(reward.durabilityMilli == quality, "catalog maximum scales by quality")
			local restored = Inventory.fromSave(Inventory.save(candidate.inventory), Job.catalog(content))
			assert(restored.items[reward.itemId].durabilityMilli == quality, "native restoration accepts reward")
		end
	end,
	["instance tool policy is optional but must reference a declared tag"] = function()
		local content, nodes, bag, access = fixture()
		local instance = table.clone(nodes.nodes["bush-1"])
		instance.requiredToolTag = nil
		local state = Gathering.new("world-1", content, { instance })
		access.equipment = function()
			return {}
		end
		local candidate, err = Gathering.gather(state, bag, context, content, "bush-1", 0, access)
		assert(candidate, err)
		instance.requiredToolTag = "undeclared"
		assert(not pcall(Gathering.new, "world-1", content, { instance }), "undeclared policy rejected")
	end,
	["native rewards preserve server quality and detached candidates"] = function()
		local content, nodes, bag, access = fixture()
		local candidate, err = Gathering.gather(nodes, bag, context, content, "bush-1", 0, access)
		assert(candidate, err)
		assert(candidate.nodes.nodes["bush-1"].charges == 0 and candidate.nodes.version == 1, "charge decremented once")
		assert(candidate.inventory.items[candidate.itemIds[1]].quantity == 3, "fiber yield")
		assert(candidate.inventory.items[candidate.itemIds[1]].qualityMilli == 1500, "server quality")
		assert(candidate.inventory.items[candidate.itemIds[2]].quantity == 1, "seed yield")
		candidate.nodes.nodes["bush-1"].position.x = 999
		candidate.inventory.items.knife.attributes.changed = true
		assert(nodes.nodes["bush-1"].position.x == 4 and nodes.nodes["bush-1"].charges == 1, "node isolation")
		assert(bag.items.knife.attributes.changed == nil and bag.version == 1, "inventory isolation")
		local snapshot = Gathering.snapshot(nodes)
		snapshot.nodes["bush-1"].position.z = 999
		assert(nodes.nodes["bush-1"].position.z == 2, "snapshot isolation")
	end,
	["refused capacity including partial multi output leaves all charges and items"] = function()
		local content, nodes, bag, access = fixture(2)
		local candidate, err = Gathering.gather(nodes, bag, context, content, "bush-1", 0, access)
		assert(not candidate and err == "FULL_SLOTS", "partial output slot refusal")
		assert(nodes.nodes["bush-1"].charges == 1 and bag.version == 1, "no early publication")
		bag.limits.slots = 20
		bag.limits.softWeightMilli = 100
		bag.limits.hardWeightMilli = 450
		local overweight, weightError = Gathering.gather(nodes, bag, context, content, "bush-1", 0, access)
		assert(not overweight and weightError == "FULL_WEIGHT", "partial output weight refusal")
		assert(nodes.version == 0 and Inventory.weight(bag, Job.catalog(content)) == 100, "unchanged weight")
	end,
	["actor container world proximity and equipped usable tool are required"] = function()
		local content, nodes, bag, access = fixture()
		local function refused(expected: string)
			local candidate, err = Gathering.gather(nodes, bag, context, content, "bush-1", 0, access)
			assert(not candidate and err == expected, tostring(err))
			assert(nodes.version == 0 and bag.version == 1, "unchanged refused state")
		end
		access.actorId = "bob"
		refused("WRONG_ACTOR")
		access.actorId = "alice"
		access.carriedContainer = "other"
		refused("WRONG_CONTAINER")
		access.carriedContainer = "bag"
		access.worldRevision = "other"
		refused("WRONG_WORLD")
		access.worldRevision = "world-1"
		access.reachable = function()
			return false
		end
		refused("NODE_UNREACHABLE")
		access.reachable = function()
			return true
		end
		access.equipment = function()
			return {}
		end
		refused("TOOL_UNAVAILABLE")
		access.equipment = function()
			return { knife = true }
		end
		bag.items.knife.durabilityMilli = 0
		refused("TOOL_UNAVAILABLE")
		bag.items.knife.durabilityMilli = 1000
		content.items[2].tags = {}
		refused("TOOL_UNAVAILABLE")
	end,
	["failed commit retries deterministically and competing final charge has one winner"] = function()
		local content, nodes, bag, access = fixture()
		local first = Gathering.gather(nodes, bag, context, content, "bush-1", 0, access)
		assert(first, "first candidate")
		-- Exact suspension boundary: both candidates are staged before the owner commits.
		local ready = false
		local competitor = coroutine.create(function()
			local staged = Gathering.gather(
				nodes,
				bag,
				{ actorId = "alice", sessionEpoch = 0, requestId = "second" },
				content,
				"bush-1",
				0,
				access
			)
			assert(staged, "competing candidate")
			ready = true
			coroutine.yield()
			assert(staged.baseNodeVersion ~= nodes.version, "owner must reject stale candidate")
			local retry, reason = Gathering.gather(
				nodes,
				bag,
				{ actorId = "alice", sessionEpoch = 0, requestId = "second" },
				content,
				"bush-1",
				nodes.version,
				access
			)
			assert(not retry and reason == "NODE_DEPLETED", "final charge already owned")
		end)
		assert(coroutine.resume(competitor))
		assert(ready and coroutine.status(competitor) == "suspended", "staging barrier reached")
		-- A failed backend commit publishes neither candidate. Re-evaluate from source.
		for _ = 1, 100 do
			local retry = Gathering.gather(nodes, bag, context, content, "bush-1", 0, access)
			assert(
				retry and retry.itemIds[1] == first.itemIds[1] and retry.inventory.version == first.inventory.version,
				"deterministic restaging"
			)
		end
		assert(nodes.nodes["bush-1"].charges == 1 and bag.version == 1, "no early publication")
		nodes, bag = first.nodes, first.inventory
		local resumed, reason = coroutine.resume(competitor)
		assert(resumed, tostring(reason))
		assert(coroutine.status(competitor) == "dead", "competitor completed")
		assert(bag.items[first.itemIds[1]].quantity == 3 and nodes.nodes["bush-1"].charges == 0, "one reward")
		local stale, err = Gathering.gather(nodes, bag, context, content, "bush-1", 0, access)
		assert(not stale and err == "STALE_VERSION", "stale shared version")
	end,
}
