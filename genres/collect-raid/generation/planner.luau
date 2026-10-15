--!strict
-- planner: the pure engine behind `forge plan`. Given a concept, a genre template
-- (the parametric `plan:` block from genres/<genre>/econ-template.yml) and a seed,
-- it derives a title, a creature/egg roster, a full economy + monetization graph,
-- the design docs, the playable pack sources, and an auto-tuned balance pass.
--
-- Everything here is a pure function of its inputs (the same concept + seed always
-- renders byte-identical output) and no network or LLM is ever involved. The
-- deterministic price/production search reuses the pure `econsim` simulator.
--
-- Hard rules encoded here: Robux sells deterministic items only (random hatching is
-- free-currency only), and the "Steal a ..." title/theft pattern is stripped and
-- routed to a team siege.

local econsim = require("../../../cli/forge/lib/econsim")

local M = {}

-- Title words drop only grammar glue, so "egg" / "keepers" survive into the title.
local TITLE_STOPWORDS: { [string]: boolean } = {
	a = true,
	an = true,
	the = true,
	of = true,
	["and"] = true,
	["or"] = true,
	but = true,
	to = true,
	["in"] = true,
	on = true,
	at = true,
	["for"] = true,
	with = true,
	from = true,
	by = true,
	as = true,
	that = true,
	this = true,
	these = true,
	those = true,
	is = true,
	are = true,
	was = true,
	were = true,
	be = true,
	been = true,
	being = true,
	["do"] = true,
	does = true,
	you = true,
	your = true,
	their = true,
	its = true,
	our = true,
	my = true,
	we = true,
	they = true,
	it = true,
	steal = true,
	steals = true,
	stealing = true,
	defend = true,
	defends = true,
	defending = true,
}

-- Creature/egg names additionally drop genre-generic nouns so the roster reads as
-- concept words, not template boilerplate.
local GENERIC_WORDS: { [string]: boolean } = {
	egg = true,
	eggs = true,
	keeper = true,
	keepers = true,
	raider = true,
	raiders = true,
	siege = true,
	sieges = true,
	vault = true,
	vaults = true,
	coin = true,
	coins = true,
	tycoon = true,
	simulator = true,
	clicker = true,
	defense = true,
	defence = true,
	battle = true,
	war = true,
	raid = true,
	raids = true,
}

local PRICE_MULTIPLIERS = { 1, 0.75, 1.25, 0.5, 1.5, 2, 3 }
local PRODUCTION_MULTIPLIERS = { 1, 0.75, 1.25, 0.5, 1.5, 2 }
local TUNE_PLAYERS = 20
local TUNE_DAYS = 7
-- The tuner targets the same defaults `forge econ sim` uses, so the committed pack
-- passes the canonical verification command without extra flags.
local TUNE_SEED = 1

local MERGES = {
	{ from = "Common", count = 3, to = "Rare" },
	{ from = "Rare", count = 3, to = "Legendary" },
}

local DAILY_QUESTS = {
	{ id = "hatch", text = "Hatch 3 eggs", target = 3, reward = 100 },
	{ id = "buy", text = "Buy 5 eggs", target = 5, reward = 150 },
	{ id = "raid", text = "Join 1 siege", target = 1, reward = 300 },
}

local EGG_COLORS = {
	{ body = { 240, 120, 40 }, accent = { 255, 210, 90 } },
	{ body = { 40, 120, 220 }, accent = { 140, 230, 255 } },
	{ body = { 120, 200, 140 }, accent = { 220, 255, 200 } },
}

export type CreatureDef = {
	id: string,
	displayName: string,
	rarity: string,
	tierIndex: number,
	baseCoinsPerSecond: number,
	archetype: string,
	scale: number,
	body: { number },
	accent: { number },
	eye: { number },
	seed: number,
}

export type EggDef = {
	id: string,
	displayName: string,
	basePrice: number,
	hatchSeconds: number,
	creatureIds: { string },
	weights: { number },
	body: { number },
	accent: { number },
}

export type Roster = {
	eggs: { EggDef },
	creatures: { CreatureDef },
}

export type PoolEntry = { id: string, weight: number }

export type EconomyEgg = {
	id: string,
	displayName: string,
	price: number,
	hatchSeconds: number,
	pool: { PoolEntry },
}

export type EconomyCreature = {
	id: string,
	displayName: string,
	rarity: string,
	coinsPerSecond: number,
}

export type MonetizationItem = {
	key: string,
	name: string,
	price: number,
	effect: string,
	deterministic: boolean,
	affectsFreeHatchOnly: boolean,
	-- Gamepass tuning (coins2x income multiplier, vipSlots incubator bonus).
	multiplier: number?,
	slotBonus: number?,
	-- Published Roblox id (0 = not published yet); forge plan carries it over.
	id: number?,
}

export type Monetization = {
	gamepasses: { MonetizationItem },
	products: { MonetizationItem },
}

export type Economy = {
	currency: string,
	startingCoins: number,
	incubators: number,
	growthPerOwned: number,
	activeSlots: number,
	eggs: { EconomyEgg },
	kaiju: { EconomyCreature },
	monetization: Monetization,
}

export type TargetReport = {
	ok: boolean,
	firstPurchaseOk: boolean,
	day7GrowthOk: boolean,
	eggSinkOk: boolean,
	firstPurchaseMinutes: number?,
	day7GrowthPercent: number,
	eggSinkPercent: number,
	reasons: { string },
}

export type TuneResult = {
	ok: boolean,
	priceMultiplier: number,
	productionMultiplier: number,
	attempts: number,
	result: econsim.SimResult?,
	targets: TargetReport?,
}

-- ---------------------------------------------------------------------------
-- Text helpers
-- ---------------------------------------------------------------------------

local function tokens(text: string): { string }
	local words: { string } = {}
	for word in string.gmatch(string.lower(text), "[%a][%a%d]*") do
		table.insert(words, word)
	end
	return words
end

