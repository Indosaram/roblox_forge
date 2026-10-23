--!strict
-- `forge gate [--pack <slug>] [--jobs N|auto] [--json <path>] [--out <dir>]`:
-- the one-command pre-commit gate. It replaces the hand-written .cmd batches
-- that ran `check`, then every native scenario record+replay, then
-- `build --all` and `smoke` one after another (~20 minutes each).
--
--   1. fast stages first (`check --skip specs,build`): lint, types, codegen
--      drift and content drift fail in seconds instead of after the specs;
--   2. then, concurrently: sharded specs, every native qa scenario of the pack
--      (record + replay), `build --all` and `smoke --local`;
--   3. the working tree is fingerprinted before and after; any source edit
--      during the run makes the verdict INVALID (exit 1), because a pass on a
--      tree that changed underneath proves nothing.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local pool = require("../lib/pool")
local specs = require("../lib/specs")
local treeguard = require("../lib/treeguard")
local registryLib = require("../lib/genreregistry")

local M = {}

local DEFAULT_PACK = "robango-island"

export type Options = { pack: string, jobs: number, json: string?, out: string, failFast: boolean }

function M.parseArgs(args: { string }): (Options?, string?)
	local options: Options = {
		pack = DEFAULT_PACK,
		jobs = specs.autoJobs(),
		json = nil,
		out = "build/gate",
		failFast = true,
	}
	local index = 2
	while index <= #args do
		local flag = args[index]
		if flag == "--no-fail-fast" then
			options.failFast = false
			index += 1
			continue
		end
		local value = args[index + 1]
		if value == nil or value == "" or string.sub(value, 1, 2) == "--" then
			return nil, flag .. " requires a value"
		end
		if flag == "--pack" then
			options.pack = value
		elseif flag == "--json" then
			options.json = value
		elseif flag == "--out" then
			options.out = value
		elseif flag == "--jobs" then
			local count = if value == "auto" then specs.autoJobs() else tonumber(value)
			if count == nil or count < 1 or count ~= math.floor(count) then
				return nil, "--jobs requires a positive integer or auto"
			end
			options.jobs = count
		else
			return nil, "unknown argument '" .. flag .. "' for forge gate"
		end
		index += 2
	end
	return options, nil
end

-- Every native scenario that can run against the pack, as <genre>:<name>:
-- pack-local scenarios, plus each native scenario of the pack's genres that is
-- not bound to another pack (a `pack:` field naming a different pack), plus
-- every native scenario game.yml selects explicitly in qa_scenarios.
function M.nativeScenarios(pack: string, registry: registryLib.Registry): { string }
	local seen: { [string]: boolean } = {}
	local refs: { string } = {}
	local function add(genre: string, name: string, path: string, selected: boolean?)
		local ref = genre .. ":" .. name
		if seen[ref] then
			return
		end
		local okDecode, raw = pcall(function()
			return serde.decode("yaml", fs.readFile(path))
		end)
		if
			okDecode
			and type(raw) == "table"
			and raw.kind == "native"
			and (selected or raw.pack == nil or raw.pack == pack)
		then
			seen[ref] = true
			table.insert(refs, ref)
		end
	end
	local packDir = "games/" .. pack
	local localDir = packDir .. "/qa-scenarios"
	if fs.isDir(localDir) then
		for _, file in fs.readDir(localDir) do
			local genre, name = string.match(file, "^([a-z][a-z0-9%-]*)%.([a-z][a-z0-9%-]*)%.yml$")
			if genre ~= nil and name ~= nil and registry.packages[genre] ~= nil then
				add(genre, name, localDir .. "/" .. file)
			end
		end
	end
	local okGame, game = pcall(function()
		return serde.decode("yaml", fs.readFile(packDir .. "/game.yml"))
	end)
	if okGame and type(game) == "table" and type(game.qa_scenarios) == "table" then
		for _, ref in game.qa_scenarios do
			local genreMatch, nameMatch = string.match(tostring(ref), "^([^:]+):([^:]+)$")
			local package = if genreMatch ~= nil then registry.packages[genreMatch] else nil
			if package ~= nil and genreMatch ~= nil and nameMatch ~= nil then
				local genre: string, name: string = genreMatch, nameMatch
				local localPath = localDir .. "/" .. genre .. "." .. name .. ".yml"
				add(
					genre,
					name,
					if fs.isFile(localPath) then localPath else package.path .. "/qa-scenarios/" .. name .. ".yml",
					true
				)
			end
		end
	end
	if okGame and type(game) == "table" and type(game.genres) == "table" then
		for _, genre in game.genres do
			local package = registry.packages[tostring(genre)]
			local dir = if package then package.path .. "/qa-scenarios" else nil
			if dir ~= nil and fs.isDir(dir) then
				for _, file in fs.readDir(dir) do
					local name = string.match(file, "^([a-z][a-z0-9%-]*)%.yml$")
					if name ~= nil then
						add(tostring(genre), name, dir .. "/" .. file)
					end
				end
			end
		end
	end
	table.sort(refs)
	return refs
