--!strict
-- `forge spec init --genre <id> [--concept "<text>"] [--pack <slug>] [--force]`
-- writes a DRAFT genres/<id>/genre-spec.yml seeded from the genre's
-- econ-template.yml and design-template.md — the same templates `forge plan`
-- reads. The draft is valid-but-empty on purpose: it loads, so the catalog keeps
-- working while a coding agent fills in resources, entities, actions, loop,
-- world, audio and the golden path, then drops `draft: true`.
--
-- `forge spec validate [--genre <id>]` reports `file: reason` for every spec the
-- registry refuses, and confirms the ones it accepts. A spec that fails any rule
-- fails `genreregistry.discover`, so `forge new`, `forge plan`, `forge check`,
-- `forge sweep`, `forge build` and `forge qa` all refuse to run against it.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local registryLib = require("../lib/genreregistry")
local genrespec = require("../lib/genrespec")
local cliutil = require("../lib/cliutil")
local contract = require("../lib/genrecontract")

local M = {}

local function printUsage()
	stdio.ewrite([[Usage: lune run cli/forge spec init --genre <id> [--concept "<text>"] [--pack <slug>] [--force]
       lune run cli/forge spec validate [--genre <id>]

  init     Write a draft genres/<id>/genre-spec.yml seeded from the genre's
           econ-template.yml and design-template.md. The draft is a valid but
           incomplete binding document: an agent fills it in, then removes
           `draft: true`.
  validate Report every spec violation as `file: reason`.
]])
end

--- The first non-empty, non-heading line of a design template, as the draft's
--- one-line reminder of the loop it must bind.
local function designSummary(path: string): string?
	if not fs.isFile(path) then
		return nil
	end
	for line in string.gmatch(fs.readFile(path), "[^\r\n]+") do
		local trimmed = string.gsub(line, "^%s*(.-)%s*$", "%1")
		if trimmed ~= "" and string.sub(trimmed, 1, 1) ~= "#" then
			return trimmed
		end
	end
	return nil
end

--- The first free currency a genre's econ template declares, as the draft's
--- starting resource. Falls back to `coins` so the draft always loads.
local function templateCurrency(path: string): string
	if fs.isFile(path) then
		local ok, decoded = pcall(function()
			return serde.decode("yaml", fs.readFile(path))
		end)
		if ok and type(decoded) == "table" and type(decoded.currencies) == "table" then
			local first = decoded.currencies[1]
			if type(first) == "table" and type(first.id) == "string" then
				return string.lower(first.id)
			end
		end
	end
	return "coins"
end

function M.draft(id: string, concept: string?, pack: string?, genrePath: string): string
	local currency = templateCurrency(genrePath .. "/econ-template.yml")
	local summary = designSummary(genrePath .. "/design-template.md")
	local lines: { string } = {
		"# DRAFT genre spec seeded by `forge spec init` from " .. id .. "/econ-template.yml",
		"# and " .. id .. "/design-template.md. Fill in resources, entities, actions,",
		"# loop, world, audio and the golden path, then drop `draft: true` and run",
		"# `lune run cli/forge spec validate`.",
	}
	if summary ~= nil then
		table.insert(lines, "#")
		table.insert(lines, "# " .. summary)
	end
	if concept ~= nil and concept ~= "" then
		table.insert(lines, "# concept: " .. concept)
	end
	if pack ~= nil and pack ~= "" then
		table.insert(lines, "# pack: " .. pack)
	end
	table.insert(lines, "api: 1")
	table.insert(lines, "version: 1.0.0")
	table.insert(lines, "id: " .. id)
	table.insert(lines, "runtime: " .. id)
	table.insert(lines, "draft: true")
	table.insert(lines, "resources:")
	table.insert(lines, "  - id: " .. currency .. "            # the snapshot field name, verbatim")
	table.insert(lines, "    name: Coins           # the text the HUD shows, next to the value")
	table.insert(lines, "    nameKey: coin_label")
	table.insert(lines, "    initial: 0")
	table.insert(lines, "    hud: {slot: resource-bar, order: 1}")
	table.insert(lines, "entities: []             # each row carries name (display) and nameKey (locale)")
	table.insert(lines, "actions: []              # one row per player-facing control, with label + labelKey")
	table.insert(lines, "loop: []                 # ordered stages, each with goal + goalKey and a runtime event")
	table.insert(lines, "ui:")
	table.insert(lines, "  resourceBar: {resources: [" .. currency .. "], order: 1}")
	table.insert(lines, "  actionButtons: {from: actions, kinds: [button, prompt, player-button], order: 2}")
	table.insert(lines, "  objective: {from: loop, order: 4}")
	table.insert(lines, "  notifications: {kinds: [info, refuse, reward], order: 5}")
	table.insert(lines, "locale:")
	table.insert(lines, "  # The one language a generated pack renders, and a translation for every key")
	table.insert(lines, "  # this spec declares. Both columns of the pack's locale table are filled")
	table.insert(lines, "  # from here, so a pack is consistent in either language.")
	table.insert(lines, "  default: en")
	table.insert(lines, "  strings:")
	table.insert(lines, '    coin_label: {ko: "코인"}')
	table.insert(lines, '    hud_menu: {ko: "메뉴"}')
	table.insert(lines, '    hud_select_player: {ko: "플레이어를 먼저 선택하세요"}')
	table.insert(lines, "economy:")
	table.insert(lines, '  simulation: {sourceTotal: ">0", sinkTotal: ">0"}')
	table.insert(lines, "qa:")
	table.insert(lines, "  name: golden-path")
	table.insert(lines, '  players: ["1"]')
	table.insert(lines, "  goldenPath: []          # ordered scenario steps; the draft asserts nothing yet")
	return table.concat(lines, "\n") .. "\n"
