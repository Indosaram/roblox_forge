--!strict
local fs = require("@lune/fs")
local stdio = require("@lune/stdio")
local scaffold = require("../lib/scaffold")
local registryLib = require("../lib/genreregistry")
local generate = require("../lib/genregenerate")
local cliutil = require("../lib/cliutil")
local M = {}
function M.parseGenres(raw: string?): ({ string }?, string?)
	local genres: { string } = {}
	local seen: { [string]: boolean } = {}
	if raw ~= nil then
		for token in string.gmatch(raw, "[^,]+") do
			local trimmed = string.gsub(string.gsub(token, "^%s+", ""), "%s+$", "")
			if trimmed ~= "" then
				if seen[trimmed] then
					return nil, "duplicate genre '" .. trimmed .. "'"
				end
				seen[trimmed] = true
				table.insert(genres, trimmed)
			end
		end
	end
	if #genres == 0 then
		return nil, nil
	end
	return genres, nil
end

function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local slug = args[2]
	if not slug or not scaffold.isValidSlug(slug) then
		stdio.ewrite("Error: new requires a lowercase-kebab slug\n")
		return false
	end
	local raw: string? = nil
	local runtimeMode: string? = nil
	local index = 3
	while index <= #args do
		local flag, value = args[index], args[index + 1]
		if not value or (flag ~= "--genre" and flag ~= "--mode") then
			stdio.ewrite("Error: invalid new argument\n")
			return false
		end
		if flag == "--genre" then
			if raw ~= nil then
				stdio.ewrite("Error: repeated --genre\n")
				return false
			end
			raw = value
		else
			if runtimeMode ~= nil or value ~= "crafting" then
				stdio.ewrite("Error: --mode supports only one explicit crafting selection\n")
				return false
			end
			runtimeMode = value
		end
		index += 2
	end
	local selected, parseError = M.parseGenres(raw)
	if not selected then
		stdio.ewrite("Error: " .. (parseError or "--genre is required") .. "\n")
		return false
	end
	if runtimeMode and (#selected ~= 1 or selected[1] ~= "survival-coop") then
		stdio.ewrite("Error: --mode crafting requires survival-coop alone\n")
		return false
	end
	local registry, errors = registryLib.discover(if context then context.genresDir else nil)
	if not registry then
		stdio.ewrite("FORGE_INVALID_CATALOG: " .. table.concat(errors, "\n") .. "\n")
		return false
	end
	local destination =
		generate.absolute((if context and context.packsDir then context.packsDir else "games") .. "/" .. slug)
	if fs.isDir(destination) or fs.isFile(destination) then
		stdio.ewrite("Error: pack already exists: " .. destination .. "\n")
		return false
	end
	local pascal = scaffold.pascalCase(slug)
	local ok, result = pcall(function()
		local assembly = generate.assemble(registry, selected, {
			mode = "new",
			slug = slug,
			pascal = pascal,
			title = scaffold.titleCase(slug),
			concept = "",
			seed = 0,
			teams = { "Red", "Blue" },
			debugName = pascal .. "Debug",
			guiName = pascal .. "Gui",
		}, destination, runtimeMode)
		local written, reason = generate.write(assembly, destination, slug, context)
		assert(written, reason)
	end)
	if not ok then
		stdio.ewrite("Error: new " .. destination .. ": " .. tostring(result) .. "\n")
		return false
	end
	stdio.write("created " .. destination .. "/\n")
	return true
end
return M
