--!strict
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local runtimeOk, runtimeError = require("./forge/lib/run").preflight({})
if not runtimeOk then
	stdio.ewrite(tostring(runtimeError) .. "\n")
	process.exit(1)
end

local checkCommand = require("./forge/commands/check")
local buildCommand = require("./forge/commands/build")
local codegenCommand = require("./forge/commands/codegen")
local newCommand = require("./forge/commands/new")
local genCommand = require("./forge/commands/gen")
local assetsCommand = require("./forge/commands/assets")
local deployCommand = require("./forge/commands/deploy")
local localeCommand = require("./forge/commands/locale")
local trendsCommand = require("./forge/commands/trends")
local reportCommand = require("./forge/commands/report")
local liveopsCommand = require("./forge/commands/liveops")
local econCommand = require("./forge/commands/econ")
local qaCommand = require("./forge/commands/qa")
local qualityCommand = require("./forge/commands/quality")
local sweepCommand = require("./forge/commands/sweep")
local specCommand = require("./forge/commands/spec")
local contentCommand = require("./forge/commands/content")
local smokeCommand = require("./forge/commands/smoke")
local planCommand = require("./forge/commands/plan")
local imagediffCommand = require("./forge/commands/imagediff")
local replayCommand = require("./forge/commands/replay")
local provenanceCommand = require("./forge/commands/provenance")
local spikeCommand = require("./forge/commands/spike")
local inspector = require("./forge/lib/inspect")
local specsRunner = require("./forge/lib/specs")

