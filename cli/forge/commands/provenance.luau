--!strict
-- `forge provenance check --pack <slug> [--packs-root <dir>] [--json <path>]`
-- `forge provenance fingerprint --corpus <dir> --set <id> --out <dir>`
-- `forge provenance fingerprint --names <file> --salt <salt>`
--
-- File I/O around the pure gate in cli/forge/lib/provenance.luau. Exit codes
-- follow docs/release/cli-contract.md: 0 PASS, 1 FAIL or argument error.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local provenance = require("../lib/provenance")

local M = {}

M.PACKS_DIR = "games"

local function readOptional(path: string): string?
	if fs.isFile(path) then
		return fs.readFile(path)
	end
	return nil
end

--- True when the pack opted in with provenance/policy.yml.
function M.hasPolicy(packDir: string): boolean
	return fs.isFile(packDir .. "/" .. provenance.FILES.policy)
end

-- Directory a policy set id is loaded from. A set too large for Git may be
-- kept outside the repository; `provenance/fingerprints/<id>.path` then holds
-- one line naming the directory (relative to the repository root, or
-- absolute) that contains <id>.fp and <id>.meta.yml.
local function setDir(packDir: string, id: string): string
	local base = packDir .. "/provenance/fingerprints"
	local pointer = readOptional(base .. "/" .. id .. ".path")
	if pointer ~= nil then
		local trimmed = string.gsub(pointer, "^%s*(.-)%s*$", "%1")
		if trimmed ~= "" then
			return trimmed
		end
	end
	return base
end

--- Reads every file the gate needs from a pack directory and judges it.
function M.checkPackDir(pack: string, packDir: string): provenance.Report
	local files: { [string]: string } = {}
	for _, rel in provenance.FILES do
		local text = readOptional(packDir .. "/" .. rel)
		if text ~= nil then
			files[rel] = text
		end
	end
	local sets: { [string]: provenance.SetFiles } = {}
	local policyText = files[provenance.FILES.policy]
	if policyText ~= nil then
		local ok, decoded = pcall(function()
			return serde.decode("yaml", policyText)
		end)
		if
			ok
			and type(decoded) == "table"
			and type(decoded.ngram) == "table"
			and type(decoded.ngram.sets) == "table"
		then
			for _, id in decoded.ngram.sets do
				if type(id) == "string" and string.match(id, "^[%w%._%-]+$") then
					local dir = setDir(packDir, id)
					sets[id] = {
						fp = readOptional(dir .. "/" .. id .. ".fp"),
						meta = readOptional(dir .. "/" .. id .. ".meta.yml"),
					}
				end
			end
		end
	end
	return provenance.checkPack(pack, files, sets)
end

