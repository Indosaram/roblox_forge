--!strict
-- Specs for lib/buildtargets: the shared build/inspect target matrix.
--
-- The pure resolver rules are driven through an injected FsLike so selector
-- parsing and discovery can be checked without touching the disk. The matrix
-- behaviour that matters most - a malformed pack failing while its valid
-- sibling is still built, and a failed build never being inspected against a
-- stale artifact - is proven by running the *actual* `forge build` and
-- `forge check` commands over fixture packs written under build/ (gitignored,
-- removed by each spec that creates them).

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local buildtargets = require("./buildtargets")
local run = require("./run")

local FIXTURE_ROOT = "build/spec-buildtargets"

-- ---------------------------------------------------------------------------
-- Fake filesystem for the pure resolver rules
-- ---------------------------------------------------------------------------

local function fakeFs(files: { [string]: string }, dirs: { string }): buildtargets.FsLike
	local dirSet: { [string]: boolean } = {}
	for _, dir in dirs do
		dirSet[dir] = true
	end
	return {
		isDir = function(path: string): boolean
			return dirSet[path] == true
		end,
		isFile = function(path: string): boolean
			return files[path] ~= nil
		end,
		readDir = function(path: string): { string }
			local names: { string } = {}
			local seen: { [string]: boolean } = {}
			for candidate in pairs(dirSet) do
				local child = string.match(candidate, "^" .. path .. "/([^/]+)$")
				if child ~= nil and not seen[child] then
					seen[child] = true
					table.insert(names, child)
				end
			end
			for candidate in pairs(files) do
				local child = string.match(candidate, "^" .. path .. "/([^/]+)$")
				if child ~= nil and not seen[child] then
					seen[child] = true
					table.insert(names, child)
				end
			end
			table.sort(names)
			return names
		end,
		readFile = function(path: string): string
			return files[path] or error("no such file: " .. path)
		end,
	}
end

local function packsFs(): buildtargets.FsLike
	return fakeFs({
		["games/alpha/game.yml"] = "name: Alpha\n",
		["games/alpha/default.project.json"] = "{}",
		["games/beta/game.yml"] = "name: Beta\n",
		["games/beta/default.project.json"] = "{}",
		-- declared pack with no project file: partial, never silently omitted
		["games/gamma/game.yml"] = "name: Gamma\n",
		-- project with no game.yml: partial in the other direction
		["games/delta/default.project.json"] = "{}",
	}, { "games", "games/alpha", "games/beta", "games/gamma", "games/delta" })
end

--- A packs root where every pack has a valid rojo project but the game.yml
--- declarations differ in validity.
local function malformedDeclarationFs(): buildtargets.FsLike
	return fakeFs({
		["games/alpha/game.yml"] = "name: Alpha\n",
		["games/alpha/default.project.json"] = "{}",
		-- valid rojo project, game.yml that does not parse
		["games/broken-yaml/game.yml"] = "name: Broken\n\tgenres: [x\n  - : :\n",
		["games/broken-yaml/default.project.json"] = "{}",
		-- decodes, but to a scalar rather than a pack declaration
		["games/scalar/game.yml"] = "just a string\n",
		["games/scalar/default.project.json"] = "{}",
		-- decodes to a mapping with no name
		["games/nameless/game.yml"] = "genres: [collect-raid]\n",
		["games/nameless/default.project.json"] = "{}",
	}, { "games", "games/alpha", "games/broken-yaml", "games/scalar", "games/nameless" })
end

local function slugs(targets: { buildtargets.Target }): { string }
	local out: { string } = {}
	for _, target in targets do
		table.insert(out, target.slug)
	end
	return out
end

local function joined(list: { string }): string
	return table.concat(list, " | ")
end

local function hasText(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) ~= nil then
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Real fixture packs
-- ---------------------------------------------------------------------------

local function writeFile(path: string, content: string)
	local dir = string.match(path, "^(.*)/[^/]+$")
	if dir ~= nil then
		local current = ""
		for segment in string.gmatch(dir, "[^/]+") do
			current = if current == "" then segment else current .. "/" .. segment
			if not fs.isDir(current) then
				fs.writeDir(current)
			end
		end
	end
	fs.writeFile(path, content)