end

local function tail(text: string, size: number): string
	return if #text > size then "..." .. string.sub(text, -size) else text
end

function M.run(args: { string }): boolean
	local options, err = M.parseArgs(args)
	if options == nil then
		stdio.ewrite("Error: " .. tostring(err) .. "\n")
		return false
	end
	local opts = options :: Options
	local started = os.clock()
	local before, fpErr = treeguard.fingerprint()
	if before == nil then
		stdio.ewrite("gate: FAIL " .. tostring(fpErr) .. "\n")
		return false
	end
	local registry, registryErrors = registryLib.discover()
	if registry == nil then
		stdio.ewrite(table.concat(registryErrors, "\n") .. "\n")
		return false
	end
	if not fs.isDir("games/" .. opts.pack) then
		stdio.ewrite("Error: unknown game pack '" .. opts.pack .. "'\n")
		return false
	end
	local journals = opts.out .. "/journals"
	if not fs.isDir(journals) then
		fs.writeDir(journals)
	end

	local report: { [string]: any } = { schemaVersion = 1, pack = opts.pack, head = before.head, jobs = {} }
	local failed: { string } = {}
	local entries: { any } = {}
	local function record(result: pool.JobResult)
		local last = result.steps[#result.steps]
		local entry = {
			name = result.name,
			ok = result.ok,
			ms = math.floor(result.ms),
			exit = if last then last.code else 0,
			output = if result.ok then nil else tail((last and (last.stdout .. last.stderr)) or "", 4000),
		}
		table.insert(entries, entry)
		if not result.ok then
			table.insert(failed, result.name)
		end
		stdio.write(
			string.format("[%s] %s (%.1f s)\n", result.name, if result.ok then "PASS" else "FAIL", result.ms / 1000)
		)
		if not result.ok then
			stdio.write(tostring(entry.output) .. "\n")
		end
	end

	-- Phase 1: every cheap stage, so a lint/type/drift error costs seconds.
	local fast = pool.run({ { name = "check-fast", steps = { { "check", "--skip", "specs,build" } } } }, 1, record)
	if not fast[1].ok and opts.failFast then
		stdio.write("gate: FAIL fast stages (use --no-fail-fast to run the rest anyway)\n")
	else
		-- Phase 2: specs shard themselves; scenarios, build and smoke share the
		-- remaining slots. Specs go first so their long tail starts immediately.
		local scenarios = M.nativeScenarios(opts.pack, registry)
		report.scenarioCount = #scenarios
		local specsJobs = math.max(1, opts.jobs - 1)
		local jobs: { pool.Job } = {
			{ name = "specs", steps = { { "specs-run", "--quiet", "--jobs", tostring(specsJobs) } } },
			{ name = "build-all", steps = { { "build", "--all" } } },
			{ name = "smoke", steps = { { "smoke", "--pack", opts.pack, "--local" } } },
		}
		for _, ref in scenarios do
			local journal = journals .. "/" .. string.gsub(ref, ":", ".") .. ".json"
			table.insert(jobs, {
				name = "qa " .. ref,
				steps = {
					{ "qa", "run", "--pack", opts.pack, "--scenario", ref, "--record", journal },
					{ "replay", journal, "--json" },
				},
			})
		end
		-- One slot runs specs (which fans out internally); a few more run the
		-- short jobs so they finish inside the specs' wall time.
		pool.run(jobs, 4, record)
	end

	local after, afterErr = treeguard.fingerprint()
	local changed: { string } = {}
	if after == nil then
		table.insert(changed, "fingerprint failed: " .. tostring(afterErr))
	elseif after.digest ~= before.digest then
		changed = treeguard.diff(before, after :: treeguard.Fingerprint)
	end
	local valid = #changed == 0
	local ok = valid and #failed == 0
	report.ok = ok
	report.valid = valid
	report.treeChanged = changed
	report.failed = failed
	report.durationMs = math.floor((os.clock() - started) * 1000)
	table.sort(entries, function(a, b)
		return a.name < b.name
	end)
	report.jobs = entries
	if opts.json then
		local encoded = serde.encode("json", report, true)
		encoded = string.gsub(encoded, '"failed":(%s*){}', '"failed":%1[]')
		encoded = string.gsub(encoded, '"treeChanged":(%s*){}', '"treeChanged":%1[]')
		fs.writeFile(opts.json :: string, encoded)
	end
	if not valid then
		stdio.write(
			"gate: INVALID TREE_CHANGED during the run; rerun on a quiet tree:\n  "
				.. table.concat(changed, "\n  ")
				.. "\n"
		)
	end
	stdio.write(
		string.format(
			"gate: %s (%d jobs, %d failed, %.1f s)%s\n",
			if ok then "PASS" elseif valid then "FAIL" else "INVALID",
			#entries,
			#failed,
			report.durationMs / 1000,
			if #failed > 0 then " failed=" .. table.concat(failed, ",") else ""
		)
	)
	return ok
end

return M