function M.formatReport(report: provenance.Report): (string, string)
	if report.ok then
		return string.format(
			"provenance: PASS %s (%d strings, %d entries, %d assets, sets=%s)\n",
			report.pack,
			report.strings,
			report.entries,
			report.assets,
			table.concat(report.sets, ",")
		),
			""
	end
	local lines: { string } = {}
	for _, finding in report.findings do
		table.insert(lines, provenance.formatFinding(report.pack, finding))
	end
	table.insert(lines, string.format("provenance: FAIL %s (%d findings)", report.pack, #report.findings))
	return "", table.concat(lines, "\n") .. "\n"
end

local function encodeJson(report: provenance.Report): string
	local encoded = serde.encode("json", {
		schemaVersion = 1,
		ok = report.ok,
		pack = report.pack,
		findings = report.findings,
	}, true)
	encoded = string.gsub(encoded, '"findings":(%s*){}', '"findings":%1[]')
	return encoded
end

local function parseFlags(
	args: { string },
	start: number,
	allowed: { [string]: boolean }
): ({ [string]: string }?, string?)
	local flags: { [string]: string } = {}
	local index = start
	while index <= #args do
		local flag = args[index]
		if not allowed[flag] then
			return nil, "unknown argument " .. flag
		end
		if flags[flag] ~= nil then
			return nil, "duplicate " .. flag
		end
		local value = args[index + 1]
		if value == nil or value == "" or string.sub(value, 1, 2) == "--" then
			return nil, flag .. " requires a value"
		end
		flags[flag] = value
		index += 2
	end
	return flags, nil
end

local function runCheck(args: { string }): boolean
	local flags, err = parseFlags(args, 3, { ["--pack"] = true, ["--packs-root"] = true, ["--json"] = true })
	if flags == nil then
		stdio.ewrite("provenance check: " .. tostring(err) .. "\n")
		return false
	end
	local pack = flags["--pack"]
	if pack == nil then
		stdio.ewrite("provenance check: --pack <slug> is required\n")
		return false
	end
	local packDir = (flags["--packs-root"] or M.PACKS_DIR) .. "/" .. pack
	if not fs.isDir(packDir) then
		stdio.ewrite("provenance check: no pack at " .. packDir .. "\n")
		return false
	end
	if not M.hasPolicy(packDir) then
		stdio.ewrite("provenance check: " .. pack .. " has no " .. provenance.FILES.policy .. "\n")
		return false
	end
	local report = M.checkPackDir(pack, packDir)
	local out, errText = M.formatReport(report)
	stdio.write(out)
	stdio.ewrite(errText)
	if flags["--json"] then
		local wrote, writeErr = pcall(fs.writeFile, flags["--json"], encodeJson(report))
		if not wrote then
			stdio.ewrite("provenance check: could not write " .. flags["--json"] .. ": " .. tostring(writeErr) .. "\n")
			return false
		end
	end
	return report.ok
end

local function runFingerprint(args: { string }): boolean
	local flags, err = parseFlags(args, 3, {
		["--corpus"] = true,
		["--set"] = true,
		["--out"] = true,
		["--names"] = true,
		["--salt"] = true,
	})
	if flags == nil then
		stdio.ewrite("provenance fingerprint: " .. tostring(err) .. "\n")
		return false
	end
	if flags["--names"] then
		-- One reviewed proper name per line in a gitignored file; prints the
		-- hashedNames entries (hashes only) for banned-names.yml.
		local salt = flags["--salt"]
		if salt == nil then
			stdio.ewrite("provenance fingerprint: --names requires --salt\n")
			return false
		end
		local names: { string } = {}
		for line in string.gmatch(fs.readFile(flags["--names"]) .. "\n", "([^\n]*)\n") do
			local trimmed = string.gsub(line, "^%s*(.-)%s*$", "%1")
			if trimmed ~= "" and string.sub(trimmed, 1, 1) ~= "#" then
				table.insert(names, trimmed)
			end
		end
		local entries, namesErr = provenance.hashNames(names, salt)
		if entries == nil then
			stdio.ewrite("provenance fingerprint: " .. tostring(namesErr) .. "\n")
			return false
		end
		for _, entry in entries do
			stdio.write(string.format('    - [%d, "%s"]\n', entry[1], entry[2]))
		end
		return true
	end
	local corpus, set, out = flags["--corpus"], flags["--set"], flags["--out"]
	if corpus == nil or set == nil or out == nil then
		stdio.ewrite("provenance fingerprint: --corpus, --set and --out are required\n")
		return false
	end
	if not string.match(set, "^[%w%._%-]+$") then
		stdio.ewrite("provenance fingerprint: invalid set id\n")
		return false
	end
	if not fs.isDir(corpus) then
		stdio.ewrite("provenance fingerprint: no corpus directory at " .. corpus .. "\n")
		return false
	end
	local docs: { provenance.CorpusDoc } = {}
	for _, name in fs.readDir(corpus) do
		if string.match(name, "%.txt$") and fs.isFile(corpus .. "/" .. name) then
			table.insert(docs, { name = name, text = fs.readFile(corpus .. "/" .. name) })
		end
	end
	if #docs == 0 then
		stdio.ewrite("provenance fingerprint: no .txt documents in " .. corpus .. "\n")
		return false
	end
	local fp, meta, fpErr = provenance.fingerprint(docs, { set = set })
	if fp == nil or meta == nil then
		stdio.ewrite("provenance fingerprint: " .. tostring(fpErr) .. "\n")
		return false
	end
	if not fs.isDir(out) then
		fs.writeDir(out)
	end
	fs.writeFile(out .. "/" .. set .. ".fp", fp)
	fs.writeFile(out .. "/" .. set .. ".meta.yml", meta)
	stdio.write(
		string.format(
			"provenance fingerprint: %s %d documents, %d hashes, %d bytes -> %s\n",
			set,
			#docs,
			#fp // 13,
			#fp,
			out
		)
	)
	return true
end

function M.run(args: { string }): boolean
	local sub = args[2]
	if sub == "check" then
		return runCheck(args)
	elseif sub == "fingerprint" then
		return runFingerprint(args)
	end
	stdio.ewrite("provenance: expected subcommand check or fingerprint\n")
	return false
end

return M
