--!strict
local Runtime = require("./WildlifeRuntime")
local Bridge = require("./WildlifeBridge")
local Wildlife = require("./Wildlife")
local Content = require("../../../core/domain/survival/Content")
local Session = require("../../../core/infra/genre/Session")
local Contract = require("./Contract")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Fenced = require("../../../core/infra/data/FencedStore")
local serde = require("@lune/serde")
local process = require("@lune/process")
local function encode(value: any): string
	return serde.encode("json", value)
end
local function fixture(windup: boolean?): any
	local c: any = { now = 0, calls = 0, failAt = 0, lost = false, capacity = 32 }
	local definitions: { any } = {
		{ id = "spear", name = "Spear", stackMax = 1, weightMilli = 100, maxDurabilityMilli = 1000 },
		{ id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 },
	}
	local raw: any = {
		survival_content = 1,
		rules = Content.RULES,
		limits = Content.DEFAULT_LIMITS,
		items = definitions,
		wildlife = { { id = "hunter", behavior = "hunter" }, { id = "grazer", behavior = "grazer" } },
	}
	local content, errors = Content.canonicalize(raw)
	assert(content, table.concat(errors, "; "))
	c.content = content
	if windup then
		(c.content :: any).progressionPolicy = { combat = { windupMillis = 600 } }
	end
	c.policy = Wildlife.catalog(content, {
		species = {
			hunter = { healthMilli = 20000, damageMilli = 1000, drops = { { item = "meat", quantity = 2 } } },
			grazer = { healthMilli = 40000, damageMilli = 0, drops = {} },
		},
		weapons = {
			spear = { damageMilli = 20000, wearMilli = 100, rangeStuds = 8, facingDot = 0.5, cooldownMillis = 2000 },
		},
	})
	c.memory = Memory.new()
	c.read = function(key: string): any
		local ok, data = c.memory.update(key, function(old)
			return old
		end)
		assert(ok, "read durable backend")
		return data
	end
	c.backend = {
		update = function(key, transform)
			c.calls += 1
			if c.failAll then
				return false, "INJECTED_OFFLINE"
			end
			if c.observe then
				c.observe(key, transform)
			end
			if c.barrier then
				local barrier = c.barrier
				c.barrier = nil
				barrier(key, transform)
			end
			if c.calls == c.failAt then
				c.hit = true
				if c.lost then
					c.memory.update(key, transform)
				end
				return false, "INJECTED_ACK_FAILURE"
			end
			return c.memory.update(key, transform)
		end,
	}
	c.open = function()
		local bridge = Bridge.new({
			resolve = function()
				return c.runtime
			end,
		})
		local descriptor = table.clone(Contract)
		descriptor.actions = table.clone(Contract.actions)
		for index, action in descriptor.actions do
			if action.id == "attack" then
				local replacement = table.clone(action)
				replacement.rate = { capacity = 1, refillPerSecond = 1 }
				descriptor.actions[index] = replacement
			end
		end
		local durable = {
			actions = { "survival-coop:attack", "survival-coop:inventory-split" },
			windowSeconds = 86400,
			maxOutcomes = c.capacity,
			personal = {
				namespace = "combat",
				inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" },
			},
		}
		local options: any = {
			packConfig = {
				api = 1,
				order = { "survival-coop" },
				configs = {
					["survival-coop"] = {
						mode = "crafting",
						currency = "Coins",
						startingBalance = 0,
						contentVersion = 1,
						inventory = {
							content = raw,
							carriedContainer = "bag",
							speedPenaltyMilli = 500,
							containers = {
								bag = {
									{
										itemId = "spear",
										catalogId = "spear",
										quantity = 1,
										qualityMilli = 1000,
										durabilityMilli = 1000,
										attributes = {},
									},
								},
							},
						},
					},
				},
			},
			contracts = { descriptor },
			controls = {},
			storeName = "CombatProof",
			durable = durable,
		}
		c.session = Session.new(options, c.backend, {
			sessionId = "owner",
			lockTimeout = 120,
			retries = 0,
			now = function()
				return c.now
			end,
		}, {
			now = function()
				return c.now
			end,
			roll = function()
				return 0
			end,
			emit = function() end,
			encode = encode,
			survivalWildlife = bridge,
		}, durable)
		c.options, c.durable = options, durable
		assert(c.session.join("alice").ok, "alice joins actual Session")
		assert(c.session.join("bob").ok, "bob joins actual Session")
		local store = Fenced.new(c.backend, {
			sessionId = "owner",
			leaseSeconds = 120,
			now = function()
				return c.now
			end,
			budget = { encode = encode },
		})
		c.runtime = assert(Runtime.new({
			key = "wildlife:one",
			content = content,
			catalog = c.policy,
			initial = {
				hunter = Wildlife.new("hunter", "hunter", { x = 0, y = 0, z = 0 }, c.policy),
				grazer = Wildlife.new("grazer", "grazer", { x = 0, y = 0, z = 0 }, c.policy),
			},
			carriedContainer = "bag",
			maxReceipts = c.capacity,
			now = function()
				return c.now
			end,
			nowMillis = function()
				return c.now * 1000
			end,
			resolvePersonal = function(actor)
				return c.session.personalTransfer(actor)
			end,
			access = function(actor, _target)
				return {
					actorId = actor,
					alive = true,
					position = { x = 0, y = 0, z = 0 },
					facing = { x = 1, y = 0, z = 0 },
					targetPosition = { x = if c.outOfRange then 40 else 4, y = 0, z = 0 },
					lineOfSight = true,
					equipped = { spear = true },
				}
			end,
		}, store))
	end
	c.restart = function()
		local fresh = Memory.new()
		for _, key in { "combat:alice", "combat:bob", "wildlife:one" } do
			local value = serde.decode("json", encode(c.read(key)))
			fresh.update(key, function()
				return value
			end)
		end
		c.memory = fresh
		c.open()
	end
	c.request = function(target: string, id: string): any
		return { action = "survival-coop:attack", args = { target }, requestId = id, sessionEpoch = 0 }
	end
	c.open()
	return c
