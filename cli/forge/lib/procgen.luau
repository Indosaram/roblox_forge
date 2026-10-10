--!strict
-- procgen: pure planning for `forge gen procedural`. Maps a pack's
-- assets/procgen.yml plus the game.yml poly_budget map into resolved specs -
-- the exact Creature/Prop spec, seed, and measured triangle count each asset
-- builds at runtime - and renders games/<pack>/src/shared/ProcAssets.luau.
--
-- Nothing here touches the filesystem or the network: the generators are pure
-- Luau (core/domain/procgen) and deterministic, so the CLI, the runtime module,
-- and the specs all agree byte for byte. No API keys are involved.

local Creature = require("../../../core/domain/procgen/Creature")
local Prop = require("../../../core/domain/procgen/Prop")

local M = {}

-- Version of the procedural geometry recipe (this module plus the core
-- Creature/Prop generators). Bump it whenever a change alters the mesh a spec
-- builds, so a recorded artifact names the exact recipe that produced it.
M.RECIPE_VERSION = "1"

export type Kind = "creature" | "prop"

export type Color = { r: number, g: number, b: number }

export type RawEntry = {
	key: string,
	kind: Kind,
	archetype: string,
	scale: number,
	body: Color,
	accent: Color,
	eye: Color?,
	-- Optional tree-canopy leaf colour; nil means Prop's fresh-green default.
	foliage: Color?,
	seed: number,
}

export type Resolved = {
	key: string,
	kind: Kind,
	archetype: string,
	spec: any,
	seed: number,
	triangleCount: number,
	budget: number,
}

local CREATURE_ARCHETYPES: { [string]: boolean } = {
	quad = true,
	serpent = true,
	titan = true,
	biped = true,
}

local PROP_ARCHETYPES: { [string]: boolean } = {
	egg = true,
	crystal = true,
	rock = true,
	tree = true,
	crate = true,
}

-- game.yml poly_budget fallbacks when a key is absent (see AGENTS.md art rules).
local DEFAULT_BUDGET = {
	creature = 3000,
	egg = 600,
	prop = 800,
}

local KEY_PATTERN = "^[%a][%w_%-]*$"

local function isPositiveNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value > 0 and value ~= math.huge
end

