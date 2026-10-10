--!strict
-- `forge plan --concept "<text>" --genre <genre> --pack <name> [--seed N] [--title
-- <text>] [--teams A,B,...] [--debug-name <name>] [--gui-name <name>]`: generates a
-- playable starter game pack from a one-line concept with no LLM or API calls.
-- The planner reads the genre's parametric template (the `plan:` block in
-- genres/<genre>/econ-template.yml plus design-template.md), derives the title,
-- roster, economy, monetization and design docs deterministically, auto-tunes the
-- balance against the pure econsim simulator, and renders every playable file
-- (config, catalog, remotes, messages, copy, audio, creature models, fx, world
-- layout/theme, server/client binders, project manifest, liveops/deploy config,
-- locale sheet, smoke suite) straight from the roster and economy, with zero
-- hand-written code.

local fs = require("@lune/fs")
local stdio = require("@lune/stdio")

local planner = require("../lib/planner")
local scaffold = require("../lib/scaffold")
local cliutil = require("../lib/cliutil")

local registryLib = require("../lib/genreregistry")
local generate = require("../lib/genregenerate")
local newCommand = require("./new")
local M = {}

local DEFAULT_SEED = 0
local DEFAULT_TEAMS = { "Red", "Blue" }

function M.hasDuplicateTeams(teams: { string }): boolean
	local seen: { [string]: boolean } = {}
	for _, name in teams do
		if seen[name] then
			return true
		end
		seen[name] = true
	end
	return false
end

local function printUsage()
	stdio.ewrite([[Usage: lune run cli/forge plan --concept "<text>" --genre <genre> --pack <name>
       [--seed N] [--title "<text>"] [--teams A,B,...] [--debug-name <name>] [--gui-name <name>]

  Generate a playable starter game pack (game.yml, econ.yml, liveops.yml,
  deploy.yml, design/, locale/, smoke/, playable src/) from a concept. Deterministic
  and keyless: the same concept + seed always writes the same bytes.
  Generation does not approve vertical-slice or release-candidate quality.

  Flags:
    --concept <text>     one-line game concept (required)
    --genre <name>       genre module under genres/ (required, e.g. collect-raid)
    --pack <slug>        new pack directory under games/ (required, lowercase-kebab)
    --seed N             deterministic generation/tuning seed (default: 0)
    --title <text>       override the derived title (default: derived from concept)
    --teams A,B,...      comma-separated team names (default: Red,Blue)
    --debug-name <name>  debug menu binding name (default: <Pascal>Debug)
    --gui-name <name>    top-level ScreenGui name (default: <Pascal>Gui)
    --force               overwrite an existing hand-made pack directory too
]])
end

local function splitCommaList(text: string): { string }
	local parts: { string } = {}
	for part in string.gmatch(text, "[^,]+") do
		table.insert(parts, part)
	end
	return parts
end

