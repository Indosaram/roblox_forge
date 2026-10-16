--!strict
local TamingRuntime = require("./TamingRuntime")
local Mounts = require("./Mounts")
local Taming = require("../../../core/domain/taming/Taming")
local Content = require("../../../core/domain/survival/Content")

local function content(): Content.Document
	local raw: any = {
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		items = { { id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 } },
		wildlife = {
			{ id = "drover", behavior = "herd-grazer" },
			{ id = "stag", behavior = "herd-grazer" },
			{ id = "crest", behavior = "charger" },
		},
	}
	local doc, errors = Content.canonicalize(raw)
	assert(doc, table.concat(errors or {}, "; "))
	return doc
end

local function build(overrides: { [string]: any }?, rate: number?): (TamingRuntime.Runtime, { now: number })
	local doc = content()
	local clock = { now = 0 }
	local tamingConfig = Taming.config({
		gaugeMax = 100,
		fillPerHit = 50,
		decayStepMillis = 1000,
		successPermille = rate or 500,
		toolWearMilli = 100,
		penMillis = 60000,
		feedShortenMillis = { berry = 20000 },
	})
	local mounts = Mounts.catalog(doc, {
		pvpSpeedCapStuds = 24,
		species = {
			drover = { rideable = true, rideSpeedStuds = 20, carryMilli = 8000 },
			stag = { rideable = true, rideSpeedStuds = 40, carryMilli = 5000 },
			crest = { rideable = false, rideSpeedStuds = 0, carryMilli = 0 },
		},
		skins = {
			["drover-gold"] = { species = "drover", paid = true },
			["stag-neon"] = { species = "stag", paid = true },
		},
	})
	local config: any = {
		taming = tamingConfig,
		mounts = mounts,
		content = doc,
		tameable = { "drover", "stag", "crest" },
		seed = 4242,
		now = function()
			return clock.now
		end,
		maxWild = 32,
		maxAnimalsPerOwner = 8,
		maxReceipts = 64,
	}
	if overrides then
		for key, value in overrides do
			config[key] = value
		end
	end
	return TamingRuntime.new(config), clock
end

local function animalOf(result: TamingRuntime.CaptureResult): string
	local animalId = result.animalId
	assert(animalId ~= nil, "capture produced an animal")
	return animalId
end

local function fill(runtime: TamingRuntime.Runtime, wildId: string)
	runtime.hit(wildId, 2)
end

