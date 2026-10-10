--!strict
-- HudText: the one authority that turns a spec's declared display data into the
-- strings a player actually reads.
--
-- Why this exists as its own module: the HUD must never show a spec id. A
-- resource carries a locale key *and* a human name, a control carries a locale
-- key *and* a human label, a loop stage carries a locale key *and* a human goal.
-- `plan` renders exactly the strings HudKit shows, and `violations` reports any
-- of them that is (or contains) an id-shaped token. HudKit renders the plan at
-- runtime; `forge sweep` checks the same plan offline, so the gate measures the
-- real visible text rather than a copy of it.
--
-- Pure Luau: no Roblox global, so the CLI can load it under Lune.

local Layout = require("../Layout")

local M = {}

-- An id-shaped token: snake_case (`coin_label`, `harvest_crop`) or kebab-case
-- (`buy-seed`), always lowercase-initial. Real display copy ("Coins", "Join
-- Queue", "Sell-held") never matches, because prose capitalises or spaces.
-- Lua patterns have no groups, so each shape is spelled out character by
-- character rather than as `(part)+`.
M.SNAKE = "^[a-z][a-z0-9]*_[a-z0-9_]*[a-z0-9]$"
M.KEBAB = "^[a-z][a-z0-9]*%-[a-z0-9%-]*[a-z0-9]$"

-- The separator between a display string and its value, in one place so the
-- gate and the HUD can never disagree about the rendered shape.
M.VALUE_GAP = "  "

-- The language the spec's declared display strings are written in, and the kit's
-- own literal strings. The kit's strings are declared here, next to the plan that
-- checks them, so HudKit renders them through the pack's locale table and the
-- sweep's script gate sees exactly the same keys a capture shows.
M.SOURCE_LOCALE = "en"
local KIT_STRINGS: { [string]: string } = {
	hud_menu = "Menu",
	hud_select_player = "Select a player first",
}
M.KIT_STRINGS = KIT_STRINGS

--- The string a HUD renders for a declared key at `locale`: the locale's own
--- translation when the pack's table has one, the source language otherwise, and
--- the declared display string when the key is absent from the table entirely.
function M.localized(strings: any, locale: string?, key: any, fallback: string): string
	if type(key) ~= "string" or type(strings) ~= "table" then
		return fallback
	end
	local row = strings[key]
	if type(row) ~= "table" then
		return fallback
	end
	local code = if type(locale) == "string" and #locale > 0 then string.sub(locale, 1, 2) else M.SOURCE_LOCALE
	local value = row[code]
	if type(value) ~= "string" or #value == 0 then
		value = row[M.SOURCE_LOCALE]
	end
	if type(value) ~= "string" or #value == 0 then
		return fallback
	end
	return value
end

--- The script family a string is written in: "hangul", "latin", or "neutral"
--- for digits, punctuation and symbols alone.
function M.script(text: any): string
	if type(text) ~= "string" then
		return "neutral"
	end
	local latin, hangul = false, false
	for _, code in utf8.codes(text) do
		if (code >= 0xAC00 and code <= 0xD7A3) or (code >= 0x1100 and code <= 0x11FF) then
			hangul = true
		elseif (code >= 65 and code <= 90) or (code >= 97 and code <= 122) then
			latin = true
		end
	end
	if hangul then
		return "hangul"
	elseif latin then
		return "latin"
	end
	return "neutral"
end

--- The display strings a plan renders at `locale`, resolved through a pack's
--- locale table: the set a capture shows.
function M.displaySet(plan: any, strings: any, locale: string?): { any }
	local out: { any } = {}
	local function add(kind: string, entry: any)
		table.insert(out, {
			kind = kind,
			id = tostring(entry.id),
			text = M.localized(strings, locale, entry.key, tostring(entry.display or "")),
		})
	end
	for _, entry in (plan or {}).resources or {} do
		add("resource", entry)
	end
	for _, entry in (plan or {}).actions or {} do
		add("control", entry)
	end
	for _, entry in (plan or {}).objectives or {} do
		add("objective", entry)
	end
	return out
end

--- Every string of a display set whose script differs from the set's first
--- scripted string. One capture shows one language: a HUD that renders English
--- resources and Korean buttons is the defect this reports.
function M.mixedScript(displays: { any }, locale: string?): { string }
	local families: { [string]: string } = {}
	for _, entry in displays do
		local family = M.script(entry.text)
		if family ~= "neutral" and families[family] == nil then
			families[family] = entry.kind .. " " .. tostring(entry.id)
		end
	end
	local out: { string } = {}
	if families.latin ~= nil and families.hangul ~= nil then
		table.insert(
			out,
			string.format(
				"locale %q mixes scripts: %s is Latin, %s is Hangul",
				tostring(locale),
				families.latin,
				families.hangul
			)
		)
	end
	return out
end

--- True when `token` is a raw spec identifier rather than player-facing text.
function M.isIdentifier(token: any): boolean
	if type(token) ~= "string" then
		return false
	end
	return string.match(token, M.SNAKE) ~= nil or string.match(token, M.KEBAB) ~= nil
end

--- The word tokens of a visible string, in order.
function M.tokens(text: string): { string }
	local out: { string } = {}
	for token in string.gmatch(text, "[%w_%-]+") do
		table.insert(out, token)
	end
	return out
end

--- Every identifier-shaped token in `text`, in order. Empty for real copy.
function M.identifiers(text: any): { string }
	local out: { string } = {}
	if type(text) ~= "string" then
		return out
	end
	for _, token in M.tokens(text) do
		if M.isIdentifier(token) then
			table.insert(out, token)
		end
	end
	return out
end

--- A declared display string, validated as player-facing text: present, trimmed,
--- bounded, and not an id. Returns (nil, reason) when it is not.
function M.checkDisplay(value: any, context: string): (string?, string?)
	if type(value) ~= "string" then
		return nil, context .. ": expected a display string"
	end
	if value ~= string.gsub(string.gsub(value, "^%s+", ""), "%s+$", "") then
		return nil, context .. ": display string has surrounding whitespace"
	end
	if #value == 0 or #value > 64 then
		return nil, context .. ": display string must be 1..64 characters"
	end
	local found = M.identifiers(value)
	if #found > 0 then
		return nil, context .. ": display string shows the raw identifier " .. found[1]
	end
	return value, nil
end

--- The value text a resource shows: the shared K/M/B formatting, so a large
--- balance never overflows its pill.
function M.value(value: any): string
	local number = tonumber(value)
	if number == nil then
		return tostring(value)
	end
	return Layout.formatNumber(number)
end

--- The visible line for one resource, e.g. `Coins  9`.
function M.resource(display: string, value: any): string
	return display .. M.VALUE_GAP .. M.value(value)
end

--- The visible line for the objective stage, e.g. `Buy a seed  (1/4)`.
function M.objective(display: string, index: number, total: number): string
	return string.format("%s%s(%d/%d)", display, M.VALUE_GAP, index, total)
end

--- The HUD's complete visible-string plan for a spec and its declared controls.
--- Each entry names the spec id it belongs to, the locale key it localises, the
--- display string, and the exact text the HUD renders.
function M.plan(spec: any, controls: { any }): any
	local resources: { any } = {}
	for _, resource in (if type(spec) == "table" and type(spec.resources) == "table" then spec.resources else {}) do
		if type(resource) == "table" then
			local display = resource.name
			table.insert(resources, {
				id = tostring(resource.id),
				key = tostring(resource.nameKey),
				display = display,
				text = if type(display) == "string" then M.resource(display, resource.initial or 0) else nil,
			})
		end
	end

	local actions: { any } = {}
	local declared: { any } = if type(controls) == "table" then controls else {}
	-- The locale key of every declared control, read from the spec: the runtime
	-- control list carries display text, so this is what lets a renderer resolve the
	-- label through a pack's locale table.
	local controlKeys: { [string]: string } = {}
	for _, row in (if type(spec) == "table" and type(spec.actions) == "table" then spec.actions else {}) do
		if type(row) == "table" and type(row.control) == "table" and type(row.control.labelKey) == "string" then
			controlKeys[tostring(row.control.id)] = row.control.labelKey
		end
	end
	for _, control in declared do
		if type(control) == "table" then
			table.insert(actions, {
				id = tostring(control.id),
				action = tostring(control.action),
				key = controlKeys[tostring(control.id)],
				display = control.label,
				kind = tostring(control.kind),
				text = if type(control.label) == "string" then control.label else nil,
			})
		end
	end

	local objectives: { any } = {}
	local stages: { any } = if type(spec) == "table" and type(spec.loop) == "table" then spec.loop else {}
	for index, stage in stages do
		if type(stage) == "table" then
			local display = stage.goal
			table.insert(objectives, {
				id = tostring(stage.id),
				key = tostring(stage.goalKey),
				display = display,
				text = if type(display) == "string" then M.objective(display, index, #stages) else nil,
			})
		end
	end

	return { resources = resources, actions = actions, objectives = objectives }
end

--- Every player-facing string the HUD would show that is missing, empty or an
--- id. Sorted, so the same plan always reports the same list.
function M.violations(plan: any): { string }
	local errors: { string } = {}
	local function check(kind: string, entry: any)
		local display, reason = M.checkDisplay(entry.display, kind .. " " .. tostring(entry.id))
		if display == nil then
			table.insert(errors, reason :: string)
			return
		end
		if display == entry.id or display == entry.key then
			table.insert(
				errors,
				kind .. " " .. tostring(entry.id) .. ": display string repeats its identifier or locale key"
			)
			return
		end
		for _, token in M.identifiers(entry.text) do
			table.insert(
				errors,
				kind .. " " .. tostring(entry.id) .. ": visible text shows the raw identifier " .. token
			)
			return
		end
	end
	for _, entry in (plan or {}).resources or {} do
		check("resource", entry)
	end
	for _, entry in (plan or {}).actions or {} do
		check("control", entry)
	end
	for _, entry in (plan or {}).objectives or {} do
		check("objective", entry)
	end
	table.sort(errors)
	return errors
end

--- Runtime guard: the HUD refuses to show an id-shaped string. Only declared
--- display data goes through here; dynamic server reasons are shown as-is.
function M.assertVisible(text: string): string
	local found = M.identifiers(text)
	assert(#found == 0, "HUD text shows the raw identifier " .. tostring(found[1]) .. ": " .. text)
	return text
end

return M