-- One usage entry per command form; the full usage and `<command> --help`
-- are both rendered from this table so they cannot drift apart.
local USAGE_ENTRIES: { { name: string, text: string } } = {
	{
		name = "check",
		text = [=[
  check [--pack <slug> | --project <path> | --all] [--packs-root <dir>]
        [--only <stage[,stage]>] [--skip <stage[,stage]>] [--json <path>]
                            Run full linting, formatting, type checking, econ drift, specs,
                            and then build and inspect every eligible game pack. Each target
                            is reported independently: one failing pack never hides another,
                            and a failed build is never inspected
                            --only/--skip select stages (genre-contract, qa-schema, selene,
                            stylua, luau-lsp, econ, game, assets, locale, provenance, lock,
                            specs, build);
                            --json writes a schemaVersion 1 stage summary]=],
	},
	{
		name = "codegen",
		text = [=[
  codegen [<pack>]          Regenerate games/<pack>/src/shared/EconConfig.luau from econ.yml (default: kaiju-egg-raiders)
  codegen <pack> --durable  Regenerate a crafting pack's src/shared/GenreDurable.luau from the survival-coop Contract]=],
	},
	{
		name = "new",
		text = [=[
  new <slug> --genre <g1,g2>  Scaffold games/<slug>/ from genre templates and run codegen]=],
	},
	{
		name = "plan",
		text = [=[
  plan --concept "<text>" --genre <g> --pack <slug> [--seed N]
                            Generate a full game pack (game.yml, econ.yml, monetization,
                            design docs, playable src) from a concept, with no LLM or
                            API calls: the same concept + seed always writes the same bytes]=],
	},
	{
		name = "gen",
		text = [=[
  gen <image|mesh|sfx> --key <assetKey> --prompt "<text>" [--pack <slug>] [--dry-run]
                            Generate one asset through its licensed provider (image via
                            studio-mcp, mesh via trellis, sfx via elevenlabs) and upsert it
                            into assets/manifest.yml as NotUploaded]=],
	},
	{
		name = "gen",
		text = [=[
  gen procedural [--pack <slug>] [--obj] [--preview] [--author <who> --created <date>]
                            Generate the pack's procedural creature/prop meshes with the pure
                            core generators (no API keys), write src/shared/ProcAssets.luau,
                            and upsert each key into assets/manifest.yml. --preview renders
                            front/side PPMs plus sheet.ppm under assets/preview/ with the
                            framework's own z-buffer rasterizer. --author (human:<handle> or
                            agent:<model>/<run>) with --created (YYYY-MM-DD) stamps each entry]=],
	},
	{
		name = "gen",
		text = [=[
  gen icons [--pack <slug>]
                            Render a 128x128 .ppm icon preview for every creature and egg in
                            assets/procgen.yml into assets/icons/ and refresh one forge-procgen
                            manifest entry per icon (pure Pixels/Icons, no API keys)]=],
	},
	{
		name = "gen",
		text = [=[
  gen launchart [--pack <slug>]
                            Render two 512x512 icons and two 1920x1080 thumbnails from the
                            pack's procedural meshes into assets/icon and assets/thumbnails as
                            deterministic PNGs, and upsert them as forge-procgen/Approved]=],
	},
	{
		name = "gen",
		text = [=[
  gen audio [--pack <slug>] [--install] [--author <who> --created <date>]
                            Synthesise the pack's assets/audio.yml cues (music/sfx/ambience)
                            with the pure core DSP/composer into assets/audio/<cue>.wav as
                            deterministic 16-bit PCM, and upsert them as forge-procgen/Approved.
                            --install copies them into the newest Studio content/forge/<pack>/
                            so rbxasset://forge/<pack>/<cue>.wav resolves. --author/--created
                            stamp each entry's provenance as for gen procedural]=],
	},
	{
		name = "gen",
		text = [=[
  gen fulfill <requestFile> --key <assetKey> [--asset-id <n>]
                            Append a fulfilled request to the pack's assets/manifest.yml]=],
	},
	{
		name = "assets",
		text = [=[
  assets check [--pack <slug>] [--env staging|production] [--manifest <path>]
                            Gate a pack's assets/manifest.yml against license and moderation rules]=],
	},
	{
		name = "assets",
		text = [=[
  assets codegen [--pack <slug>]
                            Write src/shared/Assets.luau and asphalt.toml from assets/manifest.yml]=],
	},
	{
		name = "assets",
		text = [=[
  assets status [--pack <slug>]
                            Refresh moderation for uploaded assets via the Open Cloud Assets API]=],
	},
	{
		name = "assets",
		text = [=[
  assets upload-images [--pack <slug> | --pack-dir <dir>] [--creator-group <id> | --creator-user <id>] [--cache <path>]
                       [--limit <n>] [--only <key1,key2,...>] [--dry-run]
                            Publish PNG icons as Decals, resolve image content ids, and checkpoint
                            operations in build/image-upload-cache.json. --limit <n> uploads at most n
                            not-yet-uploaded images in manifest order, then stops and reports how many
                            remain; --only restricts the run to the listed image keys. Assets.luau is
                            always regenerated from the full manifest. An invalid --limit (0, negative,
                            non-integer) exits 2. Dry run prints the planned batch and never uploads.
  assets upload-audio [--pack <slug> | --pack-dir <dir>] [--creator-group <id> | --creator-user <id>] [--cache <path>] [--dry-run]
                            Publish a pack's synthesised WAV cues (sfx/bgm) through the Open Cloud
                            Assets API, poll each operation, and record the returned rbxassetid plus
                            moderation state in assets/manifest.yml. Idempotent by artifact sha256 via
                            build/audio-upload-cache.json. Pending moderation is reported, never
                            treated as playable]=],
	},
	{
		name = "deploy",
		text = [=[
  deploy --env <staging|production> [--pack <slug>] [--dry-run] [--development]
                            Build the place with rojo and publish it via Roblox Open Cloud
                            (--dry-run: offline product/asset plan, no API key, no network)]=],
	},
	{
		name = "deploy",
		text = [=[
  deploy plan --env <staging|production> [--pack <slug>] [--out <path>] [--development]
                            Offline plan; --out writes JSON. Declared release-candidates
                            require a current authorized receipt for build/<pack>.rbxl.
                            --development is staging-only and never release approval;
                            it cannot bypass a release-candidate claim. Legacy packs
                            without quality.yml remain explicitly unassessed]=],
	},
	{
		name = "locale",
		text = [=[
  locale check [--pack <slug>]
                            Verify locale/strings.csv covers every client literal and has no empty ko-kr]=],
	},
	{
		name = "locale",
		text = [=[
  locale sync [--pack <slug>] [--dry-run]
                            Build the Localization Tables payload from strings.csv and write
                            reports/locale-sync-<pack>.json (offline)]=],
	},
	{
		name = "trends",
		text = [=[
  trends [--fixture <path>] [--out <path>]
                            Collect top experiences per genre and write reports/trends-<YYYY-MM-DD>.md]=],
	},
	{
		name = "report",
		text = [=[
  report [--pack <slug>] [--events <path>] [--out <path>]
                            Write a weekly liveops report to reports/<pack>-weekly-<YYYY-MM-DD>.md]=],
	},
	{
		name = "report",
		text = [=[
  report --all [--out <path>]
                            Write reports/dashboard-<YYYY-MM-DD>.md summarizing every pack]=],
	},
	{
		name = "liveops",
		text = [=[
  liveops push --pack <slug> --event <id> [--dry-run]
                            Publish a pack's liveops.yml event to its staging universe via Open Cloud
                            (--dry-run: print the POST target and body; no API key, no network)]=],
	},
	{
		name = "econ",
		text = [=[
  econ sim [--pack <slug>] [--players N] [--days D] [--seed S] [--out <path>] [--json <path>]
                            Simulate a pack's free-currency economy and write reports/econ-sim-<pack>.md
                            (--json also writes a schemaVersion 1 machine-readable result)]=],
	},
	{
		name = "spike",
		text = [=[
  spike [--players N] [--seed S] [--out <path>]
                            QA-SPIKE-01 layer 1: simulate N (default 64) seeded arrivals through
                            the island Allocation, queue and lease-fenced rosters on a simulated
                            clock; write the JSON report (default .omo/evidence/robango/spike-64.json)
                            and exit 1 if p95 wait > target, anyone is lost, an island is
                            overfull, or a player message leaks internal text]=],
	},
	{
		name = "qa",
		text = [=[
  qa plan [--pack <slug>]
                            Write reports/qa-plan-<pack>.md from the pack's genre qa-scenarios]=],
	},
	{
		name = "qa",
		text = [=[
  qa validate               Validate every genres/*/qa-scenarios/*.yml scenario file]=],
	},
	{
		name = "spec",
		text = [=[
  spec init --genre <id> [--concept "<text>"] [--pack <slug>] [--force]
                            Write a draft genres/<id>/genre-spec.yml seeded from the
                            genre's econ-template.yml and design-template.md. The draft
                            is a valid but incomplete binding document: an agent fills it
                            in and then removes `draft: true`]=],
	},
	{
		name = "spec",
		text = [=[
  spec validate [--genre <id>]
                            Report every declarative genre-spec violation as
                            `file: reason`. A spec that fails any rule fails genre
                            discovery, so every other command refuses to run against it]=],
	},
	{
		name = "qa",
		text = [=[
  qa run --pack <slug> --scenario <name> [--native|--studio] [--evidence <path>]
         [--record <journal.json>]
                            Execute one declarative QA scenario against the pack's real
                            Session/Executor/genre adapters with an explicit clock and
                            injectable commit barriers (--native, the default), or through
                            a connected Studio client (--studio). A missing scenario, a
                            scenario that asserts nothing, and an unreachable Studio client
                            are all FAIL: --studio never falls back to a headless run
                            --record writes the native run's command journal for `replay`]=],
	},
	{
		name = "content",
		text = [=[
  content check --file <path> | --pack <slug>
                            Validate a versioned survival content catalog (items, recipes,
                            nodes, structures, wildlife) and print every violation with its
                            field path. Catalog refs, caps, cycles and fixed-point
                            quantities are checked before anything is written]=],
	},
	{
		name = "content",
		text = [=[
  content codegen --pack <slug>
                            Write games/<pack>/src/shared/SurvivalContent.luau from the
                            pack's content.yml. Deterministic: identical input always
                            produces byte-identical output. Refuses econ.yml content drift.
  content sync-econ --pack <slug>
                            Rewrite only embedded survival-coop inventory content in econ.yml
                            from the canonical content.yml v1 projection]=],
	},
	{
		name = "provenance",
		text = [=[
  provenance check --pack <slug> [--packs-root <dir>] [--json <path>]
                            Gate an opted-in pack (provenance/policy.yml): banned names, stems,
                            single-letter speakers, hashed proper names, reference 8-gram
                            fingerprints, sidecar provenance coverage and asset tools.
                            Matches are reported by index or hash, never in plain text]=],
	},
	{
		name = "provenance",
		text = [=[
  provenance fingerprint --corpus <dir> --set <id> --out <dir>
  provenance fingerprint --names <file> --salt <salt>
                            Hash a reference corpus into <id>.fp + <id>.meta.yml (sorted
                            12-hex sha256-48 hashes only), or hash a reviewed proper-name list
                            into banned-names hashedNames entries]=],
	},
	{
		name = "quality",
		text = [=[
  quality validate [--file <path>] [--pack <slug>]
                            Validate one quality profile document (tier, reference package,
                            anchored rubric, first-play goals) and print every schema
                            violation with its field path. Schema only: a profile that
                            passes is a well-formed claim, never an approval, and any
                            self-declared verdict fails]=],
	},
	{
		name = "quality",
		text = [=[
  quality evaluate --pack <slug> --capture <dir> --reference <path> --out <path>
                            Invoke the configured evaluator on bound first-play evidence;
                            missing evaluator or inconclusive evidence cannot approve]=],
	},
	{
		name = "quality",
		text = [=[
  quality check --pack <slug> [--target starter|vertical-slice|release-candidate]
                [--receipt <path>] [--packs-root <dir>]
                            Check the declared tier (a target may not downgrade it).
                            Starter passes without approval; higher tiers require a
                            current digest-bound receipt and FORGE_QUALITY_EVALUATOR /
                            FORGE_QUALITY_ATTESTATION. No build silently upgrades a tier]=],
	},
	{
		name = "smoke",
		text = [=[
  smoke [--pack <slug>] [--local] [--cloud] [--fixture <save.json>] [--dry-run] [--strict]
                            Run a pack's local Lune smoke checks, or post and poll an
                            Open Cloud Luau Execution smoke task for the staging place
                            (--strict with --local fails a pack that has no smoke script)]=],
	},
	{
		name = "sweep",
		text = [=[
  sweep [--genres a,b,...] [--out <dir>] [--stamp <text>]
                            Baseline playability sweep: generate a fresh pack for every
                            registered genre (plus survival-coop in --mode crafting) into a
                            scratch packs root outside games/, then record generation, expected
                            files, rojo build, built-place inspection, headless native QA, and a
                            static playability-surface probe for each - independently, so one
                            failing genre never stops another. Writes sweep.json and sweep.md to
                            --out (default build/sweep/<stamp>/)
                            --stamp overrides the wall-clock stamp that names the output
                            directory (sweep.json still records per-step durationMs)]=],
	},
	{
		name = "build",
		text = [=[
  build [--all | --pack <slug> | --project <path>] [--packs-root <dir>]
                            Build game places with rojo into build/<target>.rbxl. With no
                            selector the default pack is built; --all builds every discovered
                            pack, --pack builds one, and --project builds one project file.
                            Selectors are mutually exclusive]=],
	},
	{
		name = "test",
		text = [=[
  test [filters...] [--quiet] [--slowest N] [--json <path>]
                            Run every *.spec.luau (sorted) whose path or "path :: test" contains
                            any filter. --quiet prints only FAIL lines and the summary,
                            --slowest N lists the N slowest tests, --json writes a schemaVersion 1
                            report. Exit 0 when all pass, 1 on any failure or zero matches]=],
	},
	{
		name = "replay",
		text = [=[
  replay <journal.json> [--packs-root <dir>] [--json]
                            Re-run a journal recorded by `qa run --record` against a fresh Session
                            and compare state hashes: exit 0 MATCH, 1 MISMATCH, 2 decode error]=],
	},
	{
		name = "imagediff",
		text = [=[
  imagediff <base.png> <compare.png> [--diff <out.png>] [--threshold n]
            [--ignore x1:y1-x2:y2[,..]] [--crop x:y:w:h] [--json]
                            Compare two PNGs pixel by pixel: exit 0 identical, 1 different,
                            2 usage or decode error]=],
	},
	{
		name = "help",
		text = [=[
  help [<command>]          Print this usage (or one command's section); also --help, -h,
                            and <command> --help]=],
	},
	{
		name = "inspect",
		text = [=[
  inspect <path.rbxl>       (internal) Inspect a built .rbxl place file directly]=],
	},
}

local USAGE_HEADER = "Usage: lune run cli/forge <command>\n\nCommands:\n"

local function fullUsage(): string
	local parts: { string } = {}
	for _, entry in USAGE_ENTRIES do
		table.insert(parts, entry.text)
	end
	return USAGE_HEADER .. table.concat(parts, "\n") .. "\n"
end

-- Every entry for one command (gen has several forms), or nil if unknown.
local function commandUsage(name: string): string?
	local parts: { string } = {}
	for _, entry in USAGE_ENTRIES do
		if entry.name == name then
			table.insert(parts, entry.text)
		end
	end
	if #parts == 0 then
		return nil
	end
	return "Usage: lune run cli/forge " .. name .. "\n\n" .. table.concat(parts, "\n") .. "\n"
end

local function isHelpFlag(arg: string?): boolean
	return arg == "--help" or arg == "-h"
end

-- Parses `test`/`specs-run` argv (after the command name) into specs.run options.
local function parseSpecsArgs(args: { string }): (specsRunner.RunOptions?, string?)
	local filters: { string } = {}
	local options: specsRunner.RunOptions = { filters = filters }
	local index = 2
	while index <= #args do
		local arg = args[index]
		if arg == "--quiet" then
			options.quiet = true
		elseif arg == "--slowest" then
			local count = tonumber(args[index + 1])
			if count == nil or count < 1 or count ~= math.floor(count) then
				return nil, "--slowest requires a positive integer"
			end
			options.slowest = count
			index += 1
		elseif arg == "--json" then
			local path = args[index + 1]
			if path == nil or path == "" or string.sub(path, 1, 2) == "--" then
				return nil, "--json requires a path"
			end
			options.json = path
			index += 1
		elseif string.sub(arg, 1, 2) == "--" then
			return nil, "unknown flag " .. arg
		else
			table.insert(filters, arg)
		end
		index += 1
	end
	return options, nil
end

local function main()
	local args = process.args
	if #args == 0 then
		stdio.ewrite(fullUsage())
		process.exit(2)
	end

	local cmd = args[1]
	if cmd == "help" or isHelpFlag(cmd) then
		local topic = if cmd == "help" then args[2] else nil
		if topic == nil then
			stdio.write(fullUsage())
			process.exit(0)
		end
		local section = commandUsage(topic)
		if section == nil then
			stdio.ewrite(string.format("Unknown command: '%s'\n\n", topic) .. fullUsage())
			process.exit(2)
			return
		end
		stdio.write(section)
		process.exit(0)
	end
	-- `assets <sub> --help` also prints the assets section.
	local helpRequested = isHelpFlag(args[2]) or (args[1] == "assets" and isHelpFlag(args[3]))
	if helpRequested then
		-- `specs-run` is the hidden alias of `test` and shares its usage.
		local section = commandUsage(if cmd == "specs-run" then "test" else cmd)
		if section ~= nil then
			stdio.write(section)
			process.exit(0)
		end
	end

	if cmd == "check" then
		local ok = checkCommand.run(args)
		if not ok then
			process.exit(1)
		end
	elseif cmd == "codegen" then
		if not codegenCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "new" then
		if not newCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "plan" then
		if not planCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "gen" then
		if not genCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "assets" then
		local ok, code = assetsCommand.run(args)
		if not ok then
			process.exit(code or 1)
		end
	elseif cmd == "deploy" then
		if not deployCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "locale" then
		if not localeCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "trends" then
		if not trendsCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "report" then
		if not reportCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "liveops" then
		if not liveopsCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "econ" then
		if not econCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "spike" then
		if not spikeCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "qa" then
		if not qaCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "quality" then
		if not qualityCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "sweep" then
		if not sweepCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "spec" then
		if not specCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "content" then
		if not contentCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "provenance" then
		if not provenanceCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "smoke" then
		if not smokeCommand.run(args) then
			process.exit(1)
		end
	elseif cmd == "build" then
		local res = buildCommand.run(args)
		if res.output ~= "" then
			stdio.write(res.output .. "\n")
		end
		if not res.ok then
			process.exit(1)
		end
	elseif cmd == "test" or cmd == "specs-run" then
		-- `specs-run` is the hidden alias the check command uses so specs run in
		-- their own process; both accept the same filters and flags.
		local options, parseErr = parseSpecsArgs(args)
		if options == nil then
			stdio.ewrite("Error: " .. tostring(parseErr) .. "\n\n" .. (commandUsage("test") or ""))
			process.exit(2)
			return
		end
		local specsOk, specsOut = specsRunner.run(options)
		stdio.write(specsOut .. "\n")
		-- Every test has run, so the verdict is final and Lune must not linger. Measured
		-- 196s of work followed by an unbounded stay-alive with no child process left,
		-- because a spec leaves a suspended thread or timer behind; on the success path
		-- that silence used to wedge `forge check` with no specs output at all.
		process.exit(if specsOk then 0 else 1)
	elseif cmd == "imagediff" then
		process.exit(imagediffCommand.run(args))
	elseif cmd == "replay" then
		process.exit(replayCommand.run(args))
	elseif cmd == "inspect" then
		local rbxlPath = args[2]
		if not rbxlPath or rbxlPath == "" then
			stdio.ewrite("Error: inspect requires a path to an .rbxl place file\n")
			process.exit(1)
		end
		local expected = nil
		if args[3] == "--project" and args[4] then
			local fs = require("@lune/fs")
			local serde = require("@lune/serde")
			local project = serde.decode("json", fs.readFile(args[4]))
			expected = {}
			local function collect(node: any, path: string)
				if type(node) ~= "table" then
					return
				end
				if node["$path"] and string.match(node["$path"], "%.luau$") then
					local class = if string.match(node["$path"], "%.server%.luau$")
						then "Script"
						elseif string.match(node["$path"], "%.client%.luau$") then "LocalScript"
						else "ModuleScript"
					table.insert(expected, { path = path, expected = class })
				end
				for name, child in node do
					if type(name) == "string" and string.sub(name, 1, 1) ~= "$" then
						collect(child, if path == "" then name else path .. "." .. name)
					end
				end
			end
			collect(project.tree, "")
			assert(#expected > 0, "project declares no script entrypoints")
		elseif args[3] ~= nil then
			error("usage: inspect <place.rbxl> [--project <project.json>]")
		end
		local res = inspector.inspectPlaceFile(rbxlPath, expected)
		if res.ok then
			stdio.write(string.format("inspect: PASS (%d requires resolved)\n", res.resolvedRequiresCount))
		else
			stdio.ewrite("inspect: FAIL\n")
			for _, err in res.errors do
				stdio.ewrite("ERROR: " .. err .. "\n")
			end
			process.exit(1)
		end
	else
		stdio.ewrite(string.format("Unknown command: '%s'\n\n", cmd) .. fullUsage())
		process.exit(2)
	end
end

main()
