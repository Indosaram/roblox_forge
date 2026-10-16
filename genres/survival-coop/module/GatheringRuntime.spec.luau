--!strict
local Runtime = require("./GatheringRuntime")
local Gathering = require("./Gathering")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Content = require("../../../core/domain/survival/Content")
local Job = require("../../../core/domain/crafting/Job")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Fenced = require("../../../core/infra/data/FencedStore")
local Personal = require("../../../core/infra/data/PersonalAggregate")
local Events = require("../../../core/infra/analytics/Events")
local serde = require("@lune/serde")
local function encode(value: any): string
	return serde.encode("json", value)
end
local function fixture(): any
	local c: any = { now = 0, allowed = true, reachable = true, equipped = true, calls = 0, failAt = 0, cap = 20 }
	local document, errors = Content.canonicalize({
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
	c.content = assert(document, table.concat(errors, "; "))
	c.catalog = Job.catalog(c.content)
	c.initial = Gathering.new("world-1", c.content, {
		{
			id = "bush-1",
			catalogId = "bush",
			position = { x = 1, y = 0, z = 2 },
			charges = 1,
			qualityMilli = 1500,
			requiredToolTag = "cut",
		},
	})
	c.memory = Memory.new()
	c.backend = {
		update = function(key: string, transform: Memory.Transform): (boolean, any)
			c.calls += 1
			if c.barrier then
				local barrier = c.barrier
				c.barrier = nil
				c.memory.update(key, function(old)
					transform(old)
					return old
				end)
				barrier(key)
			end
			if c.calls == c.failAt then
				c.hit = true
				c.memory.update(key, function(old)
					local candidate = transform(old)
					return if c.lost then candidate else old
				end)
				return false, "INJECTED_FAILURE"
			end
			return c.memory.update(key, transform)
		end,
	}
	c.read = function(key: string): any
		local ok, value = c.memory.update(key, function(old)
			return old
		end)
		assert(ok, "durable read")
		return value
	end
	c.open = function(session: string)
		local options: Fenced.Options = {
			sessionId = session,
			leaseSeconds = 30,
			budget = { encode = encode },
			now = function(): number
				return c.now
			end,
		}
		c.personal = Personal.new(c.backend, {
			namespace = "personal-v1",
			store = options,
			inventoryPath = { "bag" },
			validateEnvelope = function(value: any): boolean
				return type(value) == "table" and pcall(Inventory.fromSave, value.bag, c.catalog)
			end,
		})
		c.token = assert(c.personal:load("alice", function(): any
			local bag = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
			bag = assert(Inventory.add(bag, c.catalog, {
				itemId = "knife",
				catalogId = "knife",
				quantity = 1,
				qualityMilli = 1000,
				durabilityMilli = 1000,
				attributes = {},
			}, 0))
			return { bag = Inventory.save(bag), unrelated = { coins = 17 } }
		end))
		c.store = Fenced.new(c.backend, options)
		c.runtime = assert(Runtime.new({
			key = "nodes:world-1",
			initial = c.initial,
			content = c.content,
			maxReceipts = c.cap,
			analytics = c.analytics,
			nowMillis = function(): number
				return c.millis or 0
			end,
			now = function(): number
				return c.now
			end,
			resolvePersonal = function(actor)
				if actor ~= "alice" then
					return nil
				end
				return {
					personal = c.personal,
					profile = function()
						return c.token
					end,
					install = function(token)
						c.token = token
					end,
				}
			end,
			access = function(req, bag, _data)
				if not c.allowed or req.actorId ~= "alice" or req.sessionEpoch ~= 0 then
					return nil
				end
				assert(bag.items.knife ~= nil, "equipment from real sole owner")
				return {
					actorId = "alice",
					carriedContainer = "bag",
					worldRevision = "world-1",
					equipment = function()
						return if c.equipped then { knife = true } else {}
					end,
					reachable = function(_actor, position)
						assert(position.x == 1 and position.z == 2, "server node position")
						return c.reachable
					end,
				}
			end,
		}, c.store))
	end
	c.restart = function()
		local fresh = Memory.new()
		for _, key in { "nodes:world-1", "personal-v1:alice" } do
			local snapshot = serde.decode("json", encode(c.read(key)))
			fresh.update(key, function()
				return snapshot
			end)
		end
		c.memory = fresh
		c.open("same-session") -- new generation immediately, no lease sleep
	end
	c.request = {
		actorId = "alice",
		sessionEpoch = 0,
		requestId = "harvest",
		nodeId = "bush-1",
		nodeVersion = 0,
		expiresAt = 10,
	}
	c.open("same-session")
	return c
end
local function conserved(c: any, accepted: boolean)
	local source = c.read("nodes:world-1").data
	local personal = c.read("personal-v1:alice").data
	assert(source.inventory == nil and personal.inventory == nil, "no mirrored or spendable source inventory")
	assert(personal.envelope.unrelated.coins == 17, "unrelated personal fields retained")
	assert(source.nodes.nodes["bush-1"].charges == (if accepted then 0 else 1), "exact charge")
	local total = { fiber = 0, seed = 0 }
	for _, item in personal.envelope.bag.items do
		if total[item.catalogId] then
			total[item.catalogId] += item.quantity
		end
	end
	for id, receipt in source.itemTransfers.receipts do
		local credited = personal.itemTransfers.receipts[id]
		if not credited then
			assert(receipt.phase == "ESCROWED", "uncredited liability retained")
			total[receipt.item.catalogId] += receipt.item.quantity
		end
	end
	assert(total.fiber == (if accepted then 3 else 0) and total.seed == (if accepted then 1 else 0), "conservation")
end
local function finish(c: any)
	for _ = 1, 3 do
		c.runtime.recover("alice", 8)
	end
	local state = c.read("nodes:world-1").data
	for _, receipt in state.itemTransfers.receipts do
		assert(receipt.phase == "FINALIZED", "all finalized")
	end
	conserved(c, true)
end

return {
	["accepted gather emits one typed analytics event and replays or refusals emit none"] = function()
		local seen: { { name: string, fields: { [string]: any } } } = {}
		local refused = fixture()
		refused.analytics = Events.new(function(name: string, fields: { [string]: any })
			table.insert(seen, { name = name, fields = fields })
		end)
		refused.open("same-session")
		refused.allowed = false
		assert(refused.runtime.command(refused.request).status == "rejected", "access refusal")
		assert(#seen == 0, "a refused gather emits nothing")
		local c = fixture()
		c.millis = 4200
		c.analytics = refused.analytics
		c.open("same-session")
		assert(c.runtime.command(c.request).status == "pending", "first credit is pending finalization")
		finish(c)
		for _ = 1, 3 do
			assert(c.runtime.command(c.request).status == "confirmed", "exact duplicate")
		end
		assert(#seen == 1, "exactly one gather event, got " .. #seen)
		local event = seen[1]
		assert(event.name == "gather", "gather event")
		assert(event.fields.actorId == "alice" and event.fields.nodeId == "bush-1", "actor and node")
		assert(event.fields.quantity == 4, "fiber 3 + seed 1 minted, got " .. tostring(event.fields.quantity))
		assert(event.fields.atMillis == 4200, "explicit clock, not wall time")
		assert(c.analytics:counts().gather == 1, "counted once")
	end,
	["respawn persists exact deadline capacity and version without replay harvest"] = function()
		local c = fixture()
		c.runtime.command(c.request)
		finish(c)
		c.millis = 999
		c.runtime.recover("alice", 1)
		assert(c.runtime.snapshot().nodes.nodes["bush-1"].charges == 0, "before deadline")
		local nextRequest = table.clone(c.request)
		nextRequest.requestId, nextRequest.nodeVersion = "next", 1
		assert(c.runtime.command(nextRequest).error == "NODE_DEPLETED", "cannot gather before deadline")
		c.millis = 1000
		c.restart()
		c.runtime.recover("alice", 1)
		local snapshot = c.runtime.snapshot()
		assert(
			snapshot.nodes.version == 2 and snapshot.nodes.nodes["bush-1"].charges == 1,
			"exact deadline after restart"
		)
		c.runtime.recover("alice", 1)
		assert(c.runtime.snapshot().nodes.version == 2, "refill once")
		assert(c.runtime.command(c.request).status == "confirmed", "old request retains outcome")
		assert(c.runtime.snapshot().nodes.nodes["bush-1"].charges == 1, "replay never harvests respawn")
		nextRequest.nodeVersion = 2
		assert(c.runtime.command(nextRequest).status == "pending", "new identity harvests next cycle")
	end,
	["two yields exactly once across one hundred duplicate requests"] = function()
		local c = fixture()
		assert(c.runtime.command(c.request).status == "pending", "first credit is pending finalization")
		finish(c)
		for _ = 1, 100 do
			assert(c.runtime.command(c.request).status == "confirmed", "exact duplicate")
		end
		conserved(c, true)
		c.request.nodeId = "different"
		assert(c.runtime.command(c.request).error == "REQUEST_CONFLICT", "payload conflict")
		c.request.requestId, c.request.nodeId = "second", "bush-1"
		assert(c.runtime.command(c.request).error == "STALE_VERSION", "last charge has one winner")
	end,
	["every source credit refresh and finalize boundary reconstructs immediately"] = function()
		-- First command has eight durable calls: personal refresh, source mint,
		-- then source read/destination credit/personal hydration per output.
		for _, lost in { false, true } do
			for boundary = 1, 8 do
				local c = fixture()
				c.failAt, c.lost = c.calls + boundary, lost
				c.runtime.command(c.request)
				assert(c.hit, "exact failure boundary reached")
				c.restart()
				c.runtime.command(c.request)
				finish(c)
			end
			-- Recovery: cursor commit, source read, destination receipt read,
			-- personal hydration, source finalize, repeated for the second output.
			for boundary = 1, 9 do
				local c = fixture()
				c.runtime.command(c.request)
				c.failAt, c.lost = c.calls + boundary, lost
				c.runtime.recover("alice", 8)
				assert(c.hit, "exact finalize boundary reached")
				c.restart()
				finish(c)
			end
		end
	end,
	["accepted escrow survives expiry and full bag until capacity returns"] = function()
		local c = fixture()
		local lens = c.personal:inventoryLens()
		assert(
			lens:update(c.token, function(data)
				data.inventory.limits.slots = 1
				return data
			end),
			"fill bag"
		)
		assert(c.runtime.command(c.request).error == "FULL_SLOTS", "pending capacity")
		conserved(c, true)
		c.now = 30
		c.restart()
		c.allowed = false
		assert(c.runtime.recover("alice", 8).error == "FULL_SLOTS", "irrevocable beyond expiry and authority")
		assert(
			c.personal:inventoryLens():update(c.token, function(data)
				data.inventory.limits.slots = 20
				return data
			end),
			"capacity returns"
		)
		finish(c)
	end,
	["authority range tool and batch capacity refusals leave all charges"] = function()
		for _, field in { "allowed", "reachable", "equipped" } do
			local c = fixture()
			c[field] = false
			assert(c.runtime.command(c.request).status == "rejected", "access refusal")
			conserved(c, false)
		end
		local c = fixture()
		c.cap = 1
		c.open("same-session")
		assert(c.runtime.command(c.request).error == "RECEIPT_LIMIT", "second yield cannot fit")
		conserved(c, false)
		assert(next(c.read("nodes:world-1").data.itemTransfers.receipts) == nil, "no partial escrow")
	end,
	["recovery bound counts outputs and retained receipts never evict"] = function()
		local c = fixture()
		c.runtime.command(c.request)
		local first = c.runtime.recover("alice", 1)
		assert(#first.transfers == 1, "one output per budget unit")
		local second = c.runtime.recover("alice", 1)
		assert(#second.transfers == 1 and second.transfers[1].id ~= first.transfers[1].id, "fair pending cursor")
		assert(#c.runtime.recover("alice", 1).transfers == 0, "finalized records not scheduled again")
		conserved(c, true)
	end,
	["expired finalized mints retire one output per budget and cannot remint"] = function()
		local c = fixture()
		c.runtime.command(c.request)
		finish(c)
		c.now = 10
		c.runtime.recover("alice", 1)
		local count = 0
		for _ in c.read("nodes:world-1").data.itemTransfers.receipts do
			count += 1
		end
		assert(count == 1, "one retired output")
		c.restart()
		c.runtime.recover("alice", 1)
		local data = c.read("nodes:world-1").data
		assert(next(data.grants) == nil and next(data.itemTransfers.receipts) == nil, "source capacity reclaimed")
		assert(next(c.read("personal-v1:alice").data.itemTransfers.receipts) == nil, "destination capacity reclaimed")
		assert(c.runtime.command(c.request).error == "REQUEST_EXPIRED", "durable watermark rejects replay")
		conserved(c, true)
	end,
	["mint retirement failures and lost acknowledgments restart without duplicate credit"] = function()
		for _, lost in { false, true } do
			for boundary = 1, 7 do
				local c = fixture()
				c.runtime.command(c.request)
				finish(c)
				c.now = 10
				c.failAt, c.lost = c.calls + boundary, lost
				c.runtime.recover("alice", 1)
				assert(c.hit, "retirement boundary reached")
				c.restart()
				c.runtime.recover("alice", 8)
				assert(next(c.read("nodes:world-1").data.grants) == nil, "retirement resumes")
				assert(c.runtime.command(c.request).error == "REQUEST_EXPIRED", "no remint")
				conserved(c, true)
			end
		end
	end,
	["different owner takeover at the source callback fences stale mint"] = function()
		local c = fixture()
		local stale = c.runtime
		c.barrier = function()
			c.barrier = function()
				c.now = 30
				c.open("takeover")
			end
		end
		assert(stale.command(c.request).error == "lease lost", "callback lease rechecked")
		conserved(c, false)
		c.request.expiresAt = 40
		c.runtime.command(c.request)
		finish(c)
	end,
	["stale source and personal generations cannot mutate"] = function()
		local c = fixture()
		local stale = c.runtime
		c.open("same-session")
		assert(stale.command(c.request).status == "recovering", "source generation fenced")
		conserved(c, false)
		c.runtime.command(c.request)
		local token = c.token
		c.personal:load("alice", function()
			error("existing owner")
		end)
		c.token = token
		assert(c.runtime.recover("alice", 8).status == "pending", "destination generation fenced")
		conserved(c, true)
		c.restart()
		finish(c)
	end,
	["source callback replay rechecks authority and last charge"] = function()
		local c = fixture()
		-- Arm the source barrier after the personal refresh, exactly at callback.
		c.barrier = function()
			c.barrier = function()
				c.allowed = false
			end
		end
		assert(c.runtime.command(c.request).error == "UNAUTHORIZED", "authority revoked at source callback")
		conserved(c, false)
		c.allowed = true
		c.barrier = function()
			c.barrier = function()
				local competitor = table.clone(c.request)
				competitor.requestId = "competitor"
				c.runtime.command(competitor)
			end
		end
		assert(c.runtime.command(c.request).error == "STALE_VERSION", "callback sees competing final charge")
		finish(c)
	end,
}
