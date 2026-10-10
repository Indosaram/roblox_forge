--!strict
-- genrespec: the declarative genre spec (`genres/<id>/genre-spec.yml`) — schema,
-- loader and validator.
--
-- The spec is a *binding* document. Every rule it names already exists in
-- `core/domain` or `genres/<id>/module`; the spec only names it so presentation,
-- world and QA can be derived from one source. It computes no outcome, so
-- `Executor` stays the only validator. A value that already lives in
-- `PackConfig.configs[<id>]` is stored as a path into that config, never as a copy.
--
-- A malformed spec fails `genreregistry.discover`, exactly as a malformed
-- generator does, so `forge new`, `forge plan`, `forge check`, `forge sweep`,
-- `forge build` and `forge qa` all refuse to run against it.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Validation = require("../../../core/domain/genre/Validation")
local Options = require("../../../core/infra/genre/Options")
local HudText = require("../../../core/ui-kit/genre/HudText")
local WorldFeedback = require("../../../core/ui-kit/genre/WorldFeedback")
local qascenario = require("./qascenario")
local qagen = require("./qagen")
local audiocues = require("./audiocues")

local M = {}

M.FILE = "genre-spec.yml"
M.API = 1

--- The closed entity vocabulary: every kind a genre generator already emits.
M.ENTITY_KINDS = {
	"source",
	"creature",
	"egg",
	"merge-family",
	"crop",
	"plot",
	"boss",
	"quest",
	"outfit",
	"theme",
	"round",
	"item",
	"recipe",
	"structure",
	"wildlife",
	"defense",
}

local ENTITY_KIND_SET: { [string]: boolean } = {}
for _, kind in M.ENTITY_KINDS do
	ENTITY_KIND_SET[kind] = true
end

M.ZONE_KINDS = { "plaza", "base", "arena", "wild" }
-- The languages a genre spec must carry for every key it declares. `en` is the
-- source language: the spec's declared display text is its translation, so only
-- the other codes need an explicit string. A pack renders one of them (see
-- `M.localeDefault`), which is what keeps a HUD from mixing scripts.
M.LOCALE_CODES = { "en", "ko" }
M.DEFAULT_LOCALE = "en"
-- The language the spec's declared display text is written in.
M.SOURCE_LOCALE = "en"
M.NODE_KINDS = { "node", "incubator", "station", "depot" }
M.CONTROL_KINDS = { "button", "prompt", "player-button" }
M.NOTIFICATION_KINDS = { "info", "refuse", "reward" }
M.SLOTS = { "resource-bar", "action-bar", "inventory-grid", "objective", "notifications" }

local ZONE_KIND_SET: { [string]: boolean } = {}
for _, kind in M.ZONE_KINDS do
	ZONE_KIND_SET[kind] = true
end
local NODE_KIND_SET: { [string]: boolean } = {}
for _, kind in M.NODE_KINDS do
	NODE_KIND_SET[kind] = true
end
local CONTROL_KIND_SET: { [string]: boolean } = {}
for _, kind in M.CONTROL_KINDS do
	CONTROL_KIND_SET[kind] = true
end

local SPEC_KEYS = {
	"api",
	"version",
	"id",
	"runtime",
	"resources",
	"entities",
	"actions",
	"loop",
	"ui",
	"world",
	"audio",
	"economy",
	"qa",
	"overrides",
	"locale",
	"draft",
}
local UI_KEYS = { "resourceBar", "actionButtons", "inventoryGrid", "objective", "notifications" }
local OVERRIDE_KEYS = { "client", "world", "audio", "uiTargets" }
local SIMULATION_KEYS = { "sourceTotal", "sinkTotal", "rejectionRate" }
-- A simulation target is a comparison of the form `<op><number>` (`>0`, `<0.2`).
-- Lua patterns have no alternation, so the operator is a character class.
local SIMULATION_COMPARISON = "^[<>=]+%-?%d+%.?%d*$"

local function firstLine(value: any): string
	local text = tostring(value)
	return string.match(text, "^[^\r\n]+") or text
end

