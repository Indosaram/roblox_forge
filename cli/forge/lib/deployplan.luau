--!strict
-- DeployPlan: offline, network-free planning for `forge deploy`.
-- Reads a pack's monetization catalog and deploy assets and produces a
-- deterministic plan of product create/update actions plus the asset list.
-- The paid-random-item rules mirror core/infra/monetization/Catalog.luau:
-- Robux buys deterministic items only, so any random kind or pool/odds/random
-- field is refused with "paid random item: <key>".

local qualitygate = require("./qualitygate")
local M = {}

export type Action = "create" | "update"
export type Section = "gamepass" | "product"

export type Item = {
	section: Section,
	action: Action,
	key: string,
	name: string,
	price: number,
	id: number,
}

export type Asset = {
	group: string,
	id: string,
	path: string,
}

export type Plan = {
	pack: string,
	env: string,
	items: { Item },
	assets: { Asset },
	quality: qualitygate.Result?,
	externalReleaseAuthorized: boolean,
	apiVerified: boolean,
}

-- Mirror of Catalog's banned kinds. `egg`/`roll`/`random` kinds and any
-- pool/odds/random field on an entry mark it as a paid random item.
local BANNED_KINDS: { [string]: boolean } = { random = true, roll = true, egg = true }

local function isNonEmptyString(value: any): boolean
	return type(value) == "string" and value ~= ""
end

local function isPositiveInteger(value: any): boolean
	if type(value) ~= "number" then
		return false
	end
	return value == value and value > 0 and value ~= math.huge and value % 1 == 0
end

local function isRandomItem(entry: any): boolean
	if type(entry.kind) == "string" and BANNED_KINDS[entry.kind] then
		return true
	end
	return entry.pool ~= nil or entry.odds ~= nil or entry.random ~= nil
end

local function planSection(section: Section, entries: any, items: { Item }): string?
	if entries == nil then
		return nil
	end
	if type(entries) ~= "table" then
		return "invalid monetization section: " .. section
	end
	for _, entry in entries do
		if type(entry) ~= "table" then
			return "invalid entry in " .. section
		end
		local key = entry.key
		if not isNonEmptyString(key) then
			return "invalid key in " .. section
		end
		if isRandomItem(entry) then
			return "paid random item: " .. key
		end
		if not isNonEmptyString(entry.name) then
			return "invalid name: " .. key
		end
		if not isPositiveInteger(entry.price) then
			return "invalid price: " .. key
		end
		local id = entry.id
		if id == nil then
			id = 0
		end
		if type(id) ~= "number" or id < 0 or id % 1 ~= 0 then
			return "invalid id: " .. key
		end
		table.insert(items, {
			section = section,
			action = if id == 0 then "create" else "update",
			key = key,
			name = entry.name,
			price = entry.price,
			id = id,
		})
	end
	return nil
end

local function collectAssets(assets: any): { Asset }
	local list: { Asset } = {}
	if type(assets) ~= "table" then
		return list
	end
	local groups: { string } = {}
	for group in assets do
		if type(group) == "string" then
			table.insert(groups, group)
		end
	end
	table.sort(groups)
	for _, group in groups do
		local entries = assets[group]
		if type(entries) == "table" then
			for _, asset in entries do
				if type(asset) == "table" and isNonEmptyString(asset.id) and isNonEmptyString(asset.path) then
					table.insert(list, { group = group, id = asset.id, path = asset.path })
				end
			end
		end
	end
	return list
end

--- Builds a deterministic plan from decoded game.yml monetization and
--- deploy.yml assets. Returns (nil, reason) on a refusal.
function M.buildPlan(
	pack: string,
	env: string,
	monetization: any,
	assets: any,
	quality: qualitygate.Result?
): (Plan?, string?)
	if env ~= "staging" and env ~= "production" then
		return nil, "invalid deployment environment"
	end
	if env == "production" and (quality == nil or not quality.ok or not quality.releaseApproved) then
		return nil, "production plan requires current release approval"
	end
	if quality ~= nil and not quality.ok then
		return nil, "quality gate refused deployment plan"
	end
	if type(monetization) ~= "table" then
		return nil, "invalid monetization"
	end
	local items: { Item } = {}
	local gamepassError = planSection("gamepass", monetization.gamepasses, items)
	if gamepassError ~= nil then
		return nil, gamepassError
	end
	local productError = planSection("product", monetization.products, items)
	if productError ~= nil then
		return nil, productError
	end
	return {
		pack = pack,
		env = env :: string,
		items = items,
		assets = collectAssets(assets),
		quality = quality,
		externalReleaseAuthorized = false,
		apiVerified = false,
	},
		nil
end

--- Renders the plan as a byte-stable markdown report (no timestamps).
function M.render(plan: Plan): string
	local lines: { string } = {}
	table.insert(lines, "# Deploy plan: " .. plan.pack .. " (" .. plan.env .. ")")
	table.insert(lines, "")
	table.insert(lines, "Offline plan only: no credential verification, API proof, or external release authorization.")
	if plan.quality then
		table.insert(
			lines,
			"Quality: " .. plan.quality.code .. "; releaseApproved=" .. tostring(plan.quality.releaseApproved)
		)
		table.insert(lines, "Human production authorization remains separate from quality approval.")
		table.insert(lines, "")
	end
	table.insert(lines, "## Monetization")
	table.insert(lines, "")
	table.insert(lines, "| section | action | key | name | price | id | deterministic |")
	table.insert(lines, "| --- | --- | --- | --- | --- | --- | --- |")
	for _, item in plan.items do
		table.insert(
			lines,
			string.format(
				"| %s | %s | %s | %s | %d | %d | yes |",
				item.section,
				item.action,
				item.key,
				item.name,
				item.price,
				item.id
			)
		)
	end
	table.insert(lines, "")
	table.insert(lines, "## Assets")
	table.insert(lines, "")
	table.insert(lines, "| group | id | path |")
	table.insert(lines, "| --- | --- | --- |")
	for _, asset in plan.assets do
		table.insert(lines, string.format("| %s | %s | %s |", asset.group, asset.id, asset.path))
	end
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

return M