local function isSeed(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value % 1 == 0
end

-- Procgen colors are authored as [r, g, b] in 0-255; MeshBuilder wants 0-1.
local function asColor(value: any): Color?
	if typeof(value) ~= "table" or #value ~= 3 then
		return nil
	end
	local r = value[1]
	local g = value[2]
	local b = value[3]
	for _, channel in { r, g, b } do
		if typeof(channel) ~= "number" or channel ~= channel or channel < 0 or channel > 255 then
			return nil
		end
	end
	return { r = r / 255, g = g / 255, b = b / 255 }
end

--- Parses and schema-validates a decoded procgen.yml. Every problem is
--- reported; an empty errors list means the document is usable.
function M.parse(doc: any): ({ RawEntry }, { string })
	local entries: { RawEntry } = {}
	local errors: { string } = {}
	if typeof(doc) ~= "table" then
		return entries, { "procgen.yml: expected a table with an 'assets' list" }
	end
	local raw = doc.assets
	if typeof(raw) ~= "table" then
		return entries, { "procgen.yml: 'assets' must be a list" }
	end

	for index, item in raw do
		local where = "procgen.yml: asset " .. tostring(index)
		if typeof(item) ~= "table" then
			table.insert(errors, where .. " is not a table")
		else
			local key = item.key
			if typeof(key) ~= "string" or string.match(key, KEY_PATTERN) == nil then
				table.insert(errors, where .. " has invalid key '" .. tostring(key) .. "'")
			else
				where = "procgen.yml: asset " .. key
			end

			local kind = item.kind
			if kind ~= "creature" and kind ~= "prop" then
				table.insert(errors, where .. " has invalid kind '" .. tostring(kind) .. "'")
			end

			local archetype = item.archetype
			if typeof(archetype) ~= "string" then
				table.insert(errors, where .. " is missing an archetype")
			elseif kind == "creature" and not CREATURE_ARCHETYPES[archetype] then
				table.insert(errors, where .. " has invalid creature archetype '" .. archetype .. "'")
			elseif kind == "prop" and not PROP_ARCHETYPES[archetype] then
				table.insert(errors, where .. " has invalid prop archetype '" .. archetype .. "'")
			end

			if not isPositiveNumber(item.scale) then
				table.insert(errors, where .. " has an invalid scale")
			end

			local body = asColor(item.body)
			local accent = asColor(item.accent)
			if body == nil then
				table.insert(errors, where .. " has an invalid body color (expected [r, g, b] 0-255)")
			end
			if accent == nil then
				table.insert(errors, where .. " has an invalid accent color (expected [r, g, b] 0-255)")
			end

			local eye: Color? = nil
			if kind == "creature" then
				eye = asColor(item.eye)
				if eye == nil then
					table.insert(errors, where .. " has an invalid eye color (expected [r, g, b] 0-255)")
				end
			end

			-- Props may carry a separate foliage tone; when omitted the tree
			-- falls back to Prop's fresh-green default.
			local foliage: Color? = nil
			if kind == "prop" and item.foliage ~= nil then
				foliage = asColor(item.foliage)
				if foliage == nil then
					table.insert(errors, where .. " has an invalid foliage color (expected [r, g, b] 0-255)")
				end
			end

			if not isSeed(item.seed) then
				table.insert(errors, where .. " is missing an integer seed")
			end

			if
				body ~= nil
				and accent ~= nil
				and (kind == "creature" or kind == "prop")
				and typeof(archetype) == "string"
				and isPositiveNumber(item.scale)
				and isSeed(item.seed)
				and (kind ~= "creature" or eye ~= nil)
				and (item.foliage == nil or foliage ~= nil)
			then
				table.insert(entries, {
					key = item.key,
					kind = kind,
					archetype = archetype,
					scale = item.scale,
					body = body,
					accent = accent,
					eye = eye,
					foliage = foliage,
					seed = item.seed,
				})
			end
		end
	end

	return entries, errors
end

--- Resolves the triangle budget for one entry: creatures take the first of
--- poly_budget.kaiju|creature, eggs take egg, all other props take prop, each
--- with a fallback default.
function M.budgetFor(kind: string, archetype: string, polyBudget: any): number
	local budget: any = nil
	if typeof(polyBudget) == "table" then
		if kind == "creature" then
			budget = polyBudget.kaiju
			if not isPositiveNumber(budget) then
				budget = polyBudget.creature
			end
		elseif archetype == "egg" then
			budget = polyBudget.egg
		else
			budget = polyBudget.prop
		end
	end
	if isPositiveNumber(budget) then
		return budget
	end
	if kind == "creature" then
		return DEFAULT_BUDGET.creature
	end
	if archetype == "egg" then
		return DEFAULT_BUDGET.egg
	end
	return DEFAULT_BUDGET.prop
end

--- Builds each entry's runtime spec, generates the mesh once to measure its
--- triangle count, and flags any asset that still exceeds its budget.
function M.resolve(entries: { RawEntry }, polyBudget: any): ({ Resolved }, { string })
	local resolved: { Resolved } = {}
	local errors: { string } = {}
	for _, entry in entries do
		local budget = M.budgetFor(entry.kind, entry.archetype, polyBudget)
		local spec: any
		local mesh: any
		if entry.kind == "creature" then
			spec = {
				archetype = entry.archetype,
				scale = entry.scale,
				body = entry.body,
				accent = entry.accent,
				eye = entry.eye,
				polyBudget = budget,
			}
			mesh = Creature.generate(spec, entry.seed)
		else
			spec = {
				scale = entry.scale,
				body = entry.body,
				accent = entry.accent,
				foliage = entry.foliage,
				polyBudget = budget,
			}
			mesh = Prop.generate(entry.archetype :: any, spec, entry.seed)
		end

		local triangleCount = mesh.triangleCount
		if triangleCount > budget then
			table.insert(
				errors,
				string.format(
					"%s %s/%s tris=%d budget=%d exceeds budget",
					entry.key,
					entry.kind,
					entry.archetype,
					triangleCount,
					budget
				)
			)
		end
		table.insert(resolved, {
			key = entry.key,
			kind = entry.kind,
			archetype = entry.archetype,
			spec = spec,
			seed = entry.seed,
			triangleCount = triangleCount,
			budget = budget,
		})
	end
	return resolved, errors
end

--- Parses and resolves a decoded procgen.yml. Returns (resolved, errors); a
--- structural parse failure yields (nil, errors).
function M.plan(doc: any, polyBudget: any): ({ Resolved }?, { string })
	local entries, parseErrors = M.parse(doc)
	if #parseErrors > 0 then
		return nil, parseErrors
	end
	return M.resolve(entries, polyBudget)
end

local function quote(value: string): string
	local escaped = string.gsub(value, "\\", "\\\\")
	escaped = string.gsub(escaped, '"', '\\"')
	escaped = string.gsub(escaped, "\n", "\\n")
	return '"' .. escaped .. '"'
end

local function formatNumber(value: number): string
	if value % 1 == 0 and math.abs(value) < 9007199254740992 then
		return string.format("%d", value)
	end
	return tostring(value)
end

local function formatColor(color: any): string
	return string.format(
		"{ r = %s, g = %s, b = %s }",
		formatNumber(color.r),
		formatNumber(color.g),
		formatNumber(color.b)
	)
end

--- Renders the generated ProcAssets.luau specs module (key -> kind, archetype,
--- spec, seed, triangleCount), sorted by key so re-runs are byte-identical.
function M.renderLuau(resolved: { Resolved }): string
	local sorted = table.clone(resolved)
	table.sort(sorted, function(a, b)
		return a.key < b.key
	end)

	local lines: { string } = {
		"-- GENERATED by forge gen procedural; do not edit.",
		"",
		"--!strict",
		"",
		"local ProcAssetsSpecs: { [string]: any } = {",
	}
	for _, entry in sorted do
		local spec = entry.spec
		table.insert(lines, "\t[" .. quote(entry.key) .. "] = {")
		table.insert(lines, "\t\tkind = " .. quote(entry.kind) .. ",")
		table.insert(lines, "\t\tarchetype = " .. quote(entry.archetype) .. ",")
		table.insert(lines, "\t\tspec = {")
		if entry.kind == "creature" then
			table.insert(lines, "\t\t\tarchetype = " .. quote(entry.archetype) .. ",")
		end
		table.insert(lines, "\t\t\tscale = " .. formatNumber(spec.scale) .. ",")
		table.insert(lines, "\t\t\tpolyBudget = " .. formatNumber(spec.polyBudget) .. ",")
		table.insert(lines, "\t\t\tbody = " .. formatColor(spec.body) .. ",")
		table.insert(lines, "\t\t\taccent = " .. formatColor(spec.accent) .. ",")
		if entry.kind == "creature" then
			table.insert(lines, "\t\t\teye = " .. formatColor(spec.eye) .. ",")
		elseif spec.foliage ~= nil then
			table.insert(lines, "\t\t\tfoliage = " .. formatColor(spec.foliage) .. ",")
		end
		table.insert(lines, "\t\t},")
		table.insert(lines, "\t\tseed = " .. formatNumber(entry.seed) .. ",")
		table.insert(lines, "\t\ttriangleCount = " .. formatNumber(entry.triangleCount) .. ",")
		table.insert(lines, "\t},")
	end
	table.insert(lines, "}")
	table.insert(lines, "")
	table.insert(lines, "return ProcAssetsSpecs")
	return table.concat(lines, "\n") .. "\n"
end

--- Regenerates the mesh a resolved entry names. Pure and deterministic, so the
--- OBJ preview matches exactly what the runtime rebuilds from ProcAssets.
function M.buildMesh(entry: Resolved): any
	if entry.kind == "creature" then
		return Creature.generate(entry.spec, entry.seed)
	end
	return Prop.generate(entry.archetype :: any, entry.spec, entry.seed)
end

--- Serialises mesh data to Wavefront OBJ (positions, normals, index triples).
function M.renderObj(mesh: any): string
	local lines: { string } = { "# GENERATED by forge gen procedural --obj" }
	for _, p in mesh.vertices do
		table.insert(lines, string.format("v %.6f %.6f %.6f", p.x, p.y, p.z))
	end
	for _, n in mesh.normals do
		table.insert(lines, string.format("vn %.6f %.6f %.6f", n.x, n.y, n.z))
	end
	for _, tri in mesh.triangles do
		table.insert(lines, string.format("f %d//%d %d//%d %d//%d", tri[1], tri[1], tri[2], tri[2], tri[3], tri[3]))
	end
	return table.concat(lines, "\n") .. "\n"
end

return M
