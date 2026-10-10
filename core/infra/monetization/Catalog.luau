--!strict
-- Catalog: engine-free validation for the monetization catalog (gamepasses and developer products).

local Catalog = {}

export type GrantKind = "multiplier" | "slots" | "flag" | "kaiju" | "speedup" | "shield" | "serverBoost" | "coins"

export type Grant = {
	kind: GrantKind,
	kaijuId: string?,
	amount: number?,
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
}

-- Robux must never buy a random item; these kinds and fields are forbidden.
local BANNED_KINDS: { [string]: boolean } = { random = true, roll = true, egg = true }

local GAMEPASS_KINDS: { [string]: boolean } = { multiplier = true, slots = true, flag = true }

local PRODUCT_KINDS: { [string]: boolean } = {
	kaiju = true,
	speedup = true,
	shield = true,
	serverBoost = true,
	coins = true,
}

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
	return true
end

return Catalog
