--!strict
local serde = require("@lune/serde")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Fenced = require("../../../core/infra/data/FencedStore")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Job = require("../../../core/domain/crafting/Job")
local Content = require("../../../core/domain/survival/Content")
local TamingExtension = require("./TamingExtension")

local function content(): Content.Document
	local raw: any = {
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		tags = { "tool" },
		items = {
			{ id = "berry", name = "Berry", stackMax = 50, weightMilli = 100 },
			{
				id = "bola",
				name = "Bola",
				stackMax = 1,
				weightMilli = 100,
				maxDurabilityMilli = 100000,
				tags = { "tool" },
			},
		},
		wildlife = { { id = "strider", behavior = "herd-grazer" }, { id = "brute", behavior = "charger" } },
	}
	local doc, errors = Content.canonicalize(raw)
	return assert(doc, table.concat(errors or {}, "; "))
end

local function policy(): any
	return {
		version = 1,
		seed = 7,
		carriedContainer = "bag",
		captureTool = "bola",
		tameable = { "strider" },
		taming = {
			gaugeMax = 2,
			fillPerHit = 1,
			decayStepMillis = 100000,
			successPermille = 1000,
			toolWearMilli = 10000,
			penMillis = 60000,
			feedShortenMillis = { berry = 30000 },
		},
		mounts = {
			pvpSpeedCapStuds = 24,
			species = { strider = { rideable = true, rideSpeedStuds = 28, carryMilli = 9000 } },
		},
		maxWild = 4,
		maxAnimalsPerOwner = 4,
		maxReceipts = 16,
		reachStuds = 10,
		hitCooldownMillis = 0,
		wildRespawnMillis = 1000,
	}
end

type Rig = { extension: any, clock: { now: number }, bag: () -> any, failCommits: (number) -> (), backend: any }

local function build(existing: any?, captureWild: any?): Rig
	local doc = content()
	local items = Job.catalog(doc)
	local clock = { now = 0 }
	local bag = Inventory.new("bag", { slots = 10, softWeightMilli = 60000, hardWeightMilli = 90000 })
	bag = assert(Inventory.add(bag, items, {
		itemId = "tool-1",
		catalogId = "bola",
		quantity = 1,
		qualityMilli = 1000,
		durabilityMilli = 100000,
		attributes = {},
	}, bag.version))
	bag = assert(Inventory.add(bag, items, {
		itemId = "berry-1",
		catalogId = "berry",
		quantity = 5,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = {},
	}, bag.version))
	local envelope: any = { genres = { ["survival-coop"] = { data = { inventory = { bag = Inventory.save(bag) } } } } }
	local revision = 0
	local failures = 0
	local personal: any = {
		refresh = function(_self: any, profile: any): (any?, string?)
			return profile, nil
		end,
		commit = function(_self: any, _profile: any, expected: number, candidate: any): (any?, string?)
			if failures > 0 then
				failures -= 1
				return nil, "COMMIT_FAILED"
			end
			assert(expected == revision, "stale personal revision")
			envelope = candidate
			revision += 1
			return { data = { envelope = envelope, stateRevision = revision } }, nil
		end,
	}
	local access: any = {
		personal = personal,
		profile = function()
			return { data = { envelope = envelope, stateRevision = revision } }
		end,
		install = function() end,
	}
	local store = existing or Memory.new()
	local options = {
		sessionId = "taming",
		leaseSeconds = 120,
		now = function()
			return 0
		end,
		budget = {
			encode = function(value)
				return serde.encode("json", value)
			end,
		},
	}
	TamingExtension.configure(policy())
	local extension = assert(TamingExtension.factory({
		content = doc,
		store = function()
			return Fenced.new(store, options)
		end,
		now = function()
			return 0
		end,
		nowMillis = function()
			return clock.now
		end,
		members = function()
			return { "p1" }
		end,
		personalTransfer = function()
			return access
		end,
		captureWild = captureWild,
		wildlife = function(id: string): any?
			if id == "wild-1" then
				return { catalogId = "strider", healthMilli = 1000 }
			elseif id == "brute-1" then
				return { catalogId = "brute", healthMilli = 1000 }
			end
			return nil
		end,
	}))
	return {
		extension = extension,
		clock = clock,
		backend = store,
		bag = function()
			return envelope.genres["survival-coop"].data.inventory.bag
		end,
		failCommits = function(count)
			failures = count
		end,
	}