end
local function check(c: any, charged: boolean)
	local source = c.read("wildlife:one").data
	local personal = c.read("combat:alice").data
	local bag = personal.envelope.genres["survival-coop"].data.inventory.bag
	assert(source.inventory == nil and personal.inventory == nil, "no shadow bag")
	assert(bag.items.spear.durabilityMilli == (if charged then 900 else 1000), "exactly one wear")
	local meat = 0
	for _, item in bag.items do
		if item.catalogId == "meat" then
			meat += item.quantity
		end
	end
	assert(meat == (if charged then 2 else 0), "exactly one loot grant")
	assert(source.npcs.hunter.healthMilli == (if charged then 0 else 20000), "exactly one lethal hit")
end
local specs: { [string]: () -> () } = {
	["server windup defers damage and rechecks geometry at strike"] = function()
		local c = fixture(true)
		local result = c.session.command("alice", c.request("hunter", "windup"))
		assert(not result.ok and result.reason == "WINDUP", "intent pending before strike")
		assert(c.read("wildlife:one").data.npcs.hunter.healthMilli == 20000, "no early damage")
		c.now, c.outOfRange = 1, true
		local recovered = c.runtime.recover("alice", 8)
		assert(recovered.ok, "bounded strike recovery: " .. tostring(recovered.reason))
		assert(c.read("wildlife:one").data.npcs.hunter.healthMilli == 20000, "moving away causes miss")
		local bag = c.read("combat:alice").data.envelope.genres["survival-coop"].data.inventory.bag
		assert(bag.items.spear.durabilityMilli == 900, "miss still pays one attempt")
	end,
	["idle recovery sweeps keep the world lease alive past its original expiry"] = function()
		local c = fixture()
		-- No player attacks for longer than the 120 s lease; only heartbeat sweeps run.
		for second = 1, 300, 5 do
			c.now = second
			-- The personal owner is kept leased the way the live heartbeat keeps it.
			assert(c.session.save("alice").ok, "renew personal lease")
			assert(c.runtime.recover("alice", 1).ok, "quiet sweep")
		end
		local first = c.session.command("alice", c.request("hunter", "late-hit"))
		assert(first.reason ~= "lease lost", "world owner kept its lease while idle: " .. tostring(first.reason))
	end,
	["a tame capture durably removes the wild, survives restart, and respawns after the window"] = function()
		local c = fixture()
		c.now = 10
		assert(c.runtime.capture("grazer", "alice:c1", 15000) == nil, "capture applies")
		local held = c.read("wildlife:one").data.npcs.grazer
		assert(held.capturedUntil == 15000 and held.captureId == "alice:c1", "durable window")
		assert(Wildlife.captured(held, 10000) and not Wildlife.captured(held, 15000), "window bounds")
		local version = held.version
		assert(c.runtime.capture("grazer", "alice:c1", 99999) == nil, "replay accepted")
		assert(c.runtime.capture("grazer", "bob:c9", 99999) == nil, "a second capture inside the window is a no-op")
		local after = c.read("wildlife:one").data.npcs.grazer
		assert(after.version == version and after.capturedUntil == 15000, "replay never double-removes")
		local refused = c.session.command("alice", c.request("grazer", "hit-captured"))
		assert(not refused.ok and refused.reason == "UNKNOWN_TARGET", "a captured wild cannot be attacked")
		c.restart()
		local restored = assert(c.runtime.snapshot())
		assert(restored.grazer.capturedUntil == 15000, "captured state survives restart")
		c.now = 15
		assert(not Wildlife.captured(restored.grazer, c.now * 1000), "respawned once the window passes")
		assert(c.session.command("alice", c.request("grazer", "hit-back")).ok, "the respawned wild is a target again")
		assert(c.runtime.capture("hunter", "alice:c2", 1000) == nil, "an elapsed window is not applied")
		assert(c.read("wildlife:one").data.npcs.hunter.captureId == nil, "expired window left untouched")
	end,
	["pending intent survives expiry and unavailable owner blocks mutation"] = function()
		local c = fixture()
		local armed = false
		c.observe = function(key, _transform)
			if key == "combat:alice" and c.read("wildlife:one").data.actors.alice then
				c.observe = nil
				armed = true
				c.failAt = c.calls
			end
		end
		local req = c.request("hunter", "expire")
		assert(not c.session.command("alice", req).ok and armed, "intent accepted before failed charge")
		c.failAt = 0
		c.failAll = true
		local blocked = c.session.command("alice", {
			action = "survival-coop:inventory-split",
			args = { "bag", "spear", 1, "copy", 1 } :: { any },
			requestId = "blocked",
			sessionEpoch = 0,
		})
		assert(not blocked.ok, "unavailable combat owner cannot permit mutation")
		c.failAll = false
		c.now = 86401
		c.restart()
		local recovered = c.session.recoverTransfers("alice", 1)
		assert(recovered.ok and recovered.data.results[1].ok, "accepted expired intent finishes forward")
		check(c, true)
		assert(c.session.command("alice", req).reason == "REQUEST_EXPIRED", "expired replay cannot execute again")
	end,
	["staged ordinary command cannot overwrite a concurrent durable combat charge"] = function()
		local c = fixture()
		-- A second actual Session shares the personal CAS owner; it has no bridge
		-- so this test reaches the ordinary stage/commit boundary independently.
		local stale = Session.new(c.options, c.backend, {
			sessionId = "owner",
			lockTimeout = 120,
			retries = 0,
			now = function()
				return c.now
			end,
		}, {
			now = function()
				return c.now
			end,
			roll = function()
				return 0
			end,
			emit = function() end,
			encode = encode,
		}, c.durable)
		assert(stale.join("alice").ok, "second actual owner session")
		local original = assert(stale.personalTransfer("alice"), "actual personal owner")
		-- Reacquire Session A as current generation, then use that real port to
		-- commit a competing charge while Session A's ordinary candidate is staged.
		c.restart()
		local owner = c.session.personalTransfer("alice")
		local profile = owner.profile()
		local staged = false
		c.observe = function(key, _transform)
			if key ~= "combat:alice" or staged then
				return
			end
			-- Ordinary command first refreshes; its next write is the staged CAS.
			c.observe = function(nextKey, _nextTransform)
				if nextKey ~= "combat:alice" then
					return
				end
				c.observe = nil
				staged = true
				local envelope = serde.decode("json", encode(profile.data.envelope))
				local data = envelope.genres["survival-coop"].data
				data.inventory.bag.items.spear.durabilityMilli = 900
				data.inventory.bag.version += 1
				data.combat =
					{ version = 1, nextAttack = 2000, receipts = { barrier = { charged = true, binding = "barrier" } } }
				local committed = owner.personal:commit(profile, profile.data.stateRevision, envelope, nil)
				assert(committed, "competing combat CAS committed")
			end
		end
		-- The bridge preflight performs shared reads only; the two personal calls
		-- are refresh and the actual ordinary command commit.
		local result = c.session.command("alice", {
			action = "survival-coop:inventory-split",
			args = { "bag", "spear", 1, "copy", 1 } :: { any },
			requestId = "ordinary",
			sessionEpoch = 0,
		})
		assert(staged and not result.ok and result.reason == "STALE_PERSONAL_REVISION", "ordinary stage loses CAS")
		assert(
			c.read("combat:alice").data.envelope.genres["survival-coop"].data.inventory.bag.items.spear.durabilityMilli
				== 900,
			"charge not overwritten"
		)
		local staleWrite = original.personal:commit(
			original.profile(),
			original.profile().data.stateRevision,
			original.profile().data.envelope,
			nil
		)
		assert(not staleWrite, "old generation fenced")
	end,
	["personal charge CAS rejects competing inventory write then recovers once"] = function()
		local c = fixture()
		local actor = c.session.personalTransfer("alice")
		local fired = false
		c.observe = function(key, _transform)
			local source = c.read("wildlife:one").data
			if key == "combat:alice" and source.actors.alice and not fired then
				-- First personal call is refresh; intercept the next write after that.
				c.observe = function(nextKey, _nextTransform)
					if nextKey ~= "combat:alice" then
						return
					end
					c.observe = nil
					fired = true
					local lens = actor.personal:inventoryLens()
					local updated = lens:update(actor.profile(), function(data: Fenced.Data)
						data.inventory.items.spear.attributes.marker = true
						data.inventory.version += 1
						return data
					end)
					assert(updated, "competing actual personal lens mutation")
				end
			end
		end
		local result = c.session.command("alice", c.request("hunter", "cas"))
		assert(
			fired and not result.ok and result.reason == "STALE_PERSONAL_REVISION",
			"charge cannot overwrite lens CAS"
		)
		assert(c.session.command("alice", c.request("hunter", "cas")).ok, "same admission recovers without token debit")
		check(c, true)
		assert(
			c.read("combat:alice").data.envelope.genres["survival-coop"].data.inventory.bag.items.spear.attributes.marker,
			"competing field retained"
		)
	end,
	["pending charge fences stale ordinary Session command and concurrent lethal actor"] = function()
		local c = fixture()
		local fired = false
		c.observe = function(key, _transform)
			if key == "wildlife:one" and c.read("wildlife:one").data.actors.alice and not fired then
				fired = true
				c.observe = nil
				local competitor = c.session.command("bob", c.request("hunter", "other"))
				assert(not competitor.ok and competitor.reason == "SOURCE_BUSY", "same shared owner serialized")
				local other = c.session.command("alice", {
					action = "survival-coop:inventory-split",
					args = { "bag", "spear", 1, "copy", 0 } :: { any },
					requestId = "split",
					sessionEpoch = 0,
				})
				assert(not other.ok, "in-flight charge blocks ordinary mutation")
			end
		end
		assert(c.session.command("alice", c.request("hunter", "first")).ok, "accepted winner commits")
		assert(fired, "exact shared application barrier")
		check(c, true)
	end,
	["actual Session target-only admission replay cooldown and two actor lethal contention"] = function()
		local c = fixture()
		local bad = c.request("hunter", "bad")
		local forgedArgs: { any } = { "hunter", 100000 }
		bad.args = forgedArgs
		assert(not c.session.command("alice", bad).ok, "client damage rejected")
		bad = c.request("hunter", "bad")
		bad.actorId = "bob"
		assert(not c.session.command("alice", bad).ok, "forged actor rejected")
		local req = c.request("hunter", "hit")
		local first = c.session.command("alice", req)
		assert(first.ok and first.stateVersion, "committed actual Session result")
		for _ = 1, 20 do
			assert(encode(c.session.command("alice", req)) == encode(first), "replay before rate debit")
		end
		check(c, true)
		local other = c.session.command("bob", c.request("hunter", "compete"))
		assert(not other.ok and other.reason == "ALREADY_DEAD", "one lethal owner")
		assert(
			c.read("combat:bob").data.envelope.genres["survival-coop"].data.inventory.bag.items.spear.durabilityMilli
				== 1000,
			"loser uncharged"
		)
		local throttled = c.session.command("alice", c.request("grazer", "next"))
		assert(not throttled.ok, "one token capacity")
		c.now = 1
		c.session.advance(1)
		local cooldown = c.session.command("alice", c.request("grazer", "cooldown"))
		assert(not cooldown.ok and cooldown.reason == "COOLDOWN", "cooldown per actor across targets")
		c.restart()
		assert(encode(c.session.command("alice", req)) == encode(first), "durable restart replay")
		check(c, true)
	end,
	["every backend boundary recovers crash and lost ACK without duplicate charge or mint"] = function()
		local baseline = fixture()
		local start = baseline.calls
		local initial = baseline.session.command("alice", baseline.request("hunter", "hit"))
		assert(initial.ok, "baseline committed: " .. encode(initial))
		local calls = baseline.calls - start
		for _, lost in { false, true } do
			for offset = 1, calls do
				local c = fixture()
				c.failAt, c.lost = c.calls + offset, lost
				local ok = pcall(c.session.command, "alice", c.request("hunter", "hit"))
				assert(ok and c.hit, "exact failure boundary visited")
				c.failAt = 0
				c.restart()
				local result = c.session.command("alice", c.request("hunter", "hit"))
				assert(result.ok, "restart finishes offset " .. tostring(offset) .. " " .. tostring(result.reason))
				local recovered = c.session.recoverTransfers("alice", 1)
				assert(recovered.ok, "actual Session recovery")
				check(c, true)
			end
		end
	end,
}
if process.args[1] == "--run" then
	for name, test in specs do
		test()
		print("PASS " .. name)
	end
end
return specs