local function isKey(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 64 and string.match(value, "^[%a][%w_%-]*$") ~= nil
end

local function isFinite(value: any): boolean
	return Validation.finite(value)
end

local function isTriple(value: any): boolean
	if not Validation.dense(value, 3) or #value ~= 3 then
		return false
	end
	for _, axis in value do
		if not isFinite(axis) then
			return false
		end
	end
	return true
end

local function isPositiveTriple(value: any): boolean
	if not isTriple(value) then
		return false
	end
	for _, axis in value do
		if axis <= 0 then
			return false
		end
	end
	return true
end

local function indexOf(list: { string }, value: any): number?
	for index, entry in list do
		if entry == value then
			return index
		end
	end
	return nil
end

--- Keys a genre declares for its own procedural and audio assets, read from
--- `genres/<id>/assets/*.yml`, split by declaration site. A genre whose
--- generator renders its asset list itself (collect-raid's planner) ships no
--- such directory; its asset keys are then only checked against the pack by
--- `forge sweep`.
local function declaredAssetKeys(genrePath: string): any
	local sets: any = { assets = {}, cues = {} }
	local dir = genrePath .. "/assets"
	if not fs.isDir(dir) then
		return sets
	end
	for _, name in fs.readDir(dir) do
		if string.match(name, "%.yml$") == nil then
			continue
		end
		local ok, decoded = pcall(function()
			return serde.decode("yaml", fs.readFile(dir .. "/" .. name))
		end)
		if not ok or type(decoded) ~= "table" then
			continue
		end
		for _, pair in { { "assets", "assets" }, { "cues", "cues" } } do
			local list = decoded[pair[1]]
			for _, entry in (if type(list) == "table" then list else {}) do
				if type(entry) == "table" and type(entry.key) == "string" then
					sets[pair[2]][entry.key] = true
				end
			end
		end
	end
	return sets
end

M.declaredAssetKeys = declaredAssetKeys

--- Ordered control ids the spec declares, i.e. the `GenreUI.luau` the renderer
--- derives from `ui.actionButtons`.
function M.controlIds(spec: any): { string }
	local ids: { string } = {}
	for _, row in (if type(spec) == "table" and type(spec.actions) == "table" then spec.actions else {}) do
		if type(row) == "table" and type(row.control) == "table" and type(row.control.id) == "string" then
			table.insert(ids, row.control.id)
		end
	end
	return ids
end

--- The declared control descriptors, in spec order, in `Options.Control` shape.
--- `label` is the control's *display* string: a spec that declares only a
--- labelKey has no player-facing text to render, so there is no key fallback
--- here. `validate` rejects such a spec before this is ever read.
function M.controls(spec: any): { any }
	local controls: { any } = {}
	for _, row in (if type(spec) == "table" and type(spec.actions) == "table" then spec.actions else {}) do
		if type(row) == "table" and type(row.control) == "table" then
			local control = row.control
			table.insert(controls, {
				id = control.id,
				action = row.action,
				args = if type(control.args) == "table" then control.args else {},
				label = if type(control.label) == "string" then control.label else "",
				kind = control.kind,
			})
		end
	end
	return controls
end

--- Every locale key the spec declares, paired with the display string that is
--- its source text and the surface it appears on. This is what the pack's
--- `locale/strings.csv` is generated from, so a key that exists in the spec is
--- never missing from the pack's localization table.
function M.localeEntries(spec: any): { any }
	local entries: { any } = {}
	local seen: { [string]: boolean } = {}
	local function add(key: any, source: any, context: string)
		if type(key) ~= "string" or type(source) ~= "string" or seen[key] then
			return
		end
		seen[key] = true
		table.insert(entries, { key = key, source = source, context = context })
	end
	for _, resource in (if type(spec) == "table" and type(spec.resources) == "table" then spec.resources else {}) do
		if type(resource) == "table" then
			add(resource.nameKey, resource.name, "hud resource " .. tostring(resource.id))
		end
	end
	for _, entity in (if type(spec) == "table" and type(spec.entities) == "table" then spec.entities else {}) do
		if type(entity) == "table" then
			add(entity.nameKey, entity.name, "entity " .. tostring(entity.id))
		end
	end
	for _, row in (if type(spec) == "table" and type(spec.actions) == "table" then spec.actions else {}) do
		if type(row) == "table" and type(row.control) == "table" then
			add(row.control.labelKey, row.control.label, "control " .. tostring(row.control.id))
		end
	end
	for _, stage in (if type(spec) == "table" and type(spec.loop) == "table" then spec.loop else {}) do
		if type(stage) == "table" then
			add(stage.goalKey, stage.goal, "objective " .. tostring(stage.id))
		end
	end
	-- A world node's feedback copy is player-facing too: the floating text a state
	-- change pops up is translated and gated exactly like the HUD's own strings.
	local world = if type(spec) == "table" then spec.world else nil
	for _, node in (if type(world) == "table" and type(world.nodes) == "table" then world.nodes else {}) do
		if type(node) == "table" and type(node.feedback) == "table" then
			for _, entry in node.feedback do
				if type(entry) == "table" then
					add(entry.labelKey, entry.label, "world node " .. tostring(node.id) .. " feedback")
				end
			end
		end
	end
	-- The kit's own literals are rendered strings too, so they are translated and
	-- gated exactly like a declared key.
	for key, source in HudText.KIT_STRINGS do
		add(key, source, "hud kit string")
	end
	return entries
end

--- The language a pack generated from this spec renders: `locale.default`, and
--- `en` when the spec declares none.
function M.localeDefault(spec: any): string
	local block = if type(spec) == "table" then spec.locale else nil
	local value = if type(block) == "table" then block.default else nil
	if type(value) == "string" and #value > 0 then
		return value
	end
	return M.DEFAULT_LOCALE
end

--- The locale code a Roblox locale id names (`en-us` -> `en`).
function M.localeCode(locale: any): string
	if type(locale) ~= "string" or #locale == 0 then
		return M.DEFAULT_LOCALE
	end
	return string.sub(locale, 1, 2)
end

--- Every declared locale key paired with its string in every language the spec
--- carries: the source language is the declared display text, the others come
--- from `locale.strings`.
function M.localeTable(spec: any): { [string]: { [string]: string } }
	local block = if type(spec) == "table" then spec.locale else nil
	local strings = if type(block) == "table" then block.strings else nil
	local out: { [string]: { [string]: string } } = {}
	for _, entry in M.localeEntries(spec) do
		local row: { [string]: string } = { [M.SOURCE_LOCALE] = entry.source }
		local translated = if type(strings) == "table" then strings[entry.key] else nil
		if type(translated) == "table" then
			for code, text in translated do
				if type(code) == "string" and type(text) == "string" and #text > 0 then
					row[code] = text
				end
			end
		end
		out[entry.key] = row
	end
	return out
end

--- The Luau source of `src/shared/LocaleStrings.luau`: the pack's locale table,
--- which the generated client hands to its HUD so every rendered string comes
--- from the spec's own translations.
function M.serializeLocaleStrings(spec: any): string
	local table_ = M.localeTable(spec)
	local keys: { string } = {}
	for key in table_ do
		table.insert(keys, key)
	end
	table.sort(keys)
	local lines = {
		"--!strict",
		"-- GENERATED from " .. M.FILE .. ". Do not edit: edit the spec and regenerate.",
		"local strings: { [string]: { [string]: string } } = {",
	}
	for _, key in keys do
		local row = table_[key]
		local codes: { string } = {}
		for code in row do
			table.insert(codes, code)
		end
		table.sort(codes)
		local fields: { string } = {}
		for _, code in codes do
			table.insert(fields, string.format("[%q] = %q,", code, row[code]))
		end
		table.insert(lines, string.format("\t[%q] = { %s },", key, table.concat(fields, " ")))
	end
	table.insert(lines, "}")
	table.insert(lines, "return strings")
	return table.concat(lines, "\n") .. "\n"
end

--- One CSV cell, quoted when it carries a comma, a double quote or a line break, with any inner
--- quote doubled (RFC 4180). Declared copy can contain all three - "Ready, set, grow" corrupted
--- the columns under naive concatenation.
local function csvCell(value: any): string
	local text = tostring(value)
	if string.find(text, '[,"\r\n]') ~= nil then
		return '"' .. string.gsub(text, '"', '""') .. '"'
	end
	return text
end

--- The pack's `locale/strings.csv` body, derived from the spec's locale keys and
--- their translations. Every column carries that language's string, so a pack is
--- consistent in either language: `en-us` from the declared display text and
--- `ko-kr` from the spec's `locale.strings` block.
function M.renderLocaleCsv(spec: any, locales: { string }): string
	local header = { "Key", "Source", "Context" }
	for _, locale in locales do
		table.insert(header, locale)
	end
	local table_ = M.localeTable(spec)
	local headerCells: { string } = {}
	for _, cell in header do
		table.insert(headerCells, csvCell(cell))
	end
	local lines = { table.concat(headerCells, ",") }
	for _, entry in M.localeEntries(spec) do
		local row = { entry.key, entry.source, entry.context }
		for _, locale in locales do
			local code = M.localeCode(locale)
			local strings = table_[entry.key] or {}
			table.insert(row, strings[code] or entry.source)
		end
		local cells: { string } = {}
		for _, cell in row do
			table.insert(cells, csvCell(cell))
		end
		table.insert(lines, table.concat(cells, ","))
	end
	return table.concat(lines, "\n") .. "\n"
end

--- Legacy HUD instance names mapped to the spec action they drive
--- (`overrides.uiTargets`). A genre whose HUD is a declared override addresses
--- its controls by instance Name, so this is what keeps its QA targets legible.
function M.uiTargets(spec: any): { [string]: string }
	local out: { [string]: string } = {}
	local overrides = if type(spec) == "table" then spec.overrides else nil
	local targets = if type(overrides) == "table" then overrides.uiTargets else nil
	if type(targets) ~= "table" then
		return out
	end
	for name, action in targets do
		if type(name) == "string" and type(action) == "string" then
			out[name] = action
		end
	end
	return out
end

--- Loads and decodes one spec file. Returns (nil, errors) when it is missing or
--- does not decode, so a genre without a spec never silently disappears.
function M.load(path: string): (any?, { string })
	if not fs.isFile(path) then
		return nil, { path .. ": missing" }
	end
	local ok, decoded = pcall(function()
		return serde.decode("yaml", fs.readFile(path))
	end)
	if not ok then
		return nil, { path .. ": " .. firstLine(decoded) }
	end
	if type(decoded) ~= "table" then
		return nil, { path .. ": expected a mapping" }
	end
	return decoded, {}
end

--- Structural equality of two decoded values. The spec's `audio:` section and a
--- genre's runtime audio module are the same declaration in two encodings, and
--- the comparison must not care which encoding lists a key first.
local function equalValue(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	local countA, countB = 0, 0
	for key, value in a do
		countA += 1
		if not equalValue(value, b[key]) then
			return false
		end
	end
	for _ in b do
		countB += 1
	end
	return countA == countB
end

--- Every violation in a decoded spec, sorted. `context` supplies the package id
--- and the directory the spec describes. An empty list means the spec is well
--- formed; it does not mean the genre is complete.
function M.validate(raw: any, runtime: any, context: any): { string }
	if type(raw) ~= "table" then
		return { "spec: expected a mapping" }
	end
	local errors: { string } = {}
	local id: string = context.id
	local function fail(message: string)
		table.insert(errors, message)
	end

	for key in raw do
		if type(key) ~= "string" or indexOf(SPEC_KEYS, key) == nil then
			fail("unknown field " .. tostring(key))
		end
	end
	if raw.api ~= M.API then
		fail("api: unsupported spec api " .. tostring(raw.api))
	end
	if type(raw.version) ~= "string" or string.match(raw.version, "^%d+%.%d+%.%d+$") == nil then
		fail("version: expected major.minor.patch")
	end
	if raw.id ~= id or not Validation.id(raw.id) then
		fail("id: must equal the package id")
	end
	if type(runtime) ~= "table" or raw.runtime ~= runtime.id then
		fail("runtime: must equal RuntimeContract.id")
	end
	local draft = raw.draft == true
	if raw.draft ~= nil and type(raw.draft) ~= "boolean" then
		fail("draft: expected boolean")
	end

	local declared: any = declaredAssetKeys(context.path)
	local function checkAssetKey(label: string, key: any)
		if key == nil then
			return
		end
		if not isKey(key) then
			fail(label .. ": invalid asset key")
		elseif next(declared.assets) ~= nil and not declared.assets[key] then
			fail(label .. ": asset key is not declared by the genre's assets/*.yml")
		end
	end

	-- resources ------------------------------------------------------------
	local resourceIds: { string } = {}
	local resourceSet: { [string]: boolean } = {}
	if raw.resources ~= nil and not Validation.dense(raw.resources, 64) then
		fail("resources: expected a dense list")
	else
		for index, resource in raw.resources or {} do
			local label = string.format("resources[%d]", index)
			if type(resource) ~= "table" then
				fail(label .. ": expected a mapping")
				continue
			end
			for key in resource do
				if indexOf({ "id", "name", "nameKey", "assetKey", "initial", "hud" }, key) == nil then
					fail(label .. ": unknown field " .. tostring(key))
				end
			end
			if not isKey(resource.id) or resourceSet[resource.id] then
				fail(label .. ".id: invalid or duplicate resource id")
			else
				resourceSet[resource.id] = true
				table.insert(resourceIds, resource.id)
			end
			if not isKey(resource.nameKey) then
				fail(label .. ".nameKey: invalid locale key")
			end
			-- The HUD shows `name`, never the key: a spec that names only a locale key
			-- has no player-facing text and would render an identifier.
			local name, nameError = HudText.checkDisplay(resource.name, label .. ".name")
			if name == nil then
				fail(nameError :: string)
			elseif name == resource.nameKey or name == resource.id then
				fail(label .. ".name: display string repeats the identifier or locale key")
			end
			checkAssetKey(label .. ".assetKey", resource.assetKey)
			if resource.initial ~= nil and (not isFinite(resource.initial) or resource.initial < 0) then
				fail(label .. ".initial: expected a non-negative number")
			end
			local hud = resource.hud
			if type(hud) ~= "table" or hud.slot ~= "resource-bar" or not isFinite(hud.order) or hud.order < 1 then
				fail(label .. ".hud: expected slot resource-bar and a positive order")
			else
				for key in hud do
					if key ~= "slot" and key ~= "order" then
						fail(label .. ".hud: unknown field " .. tostring(key))
					end
				end
			end
		end
	end

	-- entities -------------------------------------------------------------
	local entityIds: { [string]: boolean } = {}
	if raw.entities ~= nil and not Validation.dense(raw.entities, 512) then
		fail("entities: expected a dense list")
	else
		for index, entity in raw.entities or {} do
			local label = string.format("entities[%d]", index)
			if type(entity) ~= "table" then
				fail(label .. ": expected a mapping")
				continue
			end
			for key in entity do
				if indexOf({ "id", "kind", "name", "nameKey", "assetKey", "configPath" }, key) == nil then
					fail(label .. ": unknown field " .. tostring(key))
				end
			end
			if not isKey(entity.id) or entityIds[entity.id] then
				fail(label .. ".id: invalid or duplicate entity id")
			else
				entityIds[entity.id] = true
			end
			if type(entity.kind) ~= "string" or not ENTITY_KIND_SET[entity.kind] then
				fail(label .. ".kind: expected one of " .. table.concat(M.ENTITY_KINDS, "|"))
			end
			if not isKey(entity.nameKey) then
				fail(label .. ".nameKey: invalid locale key")
			end
			local entityName, entityNameError = HudText.checkDisplay(entity.name, label .. ".name")
			if entityName == nil then
				fail(entityNameError :: string)
			elseif entityName == entity.nameKey or entityName == entity.id then
				fail(label .. ".name: display string repeats the identifier or locale key")
			end
			checkAssetKey(label .. ".assetKey", entity.assetKey)
			if entity.configPath ~= nil and not Validation.dense(entity.configPath, 12) then
				fail(label .. ".configPath: expected a dense path")
			elseif type(entity.configPath) == "table" then
				for _, segment in entity.configPath do
					if type(segment) ~= "string" and type(segment) ~= "number" then
						fail(label .. ".configPath: path segments must be strings or numbers")
					end
				end
			end
		end
	end

	-- actions --------------------------------------------------------------
	local runtimeActions: { [string]: any } = {}
	for _, action in (if type(runtime) == "table" and type(runtime.actions) == "table" then runtime.actions else {}) do
		runtimeActions[action.id] = action
	end
	local boundActions: { [string]: boolean } = {}
	local controlSet: { [string]: boolean } = {}
	if raw.actions ~= nil and not Validation.dense(raw.actions, 256) then
		fail("actions: expected a dense list")
	else
		for index, row in raw.actions or {} do
			local label = string.format("actions[%d]", index)
			if type(row) ~= "table" then
				fail(label .. ": expected a mapping")
				continue
			end
			for key in row do
				if indexOf({ "action", "control", "preconditions", "effects" }, key) == nil then
					fail(label .. ": unknown field " .. tostring(key))
				end
			end
			local namespace, localId = nil, nil
			if type(row.action) == "string" then
				namespace, localId = string.match(row.action, "^([^:]+):([^:]+)$")
			end
			if namespace ~= id or localId == nil then
				fail(label .. ".action: expected '<genre>:<action>'")
			elseif runtimeActions[localId] == nil then
				fail(label .. ".action: undeclared runtime action " .. tostring(row.action))
			else
				-- One action may be bound by several controls (one per argument row).
				boundActions[row.action] = true
			end
			if row.control == nil then
				fail(label .. ".control: every action row binds one player-facing control")
			elseif type(row.control) ~= "table" then
				fail(label .. ".control: expected a mapping")
			else
				for key in row.control do
					if indexOf({ "id", "label", "labelKey", "kind", "args", "ui" }, key) == nil then
						fail(label .. ".control: unknown field " .. tostring(key))
					end
				end
				local ui = row.control.ui
				if type(ui) ~= "table" or ui.slot ~= "action-bar" or not isFinite(ui.order) or ui.order < 1 then
					fail(label .. ".control.ui: expected slot action-bar and a positive order")
				else
					for key in ui do
						if key ~= "slot" and key ~= "order" then
							fail(label .. ".control.ui: unknown field " .. tostring(key))
						end
					end
				end
				if type(row.control.id) == "string" then
					if controlSet[row.control.id] then
						fail(label .. ".control.id: duplicate control id")
					else
						controlSet[row.control.id] = true
					end
				end
				if type(row.control.labelKey) ~= "string" or #row.control.labelKey == 0 then
					fail(label .. ".control.labelKey: expected a locale key")
				end
				local controlLabel, controlLabelError =
					HudText.checkDisplay(row.control.label, label .. ".control.label")
				if controlLabel == nil then
					fail(controlLabelError :: string)
				elseif controlLabel == row.control.labelKey or controlLabel == row.control.id then
					fail(label .. ".control.label: display string repeats the identifier or locale key")
				end
				if type(runtime) == "table" and localId ~= nil and runtimeActions[localId] ~= nil then
					-- Control legality is the authority's: namespaced id, kind, arity and
					-- per-argument schema all come from `Options.validateControls`.
					local probe = {
						id = row.control.id,
						action = row.action,
						args = if type(row.control.args) == "table" then row.control.args else {},
						label = if type(row.control.labelKey) == "string" then row.control.labelKey else "label",
						kind = row.control.kind,
					}
					local ok, reason = pcall(function()
						Options.validateControls({ probe }, { runtime })
						return nil
					end)
					if not ok then
						fail(label .. ".control: " .. firstLine(reason))
					end
				end
			end
			if row.preconditions ~= nil and not Validation.dense(row.preconditions, 16) then
				fail(label .. ".preconditions: expected a dense list")
			else
				for _, entry in row.preconditions or {} do
					if type(entry) ~= "table" or not isKey(entry.ref) then
						fail(label .. ".preconditions: expected { ref = <id> }")
					else
						for key in entry do
							if key ~= "ref" then
								fail(label .. ".preconditions: unknown field " .. tostring(key))
							end
						end
					end
				end
			end
			if row.effects ~= nil and not Validation.dense(row.effects, 16) then
				fail(label .. ".effects: expected a dense list")
			else
				for _, effect in row.effects or {} do
					if
						type(effect) ~= "table"
						or not Validation.dense(effect.path, 12)
						or #(effect.path or {}) == 0
						or not isFinite(effect.delta)
					then
						fail(label .. ".effects: expected { path = [...], delta = <number> }")
					else
						for key in effect do
							if key ~= "path" and key ~= "delta" then
								fail(label .. ".effects: unknown field " .. tostring(key))
							end
						end
					end
				end
			end
		end
	end

	-- loop -----------------------------------------------------------------
	local loopIds: { [string]: boolean } = {}
	local runtimeEvents: { [string]: boolean } = {}
	for _, name in (if type(runtime) == "table" and type(runtime.events) == "table" then runtime.events else {}) do
		runtimeEvents[name] = true
	end
	if raw.loop ~= nil and not Validation.dense(raw.loop, 64) then
		fail("loop: expected a dense list")
	else
		for index, stage in raw.loop or {} do
			local label = string.format("loop[%d]", index)
			if type(stage) ~= "table" then
				fail(label .. ": expected a mapping")
				continue
			end
			for key in stage do
				if indexOf({ "id", "actions", "on", "goal", "goalKey" }, key) == nil then
					fail(label .. ": unknown field " .. tostring(key))
				end
			end
			if not isKey(stage.id) or loopIds[stage.id] then
				fail(label .. ".id: invalid or duplicate stage id")
			else
				loopIds[stage.id] = true
			end
			if not Validation.dense(stage.actions, 64) or #(stage.actions or {}) == 0 then
				fail(label .. ".actions: expected a nonempty dense list")
			else
				for _, action in stage.actions do
					if not boundActions[action] then
						fail(label .. ".actions: undeclared action " .. tostring(action))
					end
				end
			end
			if stage.on ~= nil and not runtimeEvents[stage.on] then
				fail(label .. ".on: undeclared runtime event " .. tostring(stage.on))
			end
			if stage.goalKey ~= nil and not isKey(stage.goalKey) then
				fail(label .. ".goalKey: invalid locale key")
			end
			-- The objective line shows `goal`; a stage without one renders an id.
			local goal, goalError = HudText.checkDisplay(stage.goal, label .. ".goal")
			if goal == nil then
				fail(goalError :: string)
			elseif goal == stage.goalKey or goal == stage.id then
				fail(label .. ".goal: display string repeats the identifier or locale key")
			end
		end
	end

	-- ui -------------------------------------------------------------------
	local ui = raw.ui
	if type(ui) ~= "table" then
		fail("ui: expected a mapping")
	else
		for key in ui do
			if type(key) ~= "string" or indexOf(UI_KEYS, key) == nil then
				fail("ui: unknown field " .. tostring(key))
			end
		end
		local bar = ui.resourceBar
		if type(bar) ~= "table" or not isFinite(bar.order) or bar.order < 1 then
			fail("ui.resourceBar: expected { resources = [...], order = <positive> }")
		else
			if not Validation.dense(bar.resources, 64) then
				fail("ui.resourceBar.resources: expected a dense list")
			else
				local seen: { [string]: boolean } = {}
				for _, resource in bar.resources do
					if not resourceSet[resource] or seen[resource] then
						fail("ui.resourceBar.resources: unknown or duplicate resource " .. tostring(resource))
					end
					seen[resource] = true
				end
				for _, resource in resourceIds do
					if not seen[resource] then
						fail("ui.resourceBar.resources: missing declared resource " .. resource)
					end
				end
			end
		end
		local buttons = ui.actionButtons
		if
			type(buttons) ~= "table"
			or buttons.from ~= "actions"
			or not isFinite(buttons.order)
			or buttons.order < 1
		then
			fail("ui.actionButtons: expected { from = actions, kinds = [...], order = <positive> }")
		else
			for key in buttons do
				if indexOf({ "from", "kinds", "order" }, key) == nil then
					fail("ui.actionButtons: unknown field " .. tostring(key))
				end
			end
			if not Validation.dense(buttons.kinds, 8) or #(buttons.kinds or {}) == 0 then
				fail("ui.actionButtons.kinds: expected a nonempty dense list")
			else
				local seen: { [string]: boolean } = {}
				for _, kind in buttons.kinds do
					if not CONTROL_KIND_SET[kind] or seen[kind] then
						fail("ui.actionButtons.kinds: invalid or duplicate kind " .. tostring(kind))
					end
					seen[kind] = true
				end
				-- Derived-set equality: every declared control must be reachable
				-- through this element, so the derived GenreUI is complete by
				-- construction and `forge sweep` can only find it complete.
				for index, row in raw.actions or {} do
					if type(row) == "table" and type(row.control) == "table" and not seen[row.control.kind] then
						fail(
							string.format(
								"ui.actionButtons.kinds: actions[%d] control kind %s is not rendered",
								index,
								tostring(row.control.kind)
							)
						)
					end
				end
			end
		end
		if ui.inventoryGrid ~= nil then
			local grid = ui.inventoryGrid
			if
				type(grid) ~= "table"
				or type(grid.entityKind) ~= "string"
				or not ENTITY_KIND_SET[grid.entityKind]
				or not isFinite(grid.order)
				or grid.order < 1
			then
				fail("ui.inventoryGrid: expected a declared entity kind and a positive order")
			else
				for key in grid do
					if key ~= "entityKind" and key ~= "order" and key ~= "field" then
						fail("ui.inventoryGrid: unknown field " .. tostring(key))
					end
				end
				-- The grid reads its cells from a snapshot field; without one it
				-- renders nothing, which is a declared choice, not a guess.
				if grid.field ~= nil and not isKey(grid.field) then
					fail("ui.inventoryGrid.field: invalid snapshot field")
				end
			end
		end
		local objective = ui.objective
		if
			type(objective) ~= "table"
			or objective.from ~= "loop"
			or not isFinite(objective.order)
			or objective.order < 1
		then
			fail("ui.objective: expected { from = loop, order = <positive> }")
		else
			for key in objective do
				if key ~= "from" and key ~= "order" then
					fail("ui.objective: unknown field " .. tostring(key))
				end
			end
		end
		local notifications = ui.notifications
		if
			type(notifications) ~= "table"
			or not Validation.dense(notifications.kinds, 8)
			or not isFinite(notifications.order)
			or notifications.order < 1
		then
			fail("ui.notifications: expected { kinds = [...], order = <positive> }")
		else
			for key in notifications do
				if key ~= "kinds" and key ~= "order" then
					fail("ui.notifications: unknown field " .. tostring(key))
				end
			end
			for _, kind in notifications.kinds do
				if indexOf(M.NOTIFICATION_KINDS, kind) == nil then
					fail("ui.notifications.kinds: invalid kind " .. tostring(kind))
				end
			end
		end
	end

	-- locale ---------------------------------------------------------------
	-- Every key the spec declares, with the surface that declares it, so a missing
	-- or stale translation names the key it belongs to.
	local declaredLocaleKeys: { [string]: string } = {}
	for _, resource in raw.resources or {} do
		if type(resource) == "table" and type(resource.nameKey) == "string" then
			declaredLocaleKeys[resource.nameKey] = "resource " .. tostring(resource.id)
		end
	end
	for _, entity in raw.entities or {} do
		if type(entity) == "table" and type(entity.nameKey) == "string" then
			declaredLocaleKeys[entity.nameKey] = "entity " .. tostring(entity.id)
		end
	end
	for _, row in raw.actions or {} do
		if type(row) == "table" and type(row.control) == "table" and type(row.control.labelKey) == "string" then
			declaredLocaleKeys[row.control.labelKey] = "control " .. tostring(row.control.id)
		end
	end
	for _, stage in raw.loop or {} do
		if type(stage) == "table" and type(stage.goalKey) == "string" then
			declaredLocaleKeys[stage.goalKey] = "objective " .. tostring(stage.id)
		end
	end
	-- A world node's feedback copy is a rendered string too: it names the floating
	-- text a state change pops up, so it is translated and gated like the rest.
	local localeWorld = if type(raw.world) == "table" then raw.world else nil
	for _, node in
		(if type(localeWorld) == "table" and type(localeWorld.nodes) == "table" then localeWorld.nodes else {})
	do
		if type(node) == "table" and type(node.feedback) == "table" then
			for _, entry in node.feedback do
				if type(entry) == "table" and type(entry.labelKey) == "string" then
					declaredLocaleKeys[entry.labelKey] = "world node " .. tostring(node.id) .. " feedback"
				end
			end
		end
	end
	for key in HudText.KIT_STRINGS do
		declaredLocaleKeys[key] = "hud kit string"
	end
	local localeBlock = raw.locale
	if type(localeBlock) ~= "table" then
		fail("locale: expected { default = <code>, strings = { <key> = { <code> = <text> } } }")
	else
		for key in localeBlock do
			if key ~= "default" and key ~= "strings" then
				fail("locale: unknown field " .. tostring(key))
			end
		end
		local default = localeBlock.default
		if default ~= nil and (type(default) ~= "string" or indexOf(M.LOCALE_CODES, default) == nil) then
			fail("locale.default: expected one of " .. table.concat(M.LOCALE_CODES, "|"))
		end
		local strings = localeBlock.strings
		if type(strings) ~= "table" or next(strings) == nil then
			fail("locale.strings: expected a translation for every declared locale key")
		else
			for key, entry in strings do
				local label = "locale.strings." .. tostring(key)
				if declaredLocaleKeys[key] == nil then
					fail(label .. ": no declared locale key of that name")
				elseif type(entry) ~= "table" then
					fail(label .. ": expected a mapping of locale code to text")
				else
					for code in entry do
						if indexOf(M.LOCALE_CODES, code) == nil then
							fail(label .. ": unknown locale code " .. tostring(code))
						end
					end
					-- The source language is the declared display text, so only the other
					-- codes need a string here: a missing one leaves that pack's column
					-- empty and a HUD half-translated.
					for _, code in M.LOCALE_CODES do
						if code ~= M.SOURCE_LOCALE then
							local text = entry[code]
							if type(text) ~= "string" or #text == 0 then
								fail(label .. ": missing the " .. code .. " string")
							else
								local _, reason = HudText.checkDisplay(text, label .. "." .. code)
								if reason ~= nil then
									fail(reason :: string)
								end
							end
						end
					end
				end
			end
			for key, surface in declaredLocaleKeys do
				if strings[key] == nil then
					fail("locale.strings." .. key .. ": missing the translation of the " .. surface .. " key")
				end
			end
		end
	end

	-- world ----------------------------------------------------------------
	local zoneBounds: { [string]: any } = {}
	-- The cue keys the spec declares, so a world node's feedback binding is checked
	-- against the same list the audio bindings are (the audio block below reads it too).
	local specCueKeys: { [string]: boolean } = {}
	for _, cue in (if type(raw.audio) == "table" and type(raw.audio.cues) == "table" then raw.audio.cues else {}) do
		if type(cue) == "table" and type(cue.key) == "string" then
			specCueKeys[cue.key] = true
		end
	end
	if raw.world ~= nil then
		local world = raw.world
		if type(world) ~= "table" then
			fail("world: expected a mapping")
		else
			for key in world do
				if indexOf({ "name", "spawn", "zones", "nodes" }, key) == nil then
					fail("world: unknown field " .. tostring(key))
				end
			end
			if not isKey(world.name) then
				fail("world.name: invalid instance name")
			end
			if not Validation.dense(world.zones, 64) or #(world.zones or {}) == 0 then
				fail("world.zones: expected a nonempty dense list")
			else
				for index, zone in world.zones do
					local label = string.format("world.zones[%d]", index)
					if type(zone) ~= "table" then
						fail(label .. ": expected a mapping")
						continue
					end
					for key in zone do
						if indexOf({ "id", "kind", "center", "size", "radius", "team" }, key) == nil then
							fail(label .. ": unknown field " .. tostring(key))
						end
					end
					if not isKey(zone.id) or zoneBounds[zone.id] ~= nil then
						fail(label .. ".id: invalid or duplicate zone id")
					end
					if type(zone.kind) ~= "string" or not ZONE_KIND_SET[zone.kind] then
						fail(label .. ".kind: expected one of " .. table.concat(M.ZONE_KINDS, "|"))
					end
					if not isTriple(zone.center) then
						fail(label .. ".center: expected three finite numbers")
					end
					local bounded = false
					if zone.size ~= nil then
						if not isPositiveTriple(zone.size) then
							fail(label .. ".size: expected three positive numbers")
						else
							bounded = true
						end
					end
					if zone.radius ~= nil then
						if not isFinite(zone.radius) or zone.radius <= 0 then
							fail(label .. ".radius: expected a positive number")
						else
							bounded = true
						end
					end
					if not bounded then
						fail(label .. ": expected size or radius")
					end
					if zone.kind == "base" and not isKey(zone.team) then
						fail(label .. ".team: a base zone declares its team")
					elseif zone.kind ~= "base" and zone.team ~= nil then
						fail(label .. ".team: only a base zone declares a team")
					end
					if isKey(zone.id) and zoneBounds[zone.id] == nil then
						zoneBounds[zone.id] = zone
					end
				end
			end
			local function insideZone(zone: any, point: any): boolean
				if type(zone) ~= "table" or not isTriple(zone.center) or not isTriple(point) then
					return false
				end
				-- Zones are floor slabs (and arenas are discs): containment is horizontal,
				-- and the vertical band lets a placement sit on the floor and above it.
				local dx, dz = point[1] - zone.center[1], point[3] - zone.center[3]
				local height = 0
				if type(zone.radius) == "number" then
					if dx * dx + dz * dz > zone.radius * zone.radius then
						return false
					end
					height = zone.radius
				else
					if not isPositiveTriple(zone.size) then
						return false
					end
					if math.abs(dx) > zone.size[1] / 2 or math.abs(dz) > zone.size[3] / 2 then
						return false
					end
					height = zone.size[2]
				end
				local lift = point[2] - zone.center[2]
				return lift >= 0 and lift <= height + 8
			end
			local spawn = world.spawn
			if type(spawn) ~= "table" or not isKey(spawn.zone) or not isTriple(spawn.offset) then
				fail("world.spawn: expected { zone = <id>, offset = [x, y, z] }")
			else
				for key in spawn do
					if key ~= "zone" and key ~= "offset" then
						fail("world.spawn: unknown field " .. tostring(key))
					end
				end
				local zone = zoneBounds[spawn.zone]
				if zone == nil then
					fail("world.spawn.zone: undeclared zone " .. tostring(spawn.zone))
				elseif not insideZone(zone, spawn.offset) then
					fail("world.spawn.offset: spawn is outside its zone")
				end
			end
			local nodeIds: { [string]: boolean } = {}
			if world.nodes ~= nil and not Validation.dense(world.nodes, 256) then
				fail("world.nodes: expected a dense list")
			else
				for index, node in world.nodes or {} do
					local label = string.format("world.nodes[%d]", index)
					if type(node) ~= "table" then
						fail(label .. ": expected a mapping")
						continue
					end
					for key in node do
						if
							indexOf({ "id", "zone", "kind", "position", "control", "version", "feedback" }, key) == nil
						then
							fail(label .. ": unknown field " .. tostring(key))
						end
					end
					if not isKey(node.id) or nodeIds[node.id] then
						fail(label .. ".id: invalid or duplicate node id")
					else
						nodeIds[node.id] = true
					end
					if type(node.kind) ~= "string" or not NODE_KIND_SET[node.kind] then
						fail(label .. ".kind: expected one of " .. table.concat(M.NODE_KINDS, "|"))
					end
					if not isTriple(node.position) then
						fail(label .. ".position: expected three finite numbers")
					end
					local zone = zoneBounds[node.zone]
					if zone == nil then
						fail(label .. ".zone: undeclared zone " .. tostring(node.zone))
					elseif isTriple(node.position) and not insideZone(zone, node.position) then
						fail(label .. ".position: node is outside its zone")
					end
					if node.control ~= nil and not controlSet[node.control] then
						fail(label .. ".control: undeclared control " .. tostring(node.control))
					end
					if
						node.version ~= nil
						and (not isFinite(node.version) or node.version < 0 or node.version % 1 ~= 0)
					then
						fail(label .. ".version: expected a non-negative integer")
					end
				end
			end
			-- A node's feedback is presentation only: it names the snapshot field it
			-- reflects and the copy it pops up, and every cue it plays must be declared.
			for _, err in WorldFeedback.violations(world, specCueKeys) do
				fail(err)
			end
			-- The derived studio world path walks to a prompt-bearing node and triggers it
			-- with real input, so it is validated here too: a node whose control cannot be
			-- driven fails `discover` rather than at capture time.
			local worldPath = qagen.deriveWorldPath(raw, { name = "world-path", genre = id, pack = "spec-check" }, nil)
			if worldPath ~= nil then
				for _, err in qascenario.validate(worldPath) do
					fail("world.nodes: " .. err)
				end
			end
		end
	end

	-- audio ----------------------------------------------------------------
	if raw.audio ~= nil then
		local audio = raw.audio
		if type(audio) ~= "table" then
			fail("audio: expected a mapping")
		else
			for key in audio do
				if key ~= "cues" and key ~= "bindings" then
					fail("audio: unknown field " .. tostring(key))
				end
			end
			local cueKeys: { [string]: boolean } = {}
			if type(audio.cues) ~= "table" then
				fail("audio.cues: expected a list of cue definitions")
			else
				-- Cue shape is `audiocues.Cue` verbatim: the same authority that
				-- renders the pack's WAVs validates the spec's cues.
				local cues, cueErrors = audiocues.plan({ cues = audio.cues })
				for _, err in cueErrors do
					fail("audio.cues: " .. string.gsub(err, "^audio%.yml: ", ""))
				end
				if cues ~= nil then
					for _, cue in cues do
						cueKeys[cue.key] = true
					end
				end
				-- The spec's cue list and the genre's assets/<id>/audio.yml are one set:
				-- a cue the spec binds but the pack never renders is a silent no-op, and
				-- a cue the pack renders but the spec never binds is an orphan.
				if next(declared.cues) ~= nil then
					for key in cueKeys do
						if not declared.cues[key] then
							fail("audio.cues: " .. key .. " is not declared by the genre's assets/*.yml")
						end
					end
					for key in declared.cues do
						if not cueKeys[key] then
							fail("audio.cues: genre cue " .. key .. " is not declared by the spec")
						end
					end
				end
				for _, cue in audio.cues do
					if type(cue) == "table" and type(cue.key) == "string" then
						checkAssetKey("audio.cues[" .. cue.key .. "]", cue.key)
					end
				end
			end
			if audio.bindings ~= nil and not Validation.dense(audio.bindings, 256) then
				fail("audio.bindings: expected a dense list")
			else
				local seen: { [string]: boolean } = {}
				for index, binding in audio.bindings or {} do
					local label = string.format("audio.bindings[%d]", index)
					if type(binding) ~= "table" then
						fail(label .. ": expected a mapping")
						continue
					end
					for key in binding do
						if indexOf({ "on", "cue", "dedupe", "local", "field" }, key) == nil then
							fail(label .. ": unknown field " .. tostring(key))
						end
					end
					local on = binding.on
					local validOn = false
					if type(on) == "string" then
						local action = string.match(on, "^action:(.+)$")
						if action ~= nil then
							validOn = boundActions[action] == true
							if not validOn then
								fail(label .. ".on: undeclared action binding " .. action)
							end
						else
							local event = string.match(on, "^event:(.+)$")
							if event ~= nil then
								validOn = runtimeEvents[event] == true
								if not validOn then
									fail(label .. ".on: undeclared runtime event " .. event)
								end
							end
						end
					end
					if not validOn and (type(on) ~= "string" or string.match(on, "^action:") == nil) then
						if not (type(on) == "string" and string.match(on, "^event:") ~= nil) then
							fail(label .. ".on: expected 'action:<genre>:<action>' or 'event:<Name>'")
						end
					end
					if type(binding.cue) ~= "string" or not cueKeys[binding.cue] then
						fail(label .. ".cue: undeclared cue " .. tostring(binding.cue))
					end
					if binding.dedupe ~= nil and (not isFinite(binding.dedupe) or binding.dedupe < 0) then
						fail(label .. ".dedupe: expected a non-negative number of seconds")
					end
					if binding["local"] ~= nil and type(binding["local"]) ~= "boolean" then
						fail(label .. ".local: expected boolean")
					end
					if binding.field ~= nil and not isKey(binding.field) then
						fail(label .. ".field: invalid snapshot field")
					end
					if type(on) == "string" and seen[on] then
						fail(label .. ".on: duplicate binding for " .. on)
					elseif type(on) == "string" then
						seen[on] = true
					end
				end
			end
		end
	end

	-- The genre's runtime audio document, when the genre ships one
	-- (`module/Audio.luau`), is the same declaration as the spec's `audio:`
	-- section. A pack whose client owns its own transport reads the module, so a
	-- drift between the two would play a cue the spec does not bind — or miss one
	-- it does. A genre without the module is not asked for one: the generated
	-- client reads the declaration out of the serialized spec.
	local audioModulePath = if type(context.path) == "string" then context.path .. "/module/Audio.luau" else nil
	if audioModulePath ~= nil and fs.isFile(audioModulePath) then
		local loadedOk, loaded = pcall(function()
			-- Loaded as a chunk rather than required: the module is pure data, so a
			-- require of its own would be a defect this catches.
			return luau.load(fs.readFile(audioModulePath))()
		end)
		if not loadedOk then
			fail("module/Audio.luau: does not load: " .. firstLine(loaded))
		elseif type(loaded) ~= "table" then
			fail("module/Audio.luau: expected a table")
		else
			local declaredAudio = if type(raw.audio) == "table" then raw.audio else {}
			for _, key in { "cues", "bindings" } do
				if not equalValue(loaded[key], declaredAudio[key]) then
					fail("module/Audio.luau: " .. key .. " must equal the spec's audio." .. key)
				end
			end
		end
	end

	-- economy --------------------------------------------------------------
	if raw.economy ~= nil then
		local economy = raw.economy
		if type(economy) ~= "table" then
			fail("economy: expected a mapping")
		else
			for key in economy do
				if key ~= "startingBalance" and key ~= "simulation" then
					fail("economy: unknown field " .. tostring(key))
				end
			end
			if economy.startingBalance ~= nil then
				local path = economy.startingBalance.path
				if type(path) ~= "table" or not Validation.dense(path, 12) or #path == 0 then
					fail("economy.startingBalance: expected { path = [...] }")
				end
			end
			if economy.simulation ~= nil then
				local simulation = economy.simulation
				if type(simulation) ~= "table" then
					fail("economy.simulation: expected a mapping")
				else
					for key, value in simulation do
						if indexOf(SIMULATION_KEYS, key) == nil then
							fail("economy.simulation: unknown field " .. tostring(key))
						elseif type(value) ~= "string" or string.match(value, SIMULATION_COMPARISON) == nil then
							fail("economy.simulation." .. key .. ": expected a comparison like '>0'")
						end
					end
				end
			end
		end
	end

	-- qa -------------------------------------------------------------------
	local function checkQa(qa: any, label: string, mode: string?)
		for key in qa do
			if
				indexOf({
					"name",
					"players",
					"fixtures",
					"data",
					"starterState",
					"timeout_seconds",
					"goldenPath",
					"crafting",
					"wave",
					"worldPath",
				}, key) == nil
			then
				fail(label .. ": unknown field " .. tostring(key))
			end
		end
		-- The derived studio world path's prelude: how far the clock advances before
		-- the walk, and the one exact state it waits for. The shape is checked here;
		-- the derived scenario itself is validated by `qascenario.validate`.
		if qa.worldPath ~= nil then
			local path = qa.worldPath
			if type(path) ~= "table" then
				fail(label .. ".worldPath: expected a mapping")
			else
				for key in path do
					if indexOf({ "advanceSeconds", "waitFor", "waitTimeoutSeconds" }, key) == nil then
						fail(label .. ".worldPath: unknown field " .. tostring(key))
					end
				end
				if path.advanceSeconds ~= nil and (not isFinite(path.advanceSeconds) or path.advanceSeconds < 0) then
					fail(label .. ".worldPath.advanceSeconds: expected a non-negative number")
				end
				if path.waitFor ~= nil and type(path.waitFor) ~= "table" then
					fail(label .. ".worldPath.waitFor: expected a predicate")
				end
				if
					path.waitTimeoutSeconds ~= nil
					and (not isFinite(path.waitTimeoutSeconds) or path.waitTimeoutSeconds <= 0)
				then
					fail(label .. ".worldPath.waitTimeoutSeconds: expected a positive number")
				end
			end
		end
		if qa.name ~= nil and not isKey(qa.name) then
			fail(label .. ".name: invalid scenario id")
		end
		if qa.starterState ~= nil and type(qa.starterState) ~= "table" then
			fail(label .. ".starterState: expected a mapping")
		end
		if type(qa.goldenPath) ~= "table" or not Validation.dense(qa.goldenPath, 512) then
			fail(label .. ".goldenPath: expected a dense list of scenario steps")
		elseif #qa.goldenPath == 0 then
			if not draft then
				fail(label .. ".goldenPath: a non-draft spec requires at least one step")
			end
		else
			-- A YAML scalar that looks numeric decodes to a number, and the derived
			-- scenario round-trips through YAML again, so a string-typed argument can
			-- never survive to the domain as a string. Reject it here rather than let
			-- it be refused at run time as a type error.
			for stepIndex, step in qa.goldenPath do
				if type(step) ~= "table" or type(step.args) ~= "table" then
					continue
				end
				local _, localId = string.match(tostring(step.action), "^([^:]+):([^:]+)$")
				local action = if localId ~= nil then runtimeActions[localId] else nil
				if action == nil then
					continue
				end
				for argIndex, value in step.args do
					local validator = action.args[argIndex]
					while type(validator) == "table" and validator.kind == "optional" do
						validator = validator.inner
					end
					if type(validator) == "table" and validator.kind == "string" and type(value) == "number" then
						fail(
							string.format(
								"%s.goldenPath[%d].args[%d]: a string argument must not look numeric (YAML decodes it to a number)",
								label,
								stepIndex,
								argIndex
							)
						)
					end
				end
			end
			-- The golden path is validated by building the exact native scenario
			-- `qagen` publishes and running the run schema over it, so the spec can
			-- never describe a step the harness cannot execute.
			local document = qagen.derive(raw, {
				name = qagen.name(raw),
				genre = id,
				pack = if type(context.pack) == "string" then context.pack else "spec-check",
			}, mode)
			for _, err in qascenario.validate(document) do
				fail(label .. ".goldenPath: " .. err)
			end
		end
	end

	local qa = raw.qa
	if qa ~= nil then
		if type(qa) ~= "table" then
			fail("qa: expected a mapping")
		else
			checkQa(qa, "qa", nil)
			for _, mode in { "crafting", "wave" } do
				if qa[mode] ~= nil then
					if type(qa[mode]) ~= "table" then
						fail("qa." .. mode .. ": expected a mapping")
					else
						-- A mode block is validated as the document that mode publishes:
						-- `qagen.block` merges it over `qa`, so shared keys (players,
						-- timeout) are declared once.
						checkQa(qa[mode], "qa." .. mode, mode)
					end
				end
			end
		end
	end

	-- overrides ------------------------------------------------------------
	if raw.overrides ~= nil then
		local overrides = raw.overrides
		if type(overrides) ~= "table" then
			fail("overrides: expected a mapping")
		else
			for key in overrides do
				if indexOf(OVERRIDE_KEYS, key) == nil then
					fail("overrides: unknown field " .. tostring(key))
				end
			end
			for _, kind in { "client", "world", "audio" } do
				local override = overrides[kind]
				if override ~= nil then
					local prefix = "overrides." .. kind .. "."
					if type(override) ~= "table" or type(override.module) ~= "string" then
						fail(prefix .. "expected { module = <path> }")
					else
						for key in override do
							if key ~= "module" and not (kind == "client" and key == "mode") then
								fail(prefix .. "unknown field " .. tostring(key))
							end
						end
						-- A client override may be scoped to one config mode: survival-coop's
						-- SurvivalHUD is the crafting bootstrap's HUD, and the default wave mode renders
						-- the kit's HUD instead (its own main defend control is a kit button).
						if kind == "client" and override.mode ~= nil then
							if type(override.mode) ~= "string" or not isKey(override.mode) then
								fail(prefix .. "mode: expected a config mode name")
							end
						end
						local module = override.module
						if
							string.sub(module, 1, #("genres/" .. id .. "/module/")) ~= "genres/" .. id .. "/module/"
							or string.match(module, "^genres/[%w%-]+/module/[%w_/]+$") == nil
						then
							fail(prefix .. "module: must be a module of this genre")
						elseif
							not fs.isFile(
								context.path .. "/" .. string.sub(module, #("genres/" .. id .. "/") + 1) .. ".luau"
							)
						then
							fail(prefix .. "module: module file is missing")
						end
					end
				end
			end
			local targets = overrides.uiTargets
			if targets ~= nil then
				if type(targets) ~= "table" then
					fail("overrides.uiTargets: expected a mapping of HUD instance name to action")
				else
					for name, action in targets do
						if type(name) ~= "string" or #name == 0 then
							fail("overrides.uiTargets: invalid instance name")
						elseif not boundActions[action] then
							fail("overrides.uiTargets." .. name .. ": undeclared action " .. tostring(action))
						end
					end
				end
			end
		end
	end

	table.sort(errors)
	return errors
end

local function quote(text: string): string
	return string.format("%q", text)
end

local function renderNumber(value: number): string
	assert(value == value and value ~= math.huge and value ~= -math.huge, "invalid spec number")
	if value % 1 == 0 then
		return string.format("%d", value)
	end
	return tostring(value)
end

local renderValue: (any, boolean) -> string

--- Renders one value as Luau source. An element of a dense array is cast to
--- `any`: Luau unifies an array literal's element types and rejects a
--- heterogeneous array (a node with a control and a node without one) even
--- though the declared type is a string-keyed map.
local function renderTable(value: any): string
	local keys: { any } = {}
	for key in value do
		table.insert(keys, key)
	end
	if #keys == 0 then
		return "{}"
	end
	local dense = #keys == #value
	table.sort(keys, function(a: any, b: any): boolean
		return if dense then a < b else tostring(a) < tostring(b)
	end)
	local parts: { string } = {}
	for _, key in keys do
		local renderedKey = if type(key) == "string" then "[" .. quote(key) .. "]" else "[" .. tostring(key) .. "]"
		local item = value[key]
		table.insert(parts, renderedKey .. " = " .. renderValue(item, dense or type(item) == "table"))
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

renderValue = function(value: any, cast: boolean): string
	local rendered: string
	if type(value) == "table" then
		rendered = renderTable(value)
	elseif type(value) == "number" then
		rendered = renderNumber(value)
	elseif type(value) == "boolean" then
		rendered = tostring(value)
	elseif type(value) == "string" then
		rendered = quote(value)
	else
		error("unsupported spec value: " .. tostring(value))
	end
	return if cast then rendered .. " :: any" else rendered
end

--- The Luau source of `src/shared/GenreSpec.luau` for a validated spec. Byte
--- deterministic: identical spec input always renders identical output.
function M.serialize(spec: any): string
	return "--!strict\n-- GENERATED from "
		.. M.FILE
		.. ". Do not edit: edit the spec and regenerate.\nexport type Spec = { [string]: any }\nlocal spec: Spec = "
		.. renderTable(spec)
		.. "\nreturn spec\n"
end

--- Formats a generated Luau source to the repository style and to a fixed point.
--- stylua is not a fixed point in one pass for a deeply nested serialized table:
--- expanding an outer table changes the line lengths that decide whether an inner
--- table stays inline, so the tree publication pass alone would leave a file that
--- `stylua --check` still wants to rewrite.
function M.stabilize(source: string, fileName: string): string
	local function format(text: string): string
		local formatter = process.create("stylua", {
			"--config-path",
			"stylua.toml",
			"--stdin-filepath",
			fileName,
			"-",
		})
		formatter.stdin:write(text)
		formatter.stdin:close()
		local formatted = formatter.stdout:readToEnd()
		local errors = formatter.stderr:readToEnd()
		assert(formatter:status().ok, errors)
		return formatted
	end
	return format(format(source))
end
--- The Luau source of `src/shared/WorldSpec.luau`.
function M.serializeWorld(world: any): string
	return "--!strict\n-- GENERATED from "
		.. M.FILE
		.. ". Do not edit: edit the spec and regenerate.\nexport type World = { [string]: any }\nlocal world: World = "
		.. renderTable(world)
		.. "\nreturn world\n"
end

return M