end

local function send(rig: Rig, requestId: string, name: string, args: { any }): any
	return rig.extension.command("p1", "survival-coop:" .. name, args, { requestId = requestId }, "client", function()
		return { ok = true }
	end)
end

local function tame(rig: Rig)
	assert(send(rig, "h1", "tame-hit", { "wild-1" }).ok, "first hit")
	assert(send(rig, "h2", "tame-hit", { "wild-1" }).ok, "second hit")
	local result = send(rig, "c1", "tame-capture", { "wild-1" })
	assert(result.ok and result.data.captured, "captured")
	return result.data.animalId :: string
end

return {
	["without a configured policy the factory stays disabled"] = function()
		TamingExtension.configure(nil)
		assert(TamingExtension.factory({}) == nil, "disabled")
	end,
	["only declared tame actions are handled"] = function()
		local rig = build()
		assert(rig.extension.handles("survival-coop:tame-hit"), "tame-hit")
		assert(not rig.extension.handles("survival-coop:attack"), "attack is not ours")
		assert(not rig.extension.handles("tame-hit"), "unqualified id")
	end,
	["a non-tameable or absent wild animal is refused and never rolls"] = function()
		local rig = build()
		assert(send(rig, "r1", "tame-hit", { "brute-1" }).reason == "NOT_TAMEABLE", "not tameable")
		assert(send(rig, "r2", "tame-hit", { "ghost" }).reason == "WILD_ABSENT", "absent")
		assert(send(rig, "r3", "tame-capture", { "wild-1" }).reason == "GAUGE_NOT_FULL", "gauge gate")
	end,
	["the snapshot publishes the stun gauge of the last target"] = function()
		local rig = build()
		assert(rig.extension.snapshot("p1").gauge == nil, "no target yet")
		send(rig, "h1", "tame-hit", { "wild-1" })
		local gauge = rig.extension.snapshot("p1").gauge
		assert(gauge.level == 1 and gauge.max == 2 and gauge.species == "strider", "gauge after one hit")
	end,
	["capture wears the tool exactly once even when the request is retried"] = function()
		local rig = build()
		local animalId = tame(rig)
		assert(rig.bag().items["tool-1"].durabilityMilli == 90000, "one wear")
		local again = send(rig, "c1", "tame-capture", { "wild-1" })
		assert(again.ok and again.data.animalId == animalId, "same outcome")
		assert(rig.bag().items["tool-1"].durabilityMilli == 90000, "retry does not wear twice")
		local snapshot = rig.extension.snapshot("p1")
		assert(#snapshot.animals == 1 and snapshot.animals[1].species == "strider", "one animal")
	end,
	["a lost charge is refused as pending then settled by recover without duplication"] = function()
		local rig = build()
		send(rig, "h1", "tame-hit", { "wild-1" })
		send(rig, "h2", "tame-hit", { "wild-1" })
		rig.failCommits(1)
		local pending = send(rig, "c1", "tame-capture", { "wild-1" })
		assert(not pending.ok and pending.reason == "CHARGE_PENDING", "charge pending")
		assert(rig.bag().items["tool-1"].durabilityMilli == 100000, "not yet charged")
		assert(rig.extension.recover("p1", 1).ok, "recover")
		assert(rig.bag().items["tool-1"].durabilityMilli == 90000, "charged once")
		assert(rig.extension.recover("p1", 1).data.status == "idle", "nothing left")
	end,
	["feeding consumes one item, shortens the pen and gates mounting"] = function()
		local rig = build()
		local animalId = tame(rig)
		local early = send(rig, "m0", "tame-mount", { animalId })
		assert(early.reason == "STILL_IN_PEN", "pen gate")
		assert(send(rig, "f1", "tame-feed", { animalId, "berry" }).ok, "feed")
		assert(rig.bag().items["berry-1"].quantity == 4, "one berry consumed")
		assert(send(rig, "f3", "tame-feed", { animalId, "grass" }).reason == "UNKNOWN_FEED", "unknown feed")
		assert(send(rig, "f2", "tame-feed", { animalId, "berry" }).ok, "feed again")
		assert(send(rig, "f4", "tame-feed", { animalId, "berry" }).reason == "ALREADY_READY", "no overfeed")
		rig.clock.now = 60000
		assert(send(rig, "m1", "tame-mount", { animalId }).ok, "mount")
		local snapshot = rig.extension.snapshot("p1")
		assert(snapshot.walkSpeedStuds == 28 and snapshot.ride.carryMilli == 9000, "server ride values")
		assert(send(rig, "d1", "tame-dismount", {}).ok, "dismount")
		assert(rig.extension.snapshot("p1").walkSpeedStuds == nil, "speed cleared")
		assert(send(rig, "d2", "tame-dismount", {}).reason == "NOT_MOUNTED", "second dismount refused")
	end,
	["capture releases the wild once with a fixed respawn window, even on replay and restart"] = function()
		local calls: { any } = {}
		local fail = 1
		local function captureWild(wildId: string, captureId: string, untilMillis: number): string?
			table.insert(calls, { wildId = wildId, captureId = captureId, untilMillis = untilMillis })
			if fail > 0 then
				fail -= 1
				return "WILD_BUSY"
			end
			return nil
		end
		local rig = build(nil, captureWild)
		rig.clock.now = 500
		send(rig, "h1", "tame-hit", { "wild-1" })
		send(rig, "h2", "tame-hit", { "wild-1" })
		local pending = send(rig, "c1", "tame-capture", { "wild-1" })
		assert(pending.reason == "CHARGE_PENDING" and #calls == 1, "transient release failure stays pending")
		rig.clock.now = 700
		local settled = send(rig, "c1", "tame-capture", { "wild-1" })
		assert(settled.ok and settled.data.captured, "retry settles")
		assert(#calls == 2, "release retried once")
		assert(calls[2].wildId == "wild-1" and calls[2].captureId == "p1:c1", "capture identity")
		assert(calls[1].untilMillis == 1500 and calls[2].untilMillis == 1500, "window fixed at commit time")
		assert(rig.bag().items["tool-1"].durabilityMilli == 90000, "tool worn once")
		assert(send(rig, "c1", "tame-capture", { "wild-1" }).ok and #calls == 2, "replay never re-releases")
		assert(rig.extension.close().ok, "release lease")
		local restarted = build(rig.backend, captureWild)
		assert(send(restarted, "c1", "tame-capture", { "wild-1" }).ok and #calls == 2, "restart replay is a no-op")
		assert(restarted.extension.recover("p1", 1).data.status == "idle", "nothing left to settle")
	end,
	["actor handoff drains capture charge and departed sweeps cannot reload animals"] = function()
		local rig = build()
		local animalId = tame(rig)
		assert(rig.extension.drain("p1").ok, "capture transactions drained")
		assert(rig.extension.releaseActor("p1").ok, "actor lease released")
		assert(rig.extension.releaseActor("p1").ok, "duplicate release")
		assert(rig.extension.recover("p1", 8).ok, "old sweep is idle")
		assert(rig.extension.snapshot("p1") == nil, "old snapshot cannot reacquire")
		assert(rig.extension.resumeActor("p1").ok, "origin resumes explicitly")
		local snapshot = rig.extension.snapshot("p1")
		assert(#snapshot.animals == 1 and snapshot.animals[1].id == animalId, "one animal identity conserved")
		assert(rig.bag().items["tool-1"].durabilityMilli == 90000, "capture consumption applied exactly once")
		assert(rig.extension.close().ok, "close")
	end,
	["pens and the ride survive a restart over the same backend"] = function()
		local rig = build()
		local animalId = tame(rig)
		rig.clock.now = 60000
		assert(send(rig, "m1", "tame-mount", { animalId }).ok, "mount")
		assert(rig.extension.close().ok, "release")
		local restarted = build(rig.backend)
		restarted.clock.now = 60000
		local snapshot = restarted.extension.snapshot("p1")
		assert(#snapshot.animals == 1 and snapshot.animals[1].id == animalId, "animal restored")
		assert(snapshot.walkSpeedStuds == 28, "ride restored")
		assert(send(restarted, "m1", "tame-mount", { animalId }).ok, "replayed receipt is idempotent")
	end,
}