--- Parses flags, builds and tunes the plan, writes games/<pack>/, and returns false
--- with a stderr message on any usage or generation error.
function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local concept: string? = nil
	local genre: string? = nil
	local pack: string? = nil
	local seed = DEFAULT_SEED
	local titleOverride: string? = nil
	local teams: { string } = DEFAULT_TEAMS
	local debugNameOverride: string? = nil
	local guiNameOverride: string? = nil
	local force = false

	local index = 2
	while index <= #args do
		local flag = args[index]
		if flag == "--force" then
			force = true
			index += 1
			continue
		end
		local flagsWithValues = {
			"--concept",
			"--genre",
			"--pack",
			"--seed",
			"--title",
			"--teams",
			"--debug-name",
			"--gui-name",
		}
		local recognized = false
		for _, candidate in flagsWithValues do
			if flag == candidate then
				recognized = true
				break
			end
		end
		if recognized then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: " .. flag .. " requires a value\n")
				return false
			end
			if flag == "--concept" then
				concept = value
			elseif flag == "--genre" then
				genre = value
			elseif flag == "--pack" then
				pack = value
			elseif flag == "--title" then
				titleOverride = value
			elseif flag == "--teams" then
				teams = splitCommaList(value)
				if #teams < 2 then
					stdio.ewrite("Error: --teams requires at least 2 comma-separated names\n")
					return false
				end
				if M.hasDuplicateTeams(teams) then
					stdio.ewrite("Error: --teams contains duplicate names\n")
					return false
				end
				for _, teamName in teams do
					if not cliutil.isRecordableToken(teamName) then
						stdio.ewrite(
							"Error: --teams name '"
								.. teamName
								.. "' cannot be recorded reproducibly (no spaces, commas, or quotes)\n"
						)
						return false
					end
				end
			elseif flag == "--debug-name" then
				if not cliutil.isRecordableToken(value) then
					stdio.ewrite("Error: --debug-name cannot be recorded reproducibly (no spaces, commas, or quotes)\n")
					return false
				end
				debugNameOverride = value
			elseif flag == "--gui-name" then
				if not cliutil.isRecordableToken(value) then
					stdio.ewrite("Error: --gui-name cannot be recorded reproducibly (no spaces, commas, or quotes)\n")
					return false
				end
				guiNameOverride = value
			else
				local number, reason = cliutil.parseFiniteInt(value)
				if number == nil then
					stdio.ewrite("Error: --seed requires a number: " .. tostring(reason) .. "\n")
					return false
				end
				if not cliutil.isSafeInteger(number) then
					stdio.ewrite(
						"Error: --seed must satisfy |seed| < 2^53 to be recorded reproducibly, got '" .. value .. "'\n"
					)
					return false
				end
				seed = number
			end
			index += 2
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge plan\n")
			return false
		end
	end

	if concept == nil or genre == nil or pack == nil then
		printUsage()
		return false
	end
	if not scaffold.isValidSlug(pack) then
		stdio.ewrite("Error: invalid pack slug '" .. pack .. "' (must be lowercase-kebab, e.g. 'my-game-2')\n")
		return false
	end
	local selected, parseError = newCommand.parseGenres(genre)
	if not selected then
		stdio.ewrite("Error: " .. tostring(parseError) .. "\n")
		return false
	end
	local registry, errors = registryLib.discover(if context then context.genresDir else nil)
	if not registry then
		stdio.ewrite("FORGE_INVALID_CATALOG: " .. table.concat(errors, "\n") .. "\n")
		return false
	end
	local destination =
		generate.absolute((if context and context.packsDir then context.packsDir else "games") .. "/" .. pack)
	if fs.isDir(destination) or fs.isFile(destination) then
		local marker = destination .. "/econ.yml"
		if
			not force
			and (
				not fs.isFile(marker)
				or string.sub(fs.readFile(marker), 1, #"# GENERATED by forge plan") ~= "# GENERATED by forge plan"
			)
		then
			stdio.ewrite("Error: pack already exists (pass --force): " .. destination .. "\n")
			return false
		end
	end
	local title = if titleOverride then planner.sanitizeTitle(titleOverride) else planner.deriveTitle(concept)
	local pascal = scaffold.pascalCase(pack)
	local ok, result = pcall(function()
		local assembly = generate.assemble(registry, selected, {
			mode = "plan",
			slug = pack,
			pascal = pascal,
			title = title,
			concept = concept,
			seed = seed,
			teams = teams,
			debugName = debugNameOverride or pascal .. "Debug",
			guiName = guiNameOverride or pascal .. "Gui",
		}, destination)
		local written, reason = generate.write(assembly, destination, pack, context)
		assert(written, reason)
	end)
	if not ok then
		stdio.ewrite("Error: plan " .. destination .. ": " .. tostring(result) .. "\n")
		return false
	end
	stdio.write("planned " .. destination .. "/\n")
	stdio.write("plan: starter output; generation does not grant quality or release approval\n")
	return true
end
return M