end

local function runInit(args: { string }, context: cliutil.CommandContext?): boolean
	local genre: string? = nil
	local concept: string? = nil
	local pack: string? = nil
	local force = false
	local index = 3
	while index <= #args do
		local flag = args[index]
		if flag == "--force" then
			if force then
				stdio.ewrite("Error: duplicate --force\n")
				return false
			end
			force = true
			index += 1
			continue
		end
		if flag ~= "--genre" and flag ~= "--concept" and flag ~= "--pack" then
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge spec init\n")
			return false
		end
		local value = args[index + 1]
		if value == nil or value == "" then
			stdio.ewrite("Error: " .. flag .. " requires a value\n")
			return false
		end
		if flag == "--genre" then
			if genre ~= nil then
				stdio.ewrite("Error: duplicate --genre\n")
				return false
			end
			genre = value
		elseif flag == "--concept" then
			concept = value
		else
			if pack ~= nil then
				stdio.ewrite("Error: duplicate --pack\n")
				return false
			end
			pack = value
		end
		index += 2
	end
	if genre == nil or not contract.id(genre) then
		printUsage()
		return false
	end
	local registry, registryErrors = registryLib.discover(if context then context.genresDir else nil)
	if not registry then
		stdio.ewrite(table.concat(registryErrors, "\n") .. "\n")
		return false
	end
	local package = registry.packages[genre]
	if package == nil then
		stdio.ewrite("Error: unknown genre '" .. genre .. "'\n")
		return false
	end
	local path = package.path .. "/" .. genrespec.FILE
	if fs.isFile(path) and not force then
		stdio.ewrite("Error: " .. path .. " already exists (pass --force to overwrite)\n")
		return false
	end
	fs.writeFile(path, M.draft(genre, concept, pack, package.path))
	local draft = genrespec.load(path)
	if draft == nil then
		stdio.ewrite("Error: wrote an undecodable draft at " .. path .. "\n")
		return false
	end
	stdio.write("spec: wrote draft " .. path .. "\n")
	stdio.write("spec: the draft declares no golden path; `forge spec validate` reports it as a draft\n")
	return true
end

local function runValidate(args: { string }, context: cliutil.CommandContext?): boolean
	local genre: string? = nil
	local index = 3
	while index <= #args do
		local flag = args[index]
		if flag ~= "--genre" then
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge spec validate\n")
			return false
		end
		local value = args[index + 1]
		if value == nil or value == "" then
			stdio.ewrite("Error: --genre requires a value\n")
			return false
		end
		genre = value
		index += 2
	end
	-- Discovery already validates every spec beside its runtime descriptor, so a
	-- failed discovery is exactly the `file: reason` list a caller needs.
	local registry, registryErrors = registryLib.discover(if context then context.genresDir else nil)
	if not registry then
		for _, err in registryErrors do
			stdio.ewrite(err .. "\n")
		end
		return false
	end
	local ids: { string } = if genre ~= nil then { genre } else registry.order
	local invalid = false
	for _, id in ids do
		local package = registry.packages[id]
		if package == nil then
			stdio.ewrite("spec: unknown genre '" .. tostring(id) .. "'\n")
			invalid = true
			continue
		end
		local spec = package.spec
		local draft = type(spec) == "table" and spec.draft == true
		local violations = genrespec.validate(spec, package.runtime, { id = id, path = package.path })
		if #violations > 0 then
			invalid = true
			for _, err in violations do
				stdio.ewrite(package.path .. "/" .. genrespec.FILE .. ": " .. err .. "\n")
			end
		elseif draft then
			stdio.write(package.path .. "/" .. genrespec.FILE .. ": draft (valid, incomplete)\n")
		else
			stdio.write(package.path .. "/" .. genrespec.FILE .. ": ok\n")
		end
	end
	return not invalid
end

function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local sub = args[2]
	if sub == "init" then
		return runInit(args, context)
	end
	if sub == "validate" then
		return runValidate(args, context)
	end
	stdio.ewrite("Error: forge spec requires 'init' or 'validate'\n")
	printUsage()
	return false
end

return M
