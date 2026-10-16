--!strict
-- TamingRuntime: server-authoritative wild gauge, capture, pen and ride state.
--
-- Composes the pure Taming rules and Mounts catalog behind one owner. Time is
-- the injected `now` clock (integer milliseconds); randomness is one recorded
-- seed, forked per wild animal and then labelled "capture" inside Taming, so a
-- replay of the same seed and event order reproduces every outcome. Nothing
-- here accepts an entitlement: a paid skin is only an appearance id handed to
-- Mounts, which resolves speed and carry from the species alone.
--
-- Capture is idempotent by (actor, requestId): a retried request returns the
-- stored result without rolling again or wearing the tool twice.
local Taming = require("../../../core/domain/taming/Taming")
local Rng = require("../../../core/domain/random/Rng")
local Content = require("../../../core/domain/survival/Content")
local Mounts = require("./Mounts")
local M = {}

export type Config = {
	taming: Taming.Config,
	mounts: Mounts.Catalog,
	content: Content.Document,
	-- Species that may be captured (must exist in content.wildlife).
	tameable: { string },
	seed: number,
	now: () -> number,
	maxWild: number,
	maxAnimalsPerOwner: number,
	maxReceipts: number,
}
export type Tool = Taming.Tool
export type Owned = { id: string, species: string, owner: string, pen: Taming.Pen }
export type CaptureResult = {
	ok: boolean,
	reason: string?,
	captured: boolean,
	fled: boolean,
	retry: boolean,
	tool: Tool,
	animalId: string?,
}
export type Recorded = {
	animalId: string,
	species: string,
	skin: string?,
	speedStuds: number,
	carryMilli: number,
	pvp: boolean,
}
export type Runtime = {
	spawnWild: (wildId: string, species: string) -> string?,
	despawnWild: (wildId: string) -> (),
	hit: (wildId: string, hits: number?) -> (number?, string?),
	gaugeLevel: (wildId: string) -> number?,
	capture: (actorId: string, requestId: string, wildId: string, tool: Tool) -> CaptureResult,
	feed: (actorId: string, animalId: string, feedId: string) -> (Taming.Pen?, string?),
	animal: (animalId: string) -> Owned?,
	mount: (actorId: string, animalId: string, skin: string?, zone: Mounts.Zone) -> (Recorded?, string?),
	rezone: (actorId: string, zone: Mounts.Zone) -> Recorded?,
	dismount: (actorId: string) -> (),
	recorded: (actorId: string) -> Recorded?,
	carryCapacity: (actorId: string, baseMilli: number) -> number,
	wildCount: () -> number,
}

type Wild = { species: string, gauge: Taming.Gauge, rng: Rng.Rng }

