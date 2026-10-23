--!strict
-- `forge content check --file <path>`: validate a survival content catalog.
-- `forge content codegen --pack <slug>`: write the pack's generated
-- src/shared/SurvivalContent.luau from its content.yml, deterministically.
--
-- Both subcommands refuse to publish anything built from a document that
-- failed validation: check never writes, and codegen validates before it
-- touches the filesystem, so a malformed catalog cannot leave a partial or
-- stale generated file behind.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local Content = require("../../../core/domain/survival/Content")
local Capability = require("../../../core/domain/survival/Capability")
local contentrender = require("../lib/contentrender")
local contentgraph = require("../lib/contentgraph")
local cliutil = require("../lib/cliutil")
local contract = require("../lib/genrecontract")

local M = {}

local CONTENT_FILE = "content.yml"

local function fail(message: string): boolean
	stdio.ewrite("Error: " .. message .. "\n")
	return false
end

local function report(path: string, errors: { string }): boolean
	for _, err in errors do
		stdio.ewrite(path .. ": " .. err .. "\n")
	end
	return false
end

local function decode(path: string): (any?, string?)
	if not fs.isFile(path) then
		return nil, "missing " .. path
	end
	local ok, decoded = pcall(function()
		return serde.decode("yaml", fs.readFile(path))
	end)
	if not ok then
		return nil, path .. ": " .. tostring(decoded)
	end
	return decoded, nil
end

local function embedded(econ: any): any
	return if type(econ) == "table"
			and type(econ.genre_contract) == "table"
			and type(econ.genre_contract.configs) == "table"
			and type(econ.genre_contract.configs["survival-coop"]) == "table"
			and type(econ.genre_contract.configs["survival-coop"].inventory) == "table"
		then econ.genre_contract.configs["survival-coop"].inventory.content
		else nil
end

function M.econErrors(document: Content.Document, econ: any): { string }
	local value = embedded(econ)
	if value == nil then
		return if type(econ) == "table"
				and type(econ.genre_contract) == "table"
				and type(econ.genre_contract.configs) == "table"
				and econ.genre_contract.configs["survival-coop"] ~= nil
			then { "econ.yml: survival-coop inventory.content is missing; run forge content sync-econ --pack <slug>" }
			else {}
	end
	if type(value) ~= "table" then
		return { "econ.yml: survival-coop inventory.content must be a mapping" }
	end
	-- Canonical comparison ignores mapping/list order and fills legacy defaults.
	local raw = table.clone(value)
	raw.survival_content = document.version
	local canonical = Content.canonicalize(raw)
	if
		canonical == nil
		or contract.serialize(Content.projectV1(canonical)) ~= contract.serialize(Content.projectV1(document))
	then
		return {
			"econ.yml: genre_contract.configs.survival-coop.inventory.content differs from canonical content.yml v1 projection; run forge content sync-econ --pack <slug>",
		}
	end
	return {}
end

local function checkEcon(path: string, document: Content.Document): boolean
	local econPath = (path:match("^(.*[/\\])") or "") .. "econ.yml"
	if not fs.isFile(econPath) then
		return true
	end
	local econ, reason = decode(econPath)
	if econ == nil then
		return fail(reason :: string)
	end
	local errors = M.econErrors(document, econ)
	return if #errors == 0 then true else report(path, errors)
end