local function trim(text: string): string
	return (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", ""))
end

--- Capitalizes the first letter of each whitespace-separated word.
function M.titleCase(text: string): string
	local parts: { string } = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(parts, string.upper(string.sub(word, 1, 1)) .. string.lower(string.sub(word, 2)))
	end
	return table.concat(parts, " ")
end

local function slugify(text: string): string
	local out = string.lower(text)
	out = string.gsub(out, "[^%a%d]+", "-")
	out = string.gsub(out, "^%-+", "")
	out = string.gsub(out, "%-+$", "")
	return out
end

local function singular(word: string): string
	if #word > 3 and string.sub(word, -1) == "s" and string.sub(word, -2) ~= "ss" then
		return string.sub(word, 1, -2)
	end
	return word
end

--- True when a string contains the forbidden "Steal a ..." title/theft pattern.
function M.containsStealPattern(text: string): boolean
	local lower = string.lower(text)
	if string.find(lower, "steal a", 1, true) ~= nil then
		return true
	end
	if string.find(lower, "steal the", 1, true) ~= nil then
		return true
	end
	if string.find(lower, "^steal%f[%A]") ~= nil then
		return true
	end
	return false
end

--- Strips the "Steal a ..." pattern and falls back to a team-siege title.
function M.sanitizeTitle(title: string): string
	local out = string.gsub(title, "[Ss]teal%s+[Aa]n?%s+", "")
	out = string.gsub(out, "[Ss]teal%s+[Tt]he%s+", "")
	out = string.gsub(out, "^%s*[Ss]teal%s+", "")
	out = trim(out)
	if out == "" or M.containsStealPattern(out) then
		return "Vault Siege"
	end
	return out
end

--- Concept words that survive into the title (grammar glue removed).
function M.titleWords(concept: string): { string }
	local out: { string } = {}
	for _, word in tokens(concept) do
		if not TITLE_STOPWORDS[word] then
			table.insert(out, word)
		end
	end
	return out
end

--- Concept words usable for creature/egg names (genre boilerplate removed too).
function M.nameWords(concept: string): { string }
	local out: { string } = {}
	for _, word in M.titleWords(concept) do
		if not GENERIC_WORDS[word] then
			table.insert(out, word)
		end
	end
	return out
end

--- Derives the pack title from concept words; never returns a "Steal a ..." title.
function M.deriveTitle(concept: string): string
	local words = M.titleWords(concept)
	local picked: { string } = {}
	for index = 1, math.min(4, #words) do
		table.insert(picked, words[index])
	end
	local title = M.titleCase(table.concat(picked, " "))
	if trim(title) == "" then
		return "Vault Siege"
	end
	return M.sanitizeTitle(title)
end

local function fmtNum(value: number): string
	if value == math.floor(value) and math.abs(value) < 9007199254740992 then
		return string.format("%d", value)
	end
	local text = string.format("%.4f", value)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text
end

-- Quotes a YAML scalar only when a plain scalar would be ambiguous.
local function yquote(text: string): string
	local plain = text ~= ""
		and string.find(text, "[%c]") == nil
		and string.find(text, "[:#%[%]{}&*!|>%%@`\"'\\]") == nil
		and string.find(text, "^%s") == nil
		and string.find(text, "%s$") == nil
		and string.sub(text, 1, 1) ~= "-"
		and string.sub(text, 1, 1) ~= "?"
	if plain then
		local lower = string.lower(text)
		if
			lower == "true"
			or lower == "false"
			or lower == "null"
			or lower == "yes"
			or lower == "no"
			or tonumber(text) ~= nil
		then
			plain = false
		end
	end
	if plain then
		return text
	end
	local escaped = string.gsub(text, "\\", "\\\\")
	escaped = string.gsub(escaped, '"', '\\"')
	escaped = string.gsub(escaped, "\n", "\\n")
	return '"' .. escaped .. '"'
end

local function add(lines: { string }, line: string): ()
	table.insert(lines, line)
end

-- ---------------------------------------------------------------------------
-- Roster generation
-- ---------------------------------------------------------------------------

-- RGB (0..255) -> HSV (h in 0..360, s/v in 0..1).
local function rgbToHsv(color: { number }): (number, number, number)
	local r, g, b = color[1] / 255, color[2] / 255, color[3] / 255
	local max = math.max(r, g, b)
	local min = math.min(r, g, b)
	local delta = max - min
	local h = 0
	if delta > 1e-9 then
		if max == r then
			h = 60 * (((g - b) / delta) % 6)
		elseif max == g then
			h = 60 * ((b - r) / delta + 2)
		else
			h = 60 * ((r - g) / delta + 4)
		end
	end
	local s = if max <= 1e-9 then 0 else delta / max
	return h, s, max
end

-- HSV (h in 0..360, s/v in 0..1) -> RGB (0..255, rounded).
local function hsvToRgb(h: number, s: number, v: number): { number }
	local c = v * s
	local hp = (h % 360) / 60
	local x = c * (1 - math.abs(hp % 2 - 1))
	local r1, g1, b1 = 0, 0, 0
	if hp < 1 then
		r1, g1, b1 = c, x, 0
	elseif hp < 2 then
		r1, g1, b1 = x, c, 0
	elseif hp < 3 then
		r1, g1, b1 = 0, c, x
	elseif hp < 4 then
		r1, g1, b1 = 0, x, c
	elseif hp < 5 then
		r1, g1, b1 = x, 0, c
	else
		r1, g1, b1 = c, 0, x
	end
	local m = v - c
	return {
		math.floor(math.clamp((r1 + m) * 255, 0, 255) + 0.5),
		math.floor(math.clamp((g1 + m) * 255, 0, 255) + 0.5),
		math.floor(math.clamp((b1 + m) * 255, 0, 255) + 0.5),
	}
end

-- Snaps `hue` to the nearest entry in the template's egg hue-family list, so
-- an egg picked by seed still lands on one of a small set of readable hues
-- instead of an arbitrary in-between color.
local function nearestHueFamily(hue: number, families: { number }): number
	local best = families[1]
	local bestDelta = math.huge
	for _, family in families do
		local delta = math.abs(((hue - family + 180) % 360) - 180)
		if delta < bestDelta then
			bestDelta = delta
			best = family
		end
	end
	return best
end

--- Derives a creature's body/accent/eye palette from the egg's hue family and
--- the tier's saturation/brightness/accent style, so every egg gets its own
--- hue family and every rarity reads as visibly more saturated/brighter/more
--- intense-accented than the one below it.
local function tierPalette(eggHue: number, style: any): ({ number }, { number }, { number })
	local saturation = style.saturation
	local brightness = style.brightness
	local body = hsvToRgb(eggHue, saturation, brightness)
	local accent = hsvToRgb(
		(eggHue + 40) % 360,
		math.min(1, saturation + style.accent_boost),
		math.min(1, brightness + style.accent_boost)
	)
	local eye = hsvToRgb(eggHue, math.max(0, saturation - 0.5), 1)
	return body, accent, eye
end

--- Resolves a creature's archetype from its name noun (the rarity-tier
--- suffix, e.g. "Serpent", "Leviathan"): the noun is looked up in the
--- template's keyword map (serpent/snake/eel/leviathan/wyrm -> serpent, etc.)
--- and falls back to the tier's default archetype when the noun matches no
--- keyword, so every archetype choice stays deterministic.
local function archetypeForSuffix(suffix: string, tierName: string, plan: any): string
	local keywords = plan.archetype_keywords
	if type(keywords) == "table" then
		local lower = string.lower(suffix)
		local hit = keywords[lower]
		if hit ~= nil then
			return hit
		end
	end
	return plan.archetypes[tierName]
end

local function namePool(concept: string, plan: any): { string }
	local pool: { string } = {}
	local seen: { [string]: boolean } = {}
	local function push(word: string): ()
		local key = string.lower(singular(word))
		if word ~= "" and not seen[key] then
			seen[key] = true
			table.insert(pool, word)
		end
	end
	-- Concept words first; template nouns only pad a thin concept to the max egg count.
	for _, word in M.nameWords(concept) do
		push(word)
	end
	for _, word in plan.fallback_nouns do
		if #pool >= plan.egg_count.max then
			break
		end
		push(word)
	end
	return pool
end

--- Builds the deterministic creature/egg roster from concept words, the template
--- pools, and the seed. The RNG draw order is fixed, so the same inputs repeat.
function M.buildRoster(concept: string, plan: any, seed: number): Roster
	local rng = econsim.newRng(seed)
	local tiers = plan.rarity_tiers
	local tierCount = #tiers
	local pool = namePool(concept, plan)

	local eggCount = econsim.nextInt(rng, plan.egg_count.min, plan.egg_count.max)
	local start = seed % #pool

	local creatures: { CreatureDef } = {}
	local eggs: { EggDef } = {}
	local used: { [string]: boolean } = {}
	local creatureSeed = 100

	for eggIndex = 1, eggCount do
		local base = singular(pool[((start + eggIndex - 1) % #pool) + 1])
		local profile = plan.egg_weight_profiles[((eggIndex - 1) % #plan.egg_weight_profiles) + 1]
		local creatureIds: { string } = {}
		local weights: { number } = {}

		local eggColor = EGG_COLORS[((eggIndex - 1) % #EGG_COLORS) + 1]
		local eggHueRaw, _, _ = rgbToHsv(eggColor.body)
		local eggHue = nearestHueFamily(eggHueRaw, plan.egg_hue_families)

		for tierIndex = 1, tierCount do
			local tier = tiers[tierIndex]
			local suffixes = plan.creature_suffixes[tier.name]
			local suffix = suffixes[econsim.nextInt(rng, 1, #suffixes)]
			local id = slugify(base .. "-" .. suffix)
			if used[id] then
				id = id .. "-" .. tostring(tierIndex)
			end
			used[id] = true

			local style = plan.tier_style[tier.name]
			local body, accent, eye = tierPalette(eggHue, style)
			creatureSeed += 1
			table.insert(creatures, {
				id = id,
				displayName = M.titleCase(base) .. " " .. suffix,
				rarity = tier.name,
				tierIndex = tierIndex,
				baseCoinsPerSecond = tier.coins_per_second,
				archetype = archetypeForSuffix(suffix, tier.name, plan),
				scale = plan.scales[tier.name],
				body = body,
				accent = accent,
				eye = eye,
				seed = creatureSeed,
			})
			table.insert(creatureIds, id)
			table.insert(weights, profile[tierIndex] / 100)
		end

		local eggId = slugify(base)
		if used[eggId] then
			eggId = eggId .. "-" .. tostring(eggIndex)
		end
		used[eggId] = true
		table.insert(eggs, {
			id = eggId,
			displayName = M.titleCase(base) .. " Egg",
			basePrice = plan.egg_base_price * plan.egg_price_multipliers[eggIndex],
			hatchSeconds = plan.egg_hatch_seconds[eggIndex],
			creatureIds = creatureIds,
			weights = weights,
			body = eggColor.body,
			accent = eggColor.accent,
		})
	end

	return { eggs = eggs, creatures = creatures }
end

-- ---------------------------------------------------------------------------
-- Economy + monetization
-- ---------------------------------------------------------------------------

--- Turns the template's tiered price ladder into concrete Robux prices. Every
--- entry is deterministic; only the luck boost is flagged as free-hatch-only.
function M.buildMonetization(plan: any): Monetization
	local ladder = plan.monetization.price_ladder
	local gamepasses: { MonetizationItem } = {}
	for _, item in plan.monetization.gamepasses do
		table.insert(gamepasses, {
			key = item.key,
			name = item.name,
			price = ladder[item.tier],
			effect = item.effect,
			deterministic = true,
			affectsFreeHatchOnly = false,
			multiplier = item.multiplier,
			slotBonus = item.slotBonus,
		})
	end
	local products: { MonetizationItem } = {}
	for _, item in plan.monetization.products do
		table.insert(products, {
			key = item.key,
			name = item.name,
			price = ladder[item.tier],
			effect = item.effect,
			deterministic = true,
			affectsFreeHatchOnly = item.key == "luckBoost",
		})
	end
	return { gamepasses = gamepasses, products = products }
end

--- Builds the concrete economy for a roster and a (price, production) multiplier
--- pair. Egg prices and creature rates scale by the multipliers so the tuner can
--- search deterministically.
function M.buildEconomy(plan: any, roster: Roster, priceMultiplier: number, productionMultiplier: number): Economy
	local eggs: { EconomyEgg } = {}
	for _, egg in roster.eggs do
		local price = math.max(1, math.floor(egg.basePrice * priceMultiplier + 0.5))
		local pool: { PoolEntry } = {}
		for index, creatureId in egg.creatureIds do
			table.insert(pool, { id = creatureId, weight = egg.weights[index] })
		end
		table.insert(eggs, {
			id = egg.id,
			displayName = egg.displayName,
			price = price,
			hatchSeconds = egg.hatchSeconds,
			pool = pool,
		})
	end

	local kaiju: { EconomyCreature } = {}
	for _, creature in roster.creatures do
		table.insert(kaiju, {
			id = creature.id,
			displayName = creature.displayName,
			rarity = creature.rarity,
			coinsPerSecond = creature.baseCoinsPerSecond * productionMultiplier,
		})
	end

	return {
		currency = plan.currency,
		startingCoins = plan.starting_coins,
		incubators = plan.incubators,
		growthPerOwned = plan.growth_per_owned,
		activeSlots = plan.active_slots,
		eggs = eggs,
		kaiju = kaiju,
		monetization = M.buildMonetization(plan),
	}
end

--- Adapts an Economy into the econsim config shape (free-currency loop only).
function M.toSimConfig(economy: Economy): econsim.EconConfig
	return econsim.parseConfig({
		currencies = { { id = economy.currency, starting = economy.startingCoins } },
		incubators = { max = economy.incubators },
		pricing = { growthPerOwned = economy.growthPerOwned },
		income = { activeSlots = economy.activeSlots },
		eggs = economy.eggs,
		kaiju = economy.kaiju,
	})
end

-- ---------------------------------------------------------------------------
-- Auto-tuning
-- ---------------------------------------------------------------------------

--- Checks a simulation run against the genre balance targets from the template.
function M.evaluateTargets(plan: any, result: econsim.SimResult): TargetReport
	local low = plan.first_purchase_target_minutes[1]
	local high = plan.first_purchase_target_minutes[2]
	local firstPurchase = result.medianFirstPurchaseMinute
	local firstPurchaseOk = firstPurchase ~= nil and firstPurchase >= low and firstPurchase <= high

	local day7Growth = result.dailyInflation[#result.dailyInflation] or 0
	local day7GrowthOk = day7Growth <= plan.day7_growth_max_percent

	local eggSink = if result.totalProduced > 0 then result.totalSpent / result.totalProduced * 100 else 0
	local eggSinkOk = eggSink >= plan.egg_sink_min_percent

	local reasons: { string } = {}
	if not firstPurchaseOk then
		table.insert(
			reasons,
			string.format(
				"median first-purchase %s outside %g-%g min",
				if firstPurchase ~= nil then string.format("%.1f", firstPurchase) else "none",
				low,
				high
			)
		)
	end
	if not day7GrowthOk then
		table.insert(
			reasons,
			string.format("day-7 growth %+.2f%% above %g%%", day7Growth, plan.day7_growth_max_percent)
		)
	end
	if not eggSinkOk then
		table.insert(reasons, string.format("egg sink %.2f%% below %g%%", eggSink, plan.egg_sink_min_percent))
	end

	return {
		ok = firstPurchaseOk and day7GrowthOk and eggSinkOk,
		firstPurchaseOk = firstPurchaseOk,
		day7GrowthOk = day7GrowthOk,
		eggSinkOk = eggSinkOk,
		firstPurchaseMinutes = firstPurchase,
		day7GrowthPercent = day7Growth,
		eggSinkPercent = eggSink,
		reasons = reasons,
	}
end

--- Deterministic bounded search over (price, production) multipliers. The grid
--- order is fixed and (1, 1) is evaluated first, so a passing default is stable.
function M.tune(plan: any, roster: Roster): TuneResult
	local attempts = 0
	local last: TargetReport? = nil
	for _, priceMultiplier in PRICE_MULTIPLIERS do
		for _, productionMultiplier in PRODUCTION_MULTIPLIERS do
			attempts += 1
			local economy = M.buildEconomy(plan, roster, priceMultiplier, productionMultiplier)
			local result = econsim.simulate(M.toSimConfig(economy), {
				players = TUNE_PLAYERS,
				days = TUNE_DAYS,
				seed = TUNE_SEED,
			})
			local targets = M.evaluateTargets(plan, result)
			last = targets
			if targets.ok then
				return {
					ok = true,
					priceMultiplier = priceMultiplier,
					productionMultiplier = productionMultiplier,
					attempts = attempts,
					result = result,
					targets = targets,
				}
			end
		end
	end
	return {
		ok = false,
		priceMultiplier = 1,
		productionMultiplier = 1,
		attempts = attempts,
		result = nil,
		targets = last,
	}
end

-- ---------------------------------------------------------------------------
-- Rendering: game.yml + econ.yml
-- ---------------------------------------------------------------------------

local function renderMonetizationYml(
	lines: { string },
	monetization: Monetization,
	indent: string,
	withEffects: boolean?
): ()
	add(lines, indent .. "gamepasses:")
	for _, item in monetization.gamepasses do
		add(lines, indent .. "  - key: " .. yquote(item.key))
		add(lines, indent .. "    name: " .. yquote(item.name))
		add(lines, indent .. "    price: " .. fmtNum(item.price))
		add(lines, indent .. "    id: " .. tostring(item.id or 0))
		if withEffects and item.multiplier ~= nil then
			add(lines, indent .. "    multiplier: " .. fmtNum(item.multiplier))
		end
		if withEffects and item.slotBonus ~= nil then
			add(lines, indent .. "    slotBonus: " .. fmtNum(item.slotBonus))
		end
	end
	add(lines, indent .. "products:")
	for _, item in monetization.products do
		add(lines, indent .. "  - key: " .. yquote(item.key))
		add(lines, indent .. "    name: " .. yquote(item.name))
		add(lines, indent .. "    price: " .. fmtNum(item.price))
		add(lines, indent .. "    id: " .. tostring(item.id or 0))
		add(lines, indent .. "    deterministic: true")
		add(lines, indent .. "    affectsFreeHatchOnly: " .. tostring(item.affectsFreeHatchOnly))
	end
end

--- Renders the concrete econ.yml for a tuned economy.
function M.renderEconYml(economy: Economy): string
	local lines: { string } = {}
	add(lines, "# GENERATED by forge plan from genres/collect-raid/econ-template.yml. Do not edit.")
	add(lines, "# Robux products are deterministic only; random hatching runs on free currency only.")
	add(lines, "")
	add(lines, "currencies:")
	add(lines, "  - id: " .. yquote(economy.currency))
	add(lines, "    kind: free")
	add(lines, "    starting: " .. fmtNum(economy.startingCoins))
	add(lines, "")
	add(lines, "incubators:")
	add(lines, "  max: " .. fmtNum(economy.incubators))
	add(lines, "")
	add(lines, "pricing:")
	add(lines, "  growthPerOwned: " .. fmtNum(economy.growthPerOwned))
	add(lines, "")
	add(lines, "income:")
	add(lines, "  activeSlots: " .. fmtNum(economy.activeSlots))
	add(lines, "")
	add(lines, "eggs:")
	for _, egg in economy.eggs do
		add(lines, "  - id: " .. yquote(egg.id))
		add(lines, "    displayName: " .. yquote(egg.displayName))
		add(lines, "    price: " .. fmtNum(egg.price))
		add(lines, "    hatchSeconds: " .. fmtNum(egg.hatchSeconds))
		add(lines, "    pool:")
		for _, entry in egg.pool do
			add(lines, "      - id: " .. yquote(entry.id))
			add(lines, "        weight: " .. fmtNum(entry.weight))
		end
	end
	add(lines, "")
	add(lines, "kaiju:")
	for _, creature in economy.kaiju do
		add(lines, "  - id: " .. yquote(creature.id))
		add(lines, "    displayName: " .. yquote(creature.displayName))
		add(lines, "    rarity: " .. yquote(creature.rarity))
		add(lines, "    coinsPerSecond: " .. fmtNum(creature.coinsPerSecond))
	end
	add(lines, "")
	add(lines, "sinks:")
	for _, sink in M.planSinks(economy) do
		add(lines, "  - " .. yquote(sink))
	end
	add(lines, "")
	add(lines, "merges:")
	for _, merge in MERGES do
		add(lines, "  - from: " .. merge.from)
		add(lines, "    count: " .. tostring(merge.count))
		add(lines, "    to: " .. merge.to)
	end
	add(lines, "")
	add(lines, "dailyQuests:")
	for _, quest in DAILY_QUESTS do
		add(lines, "  - id: " .. yquote(quest.id))
		add(lines, "    text: " .. yquote(quest.text))
		add(lines, "    reward: " .. fmtNum(quest.reward))
	end
	add(lines, "")
	add(lines, "monetization:")
	renderMonetizationYml(lines, economy.monetization, "  ", true)
	return table.concat(lines, "\n") .. "\n"
end

--- Renders the pack game.yml.
function M.renderGameYml(
	plan: any,
	economy: Economy,
	title: string,
	slug: string,
	genre: string,
	generatedBy: string?
): string
	local lines: { string } = {}
	add(lines, "name: " .. yquote(title))
	add(lines, "slug: " .. slug)
	add(lines, "genres: [" .. genre .. "]")
	if generatedBy ~= nil then
		add(lines, "# Regenerate with: " .. generatedBy)
		add(lines, "generatedBy: " .. yquote(generatedBy))
	end
	add(lines, "currencies: [" .. economy.currency .. "]")
	add(lines, "# Robux products are deterministic only; random hatching runs on free currency only.")
	add(lines, "monetization:")
	renderMonetizationYml(lines, economy.monetization, "  ")
	add(lines, "  subscriptions: []")
	add(lines, "art_style: " .. yquote(plan.art_style))
	add(
		lines,
		"poly_budget: { kaiju: "
			.. fmtNum(plan.poly_budget.kaiju)
			.. ", egg: "
			.. fmtNum(plan.poly_budget.egg)
			.. ", prop: "
			.. fmtNum(plan.poly_budget.prop)
			.. ", world_parts_max: "
			.. fmtNum(plan.poly_budget.world_parts_max)
			.. " }"
	)
	add(lines, "locales: [en-us, ko-kr]")
	add(lines, "qa_scenarios: [tutorial, core-loop, first-purchase, rejoin]")
	add(lines, "liveops_cadence: weekly")
	add(lines, "session_target_minutes: " .. fmtNum(plan.session_target_minutes))
	add(lines, "core_loop: " .. yquote(plan.core_loop))
	add(lines, "siege:")
	add(lines, "  structure: " .. yquote(plan.siege.structure))
	add(lines, "  period_seconds: " .. fmtNum(plan.siege.period_seconds))
	add(lines, "  duration_seconds: " .. fmtNum(plan.siege.duration_seconds))
	add(lines, "  max_take: " .. fmtNum(plan.siege.max_take))
	add(lines, "tutorial_steps:")
	for _, step in plan.tutorial_steps do
		add(lines, "  - " .. yquote(step))
	end
	add(lines, "analytics_events:")
	for _, event in plan.analytics_events do
		add(lines, "  - " .. yquote(event))
	end
	add(lines, "ratings:")
	add(lines, "  violence: " .. yquote(plan.ratings.violence))
	add(lines, "  romance: " .. yquote(plan.ratings.romance))
	add(lines, "  gambling: " .. yquote(plan.ratings.gambling))
	add(lines, "  social: " .. yquote(plan.ratings.social))
	add(lines, "  language: " .. yquote(plan.ratings.language))
	add(lines, "  paid_random: " .. tostring(plan.ratings.paid_random))
	add(lines, "")
	return table.concat(lines, "\n")
end

--- The design-doc sinks list, derived from the template knobs.
function M.planSinks(economy: Economy): { string }
	return {
		string.format(
			"Egg prices scale with the owned creature count (pricing.growthPerOwned %s)",
			fmtNum(economy.growthPerOwned)
		),
		string.format(
			"Only the top %s earning creatures produce income (income.activeSlots)",
			fmtNum(economy.activeSlots)
		),
		"Merging consumes 3 creatures to produce 1 of the next rarity",
	}
end

-- ---------------------------------------------------------------------------
-- Rendering: playable pack sources
-- ---------------------------------------------------------------------------

local function rgb(color: { number }): string
	return string.format("[%d, %d, %d]", color[1], color[2], color[3])
end

--- Renders assets/procgen.yml so every roster creature and every egg has a spec.
-- Scatter decor meshes (keys match genres/collect-raid/module/runtime/WorldDecor).
local DECOR_SPECS: { { key: string, archetype: string, body: { number }, accent: { number }, foliage: { number }?, seed: number } } =
	{
		{ key = "decor-rock", archetype = "rock", body = { 120, 120, 115 }, accent = { 104, 150, 72 }, seed = 301 },
		{
			key = "decor-tree",
			archetype = "tree",
			body = { 120, 82, 44 },
			accent = { 214, 86, 72 },
			foliage = { 90, 170, 70 },
			seed = 302,
		},
		{
			key = "decor-crystal",
			archetype = "crystal",
			body = { 60, 220, 255 },
			accent = { 180, 240, 255 },
			seed = 303,
		},
		{ key = "decor-crate", archetype = "crate", body = { 156, 110, 62 }, accent = { 96, 64, 34 }, seed = 304 },
	}

function M.renderProcgen(roster: Roster, title: string): string
	local lines: { string } = {}
	add(lines, "# Procedural asset specs for " .. title .. ", generated by forge plan.")
	add(lines, "# `lune run cli/forge gen procedural` builds these pure meshes under Lune (no API keys).")
	add(lines, "assets:")
	for _, creature in roster.creatures do
		add(lines, "  - key: " .. creature.id)
		add(lines, "    kind: creature")
		add(lines, "    archetype: " .. creature.archetype)
		add(lines, "    scale: " .. fmtNum(creature.scale))
		add(lines, "    body: " .. rgb(creature.body))
		add(lines, "    accent: " .. rgb(creature.accent))
		add(lines, "    eye: " .. rgb(creature.eye))
		add(lines, "    seed: " .. tostring(creature.seed))
	end
	for index, egg in roster.eggs do
		add(lines, "  - key: " .. egg.id)
		add(lines, "    kind: prop")
		add(lines, "    archetype: egg")
		add(lines, "    scale: 1")
		add(lines, "    body: " .. rgb(egg.body))
		add(lines, "    accent: " .. rgb(egg.accent))
		add(lines, "    seed: " .. tostring(200 + index))
	end
	-- Scatter decor meshes the genre WorldDecor runtime looks up by key.
	for _, decor in DECOR_SPECS do
		add(lines, "  - key: " .. decor.key)
		add(lines, "    kind: prop")
		add(lines, "    archetype: " .. decor.archetype)
		add(lines, "    scale: 1")
		add(lines, "    body: " .. rgb(decor.body))
		add(lines, "    accent: " .. rgb(decor.accent))
		if decor.foliage ~= nil then
			add(lines, "    foliage: " .. rgb(decor.foliage))
		end
		add(lines, "    seed: " .. tostring(decor.seed))
	end
	return table.concat(lines, "\n") .. "\n"
end

local TEAM_COLORS_BY_NAME: { [string]: string } = {
	Red = "Really red",
	Blue = "Bright blue",
}
local FALLBACK_TEAM_COLORS = { "Really red", "Bright blue", "Bright green", "New Yeller" }

-- rgb for each BrickColor name FALLBACK_TEAM_COLORS can produce, so generated
-- world data can paint a team-colored part without depending on the engine's
-- BrickColor palette at generation time (planner.luau runs under Lune).
local TEAM_BRICK_RGB: { [string]: { number } } = {
	["Really red"] = { 200, 50, 50 },
	["Bright blue"] = { 50, 90, 210 },
	["Bright green"] = { 60, 170, 80 },
	["New Yeller"] = { 220, 200, 60 },
}

--- Resolves a BrickColor name for a team: a well-known team name keeps its
--- traditional color, otherwise teams are colored in a fixed rotation so the
--- same `--teams` list always renders the same colors.
function M.teamBrickColor(teamName: string, index: number): string
	return TEAM_COLORS_BY_NAME[teamName] or FALLBACK_TEAM_COLORS[((index - 1) % #FALLBACK_TEAM_COLORS) + 1]
end

--- Renders src/shared/Config.luau: the full `Loop.Config` (see the collect-raid
--- genre runtime) plus the server-only anticheat/liveops sections the genre
--- Server runtime also takes as config. `plan` (the template's `plan:` block)
--- is optional so old 3-arg callers still get the template's default siege
--- timings; teams live in `Server.Options.teams`, not `Loop.Config`.
function M.renderConfig(roster: Roster, title: string, plan: any?): string
	local siege = if plan ~= nil
			and typeof(plan) == "table"
			and plan.siege ~= nil
		then plan.siege
		else { period_seconds = 600, duration_seconds = 120, max_take = 3 }
	local lines: { string } = {
		"--!strict",
		"-- Config: pure data for " .. title .. ", shaped to the collect-raid genre runtime's",
		"-- Loop.Config plus two server-only sections (anticheat, liveops). Generated by forge",
		"-- plan; economy values come from EconConfig (generated from econ.yml by forge codegen).",
		"",
		'local Loop = require("../../../../genres/collect-raid/module/runtime/Loop")',
		'local EconConfig = require("./EconConfig")',
		"",
		"export type AnticheatConfig = {",
		"\tcapacity: number,",
		"\trefillPerSecond: number,",
		"}",
		"",
		"export type LiveopsConfig = {",
		"\tevents: { { id: string, startsAt: number, endsAt: number, multipliers: { [string]: number }? } },",
		"\tflags: { [string]: boolean | { rollout: number } },",
		"}",
		"",
		"export type PackConfig = Loop.Config & {",
		"\tanticheat: { [string]: AnticheatConfig },",
		"\tliveops: LiveopsConfig,",
		"}",
		"",
		"local Config: PackConfig = {",
		"\tcurrency = EconConfig.currency,",
		"\tstartingCoins = EconConfig.startingCoins,",
		"\tmaxIncubators = EconConfig.maxIncubators,",
		"",
		"\tpricing = EconConfig.pricing,",
		"\tincome = EconConfig.income,",
		"\tpassEffects = EconConfig.passEffects,",
		"",
		"\tsources = EconConfig.eggs,",
		"\tsourceOrder = EconConfig.eggOrder,",
		"\tcreatures = EconConfig.kaiju,",
		"",
	}

	add(lines, "\tmergeFamilies = {")
	for _, egg in roster.eggs do
		local rules: { string } = {}
		for tierIndex, merge in MERGES do
			-- creatureIds are in tier order (Common, Rare, Legendary, ...), so tier
			-- index k merges into tier index k+1.
			local fromCreature = egg.creatureIds[tierIndex]
			local toCreature = egg.creatureIds[tierIndex + 1]
			if fromCreature ~= nil and toCreature ~= nil then
				table.insert(
					rules,
					string.format(
						"\t\t\t\t{ from = %q, to = %q, count = %d, resultId = %q },",
						merge.from,
						merge.to,
						merge.count,
						toCreature
					)
				)
			end
		end
		add(lines, "\t\t{")
		add(lines, string.format("\t\t\tid = %q,", egg.id))
		add(lines, string.format("\t\t\tdisplayName = %q,", M.titleCase(egg.id)))
		add(lines, "\t\t\trules = {")
		for _, rule in rules do
			add(lines, rule)
		end
		add(lines, "\t\t\t},")
		add(lines, "\t\t},")
	end
	add(lines, "\t},")
	add(lines, "")

	add(lines, "\tsiege = {")
	add(lines, "\t\tperiod = " .. fmtNum(siege.period_seconds) .. ",")
	add(lines, "\t\tduration = " .. fmtNum(siege.duration_seconds) .. ",")
	add(lines, "\t\tmaxTake = " .. fmtNum(siege.max_take) .. ",")
	add(lines, "\t},")
	add(lines, "")

	add(lines, "\toffline = {")
	add(lines, "\t\tmaxSeconds = 8 * 3600,")
	add(lines, "\t\tefficiency = 0.5,")
	add(lines, "\t},")
	add(lines, "")

	add(lines, "\tdailyQuests = {")
	for _, quest in DAILY_QUESTS do
		add(lines, string.format("\t\t{ id = %q, target = %d, reward = %d },", quest.id, quest.target, quest.reward))
	end
	add(lines, "\t},")
	add(lines, "")

	add(lines, "\ttutorialSteps = {")
	add(lines, '\t\t{ id = "buy", hint = "Buy an egg from the panel", event = "buy" },')
	add(lines, '\t\t{ id = "hatch", hint = "Hatch your egg when it is ready", event = "hatch" },')
	add(lines, '\t\t{ id = "claim", hint = "Claim a completed daily quest", event = "claim" },')
	add(lines, '\t\t{ id = "store", hint = "Open the store to see Robux items", event = "store" },')
	add(lines, "\t},")
	add(lines, "")

	add(lines, "\tprofile = {")
	add(lines, "\t\tversion = 1,")
	add(lines, "\t\tdefaults = function(): { [string]: any }")
	add(lines, "\t\t\treturn {")
	add(lines, "\t\t\t\tcoins = EconConfig.startingCoins,")
	add(lines, "\t\t\t\tcreatures = {},")
	add(lines, "\t\t\t\tlastSeen = 0,")
	add(lines, "\t\t\t\tquestDay = 0,")
	add(lines, "\t\t\t\tquest = nil,")
	add(lines, "\t\t\t}")
	add(lines, "\t\tend,")
	add(lines, "\t},")
	add(lines, "")

	add(lines, "\tanticheat = {")
	add(lines, "\t\tBuyEgg = { capacity = 5, refillPerSecond = 2 },")
	add(lines, "\t\tHatchEgg = { capacity = 5, refillPerSecond = 2 },")
	add(lines, "\t\tMerge = { capacity = 5, refillPerSecond = 2 },")
	add(lines, "\t\tClaimQuest = { capacity = 5, refillPerSecond = 2 },")
	add(lines, "\t\tRaid = { capacity = 2, refillPerSecond = 0.2 },")
	add(lines, "\t\tStoreOpen = { capacity = 3, refillPerSecond = 0.5 },")
	add(lines, "\t},")
	add(lines, "")

	add(lines, "\tliveops = {")
	add(lines, "\t\tevents = {},")
	add(lines, "\t\tflags = {},")
	add(lines, "\t},")
	add(lines, "}")
	add(lines, "")
	add(lines, "return Config")
	add(lines, "")
	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Rendering: shared data modules (Catalog, Remotes, Messages, Copy,
-- AudioConfig, CreatureModels, Fx) and world generation (WorldLayout,
-- WorldTheme). All are pure functions of (economy/roster/identity flags), so
-- the same plan args always render byte-identical modules.
-- ---------------------------------------------------------------------------

-- Robux grant kind per template monetization key. The `plan:` template's key
-- set is fixed (see genres/collect-raid/econ-template.yml monetization.*), so
-- mapping by key is exact and stable across packs.
local GRANT_KIND: { [string]: string } = {
	coins2x = "multiplier",
	vipSlots = "slots",
	autoLock = "flag",
	creaturePack = "kaiju",
	hatchSpeedup = "speedup",
	siegeShield = "shield",
	luckBoost = "serverBoost",
}

local GRANT_VALUE: { [string]: number } = {
	coins2x = 2,
	vipSlots = 4,
}

--- Renders src/shared/Catalog.luau: the pack's monetization catalog. Every
--- entry's `id` stays 0 until the item is created on Roblox (see AGENTS.md;
--- Robux never buys a random item).
function M.renderCatalog(economy: Economy, roster: Roster): string
	local lines: { string } = {}
	add(lines, "--!strict")
	add(lines, "-- Catalog: generated by forge plan from game.yml monetization. Deterministic only:")
	add(lines, "-- Robux never buys a random item (see AGENTS.md). Each entry's `id` stays 0 until the")
	add(lines, "-- item is created on Roblox and is filled in at publish time.")
	add(lines, "")
	add(
		lines,
		'export type GrantKind = "multiplier" | "slots" | "flag" | "kaiju" | "speedup" | "shield" | "serverBoost"'
	)
	add(lines, "")
	add(lines, "export type Grant = {")
	add(lines, "\tkind: GrantKind,")
	add(lines, "\tvalue: number?,")
	add(lines, "\tflag: string?,")
	add(lines, "\tkaijuId: string?,")
	add(lines, "\tseconds: number?,")
	add(lines, "}")
	add(lines, "")
	add(lines, "export type Entry = {")
	add(lines, "\tid: number,")
	add(lines, "\tkey: string,")
	add(lines, "\tname: string,")
	add(lines, "\tprice: number,")
	add(lines, "\tgrant: Grant,")
	add(lines, "}")
	add(lines, "")
	add(lines, "export type Catalog = {")
	add(lines, "\tgamepasses: { Entry },")
	add(lines, "\tproducts: { Entry },")
	add(lines, "}")
	add(lines, "")
	add(lines, "local Catalog = {}")
	add(lines, "")

	-- Rare-est creature backs the guaranteed-creature product's grant so it
	-- reads as a genuine reward, not a random common.
	local rareCreatureId = roster.creatures[1].id
	for _, creature in roster.creatures do
		if creature.rarity == "Rare" then
			rareCreatureId = creature.id
			break
		end
	end

	local function grantFor(item: MonetizationItem): string
		local kind = GRANT_KIND[item.key] or "flag"
		if kind == "multiplier" then
			return string.format("{ kind = %q, value = %d }", kind, item.multiplier or GRANT_VALUE[item.key] or 2)
		elseif kind == "slots" then
			return string.format("{ kind = %q, value = %d }", kind, item.slotBonus or GRANT_VALUE[item.key] or 4)
		elseif kind == "flag" then
			return string.format("{ kind = %q, flag = %q }", kind, item.key)
		elseif kind == "kaiju" then
			return string.format("{ kind = %q, kaijuId = %q }", kind, rareCreatureId)
		elseif kind == "speedup" then
			return string.format("{ kind = %q, seconds = 3600 }", kind)
		elseif kind == "shield" then
			return string.format("{ kind = %q, seconds = 600 }", kind)
		elseif kind == "serverBoost" then
			return string.format("{ kind = %q, seconds = 900 }", kind)
		end
		return string.format("{ kind = %q }", kind)
	end

	add(lines, "Catalog.gamepasses = {")
	for _, item in economy.monetization.gamepasses do
		add(
			lines,
			string.format(
				"\t{ id = %d, key = %q, name = %q, price = %d, grant = %s },",
				item.id or 0,
				item.key,
				item.name,
				item.price,
				grantFor(item)
			)
		)
	end
	add(lines, "} :: { Entry }")
	add(lines, "")
	add(lines, "Catalog.products = {")
	for _, item in economy.monetization.products do
		add(
			lines,
			string.format(
				"\t{ id = %d, key = %q, name = %q, price = %d, grant = %s },",
				item.id or 0,
				item.key,
				item.name,
				item.price,
				grantFor(item)
			)
		)
	end
	add(lines, "} :: { Entry }")
	add(lines, "")
	add(lines, "-- Lookups by Roblox id only include published items (id > 0); key lookups cover all.")
	add(lines, "Catalog.gamepassById = {} :: { [number]: Entry }")
	add(lines, "Catalog.productById = {} :: { [number]: Entry }")
	add(lines, "Catalog.gamepassByKey = {} :: { [string]: Entry }")
	add(lines, "Catalog.productByKey = {} :: { [string]: Entry }")
	add(lines, "")
	add(lines, "for _, entry in Catalog.gamepasses do")
	add(lines, "\tCatalog.gamepassByKey[entry.key] = entry")
	add(lines, "\tif entry.id > 0 then")
	add(lines, "\t\tCatalog.gamepassById[entry.id] = entry")
	add(lines, "\tend")
	add(lines, "end")
	add(lines, "for _, entry in Catalog.products do")
	add(lines, "\tCatalog.productByKey[entry.key] = entry")
	add(lines, "\tif entry.id > 0 then")
	add(lines, "\t\tCatalog.productById[entry.id] = entry")
	add(lines, "\tend")
	add(lines, "end")
	add(lines, "")
	add(lines, "return Catalog")
	add(lines, "")
	return table.concat(lines, "\n")
end

--- Renders src/shared/Remotes.luau. Pack-independent except for the comment
--- header, since the ReplicatedStorage.Remotes shape is fixed by the genre.
--- Renders src/shared/Catalog.spec.luau: generic core-Catalog validation plus
--- the AGENTS.md hard rules (no random/roll/egg grants, no pool/odds grant on
--- a paid item, fixed creature id on any `kaiju`-kind grant). No pack-specific
--- data, so this is identical for every collect-raid pack.
function M.renderCatalogSpec(): string
	local lines: { string } = {
		"--!strict",
		"-- Specs for the game catalog: core validation passes and no paid random items.",
		"-- Generated by forge plan.",
		"",
		'local CatalogCore = require("../../../../core/infra/monetization/Catalog")',
		'local Catalog = require("./Catalog")',
		"",
		"return {",
		'\t["pack catalog passes core Catalog.validate"] = function()',
		"\t\tlocal ok, reason = CatalogCore.validate(Catalog)",
		'\t\tassert(ok == true, "catalog must validate: " .. tostring(reason))',
		'\t\tassert(reason == nil, "no reason on success")',
		"\tend,",
		"",
		'\t["no catalog entry grants a random item"] = function()',
		"\t\tlocal sections: { { Catalog.Entry } } = { Catalog.gamepasses, Catalog.products }",
		"\t\tfor _, section in sections do",
		"\t\t\tfor _, entry in section do",
		"\t\t\t\tlocal grant: any = entry.grant",
		"\t\t\t\tlocal kind = entry.grant.kind",
		'\t\t\t\tassert(kind ~= "random" and kind ~= "roll" and kind ~= "egg", "random grant: " .. entry.key)',
		'\t\t\t\tassert(grant.pool == nil and grant.odds == nil, "pool/odds grant: " .. entry.key)',
		"\t\t\tend",
		"\t\tend",
		"\tend,",
		"",
		'\t["kaiju products name a fixed kaiju id"] = function()',
		"\t\tfor _, entry in Catalog.products do",
		'\t\t\tif entry.grant.kind == "kaiju" then',
		"\t\t\t\tlocal kaijuId = entry.grant.kaijuId",
		'\t\t\t\tassert(type(kaijuId) == "string" and kaijuId ~= "", "fixed kaijuId required: " .. entry.key)',
		"\t\t\tend",
		"\t\tend",
		"\tend,",
		"}",
		"",
	}
	return table.concat(lines, "\n")
end

function M.renderRemotes(title: string): string
	local lines: { string } = {
		"--!strict",
		"-- Remotes: typed handles for " .. title .. "'s ReplicatedStorage.Remotes",
		"-- folder (declared in default.project.json), shared by the server and client",
		"-- entry points so neither has to repeat the WaitForChild/cast boilerplate.",
		"-- Generated by forge plan.",
		"",
		'local ReplicatedStorage = game:GetService("ReplicatedStorage")',
		"",
		'local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes")',
		"",
		"local Remotes = {",
		'\tBuyEgg = RemotesFolder:WaitForChild("BuyEgg") :: RemoteFunction,',
		'\tHatchEgg = RemotesFolder:WaitForChild("HatchEgg") :: RemoteFunction,',
		'\tStateChanged = RemotesFolder:WaitForChild("StateChanged") :: RemoteEvent,',
		'\tRaid = RemotesFolder:WaitForChild("Raid") :: RemoteFunction,',
		'\tMerge = RemotesFolder:WaitForChild("Merge") :: RemoteFunction,',
		'\tClaimQuest = RemotesFolder:WaitForChild("ClaimQuest") :: RemoteFunction,',
		'\tSiegeState = RemotesFolder:WaitForChild("SiegeState") :: RemoteEvent,',
		'\tNotify = RemotesFolder:WaitForChild("Notify") :: RemoteEvent,',
		'\tStoreOpen = RemotesFolder:WaitForChild("StoreOpen") :: RemoteEvent,',
		'\tTutorialState = RemotesFolder:WaitForChild("TutorialState") :: RemoteEvent,',
		'\tRaidReplay = RemotesFolder:WaitForChild("RaidReplay") :: RemoteEvent,',
		"}",
		"",
		"return Remotes",
		"",
	}
	return table.concat(lines, "\n")
end

--- Renders src/shared/Messages.luau: server-side user-facing copy. Generic
--- wording (no roster-specific text needed by the genre's Messages contract).
function M.renderMessages(title: string): string
	local lines: { string } = {
		"--!strict",
		"-- Messages: " .. title .. "'s server-side user-facing copy, injected into the",
		"-- collect-raid genre Server runtime so the genre never hardcodes display text.",
		"-- Generated by forge plan.",
		"",
		'local Server = require("../../../../genres/collect-raid/module/runtime/Server")',
		"",
		"local Messages: Server.Messages = {",
		'\tprofileLocked = "Your profile is still locked by another server. Please rejoin.",',
		'\tprofileLoadFailed = "Could not load your profile. Please rejoin.",',
		'\tserverBoostActive = "Server Luck Boost active!",',
		"\trareHatchLocal = function(playerName: string, displayName: string): string",
		'\t\treturn string.format("%s hatched %s!", playerName, displayName)',
		"\tend,",
		"\trareHatchGlobal = function(playerName: string, displayName: string): string",
		'\t\treturn string.format("[Global] %s hatched %s!", playerName, displayName)',
		"\tend,",
		"\twrongTeamIncubator = function(teamName: string): string",
		'\t\treturn "That incubator belongs to the " .. teamName .. " team"',
		"\tend,",
		"\thatchFailed = function(reason: string): string",
		'\t\treturn "Hatch: " .. reason',
		"\tend,",
		'\traidOwnVault = "Raid the rival vault, not your own",',
		"\traidFailed = function(reason: string): string",
		'\t\treturn "Raid: " .. reason',
		"\tend,",
		'\tincubatorActionText = "Hatch",',
		"\tincubatorObjectText = function(index: number): string",
		'\t\treturn "Incubator " .. tostring(index)',
		"\tend,",
		'\tvaultActionText = "Raid",',
		"\tvaultObjectText = function(teamName: string): string",
		'\t\treturn teamName .. " Vault"',
		"\tend,",
		"}",
		"",
		"return Messages",
		"",
	}
	return table.concat(lines, "\n")
end

--- Renders src/shared/Copy.luau: HUD user-facing text, parametrized only by
--- title and the ScreenGui name (`--gui-name`, default "<Pascal>Gui").
function M.renderCopy(title: string, guiName: string): string
	local lines: { string } = {
		"--!strict",
		"-- Copy: " .. title .. "'s HUD user-facing text, injected into the",
		"-- collect-raid genre Hud runtime so the genre never hardcodes display text.",
		"-- Generated by forge plan.",
		"",
		'local Hud = require("../../../../genres/collect-raid/module/runtime/Hud")',
		"",
		"local Copy: Hud.Copy = {",
		string.format("\tguiName = %q,", guiName),
		string.format("\ttitle = %q,", title),
		'\tbuyEggsTitle = "Buy Eggs",',
		'\tmergeTitle = "Merge",',
		'\traidQuestsTitle = "Raid & Quests",',
		'\tstoreTitle = "Store",',
		'\tincubatorsHeader = "Incubators",',
		'\thatchOddsHeader = "Hatch Odds",',
		"\tcoinsLabel = function(coins: string): string",
		'\t\treturn "Coins: " .. coins',
		"\tend,",
		"\tcreaturesOwnedLabel = function(count: number): string",
		'\t\treturn string.format("Kaiju Owned: %d", count)',
		"\tend,",
		"\tvaultedLabel = function(count: number): string",
		'\t\treturn string.format("Vaulted: %d", count)',
		"\tend,",
		'\temptyInventoryHint = "Hatch an egg to get your first kaiju",',
		"\tnextSiegeLabel = function(clock: string): string",
		'\t\treturn "Next siege in " .. clock',
		"\tend,",
		"\tsiegeActiveLabel = function(clock: string): string",
		'\t\treturn "Siege ACTIVE " .. clock',
		"\tend,",
		"\tvaultCountsLabel = function(teamNames: { string }, counts: { [string]: number }): string",
		"\t\tlocal parts: { string } = {}",
		"\t\tfor _, teamName in teamNames do",
		'\t\t\ttable.insert(parts, string.format("%s vault: %d", teamName, counts[teamName] or 0))',
		"\t\tend",
		'\t\treturn table.concat(parts, " | ")',
		"\tend,",
		'\traidButtonText = "Raid rival vault",',
		"\traidResultText = function(reason: string): string",
		'\t\treturn "Raid: " .. reason',
		"\tend,",
		'\traidNothingReason = "nothing to grab",',
		"\tmergeButtonText = function(displayName: string): string",
		'\t\treturn string.format("Merge %s family", displayName)',
		"\tend,",
		"\tbuyButtonText = function(id: string, price: number): string",
		'\t\treturn string.format("Buy %s (%d Coins)", id, price)',
		"\tend,",
		"\tstoreButtonText = function(name: string, price: number): string",
		'\t\treturn string.format("%s - %d R$", name, price)',
		"\tend,",
		'\tstoreUnpublishedText = "Not available until published",',
		'\tinviteButtonText = "Invite Friends",',
		'\tinvitesUnavailableText = "Invites are not available here",',
		'\tdailyQuestsHeader = "Daily Quests",',
		'\tgamePassesHeader = "Game Passes",',
		'\tdevProductsHeader = "Developer Products",',
		'\tclaimButtonText = "Claim",',
		'\tclaimedButtonText = "Claimed",',
		"\tquestRowText = function(id: string, progress: number, target: number, reward: number): string",
		'\t\treturn string.format("%s %d/%d (+%d)", id, progress, target, reward)',
		"\tend,",
		"\thatchButtonText = function(index: number): string",
		'\t\treturn string.format("Hatch #%d", index)',
		"\tend,",
		"\thatchedPopText = function(creatureId: string): string",
		'\t\treturn "Hatched " .. creatureId .. "!"',
		"\tend,",
		"\tslotStatusText = function(index: number, sourceId: string, remaining: string): string",
		'\t\treturn string.format("Slot %d: %s (%s)", index, if sourceId ~= "" then sourceId else "Egg", remaining)',
		"\tend,",
		'\ttutorialPrefix = "Tutorial: ",',
		"\tisRareHatchNotify = function(text: string): boolean",
		'\t\treturn string.find(text, "hatched", 1, true) ~= nil and string.find(text, "Legendary", 1, true) == nil',
		"\tend,",
		"}",
		"",
		"return Copy",
		"",
	}
	return table.concat(lines, "\n")
end

-- Every cue AudioConfig references, so a planned pack never ships an empty SoundId.
-- Music and ambience render at 44.1 kHz like the SFX (22.05 kHz lost the highs).
local AUDIO_CUES = {
	{ key = "musicExplore", kind = "music", field = "mood", value = "explore", duration = 75, seed = 1001 },
	{ key = "musicSiege", kind = "music", field = "mood", value = "siege", duration = 70, seed = 1002 },
	{ key = "ambienceWind", kind = "ambience", field = "type", value = "wind", duration = 8, seed = 2101 },
	{ key = "ambienceBirds", kind = "ambience", field = "type", value = "birds", duration = 8, seed = 2102 },
	{ key = "sfxClick", kind = "sfx", field = "type", value = "click", duration = 0.12, seed = 3101 },
	{ key = "sfxCoin", kind = "sfx", field = "type", value = "coin", duration = 0.45, seed = 3102 },
	{ key = "sfxHatch", kind = "sfx", field = "type", value = "hatch", duration = 0.5, seed = 3103 },
	{ key = "sfxRare", kind = "sfx", field = "type", value = "rare", duration = 1, seed = 3104 },
	{ key = "sfxRaid", kind = "sfx", field = "type", value = "raid", duration = 0.9, seed = 3105 },
	{ key = "sfxError", kind = "sfx", field = "type", value = "error", duration = 0.35, seed = 3106 },
}

--- Renders assets/audio.yml with every cue the genre runtime plays. The pack
--- seed offsets each cue seed so different packs get different music.
function M.renderAudioYml(title: string, pack: string, seed: number): string
	local lines: { string } = {}
	add(lines, "# GENERATED by forge plan. `lune run cli/forge gen audio --pack " .. pack .. "` synthesises")
	add(lines, "# every cue for " .. title .. " with the pure core/domain/procgen DSP (no keys, no network).")
	add(lines, "#")
	add(lines, "# kind: music (mood explore|siege), sfx (type click|coin|hatch|rare|raid|error),")
	add(lines, "#       ambience (type wind|birds). duration is seconds.")
	add(lines, "cues:")
	for _, cue in AUDIO_CUES do
		add(lines, "  - key: " .. cue.key)
		add(lines, "    kind: " .. cue.kind)
		add(lines, "    " .. cue.field .. ": " .. cue.value)
		add(lines, "    duration: " .. fmtNum(cue.duration))
		add(lines, "    sampleRate: 44100")
		add(lines, "    seed: " .. tostring(cue.seed + seed * 10000))
	end
	return table.concat(lines, "\n") .. "\n"
end

--- Renders src/shared/AudioConfig.luau: sound cues and Notify/prompt text
--- classifiers. Cue keys are genre-generic and map 1:1 onto the Assets keys
--- `forge gen audio` always produces, so no roster data is needed here.
function M.renderAudioConfig(title: string, teams: { string }): string
	local rivals: { string } = {}
	for index, team in teams do
		local rival = teams[(index % #teams) + 1]
		table.insert(rivals, string.format("\t\t[%q] = %q,", team, rival))
	end

	local lines: { string } = {
		"--!strict",
		"-- AudioConfig: " .. title .. "'s sound cue table and Notify/prompt text",
		"-- classifiers, injected into the collect-raid genre Audio runtime so the",
		"-- genre never depends on this pack's copy. Generated by forge plan.",
		"",
		'local Assets = require("./Assets")',
		'local SoundBank = require("../../../../core/infra/audio/SoundBank")',
		'local Audio = require("../../../../genres/collect-raid/module/runtime/Audio")',
		"",
		"local cues: { [string]: SoundBank.Cue } = {",
		'\tuiClick = { soundId = Assets.sfxClick, volume = 0.45, playbackSpeed = 1.15, group = "UI" },',
		'\tcoin = { soundId = Assets.sfxClick, volume = 0.35, playbackSpeed = 1.4, group = "SFX" },',
		'\tplace = { soundId = Assets.sfxCoin, volume = 0.5, group = "SFX" },',
		'\thatch = { soundId = Assets.sfxHatch, volume = 0.6, group = "SFX" },',
		'\tmergeLow = { soundId = Assets.sfxRare, volume = 0.7, playbackSpeed = 0.85, group = "SFX" },',
		'\tmergeHigh = { soundId = Assets.sfxHatch, volume = 0.6, playbackSpeed = 1.4, group = "SFX" },',
		'\tquestClaim = { soundId = Assets.sfxRare, volume = 0.65, playbackSpeed = 1.1, group = "SFX" },',
		'\tcoinBig = { soundId = Assets.sfxCoin, volume = 0.6, playbackSpeed = 1.2, group = "SFX" },',
		'\traidMiss = { soundId = Assets.sfxError, volume = 0.45, playbackSpeed = 1.2, group = "SFX" },',
		'\tfanfare = { soundId = Assets.sfxRare, volume = 0.7, group = "SFX" },',
		'\traid = { soundId = Assets.sfxRaid, volume = 0.7, group = "SFX" },',
		'\terror = { soundId = Assets.sfxError, volume = 0.4, group = "UI" },',
		'\tsiegeStart = { soundId = Assets.sfxRaid, volume = 0.8, playbackSpeed = 0.6, group = "SFX" },',
		'\tsiegeEnd = { soundId = Assets.sfxError, volume = 0.5, playbackSpeed = 0.75, group = "SFX" },',
		'\ttutorial = { soundId = Assets.sfxRare, volume = 0.45, playbackSpeed = 1.35, group = "UI" },',
		'\tpromptHatch = { soundId = Assets.sfxHatch, volume = 0.5, playbackSpeed = 1.25, group = "SFX" },',
		'\tpromptRaid = { soundId = Assets.sfxRaid, volume = 0.5, playbackSpeed = 1.4, group = "SFX" },',
		"\tambienceWind = {",
		"\t\tsoundId = Assets.ambienceWind,",
		"\t\tvolume = 0.12,",
		"\t\tplaybackSpeed = 0.55,",
		"\t\tlooped = true,",
		'\t\tgroup = "SFX",',
		"\t},",
		"\tambienceBirds = {",
		"\t\tsoundId = Assets.ambienceBirds,",
		"\t\tvolume = 0.05,",
		"\t\tplaybackSpeed = 1.7,",
		"\t\tlooped = true,",
		'\t\tgroup = "SFX",',
		"\t},",
		"}",
		"",
		"local notifyClassifiers: Audio.NotifyClassifiers = {",
		"\tisRareHatch = function(text: string): boolean",
		'\t\treturn string.find(text, "hatched", 1, true) ~= nil',
		"\tend,",
		"\tisHatchFailure = function(text: string): boolean",
		'\t\treturn string.find(text, "Hatch:", 1, true) == 1',
		"\tend,",
		"\tisRaidText = function(text: string): boolean",
		'\t\treturn string.find(text, "Raid", 1, true) ~= nil',
		"\tend,",
		"}",
		"",
		"local promptClassifiers: Audio.PromptClassifiers = {",
		"\tisHatchAction = function(actionText: string): boolean",
		'\t\treturn string.find(string.lower(actionText), "hatch", 1, true) ~= nil',
		"\tend,",
		"\tisRaidAction = function(actionText: string): boolean",
		'\t\treturn string.find(string.lower(actionText), "raid", 1, true) ~= nil',
		"\tend,",
		"}",
		"",
		"local AudioConfig = {",
		"\tcues = cues,",
		"\tnotifyClassifiers = notifyClassifiers,",
		"\tpromptClassifiers = promptClassifiers,",
		'\tmusicTracks = { explore = "musicExplore", siege = "musicSiege" },',
		"\tteamRivals = {\n" .. table.concat(rivals, "\n") .. "\n\t},",
		"}",
		"",
		"return AudioConfig",
		"",
	}
	return table.concat(lines, "\n")
end

--- Renders src/shared/CreatureModels.luau: thin ProcAssets-backed model
--- builders plus a rarity lookup. Every roster creature/egg always has a
--- procgen spec (assets/procgen.yml, written by renderProcgen), so this module
--- never needs the hand-authored Part fallback packs like Kaiju once carried.
function M.renderCreatureModels(roster: Roster): string
	local lines: { string } = {
		"--!strict",
		"-- CreatureModels: thin ProcAssets-backed model builders. Generated by forge plan.",
		"-- Every roster creature/egg has a procedural spec (assets/procgen.yml), so",
		"-- buildKaiju/buildEgg always resolve through ProcAssets; the rarity table",
		"-- below is the only hand data (used for showcase scale and Fx aura color).",
		"",
		'local ProcAssets = require("../../../../core/infra/render/ProcAssets")',
		'local ProcAssetsSpecs = require("./ProcAssets")',
		"",
		"local RARITY: { [string]: string } = {",
	}
	for _, creature in roster.creatures do
		table.insert(lines, string.format("\t[%q] = %q,", creature.id, creature.rarity))
	end
	local scaleLines: { string } = { "local SCALE: { [string]: number } = {" }
	for _, creature in roster.creatures do
		table.insert(scaleLines, string.format("\t[%q] = %s,", creature.id, fmtNum(creature.scale)))
	end
	table.insert(scaleLines, "}")

	local tail: { string } = {
		"}",
		"",
	}
	for _, line in scaleLines do
		table.insert(tail, line)
	end
	table.insert(tail, "")
	table.insert(tail, "local CreatureModels = {}")
	table.insert(tail, "")
	table.insert(tail, "--- Builds a creature's showcase model, scaled so its largest extent reads at")
	table.insert(tail, "--- 7 studs for a Common (bigger rarities scale up per SCALE).")
	table.insert(tail, "function CreatureModels.buildKaiju(kaijuId: string): Model")
	table.insert(tail, "\tlocal model = ProcAssets.build(ProcAssetsSpecs, kaijuId, kaijuId)")
	table.insert(tail, "\tif model == nil then")
	table.insert(tail, '\t\terror("CreatureModels.buildKaiju: no procgen spec for \'" .. kaijuId .. "\'")')
	table.insert(tail, "\tend")
	table.insert(tail, '\tmodel:SetAttribute("KaijuId", kaijuId)')
	table.insert(tail, "\tlocal scale = SCALE[kaijuId] or 1")
	table.insert(tail, "\tlocal extents = model:GetExtentsSize()")
	table.insert(tail, "\tlocal largest = math.max(extents.X, extents.Y, extents.Z)")
	table.insert(tail, "\tif largest > 1e-4 then")
	table.insert(tail, "\t\tmodel:ScaleTo(7 * scale / largest)")
	table.insert(tail, "\tend")
	table.insert(tail, "\treturn model")
	table.insert(tail, "end")
	table.insert(tail, "")
	table.insert(tail, "--- Builds an egg's showcase model (forceParts: eggs never use EditableMesh),")
	table.insert(tail, "--- scaled to read 3 studs tall at the incubator point.")
	table.insert(tail, "function CreatureModels.buildEgg(eggId: string): Model")
	table.insert(tail, "\tlocal model = ProcAssets.build(ProcAssetsSpecs, eggId, eggId, { forceParts = true })")
	table.insert(tail, "\tif model == nil then")
	table.insert(tail, '\t\terror("CreatureModels.buildEgg: no procgen spec for \'" .. eggId .. "\'")')
	table.insert(tail, "\tend")
	table.insert(tail, '\tmodel:SetAttribute("EggId", eggId)')
	table.insert(tail, "\tlocal extents = model:GetExtentsSize()")
	table.insert(tail, "\tlocal largest = math.max(extents.X, extents.Y, extents.Z)")
	table.insert(tail, "\tif largest > 1e-4 then")
	table.insert(tail, "\t\tmodel:ScaleTo(3 / largest)")
	table.insert(tail, "\tend")
	table.insert(tail, "\treturn model")
	table.insert(tail, "end")
	table.insert(tail, "")
	table.insert(tail, "function CreatureModels.rarityOf(kaijuId: string): string")
	table.insert(tail, '\treturn RARITY[kaijuId] or "Common"')
	table.insert(tail, "end")
	table.insert(tail, "")
	table.insert(tail, "return CreatureModels")
	table.insert(tail, "")

	for _, line in tail do
		table.insert(lines, line)
	end
	return table.concat(lines, "\n")
end

--- Renders src/shared/Fx.luau: particle/sound/UI feedback helpers. Only the
--- rarity color table is roster-derived; the rest is genre-generic engine code.
function M.renderFx(roster: Roster): string
	local seenRarities: { [string]: boolean } = {}
	local rarities: { string } = {}
	for _, creature in roster.creatures do
		if not seenRarities[creature.rarity] then
			seenRarities[creature.rarity] = true
			table.insert(rarities, creature.rarity)
		end
	end
	local RARITY_COLORS: { [string]: { number } } = {
		Common = { 200, 200, 200 },
		Rare = { 80, 160, 255 },
		Legendary = { 255, 190, 40 },
		Mythic = { 255, 80, 200 },
	}

	local lines: { string } = {
		"--!strict",
		"-- Fx: particle/sound/UI feedback helpers. Generated by forge plan; only the",
		"-- rarity color table below is roster-derived, the rest is genre-generic.",
		"local Fx = {}",
		'local TweenService = game:GetService("TweenService")',
		'local SoundService = game:GetService("SoundService")',
		'local Debris = game:GetService("Debris")',
		'local Assets = require("./Assets")',
		"",
		"Fx.SOUNDS = {",
		"\tclick = Assets.sfxClick,",
		"\thatch = Assets.sfxHatch,",
		"\trare = Assets.sfxRare,",
		"\tcoin = Assets.sfxCoin,",
		"\traid = Assets.sfxRaid,",
		"\terror = Assets.sfxError,",
		"}",
		"",
		"function Fx.play(name: string, volume: number?): ()",
		"\tlocal soundId = Fx.SOUNDS[name]",
		'\tif soundId == nil or soundId == "" then',
		"\t\treturn",
		"\tend",
		"",
		'\tlocal sound = Instance.new("Sound")',
		"\tsound.SoundId = soundId",
		"\tsound.Volume = volume or 0.5",
		"\tsound.Parent = SoundService",
		"\tsound:Play()",
		"\tDebris:AddItem(sound, 6)",
		"end",
		"",
		"function Fx.burst(position: Vector3, color: Color3, count: number?): ()",
		'\tlocal part = Instance.new("Part")',
		"\tpart.Anchored = true",
		"\tpart.CanCollide = false",
		"\tpart.Transparency = 1",
		"\tpart.Size = Vector3.new(1, 1, 1)",
		"\tpart.Position = position",
		"\tpart.Parent = workspace",
		"",
		'\tlocal emitter = Instance.new("ParticleEmitter")',
		"\temitter.Color = ColorSequence.new(color)",
		"\temitter.LightEmission = 0.8",
		"\temitter.Speed = NumberRange.new(8, 16)",
		"\temitter.Lifetime = NumberRange.new(0.6, 1.2)",
		"\temitter.SpreadAngle = Vector2.new(180, 180)",
		"\temitter.Size = NumberSequence.new({",
		"\t\tNumberSequenceKeypoint.new(0, 1.2),",
		"\t\tNumberSequenceKeypoint.new(1, 0),",
		"\t})",
		"\temitter.Rate = 0",
		"\temitter.Parent = part",
		"",
		"\temitter:Emit(count or 40)",
		"\tDebris:AddItem(part, 3)",
		"end",
		"",
		"function Fx.popText(parent: GuiBase2d, text: string, color: Color3): ()",
		'\tlocal label = Instance.new("TextLabel")',
		"\tlabel.Text = text",
		"\tlabel.Font = Enum.Font.GothamBold",
		"\tlabel.TextSize = 28",
		"\tlabel.TextColor3 = color",
		"\tlabel.TextStrokeTransparency = 0.4",
		"\tlabel.BackgroundTransparency = 1",
		"\tlabel.Size = UDim2.fromOffset(300, 40)",
		"\tlabel.AnchorPoint = Vector2.new(0.5, 0.5)",
		"\tlabel.Position = UDim2.fromScale(0.5, 0.45)",
		"\tlabel.Parent = parent",
		"",
		"\tlocal tween =",
		"\t\tTweenService:Create(label, TweenInfo.new(1.2), { Position = UDim2.fromScale(0.5, 0.35), TextTransparency = 1 })",
		"\ttween:Play()",
		"\tDebris:AddItem(label, 1.5)",
		"end",
		"",
		"function Fx.flash(screenGui: ScreenGui, color: Color3): ()",
		'\tlocal frame = Instance.new("Frame")',
		"\tframe.BackgroundColor3 = color",
		"\tframe.BackgroundTransparency = 0.4",
		"\tframe.ZIndex = 50",
		"\tframe.Size = UDim2.fromScale(1, 1)",
		"\tframe.Parent = screenGui",
		"",
		"\tlocal tween = TweenService:Create(frame, TweenInfo.new(0.5), { BackgroundTransparency = 1 })",
		"\ttween:Play()",
		"\tDebris:AddItem(frame, 0.6)",
		"end",
		"",
		"function Fx.rarityColor(rarity: string): Color3",
	}
	for _, rarity in rarities do
		local color = RARITY_COLORS[rarity] or { 255, 255, 255 }
		add(lines, string.format("\tif rarity == %q then", rarity))
		add(lines, string.format("\t\treturn Color3.fromRGB(%d, %d, %d)", color[1], color[2], color[3]))
		add(lines, "\tend")
	end
	add(lines, "\treturn Color3.new(1, 1, 1)")
	add(lines, "end")
	add(lines, "")
	add(lines, "return Fx")
	add(lines, "")
	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Rendering: world data (WorldLayout, WorldTheme, World.luau), the pack's
-- thin server/client entry points, default.project.json, liveops.yml,
-- deploy.yml, locale/strings.csv, and the smoke suite. All are pure functions
-- of (economy/roster/identity flags), so the same plan args always render
-- byte-identical files.
-- ---------------------------------------------------------------------------

local BASE_X = 70
local INCUBATORS_PER_TEAM = 4

--- Renders src/shared/WorldLayout.luau: two-or-more team bases arranged around
--- a central arena, one incubator per creature tier, and a parade slot per
--- creature so every roster creature has somewhere to stand. Pure Luau data,
--- no Roblox APIs (WorldBuilder turns it into the actual world).
function M.renderWorldLayout(
	roster: Roster,
	title: string,
	teams: { string },
	pascal: string,
	requestedIncubators: number?
): string
	local incubatorsPerTeam = math.max(#roster.creatures, requestedIncubators or INCUBATORS_PER_TEAM)
	local paradeSlots = math.max(#roster.creatures, 3)
	local lines: { string } = {
		"--!strict",
		"-- WorldLayout: pure world data for " .. title .. " (no Roblox APIs). Generated by",
		"-- forge plan; WorldBuilder turns this into the arena, team bases with",
		"-- incubators, and parade slots.",
		"",
		"export type Vec = { x: number, y: number, z: number }",
		"",
		"export type ParadeLayout = {",
		"\tname: string,",
		"\tpositions: { Vec },",
		"}",
		"",
		"export type BaseLayout = {",
		"\tteam: string,",
		"\tcenter: Vec,",
		"\tsize: Vec,",
		"\tspawn: Vec,",
		"\tspawnTeamColor: string,",
		"\tincubators: { Vec },",
		"\tvault: Vec,",
		"\tparade: ParadeLayout,",
		"\tshop: Vec,",
		"\tcolor: { r: number, g: number, b: number },",
		"}",
		"",
		"export type ArenaLayout = {",
		"\tcenter: Vec,",
		"\tradius: number,",
		"\tcovers: { { position: Vec, size: Vec } },",
		"\ttorches: { Vec },",
		"}",
		"",
		"export type Decoration = {",
		"\tkind: string,",
		"\tposition: Vec,",
		"\tscale: Vec,",
		"\tseed: number,",
		"}",
		"",
		"export type Layout = {",
		"\tname: string,",
		"\tground: { cells: number, cellSize: number, originX: number, originZ: number, y: number, thickness: number },",
		"\tbases: { BaseLayout },",
		"\tarena: ArenaLayout,",
		"\tdecorations: { Decoration }?,",
		"\tflowers: { Decoration }?,",
		"}",
		"",
		string.format("local INCUBATORS_PER_TEAM = %d", incubatorsPerTeam),
		string.format("local PARADE_SLOTS = %d", paradeSlots),
		string.format("local BASE_X = %d", BASE_X),
		"",
		"local function vec(x: number, y: number, z: number): Vec",
		"\treturn { x = x, y = y, z = z }",
		"end",
		"",
	}

	add(lines, "local TEAM_COLORS: { [string]: string } = {")
	for index, teamName in teams do
		add(lines, string.format("\t[%q] = %q,", teamName, M.teamBrickColor(teamName, index)))
	end
	add(lines, "}")
	add(lines, "")

	local TEAM_RGB: { [string]: { number } } = TEAM_BRICK_RGB
	add(lines, "local TEAM_RGB: { [string]: { r: number, g: number, b: number } } = {")
	for index, teamName in teams do
		local brickColor = M.teamBrickColor(teamName, index)
		local color = TEAM_RGB[brickColor] or { 150, 150, 150 }
		add(lines, string.format("\t[%q] = { r = %d, g = %d, b = %d },", teamName, color[1], color[2], color[3]))
	end
	add(lines, "}")
	add(lines, "")

	-- TEAM_COLORS/TEAM_RGB must be defined above `base`, which reads them as
	-- upvalues; Luau locals are not visible to code written earlier in the file.
	-- Pure numeric trig (no CFrame/Vector3): WorldLayout is required by smoke.luau
	-- and specs, which run under Lune, where the Roblox math types do not exist.
	add(lines, "-- Bases sit evenly spaced around a ring of radius BASE_X * (team count / 2),")
	add(lines, "-- so any number of teams (2, 3, 4, ...) gets a fair, symmetric layout.")
	add(lines, "local function base(team: string, index: number, teamCount: number): BaseLayout")
	add(lines, "\tlocal angle = (index - 1) * (2 * math.pi / teamCount)")
	add(lines, "\tlocal ringRadius = BASE_X * math.max(1, teamCount / 2)")
	add(lines, "\tlocal cx = math.cos(angle) * ringRadius")
	add(lines, "\tlocal cz = math.sin(angle) * ringRadius")
	add(lines, "\t-- outward: unit vector from the ring center to this base; inward is its")
	add(lines, '\t-- opposite, and (-inwardZ, inwardX) is the perpendicular ("sideways") axis.')
	add(lines, "\tlocal outwardX, outwardZ = math.cos(angle), math.sin(angle)")
	add(lines, "\tlocal inwardX, inwardZ = -outwardX, -outwardZ")
	add(lines, "\tlocal sideX, sideZ = -inwardZ, inwardX")
	add(lines, "")
	add(lines, "\t-- Two rows (inward -6 and 5) instead of one: both stay well clear of the")
	add(lines, "\t-- vault at inward 22 and the shop at inward 16/side 20, and the 10.5-stud")
	add(lines, "\t-- pitch keeps every pair at least 10 studs apart with float headroom")
	add(lines, "\t-- (exactly 10 can round under the limit). A pedestal is a 9-stud cylinder")
	add(lines, "\t-- (radius 4.5); for a row offset (inward, side), its worst-case distance")
	add(lines, "\t-- from the base center over every possible base rotation is")
	add(lines, "\t-- sqrt(inward^2 + side^2): the platform is axis-aligned in world space")
	add(lines, "\t-- (WorldBuilder places it with `Position`, not a rotated `CFrame`), so a")
	add(lines, "\t-- diagonal base angle (e.g. the 120/240 degree bases in a 3-team layout)")
	add(lines, "\t-- can swing a row's local offset onto either world axis. HALF below is")
	add(lines, "\t-- sized against that worst case, not just the axis-aligned one.")
	add(lines, "\tlocal incubators: { Vec } = {}")
	add(lines, "\tlocal frontCount = math.ceil(INCUBATORS_PER_TEAM / 2)")
	add(lines, "\tlocal backCount = INCUBATORS_PER_TEAM - frontCount")
	add(lines, "\tfor i = 1, INCUBATORS_PER_TEAM do")
	add(lines, "\t\tlocal rowCount = if i <= frontCount then frontCount else backCount")
	add(lines, "\t\tlocal seat = if i <= frontCount then i else i - frontCount")
	add(lines, "\t\tlocal rowInward = if i <= frontCount then -6 else 5")
	add(lines, "\t\tlocal t = (-(rowCount - 1) / 2 + (seat - 1)) * 10.5")
	add(lines, "\t\tlocal offsetX, offsetZ = inwardX * rowInward + sideX * t, inwardZ * rowInward + sideZ * t")
	add(lines, "\t\ttable.insert(incubators, vec(cx + offsetX, 1, cz + offsetZ))")
	add(lines, "\tend")
	add(lines, "")
	add(lines, "\t-- Platform half-width: at least 28 (the original 56-stud platform), and")
	add(lines, "\t-- large enough that every pedestal's worst-case radius above still clears")
	add(lines, "\t-- the edge by a 2-stud margin. 6 (not 5) is used for both rows' inward")
	add(lines, "\t-- magnitude since the formula only needs a safe upper bound.")
	add(lines, "\tlocal rowRadius = math.sqrt(36 + ((math.max(frontCount, backCount) - 1) / 2 * 10.5) ^ 2)")
	add(lines, "\tlocal half = math.max(28, rowRadius + 4.5 + 2)")
	add(lines, "")
	add(lines, "\tlocal positions: { Vec } = {}")
	add(lines, "\tfor k = 1, PARADE_SLOTS do")
	add(lines, "\t\tlocal t = -16 + (k - 1) * 16")
	add(lines, "\t\tlocal offsetX, offsetZ = outwardX * 16 + sideX * t, outwardZ * 16 + sideZ * t")
	add(lines, "\t\ttable.insert(positions, vec(cx + offsetX, 1, cz + offsetZ))")
	add(lines, "\tend")
	add(lines, "")
	add(lines, "\t-- Spawn sits at the map edge (outward, away from the arena); the vault sits")
	add(lines, "\t-- closer in (inward), so raiders always have farther to walk than defenders.")
	add(lines, "\tlocal spawnOffsetX, spawnOffsetZ = outwardX * 20, outwardZ * 20")
	add(lines, "\tlocal vaultOffsetX, vaultOffsetZ = inwardX * 22, inwardZ * 22")
	add(lines, "\tlocal shopOffsetX, shopOffsetZ = inwardX * 16 + sideX * 20, inwardZ * 16 + sideZ * 20")
	add(lines, "")
	add(lines, "\treturn {")
	add(lines, "\t\tteam = team,")
	add(lines, "\t\tcenter = vec(cx, 0, cz),")
	add(lines, "\t\tsize = vec(half * 2, 8, half * 2),")
	add(lines, "\t\tspawn = vec(cx + spawnOffsetX, 3, cz + spawnOffsetZ),")
	add(lines, '\t\tspawnTeamColor = TEAM_COLORS[team] or "Medium stone grey",')
	add(lines, "\t\tincubators = incubators,")
	add(lines, "\t\tvault = vec(cx + vaultOffsetX, 2, cz + vaultOffsetZ),")
	add(lines, '\t\tparade = { name = "' .. pascal .. 'Slot", positions = positions },')
	add(lines, "\t\tshop = vec(cx + shopOffsetX, 1, cz + shopOffsetZ),")
	add(lines, "\t\tcolor = TEAM_RGB[team] or { r = 150, g = 150, b = 150 },")
	add(lines, "\t}")
	add(lines, "end")
	add(lines, "")

	add(lines, "local WorldLayout = {}")
	add(lines, "")
	add(lines, "WorldLayout.name = " .. string.format("%q", pascal .. "World"))
	add(
		lines,
		"WorldLayout.ground = { cells = 16, cellSize = 25, originX = -200, originZ = -200, y = -0.5, thickness = 1 }"
	)
	add(lines, "")
	add(lines, "local function arena(): ArenaLayout")
	add(lines, "\treturn {")
	add(lines, "\t\tcenter = vec(0, 0, 0),")
	add(lines, "\t\tradius = 40,")
	add(lines, "\t\tcovers = {")
	add(lines, "\t\t\t{ position = vec(20, 3, 20), size = vec(8, 6, 2) },")
	add(lines, "\t\t\t{ position = vec(-20, 3, -20), size = vec(8, 6, 2) },")
	add(lines, "\t\t\t{ position = vec(20, 3, -20), size = vec(8, 6, 2) },")
	add(lines, "\t\t\t{ position = vec(-20, 3, 20), size = vec(8, 6, 2) },")
	add(lines, "\t\t},")
	add(lines, "\t\ttorches = { vec(40, 0, 0), vec(-40, 0, 0), vec(0, 0, 40), vec(0, 0, -40) },")
	add(lines, "\t}")
	add(lines, "end")
	add(lines, "")

	add(lines, "local bases: { BaseLayout } = {}")
	add(lines, "local TEAMS = {")
	for _, teamName in teams do
		add(lines, string.format("\t%q,", teamName))
	end
	add(lines, "}")
	add(lines, "for index, teamName in TEAMS do")
	add(lines, "\ttable.insert(bases, base(teamName, index, #TEAMS))")
	add(lines, "end")
	add(lines, "")
	add(lines, "local ARENA = arena()")
	add(lines, "")

	-- Decoration scatter: WorldBuilderMath.scatter turns pure band specs into a
	-- deterministic Poisson-disk-ish layout, kept off the arena floor, every base,
	-- every spawn, and the base-to-arena lanes, matching the density and kind mix
	-- of the original hand-authored Kaiju world (91 decor: trees/rocks/crystals/
	-- crates, 40 flower patches) so a generated world never reads emptier.
	add(lines, 'local WorldBuilderMath = require("../../../../genres/collect-raid/module/WorldBuilderMath")')
	add(lines, "")
	add(lines, "local DECOR_REGION = { minX = -190, maxX = 190, minZ = -190, maxZ = 190 }")
	add(lines, "")
	add(lines, "-- Exclusion zones keep props off the arena, every base, every spawn, and the")
	add(lines, "-- base-to-arena lanes.")
	add(lines, "local function exclusionZones(): { WorldBuilderMath.ScatterZone }")
	add(lines, "\tlocal zones: { WorldBuilderMath.ScatterZone } = {")
	add(lines, "\t\t{ x = ARENA.center.x, z = ARENA.center.z, inner = 0, outer = ARENA.radius + 20 },")
	add(lines, "\t}")
	add(lines, "\tfor _, b in bases do")
	add(lines, "\t\tlocal half = b.size.x / 2")
	add(lines, "\t\tlocal dx, dz = b.center.x - ARENA.center.x, b.center.z - ARENA.center.z")
	add(lines, "\t\tlocal len = math.sqrt(dx * dx + dz * dz)")
	add(lines, "\t\tlocal dirX, dirZ = if len > 1e-4 then dx / len else 1, if len > 1e-4 then dz / len else 0")
	add(lines, "\t\ttable.insert(zones, { x = b.center.x, z = b.center.z, inner = 0, outer = half + 19 })")
	add(lines, "\t\ttable.insert(zones, { x = b.spawn.x, z = b.spawn.z, inner = 0, outer = 14 })")
	add(lines, "\t\tfor k = 0, 1 do")
	add(lines, "\t\t\ttable.insert(zones, {")
	add(lines, "\t\t\t\tx = b.center.x - dirX * (half + 5 + k * 12),")
	add(lines, "\t\t\t\tz = b.center.z - dirZ * (half + 5 + k * 12),")
	add(lines, "\t\t\t\tinner = 0,")
	add(lines, "\t\t\t\touter = 12,")
	add(lines, "\t\t\t})")
	add(lines, "\t\tend")
	add(lines, "\tend")
	add(lines, "\treturn zones")
	add(lines, "end")
	add(lines, "")
	add(lines, "local function baseRings(inner: number, outer: number): { WorldBuilderMath.ScatterZone }")
	add(lines, "\tlocal zones: { WorldBuilderMath.ScatterZone } = {}")
	add(lines, "\tfor _, b in bases do")
	add(lines, "\t\ttable.insert(zones, { x = b.center.x, z = b.center.z, inner = inner, outer = outer })")
	add(lines, "\tend")
	add(lines, "\treturn zones")
	add(lines, "end")
	add(lines, "")
	add(lines, "local CRYSTAL_ZONES: { WorldBuilderMath.ScatterZone } = {")
	add(lines, "\t{ x = ARENA.center.x, z = ARENA.center.z, inner = ARENA.radius + 32, outer = ARENA.radius + 60 },")
	add(lines, "}")
	add(lines, "for _, zone in baseRings(66, 92) do")
	add(lines, "\ttable.insert(CRYSTAL_ZONES, zone)")
	add(lines, "end")
	add(lines, "")
	add(lines, "local DECOR_SPEC: WorldBuilderMath.ScatterSpec = {")
	add(lines, "\tregion = DECOR_REGION,")
	add(lines, "\texclusions = exclusionZones(),")
	add(lines, "\tbands = {")
	add(lines, "\t\t{")
	add(lines, '\t\t\tkind = "Tree",')
	add(lines, "\t\t\tcount = 41,")
	add(lines, "\t\t\tminSpacing = 16,")
	add(lines, "\t\t\tscaleMin = 8,")
	add(lines, "\t\t\tscaleMax = 14,")
	add(lines, "\t\t\tyFactor = 0.95,")
	add(lines, "\t\t\tedgeBias = 0.85,")
	add(lines, "\t\t\tedgeWidth = 95,")
	add(lines, "\t\t},")
	add(lines, "\t\t{")
	add(lines, '\t\t\tkind = "Rock",')
	add(lines, "\t\t\tcount = 28,")
	add(lines, "\t\t\tminSpacing = 10,")
	add(lines, "\t\t\tscaleMin = 3,")
	add(lines, "\t\t\tscaleMax = 7,")
	add(lines, "\t\t\tyFactor = 0.55,")
	add(lines, "\t\t\tedgeBias = 0.35,")
	add(lines, "\t\t\tedgeWidth = 70,")
	add(lines, "\t\t},")
	add(lines, "\t\t{")
	add(lines, '\t\t\tkind = "Crystal",')
	add(lines, "\t\t\tcount = 13,")
	add(lines, "\t\t\tminSpacing = 8,")
	add(lines, "\t\t\tscaleMin = 3,")
	add(lines, "\t\t\tscaleMax = 6,")
	add(lines, "\t\t\tyFactor = 0.9,")
	add(lines, "\t\t\tattractors = CRYSTAL_ZONES,")
	add(lines, "\t\t\tattractorChance = 0.85,")
	add(lines, "\t\t},")
	add(lines, "\t\t{")
	add(lines, '\t\t\tkind = "Crate",')
	add(lines, "\t\t\tcount = 9,")
	add(lines, "\t\t\tminSpacing = 8,")
	add(lines, "\t\t\tscaleMin = 3,")
	add(lines, "\t\t\tscaleMax = 4,")
	add(lines, "\t\t\tyFactor = 0.85,")
	add(lines, "\t\t\tattractors = baseRings(66, 96),")
	add(lines, "\t\t\tattractorChance = 0.9,")
	add(lines, "\t\t},")
	add(lines, "\t},")
	add(lines, "\tmaxAttempts = 4000,")
	add(lines, "}")
	add(lines, "")
	add(lines, "-- Trees 45% / rocks 30% / crystals 15% / crates 10%, 91 total.")
	add(lines, "local decorations = WorldBuilderMath.scatter(DECOR_SPEC, 20260929)")
	add(lines, "")
	add(lines, "local FLOWER_SPEC: WorldBuilderMath.ScatterSpec = {")
	add(lines, "\tregion = DECOR_REGION,")
	add(lines, "\texclusions = exclusionZones(),")
	add(lines, "\tbands = {")
	add(lines, "\t\t{")
	add(lines, '\t\t\tkind = "Flower",')
	add(lines, "\t\t\tcount = 40,")
	add(lines, "\t\t\tminSpacing = 13,")
	add(lines, "\t\t\tscaleMin = 1.5,")
	add(lines, "\t\t\tscaleMax = 2.5,")
	add(lines, "\t\t\tyFactor = 0.4,")
	add(lines, "\t\t\tedgeBias = 0.2,")
	add(lines, "\t\t\tedgeWidth = 60,")
	add(lines, "\t\t},")
	add(lines, "\t},")
	add(lines, "\tmaxAttempts = 4000,")
	add(lines, "}")
	add(lines, "")
	add(lines, "local flowers = WorldBuilderMath.scatter(FLOWER_SPEC, 76543)")
	add(lines, "")

	add(lines, "WorldLayout.layout = ({")
	add(lines, "\tname = WorldLayout.name,")
	add(lines, "\tground = WorldLayout.ground,")
	add(lines, "\tbases = bases,")
	add(lines, "\tarena = ARENA,")
	add(lines, "\tdecorations = decorations,")
	add(lines, "\tflowers = flowers,")
	add(lines, "} :: Layout)")
	add(lines, "")
	add(lines, "return WorldLayout")
	add(lines, "")
	return table.concat(lines, "\n")
end

--- Renders src/shared/WorldTheme.luau: palette, materials, and lighting handed
--- to the collect-raid WorldBuilder. Roster-derived only in the accent color
--- (the rarest creature's accent), so the world reads as belonging to this
--- pack's roster without hand authorship.
function M.renderWorldTheme(roster: Roster, title: string, teams: { string }): string
	local accent = roster.creatures[1].accent
	for _, creature in roster.creatures do
		if creature.rarity == "Legendary" then
			accent = creature.accent
			break
		end
	end
	local lines: { string } = {
		"--!strict",
		"-- WorldTheme: palette, materials, and lighting for " .. title .. ", handed to the",
		"-- collect-raid WorldBuilder. Generated by forge plan; the accent color comes from",
		"-- the roster's rarest creature so the world reads as belonging to this pack.",
		"",
		"local WorldTheme = {",
		"\tpalette = {",
		"\t\tground = { Color3.fromRGB(96, 156, 88), Color3.fromRGB(84, 142, 78) },",
		"\t\tterrainGrass = Color3.fromRGB(96, 156, 88),",
		"\t\tterrainRock = Color3.fromRGB(124, 120, 112),",
		"\t\tsand = Color3.fromRGB(214, 197, 148),",
		"\t\twater = Color3.fromRGB(52, 122, 168),",
		"\t\tpath = Color3.fromRGB(170, 168, 160),",
	}
	for index, teamName in teams do
		local brickColor = M.teamBrickColor(teamName, index)
		local color = TEAM_BRICK_RGB[brickColor] or { 150, 150, 150 }
		add(
			lines,
			string.format(
				"\t\t[%q] = Color3.fromRGB(%d, %d, %d),",
				string.lower(teamName),
				color[1],
				color[2],
				color[3]
			)
		)
	end
	add(lines, string.format("\t\taccent = Color3.fromRGB(%d, %d, %d),", accent[1], accent[2], accent[3]))
	add(lines, "\t\tplatform = Color3.fromRGB(112, 112, 122),")
	add(lines, "\t\tmetal = Color3.fromRGB(70, 70, 80),")
	add(lines, "\t\tglass = Color3.fromRGB(180, 220, 255),")
	add(lines, "\t\tslot = Color3.fromRGB(205, 205, 214),")
	add(lines, "\t\tcrate = Color3.fromRGB(92, 92, 102),")
	add(lines, "\t\twood = Color3.fromRGB(160, 110, 60),")
	add(lines, "\t\tarena = Color3.fromRGB(150, 140, 130),")
	add(lines, "\t\tarenaLine = Color3.fromRGB(245, 245, 235),")
	add(lines, "\t\tcover = Color3.fromRGB(140, 90, 70),")
	add(lines, "\t\tdecoration = Color3.fromRGB(120, 120, 115),")
	add(lines, "\t\tfence = Color3.fromRGB(72, 72, 82),")
	add(lines, "\t\tbanner = Color3.fromRGB(238, 238, 244),")
	add(lines, "\t\tflag = Color3.fromRGB(238, 238, 244),")
	add(lines, "\t\ttorchWood = Color3.fromRGB(122, 82, 46),")
	add(lines, "\t\tflowers = {")
	add(lines, "\t\t\tColor3.fromRGB(255, 168, 200),")
	add(lines, "\t\t\tColor3.fromRGB(255, 232, 140),")
	add(lines, "\t\t\tColor3.fromRGB(198, 170, 245),")
	add(lines, "\t\t},")
	add(lines, "\t},")
	add(lines, "\tmaterials = {")
	add(lines, "\t\tground = Enum.Material.Grass,")
	add(lines, "\t\tterrainGrass = Enum.Material.Grass,")
	add(lines, "\t\tterrainRock = Enum.Material.Rock,")
	add(lines, "\t\tsand = Enum.Material.Sand,")
	add(lines, "\t\tpath = Enum.Material.Cobblestone,")
	add(lines, "\t\tplatform = Enum.Material.Slate,")
	add(lines, "\t\ttrim = Enum.Material.Neon,")
	add(lines, "\t\tmetal = Enum.Material.Metal,")
	add(lines, "\t\tglass = Enum.Material.Glass,")
	add(lines, "\t\tcrate = Enum.Material.DiamondPlate,")
	add(lines, "\t\tslot = Enum.Material.SmoothPlastic,")
	add(lines, "\t\tshop = Enum.Material.WoodPlanks,")
	add(lines, "\t\tarena = Enum.Material.Concrete,")
	add(lines, "\t\tarenaLine = Enum.Material.Neon,")
	add(lines, "\t\tcover = Enum.Material.Brick,")
	add(lines, "\t\ttorch = Enum.Material.WoodPlanks,")
	add(lines, "\t\tdecoration = Enum.Material.Rock,")
	add(lines, "\t\tfence = Enum.Material.Metal,")
	add(lines, "\t\tbanner = Enum.Material.Fabric,")
	add(lines, "\t\tflag = Enum.Material.Fabric,")
	add(lines, "\t\tpedestal = Enum.Material.Concrete,")
	add(lines, "\t},")
	add(lines, "\tparticles = {")
	add(lines, '\t\tsparkle = "rbxasset://textures/particles/sparkles_main.dds",')
	add(lines, '\t\tglow = "rbxasset://textures/sparkle.png",')
	add(lines, '\t\tfirefly = "rbxasset://textures/particles/sparkles_main.dds",')
	add(lines, '\t\tdust = "rbxasset://textures/sparkle.png",')
	add(lines, "\t},")
	add(lines, "\tterrain = {")
	add(lines, "\t\tenabled = true,")
	add(lines, "\t\thalf = 360,")
	add(lines, "\t\tflatHalf = 210,")
	add(lines, "\t\tcellSize = 16,")
	add(lines, "\t\tbaseY = 0,")
	add(lines, "\t\thillHeight = 26,")
	add(lines, "\t\twaterLevel = -4,")
	add(lines, "\t\twaterDepth = 14,")
	add(lines, "\t\tcolumnDepth = 40,")
	add(lines, "\t\tnoiseScale = 0.021,")
	add(lines, "\t\tseed = 1337,")
	add(lines, "\t\twater = {")
	add(lines, "\t\t\tcolor = Color3.fromRGB(52, 122, 168),")
	add(lines, "\t\t\twaveSize = 0.35,")
	add(lines, "\t\t\twaveSpeed = 8,")
	add(lines, "\t\t\ttransparency = 0.35,")
	add(lines, "\t\t\treflectance = 0.2,")
	add(lines, "\t\t},")
	add(lines, "\t},")
	add(lines, "\tdetail = {")
	add(lines, "\t\tcornerRadius = 2.5,")
	add(lines, "\t\tfenceHeight = 5,")
	add(lines, "\t\tfencePostSpacing = 14,")
	add(lines, "\t\tbannerHeight = 10,")
	add(lines, "\t\tflagHeight = 15,")
	add(lines, "\t\tstandRadius = 60,")
	add(lines, "\t\tstandCount = 6,")
	add(lines, "\t\tincubatorSparkleRate = 4,")
	add(lines, "\t\tfireflyRate = 1.2,")
	add(lines, "\t\tdustRate = 0.8,")
	add(lines, "\t},")
	add(lines, "\tlighting = {")
	add(lines, '\t\ttechnology = "Future",')
	add(lines, "\t\tclockTime = 14,")
	add(lines, "\t\tbrightness = 2.5,")
	add(lines, "\t\tambient = Color3.fromRGB(140, 140, 150),")
	add(lines, "\t\toutdoorAmbient = Color3.fromRGB(150, 150, 160),")
	add(lines, "\t\tglobalShadows = true,")
	add(lines, "\t\tshadowSoftness = 0.25,")
	add(lines, "\t\tenvironmentDiffuseScale = 1,")
	add(lines, "\t\tenvironmentSpecularScale = 1,")
	add(lines, "\t\tfogEnd = 100000,")
	add(lines, "\t\tsky = { celestialBodiesShown = true, sunAngularSize = 22, starCount = 3000, skybox = {} },")
	add(lines, "\t\tclouds = { cover = 0.2, density = 0.35, color = Color3.fromRGB(255, 255, 255) },")
	add(lines, "\t\tatmosphere = {")
	add(lines, "\t\t\tdensity = 0.3,")
	add(lines, "\t\t\thaze = 1.2,")
	add(lines, "\t\t\tcolor = Color3.fromRGB(255, 235, 210),")
	add(lines, "\t\t\tdecay = Color3.fromRGB(120, 150, 190),")
	add(lines, "\t\t},")
	add(lines, "\t\tcolorCorrection = { saturation = 0.12, contrast = 0.08 },")
	add(lines, "\t\tbloom = { intensity = 0.4, size = 24, threshold = 1.5 },")
	add(lines, "\t\tsunRays = { intensity = 0.05 },")
	add(
		lines,
		"\t\tdepthOfField = { farIntensity = 0.15, focusDistance = 45, inFocusRadius = 70, nearIntensity = 0.08 },"
	)
	add(lines, "\t},")
	add(lines, "\tbudget = { worldPartsMax = 6000 },")
	add(lines, "}")
	add(lines, "")
	add(lines, "return WorldTheme")
	add(lines, "")
	return table.concat(lines, "\n")
end

--- Renders src/server/World.luau: the thin per-pack wrapper the genre Server
--- runtime's `World` option expects, binding WorldLayout/WorldTheme to
--- WorldBuilder. Pack-independent aside from the header and require paths.
-- Fixed by the collect-raid genre Server.Remotes contract (genres/collect-raid/module/runtime/Server.luau);
-- every pack's ReplicatedStorage.Remotes folder has exactly these instances.
local REMOTES: { { name: string, className: string } } = {
	{ name = "BuyEgg", className = "RemoteFunction" },
	{ name = "HatchEgg", className = "RemoteFunction" },
	{ name = "StateChanged", className = "RemoteEvent" },
	{ name = "Raid", className = "RemoteFunction" },
	{ name = "Merge", className = "RemoteFunction" },
	{ name = "ClaimQuest", className = "RemoteFunction" },
	{ name = "SiegeState", className = "RemoteEvent" },
	{ name = "Notify", className = "RemoteEvent" },
	{ name = "StoreOpen", className = "RemoteEvent" },
	{ name = "TutorialState", className = "RemoteEvent" },
	{ name = "RaidReplay", className = "RemoteEvent" },
}

--- Renders default.project.json for a full collect-raid pack: named Remotes
--- (the genre Server/Client contract), Forge core/genre/game module paths, a
--- Future-lighting Lighting block, the pack's `<Pascal>Server` + `World`
--- server scripts, and its `<Pascal>Client` client script.
function M.renderProjectJson(pack: string, pascal: string, genre: string): string
	local lines: { string } = {
		"{",
		'\t"name": ' .. string.format("%q", pack) .. ",",
		'\t"globIgnorePaths": ["**/*.spec.luau", "**/*.md", "**/.gitkeep", "**/*.yml"],',
		'\t"tree": {',
		'\t\t"$className": "DataModel",',
		'\t\t"ReplicatedStorage": {',
		'\t\t\t"Remotes": {',
		'\t\t\t\t"$className": "Folder",',
	}
	for index, remote in REMOTES do
		local comma = if index < #REMOTES then "," else ""
		add(lines, string.format('\t\t\t\t%q: { "$className": %q }%s', remote.name, remote.className, comma))
	end
	add(lines, "\t\t\t},")
	add(lines, '\t\t\t"Forge": {')
	add(lines, '\t\t\t\t"$className": "Folder",')
	add(lines, '\t\t\t\t"core": {')
	add(lines, '\t\t\t\t\t"$className": "Folder",')
	add(lines, '\t\t\t\t\t"domain": { "$path": "../../core/domain" },')
	add(lines, '\t\t\t\t\t"infra": { "$path": "../../core/infra" },')
	add(lines, '\t\t\t\t\t"anticheat": { "$path": "../../core/anticheat" },')
	add(lines, '\t\t\t\t\t"ui-kit": { "$path": "../../core/ui-kit" }')
	add(lines, "\t\t\t\t},")
	add(lines, '\t\t\t\t"genres": {')
	add(lines, '\t\t\t\t\t"$className": "Folder",')
	add(lines, string.format("\t\t\t\t\t%q: {", genre))
	add(lines, '\t\t\t\t\t\t"$className": "Folder",')
	add(lines, string.format('\t\t\t\t\t\t"module": { "$path": "../../genres/%s/module" }', genre))
	add(lines, "\t\t\t\t\t}")
	add(lines, "\t\t\t\t},")
	add(lines, '\t\t\t\t"games": {')
	add(lines, '\t\t\t\t\t"$className": "Folder",')
	add(lines, string.format("\t\t\t\t\t%q: {", pack))
	add(lines, '\t\t\t\t\t\t"$className": "Folder",')
	add(lines, '\t\t\t\t\t\t"src": {')
	add(lines, '\t\t\t\t\t\t\t"$className": "Folder",')
	add(lines, '\t\t\t\t\t\t\t"shared": { "$path": "src/shared" }')
	add(lines, "\t\t\t\t\t\t}")
	add(lines, "\t\t\t\t\t}")
	add(lines, "\t\t\t\t}")
	add(lines, "\t\t\t}")
	add(lines, "\t\t},")
	add(lines, '\t\t"Lighting": {')
	add(lines, '\t\t\t"$className": "Lighting",')
	add(lines, '\t\t\t"$properties": {')
	add(lines, '\t\t\t\t"Technology": "Future",')
	add(lines, '\t\t\t\t"GlobalShadows": true')
	add(lines, "\t\t\t}")
	add(lines, "\t\t},")
	add(lines, '\t\t"ServerScriptService": {')
	add(lines, string.format('\t\t\t%q: { "$path": "src/server/%sServer.server.luau" },', pascal .. "Server", pascal))
	add(lines, '\t\t\t"World": { "$path": "src/server/World.luau" }')
	add(lines, "\t\t},")
	add(lines, '\t\t"StarterPlayer": {')
	add(lines, '\t\t\t"StarterPlayerScripts": {')
	add(lines, string.format('\t\t\t\t%q: { "$path": "src/client/%sClient.client.luau" }', pascal .. "Client", pascal))
	add(lines, "\t\t\t}")
	add(lines, "\t\t}")
	add(lines, "\t}")
	add(lines, "}")
	add(lines, "")
	return table.concat(lines, "\n")
end

--- Renders liveops.yml: one starter double-coins event pushed with `forge
--- liveops push` to the staging universe. `kind` is the runtime Broadcast
--- handler name; `data` becomes the envelope data.
function M.renderLiveopsYml(): string
	local lines: { string } = {
		"# LiveOps events pushed with `forge liveops push` to the staging universe.",
		"# `kind` is the runtime Broadcast handler name; `data` becomes the envelope data.",
		"events:",
		"  - id: double-coins",
		"    kind: event",
		"    data:",
		"      multiplier: 2",
		"      durationSeconds: 3600",
		"",
	}
	return table.concat(lines, "\n")
end

--- Renders deploy.yml: staging-only environment (universeId/placeId 0 until a
--- human publishes), no localization table yet, and the launch art `forge gen
--- launchart` writes (icon/thumbnail a/b variants).
function M.renderDeployYml(): string
	local lines: { string } = {
		"environments:",
		"  staging:",
		"    universeId: 0",
		"    placeId: 0",
		"  production:",
		"    universeId: 0",
		"    placeId: 0",
		"    requiresHumanMerge: true",
		"# Localization Tables API target for `forge locale sync` (0 = unset).",
		"localizationTableId: 0",
		"# Launch art uploaded by the G5 publish step; `id` is the A/B variant id.",
		"assets:",
		"  icon:",
		"    - id: a",
		"      path: assets/icon/icon-a.png",
		"    - id: b",
		"      path: assets/icon/icon-b.png",
		"  thumbnails:",
		"    - id: a",
		"      path: assets/thumbnails/thumb-a.png",
		"    - id: b",
		"      path: assets/thumbnails/thumb-b.png",
		"",
	}
	return table.concat(lines, "\n")
end

--- Renders smoke.luau: pure, engine-free smoke checks (profile round-trip,
--- econ config validity, save serialization, profile migration). Identical
--- across packs except for `firstEggId`, the egg bought in the default
--- (fixture-less) round-trip and serialization checks.
function M.renderSmoke(firstEggId: string): string
	local lines: { string } = {
		"--!strict",
		"-- Pure, engine-free smoke checks. Requires only the pack's pure modules",
		"-- (src/shared) and core/domain; the default path touches no Roblox APIs and",
		"-- no Lune APIs, so the same source can be bundled as text for an Open Cloud",
		"-- Luau Execution task. Generated by forge plan.",
		"",
		'local Loop = require("../../../genres/collect-raid/module/runtime/Loop")',
		'local Config = require("../src/shared/Config")',
		'local ProfileSchema = require("../../../core/domain/state/ProfileSchema")',
		"",
		"export type Check = {",
		"\tname: string,",
		"\tok: boolean,",
		"\tdetail: string,",
		"}",
		"",
		"local M = {}",
		"",
		"local function isFiniteNumber(value: any): boolean",
		'\treturn type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge',
		"end",
		"",
		"local function pass(name: string, detail: string): Check",
		"\treturn { name = name, ok = true, detail = detail }",
		"end",
		"",
		"local function fail(name: string, detail: string): Check",
		"\treturn { name = name, ok = false, detail = detail }",
		"end",
		"",
		"-- Resolves the optional fixture argument: nil (fresh player), an already-decoded",
		"-- save table (the CLI and spec decode the JSON), or a JSON path read lazily",
		"-- through @lune. The @lune require is only reached for an explicit local path,",
		"-- never on the default or cloud path.",
		"local function resolveFixture(fixture: any): (any, string?)",
		"\tif fixture == nil then",
		"\t\treturn nil, nil",
		"\tend",
		'\tif type(fixture) == "table" then',
		"\t\treturn fixture, nil",
		"\tend",
		'\tif type(fixture) == "string" then',
		"\t\tlocal dynamicRequire = require :: any",
		"\t\tlocal readOk, decoded = pcall(function()",
		'\t\t\tlocal fs = dynamicRequire("@lune/fs")',
		'\t\t\tlocal serde = dynamicRequire("@lune/serde")',
		'\t\t\treturn serde.decode("json", fs.readFile(fixture))',
		"\t\tend)",
		"\t\tif not readOk then",
		'\t\t\treturn nil, "failed to read fixture: " .. tostring(decoded)',
		"\t\tend",
		'\t\tif type(decoded) ~= "table" then',
		'\t\t\treturn nil, "fixture did not decode to a table"',
		"\t\tend",
		"\t\treturn decoded, nil",
		"\tend",
		'\treturn nil, "unsupported fixture type: " .. typeof(fixture)',
		"end",
		"",
		"-- (a) Save round-trip: snapshot, serialize, restore, and compare coins plus the",
		"-- incubator count. With a fixture the decoded save is validated (and must be",
		"-- corrupt for the shipped fixture, whose coins field is not a number).",
		"local function checkProfileRoundTrip(fixture: any): Check",
		'\tlocal name = "profile round-trip"',
		"\tlocal now = 0",
		"\tlocal state",
		"\tif fixture ~= nil then",
		"\t\tif not isFiniteNumber(fixture.coins) then",
		'\t\t\treturn fail(name, "fixture coins is not a finite number: " .. tostring(fixture.coins))',
		"\t\tend",
		"\t\tstate = Loop.fromSave(Config, fixture, now)",
		"\telse",
		"\t\tstate = Loop.newPlayer(Config, now)",
		string.format("\t\tlocal bought, err = Loop.buySource(Config, state, %q, now)", firstEggId),
		"\t\tif not bought then",
		string.format('\t\t\treturn fail(name, "buySource(%s) failed: " .. tostring(err))', firstEggId),
		"\t\tend",
		"\tend",
		"",
		"\tlocal before = Loop.snapshot(Config, state, 10)",
		"\tif not isFiniteNumber(before.coins) or before.coins < 0 then",
		'\t\treturn fail(name, "pre-save coins is not a finite number >= 0: " .. tostring(before.coins))',
		"\tend",
		"",
		"\tlocal save = Loop.toSave(Config, state, 10)",
		"\tlocal restored = Loop.fromSave(Config, save, 10)",
		"\tlocal after = Loop.snapshot(Config, restored, 10)",
		"\tif not isFiniteNumber(after.coins) or after.coins < 0 then",
		'\t\treturn fail(name, "restored coins is not a finite number >= 0: " .. tostring(after.coins))',
		"\tend",
		"\tif after.coins ~= before.coins then",
		'\t\treturn fail(name, string.format("coins changed across save/load: %d -> %d", before.coins, after.coins))',
		"\tend",
		"\tif #after.incubators ~= #before.incubators then",
		"\t\treturn fail(",
		"\t\t\tname,",
		'\t\t\tstring.format("incubators changed across save/load: %d -> %d", #before.incubators, #after.incubators)',
		"\t\t)",
		"\tend",
		'\treturn pass(name, string.format("coins %d, incubators %d", after.coins, #after.incubators))',
		"end",
		"",
		"-- (b) Econ config validity: positive prices, non-empty pools, known creatures, and",
		"-- merge rules that resolve to existing creatures.",
		"local function checkEconConfig(): Check",
		'\tlocal name = "econ config"',
		"\tlocal eggCount = 0",
		"\tfor eggId, egg in Config.sources do",
		"\t\teggCount += 1",
		'\t\tif not (type(egg.price) == "number" and egg.price > 0) then',
		'\t\t\treturn fail(name, "egg \'" .. eggId .. "\' has non-positive price: " .. tostring(egg.price))',
		"\t\tend",
		"\t\tlocal weightSum = 0",
		"\t\tfor _, entry in egg.pool do",
		"\t\t\tif Config.creatures[entry.id] == nil then",
		'\t\t\t\treturn fail(name, "egg \'" .. eggId .. "\' pools unknown creature: " .. tostring(entry.id))',
		"\t\t\tend",
		'\t\t\tif not (type(entry.weight) == "number" and entry.weight >= 0) then',
		'\t\t\t\treturn fail(name, "egg \'" .. eggId .. "\' has invalid weight for " .. tostring(entry.id))',
		"\t\t\tend",
		"\t\t\tweightSum += entry.weight",
		"\t\tend",
		"\t\tif not (weightSum > 0) then",
		'\t\t\treturn fail(name, "egg \'" .. eggId .. "\' pool weights sum to " .. tostring(weightSum))',
		"\t\tend",
		"\tend",
		"\tfor _, family in Config.mergeFamilies do",
		"\t\tfor _, rule in family.rules do",
		"\t\t\tif Config.creatures[rule.resultId] == nil then",
		"\t\t\t\treturn fail(",
		"\t\t\t\t\tname,",
		'\t\t\t\t\t"merge rule in \'" .. family.id .. "\' references unknown creature: " .. tostring(rule.resultId)',
		"\t\t\t\t)",
		"\t\t\tend",
		"\t\tend",
		"\tend",
		'\treturn pass(name, string.format("%d eggs and %d merge families valid", eggCount, #Config.mergeFamilies))',
		"end",
		"",
		"-- (c) Serialization walk: the save holds only strings/numbers/booleans/tables,",
		"-- with no NaN/inf, no functions, and no cycles.",
		"local function checkSerialization(): Check",
		'\tlocal name = "save serialization"',
		"\tlocal state = Loop.newPlayer(Config, 0)",
		string.format("\tLoop.buySource(Config, state, %q, 0)", firstEggId),
		"\tlocal save = Loop.toSave(Config, state, 10)",
		"",
		"\tlocal seen = {}",
		"\tlocal stack: { any } = { save }",
		"\twhile #stack > 0 do",
		"\t\tlocal value = table.remove(stack)",
		"\t\tlocal valueType = typeof(value)",
		'\t\tif valueType == "number" then',
		"\t\t\tif not isFiniteNumber(value) then",
		'\t\t\t\treturn fail(name, "non-finite number in save: " .. tostring(value))',
		"\t\t\tend",
		'\t\telseif valueType == "table" then',
		"\t\t\tif seen[value] then",
		'\t\t\t\treturn fail(name, "cycle detected in save table")',
		"\t\t\tend",
		"\t\t\tseen[value] = true",
		"\t\t\tfor key, child in value do",
		"\t\t\t\tlocal keyType = typeof(key)",
		'\t\t\t\tif keyType ~= "string" and keyType ~= "number" then',
		'\t\t\t\t\treturn fail(name, "table key is not a string/number: " .. tostring(key))',
		"\t\t\t\tend",
		"\t\t\t\ttable.insert(stack, child)",
		"\t\t\tend",
		'\t\telseif valueType ~= "string" and valueType ~= "boolean" then',
		'\t\t\treturn fail(name, "unsupported value type in save: " .. valueType)',
		"\t\tend",
		"\tend",
		'\treturn pass(name, "save is plain DataStore-safe data")',
		"end",
		"",
		"-- (d) Profile migration: migrating an empty record with the pack defaults fills",
		"-- every default key.",
		"local function checkProfileMigrate(): Check",
		'\tlocal name = "profile migration"',
		"\tlocal migrated = ProfileSchema.migrate({}, Config.profile.version, Config.profile.defaults, {})",
		"\tfor key in Config.profile.defaults() do",
		"\t\tif migrated[key] == nil then",
		'\t\t\treturn fail(name, "missing default key: " .. tostring(key))',
		"\t\tend",
		"\tend",
		'\treturn pass(name, "migration fills every default key")',
		"end",
		"",
		"--- Runs every smoke check. `fixture` may be nil, a decoded save table, or a",
		"--- JSON path string (read lazily through @lune).",
		"function M.run(fixture: any?): { Check }",
		"\tlocal fixtureTable, fixtureErr = resolveFixture(fixture)",
		"\tif fixtureErr ~= nil then",
		"\t\treturn {",
		'\t\t\tfail("fixture load", fixtureErr),',
		"\t\t\tcheckEconConfig(),",
		"\t\t\tcheckSerialization(),",
		"\t\t\tcheckProfileMigrate(),",
		"\t\t}",
		"\tend",
		"\treturn {",
		"\t\tcheckProfileRoundTrip(fixtureTable),",
		"\t\tcheckEconConfig(),",
		"\t\tcheckSerialization(),",
		"\t\tcheckProfileMigrate(),",
		"\t}",
		"end",
		"",
		"return M",
		"",
	}
	return table.concat(lines, "\n")
end

--- Renders smoke.spec.luau: generic specs (default run passes every check, the
--- corrupt fixture fails at least one). `pack` selects the fixture path.
function M.renderSmokeSpec(pack: string): string
	local lines: { string } = {
		"--!strict",
		"-- Specs for the smoke checks: the default run passes every check, and the",
		"-- corrupt fixture fails at least one. Generated by forge plan.",
		"",
		'local fs = require("@lune/fs")',
		'local serde = require("@lune/serde")',
		"",
		'local Smoke = require("./smoke")',
		"",
		"-- Specs run from the repository root.",
		string.format('local FIXTURE_PATH = "games/%s/smoke/fixtures/corrupt-save.json"', pack),
		"",
		"local function anyFailed(checks: { any }): boolean",
		"\tfor _, check in checks do",
		"\t\tif not check.ok then",
		"\t\t\treturn true",
		"\t\tend",
		"\tend",
		"\treturn false",
		"end",
		"",
		"return {",
		'\t["the default smoke passes every check"] = function()',
		"\t\tlocal checks = Smoke.run()",
		'\t\tassert(#checks > 0, "expected at least one smoke check")',
		"\t\tfor _, check in checks do",
		'\t\t\tassert(check.ok, check.name .. " failed: " .. check.detail)',
		"\t\tend",
		"\tend,",
		"",
		'\t["the corrupt fixture fails at least one check"] = function()',
		'\t\tlocal decoded = serde.decode("json", fs.readFile(FIXTURE_PATH))',
		"\t\tlocal checks = Smoke.run(decoded)",
		'\t\tassert(#checks > 0, "expected at least one smoke check")',
		'\t\tassert(anyFailed(checks), "the corrupt save fixture should fail at least one check")',
		"\tend,",
		"}",
		"",
	}
	return table.concat(lines, "\n")
end

--- Renders smoke/fixtures/corrupt-save.json: a structurally valid save whose
--- `coins` field is intentionally not a number, so `Smoke.run` fails the
--- profile round-trip check. Generic across packs (mirrors
--- Config.profile.defaults(): coins, creatures, lastSeen, questDay, quest).
function M.renderCorruptFixture(): string
	local lines: { string } = {
		"{",
		'  "version": 1,',
		'  "coins": "abc",',
		'  "creatures": {},',
		'  "lastSeen": 0,',
		'  "questDay": 0,',
		'  "quest": null',
		"}",
		"",
	}
	return table.concat(lines, "\n")
end

local function csvField(value: string): string
	if string.find(value, '[,"\n]') then
		return '"' .. string.gsub(value, '"', '""') .. '"'
	end
	return value
end

local function csvRow(key: string, source: string, context: string, enUs: string, koKr: string): string
	return table.concat({ csvField(key), csvField(source), csvField(context), csvField(enUs), csvField(koKr) }, ",")
end

--- Renders locale/strings.csv: every literal `Text =`/`string.format("...")`
--- string the collect-raid genre runtime ships (required by `forge locale
--- check`, which is hardcoded to the columns below) plus the full en-us/ko-kr
--- UI copy for this pack's Copy/Messages text and roster names, so the sheet
--- a translator gets covers everything a player can see, not just the bare
--- minimum the checker enforces.
function M.renderLocaleCsv(roster: Roster, economy: Economy, teams: { string }): string
	local lines: { string } = {
		"Key,Source,Context,en-us,ko-kr",
		csvRow("hud.coinsPrefix", "Coins:", "Coins label prefix", "Coins:", "코인:"),
		csvRow("hud.coinsCount", "Coins: %d", "Coins counter template", "Coins: %d", "코인: %d"),
		csvRow(
			"hud.kaijuCount",
			"Kaiju Owned: %d",
			"Creatures owned counter template",
			"Kaiju Owned: %d",
			"보유 카이주: %d"
		),
		csvRow(
			"hud.siegeNextPrefix",
			"Next siege in",
			"Siege banner idle prefix before the clock",
			"Next siege in",
			"다음 공성까지"
		),
		csvRow(
			"hud.siegeActivePrefix",
			"Siege ACTIVE",
			"Siege banner active prefix before the clock",
			"Siege ACTIVE",
			"공성 진행 중"
		),
		csvRow("hud.clock", "%d:%02d", "Siege countdown clock template", "%d:%02d", "%d:%02d"),
		csvRow("hud.vaultedCount", "Vaulted: %d", "Vaulted egg counter template", "Vaulted: %d", "보관된 알: %d"),
		csvRow("hud.invite", "Invite Friends", "Friend invite button", "Invite Friends", "친구 초대"),
		csvRow(
			"hud.inviteUnavailable",
			"Invites are not available here",
			"Toast shown when the platform cannot send a game invite",
			"Invites are not available here",
			"여기서는 초대를 보낼 수 없습니다"
		),
		csvRow(
			"hud.slotStatus",
			"Slot %d: %s (%s)",
			"Incubator slot status template",
			"Slot %d: %s (%s)",
			"슬롯 %d: %s (%s)"
		),
		csvRow("hud.toggle", "\\u{2261}", "HUD panel collapse toggle glyph", "\u{2261}", "\u{2261}"),
		csvRow("button.raid", "Raid rival vault", "Raid button label", "Raid rival vault", "라이벌 금고 습격"),
		csvRow(
			"button.merge",
			"Merge %s family",
			"Merge button per creature family",
			"Merge %s family",
			"%s 계열 합성"
		),
		csvRow(
			"button.buyEgg",
			"Buy %s (%d Coins)",
			"Egg purchase button",
			"Buy %s (%d Coins)",
			"%s 구매 (%d 코인)"
		),
		csvRow("button.store", "Store", "Store button and store panel title", "Store", "상점"),
		csvRow("button.odds", "Odds", "Odds button label", "Odds", "확률"),
		csvRow("store.passesHeader", "Game Passes", "Store game pass section header", "Game Passes", "게임 패스"),
		csvRow(
			"store.productsHeader",
			"Developer Products",
			"Store developer product section header",
			"Developer Products",
			"개발자 제품"
		),
		csvRow("store.itemButton", "%s - %d R$", "Store item price button", "%s - %d R$", "%s - %d R$"),
		csvRow(
			"store.unpublishedStatus",
			"Not available until published",
			"Store status shown after clicking a not-yet-published item",
			"Not available until published",
			"게시 전에는 이용할 수 없습니다"
		),
		csvRow("odds.title", "Hatch Odds", "Odds panel title", "Hatch Odds", "부화 확률"),
		csvRow("odds.entry", "%s %.1f%%", "Odds row per creature in an egg pool", "%s %.1f%%", "%s %.1f%%"),
		csvRow("quest.header", "Daily Quests", "Daily quest panel header", "Daily Quests", "일일 퀘스트"),
		csvRow("quest.row", "%s %d/%d (+%d)", "Daily quest progress row", "%s %d/%d (+%d)", "%s %d/%d (+%d)"),
		csvRow("quest.claim", "Claim", "Quest claim button", "Claim", "수령"),
		csvRow("quest.claimed", "Claimed", "Quest claim button after claiming", "Claimed", "수령 완료"),
		csvRow("quest.hatch", "hatch", "Quest id shown in the quest row", "Hatch eggs", "알 부화"),
		csvRow("quest.buy", "buy", "Quest id shown in the quest row", "Buy eggs", "알 구매"),
		csvRow("quest.raid", "raid", "Quest id shown in the quest row", "Raid a vault", "금고 습격"),
		csvRow("incubator.hatchButton", "Hatch #%d", "Hatch button for a ready incubator", "Hatch #%d", "부화 #%d"),
		csvRow(
			"incubator.slotStatusText",
			"Slot %d: %s (%s)",
			"Incubator slot countdown with a preformatted duration",
			"Slot %d: %s (%s)",
			"슬롯 %d: %s (%s)"
		),
		csvRow("incubator.eggFallback", "Egg", "Fallback egg name in the incubator slot status", "Egg", "알"),
		csvRow("tutorial.prefix", "Tutorial:", "Prefix in front of the tutorial hint", "Tutorial:", "튜토리얼:"),
		csvRow(
			"notify.serverBoost",
			"Server Luck Boost active!",
			"Toast when a server luck boost starts",
			"Server Luck Boost active!",
			"서버 행운 부스트 활성화!"
		),
		csvRow(
			"notify.legendaryHatch",
			"%s hatched %s!",
			"Server-wide broadcast when a legendary creature hatches",
			"%s hatched %s!",
			"%s님이 %s을(를) 부화했습니다!"
		),
		csvRow(
			"kick.profileLocked",
			"Your profile is still locked by another server. Please rejoin.",
			"Kick reason when the profile lock times out",
			"Your profile is still locked by another server. Please rejoin.",
			"프로필이 다른 서버에서 잠겨 있습니다. 다시 접속해 주세요."
		),
		csvRow(
			"kick.profileLoadFailed",
			"Could not load your profile. Please rejoin.",
			"Kick reason when the profile fails to load",
			"Could not load your profile. Please rejoin.",
			"프로필을 불러오지 못했습니다. 다시 접속해 주세요."
		),
		csvRow("currency.coins", "Coins", "Currency display name", "Coins", "코인"),
		csvRow("button.overflowMenu", "\\u{2261}", "Overflow menu toggle glyph", "\u{2261}", "\u{2261}"),
		csvRow(
			"inventory.emptyHint",
			"Hatch an egg to get your first creature",
			"Creature inventory empty-state hint",
			"Hatch an egg to get your first creature",
			"첫 크리처를 얻으려면 알을 부화하세요"
		),
		csvRow("inventory.countPrefix", "x", "Creature inventory count prefix", "x", "x"),
	}

	-- Team-count-driven rows: the genre Hud joins one "<Team> vault: %d" clause
	-- per team with " | ", so the Source/en-us text must list every team.
	do
		local zeroParts: { string } = {}
		local templateParts: { string } = {}
		local koParts: { string } = {}
		for _, teamName in teams do
			table.insert(zeroParts, string.format("%s vault: 0", teamName))
			table.insert(templateParts, string.format("%s vault: %%d", teamName))
			table.insert(koParts, string.format("%s 금고: %%d", teamName))
		end
		local zero = table.concat(zeroParts, " | ")
		local template = table.concat(templateParts, " | ")
		local koTemplate = table.concat(koParts, " | ")
		add(
			lines,
			csvRow("hud.vaults", zero, "Initial team vault counts label", zero, (string.gsub(koTemplate, "%%d", "0")))
		)
		add(lines, csvRow("hud.vaultCounts", template, "Team vault counts template", template, koTemplate))
	end

	-- Roster-driven rows: egg and creature display names, and one merge family
	-- per egg (id = egg id, display name = Title Case of the egg id).
	for _, egg in roster.eggs do
		local name = M.titleCase(egg.id) .. " Egg"
		add(lines, csvRow("egg." .. egg.id, name, "Egg display name", name, name))
	end
	for _, creature in roster.creatures do
		add(
			lines,
			csvRow(
				"creature." .. creature.id,
				creature.displayName,
				"Creature display name",
				creature.displayName,
				creature.displayName
			)
		)
	end
	for _, egg in roster.eggs do
		local name = M.titleCase(egg.id)
		add(lines, csvRow("family." .. egg.id, name, "Merge family display name", name, name))
	end

	-- Monetization item names (gamepasses, then developer products).
	for _, item in economy.monetization.gamepasses do
		add(lines, csvRow("item." .. item.key, item.name, "Game pass name", item.name, item.name))
	end
	for _, item in economy.monetization.products do
		add(lines, csvRow("item." .. item.key, item.name, "Developer product name", item.name, item.name))
	end

	add(lines, "")
	return table.concat(lines, "\n")
end

--- Renders design/perf.md: performance budgets and the remote call budget
--- (both derivable at plan time from the fixed `Config.anticheat` table every
--- collect-raid pack ships) plus the measurement procedure. Studio-only
--- numbers (heartbeat, client FPS, part count, memory) are left as TBD since
--- `forge plan` runs offline and cannot open a Studio session to measure them.
function M.renderPerf(title: string, worldName: string): string
	local lines: { string } = {
		"# " .. title .. " - Performance Budgets",
		"",
		"Budgets protect the 30-second first loop and the 10-minute siege on low-end mobile.",
		"Remote limits come from `src/shared/Config.luau` (`Config.anticheat`); the part budget",
		string.format("applies to the `%s` model built by `src/server/World.luau` (`World.build`).", worldName),
		"",
		"## Budgets",
		"",
		"| Metric | Budget | Notes |",
		"| --- | --- | --- |",
		"| Server heartbeat | >= 55 Hz | 55/60 = 8.3% headroom under the 60 Hz target |",
		"| Client FPS (low-end mobile) | >= 30 FPS | floor is 30 FPS; target 60 FPS on desktop |",
		string.format("| BaseParts in `%s` | <= 6000 | replicad part count of the world model |", worldName),
		"| Client memory | < 800 MB | RSS/total memory on low-end mobile |",
		"| Remote calls / s / player | sustained <= 8.7, burst <= 25 | derived from `Config.anticheat` (below) |",
		"",
		"## Remote call budget per player",
		"",
		"Each remote is a per-player token bucket. Sustained rate is `refillPerSecond`;",
		"burst is `capacity`. Totals: sustained 2 + 2 + 2 + 2 + 0.2 + 0.5 = 8.7 calls/s,",
		"burst 5 + 5 + 5 + 5 + 2 + 3 = 25 calls.",
		"",
		"| Remote | Capacity (burst) | Refill/s (sustained) |",
		"| --- | --- | --- |",
		"| BuyEgg | 5 | 2 |",
		"| HatchEgg | 5 | 2 |",
		"| Merge | 5 | 2 |",
		"| ClaimQuest | 5 | 2 |",
		"| Raid | 2 | 0.2 |",
		"| StoreOpen | 3 | 0.5 |",
		"",
		"`Raid` (capacity 2, refill 0.2/s) is the tightest gate: at most 2 raid calls per burst",
		"and 1 every 5 s sustained, matching the 120 s siege window inside the 600 s period.",
		"",
		"## Measurement procedure",
		"",
		"1. Server heartbeat - open Studio, run in Play mode, enable the MicroProfiler",
		'   (`Ctrl+F6`) and read the "Heartbeat" / server frame bars over a 60 s siege window.',
		"   Record the minimum observed Hz, not the average.",
		'2. Client FPS - use the Stats service (`game:GetService("Stats")`) or the MicroProfiler',
		"   frame time; sample a low-end mobile device profile for 60 s during a siege and record",
		"   the 1st-percentile FPS.",
		"3. BaseParts - in the command bar run",
		string.format("   `#workspace:GetDescendants()` filtered to `BasePart` under `workspace.%s`,", worldName),
		'   i.e. `local n = 0 for _, d in workspace:GetDescendants() do if d:IsA("BasePart") and',
		string.format("   d:IsDescendantOf(workspace.%s) then n += 1 end end print(n)`.", worldName),
		"   Count after `World.build()` has parented the model.",
		"4. Client memory - read memory from the MicroProfiler memory view or the developer",
		"   console on the low-end device after 5 minutes in a siege; record the peak, not the start.",
		"5. Remotes - assert against `Config.anticheat` counters in `core/anticheat`; a healthy",
		"   client stays well under the sustained column, so sustained is the alarm threshold.",
		"",
		"## Results",
		"",
		"forge plan runs offline and cannot open a Studio session, so every measured value below",
		"is TBD until a human captures it in Studio and fills this table in.",
		"",
		"| Metric | Budget | Measured | Method | Status |",
		"| --- | --- | --- | --- | --- |",
		"| Server heartbeat | >= 55 Hz | TBD | MicroProfiler server frames | TBD |",
		"| Client FPS (low-end mobile) | >= 30 FPS | TBD | Stats service, 1st percentile | TBD |",
		string.format("| BaseParts in `%s` | <= 6000 | TBD | `workspace:GetDescendants` filter | TBD |", worldName),
		"| Client memory | < 800 MB | TBD | MicroProfiler memory view | TBD |",
		"| Remote calls/s/player | <= 8.7 sustained | TBD | `core/anticheat` counters | TBD |",
		"",
		"## Regression triggers",
		"",
		"- Any change to `src/server/World.luau` part counts requires a fresh",
		"  `workspace:GetDescendants` count before merge.",
		"- Any new remote must add a `Config.anticheat` entry with `capacity` and",
		"  `refillPerSecond`, and the sustained total (currently 8.7/s) must be re-summed.",
		"- A heartbeat under 55 Hz or client FPS under 30 FPS on the mobile profile blocks release",
		"  until the offending system is profiled and fixed.",
		"",
	}
	return table.concat(lines, "\n")
end

--- Renders src/shared/WorldLayout.spec.luau: pure Luau specs generalized over
--- any team list (mirroring only applies to exactly 2 teams; for other counts
--- the checks fall back to per-base symmetry-free assertions), checking base
--- spacing/incubator counts, arena shape, decoration/flower density and kind
--- mix, and that no decoration lands on the arena, a base, or off the grid.
function M.renderWorldLayoutSpec(teams: { string }, incubatorsPerTeam: number): string
	local lines: { string } = {
		"--!strict",
		"-- Specs for WorldLayout. Pure Luau, no Roblox APIs. Generated by forge plan.",
		"",
		'local WorldLayout = require("./WorldLayout")',
		"",
		"local tests = {}",
		"",
		"local ORIGIN = { x = 0, y = 0, z = 0 }",
		"",
		"local function dist(a: WorldLayout.Vec, b: WorldLayout.Vec)",
		"\tlocal dx = a.x - b.x",
		"\tlocal dy = a.y - b.y",
		"\tlocal dz = a.z - b.z",
		"\treturn math.sqrt(dx * dx + dy * dy + dz * dz)",
		"end",
		"",
		"local function findBase(team: string): WorldLayout.BaseLayout",
		"\tfor _, base in WorldLayout.layout.bases do",
		"\t\tif base.team == team then",
		"\t\t\treturn base",
		"\t\tend",
		"\tend",
		'\terror("unknown team: " .. team)',
		"end",
		"",
		"-- Luau cannot unify `{Decoration} | {}` as a single for..in iteration form, so",
		"-- an explicitly typed empty fallback (not a bare `{}` literal) is required.",
		"local EMPTY_DECOR: { WorldLayout.Decoration } = {}",
		"",
	}

	add(lines, "local TEAMS = {")
	for _, teamName in teams do
		add(lines, string.format("\t%q,", teamName))
	end
	add(lines, "}")
	add(lines, "")

	add(lines, string.format("local INCUBATORS_PER_TEAM = %d", incubatorsPerTeam))
	add(lines, "")

	add(lines, "function tests.every_team_has_a_base()")
	add(lines, '\tassert(#WorldLayout.layout.bases == #TEAMS, "one base per team")')
	add(lines, "\tfor _, team in TEAMS do")
	add(lines, "\t\tfindBase(team)")
	add(lines, "\tend")
	add(lines, "end")
	add(lines, "")

	add(lines, "function tests.bases_are_equidistant_from_the_arena()")
	add(lines, "\tlocal radius: number? = nil")
	add(lines, "\tfor _, team in TEAMS do")
	add(lines, "\t\tlocal base = findBase(team)")
	add(lines, "\t\tlocal d = dist(base.center, ORIGIN)")
	add(lines, "\t\tif radius == nil then")
	add(lines, "\t\t\tradius = d")
	add(lines, "\t\telse")
	add(lines, '\t\t\tassert(math.abs(d - radius) < 1e-3, team .. " base must sit on the same ring as the others")')
	add(lines, "\t\tend")
	add(lines, "\tend")
	add(lines, "end")
	add(lines, "")

	add(lines, "function tests.incubators_are_spaced()")
	add(lines, "\tfor _, team in TEAMS do")
	add(lines, "\t\tlocal base = findBase(team)")
	add(
		lines,
		'\t\tassert(#base.incubators == INCUBATORS_PER_TEAM, team .. " must have INCUBATORS_PER_TEAM incubators")'
	)
	add(lines, "\t\tfor i = 1, #base.incubators do")
	add(lines, "\t\t\tfor j = i + 1, #base.incubators do")
	add(lines, "\t\t\t\tlocal d = dist(base.incubators[i], base.incubators[j])")
	add(lines, "\t\t\t\tassert(")
	add(lines, "\t\t\t\t\td >= 10,")
	add(
		lines,
		'\t\t\t\t\tteam .. " incubators " .. tostring(i) .. " and " .. tostring(j) .. " too close: " .. tostring(d)'
	)
	add(lines, "\t\t\t\t)")
	add(lines, "\t\t\tend")
	add(lines, "\t\tend")
	add(lines, "\tend")
	add(lines, "end")
	add(lines, "")

	add(lines, "-- WorldBuilder places the platform, vault crate and shop with `Position`")
	add(lines, "-- (no rotated `CFrame`), so their footprints are always axis-aligned in")
	add(lines, "-- world space, regardless of the base's own angle around the arena. A")
	add(lines, "-- pedestal is a 9-stud cylinder (radius 4.5).")
	add(lines, "local PEDESTAL_RADIUS = 4.5")
	add(lines, "local VAULT_HALF_X, VAULT_HALF_Z = 5, 5")
	add(lines, "local SHOP_HALF_X, SHOP_HALF_Z = 3, 1.5")
	add(lines, "")
	add(lines, "local function circleRectClear(")
	add(lines, "\tpoint: WorldLayout.Vec,")
	add(lines, "\trectCenter: WorldLayout.Vec,")
	add(lines, "\thalfX: number,")
	add(lines, "\thalfZ: number,")
	add(lines, "\tradius: number")
	add(lines, "): boolean")
	add(lines, "\tlocal dx = math.max(math.abs(point.x - rectCenter.x) - halfX, 0)")
	add(lines, "\tlocal dz = math.max(math.abs(point.z - rectCenter.z) - halfZ, 0)")
	add(lines, "\treturn math.sqrt(dx * dx + dz * dz) >= radius")
	add(lines, "end")
	add(lines, "")

	add(lines, "function tests.incubators_stay_on_platform_and_clear_of_vault_shop()")
	add(lines, "\tfor _, team in TEAMS do")
	add(lines, "\t\tlocal base = findBase(team)")
	add(lines, "\t\tlocal halfX, halfZ = base.size.x / 2, base.size.z / 2")
	add(lines, "\t\tfor i, p in base.incubators do")
	add(lines, "\t\t\tlocal withinX = math.abs(p.x - base.center.x) + PEDESTAL_RADIUS <= halfX")
	add(lines, "\t\t\tlocal withinZ = math.abs(p.z - base.center.z) + PEDESTAL_RADIUS <= halfZ")
	add(lines, "\t\t\tassert(")
	add(lines, "\t\t\t\twithinX and withinZ,")
	add(lines, '\t\t\t\tteam .. " incubator " .. tostring(i) .. " footprint overruns the platform bounds"')
	add(lines, "\t\t\t)")
	add(lines, "\t\t\tassert(")
	add(lines, "\t\t\t\tcircleRectClear(p, base.vault, VAULT_HALF_X, VAULT_HALF_Z, PEDESTAL_RADIUS),")
	add(lines, '\t\t\t\tteam .. " incubator " .. tostring(i) .. " overlaps the vault crate"')
	add(lines, "\t\t\t)")
	add(lines, "\t\t\tassert(")
	add(lines, "\t\t\t\tcircleRectClear(p, base.shop, SHOP_HALF_X, SHOP_HALF_Z, PEDESTAL_RADIUS),")
	add(lines, '\t\t\t\tteam .. " incubator " .. tostring(i) .. " overlaps the shop"')
	add(lines, "\t\t\t)")
	add(lines, "\t\tend")
	add(lines, "\tend")
	add(lines, "end")
	add(lines, "")

	add(lines, "function tests.vault_is_closer_than_spawn()")
	add(lines, "\tfor _, team in TEAMS do")
	add(lines, "\t\tlocal base = findBase(team)")
	add(lines, "\t\tassert(")
	add(lines, "\t\t\tdist(base.vault, ORIGIN) < dist(base.spawn, ORIGIN),")
	add(lines, '\t\t\tteam .. " vault must be closer to the arena than its spawn"')
	add(lines, "\t\t)")
	add(lines, "\tend")
	add(lines, "end")
	add(lines, "")

	add(lines, "function tests.arena_shape()")
	add(lines, "\tlocal arena = WorldLayout.layout.arena")
	add(lines, '\tassert(arena.radius == 40, "arena radius must be 40")')
	add(lines, '\tassert(#arena.covers == 4, "arena must have 4 covers")')
	add(lines, "end")
	add(lines, "")

	add(lines, "function tests.bases_clear_of_arena()")
	add(lines, "\tlocal arena = WorldLayout.layout.arena")
	add(lines, "\tfor _, team in TEAMS do")
	add(lines, "\t\tlocal base = findBase(team)")
	add(lines, "\t\tlocal edge = dist(base.center, ORIGIN) - base.size.x / 2")
	add(lines, '\t\tassert(edge > arena.radius, team .. " base overlaps the arena")')
	add(lines, "\tend")
	add(lines, "end")
	add(lines, "")

	add(lines, "function tests.unknown_team_errors()")
	add(lines, '\tassert(pcall(findBase, "Nonexistent-Team") == false, "unknown team must error")')
	add(lines, "end")
	add(lines, "")

	add(lines, "function tests.decorations_are_scattered_by_kind()")
	add(lines, "\tlocal decorations = WorldLayout.layout.decorations or EMPTY_DECOR")
	add(lines, '\tassert(#decorations >= 81 and #decorations <= 99, "about ninety decorations, got " .. #decorations)')
	add(lines, "")
	add(lines, "\tlocal counts: { [string]: number } = {}")
	add(lines, "\tfor _, d in decorations do")
	add(lines, "\t\tcounts[d.kind] = (counts[d.kind] or 0) + 1")
	add(lines, "\tend")
	add(lines, '\tassert((counts.Tree or 0) >= 36, "trees are the bulk of the scatter")')
	add(lines, '\tassert((counts.Rock or 0) >= 24, "rocks are a large share")')
	add(lines, '\tassert((counts.Crystal or 0) >= 11, "crystals accent the arena and bases")')
	add(lines, '\tassert((counts.Crate or 0) >= 7, "crates cluster near the bases")')
	add(
		lines,
		'\tassert(counts.Tree + counts.Rock + counts.Crystal + counts.Crate == #decorations, "only known kinds")'
	)
	add(lines, "end")
	add(lines, "")

	add(lines, "function tests.decorations_stay_on_grass()")
	add(lines, "\tlocal arena = WorldLayout.layout.arena")
	add(lines, "\tfor _, d in WorldLayout.layout.decorations or EMPTY_DECOR do")
	add(
		lines,
		'\t\tassert(math.abs(d.position.x) <= 190 and math.abs(d.position.z) <= 190, "decor stays on the ground grid")'
	)
	add(lines, "\t\tlocal dx, dz = d.position.x - arena.center.x, d.position.z - arena.center.z")
	add(lines, '\t\tassert(math.sqrt(dx * dx + dz * dz) > arena.radius, "decor stays off the arena floor")')
	add(lines, '\t\tassert(d.position.y >= 0, "decor sits on the ground")')
	add(lines, "\tend")
	add(lines, "\tfor _, team in TEAMS do")
	add(lines, "\t\tlocal base = findBase(team)")
	add(lines, "\t\tlocal half = base.size.x / 2")
	add(lines, "\t\tfor _, d in WorldLayout.layout.decorations or EMPTY_DECOR do")
	add(lines, "\t\t\tlocal inside = math.abs(d.position.x - base.center.x) < half")
	add(lines, "\t\t\t\tand math.abs(d.position.z - base.center.z) < half")
	add(lines, '\t\t\tassert(not inside, "decor stays off the " .. team .. " base")')
	add(lines, "\t\tend")
	add(lines, "\tend")
	add(lines, "end")
	add(lines, "")

	add(lines, "function tests.flowers_are_patched_and_clear()")
	add(lines, "\tlocal flowers = WorldLayout.layout.flowers or EMPTY_DECOR")
	add(lines, '\tassert(#flowers >= 36 and #flowers <= 44, "about forty flower patches")')
	add(lines, "\tlocal arena = WorldLayout.layout.arena")
	add(lines, "\tfor _, f in flowers do")
	add(lines, '\t\tassert(f.kind == "Flower", "flower patches are tagged")')
	add(lines, "\t\tlocal dx, dz = f.position.x - arena.center.x, f.position.z - arena.center.z")
	add(lines, '\t\tassert(math.sqrt(dx * dx + dz * dz) > arena.radius, "flowers stay off the arena")')
	add(lines, "\tend")
	add(lines, "end")
	add(lines, "")
	add(lines, "return tests")
	add(lines, "")
	return table.concat(lines, "\n")
end

function M.renderWorld(pack: string): string
	local lines: { string } = {
		"--!strict",
		"-- World: thin per-game wrapper binding this pack's layout + theme to the",
		"-- collect-raid genre WorldBuilder. Generated by forge plan.",
		"",
		'local ReplicatedStorage = game:GetService("ReplicatedStorage")',
		"",
		'local Forge = ReplicatedStorage:WaitForChild("Forge")',
		string.format("local WorldLayout = require(Forge.games[%q].src.shared.WorldLayout)", pack),
		string.format("local WorldTheme = require(Forge.games[%q].src.shared.WorldTheme)", pack),
		'local WorldBuilder = require(Forge.genres["collect-raid"].module.WorldBuilder)',
		"",
		"local World = {}",
		"",
		"function World.build(): Folder",
		"\treturn WorldBuilder.build(WorldLayout.layout, WorldTheme)",
		"end",
		"",
		"function World.incubator(team: string, index: number): Model?",
		"\treturn WorldBuilder.incubator(WorldLayout.layout, team, index)",
		"end",
		"",
		"function World.vault(team: string): Model?",
		"\treturn WorldBuilder.vault(WorldLayout.layout, team)",
		"end",
		"",
		"function World.spawn(team: string): SpawnLocation?",
		"\treturn WorldBuilder.spawn(WorldLayout.layout, team)",
		"end",
		"",
		"return World",
		"",
	}
	return table.concat(lines, "\n")
end

--- Renders src/server/<Pascal>Server.server.luau: the thin pack entry point
--- that binds this pack's data (config, catalog, world, remotes, messages,
--- teams) to the collect-raid genre Server runtime.
function M.renderServer(
	pack: string,
	pascal: string,
	teams: { string },
	debugName: string,
	incubatorsPerTeam: number
): string
	local lines: { string } = {
		"--!strict",
		"-- " .. pascal .. "Server: thin pack entry point. All gameplay logic lives in the",
		"-- collect-raid genre runtime; this file only binds this pack's data (config,",
		"-- catalog, world, remotes, copy) to it. Generated by forge plan.",
		"",
		'local ReplicatedStorage = game:GetService("ReplicatedStorage")',
		'local ServerScriptService = game:GetService("ServerScriptService")',
		"",
		"local Forge = ReplicatedStorage.Forge",
		'local Server = require(Forge.genres["collect-raid"].module.runtime.Server)',
		string.format("local Config = require(Forge.games[%q].src.shared.Config)", pack),
		string.format("local Catalog = require(Forge.games[%q].src.shared.Catalog)", pack),
		string.format("local Messages = require(Forge.games[%q].src.shared.Messages)", pack),
		string.format("local Remotes = require(Forge.games[%q].src.shared.Remotes)", pack),
		"",
		'local World = require(ServerScriptService:WaitForChild("World")) :: any',
		"",
		"Server.start({",
		"\tconfig = Config,",
		"\tcatalog = Catalog,",
		"\tworld = World,",
		"\tremotes = Remotes,",
		"\tmessages = Messages,",
		"\tteams = {",
	}
	for _, teamName in teams do
		add(lines, string.format("\t\t%q,", teamName))
	end
	add(lines, "\t},")
	add(lines, "\tteamColors = {")
	for index, teamName in teams do
		add(lines, string.format("\t\t[%q] = BrickColor.new(%q),", teamName, M.teamBrickColor(teamName, index)))
	end
	add(lines, "\t},")
	add(lines, "\trareRarities = { Legendary = true, Mythic = true },")
	add(lines, string.format("\tstoreName = %q,", pascal .. "Profiles_v1"))
	add(lines, string.format("\tdebugName = %q,", debugName))
	add(lines, string.format("\tlogPrefix = %q,", pascal .. "Server"))
	add(lines, string.format("\tincubatorsPerTeam = %d,", incubatorsPerTeam))
	add(lines, "})")
	add(lines, "")
	return table.concat(lines, "\n")
end

--- Renders src/client/<Pascal>Client.client.luau: the thin pack entry point
--- that binds this pack's data (config, catalog, assets, copy) to the
--- collect-raid genre Client runtime (Hud, Audio, WorldView, WorldDecor,
--- RaidReplay).
function M.renderClient(pack: string, pascal: string, teams: { string }, incubatorsPerTeam: number): string
	local storeIcons = {
		"coins2x",
		"vipSlots",
		"autoLock",
		"creaturePack",
		"hatchSpeedup",
		"siegeShield",
		"luckBoost",
	}
	local worldName = pascal .. "World"
	local lines: { string } = {
		"--!strict",
		"-- " .. pascal .. "Client: thin pack entry point. All HUD/audio/world-render logic",
		"-- lives in the collect-raid genre runtime; this file only binds this pack's",
		"-- data (config, catalog, assets, copy) to it. Generated by forge plan.",
		"",
		'local ReplicatedStorage = game:GetService("ReplicatedStorage")',
		"",
		'local Forge = ReplicatedStorage:WaitForChild("Forge")',
		'local Client = require(Forge.genres["collect-raid"].module.runtime.Client)',
		string.format("local Config = require(Forge.games[%q].src.shared.Config)", pack),
		string.format("local Catalog = require(Forge.games[%q].src.shared.Catalog)", pack),
		string.format("local ProcAssets = require(Forge.games[%q].src.shared.ProcAssets)", pack),
		string.format("local CreatureModels = require(Forge.games[%q].src.shared.CreatureModels)", pack),
		string.format("local Fx = require(Forge.games[%q].src.shared.Fx)", pack),
		string.format("local Copy = require(Forge.games[%q].src.shared.Copy)", pack),
		string.format("local AudioConfig = require(Forge.games[%q].src.shared.AudioConfig)", pack),
		string.format("local WorldLayout = require(Forge.games[%q].src.shared.WorldLayout)", pack),
		string.format("local Remotes = require(Forge.games[%q].src.shared.Remotes)", pack),
		"",
		"local RARITY_RANK: { [string]: number } = { Common = 1, Rare = 2, Legendary = 3, Mythic = 4 }",
		"",
		"Client.start({",
		"\thud = {",
		"\t\tconfig = Config,",
		"\t\tcatalog = Catalog,",
		"\t\tfx = Fx,",
		"\t\tprocAssets = ProcAssets,",
		"\t\tstoreIcons = {",
	}
	for _, key in storeIcons do
		add(lines, string.format("\t\t\t%s = %q,", key, key))
	end
	add(lines, "\t\t},")
	add(lines, "\t\tcopy = Copy,")
	add(lines, "\t\trarityRank = RARITY_RANK,")
	add(lines, "\t\tteamNames = {")
	for _, teamName in teams do
		add(lines, string.format("\t\t\t%q,", teamName))
	end
	add(lines, "\t\t},")
	add(lines, "\t\tremotes = Remotes,")
	add(lines, "\t},")
	add(lines, "\taudio = {")
	add(lines, "\t\tremotes = Remotes,")
	add(lines, "\t\tcues = AudioConfig.cues,")
	add(lines, "\t\tcreatures = Config.creatures,")
	add(lines, "\t\trarityRank = RARITY_RANK,")
	add(lines, "\t\tnotifyClassifiers = AudioConfig.notifyClassifiers,")
	add(lines, "\t\tpromptClassifiers = AudioConfig.promptClassifiers,")
	add(lines, "\t\tmusicTracks = AudioConfig.musicTracks,")
	add(lines, "\t\tteamRivals = AudioConfig.teamRivals,")
	add(lines, "\t},")
	add(lines, "\tworldView = {")
	add(lines, "\t\tremotes = { StateChanged = Remotes.StateChanged },")
	add(lines, string.format("\t\tworldName = %q,", worldName))
	add(lines, string.format("\t\tslotPrefix = %q,", pascal .. "Slot"))
	add(lines, '\t\tincubatorPrefix = "Incubator",')
	add(lines, string.format("\t\tincubatorCount = %d,", incubatorsPerTeam))
	add(lines, "\t\tslotCount = #WorldLayout.layout.bases[1].parade.positions,")
	add(lines, "\t\tmodels = {")
	add(lines, "\t\t\tbuildSource = CreatureModels.buildEgg,")
	add(lines, "\t\t\tbuildCreature = CreatureModels.buildKaiju,")
	add(lines, "\t\t},")
	add(lines, "\t\tprocSpecs = ProcAssets,")
	add(lines, "\t\tteamYaw = {")
	for index, teamName in teams do
		local yaw = 90 - (index - 1) * math.floor(180 / math.max(1, #teams - 1) + 0.5)
		add(lines, string.format("\t\t\t[%q] = %d,", teamName, yaw))
	end
	add(lines, "\t\t},")
	add(lines, string.format("\t\tfolderName = %q,", pascal .. "WorldView"))
	add(lines, "\t},")
	add(lines, "\tworldDecor = {")
	add(lines, string.format("\t\tworldName = %q,", worldName))
	add(lines, "\t\tprocAssetsSpecs = ProcAssets,")
	add(lines, "\t},")
	add(lines, "\traidReplay = {")
	add(lines, "\t\tremotes = { RaidReplay = Remotes.RaidReplay },")
	add(lines, string.format("\t\tworldName = %q,", worldName))
	add(lines, "\t},")
	add(lines, "})")
	add(lines, "")
	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Rendering: design docs
-- ---------------------------------------------------------------------------

local function fill(text: string, vars: { [string]: string }): string
	local out = text
	for key, value in vars do
		out = string.gsub(out, key, function(): string
			return value
		end)
	end
	return out
end

local function bulletList(items: { string }): string
	local lines: { string } = {}
	for _, item in items do
		table.insert(lines, "- " .. item)
	end
	return table.concat(lines, "\n")
end

local function joinEggs(economy: Economy): string
	local parts: { string } = {}
	for _, egg in economy.eggs do
		table.insert(parts, string.format("%s (%d %s)", egg.displayName, egg.price, economy.currency))
	end
	return table.concat(parts, ", ")
end

local function joinCreatures(economy: Economy): string
	local parts: { string } = {}
	for _, creature in economy.kaiju do
		table.insert(
			parts,
			string.format("%s (%s, %s/s)", creature.displayName, creature.rarity, fmtNum(creature.coinsPerSecond))
		)
	end
	return table.concat(parts, ", ")
end

--- Fills the genre design template into the pack's design/README.md.
function M.renderDesignReadme(template: string, plan: any, economy: Economy, title: string, concept: string): string
	local quests: { string } = {}
	for _, quest in DAILY_QUESTS do
		table.insert(quests, string.format("%s (+%d %s)", quest.text, quest.reward, economy.currency))
	end
	local retentionText = "Retention leans on three hooks: daily quests ("
		.. table.concat(quests, ", ")
		.. "), a weekly liveops cadence, and the merge ladder that turns a Common roster into a long-tail Legendary collection goal."
	return fill(template, {
		__TITLE__ = title,
		__CONCEPT__ = concept,
		__CORE_LOOP__ = plan.core_loop,
		__SESSION_TARGET__ = tostring(plan.session_target_minutes),
		__SIEGE_PERIOD__ = tostring(plan.siege.period_seconds),
		__SIEGE_DURATION__ = tostring(plan.siege.duration_seconds),
		__PILLARS__ = bulletList(plan.pillars),
		__SIEGE_STRUCTURE__ = plan.siege.structure,
		__RETENTION__ = retentionText,
		__EGG_LIST__ = joinEggs(economy),
		__CREATURE_LIST__ = joinCreatures(economy),
	})
end

--- Renders design/balance.md with the section-7 targets table the tuner enforced.
function M.renderBalance(economy: Economy, plan: any, tune: TuneResult, title: string, pack: string): string
	local targets = tune.targets
	local first = if targets ~= nil and targets.firstPurchaseMinutes ~= nil
		then string.format("%.1f min", targets.firstPurchaseMinutes)
		else "none"
	local day7 = if targets ~= nil then string.format("%+.2f%%", targets.day7GrowthPercent) else "n/a"
	local sink = if targets ~= nil then string.format("%.2f%%", targets.eggSinkPercent) else "n/a"

	local function status(ok: boolean?): string
		return if ok then "PASS" else "FAIL"
	end

	local lines: { string } = {}
	add(lines, "# " .. title .. " - Balance Targets")
	add(lines, "")
	add(lines, "Generated by `forge plan`; every number is sourced from `econ.yml` and checked with")
	add(lines, "`lune run cli/forge econ sim --pack " .. pack .. "`.")
	add(lines, "")
	add(lines, "## 7. Economy simulation targets")
	add(lines, "")
	add(
		lines,
		string.format(
			"Tuned with price multiplier `%s` and production multiplier `%s` after %d candidate(s) (seed %d, %d players, %d days).",
			fmtNum(tune.priceMultiplier),
			fmtNum(tune.productionMultiplier),
			tune.attempts,
			TUNE_SEED,
			TUNE_PLAYERS,
			TUNE_DAYS
		)
	)
	add(lines, "")
	add(lines, "| Target | Threshold | Measured | Status |")
	add(lines, "| --- | --- | --- | --- |")
	add(
		lines,
		string.format(
			"| Median first-purchase moment | %g-%g min | %s | %s |",
			plan.first_purchase_target_minutes[1],
			plan.first_purchase_target_minutes[2],
			first,
			status(if targets ~= nil then targets.firstPurchaseOk else nil)
		)
	)
	add(
		lines,
		string.format(
			"| Day-7 daily supply growth | <= %g%% | %s | %s |",
			plan.day7_growth_max_percent,
			day7,
			status(if targets ~= nil then targets.day7GrowthOk else nil)
		)
	)
	add(
		lines,
		string.format(
			"| Eggs share of coins spent | >= %g%% over %d days | %s | %s |",
			plan.egg_sink_min_percent,
			TUNE_DAYS,
			sink,
			status(if targets ~= nil then targets.eggSinkOk else nil)
		)
	)
	add(lines, "")
	add(lines, "Egg sink share is `spent on eggs / total coins produced` from the")
	add(lines, "`Total coins produced ...; spent on eggs ...` line of the econ-sim report.")
	add(lines, "")
	add(lines, "## Tuning knobs")
	add(lines, "")
	add(lines, "- `pricing.growthPerOwned` - " .. fmtNum(economy.growthPerOwned))
	add(lines, "- `income.activeSlots` - " .. fmtNum(economy.activeSlots))
	for _, egg in economy.eggs do
		add(
			lines,
			string.format(
				"- `eggs.%s.price` / `eggs.%s.hatchSeconds` - %d / %d",
				egg.id,
				egg.id,
				egg.price,
				egg.hatchSeconds
			)
		)
	end
	for _, creature in economy.kaiju do
		add(
			lines,
			string.format(
				"- `kaiju.%s` - %s, %s %s/s",
				creature.id,
				creature.rarity,
				fmtNum(creature.coinsPerSecond),
				economy.currency
			)
		)
	end
	add(lines, "")
	return table.concat(lines, "\n")
end

--- Renders design/monetization.md: the strategy, ladder, first-purchase target and
--- fairness rules. Robux products are deterministic by construction.
function M.renderMonetization(plan: any, economy: Economy, title: string): string
	local ladder = plan.monetization.price_ladder
	local lines: { string } = {}
	add(lines, "# " .. title .. " - Monetization")
	add(lines, "")
	add(lines, "## Strategy")
	add(lines, "")
	add(lines, "The store is a thank-you for players who enjoy the loop, never a gate. Every")
	add(lines, "Robux item is deterministic: the label names exactly what is granted, and random")
	add(lines, "hatching runs only on free `" .. economy.currency .. "`. There is no paid loot box.")
	add(lines, "")
	add(lines, "## Price ladder")
	add(lines, "")
	add(lines, "| Tier | Robux | Item |")
	add(lines, "| --- | ---: | --- |")
	for _, item in economy.monetization.gamepasses do
		add(lines, string.format("| pass/%s | %d | %s |", item.key, item.price, item.name))
	end
	for _, item in economy.monetization.products do
		add(lines, string.format("| product/%s | %d | %s |", item.key, item.price, item.name))
	end
	add(lines, "")
	add(
		lines,
		"Ladder source: `price_ladder` in `genres/collect-raid/econ-template.yml` (low "
			.. tostring(ladder.low)
			.. ", mid "
			.. tostring(ladder.mid)
			.. ", high "
			.. tostring(ladder.high)
			.. ", premium "
			.. tostring(ladder.premium)
			.. ")."
	)
	add(lines, "")
	add(lines, "## Game passes")
	add(lines, "")
	for _, item in economy.monetization.gamepasses do
		add(lines, string.format("- **%s** (%d Robux) - %s", item.name, item.price, item.effect))
	end
	add(lines, "")
	add(lines, "## Developer products")
	add(lines, "")
	for _, item in economy.monetization.products do
		add(lines, string.format("- **%s** (%d Robux) - %s", item.name, item.price, item.effect))
	end
	add(lines, "")
	add(lines, "## First-purchase moment")
	add(lines, "")
	add(
		lines,
		string.format(
			"The simulator spaces the first `%s`-blocked moment to %g-%g minutes, where the deterministic shelf (starting with the %d-Robux %s) is offered before the next egg becomes affordable.",
			economy.currency,
			plan.first_purchase_target_minutes[1],
			plan.first_purchase_target_minutes[2],
			economy.monetization.products[1].price,
			economy.monetization.products[1].name
		)
	)
	add(lines, "")
	add(lines, "## Fairness rules")
	add(lines, "")
	add(lines, bulletList(plan.fairness_rules))
	add(lines, "")
	return table.concat(lines, "\n")
end

--- Renders design/store-listing.md from the concept, roster and ratings flags.
function M.renderStoreListing(plan: any, economy: Economy, title: string, concept: string): string
	local lines: { string } = {}
	add(lines, "# " .. title .. " - Store Listing")
	add(lines, "")
	add(lines, "## Title and hook")
	add(lines, "")
	add(lines, "- English title: **" .. title .. "**")
	add(
		lines,
		"- One-line hook: **Raise the "
			.. title
			.. " roster, merge up a rarity, and siege the rival vault every "
			.. tostring(plan.siege.period_seconds / 60)
			.. " minutes.**"
	)
	add(lines, "- Concept source: `" .. concept .. "`")
	add(lines, "- Locales: `en-us` (`game.yml locales`).")
	add(lines, "")
	add(lines, "## Description (3 paragraphs)")
	add(lines, "")
	add(lines, "**Paragraph 1 - hatch and merge.** " .. plan.core_loop)
	add(lines, "")
	add(lines, "**Paragraph 2 - team siege.** " .. plan.siege.structure)
	add(lines, "")
	add(
		lines,
		"**Paragraph 3 - fair monetization.** Everything in the store is deterministic: paid Robux items say exactly what they grant, and egg odds never change. Random hatching runs on free "
			.. economy.currency
			.. " only, so no Robux is ever spent on a random roll."
	)
	add(lines, "")
	add(lines, "## Tags (" .. tostring(#plan.store_tags) .. ")")
	add(lines, "")
	for index, tag in plan.store_tags do
		add(lines, tostring(index) .. ". " .. tag)
	end
	add(lines, "")
	add(lines, "## Thumbnail / icon shot list")
	add(lines, "")
	add(lines, "1. **Icon** - a cracked egg with the " .. economy.kaiju[1].displayName .. " eye peeking out.")
	add(lines, "2. **Shot 1 - Hatch** - an incubator cracking open with the egg odds shown.")
	add(lines, "3. **Shot 2 - Roster** - the merge ladder from " .. economy.kaiju[1].displayName .. " upward.")
	add(lines, "4. **Shot 3 - Siege** - two-team vault standoff with the siege timer running.")
	add(lines, '5. **Shot 4 - Store** - the deterministic Robux shelf, labelled "no random rolls".')
	add(lines, "")
	add(lines, "## Maturity questionnaire answers")
	add(lines, "")
	add(lines, "| Category | Answer |")
	add(lines, "| --- | --- |")
	add(lines, "| Violence | " .. plan.ratings.violence .. " |")
	add(lines, "| Romance | " .. plan.ratings.romance .. " |")
	add(lines, "| Gambling | " .. plan.ratings.gambling .. " |")
	add(lines, "| Social | " .. plan.ratings.social .. " |")
	add(lines, "| Language | " .. plan.ratings.language .. " |")
	add(lines, "| Paid randomness | None - `paid_random: false`; every Robux item is deterministic. |")
	add(lines, "")
	return table.concat(lines, "\n")
end

--- Renders design/launch-checklist.md; user-only items are marked, never ticked.
function M.renderLaunchChecklist(plan: any, economy: Economy, title: string, pack: string, genre: string): string
	local lines: { string } = {}
	add(lines, "# " .. title .. " - Launch Checklist")
	add(lines, "")
	add(lines, "All items are unchecked. `USER DECISION` and `USER CONFIRMATION` items require the")
	add(lines, "owner to act; do not tick them from an automated run.")
	add(lines, "")
	add(lines, "## Build")
	add(lines, "")
	add(lines, "- [ ] `lune run cli/forge check` exits 0 on a clean checkout")
	add(lines, "- [ ] `lune run cli/forge codegen` output (`EconConfig`) matches `econ.yml`")
	add(lines, "- [ ] `default.project.json` builds the place without errors")
	add(lines, "- [ ] `assets/procgen.yml` matches the roster in `econ.yml`")
	add(lines, "- [ ] Server heartbeat and client FPS within budget")
	add(lines, "")
	add(lines, "## Content")
	add(lines, "")
	add(
		lines,
		"- [ ] First egg reachable from `currencies."
			.. economy.currency
			.. ".starting` "
			.. tostring(economy.startingCoins)
	)
	add(lines, "- [ ] Merge families wired: 3 Common -> Rare, 3 Rare -> Legendary")
	add(
		lines,
		string.format(
			"- [ ] Siege window: %d s open every %d s period, maxTake %d",
			plan.siege.duration_seconds,
			plan.siege.period_seconds,
			plan.siege.max_take
		)
	)
	for _, step in plan.tutorial_steps do
		add(lines, "- [ ] Tutorial step fires: " .. step)
	end
	add(lines, "- [ ] Egg odds panel shows each pool before purchase")
	add(lines, "")
	add(lines, "## Monetization")
	add(lines, "")
	for _, item in economy.monetization.gamepasses do
		add(lines, string.format("- [ ] Game pass configured: %s (%d Robux)", item.name, item.price))
	end
	for _, item in economy.monetization.products do
		add(lines, string.format("- [ ] Product configured: %s (%d Robux)", item.name, item.price))
	end
	add(lines, "- [ ] Every product is deterministic; no Robux path opens a random roll")
	add(lines, "- [ ] Product IDs replaced from `0` with live Roblox asset IDs")
	add(lines, "- [ ] Prices reviewed against `design/monetization.md`")
	add(lines, "")
	add(lines, "## Compliance")
	add(lines, "")
	add(lines, "- [ ] Maturity questionnaire submitted (mild fantasy violence only, no blood)")
	add(lines, "- [ ] No romance, no gambling, no paid randomness declared")
	add(lines, "- [ ] Probability disclosure shown on every egg purchase")
	add(lines, "- [ ] Social features limited to default Roblox chat")
	add(lines, "- [ ] Store listing text and thumbnails match `design/store-listing.md`")
	add(lines, "")
	add(lines, "## Ops")
	add(lines, "")
	add(lines, "- [ ] DataStore profile migration path tested")
	add(lines, "- [ ] Rejoin and offline-collection path tested")
	add(lines, "- [ ] Anticheat counters alarm at their sustained thresholds")
	add(lines, "- [ ] Rollback plan documented for the public switch")
	add(lines, "")
	add(lines, "## Publish")
	add(lines, "")
	add(lines, "- [ ] Group ownership needs 100 Robux (USER DECISION)")
	add(lines, "- [ ] Staging experience created")
	add(lines, "- [ ] Place uploaded to the staging experience")
	add(lines, "- [ ] Staging smoke test passed end to end")
	add(lines, "- [ ] Production Roblox asset IDs swapped into `game.yml`")
	add(lines, "- [ ] Public switch (USER CONFIRMATION)")
	add(lines, "")
	add(lines, "Pack: `" .. pack .. "` / genre: `" .. genre .. "`.")
	add(lines, "")
	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Validation helpers (used by specs)
-- ---------------------------------------------------------------------------

--- Validates the invariants the hard rules require: every pool sums to 1, every
--- Robux item is deterministic, and no generated title carries the theft pattern.
function M.validate(economy: Economy, title: string): { string }
	local errors: { string } = {}
	if M.containsStealPattern(title) then
		table.insert(errors, "title still matches the forbidden 'Steal a' pattern: " .. title)
	end
	for _, egg in economy.eggs do
		local sum = 0
		for _, entry in egg.pool do
			if entry.weight <= 0 then
				table.insert(errors, "egg " .. egg.id .. " has a non-positive weight")
			end
			sum += entry.weight
		end
		if math.abs(sum - 1) > 1e-9 then
			table.insert(errors, string.format("egg %s pool weights sum to %.6f, not 1", egg.id, sum))
		end
	end
	for _, item in economy.monetization.gamepasses do
		if not item.deterministic then
			table.insert(errors, "game pass " .. item.key .. " is not deterministic")
		end
	end
	for _, item in economy.monetization.products do
		if not item.deterministic then
			table.insert(errors, "product " .. item.key .. " is not deterministic")
		end
	end
	return errors
end

return M