local function id(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 64
end

local function integer(n: any, low: number, high: number): boolean
	return type(n) == "number" and n == n and n % 1 == 0 and n >= low and n <= high
end

function M.new(config: Config): Runtime
	assert(integer(config.maxWild, 1, 32), "INVALID_WILD_LIMIT")
	assert(integer(config.maxAnimalsPerOwner, 1, 64), "INVALID_OWNER_LIMIT")
	assert(integer(config.maxReceipts, 1, 4096), "INVALID_RECEIPT_LIMIT")
	assert(type(config.now) == "function", "INVALID_CLOCK")
	local known: { [string]: boolean } = {}
	for _, entry in config.content.wildlife do
		known[entry.id] = true
	end
	local tameable: { [string]: boolean } = {}
	for _, species in config.tameable do
		assert(known[species], "UNKNOWN_SPECIES")
		tameable[species] = true
	end
	local root = Rng.new(config.seed)
	local wilds: { [string]: Wild } = {}
	local wildCount = 0
	local animals: { [string]: Owned } = {}
	local owned: { [string]: number } = {}
	local rides: { [string]: Recorded? } = {}
	local receipts: { [string]: CaptureResult } = {}
	local receiptOrder: { string } = {}
	local serial = 0

	local function clock(): number
		local now = config.now()
		assert(integer(now, 0, 2 ^ 53 - 1), "INVALID_CLOCK")
		return now
	end

	local function remember(key: string, result: CaptureResult)
		receipts[key] = result
		table.insert(receiptOrder, key)
		if #receiptOrder > config.maxReceipts then
			receipts[table.remove(receiptOrder, 1) :: string] = nil
		end
	end

	local function copyResult(result: CaptureResult): CaptureResult
		local copy = table.clone(result)
		copy.tool = table.clone(result.tool)
		return copy
	end

	local runtime = {} :: Runtime

	function runtime.spawnWild(wildId: string, species: string): string?
		if not id(wildId) or not tameable[species] then
			return "NOT_TAMEABLE"
		end
		if wilds[wildId] then
			return "ALREADY_SPAWNED"
		end
		if wildCount >= config.maxWild then
			return "WILD_LIMIT"
		end
		wilds[wildId] = {
			species = species,
			gauge = Taming.newGauge(clock()),
			rng = root:fork("wild:" .. wildId),
		}
		wildCount += 1
		return nil
	end

	function runtime.despawnWild(wildId: string)
		if wilds[wildId] then
			wilds[wildId] = nil
			wildCount -= 1
		end
	end

	function runtime.hit(wildId: string, hits: number?): (number?, string?)
		local wild = wilds[wildId]
		if not wild then
			return nil, "UNKNOWN_WILD"
		end
		wild.gauge = Taming.hit(config.taming, wild.gauge, clock(), hits)
		return wild.gauge.level, nil
	end

	function runtime.gaugeLevel(wildId: string): number?
		local wild = wilds[wildId]
		return if wild then Taming.level(config.taming, wild.gauge, clock()) else nil
	end

	function runtime.capture(actorId: string, requestId: string, wildId: string, tool: Tool): CaptureResult
		local refused = function(reason: string): CaptureResult
			return {
				ok = false,
				reason = reason,
				captured = false,
				fled = false,
				retry = false,
				tool = table.clone(tool),
				animalId = nil,
			}
		end
		if not id(actorId) or not id(requestId) then
			return refused("INVALID_REQUEST")
		end
		local key = actorId .. "\0" .. requestId
		local prior = receipts[key]
		if prior then
			return copyResult(prior)
		end
		local wild = wilds[wildId]
		if not wild then
			return refused("UNKNOWN_WILD")
		end
		if (owned[actorId] or 0) >= config.maxAnimalsPerOwner then
			return refused("PEN_FULL")
		end
		local now = clock()
		local attempt = Taming.capture(config.taming, wild.gauge, now, wild.rng, tool)
		wild.gauge = attempt.gauge
		local result: CaptureResult = {
			ok = attempt.ok,
			reason = attempt.reason,
			captured = attempt.captured,
			fled = false,
			retry = attempt.retry,
			tool = attempt.tool,
			animalId = nil,
		}
		if attempt.captured then
			serial += 1
			local animalId = actorId .. ":" .. tostring(serial)
			animals[animalId] =
				{ id = animalId, species = wild.species, owner = actorId, pen = Taming.pen(config.taming, now) }
			owned[actorId] = (owned[actorId] or 0) + 1
			result.animalId = animalId
			runtime.despawnWild(wildId)
		end
		-- A refusal before the roll (gauge not full, broken tool) is not stored:
		-- nothing was consumed, so the same request id may be retried later.
		if attempt.ok then
			remember(key, result)
		end
		return copyResult(result)
	end

	function runtime.feed(actorId: string, animalId: string, feedId: string): (Taming.Pen?, string?)
		local animal = animals[animalId]
		if not animal or animal.owner ~= actorId then
			return nil, "NOT_OWNER"
		end
		if config.taming.feedShortenMillis[feedId] == nil then
			return nil, "UNKNOWN_FEED"
		end
		animal.pen = Taming.feed(config.taming, animal.pen, clock(), feedId)
		return table.clone(animal.pen), nil
	end

	function runtime.animal(animalId: string): Owned?
		local animal = animals[animalId]
		if not animal then
			return nil
		end
		local copy = table.clone(animal)
		copy.pen = table.clone(animal.pen)
		return copy
	end

	local function record(animal: Owned, skin: string?, zone: Mounts.Zone): (Recorded?, string?)
		local ride, reason = Mounts.resolve(config.mounts, animal.species, skin, zone)
		if not ride then
			return nil, reason
		end
		return {
			animalId = animal.id,
			species = animal.species,
			skin = skin,
			speedStuds = ride.speedStuds,
			carryMilli = ride.carryMilli,
			pvp = zone.pvp,
		},
			nil
	end

	function runtime.mount(actorId: string, animalId: string, skin: string?, zone: Mounts.Zone): (Recorded?, string?)
		local animal = animals[animalId]
		if not animal or animal.owner ~= actorId then
			return nil, "NOT_OWNER"
		end
		if not Taming.isReady(animal.pen, clock()) then
			return nil, "STILL_IN_PEN"
		end
		local recorded, reason = record(animal, skin, zone)
		if not recorded then
			return nil, reason
		end
		rides[actorId] = recorded
		return table.clone(recorded), nil
	end

	--- Re-resolves the active ride after the rider crosses a zone boundary.
	function runtime.rezone(actorId: string, zone: Mounts.Zone): Recorded?
		local current = rides[actorId]
		if not current then
			return nil
		end
		local recorded = record(animals[current.animalId], current.skin, zone)
		rides[actorId] = recorded
		return if recorded then table.clone(recorded) else nil
	end

	function runtime.dismount(actorId: string)
		rides[actorId] = nil
	end

	function runtime.recorded(actorId: string): Recorded?
		local ride = rides[actorId]
		return if ride then table.clone(ride) else nil
	end

	function runtime.carryCapacity(actorId: string, baseMilli: number): number
		local ride = rides[actorId]
		return baseMilli + (if ride then ride.carryMilli else 0)
	end

	function runtime.wildCount(): number
		return wildCount
	end

	return runtime
end

return M
