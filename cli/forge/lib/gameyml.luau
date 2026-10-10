--!strict
-- gameyml: pure schema validation for a pack's games/<pack>/game.yml.
-- Nothing here touches the filesystem, so the check [game] stage and the specs
-- share the exact same logic. `TBD` is the placeholder `forge new` writes into a
-- fresh scaffold; it must be replaced before the pack can pass check.

local contract = require("./genrecontract")
local registryLib = require("./genreregistry")
local M = {}
export type Context = { registry: registryLib.Registry, config: any? }

export type CheckResult = { ok: boolean, errors: { string } }

local REQUIRED_STRINGS = { "name", "slug" }

local function isNonEmptyString(value: any): boolean
	return type(value) == "string" and value ~= ""
end

-- Case-insensitive so a hand-written "tbd" is caught too.
local function isTbd(value: any): boolean
	return type(value) == "string" and string.upper(value) == "TBD"
end

--- Validates a decoded game.yml. Every problem is reported so one run names all
--- of them; an empty errors list means the config is complete.
function M.validate(yamlTable: any, context: Context?): CheckResult
	local errors: { string } = {}
	if type(yamlTable) ~= "table" then
		return { ok = false, errors = { "game.yml: expected a table" } }
	end

	for _, field in REQUIRED_STRINGS do
		if not isNonEmptyString(yamlTable[field]) then
			table.insert(errors, "game.yml: missing a non-empty '" .. field .. "'")
		end
	end

	local genres = yamlTable.genres
	if not contract.dense(genres, 64) or #genres == 0 then
		table.insert(errors, "game.yml: 'genres' must be a non-empty list")
	else
		local seen = {}
		for _, id in genres do
			if not contract.id(id) or seen[id] then
				table.insert(errors, "game.yml: invalid/duplicate genre " .. tostring(id))
			end
			seen[id] = true
			if context and context.registry.packages[id] == nil then
				table.insert(errors, "game.yml: unknown genre " .. tostring(id))
			end
		end
	end
	if yamlTable.genre_contract ~= nil then
		if yamlTable.genre_contract ~= 1 then
			table.insert(errors, "game.yml: unsupported genre_contract")
		end
		if context then
			local config = context.config
			if type(config) ~= "table" or type(config.genre_contract) ~= "table" then
				table.insert(errors, "game.yml: missing genre config source")
			else
				for _, err in contract.validatePack(config.genre_contract, context.registry.runtimes) do
					table.insert(errors, err)
				end
				if
					not contract.dense(genres, 64)
					or not contract.dense(config.genre_contract.order, 64)
					or contract.serialize(genres) ~= contract.serialize(config.genre_contract.order)
				then
					table.insert(errors, "game.yml: genres differ from config order")
				end
			end
		end
	end

	local artStyle = yamlTable.art_style
	if isTbd(artStyle) then
		table.insert(errors, "game.yml: 'art_style' is still TBD; write the pack's art direction")
	elseif not isNonEmptyString(artStyle) then
		table.insert(errors, "game.yml: 'art_style' must be a non-empty string")
	end

	local polyBudget = yamlTable.poly_budget
	if isTbd(polyBudget) then
		table.insert(errors, "game.yml: 'poly_budget' is still TBD; fill in the triangle budgets")
	elseif type(polyBudget) ~= "table" then
		table.insert(errors, "game.yml: 'poly_budget' must be a table of per-mesh triangle budgets")
	elseif next(polyBudget) == nil then
		table.insert(errors, "game.yml: 'poly_budget' is empty")
	else
		for key, value in pairs(polyBudget) do
			if type(value) ~= "number" or value <= 0 or value ~= math.floor(value) then
				table.insert(errors, "game.yml: poly_budget." .. tostring(key) .. " must be a positive integer")
			end
		end
	end

	-- The one language a generated pack renders: every HUD string is resolved
	-- through the pack's locale table at this code, so one capture shows one
	-- language. A pack without the block renders `en`.
	local localeBlock = yamlTable.locale
	if localeBlock ~= nil then
		if type(localeBlock) ~= "table" then
			table.insert(errors, "game.yml: 'locale' must be a mapping")
		else
			for key in localeBlock do
				if key ~= "default" then
					table.insert(errors, "game.yml: locale." .. tostring(key) .. " is not a supported field")
				end
			end
			local default = localeBlock.default
			if type(default) ~= "string" or string.match(default, "^[a-z][a-z]$") == nil then
				table.insert(errors, "game.yml: locale.default must be a two-letter language code")
			end
		end
	end

	return { ok = #errors == 0, errors = errors }
end

return M