end

local function projectJson(name: string, serverPath: string, sharedPath: string): string
	return serde.encode("json", {
		name = name,
		globIgnorePaths = { "**/*.spec.luau" },
		tree = {
			["$className"] = "DataModel",
			ReplicatedStorage = {
				Remotes = {
					["$className"] = "Folder",
					Ping = { ["$className"] = "RemoteEvent" },
				},
				Shared = { ["$path"] = sharedPath },
			},
			ServerScriptService = {
				Main = { ["$path"] = serverPath },
			},
		},
	}, true) .. "\n"
end

--- Writes a pack directory whose place builds and inspects cleanly. The
--- shared folder holds two sibling modules so the inspection actually has a
--- require to resolve.
local function writeValidPack(dir: string, name: string)
	writeFile(dir .. "/game.yml", "name: " .. name .. "\nslug: " .. name .. "\n")
	writeFile(dir .. "/default.project.json", projectJson(name, "src/Main.server.luau", "src/shared"))
	writeFile(dir .. "/src/shared/Helper.luau", "--!strict\nreturn { ok = true }\n")
	writeFile(dir .. "/src/shared/Entry.luau", '--!strict\nlocal helper = require("./Helper")\nreturn helper\n')
	writeFile(dir .. "/src/Main.server.luau", "--!strict\nlocal _ = 1\n")
end

--- Writes a pack whose place builds but whose shared module requires a sibling
--- that is not in the tree: the build succeeds, inspection must fail.
local function writeMissingRequirePack(dir: string, name: string)
	writeValidPack(dir, name)
	writeFile(dir .. "/src/shared/Entry.luau", '--!strict\nlocal _ = require("./NotThere")\nreturn true\n')
end

--- Writes a pack whose rojo project points at a path that does not exist: the
--- build itself fails, so nothing may be inspected.
local function writeUnbuildablePack(dir: string, name: string)
	writeValidPack(dir, name)
	writeFile(dir .. "/default.project.json", projectJson(name, "src/Missing.server.luau", "src/shared"))
end

local function removeFixture(dir: string)
	if fs.isDir(dir) then
		fs.removeDir(dir)
	end
end

local function forge(args: { string }): (boolean, string)
	local argv = { "run", "cli/forge" }
	for _, arg in args do
		table.insert(argv, arg)
	end
	local res = run.exec("lune", argv)
	local output = res.stdout
	if res.stderr ~= "" then
		output = output .. "\n" .. res.stderr
	end
	return res.ok, output
end

