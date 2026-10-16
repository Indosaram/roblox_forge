--!strict
-- Catalog: engine-free validation for the monetization catalog (gamepasses and developer products).

local Catalog = {}

export type GrantKind =
	"multiplier"
	| "slots"
	| "flag"
	| "kaiju"
	| "speedup"
	| "shield"
	| "serverBoost"
	| "coins"
	-- Survival grants (plan §8.1): deterministic, fixed effects only.
	| "storageSlots"
	| "characterSlot"
	| "cosmeticSet"
	| "respecToken"
	| "subscriptionMonthly"

export type Grant = {
	kind: GrantKind,
	kaijuId: string?,
	amount: number?,
	-- cosmeticSet / subscriptionMonthly: the fixed cosmetic set granted.
	cosmeticSetId: string?,
	-- subscriptionMonthly: storage slots that stay writable while subscribed.
	storageSlots: number?,
}

export type Entry = {
	key: string,
	name: string,
	price: number,
	grant: Grant,
}

export type Catalog = {
	gamepasses: { Entry }?,
	products: { Entry }?,
	subscriptions: { Entry }?,
}

-- Robux must never buy a random item; these kinds and fields are forbidden.
local BANNED_KINDS: { [string]: boolean } = { random = true, roll = true, egg = true }

local GAMEPASS_KINDS: { [string]: boolean } = {
	multiplier = true,
	slots = true,
	flag = true,
	storageSlots = true,
	characterSlot = true,
}

local PRODUCT_KINDS: { [string]: boolean } = {
	kaiju = true,
	speedup = true,
	shield = true,
	serverBoost = true,
	coins = true,
	cosmeticSet = true,
	respecToken = true,
}

local SUBSCRIPTION_KINDS: { [string]: boolean } = { subscriptionMonthly = true }

local function isNonEmptyString(value: any): boolean
	return type(value) == "string" and value ~= ""
end

local function isPositiveInteger(value: any): boolean
	if type(value) ~= "number" then
		return false
	end
	return value == value and value > 0 and value ~= math.huge and value % 1 == 0
end

local function validateGrant(key: string, grant: any, allowedKinds: { [string]: boolean }): string?
	if type(grant) ~= "table" then
		return "invalid grant: " .. key
	end
	local kind = grant.kind
	if type(kind) ~= "string" then
		return "invalid grant kind: " .. key
	end
	if BANNED_KINDS[kind] or grant.pool ~= nil or grant.odds ~= nil then
		return "paid random item: " .. key
	end
	if kind == "kaiju" and not isNonEmptyString(grant.kaijuId) then
		return "kaiju grant requires a fixed kaijuId: " .. key
	end
	if not allowedKinds[kind] then
		return "invalid grant kind: " .. key
	end
	if kind == "coins" and not isPositiveInteger(grant.amount) then
		return "coins grant requires a positive integer amount: " .. key
	end
	if (kind == "storageSlots" or kind == "characterSlot") and not isPositiveInteger(grant.amount) then
		return kind .. " grant requires a positive integer amount: " .. key
	end
	if kind == "respecToken" and grant.amount ~= nil and not isPositiveInteger(grant.amount) then
		return "respecToken grant amount must be a positive integer: " .. key
	end
	if (kind == "cosmeticSet" or kind == "subscriptionMonthly") and not isNonEmptyString(grant.cosmeticSetId) then
		return kind .. " grant requires a fixed cosmeticSetId: " .. key
	end
	if kind == "subscriptionMonthly" and not isPositiveInteger(grant.storageSlots) then
		return "subscriptionMonthly grant requires positive integer storageSlots: " .. key
	end
	return nil
end

local function validateSection(section: any, allowedKinds: { [string]: boolean }, seen: { [string]: boolean }): string?
	if section == nil then
		return nil
	end
	if type(section) ~= "table" then
		return "invalid catalog section"
	end
	for _, entry in section do
		if type(entry) ~= "table" then
			return "invalid entry"
		end
		local key = entry.key
		if not isNonEmptyString(key) then
			return "invalid key"
		end
		if seen[key] then
			return "duplicate key: " .. key
		end
		seen[key] = true
		if not isNonEmptyString(entry.name) then
			return "invalid name: " .. key
		end
		if not isPositiveInteger(entry.price) then
			return "invalid price: " .. key
		end
		local grantError = validateGrant(key, entry.grant, allowedKinds)
		if grantError ~= nil then
			return grantError
		end
	end
	return nil
end

-- Accepts untrusted catalog data and returns (true) or (false, reason).
function Catalog.validate(catalog: any): (boolean, string?)
	if type(catalog) ~= "table" then
		return false, "invalid catalog"
	end
	local seen: { [string]: boolean } = {}
	local gamepassError = validateSection(catalog.gamepasses, GAMEPASS_KINDS, seen)
	if gamepassError ~= nil then
		return false, gamepassError
	end
	local productError = validateSection(catalog.products, PRODUCT_KINDS, seen)
	if productError ~= nil then
		return false, productError
	end
	local subscriptionError = validateSection(catalog.subscriptions, SUBSCRIPTION_KINDS, seen)
	if subscriptionError ~= nil then
		return false, subscriptionError
	end
	return true
end

-- ADR-07 BM hard rules as a lint over untrusted monetization data (game.yml
-- `monetization` or a Catalog). Field names are split into lowercase words
-- (camelCase, `_`, `-`, digits), so `dropRate`, `luck_mult` and `oddsPct` all
-- match. Values (names, keys) are not inspected; only field names and kinds.

