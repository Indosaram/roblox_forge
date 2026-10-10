--!strict
-- econsim: deterministic, engine-free economy simulator behind `forge econ sim`.
--
-- Everything here is a pure function of its inputs: no IO, no globals, and no
-- math.random. All randomness comes from a seeded 32-bit LCG, so the same
-- (config, players, days, seed) always produces identical results. Callers do
-- the YAML/JSON decoding and file writing; this module only computes and renders.
--
-- Model, per player and per simulated minute of play:
--   * sessions: 1-3 per day (seeded), each 10-40 minutes long
--   * income: 60 * coins/sec of the top `income.activeSlots` owned kaiju
--   * buy: while an incubator is free, buy the most expensive affordable egg;
--     its price is `eggs.*.price * (1 + pricing.growthPerOwned * ownedKaiju)`
--   * hatch: after hatchSeconds, draw a kaiju from the egg pool by weight
--   * siege: every 10 minutes of play, steal up to 10% of a rival's free-produced
--     Common value (Robux-sourced kaiju are never eligible)
-- A "first purchase moment" is the first >= 5-minute play block in which the
-- player cannot afford the cheapest egg it does not yet own.

local M = {}

-- 32-bit LCG (Numerical Recipes constants). state * MULTIPLIER + INCREMENT stays
-- below 2^53, so double arithmetic stays exact and the sequence is portable.
local MODULUS = 4294967296
local MULTIPLIER = 1664525
local INCREMENT = 1013904223

local SECONDS_PER_MINUTE = 60
local MINUTES_PER_DAY = 1440
local SIEGE_EVERY_PLAY_MINUTES = 10
local SIEGE_MAX_FRACTION = 0.10
local FIRST_PURCHASE_BLOCK_MINUTES = 5

export type Rng = { state: number }

export type EggPoolEntry = { id: string, weight: number }

export type EggDef = {
	id: string,
	displayName: string,
	price: number,
	hatchSeconds: number,
	pool: { EggPoolEntry },
}

export type KaijuDef = {
	id: string,
	rarity: string,
	coinsPerSecond: number,
}

export type OwnedKaiju = {
	id: string,
	rarity: string,
	coinsPerSecond: number,
	source: string, -- "free" for hatched kaiju, "robux" for purchased items
}

export type EconConfig = {
	currency: string,
	startingCoins: number,
	maxIncubators: number,
	pricing: { growthPerOwned: number },
	income: { activeSlots: number }, -- 0 means "no slot limit"
	eggs: { EggDef }, -- sorted by price ascending, then id
	eggById: { [string]: EggDef },
	kaiju: { KaijuDef }, -- document order
	kaijuById: { [string]: KaijuDef },
	cropCount: number,
}

export type SimOptions = { players: number, days: number, seed: number }

export type MonetizationEntry = { kind: string, name: string, price: number }

export type SimResult = {
	players: number,
	days: number,
	seed: number,
	hasEggLoop: boolean,
	startingSupply: number,
	dailySupply: { number },
	dailyInflation: { number },
	totalProduced: number,
	totalSpent: number,
	eggBuyCounts: { [string]: number },
	eggBuyers: { [string]: number },
	neverBoughtByMajority: { string },
	rarityTiers: { string },
	rarityOwners: { [string]: number },
	zeroOwnerRarities: { string },
	firstPurchaseMinutes: { number },
	playersWithFirstPurchase: number,
	medianFirstPurchaseMinute: number?,
	siegeCoinsTaken: number,
	siegeEvents: number,
	siegeShare: number,
}

type Session = { start: number, length: number }
type ActiveHatch = { eggId: string, readyAt: number }
type PlayerState = {
	index: number,
	coins: number,
	owned: { OwnedKaiju },
	active: { ActiveHatch },
	sessions: { Session },
	playMinutes: number,
	blockedPlayMinutes: number,
	-- Play-time minute (player.playMinutes at block start), not the absolute
	-- simulation minute: offline time between sessions must not count.
	blockStartedAt: number?,
	firstPurchaseMinute: number?,
	boughtEggs: { [string]: boolean },
}

local function asString(value: any, fallback: string): string
	if typeof(value) == "string" and value ~= "" then
		return value
	end
	if typeof(value) == "number" then
		return tostring(value)
	end
	return fallback
end

local function asNumber(value: any, fallback: number): number
	if typeof(value) == "number" then
		return value
	end
	return fallback
end

local function fmtInt(value: number): string
	return string.format("%.0f", value)
end