return {
	["capture refused until the wild gauge is full, then rolls and wears the tool"] = function()
		local runtime = build()
		assert(runtime.spawnWild("w1", "drover") == nil, "spawned")
		runtime.hit("w1")
		local early = runtime.capture("alice", "r1", "w1", { durabilityMilli = 1000 })
		assert(
			not early.ok and early.reason == "GAUGE_NOT_FULL" and early.tool.durabilityMilli == 1000,
			"refused, nothing consumed"
		)
		runtime.hit("w1")
		assert(runtime.gaugeLevel("w1") == 100, "full after two hits")
		local tried = runtime.capture("alice", "r2", "w1", { durabilityMilli = 1000 })
		assert(tried.ok and tried.tool.durabilityMilli == 900 and not tried.fled, "rolled, tool wore, no flee")
	end,
	["a failed capture keeps the animal in a retry state and never flees"] = function()
		local runtime = build(nil, 0)
		runtime.spawnWild("w1", "drover")
		fill(runtime, "w1")
		local tool = { durabilityMilli = 300 }
		for attempt = 1, 3 do
			local result = runtime.capture("alice", "r" .. attempt, "w1", tool)
			assert(result.ok and not result.captured and result.retry and not result.fled, "retry state")
			tool = result.tool
		end
		assert(
			tool.durabilityMilli == 0 and runtime.wildCount() == 1 and runtime.gaugeLevel("w1") == 100,
			"animal remains, gauge full"
		)
		local broken = runtime.capture("alice", "r4", "w1", tool)
		assert(
			not broken.ok and broken.reason == "TOOL_BROKEN" and runtime.wildCount() == 1,
			"broken tool refuses, animal stays"
		)
	end,
	["success creates an owned penned animal and removes the wild one"] = function()
		local runtime, clock = build(nil, 1000)
		runtime.spawnWild("w1", "drover")
		fill(runtime, "w1")
		clock.now = 500
		local result = runtime.capture("alice", "r1", "w1", { durabilityMilli = 1000 })
		assert(
			result.captured and result.animalId ~= nil and runtime.wildCount() == 0,
			"captured and gone from the wild"
		)
		local animal = assert(runtime.animal(result.animalId :: string))
		assert(
			animal.owner == "alice" and animal.species == "drover" and animal.pen.readyAt == 60500,
			"owned with a pen timer"
		)
		assert(runtime.gaugeLevel("w1") == nil, "wild record is gone")
		local again = runtime.capture("alice", "r9", "w1", { durabilityMilli = 1000 })
		assert(not again.ok and again.reason == "UNKNOWN_WILD", "cannot capture twice")
	end,
	["a retried request id replays the stored result without rolling or wearing again"] = function()
		local runtime = build(nil, 0)
		runtime.spawnWild("w1", "drover")
		fill(runtime, "w1")
		local first = runtime.capture("alice", "r1", "w1", { durabilityMilli = 1000 })
		local replay = runtime.capture("alice", "r1", "w1", { durabilityMilli = 1000 })
		assert(
			first.tool.durabilityMilli == 900 and replay.tool.durabilityMilli == 900,
			"stored result, tool not worn twice"
		)
		replay.tool.durabilityMilli = 1
		assert(
			runtime.capture("alice", "r1", "w1", { durabilityMilli = 1000 }).tool.durabilityMilli == 900,
			"stored result not aliased"
		)
		local other = runtime.capture("bob", "r1", "w1", { durabilityMilli = 1000 })
		assert(other.ok and other.tool.durabilityMilli == 900, "request ids are per actor")
	end,
	["same seed and events reproduce every capture outcome (QA-TAME-01 replay)"] = function()
		local function run(): string
			local runtime, clock = build()
			local out = {}
			for index = 1, 24 do
				local wild = "w" .. index
				runtime.spawnWild(wild, "drover")
				fill(runtime, wild)
				clock.now += 10
				local result = runtime.capture("alice", "r" .. index, wild, { durabilityMilli = 1000 })
				table.insert(out, if result.captured then "1" else "0")
				runtime.despawnWild(wild)
				if result.animalId then
					runtime.dismount("alice")
				end
				if index % 7 == 0 then
					-- keep the owner under the pen limit so every roll is reached
					break
				end
			end
			return table.concat(out)
		end
		assert(run() == run(), "MATCH")
		local a = build({ seed = 1 })
		local b = build({ seed = 2 })
		local differs = false
		for index = 1, 40 do
			for _, runtime in { a, b } do
				runtime.spawnWild("x" .. index, "stag")
				fill(runtime, "x" .. index)
			end
			local ra = a.capture("u" .. index, "r", "x" .. index, { durabilityMilli = 1000 })
			local rb = b.capture("u" .. index, "r", "x" .. index, { durabilityMilli = 1000 })
			if ra.captured ~= rb.captured then
				differs = true
			end
		end
		assert(differs, "different seeds diverge")
	end,
	["the ride is gated by pen time and ownership, and feed shortens it deterministically"] = function()
		local runtime, clock = build(nil, 1000)
		runtime.spawnWild("w1", "drover")
		fill(runtime, "w1")
		local animalId = animalOf(runtime.capture("alice", "r1", "w1", { durabilityMilli = 1000 }))
		local _, early = runtime.mount("alice", animalId, nil, { pvp = false })
		assert(early == "STILL_IN_PEN", "not ready yet")
		local pen = assert(runtime.feed("alice", animalId, "berry"))
		assert(pen.readyAt == 40000, "berry removes 20s")
		local _, stranger = runtime.mount("bob", animalId, nil, { pvp = false })
		assert(stranger == "NOT_OWNER", "only the owner rides")
		assert(select(2, runtime.feed("bob", animalId, "berry")) == "NOT_OWNER", "only the owner feeds")
		assert(select(2, runtime.feed("alice", animalId, "gold")) == "UNKNOWN_FEED", "unknown feed refused")
		clock.now = 39999
		assert(select(2, runtime.mount("alice", animalId, nil, { pvp = false })) == "STILL_IN_PEN", "one ms early")
		clock.now = 40000
		assert(runtime.mount("alice", animalId, nil, { pvp = false }) ~= nil, "ready on the boundary")
	end,
	["server-recorded ride speed and carry match for paid skins in every zone and clamp in PvP"] = function()
		local runtime, clock = build(nil, 1000)
		local ids: { [string]: string } = {}
		for _, species in { "drover", "stag" } do
			runtime.spawnWild("w-" .. species, species)
			fill(runtime, "w-" .. species)
			ids[species] =
				animalOf(runtime.capture("alice", "r-" .. species, "w-" .. species, { durabilityMilli = 1000 }))
		end
		clock.now = 100000
		for _, zone in { { pvp = false }, { pvp = true } } do
			local skinOf: { [string]: string } = { drover = "drover-gold", stag = "stag-neon" }
			for species, skin in skinOf do
				local free = assert(runtime.mount("alice", ids[species], nil, zone))
				local paid = assert(runtime.mount("alice", ids[species], skin, zone))
				assert(
					free.speedStuds == paid.speedStuds and free.carryMilli == paid.carryMilli,
					`{species} pvp={zone.pvp}`
				)
				assert((runtime.recorded("alice") or { skin = "" }).skin == skin, "recorded appearance")
				assert(
					runtime.carryCapacity("alice", 10000) == 10000 + paid.carryMilli,
					"capacity adds species carry only"
				)
			end
		end
		local fast = assert(runtime.mount("alice", ids.stag, "stag-neon", { pvp = true }))
		assert(fast.speedStuds == 24, "PvP clamp applies to the paid mount")
		local safe = assert(runtime.rezone("alice", { pvp = false }))
		assert(safe.speedStuds == 40 and safe.carryMilli == 5000, "leaving PvP restores the species speed")
		local back = assert(runtime.rezone("alice", { pvp = true }))
		assert(back.speedStuds == 24, "entering PvP clamps the active ride")
		runtime.dismount("alice")
		assert(runtime.recorded("alice") == nil and runtime.carryCapacity("alice", 10000) == 10000, "dismounted")
		assert(runtime.rezone("alice", { pvp = true }) == nil, "nothing to rezone")
	end,
	["an unrideable captured species cannot be mounted and unknown skins are refused"] = function()
		local runtime, clock = build(nil, 1000)
		runtime.spawnWild("w1", "crest")
		fill(runtime, "w1")
		local crest = animalOf(runtime.capture("alice", "r1", "w1", { durabilityMilli = 1000 }))
		runtime.spawnWild("w2", "drover")
		fill(runtime, "w2")
		local drover = animalOf(runtime.capture("alice", "r2", "w2", { durabilityMilli = 1000 }))
		clock.now = 100000
		assert(select(2, runtime.mount("alice", crest, nil, { pvp = false })) == "NOT_RIDEABLE", "species flag refuses")
		assert(
			select(2, runtime.mount("alice", drover, "stag-neon", { pvp = false })) == "SKIN_SPECIES_MISMATCH",
			"wrong skin"
		)
		assert(select(2, runtime.mount("alice", drover, "ghost", { pvp = false })) == "UNKNOWN_SKIN", "unknown skin")
		assert(runtime.recorded("alice") == nil, "refusals record no ride")
	end,
	["limits: wild budget, tameable species and per owner pen size"] = function()
		local runtime = build({ maxWild = 2, maxAnimalsPerOwner = 1 }, 1000)
		assert(runtime.spawnWild("a", "drover") == nil and runtime.spawnWild("b", "drover") == nil, "two fit")
		assert(runtime.spawnWild("c", "drover") == "WILD_LIMIT", "third refused")
		assert(runtime.spawnWild("a", "drover") == "ALREADY_SPAWNED", "duplicate id refused")
		assert(runtime.spawnWild("d", "ghost") == "NOT_TAMEABLE", "unknown species refused")
		fill(runtime, "a")
		fill(runtime, "b")
		assert(runtime.capture("alice", "r1", "a", { durabilityMilli = 1000 }).captured, "first capture")
		local full = runtime.capture("alice", "r2", "b", { durabilityMilli = 1000 })
		assert(
			not full.ok and full.reason == "PEN_FULL" and full.tool.durabilityMilli == 1000,
			"pen full costs nothing"
		)
		assert(not pcall(build, { tameable = { "ghost" } }), "tameable species must exist in content")
		assert(not pcall(build, { maxWild = 33 }), "wild budget above 32 refused")
	end,
}