-- Rule paid-random: Robux never buys a pool, odds or any chance-based outcome.
local RANDOM_WORDS: { [string]: boolean } = {
	pool = true,
	pools = true,
	odds = true,
	chance = true,
	chances = true,
	probability = true,
	probabilities = true,
	random = true,
	roll = true,
	rolls = true,
	reroll = true,
	gacha = true,
	loot = true,
}
-- Rule luck-drop-boost: no luck, drop-rate or rate-up effects (ADR-07 rule 2).
local BOOST_WORDS: { [string]: boolean } = {
	luck = true,
	lucky = true,
	drop = true,
	drops = true,
	rate = true,
	rates = true,
}
-- Rule soft-currency-sale: Robux never converts into the soft currency (ADR-07 rule 1).
local CURRENCY_WORDS: { [string]: boolean } = { currency = true, currencies = true, coin = true, coins = true }
-- Rule mixed-random: no paid input into a random combine/upgrade (ADR-07 rule 3).
local MIXED_WORDS: { [string]: boolean } = { enhance = true, fuse = true, fusion = true, infuse = true }

local LINT_KIND_RULES: { [string]: string } = {
	random = "paid-random",
	roll = "paid-random",
	egg = "paid-random",
	coins = "soft-currency-sale",
	currency = "soft-currency-sale",
	-- Free-currency gain multipliers and server luck boosts (ADR-07 rule 2).
	multiplier = "luck-drop-boost",
	serverBoost = "luck-drop-boost",
}

-- Only these grant fields may appear on a subscription (ADR-07 rule 4).
local SUBSCRIPTION_GRANT_FIELDS: { [string]: boolean } = { kind = true, cosmeticSetId = true, storageSlots = true }

local function fieldWords(name: string): { string }
	local spaced = string.gsub(name, "(%l)(%u)", "%1 %2")
	spaced = string.gsub(spaced, "(%u)(%u%l)", "%1 %2")
	spaced = string.gsub(spaced, "[%d_%-%.]+", " ")
	local words: { string } = {}
	for word in string.gmatch(spaced, "%a+") do
		table.insert(words, string.lower(word))
	end
	return words
end

local function ruleForField(name: string): string?
	for _, word in fieldWords(name) do
		if RANDOM_WORDS[word] then
			return "paid-random"
		elseif BOOST_WORDS[word] then
			return "luck-drop-boost"
		elseif CURRENCY_WORDS[word] then
			return "soft-currency-sale"
		elseif MIXED_WORDS[word] then
			return "mixed-random"
		end
	end
	return nil
end

local function sortedKeys(value: { [any]: any }): { string }
	local keys: { string } = {}
	for key in value do
		if type(key) == "string" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	return keys
end

local function lintFields(value: any, path: string, entryKey: string, out: { string }, depth: number)
	if type(value) ~= "table" or depth > 8 then
		return
	end
	for _, name in sortedKeys(value) do
		local rule = ruleForField(name)
		if rule ~= nil then
			table.insert(out, string.format("%s: %s (field %s%s)", rule, entryKey, path, name))
		end
		lintFields(value[name], path .. name .. ".", entryKey, out, depth + 1)
	end
	for index, child in ipairs(value) do
		lintFields(child, path .. tostring(index) .. ".", entryKey, out, depth + 1)
	end
end

local function lintSection(section: any, sectionName: string, out: { string })
	if type(section) ~= "table" then
		return
	end
	for index, entry in ipairs(section) do
		if type(entry) == "table" then
			local entryKey = if isNonEmptyString(entry.key)
				then entry.key
				else sectionName .. "[" .. tostring(index) .. "]"
			lintFields(entry, "", entryKey, out, 0)
			local grant = entry.grant
			-- game.yml entries carry `kind` at the top level; catalogs carry it on the grant.
			for _, kind in { entry.kind, if type(grant) == "table" then grant.kind else nil } do
				if type(kind) == "string" then
					local kindRule = LINT_KIND_RULES[kind] or ruleForField(kind)
					if kindRule ~= nil then
						table.insert(out, string.format("%s: %s (kind %s)", kindRule, entryKey, kind))
					end
				end
			end
			if sectionName == "subscriptions" then
				if type(grant) == "table" then
					if grant.kind ~= nil and grant.kind ~= "subscriptionMonthly" then
						table.insert(
							out,
							string.format("subscription-effect: %s (grant kind %s)", entryKey, tostring(grant.kind))
						)
					end
					for _, name in sortedKeys(grant) do
						if not SUBSCRIPTION_GRANT_FIELDS[name] then
							table.insert(out, string.format("subscription-effect: %s (field grant.%s)", entryKey, name))
						end
					end
				end
			end
		end
	end
end

--- Returns every ADR-07 violation as "<rule>: <key> (<where>)", in catalog
--- order; an empty list means the catalog is clean. Rules: paid-random,
--- luck-drop-boost, soft-currency-sale, mixed-random, subscription-effect.
function Catalog.lint(catalog: any): { string }
	local out: { string } = {}
	if type(catalog) ~= "table" then
		return out
	end
	for _, sectionName in { "gamepasses", "products", "subscriptions" } do
		lintSection(catalog[sectionName], sectionName, out)
	end
	return out
end

return Catalog
