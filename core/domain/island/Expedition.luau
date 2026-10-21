--!strict
-- Expedition: route cards -> volatile expedition islands (plan §5.2, ADR-05).
--
-- An expedition island document is {templateId, seed, delta, expiresAt}.
-- The seed is derived through Rng: worldSeed -> fork("expedition") ->
-- fork(routeId .. "|" .. dayKey), so a route is stable within its rotation
-- window and changes when the window rotates. Time is always passed in.
--
-- Delta storage stays within 50% of the DataStore per-key limit
-- (4,194,304 chars, plan §11.2); larger deltas are sharded by zone. The
-- encoder is injected so this module stays engine-free (HttpService:JSONEncode
-- in Roblox, serde in Lune).

local Rng = require("../random/Rng")

local Expedition = {}

-- Facts are loaded by the server from the actor's current expedition, never
-- accepted from a travel remote or TeleportData.
function Expedition.admitStage(facts: any, now: number): (boolean, string?)
	if type(facts) ~= "table" then
		return false, "missing_expedition"
	end
	local levels = { 2, 35, 40, 50, 60 }
	local minimum = levels[facts.index]
	if minimum == nil then
		return false, "invalid_index"
	end
	if type(facts.level) ~= "number" or facts.level < minimum then
		return false, "level_gate"
	end
	if type(facts.developmentGrade) ~= "number" or facts.developmentGrade < facts.index * 2 then
		return false, "development_gate"
	end
	if type(facts.expiresAt) ~= "number" or now >= facts.expiresAt then
		return false, "route_expired"
	end
	if type(facts.stage) ~= "number" or facts.stage < 1 or facts.stage > 4 or facts.stage % 1 ~= 0 then
		return false, "invalid_stage"
	end
	if facts.stage > 1 and (facts.completedStage ~= facts.stage - 1 or facts.completedObjectives ~= 2) then
		return false, "mission_gate"
	end
	return true, nil
end

Expedition.DEFAULT_TTL_SECONDS = 24 * 60 * 60 -- ADR-05: 24 h rotation
Expedition.DATASTORE_KEY_LIMIT = 4194304
Expedition.DELTA_BUDGET = Expedition.DATASTORE_KEY_LIMIT // 2

export type RouteCard = { routeId: string, templateId: string }
export type Island = {
	routeId: string,
	templateId: string,
	seed: number,
	delta: { [string]: any },
	expiresAt: number,
}
export type Shard = { zones: { string }, delta: { [string]: any }, size: number }
export type ShardPlan = { sharded: boolean, shards: { Shard } }
export type Encoder = (value: any) -> string

local function checkTime(value: any, label: string): ()
	if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
		error("invalid " .. label)
	end
end

local function checkTtl(ttl: number?): number
	local value = ttl or Expedition.DEFAULT_TTL_SECONDS
	if type(value) ~= "number" or value <= 0 or value ~= math.floor(value) then
		error("invalid ttl")
	end
	return value
end

local function checkCard(card: any): ()
	if type(card) ~= "table" then
		error("invalid route card")
	end
	if type(card.routeId) ~= "string" or #card.routeId == 0 then
		error("invalid route id")
	end
	if type(card.templateId) ~= "string" or #card.templateId == 0 then
		error("invalid template id")
	end
end

-- Rotation window index for `now` (whole windows since epoch 0).
function Expedition.dayKey(now: number, ttl: number?): number
	checkTime(now, "now")
	return math.floor(now / checkTtl(ttl))
end

function Expedition.seedFor(worldSeed: number, routeId: string, dayKey: number): number
	if type(routeId) ~= "string" or #routeId == 0 then
		error("invalid route id")
	end
	return Rng.new(worldSeed):fork("expedition"):fork(routeId .. "|" .. tostring(dayKey)):nextU32()
end

-- Opens (or re-derives) the island for a route card at `now`. The island
-- expires at the end of the current rotation window.
function Expedition.open(card: RouteCard, worldSeed: number, now: number, ttl: number?): Island
	checkCard(card)
	local window = checkTtl(ttl)
	local day = Expedition.dayKey(now, window)
	return {
		routeId = card.routeId,
		templateId = card.templateId,
		seed = Expedition.seedFor(worldSeed, card.routeId, day),
		delta = {},
		expiresAt = (day + 1) * window,
	}
end

function Expedition.isExpired(island: Island, now: number): boolean
	checkTime(now, "now")
	return now >= island.expiresAt
end

-- Admission check for travelling to an expedition island. Returns
-- (true, nil) or (false, "route_expired"); the code maps to a player message.
function Expedition.canEnter(island: Island, now: number): (boolean, string?)
	if Expedition.isExpired(island, now) then
		return false, "route_expired"
	end
	return true, nil
end

-- Splits a zone-keyed delta into shards that each encode within `budget`
-- (default 50% of the key limit). Zones are packed greedily in sorted order so
-- the layout is deterministic. A single zone larger than the budget cannot be
-- stored and raises "zone over budget".
function Expedition.shardDelta(delta: { [string]: any }, encode: Encoder, budget: number?): ShardPlan
	if type(delta) ~= "table" then
		error("invalid delta")
	end
	if type(encode) ~= "function" then
		error("invalid encoder")
	end
	local limit = budget or Expedition.DELTA_BUDGET
	if type(limit) ~= "number" or limit <= 0 then
		error("invalid budget")
	end
	local whole = #encode(delta)
	if whole <= limit then
		local zones = {}
		for zone in delta do
			if type(zone) ~= "string" then
				error("invalid zone id")
			end
			table.insert(zones, zone)
		end
		table.sort(zones)
		return { sharded = false, shards = { { zones = zones, delta = delta, size = whole } } }
	end

	local zones: { string } = {}
	for zone in delta do
		if type(zone) ~= "string" then
			error("invalid zone id")
		end
		table.insert(zones, zone)
	end
	table.sort(zones)

	local shards: { Shard } = {}
	local current: Shard? = nil
	for _, zone in zones do
		if #encode({ [zone] = delta[zone] }) > limit then
			error("zone over budget: " .. zone)
		end
		if current then
			local candidate = table.clone(current.delta)
			candidate[zone] = delta[zone]
			local size = #encode(candidate)
			if size <= limit then
				table.insert(current.zones, zone)
				current.delta = candidate
				current.size = size
				continue
			end
		end
		local single = { [zone] = delta[zone] }
		current = { zones = { zone }, delta = single, size = #encode(single) }
		table.insert(shards, current :: Shard)
	end
	return { sharded = true, shards = shards }
end

return Expedition
