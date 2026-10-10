--!strict
-- `forge codegen [<pack>]`: regenerate games/<pack>/src/shared/EconConfig.luau from econ.yml.

local fs = require("@lune/fs")
local stdio = require("@lune/stdio")

local codegen = require("../lib/codegen")
local serde = require("@lune/serde")
local registryLib = require("../lib/genreregistry")
local cliutil = require("../lib/cliutil")
local gameyml = require("../lib/gameyml")

local M = {}

local DEFAULT_PACK = "kaiju-egg-raiders"

--- Writes the generated EconConfig.luau for a pack. Returns false (with a message
--- on stderr) when the pack or its econ.yml is missing or does not decode.
function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local pack = DEFAULT_PACK
	if args[2] ~= nil and args[2] ~= "" then
		pack = args[2]
	end

	local packDir = (if context and context.packsDir then context.packsDir else "games") .. "/" .. pack
	if not fs.isDir(packDir) then
		stdio.ewrite("Error: unknown game pack '" .. pack .. "' (missing " .. packDir .. "/)\n")
		return false
	end

	local econPath = packDir .. "/econ.yml"
	if not fs.isFile(econPath) then
		stdio.ewrite("Error: missing " .. econPath .. "\n")
		return false
	end

	local generated: string = ""
	local outputName = "EconConfig.luau"
	local ok, result = pcall(function()
		local text = fs.readFile(econPath)
		local doc = serde.decode("yaml", text)
		local registry = nil
		if type(doc) == "table" and doc.genre_contract ~= nil then
			local errors
			registry, errors = registryLib.discover(if context then context.genresDir else nil)
			assert(registry ~= nil, table.concat(errors, "; "))
			local game = serde.decode("yaml", fs.readFile(packDir .. "/game.yml"))
			local checked = gameyml.validate(game, { registry = registry, config = doc })
			assert(checked.ok, table.concat(checked.errors, "; "))
		end
		local name, content = codegen.generateDocument(text, registry)
		outputName = name
		return content
	end)
	if not ok then
		stdio.ewrite("Error: failed to generate from " .. econPath .. ": " .. tostring(result) .. "\n")
		return false
	end
	generated = result :: string

	local srcDir = packDir .. "/src"
	if not fs.isDir(srcDir) then
		fs.writeDir(srcDir)
	end
	local sharedDir = srcDir .. "/shared"
	if not fs.isDir(sharedDir) then
		fs.writeDir(sharedDir)
	end

	local outputPath = sharedDir .. "/" .. outputName
	fs.writeFile(outputPath, generated)
	stdio.write("codegen: wrote " .. outputPath .. "\n")
	return true
end

return M