return {
	["pending publication blocks discovery and explicit project resolution"] = function()
		for _, marker in { ".forge-stage", ".forge-backup" } do
			local io = fakeFs({
				["games/alpha/game.yml"] = "name: Alpha\n",
				["games/alpha/default.project.json"] = "{}",
				["games/alpha" .. marker] = "untrusted marker",
			}, { "games", "games/alpha" })
			local targets, errors = buildtargets.discover("games", io)
			assert(
				#targets == 0 and hasText(errors, "FORGE_PUBLICATION_PENDING"),
				'#targets == 0 and hasText(errors, "FORGE_PUBLICATION_PENDING")'
			)
			local selection = buildtargets.parseSelectors({ "--project", "games/alpha/default.project.json" })
			local explicit, reasons = buildtargets.resolveTargets(selection :: buildtargets.Selection, "single", io)
			assert(
				#explicit == 0 and hasText(reasons, "FORGE_PUBLICATION_PENDING"),
				'#explicit == 0 and hasText(reasons, "FORGE_PUBLICATION_PENDING")'
			)
		end
	end,
	["direct target pending publication leaves prior artifact untouched before tools"] = function()
		local dir = FIXTURE_ROOT .. "/publication"
		assert(not fs.isDir(dir) and not fs.isDir(dir .. ".forge-stage"), "owned fixture already exists")
		writeFile(dir .. "/prior.rbxl", "prior artifact")
		fs.writeDir(dir .. ".forge-stage")
		local ok, err = pcall(function()
			local result = buildtargets.runTarget({
				kind = "project",
				slug = "publication",
				projectPath = dir .. "/default.project.json",
				outputPath = dir .. "/prior.rbxl",
			})
			assert(
				not result.built and not result.ok and result.revision == "unknown",
				'not result.built and not result.ok and result.revision == "unknown"'
			)
			assert(hasText(result.errors, "FORGE_PUBLICATION_PENDING"))
			assert(
				fs.readFile(dir .. "/prior.rbxl") == "prior artifact",
				'fs.readFile(dir .. "/prior.rbxl") == "prior artifact"'
			)
		end)
		fs.removeDir(dir .. ".forge-stage")
		removeFixture(dir)
		assert(ok, tostring(err))
	end,
	-- selectors --------------------------------------------------------------
	["no selector resolves the default mode"] = function()
		local selection, err = buildtargets.parseSelectors({ "build" }, 2)
		assert(selection ~= nil, tostring(err))
		assert((selection :: buildtargets.Selection).mode == "default", "no selector stays default")
		assert(
			(selection :: buildtargets.Selection).packsRoot == buildtargets.DEFAULT_PACKS_ROOT,
			"the default packs root is games"
		)
	end,

	["--pack, --all and --project each select their own mode"] = function()
		local all = buildtargets.parseSelectors({ "build", "--all" }, 2)
		assert(all ~= nil and (all :: buildtargets.Selection).mode == "all", "--all selects every pack")

		local pack = buildtargets.parseSelectors({ "build", "--pack", "kaiju-egg-raiders" }, 2)
		assert(pack ~= nil, "--pack <slug> parses")
		assert((pack :: buildtargets.Selection).pack == "kaiju-egg-raiders", "the slug is kept")

		local project = buildtargets.parseSelectors({ "build", "--project", "a/b/default.project.json" }, 2)
		assert(project ~= nil, "--project <path> parses")
		assert(
			(project :: buildtargets.Selection).projectPath == "a/b/default.project.json",
			"the project path is kept"
		)
	end,

	["two target selectors at once are rejected"] = function()
		for _, argv in
			{
				{ "build", "--all", "--pack", "kaiju-egg-raiders" },
				{ "build", "--pack", "kaiju-egg-raiders", "--project", "a/default.project.json" },
				{ "build", "--project", "a/default.project.json", "--all" },
			}
		do
			local selection, err = buildtargets.parseSelectors(argv, 2)
			assert(selection == nil, "mutually exclusive selectors must fail: " .. table.concat(argv, " "))
			assert(err ~= nil and string.find(err :: string, "duplicate", 1, true) ~= nil, "the error names the clash")
		end
	end,

	["malformed selector values are rejected"] = function()
		local cases: { { argv: { string }, needle: string } } = {
			{ argv = { "build", "--pack" }, needle = "requires a value" },
			{ argv = { "build", "--pack", "Not A Slug" }, needle = "invalid pack slug" },
			{ argv = { "build", "--project", "games/alpha" }, needle = "*.project.json" },
			{ argv = { "build", "--packs-root" }, needle = "requires a value" },
			{ argv = { "build", "--wat" }, needle = "unknown option" },
			{
				argv = { "build", "--project", "a/default.project.json", "--packs-root", "x" },
				needle = "--packs-root cannot be combined",
			},
		}
		for _, case in cases do
			local selection, err = buildtargets.parseSelectors(case.argv, 2)
			assert(selection == nil, "must reject: " .. table.concat(case.argv, " "))
			assert(
				err ~= nil and string.find(err :: string, case.needle, 1, true) ~= nil,
				"error names the problem, got: " .. tostring(err)
			)
		end
	end,

	-- discovery --------------------------------------------------------------
	["discovery reports partial packs instead of omitting them"] = function()
		local targets, errors = buildtargets.discover("games", packsFs())
		assert(joined(slugs(targets)) == "alpha | beta", "both complete packs are discovered")
		assert(#errors == 2, "both partial packs are reported: " .. joined(errors))
		assert(hasText(errors, "games/gamma"), "a pack with no project file is an error")
		assert(hasText(errors, "games/delta"), "a project with no game.yml is an error")
	end,

	["default check resolves every declared pack, default build resolves one"] = function()
		local io = packsFs()
		local selection = buildtargets.parseSelectors({ "check" }, 2) :: buildtargets.Selection

		local allTargets, allErrors = buildtargets.resolveTargets(selection, "all", io)
		assert(joined(slugs(allTargets)) == "alpha | beta", "check builds every declared pack")
		assert(#allErrors == 2, "partial packs still fail the run: " .. joined(allErrors))

		local defaultTargets = buildtargets.resolveTargets(selection, "single", io)
		assert(#defaultTargets == 0, "the default build pack is absent from this fixture root")

		local alpha = buildtargets.resolveTargets(
			buildtargets.parseSelectors({ "build", "--pack", "alpha" }, 2) :: buildtargets.Selection,
			"single",
			io
		)
		assert(joined(slugs(alpha)) == "alpha", "--pack selects exactly that pack")
	end,

	["an unknown pack slug fails and names the available packs"] = function()
		local selection = buildtargets.parseSelectors({ "build", "--pack", "nope" }, 2) :: buildtargets.Selection
		local targets, errors = buildtargets.resolveTargets(selection, "single", packsFs())
		assert(#targets == 0, "no target is selected")
		assert(hasText(errors, "no declared pack 'nope'"), "the error names the slug: " .. joined(errors))
		assert(hasText(errors, "alpha, beta"), "the error lists what is available: " .. joined(errors))
	end,

	["a missing packs root or project path fails"] = function()
		local io = packsFs()
		local rootSelection =
			buildtargets.parseSelectors({ "check", "--packs-root", "no/such/root" }, 2) :: buildtargets.Selection
		local rootTargets, rootErrors = buildtargets.resolveTargets(rootSelection, "all", io)
		assert(#rootTargets == 0 and hasText(rootErrors, "packs root does not exist"), joined(rootErrors))

		local projectSelection = buildtargets.parseSelectors(
			{ "build", "--project", "no/such/default.project.json" },
			2
		) :: buildtargets.Selection
		local projectTargets, projectErrors = buildtargets.resolveTargets(projectSelection, "single", io)
		assert(#projectTargets == 0 and hasText(projectErrors, "project file does not exist"), joined(projectErrors))
	end,

	["a malformed game.yml is rejected even with a valid rojo project"] = function()
		local targets, errors = buildtargets.discover("games", malformedDeclarationFs())
		assert(joined(slugs(targets)) == "alpha", "only the well-declared pack is eligible: " .. joined(slugs(targets)))
		assert(hasText(errors, "games/broken-yaml/game.yml"), "unparseable YAML is reported: " .. joined(errors))
		assert(hasText(errors, "games/scalar/game.yml"), "a non-mapping document is reported: " .. joined(errors))
		assert(hasText(errors, "games/nameless/game.yml"), "a mapping with no name is reported: " .. joined(errors))
		for _, err in errors do
			assert(string.find(err, "\n", 1, true) == nil, "a report line carries the reason, not a traceback: " .. err)
		end
	end,

	["output paths are injective, not merely sanitized"] = function()
		assert(
			buildtargets.packOutputPath("games", "kaiju-egg-raiders") == "build/kaiju-egg-raiders.rbxl",
			"the default pack output path is unchanged"
		)

		-- Two project files in the SAME directory must not share one artifact:
		-- keying only on the directory name made them collide, so building the
		-- second target would delete the first target's output.
		assert(
			buildtargets.projectOutputPath("a/default.project.json")
				~= buildtargets.projectOutputPath("a/other.project.json"),
			"two projects in one directory get their own artifacts"
		)
		assert(
			buildtargets.projectOutputPath("a/one/default.project.json")
				~= buildtargets.projectOutputPath("a/two/default.project.json"),
			"two project directories do not collide"
		)

		-- Sanitizing is lossy by design: `a_b`, `a-b` and `A-B` collapse to one
		-- segment, so the path tag - not the segment - carries the isolation.
		assert(
			buildtargets.sanitizeSegment("a_b") == buildtargets.sanitizeSegment("a-b"),
			"sanitize is documented as lossy, not injective"
		)
		local seen: { [string]: string } = {}
		for _, root in { ".omo/fixtures/a_b", ".omo/fixtures/a-b", ".omo/fixtures/A-B", "other/a-b" } do
			local path = buildtargets.packOutputPath(root, "kaiju-egg-raiders")
			assert(seen[path] == nil, "roots '" .. root .. "' and '" .. tostring(seen[path]) .. "' share " .. path)
			assert(path ~= "build/kaiju-egg-raiders.rbxl", "a fixture root cannot overwrite a real artifact")
			seen[path] = root
		end
		assert(
			buildtargets.packOutputPath(".omo/fixtures/x", "p") == buildtargets.packOutputPath(".omo/fixtures/x/", "p"),
			"the same root spelled with a trailing slash is still one target"
		)
	end,

	-- inspection expectations ------------------------------------------------
	["inspection expectations come from the target's own project"] = function()
		local expected, err = buildtargets.expectedInstances(
			projectJson("spec", "src/Main.server.luau", "src/shared"),
			"spec/default.project.json"
		)
		assert(expected ~= nil, tostring(err))
		local byPath: { [string]: string } = {}
		for _, item in expected :: { buildtargets.Expectation } do
			byPath[item.path] = item.expected
		end
		assert(byPath["ServerScriptService.Main"] == "Script", "a .server.luau path is a Script")
		assert(byPath["ReplicatedStorage.Remotes.Ping"] == "RemoteEvent", "a declared remote must exist")
		assert(byPath["ReplicatedStorage.Remotes"] == nil, "plain folders are not asserted")

		local empty, emptyErr = buildtargets.expectedInstances('{"tree":{"$className":"DataModel"}}', "empty.json")
		assert(empty == nil, "a project with nothing to assert is rejected, not inspected vacuously")
		assert(emptyErr ~= nil, "the rejection explains itself")

		local bad, badErr = buildtargets.expectedInstances("not json", "bad.json")
		assert(bad == nil and badErr ~= nil, "an undecodable project is rejected")
	end,

	-- real commands ----------------------------------------------------------
	["forge build --project builds and inspects one fixture project"] = function()
		local dir = FIXTURE_ROOT .. "/project-ok"
		removeFixture(dir)
		writeValidPack(dir, "project-ok")
		local ok, output = forge({ "build", "--project", dir .. "/default.project.json" })
		local artifact = buildtargets.projectOutputPath(dir .. "/default.project.json")
		assert(ok, "a valid fixture project must build and inspect: " .. output)
		assert(string.find(output, "build PASS", 1, true) ~= nil, output)
		assert(string.find(output, "inspect PASS", 1, true) ~= nil, output)
		assert(string.find(output, "(1 requires resolved)", 1, true) ~= nil, "the require was resolved: " .. output)
		assert(string.find(output, "revision=", 1, true) ~= nil, "the report names the revision: " .. output)
		assert(fs.isFile(artifact), "the artifact exists at " .. artifact)
		assert(
			string.find(output, serde.hash("sha256", fs.readFile(artifact)), 1, true) ~= nil,
			"digest is the artifact's own: " .. output
		)
		fs.removeFile(artifact)
		removeFixture(dir)
	end,

	["a fixture whose require is missing fails inspection without a stale pass"] = function()
		local dir = FIXTURE_ROOT .. "/project-missing-require"
		removeFixture(dir)
		writeMissingRequirePack(dir, "project-missing-require")
		local ok, output = forge({ "build", "--project", dir .. "/default.project.json" })
		assert(not ok, "a missing require must fail the command: " .. output)
		assert(string.find(output, "build PASS", 1, true) ~= nil, "the build itself succeeded: " .. output)
		assert(string.find(output, "inspect FAIL", 1, true) ~= nil, "inspection of the fresh place failed: " .. output)
		assert(string.find(output, "unresolved require", 1, true) ~= nil, output)
		local artifact = buildtargets.projectOutputPath(dir .. "/default.project.json")
		if fs.isFile(artifact) then
			fs.removeFile(artifact)
		end
		removeFixture(dir)
	end,

	["a failed build is never inspected and leaves no stale artifact"] = function()
		local dir = FIXTURE_ROOT .. "/project-stale"
		removeFixture(dir)
		writeValidPack(dir, "project-stale")
		local projectPath = dir .. "/default.project.json"
		local artifact = buildtargets.projectOutputPath(projectPath)

		local firstOk = forge({ "build", "--project", projectPath })
		assert(firstOk, "the first build succeeds")
		assert(fs.isFile(artifact), "and leaves an artifact that a later run could stale-inspect")

		writeUnbuildablePack(dir, "project-stale")
		local ok, output = forge({ "build", "--project", projectPath })
		assert(not ok, "a failing build must fail the command: " .. output)
		assert(string.find(output, "build FAIL", 1, true) ~= nil, output)
		assert(string.find(output, "inspect SKIPPED", 1, true) ~= nil, "no inspection may run: " .. output)
		assert(string.find(output, "inspect PASS", 1, true) == nil, "and none may pass: " .. output)
		assert(not fs.isFile(artifact), "the previous artifact is gone, not left to be re-inspected")
		removeFixture(dir)
	end,

	["check --packs-root fails the malformed pack and still verifies the valid one"] = function()
		local root = FIXTURE_ROOT .. "/matrix"
		removeFixture(root)
		writeValidPack(root .. "/good", "good")
		writeUnbuildablePack(root .. "/broken", "broken")
		writeFile(root .. "/partial/game.yml", "name: partial\n")

		-- A previous artifact for the broken pack: it must never be inspected.
		local brokenArtifact = buildtargets.packOutputPath(root, "broken")
		writeValidPack(root .. "/broken-seed", "broken-seed")
		local seedOk = forge({ "build", "--project", root .. "/broken-seed/default.project.json" })
		assert(seedOk, "the seed place builds")
		local seedArtifact = buildtargets.projectOutputPath(root .. "/broken-seed/default.project.json")
		local seedDir = string.match(brokenArtifact, "^(.*)/[^/]+$")
		if seedDir ~= nil and not fs.isDir(seedDir) then
			local current = ""
			for segment in string.gmatch(seedDir, "[^/]+") do
				current = if current == "" then segment else current .. "/" .. segment
				if not fs.isDir(current) then
					fs.writeDir(current)
				end
			end
		end
		fs.writeFile(brokenArtifact, fs.readFile(seedArtifact))
		fs.removeFile(seedArtifact)
		removeFixture(root .. "/broken-seed")

		local targets, errors = buildtargets.resolveTargets(
			buildtargets.parseSelectors({ "check", "--packs-root", root }, 2) :: buildtargets.Selection,
			"all"
		)
		assert(joined(slugs(targets)) == "broken | good", "both declared packs are targets: " .. joined(slugs(targets)))
		assert(hasText(errors, "partial"), "the partial pack is reported: " .. joined(errors))

		local results = buildtargets.runTargets(targets)
		assert(#results == 2, "every target is reported independently")
		local bySlug: { [string]: buildtargets.TargetResult } = {}
		for _, result in results do
			bySlug[result.target.slug] = result
		end
		assert(bySlug["good"].ok, "the valid pack is still built and inspected")
		assert(bySlug["good"].digest ~= nil, "and carries its own fresh digest")
		assert(not bySlug["broken"].built, "the broken pack fails its build")
		assert(
			string.find(buildtargets.formatInspect(bySlug["broken"]), "SKIPPED", 1, true) ~= nil,
			"and is never inspected"
		)
		assert(not fs.isFile(brokenArtifact), "its previous artifact was removed before the failed build")

		local goodArtifact = buildtargets.packOutputPath(root, "good")
		assert(fs.isFile(goodArtifact), "the valid pack's artifact exists")
		fs.removeFile(goodArtifact)
		removeFixture(root)
	end,
}
