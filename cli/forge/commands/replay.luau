--!strict
-- `forge replay <journal.json> [--packs-root <dir>] [--json]`
--
-- Rebuilds a fresh native Session for the journal's scenario target (the same
-- construction qaharness uses for `qa run`), applies the recorded entries in
-- order with the recorded clock and seed, and compares the rebuilt state hash
-- with the recorded one. Prints "replay: MATCH <hash>" (0) or
-- "replay: MISMATCH expected=<a> actual=<b>" (1); usage, decode and target
-- errors return 2. Dispatch and process.exit are wired by the CLI entry point.
--
-- The target pack is the scenario's own `pack` binding. Its directory is
-- --packs-root when given, else games/<pack>, else the scenario fixture
-- convention cli/forge/fixtures/<scenario>/<pack>.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local Journal = require("../../../core/domain/command/Journal")
local qaharness = require("../lib/qaharness")
local qascenario = require("../lib/qascenario")
local registryLib = require("../lib/genreregistry")
local cliutil = require("../lib/cliutil")
local qa = require("./qa")

local M = {}

M.SCHEMA_VERSION = 1

export type Output = { write: (string) -> (), ewrite: (string) -> () }
export type Options = { journal: string, packsRoot: string?, json: boolean }

local USAGE = "Usage: lune run cli/forge replay <journal.json> [--packs-root <dir>] [--json]\n"

function M.parseArgs(args: { string }): (Options?, string?)
	local journal: string? = nil
	local packsRoot: string? = nil
	local json = false
	-- args[1] is the command name itself, as for every forge command.
	local index = 2
	while index <= #args do
		local arg = args[index]
		if arg == "--json" then
			json = true
			index += 1
		elseif arg == "--packs-root" then
			local value = args[index + 1]
			if value == nil or value == "" then
				return nil, "--packs-root requires a value"
			end
			packsRoot = value
			index += 2
		elseif string.sub(arg, 1, 2) == "--" then
			return nil, "unknown argument '" .. arg .. "'"
		elseif journal ~= nil then
			return nil, "unexpected argument '" .. arg .. "'"
		else
			journal = arg
			index += 1
		end
	end
	if journal == nil then
		return nil, "replay requires a journal path"
	end
	return { journal = journal :: string, packsRoot = packsRoot, json = json }, nil
end

local function packsDirFor(pack: string, name: string, explicit: string?): string?
	if explicit ~= nil then
		return explicit
	end
	if fs.isFile("games/" .. pack .. "/econ.yml") then
		return "games"
	end
	local fixture = "cli/forge/fixtures/" .. name
	if fs.isFile(fixture .. "/" .. pack .. "/econ.yml") then
		return fixture
	end
	return nil
end

export type Report = {
	match: boolean,
	expected: string,
	actual: string,
	scenario: string,
	entries: number,
	diverged: string?,
}

--- Replays a decoded journal. Returns a report, or nil plus an error that maps
--- to exit code 2.
function M.replay(journal: Journal.Journal, packsRoot: string?, context: cliutil.CommandContext?): (Report?, string?)
	local reference = journal.meta.scenario
	if reference == nil or journal.stateHash == nil then
		return nil, "journal names no scenario or carries no stateHash"
	end
	local registry, registryErrors = registryLib.discover(if context then context.genresDir else nil)
	if not registry then
		return nil, table.concat(registryErrors, "; ")
	end
	local genre, name = string.match(reference, "^([^:]+):([^:]+)$")
	if genre == nil or name == nil or registry.packages[genre] == nil then
		return nil, "journal scenario must be <genre>:<name> for a known genre"
	end
	-- Read the scenario's pack binding from the genre copy, then resolve through
	-- the same path `qa run` uses so a pack-local override wins identically.
	local genrePath = registry.packages[genre].path .. "/qa-scenarios/" .. name .. ".yml"
	if not fs.isFile(genrePath) then
		return nil, "scenario not found: " .. genrePath
	end
	local okGenre, genreRaw = pcall(function()
		return serde.decode("yaml", fs.readFile(genrePath))
	end)
	if not okGenre or type(genreRaw) ~= "table" or type(genreRaw.pack) ~= "string" then
		return nil, "scenario declares no pack: " .. genrePath
	end
	local pack: string = genreRaw.pack
	local packsDir = packsDirFor(pack, name :: string, packsRoot)
	if packsDir == nil then
		return nil, "no target found for pack '" .. pack .. "'; pass --packs-root"
	end
	local resolution, resolutionErrors = qa.resolveScenario(reference, pack, packsDir, registry)
	if resolution == nil then
		return nil, table.concat(resolutionErrors, "; ")
	end
	local okRaw, raw = pcall(function()
		return serde.decode("yaml", fs.readFile(resolution.path))
	end)
	if not okRaw or type(raw) ~= "table" or raw.kind ~= "native" then
		return nil, "journal scenario is not a native scenario: " .. resolution.path
	end
	local errors = qascenario.validate(raw)
	if #errors > 0 then
		return nil, table.concat(errors, "; ")
	end
	local target, targetErrors = qa.loadTarget(pack, registry, context, packsDir)
	if target == nil then
		return nil, table.concat(targetErrors, "; ")
	end
	local outcome = qaharness.runNative(raw, target, nil, { replay = journal })
	local expected = journal.stateHash :: string
	local actual = outcome.stateHash or "none"
	return {
		match = outcome.diverged == nil and actual == expected,
		expected = expected,
		actual = actual,
		scenario = reference,
		entries = #journal.entries,
		diverged = outcome.diverged,
	},
		nil
end

function M.run(args: { string }, out: Output?, context: cliutil.CommandContext?): number
	local io: Output = out or { write = stdio.write, ewrite = stdio.ewrite }
	local options, parseErr = M.parseArgs(args)
	if options == nil then
		io.ewrite("Error: " .. tostring(parseErr) .. "\n" .. USAGE)
		return 2
	end
	if not fs.isFile(options.journal) then
		io.ewrite("replay: error: cannot read " .. options.journal .. "\n")
		return 2
	end
	local decoded, journal = pcall(Journal.decode, fs.readFile(options.journal))
	if not decoded then
		io.ewrite("replay: error: " .. tostring(journal) .. "\n")
		return 2
	end
	local okReplay, report, replayErr = pcall(M.replay, journal, options.packsRoot, context)
	if not okReplay then
		io.ewrite("replay: error: " .. tostring(report) .. "\n")
		return 2
	end
	if report == nil then
		io.ewrite("replay: error: " .. tostring(replayErr) .. "\n")
		return 2
	end
	if options.json then
		io.write(serde.encode("json", {
			schemaVersion = M.SCHEMA_VERSION,
			match = report.match,
			expected = report.expected,
			actual = report.actual,
			scenario = report.scenario,
			entries = report.entries,
			diverged = report.diverged,
		}) .. "\n")
	elseif report.match then
		io.write("replay: MATCH " .. report.actual .. "\n")
	else
		if report.diverged ~= nil then
			io.ewrite("replay: diverged: " .. report.diverged .. "\n")
		end
		io.write(string.format("replay: MISMATCH expected=%s actual=%s\n", report.expected, report.actual))
	end
	return if report.match then 0 else 1
end

return M