local function fmtMinute(value: number): string
	return string.format("%.1f min", value)
end

-- ---------------------------------------------------------------------------
-- Seeded PRNG
-- ---------------------------------------------------------------------------

--- Creates a PRNG state from a seed. Negative seeds are wrapped into the modulus.
function M.newRng(seed: number): Rng
	local normalized = seed % MODULUS
	if normalized < 0 then
		normalized += MODULUS
	end
	return { state = normalized }
end

--- Advances the generator and returns a float in [0, 1).
function M.nextUnit(rng: Rng): number
	rng.state = (MULTIPLIER * rng.state + INCREMENT) % MODULUS
	return rng.state / MODULUS
end

--- Returns a uniform integer in [min, max] inclusive.
function M.nextInt(rng: Rng, min: number, max: number): number
	return min + math.floor(M.nextUnit(rng) * (max - min + 1))
end

--- Draws an id from a weighted pool, or nil when the pool has no positive weight.
function M.pickWeighted(rng: Rng, pool: { EggPoolEntry }): string?
	local total = 0
	for _, entry in pool do
		total += entry.weight
	end
	if total <= 0 then
		return nil
	end
	local roll = M.nextUnit(rng) * total
	local cumulative = 0
	for _, entry in pool do
		cumulative += entry.weight
		if roll < cumulative then
			return entry.id
		end
	end
	return pool[#pool].id
end

-- ---------------------------------------------------------------------------
-- Config parsing
-- ---------------------------------------------------------------------------

-- Match codegen's sequence order, sorted mapping order, and key-to-ID fallback.
local function readEntries(value: any): { { key: any, value: any } }
	local entries: { { key: any, value: any } } = {}
	if typeof(value) ~= "table" then
		return entries
	end
	if value[1] ~= nil then
		for index = 1, #value do
			table.insert(entries, { key = index, value = value[index] })
		end
		return entries
	end
	local keys: { any } = {}
	for key in value do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	for _, key in keys do
		table.insert(entries, { key = key, value = value[key] })
	end
	return entries
end

local function entryId(entry: { key: any, value: any }): string
	local rawId = entry.value.id
	if rawId ~= nil and tostring(rawId) ~= "" then
		return tostring(rawId)
	end
	return tostring(entry.key)
end

--- Normalizes a decoded econ.yml document into an EconConfig. Missing sections
--- (for example a pack with no eggs/kaiju) parse to empty defaults instead of
--- failing, so a differently-shaped pack still yields a report.
function M.parseConfig(econ: any): EconConfig
	local currency = "Coins"
	local startingCoins = 0
	local maxIncubators = 0
	local eggs: { EggDef } = {}
	local eggById: { [string]: EggDef } = {}
	local kaiju: { KaijuDef } = {}
	local kaijuById: { [string]: KaijuDef } = {}
	local cropCount = 0
	local growthPerOwned = 0
	local activeSlots = 0

	if typeof(econ) ~= "table" then
		return {
			currency = currency,
			startingCoins = startingCoins,
			maxIncubators = maxIncubators,
			pricing = { growthPerOwned = growthPerOwned },
			income = { activeSlots = activeSlots },
			eggs = eggs,
			eggById = eggById,
			kaiju = kaiju,
			kaijuById = kaijuById,
			cropCount = cropCount,
		}
	end

	local currencies = readEntries(econ.currencies)
	if #currencies > 0 then
		local first = currencies[1].value
		if typeof(first) == "table" then
			currency = entryId(currencies[1])
			startingCoins = math.max(0, asNumber(first.starting, 0))
		end
	end

	local incubators = econ.incubators
	if typeof(incubators) == "table" then
		maxIncubators = math.max(0, math.floor(asNumber(incubators.max, 0)))
	end

	local pricing = econ.pricing
	if typeof(pricing) == "table" then
		growthPerOwned = math.max(0, asNumber(pricing.growthPerOwned, 0))
	end

	local income = econ.income
	if typeof(income) == "table" then
		local slots = asNumber(income.activeSlots, 0)
		if slots >= 1 then
			activeSlots = math.floor(slots)
		end
	end

	local rawKaiju = econ.kaiju
	if typeof(rawKaiju) == "table" then
		for _, item in readEntries(rawKaiju) do
			local entry = item.value
			if typeof(entry) == "table" then
				local id = entryId(item)
				if id ~= "" then
					local def: KaijuDef = {
						id = id,
						rarity = asString(entry.rarity, "Common"),
						coinsPerSecond = math.max(0, asNumber(entry.coinsPerSecond, 0)),
					}
					table.insert(kaiju, def)
					kaijuById[id] = def
				end
			end
		end
	end

	local rawEggs = econ.eggs
	if typeof(rawEggs) == "table" then
		for _, item in readEntries(rawEggs) do
			local entry = item.value
			if typeof(entry) == "table" then
				local id = entryId(item)
				if id ~= "" then
					local pool: { EggPoolEntry } = {}
					local rawPool = entry.pool
					if typeof(rawPool) == "table" then
						for _, poolItem in readEntries(rawPool) do
							local poolEntry = poolItem.value
							if typeof(poolEntry) == "table" then
								local poolId = entryId(poolItem)
								local weight = asNumber(poolEntry.weight, 0)
								if poolId ~= "" and weight > 0 then
									table.insert(pool, { id = poolId, weight = weight })
								end
							end
						end
					end
					local def: EggDef = {
						id = id,
						displayName = asString(entry.displayName, id),
						price = math.max(0, asNumber(entry.price, 0)),
						hatchSeconds = math.max(0, asNumber(entry.hatchSeconds, 0)),
						pool = pool,
					}
					table.insert(eggs, def)
					eggById[id] = def
				end
			end
		end
	end

	local crops = econ.crops
	if typeof(crops) == "table" then
		for _ in pairs(crops) do
			cropCount += 1
		end
	end

	table.sort(eggs, function(a, b)
		if a.price == b.price then
			return a.id < b.id
		end
		return a.price < b.price
	end)

	return {
		currency = currency,
		startingCoins = startingCoins,
		maxIncubators = maxIncubators,
		pricing = { growthPerOwned = growthPerOwned },
		income = { activeSlots = activeSlots },
		eggs = eggs,
		eggById = eggById,
		kaiju = kaiju,
		kaijuById = kaijuById,
		cropCount = cropCount,
	}
end

-- ---------------------------------------------------------------------------
-- Pure economy helpers
-- ---------------------------------------------------------------------------

--- Day-over-day supply inflation as a percentage. A non-positive previous supply
--- has no meaningful base, so it reports 0.
function M.inflationPercent(previous: number, current: number): number
	if previous <= 0 then
		return 0
	end
	return (current - previous) / previous * 100
end

--- Median of a list of numbers (nil when empty). Input order is not assumed.
function M.median(values: { number }): number?
	local count = #values
	if count == 0 then
		return nil
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	if count % 2 == 1 then
		return sorted[(count + 1) // 2]
	end
	return (sorted[count // 2] + sorted[count // 2 + 1]) / 2
end

--- Effective egg price for a buyer that already owns `ownedCount` kaiju.
function M.eggPrice(config: EconConfig, egg: EggDef, ownedCount: number): number
	return math.floor(egg.price * (1 + config.pricing.growthPerOwned * ownedCount))
end

--- Coins/sec produced by the top `income.activeSlots` owned kaiju: the same
--- slot rule the game loop applies. A cap < 1 means every kaiju earns.
function M.activeRate(config: EconConfig, owned: { OwnedKaiju }): number
	local rates: { number } = {}
	for _, kaiju in owned do
		table.insert(rates, kaiju.coinsPerSecond)
	end
	table.sort(rates, function(a, b)
		return a > b
	end)
	local slots = config.income.activeSlots
	local limit = if slots >= 1 then math.min(slots, #rates) else #rates
	local rate = 0
	for index = 1, limit do
		rate += rates[index]
	end
	return rate
end

--- Coins a rival produces per minute from free Common kaiju. Robux-sourced kaiju
--- and every non-Common rarity are excluded, so sieges never touch them.
function M.stealableCommonValue(owned: { OwnedKaiju }): number
	local cps = 0
	for _, kaiju in owned do
		if kaiju.rarity == "Common" and kaiju.source == "free" then
			cps += kaiju.coinsPerSecond
		end
	end
	return cps * SECONDS_PER_MINUTE
end

--- Coins a single siege takes from a victim: a random amount up to 10% of the
--- victim's free Common value, capped at the coins the victim actually holds.
function M.siegeAmount(rng: Rng, victim: { OwnedKaiju }, victimCoins: number): number
	local base = M.stealableCommonValue(victim)
	if base <= 0 or victimCoins <= 0 then
		return 0
	end
	local amount = math.floor(base * SIEGE_MAX_FRACTION * M.nextUnit(rng))
	return math.min(amount, math.floor(victimCoins))
end

-- ---------------------------------------------------------------------------
-- Simulation
-- ---------------------------------------------------------------------------

local function isOnline(sessions: { Session }, minute: number): boolean
	for _, session in sessions do
		if minute >= session.start and minute < session.start + session.length then
			return true
		end
	end
	return false
end

local function siegeInto(rng: Rng, states: { PlayerState }, attacker: PlayerState): number
	if #states < 2 then
		return 0
	end
	local offset = M.nextInt(rng, 1, #states - 1)
	local victimIndex = attacker.index + offset
	if victimIndex > #states then
		victimIndex -= #states
	end
	local victim = states[victimIndex]
	local amount = M.siegeAmount(rng, victim.owned, victim.coins)
	if amount > 0 then
		victim.coins -= amount
		attacker.coins += amount
	end
	return amount
end

--- Runs the agent-based simulation and returns the aggregate report data.
function M.simulate(config: EconConfig, options: SimOptions): SimResult
	local playerCount = math.max(1, math.floor(options.players))
	local days = math.max(1, math.floor(options.days))
	local rng = M.newRng(options.seed)

	local states: { PlayerState } = {}
	for index = 1, playerCount do
		local sessions: { Session } = {}
		for day = 0, days - 1 do
			local dayStart = day * MINUTES_PER_DAY
			local sessionCount = M.nextInt(rng, 1, 3)
			local offset = M.nextInt(rng, 0, 60)
			for _ = 1, sessionCount do
				local length = M.nextInt(rng, 10, 40)
				if offset + length > MINUTES_PER_DAY then
					break
				end
				table.insert(sessions, { start = dayStart + offset, length = length })
				offset += length + M.nextInt(rng, 5, 45)
			end
		end
		table.insert(states, {
			index = index,
			coins = config.startingCoins,
			owned = {},
			active = {},
			sessions = sessions,
			playMinutes = 0,
			blockedPlayMinutes = 0,
			blockStartedAt = nil,
			firstPurchaseMinute = nil,
			boughtEggs = {},
		})
	end

	local dailySupply: { number } = {}
	local eggBuyCounts: { [string]: number } = {}
	local eggBuyers: { [string]: number } = {}
	local totalProduced = 0
	local totalSpent = 0
	local siegeCoinsTaken = 0
	local siegeEvents = 0
	local producedToday = 0
	local maxMinute = days * MINUTES_PER_DAY

	for minute = 0, maxMinute - 1 do
		for _, player in states do
			if not isOnline(player.sessions, minute) then
				continue
			end
			player.playMinutes += 1

			local cps = M.activeRate(config, player.owned)
			local income = cps * SECONDS_PER_MINUTE
			player.coins += income
			totalProduced += income
			producedToday += income

			local stillActive: { ActiveHatch } = {}
			for _, hatch in player.active do
				if hatch.readyAt <= minute then
					local egg = config.eggById[hatch.eggId]
					if egg ~= nil then
						local kaijuId = M.pickWeighted(rng, egg.pool)
						if kaijuId ~= nil then
							local def = config.kaijuById[kaijuId]
							if def ~= nil then
								table.insert(player.owned, {
									id = def.id,
									rarity = def.rarity,
									coinsPerSecond = def.coinsPerSecond,
									source = "free",
								})
							end
						end
					end
				else
					table.insert(stillActive, hatch)
				end
			end
			player.active = stillActive

			while #player.active < config.maxIncubators do
				local chosen: EggDef? = nil
				for i = #config.eggs, 1, -1 do
					local egg = config.eggs[i]
					if M.eggPrice(config, egg, #player.owned) <= player.coins then
						chosen = egg
						break
					end
				end
				if chosen == nil then
					break
				end
				local price = M.eggPrice(config, chosen, #player.owned)
				player.coins -= price
				totalSpent += price
				table.insert(player.active, {
					eggId = chosen.id,
					readyAt = minute + chosen.hatchSeconds / SECONDS_PER_MINUTE,
				})
				eggBuyCounts[chosen.id] = (eggBuyCounts[chosen.id] or 0) + 1
				if not player.boughtEggs[chosen.id] then
					player.boughtEggs[chosen.id] = true
					eggBuyers[chosen.id] = (eggBuyers[chosen.id] or 0) + 1
				end
			end

			-- Track a >= 5-minute play block where the next egg stays unaffordable.
			local nextEggPrice: number? = nil
			for _, egg in config.eggs do
				if M.eggPrice(config, egg, #player.owned) > player.coins then
					nextEggPrice = M.eggPrice(config, egg, #player.owned)
					break
				end
			end
			if nextEggPrice ~= nil then
				if player.blockStartedAt == nil then
					player.blockStartedAt = player.playMinutes - 1
				end
				player.blockedPlayMinutes += 1
				if player.firstPurchaseMinute == nil and player.blockedPlayMinutes >= FIRST_PURCHASE_BLOCK_MINUTES then
					player.firstPurchaseMinute = player.blockStartedAt
				end
			else
				player.blockedPlayMinutes = 0
				player.blockStartedAt = nil
			end

			if player.playMinutes % SIEGE_EVERY_PLAY_MINUTES == 0 then
				siegeEvents += 1
				siegeCoinsTaken += siegeInto(rng, states, player)
			end
		end

		if (minute + 1) % MINUTES_PER_DAY == 0 then
			local supply = 0
			for _, player in states do
				supply += player.coins
			end
			table.insert(dailySupply, supply)
			producedToday = 0
		end
	end

	local startingSupply = config.startingCoins * playerCount
	local dailyInflation: { number } = {}
	local previousSupply = startingSupply
	for day = 1, days do
		local current = dailySupply[day]
		table.insert(dailyInflation, M.inflationPercent(previousSupply, current))
		previousSupply = current
	end

	local firstPurchaseMinutes: { number } = {}
	for _, player in states do
		local minute = player.firstPurchaseMinute
		if minute ~= nil then
			table.insert(firstPurchaseMinutes, minute)
		end
	end
	local medianFirstPurchaseMinute = M.median(firstPurchaseMinutes)

	local rarityTiers: { string } = {}
	local seenRarity: { [string]: boolean } = {}
	for _, def in config.kaiju do
		if not seenRarity[def.rarity] then
			seenRarity[def.rarity] = true
			table.insert(rarityTiers, def.rarity)
		end
	end
	table.sort(rarityTiers)

	local rarityOwners: { [string]: number } = {}
	for _, player in states do
		local ownedRarities: { [string]: boolean } = {}
		for _, owned in player.owned do
			if not ownedRarities[owned.rarity] then
				ownedRarities[owned.rarity] = true
				rarityOwners[owned.rarity] = (rarityOwners[owned.rarity] or 0) + 1
			end
		end
	end
	local zeroOwnerRarities: { string } = {}
	for _, rarity in rarityTiers do
		if rarityOwners[rarity] == nil then
			table.insert(zeroOwnerRarities, rarity)
		end
	end

	local neverBoughtByMajority: { string } = {}
	for _, egg in config.eggs do
		local buyers = eggBuyers[egg.id] or 0
		if buyers * 2 <= playerCount then
			table.insert(neverBoughtByMajority, egg.id)
		end
	end

	local totalSupplyEver = startingSupply + totalProduced
	local siegeShare = if totalSupplyEver > 0 then siegeCoinsTaken / totalSupplyEver else 0

	return {
		players = playerCount,
		days = days,
		seed = options.seed,
		hasEggLoop = #config.eggs > 0,
		startingSupply = startingSupply,
		dailySupply = dailySupply,
		dailyInflation = dailyInflation,
		totalProduced = totalProduced,
		totalSpent = totalSpent,
		eggBuyCounts = eggBuyCounts,
		eggBuyers = eggBuyers,
		neverBoughtByMajority = neverBoughtByMajority,
		rarityTiers = rarityTiers,
		rarityOwners = rarityOwners,
		zeroOwnerRarities = zeroOwnerRarities,
		firstPurchaseMinutes = firstPurchaseMinutes,
		playersWithFirstPurchase = #firstPurchaseMinutes,
		medianFirstPurchaseMinute = medianFirstPurchaseMinute,
		siegeCoinsTaken = siegeCoinsTaken,
		siegeEvents = siegeEvents,
		siegeShare = siegeShare,
	}
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Renders the markdown report for a completed simulation.
function M.renderReport(
	pack: string,
	config: EconConfig,
	options: SimOptions,
	monetization: { MonetizationEntry },
	result: SimResult
): string
	local lines: { string } = {}
	local function add(line: string)
		table.insert(lines, line)
	end

	add("# Economy simulation - " .. pack)
	add("")
	add(string.format("`forge econ sim` - seed %d, %d players, %d days.", options.seed, result.players, result.days))
	add("")
	add("## Configuration")
	add("")
	add(string.format("- Currency: %s (starting %s)", config.currency, fmtInt(config.startingCoins)))
	add(string.format("- Incubators per player: %d", config.maxIncubators))
	add(string.format("- Eggs: %d", #config.eggs))
	add(string.format("- Kaiju types: %d", #config.kaiju))
	if config.cropCount > 0 then
		add(string.format("- Crops (declared, not simulated): %d", config.cropCount))
	end
	add("")
	if #config.eggs > 0 then
		add("| Egg | Price | Hatch (s) |")
		add("| --- | ---: | ---: |")
		for _, egg in config.eggs do
			add(string.format("| %s | %s | %s |", egg.id, fmtInt(egg.price), fmtInt(egg.hatchSeconds)))
		end
		add("")
	end

	add("## Monetization")
	add("")
	if #monetization == 0 then
		add("No Robux products are declared in `game.yml`.")
	else
		add(
			"Robux products are deterministic and are never eligible for a team siege: sieges only move free-produced Common value."
		)
		add("")
		add("| Kind | Name | Robux |")
		add("| --- | --- | ---: |")
		for _, item in monetization do
			add(string.format("| %s | %s | %s |", item.kind, item.name, fmtInt(item.price)))
		end
	end
	add("")

	add("## Coin supply by day")
	add("")
	add("| Day | Supply | Inflation |")
	add("| ---: | ---: | ---: |")
	for day = 1, result.days do
		add(string.format("| %d | %s | %+.2f%% |", day, fmtInt(result.dailySupply[day]), result.dailyInflation[day]))
	end
	add("")
	add(
		string.format(
			"Total coins produced over the run: %s; spent on eggs: %s.",
			fmtInt(result.totalProduced),
			fmtInt(result.totalSpent)
		)
	)
	add("")

	add("## First purchase moment")
	add("")
	if result.medianFirstPurchaseMinute == nil then
		if result.hasEggLoop then
			add("No player hit a 5-minute affordability block on the next egg.")
		else
			add("Not applicable: this pack defines no egg loop.")
		end
	else
		add(
			string.format(
				"Median first-purchase minute: **%s** (%d of %d players were blocked >= 5 minutes on the next egg).",
				fmtMinute(result.medianFirstPurchaseMinute),
				result.playersWithFirstPurchase,
				result.players
			)
		)
	end
	add("")

	add("## Bottlenecks")
	add("")
	if #config.eggs == 0 then
		add("- No eggs are declared, so there is no egg bottleneck to report.")
	else
		if #result.neverBoughtByMajority == 0 then
			add("- Every egg was bought by more than 50% of players.")
		else
			add("- Eggs bought by <= 50% of players: " .. table.concat(result.neverBoughtByMajority, ", "))
		end
		add("")
		add("| Egg | Buyers | Total buys |")
		add("| --- | ---: | ---: |")
		for _, egg in config.eggs do
			add(
				string.format(
					"| %s | %d | %d |",
					egg.id,
					result.eggBuyers[egg.id] or 0,
					result.eggBuyCounts[egg.id] or 0
				)
			)
		end
	end
	add("")
	if #result.rarityTiers == 0 then
		add("- No kaiju rarities are declared.")
	elseif #result.zeroOwnerRarities == 0 then
		add("- Every rarity tier has at least one owner at the end.")
	else
		add("- Rarity tiers with zero owners at end: " .. table.concat(result.zeroOwnerRarities, ", "))
	end
	add("")

	add("## Team sieges")
	add("")
	add(
		string.format(
			"Siege events: %d. Coins taken by sieges: %s (%.2f%% of all coins ever in supply).",
			result.siegeEvents,
			fmtInt(result.siegeCoinsTaken),
			result.siegeShare * 100
		)
	)
	add("")

	return table.concat(lines, "\n") .. "\n"
end

--- One-line console summary of a completed simulation.
function M.summarize(pack: string, outPath: string, result: SimResult): string
	local lastSupply = result.dailySupply[#result.dailySupply] or 0
	local lastInflation = result.dailyInflation[#result.dailyInflation] or 0
	local median = if result.medianFirstPurchaseMinute ~= nil
		then string.format("%.1f min", result.medianFirstPurchaseMinute)
		else "none"
	return string.format(
		"econ sim %s: day %d supply %s (%+.2f%%), median first-purchase %s, siege share %.2f%%, bottlenecks %d eggs / %d rarities -> %s",
		pack,
		result.days,
		fmtInt(lastSupply),
		lastInflation,
		median,
		result.siegeShare * 100,
		#result.neverBoughtByMajority,
		#result.zeroOwnerRarities,
		outPath
	)
end

return M