--- Locate only the nested mapping block; all surrounding bytes remain untouched.
function M.syncText(source: string, document: Content.Document): (string?, string?)
	local target = { "genre_contract", "configs", "survival-coop", "inventory", "content" }
	local stack: { { indent: number, key: string } } = {}
	local start: number? = nil
	local finish = #source + 1
	local blockIndent = 0
	local versionStart: number? = nil
	local versionFinish: number? = nil
	local versionIndent = ""
	local cursor = 1
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		local spaces, key = line:match("^(%s*)['\"]?([%w_%-]+)['\"]?:%s*")
		if start and line:match("%S") and #(line:match("^(%s*)") :: string) <= blockIndent then
			finish = cursor
			break
		end
		if spaces and key then
			while #stack > 0 and stack[#stack].indent >= #spaces do
				table.remove(stack)
			end
			table.insert(stack, { indent = #spaces, key = key })
			if
				#stack == 4
				and stack[1].key == "genre_contract"
				and stack[2].key == "configs"
				and stack[3].key == "survival-coop"
				and key == "contentVersion"
			then
				versionStart = cursor
				versionIndent = spaces
				versionFinish = cursor + #line + 1
			end
			local matches = #stack == #target
			for index, part in stack do
				if part.key ~= target[index] then
					matches = false
				end
			end
			if matches then
				start = cursor + #line + 1
				blockIndent = #spaces
			end
		elseif versionFinish and cursor == versionFinish then
			versionFinish = cursor + #line + 1
		end
		cursor += #line + 1
	end
	if start == nil then
		return nil, "econ.yml: missing genre_contract.configs.survival-coop.inventory.content block"
	end
	local newline = if source:find("\r\n", 1, true) then "\r\n" else "\n"
	local lines = {}
	for line in serde.encode("yaml", Content.projectV1(document)):gmatch("[^\r\n]+") do
		table.insert(lines, string.rep(" ", blockIndent + 1) .. line)
	end
	local prefix = source:sub(1, (start :: number) - 1)
	if document.version == 2 and versionStart and versionFinish then
		prefix = prefix:sub(1, versionStart - 1)
			.. versionIndent
			.. "contentVersion: 2"
			.. newline
			.. prefix:sub(versionFinish)
	end
	return prefix .. table.concat(lines, newline) .. newline .. source:sub(finish), nil
end

function M.syncEcon(pack: string, root: string): boolean
	if not cliutil.isValidKey(pack) then
		return fail("invalid pack slug")
	end
	local dir = root .. "/" .. pack
	local raw, reason = decode(dir .. "/content.yml")
	if raw == nil then
		return fail(reason :: string)
	end
	local document, errors = Content.canonicalize(raw)
	if not document then
		return report(dir .. "/content.yml", errors)
	end
	local path = dir .. "/econ.yml"
	local econ, econReason = decode(path)
	if not econ then
		return fail(econReason :: string)
	end
	if embedded(econ) == nil then
		return fail("econ.yml: missing survival-coop inventory content")
	end
	local rewritten, rewriteReason = M.syncText(fs.readFile(path), document)
	if not rewritten then
		return fail(rewriteReason :: string)
	end
	local decoded = serde.decode("yaml", rewritten)
	if #M.econErrors(document, decoded) > 0 then
		return fail("econ.yml: synchronized projection failed equality")
	end
	fs.writeFile(path, rewritten)
	stdio.write("content sync-econ: wrote " .. path .. "\n")
	return true
end

local function parseFlags(args: { string }, start: number, allowed: { string }): ({ [string]: string }?, string?)
	local values: { [string]: string } = {}
	local index = start
	while index <= #args do
		local flag = args[index]
		local name = string.match(flag, "^%-%-([%w%-]+)$")
		if name == nil or table.find(allowed, name) == nil then
			return nil, "unknown argument '" .. tostring(flag) .. "'"
		end
		local value = args[index + 1]
		if value == nil or value == "" or string.sub(value, 1, 2) == "--" then
			return nil, "--" .. name .. " requires a value"
		end
		if values[name] ~= nil then
			return nil, "duplicate --" .. name
		end
		values[name] = value
		index += 2
	end
	return values, nil
end

--- Validates one content document. Returns true only when the catalog is
--- fully valid; every violation is printed as `<path>: <field>: <reason>`.
function M.check(path: string, graphJson: string?): boolean
	local raw, reason = decode(path)
	if raw == nil then
		return fail(reason :: string)
	end
	local errors = Content.validate(raw)
	if #errors > 0 then
		return report(path, errors)
	end
	local document = Content.canonicalize(raw)
	assert(document ~= nil, "validated content must canonicalize")
	local resolved = document :: Content.Document
	local graph = contentgraph.check(resolved)
	if graphJson then
		local parent = graphJson:match("^(.*)[/\\][^/\\]+$")
		if parent and not fs.isDir(parent) then
			fs.writeDir(parent)
		end
		local json = serde.encode("json", graph, true)
		-- Lune represents empty tables as objects; these result fields are lists.
		for _, field in
			{
				"unresolved",
				"levelFailures",
				"stationCycles",
				"skillCycles",
				"missingEntryActions",
				"unhandledEntryActions",
				"rankPrefix",
				"unplacedSpecies",
				"levelReachability",
			}
		do
			json = json:gsub('("' .. field .. '"%s*:%s*){}', "%1[]")
		end
		fs.writeFile(graphJson, json .. "\n")
	end
	if not graph.ok then
		return fail(path .. ": catalog graph failed: " .. serde.encode("json", graph))
	end
	if not checkEcon(path, resolved) then
		return false
	end
	stdio.write(
		string.format(
			"content: PASS %s (v%d, %d items, %d recipes, %d nodes, %d structures, %d wildlife)\n",
			path,
			resolved.version,
			#resolved.items,
			#resolved.recipes,
			#resolved.nodes,
			#resolved.structures,
			#resolved.wildlife
		)
	)
	local missing = Capability.missingFeatures("crafting")
	if #missing > 0 then
		stdio.write("content: crafting declares unimplemented features: " .. table.concat(missing, ", ") .. "\n")
	end
	return true
end

--- Writes `<packs-root>/<pack>/src/shared/SurvivalContent.luau` from the
--- pack's content.yml. Byte-identical across runs for identical input.
function M.codegen(pack: string, context: cliutil.CommandContext?, packsRoot: string?): boolean
	if not cliutil.isValidKey(pack) then
		return fail("invalid pack slug '" .. pack .. "'")
	end
	local root = packsRoot or (if context and context.packsDir then context.packsDir else "games")
	local packDir = root .. "/" .. pack
	if not fs.isDir(packDir) then
		return fail("unknown game pack '" .. pack .. "' (missing " .. packDir .. "/)")
	end
	local path = packDir .. "/" .. CONTENT_FILE
	local raw, reason = decode(path)
	if raw == nil then
		return fail(reason :: string)
	end
	local canonical, validationErrors = Content.canonicalize(raw)
	if not canonical then
		return report(path, validationErrors)
	end
	if not checkEcon(path, canonical) then
		return false
	end
	local rendered, errors = contentrender.build(raw, "crafting")
	if rendered == nil then
		return report(path, errors)
	end
	local sharedDir = packDir .. "/src/shared"
	for _, dir in { packDir .. "/src", sharedDir } do
		if not fs.isDir(dir) then
			fs.writeDir(dir)
		end
	end
	local outputPath = packDir .. "/" .. (rendered :: contentrender.Rendered).path
	fs.writeFile(outputPath, (rendered :: contentrender.Rendered).content)
	stdio.write("content codegen: wrote " .. outputPath .. "\n")
	return true
end

function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local sub = args[2]
	if sub == "check" then
		local flags, flagError = parseFlags(args, 3, { "file", "pack", "graph-json" })
		if flags == nil then
			return fail((flagError :: string) .. " for forge content check")
		end
		local values = flags :: { [string]: string }
		if values.pack and not cliutil.isValidKey(values.pack) then
			return fail("invalid pack slug")
		end
		local file = values.file
			or (
				if values.pack
					then (if context and context.packsDir then context.packsDir else "games")
						.. "/"
						.. values.pack
						.. "/content.yml"
					else nil
			)
		if file == nil then
			return fail("forge content check requires --file <path>")
		end
		return M.check(file, values["graph-json"])
	end
	if sub == "codegen" or sub == "sync-econ" then
		local flags, flagError = parseFlags(args, 3, { "pack", "packs-root" })
		if flags == nil then
			return fail((flagError :: string) .. " for forge content codegen")
		end
		local values = flags :: { [string]: string }
		local pack = values.pack
		if pack == nil then
			return fail("forge content codegen requires --pack <slug>")
		end
		if sub == "sync-econ" then
			return M.syncEcon(
				pack,
				values["packs-root"] or (if context and context.packsDir then context.packsDir else "games")
			)
		end
		return M.codegen(pack, context, values["packs-root"])
	end
	return fail(
		"forge content requires 'check', 'codegen' or 'sync-econ', e.g. lune run cli/forge content check --file <path>"
	)
end

return M
