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
local cliutil = require("../lib/cliutil")

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
function M.check(path: string): boolean
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
		local flags, flagError = parseFlags(args, 3, { "file" })
		if flags == nil then
			return fail((flagError :: string) .. " for forge content check")
		end
		local file = (flags :: { [string]: string }).file
		if file == nil then
			return fail("forge content check requires --file <path>")
		end
		return M.check(file)
	end
	if sub == "codegen" then
		local flags, flagError = parseFlags(args, 3, { "pack", "packs-root" })
		if flags == nil then
			return fail((flagError :: string) .. " for forge content codegen")
		end
		local values = flags :: { [string]: string }
		local pack = values.pack
		if pack == nil then
			return fail("forge content codegen requires --pack <slug>")
		end
		return M.codegen(pack, context, values["packs-root"])
	end
	return fail("forge content requires 'check' or 'codegen', e.g. lune run cli/forge content check --file <path>")
end

return M
