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
local inspector = require("./forge/lib/inspect")
local specsRunner = require("./forge/lib/specs")

local function printUsage()
	stdio.ewrite([[Usage: lune run cli/forge <command>

Commands:
  check [--pack <slug> | --project <path> | --all] [--packs-root <dir>]
                            Run full linting, formatting, type checking, econ drift, specs,
                            and then build and inspect every eligible game pack. Each target
                            is reported independently: one failing pack never hides another,
                            and a failed build is never inspected
  codegen [<pack>]          Regenerate games/<pack>/src/shared/EconConfig.luau from econ.yml (default: kaiju-egg-raiders)
  new <slug> --genre <g1,g2>  Scaffold games/<slug>/ from genre templates and run codegen
  plan --concept "<text>" --genre <g> --pack <slug> [--seed N]
                            Generate a full game pack (game.yml, econ.yml, monetization,
                            design docs, playable src) from a concept, with no LLM or
                            API calls: the same concept + seed always writes the same bytes
  gen <image|mesh|sfx> --key <assetKey> --prompt "<text>" [--pack <slug>] [--dry-run]
                            Generate one asset through its licensed provider (image via
                            studio-mcp, mesh via trellis, sfx via elevenlabs) and upsert it
                            into assets/manifest.yml as NotUploaded
  gen procedural [--pack <slug>] [--obj] [--preview]
                            Generate the pack's procedural creature/prop meshes with the pure
                            core generators (no API keys), write src/shared/ProcAssets.luau,
                            and upsert each key into assets/manifest.yml. --preview renders
                            front/side PPMs plus sheet.ppm under assets/preview/ with the
                            framework's own z-buffer rasterizer
  gen icons [--pack <slug>]
                            Render a 128x128 .ppm icon preview for every creature and egg in
                            assets/procgen.yml into assets/icons/ and refresh one forge-procgen
                            manifest entry per icon (pure Pixels/Icons, no API keys)
  gen launchart [--pack <slug>]
                            Render two 512x512 icons and two 1920x1080 thumbnails from the
                            pack's procedural meshes into assets/icon and assets/thumbnails as
                            deterministic PNGs, and upsert them as forge-procgen/Approved
  gen audio [--pack <slug>] [--install]
                            Synthesise the pack's assets/audio.yml cues (music/sfx/ambience)
                            with the pure core DSP/composer into assets/audio/<cue>.wav as
                            deterministic 16-bit PCM, and upsert them as forge-procgen/Approved.
                            --install copies them into the newest Studio content/forge/<pack>/
                            so rbxasset://forge/<pack>/<cue>.wav resolves
  gen fulfill <requestFile> --key <assetKey> [--asset-id <n>]
                            Append a fulfilled request to the pack's assets/manifest.yml
  assets check [--pack <slug>] [--env staging|production] [--manifest <path>]
                            Gate a pack's assets/manifest.yml against license and moderation rules
  assets codegen [--pack <slug>]
                            Write src/shared/Assets.luau and asphalt.toml from assets/manifest.yml
  assets status [--pack <slug>]
                            Refresh moderation for uploaded assets via the Open Cloud Assets API
  assets upload-audio [--pack <slug> | --pack-dir <dir>] [--creator-group <id>] [--cache <path>] [--dry-run]
                            Publish a pack's synthesised WAV cues (sfx/bgm) through the Open Cloud
                            Assets API, poll each operation, and record the returned rbxassetid plus
                            moderation state in assets/manifest.yml. Idempotent by artifact sha256 via
                            build/audio-upload-cache.json. Pending moderation is reported, never
                            treated as playable
  deploy --env <staging|production> [--pack <slug>] [--dry-run] [--development]
                            Build the place with rojo and publish it via Roblox Open Cloud
                            (--dry-run: offline product/asset plan, no API key, no network)
  deploy plan --env <staging|production> [--pack <slug>] [--out <path>] [--development]
                            Offline plan; --out writes JSON. Declared release-candidates
                            require a current authorized receipt for build/<pack>.rbxl.
                            --development is staging-only and never release approval;
                            it cannot bypass a release-candidate claim. Legacy packs
                            without quality.yml remain explicitly unassessed
  locale check [--pack <slug>]
                            Verify locale/strings.csv covers every client literal and has no empty ko-kr
  locale sync [--pack <slug>] [--dry-run]
                            Build the Localization Tables payload from strings.csv and write
                            reports/locale-sync-<pack>.json (offline)
  trends [--fixture <path>] [--out <path>]
                            Collect top experiences per genre and write reports/trends-<YYYY-MM-DD>.md
  report [--pack <slug>] [--events <path>] [--out <path>]
                            Write a weekly liveops report to reports/<pack>-weekly-<YYYY-MM-DD>.md
  report --all [--out <path>]
                            Write reports/dashboard-<YYYY-MM-DD>.md summarizing every pack
  liveops push --pack <slug> --event <id> [--dry-run]
                            Publish a pack's liveops.yml event to its staging universe via Open Cloud
                            (--dry-run: print the POST target and body; no API key, no network)
  econ sim [--pack <slug>] [--players N] [--days D] [--seed S] [--out <path>]
                            Simulate a pack's free-currency economy and write reports/econ-sim-<pack>.md
  qa plan [--pack <slug>]
                            Write reports/qa-plan-<pack>.md from the pack's genre qa-scenarios
  qa validate               Validate every genres/*/qa-scenarios/*.yml scenario file
  spec init --genre <id> [--concept "<text>"] [--pack <slug>] [--force]
                            Write a draft genres/<id>/genre-spec.yml seeded from the
                            genre's econ-template.yml and design-template.md. The draft
                            is a valid but incomplete binding document: an agent fills it
                            in and then removes `draft: true`
  spec validate [--genre <id>]
                            Report every declarative genre-spec violation as
                            `file: reason`. A spec that fails any rule fails genre
                            discovery, so every other command refuses to run against it
  qa run --pack <slug> --scenario <name> [--native|--studio] [--evidence <path>]
                            Execute one declarative QA scenario against the pack's real
                            Session/Executor/genre adapters with an explicit clock and
                            injectable commit barriers (--native, the default), or through
                            a connected Studio client (--studio). A missing scenario, a
                            scenario that asserts nothing, and an unreachable Studio client
                            are all FAIL: --studio never falls back to a headless run
  content check --file <path>
                            Validate a versioned survival content catalog (items, recipes,
                            nodes, structures, wildlife) and print every violation with its
                            field path. Catalog refs, caps, cycles and fixed-point
                            quantities are checked before anything is written
  content codegen --pack <slug>
                            Write games/<pack>/src/shared/SurvivalContent.luau from the
                            pack's content.yml. Deterministic: identical input always
                            produces byte-identical output
  quality validate [--file <path>] [--pack <slug>]
                            Validate one quality profile document (tier, reference package,
                            anchored rubric, first-play goals) and print every schema
                            violation with its field path. Schema only: a profile that
                            passes is a well-formed claim, never an approval, and any
                            self-declared verdict fails
  quality evaluate --pack <slug> --capture <dir> --reference <path> --out <path>
                            Invoke the configured evaluator on bound first-play evidence;
                            missing evaluator or inconclusive evidence cannot approve
  quality check --pack <slug> [--target starter|vertical-slice|release-candidate]
                [--receipt <path>] [--packs-root <dir>]
                            Check the declared tier (a target may not downgrade it).
                            Starter passes without approval; higher tiers require a
                            current digest-bound receipt and FORGE_QUALITY_EVALUATOR /
                            FORGE_QUALITY_ATTESTATION. No build silently upgrades a tier
  smoke [--pack <slug>] [--local] [--cloud] [--fixture <save.json>] [--dry-run]
                            Run a pack's local Lune smoke checks, or post and poll an
                            Open Cloud Luau Execution smoke task for the staging place
  sweep [--genres a,b,...] [--out <dir>]
                            Baseline playability sweep: generate a fresh pack for every
                            registered genre (plus survival-coop in --mode crafting) into a
                            scratch packs root outside games/, then record generation, expected
                            files, rojo build, built-place inspection, headless native QA, and a
                            static playability-surface probe for each - independently, so one
                            failing genre never stops another. Writes sweep.json and sweep.md to
                            --out (default build/sweep/<stamp>/)
  build [--all | --pack <slug> | --project <path>] [--packs-root <dir>]
                            Build game places with rojo into build/<target>.rbxl. With no
                            selector the default pack is built; --all builds every discovered
                            pack, --pack builds one, and --project builds one project file.
                            Selectors are mutually exclusive
  inspect <path.rbxl>       (internal) Inspect a built .rbxl place file directly
]])
end

local function main()
	local args = process.args
	if #args == 0 then
		printUsage()
		process.exit(1)
	end

	local cmd = args[1]
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
		if not assetsCommand.run(args) then
			process.exit(1)
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
	elseif cmd == "specs-run" then
		-- Hidden: used by the check command so specs run in their own process.
		local specsOk, specsOut = specsRunner.runAll()
		stdio.write(specsOut .. "\n")
		-- Every test has run, so the verdict is final and Lune must not linger. Measured
		-- 196s of work followed by an unbounded stay-alive with no child process left,
		-- because a spec leaves a suspended thread or timer behind; on the success path
		-- that silence used to wedge `forge check` with no specs output at all.
		process.exit(if specsOk then 0 else 1)
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
		stdio.ewrite(string.format("Unknown command: '%s'\n\n", cmd))
		printUsage()
		process.exit(1)
	end
end

main()
