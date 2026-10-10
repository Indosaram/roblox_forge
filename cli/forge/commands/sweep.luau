--!strict
-- `forge sweep [--genres a,b,...] [--out <dir>]`: the baseline playability
-- harness. For every registered genre (plus survival-coop in `--mode crafting`
-- as one extra variant) it generates a fresh pack into a scratch packs root
-- outside games/, then records each step independently, with its own pass/fail
-- and first error:
--
--   generate - did pack generation write anything at all
--   files    - do the expected entrypoints exist (Assets.luau, client/server
--              entry scripts, default.project.json)
--   build    - does rojo build the pack to build/sweep/<stamp>/<genre>.rbxl
--   inspect  - does the built place resolve every require and declared instance
--   spec     - does the genre's declarative spec validate, and does the
--              generated pack carry its serialized src/shared/GenreSpec.luau
--   nativeQa - every executable (native) scenario that applies to the generated
--              pack, run in-process through the real qa harness; "no executable
--              scenarios" is recorded explicitly when none apply
--   surface  - controls exposed vs controls the genre's qa-scenarios reference
--              (with unmatched targets), whether a HUD beyond the debug
--              Snapshots panel is wired, whether every visible HUD string is
--              declared display text rather than a raw spec id, and whether the
--              built place carries a playable world (part floors per zone,
--              ground under the spawn, a baked Atmosphere/Sky environment).
--
-- One genre failing never stops another: the JSON + markdown report is always
-- written, and the command exits non-zero when any genre is not fully green.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local buildtargets = require("../lib/buildtargets")
local cliutil = require("../lib/cliutil")
local generate = require("../lib/genregenerate")
local genrespec = require("../lib/genrespec")
local project = require("../lib/genreproject")
local qaharness = require("../lib/qaharness")
local loadproof = require("../lib/loadproof")
local qualityevidence = require("../lib/qualityevidence")
local qualityprofile = require("../lib/qualityprofile")
local registryLib = require("../lib/genreregistry")
local scaffold = require("../lib/scaffold")
local qaCommand = require("./qa")
local HudText = require("../../../core/ui-kit/genre/HudText")
local HudContrast = require("../../../core/ui-kit/genre/HudContrast")
local HudFit = require("../../../core/ui-kit/genre/HudFit")
local HudScale = require("../../../core/ui-kit/genre/HudScale")
local Theme = require("../../../core/ui-kit/Theme")
local WorldKit = require("../../../core/ui-kit/genre/WorldKit")

local M = {}

M.DEFAULT_OUT_ROOT = "build/sweep"
M.STEP_NAMES = {
	"generate",
	"files",
	"build",
	"inspect",
	"spec",
	"hud",
	"world",
	"audio",
	"nativeQa",
	"surface",
	"load",
	"quality",
}
M.REQUIRED_FILES = { "default.project.json", "game.yml", "econ.yml", "src/shared/Assets.luau", "quality.yml" }

export type Variant = { id: string, mode: string?, label: string, slug: string, artifact: string }
export type Step = { ok: boolean, error: string?, [string]: any }
export type Report = {
	genre: string,
	label: string,
	slug: string,
	mode: string?,
	packDir: string,
	steps: { [string]: Step },
	ok: boolean,
}
export type Summary = {
	total: number,
	passed: number,
	failed: number,
	stepNames: { string },
	stepFailures: { [string]: number },
	failures: { { genre: string, step: string, error: string } },
}

local function firstLine(value: any): string
	local text = tostring(value)
	return string.match(text, "^[^\r\n]+") or text
end

local function firstError(errors: { string }): string?
	return if #errors > 0 then firstLine(errors[1]) else nil
end

local function ensureDir(path: string)
	local segments: { string } = {}
	for segment in string.gmatch(path, "[^/]+") do
		table.insert(segments, segment)
	end
	local current = ""
	for _, segment in segments do
		current = if current == "" then segment else current .. "/" .. segment
		if not fs.isDir(current) then
			fs.writeDir(current)
		end
	end
end

local function listRelative(root: string): { string }
	local out: { string } = {}
	local function visit(dir: string, prefix: string)
		if not fs.isDir(dir) then
			return
		end
		local names = fs.readDir(dir)
		table.sort(names)
		for _, name in names do
			local path = dir .. "/" .. name
			if fs.isDir(path) then
				visit(path, prefix .. name .. "/")
			else
				table.insert(out, prefix .. name)
			end
		end
	end
	visit(root, "")
	return out
end

local function matches(files: { string }, pattern: string): { string }
	local out: { string } = {}
	for _, file in files do
		if string.match(file, pattern) then
			table.insert(out, file)
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Argument parsing (pure)
-- ---------------------------------------------------------------------------

--- Splits a comma-separated genre list, trimming each token. Rejects an empty
--- token and a duplicate, so `--genres a,,b` and `--genres a,a` are usage
--- errors rather than a silently shortened sweep.
function M.parseGenreList(raw: string): ({ string }?, string?)
	local genres: { string } = {}
	local seen: { [string]: boolean } = {}
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
	if #genres == 0 then
		return nil, "--genres requires at least one genre"
	end
	return genres, nil
end

export type Options = { genres: { string }?, out: string? }

--- Parses the sweep's own options. Returns (nil, reason) for an unknown flag or
--- a flag without a value.
function M.parseArgs(args: { string }, startIndex: number?): (Options?, string?)
	local options: Options = { genres = nil, out = nil }
	local index = startIndex or 2
	while index <= #args do
		local flag = args[index]
		local value = args[index + 1]
		if flag == "--genres" or flag == "--out" then
			if value == nil or value == "" or string.sub(value, 1, 2) == "--" then
				return nil, flag .. " requires a value"
			end
			if flag == "--genres" then
				if options.genres ~= nil then
					return nil, "duplicate --genres"
				end
				local genres, reason = M.parseGenreList(value)
				if genres == nil then
					return nil, reason
				end
				options.genres = genres
			else
				if options.out ~= nil then
					return nil, "duplicate --out"
				end
				options.out = string.gsub(value, "\\", "/")
			end
			index += 2
		else
			return nil, "unknown option '" .. tostring(flag) .. "'"
		end
	end
	return options, nil
end

-- ---------------------------------------------------------------------------
-- Variant selection (pure)
-- ---------------------------------------------------------------------------

--- The sweep matrix: every registered genre in registry order, plus the
--- survival-coop crafting variant. When `selected` is given, only the named
--- genres run (survival-coop still contributes both of its variants).
function M.variants(registry: registryLib.Registry, selected: { [string]: boolean }?): ({ Variant }, { string })
	local variants: { Variant } = {}
	for _, id in registry.order do
		if selected ~= nil and not selected[id] then
			continue
		end
		table.insert(variants, { id = id, mode = nil, label = id, slug = id .. "-sweep", artifact = id })
		if id == "survival-coop" then
			local crafting: Variant = {
				id = id,
				mode = "crafting",
				label = id .. " (crafting)",
				slug = id .. "-crafting-sweep",
				artifact = id .. "-crafting",
			}
			table.insert(variants, crafting)
		end
	end
	local errors: { string } = {}
	if selected ~= nil then
		for id in selected do
			if registry.packages[id] == nil then
				table.insert(errors, "unknown genre '" .. id .. "'")
			end
		end
		table.sort(errors)
	end
	return variants, errors
end

-- ---------------------------------------------------------------------------
-- Report aggregation (pure)
-- ---------------------------------------------------------------------------

--- Counts the genres that passed every step and collects one row per failing
--- step (genre, step, first error), sorted. A genre whose step is missing
--- entirely is a failure, so a truncated report can never read as a pass.
function M.summarize(reports: { Report }): Summary
	local summary: Summary = {
		total = #reports,
		passed = 0,
		failed = 0,
		stepNames = table.clone(M.STEP_NAMES),
		stepFailures = {},
		failures = {},
	}
	for _, name in M.STEP_NAMES do
		summary.stepFailures[name] = 0
	end
	for _, report in reports do
		if report.ok then
			summary.passed += 1
		else
			summary.failed += 1
		end
		for _, name in M.STEP_NAMES do
			local step = report.steps[name]
			if step == nil or not step.ok then
				summary.stepFailures[name] += 1
				table.insert(summary.failures, {
					genre = report.label,
					step = name,
					error = if step ~= nil and step.error ~= nil then step.error else "step not recorded",
				})
			end
		end
	end
	table.sort(summary.failures, function(a, b)
		if a.genre ~= b.genre then
			return a.genre < b.genre
		end
		if a.step ~= b.step then
			return a.step < b.step
		end
		return a.error < b.error
	end)
	return summary
end

--- One markdown table of step verdicts plus the first failure of each step.
function M.renderMarkdown(summary: Summary, reports: { Report }, stamp: string): string
	local lines = {
		"# Forge genre sweep " .. stamp,
		"",
		string.format("Result: %d/%d genres fully passed.", summary.passed, summary.total),
		"",
	}
	local header = { "genre" }
	for _, name in M.STEP_NAMES do
		table.insert(header, name)
	end
	table.insert(header, "verdict")
	table.insert(lines, "| " .. table.concat(header, " | ") .. " |")
	local separators: { string } = {}
	for _ = 1, #header do
		table.insert(separators, "---")
	end
	table.insert(lines, "| " .. table.concat(separators, " | ") .. " |")
	for _, report in reports do
		local row = { report.label }
		for _, name in M.STEP_NAMES do
			local step = report.steps[name]
			-- The audio column distinguishes declared from playable: a pack whose cues are declared but
			-- whose published asset ids are absent is silent, which must never read as PASS.
			if step == nil then
				table.insert(row, "MISSING")
			elseif not step.ok then
				table.insert(row, "FAIL")
			elseif name == "audio" and step.playable == false then
				table.insert(row, "DECLARED")
			elseif name == "nativeQa" and step.skipped == true then
				table.insert(row, "SKIP")
			else
				table.insert(row, "PASS")
			end
		end
		table.insert(row, if report.ok then "PASS" else "FAIL")
		table.insert(lines, "| " .. table.concat(row, " | ") .. " |")
	end
	table.insert(lines, "")
	table.insert(
		lines,
		"Legend: `quality` passes only when the receipt is valid for the pack's declared tier; "
			.. "fun and visual quality remain human-judgment-pending in every case."
	)
	table.insert(lines, "")
	table.insert(lines, "## First failure per step")
	table.insert(lines, "")
	if #summary.failures == 0 then
		table.insert(lines, "None: every genre passed every step.")
	else
		for _, failure in summary.failures do
			table.insert(lines, string.format("- %s / %s: %s", failure.genre, failure.step, failure.error))
		end
	end
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Step probes
-- ---------------------------------------------------------------------------

local function fileChecks(packDir: string): any
	local missing: { string } = {}
	for _, path in M.REQUIRED_FILES do
		if not fs.isFile(packDir .. "/" .. path) then
			table.insert(missing, path)
		end
	end
	local files = listRelative(packDir)
	local clientEntries = matches(files, "^src/client/.*%.client%.luau$")
	local serverEntries = matches(files, "^src/server/.*%.server%.luau$")
	if #clientEntries == 0 then
		table.insert(missing, "src/client/*.client.luau")
	end
	if #serverEntries == 0 then
		table.insert(missing, "src/server/*.server.luau")
	end
	table.sort(missing)
	return { missing = missing, clientEntries = clientEntries, serverEntries = serverEntries, files = files }
end

--- Decodes every qa-scenario the genre ships (any kind), so the native-QA step
--- and the surface probe read the same source of truth.
local function genreScenarios(registry: registryLib.Registry, id: string): { any }
	local dir = registry.root .. "/" .. id .. "/qa-scenarios"
	local out: { any } = {}
	if not fs.isDir(dir) then
		return out
	end
	local names = fs.readDir(dir)
	table.sort(names)
	for _, name in names do
		if string.match(name, "%.yml$") then
			local path = dir .. "/" .. name
			local ok, decoded = pcall(function()
				return serde.decode("yaml", fs.readFile(path))
			end)
			if ok and type(decoded) == "table" then
				table.insert(out, { name = string.gsub(name, "%.yml$", ""), path = path, scenario = decoded })
			end
		end
	end
	return out
end

--- Decodes every qa-scenario the generated pack itself carries, so the native
--- step runs the pack's own QA (the derived golden path) rather than the genre
--- directory's fixture-bound scenarios.
local function packScenarios(packDir: string): { any }
	local dir = packDir .. "/qa-scenarios"
	local out: { any } = {}
	if not fs.isDir(dir) then
		return out
	end
	local names = fs.readDir(dir)
	table.sort(names)
	for _, name in names do
		if string.match(name, "%.yml$") then
			local path = dir .. "/" .. name
			local ok, decoded = pcall(function()
				return serde.decode("yaml", fs.readFile(path))
			end)
			if ok and type(decoded) == "table" then
				table.insert(out, { name = string.gsub(name, "%.yml$", ""), path = path, scenario = decoded })
			end
		end
	end
	return out
end

--- The generated pack's own smoke, run in-process. A legacy pack's playable loop is engine-side, so
--- the generic Executor fixture beside it is a parallel runtime rather than the game: the legacy
--- smoke, which drives the pack's real pure modules, is its native evidence. A legacy pack that
--- ships no smoke is a SKIP (the same convention `forge smoke --local` uses), never a pass claim -
--- its evidence is the Studio scenario that drives the real runtime.
local function runLegacySmoke(packDir: string): (boolean, { any }, string?, boolean)
	local scriptPath = packDir .. "/smoke/smoke.luau"
	if not fs.isFile(scriptPath) then
		return true,
			{},
			"no in-process smoke ships with this legacy pack; its evidence is the Studio scenario over the real runtime",
			true
	end
	local loaded, smoke = pcall(function()
		return (require :: any)("./" .. project.relative("cli/forge/commands", packDir .. "/smoke/smoke"))
	end)
	if not loaded then
		return false, {}, "failed to load smoke: " .. firstLine(smoke), false
	end
	if type(smoke) ~= "table" or type(smoke.run) ~= "function" then
		return false, {}, "smoke does not export run()", false
	end
	local ran, checks = pcall(smoke.run, nil)
	if not ran then
		return false, {}, "smoke errored: " .. firstLine(checks), false
	end
	if type(checks) ~= "table" or #checks == 0 then
		return false, {}, "smoke returned no checks", false
	end
	local rows: { any } = {}
	local allOk = true
	for _, check in checks do
		local rowOk = type(check) == "table" and check.ok == true
		if not rowOk then
			allOk = false
		end
		table.insert(rows, {
			name = if type(check) == "table" then tostring(check.name) else "check",
			ok = rowOk,
			error = if rowOk or type(check) ~= "table" then nil else tostring(check.detail),
		})
	end
	return allOk, rows, if allOk then nil else "legacy smoke failed", false
end

--- True when a step's target names a player-facing control instance. A
--- `capture` label, a `purchase_sim` slot and a Workspace path are none of
--- those, so none pollutes the referenced set.
local function isControlTarget(verb: string?, target: any): boolean
	if type(target) ~= "string" or string.match(target, "^Workspace%.") ~= nil then
		return false
	end
	if string.match(target, "^[a-z][%w%-]*:[a-z][%w%-]*$") ~= nil then
		return true
	end
	return verb == "click" or verb == "equip" or verb == "touch"
end

--- The controls the genre's QA drives: the generator's declared targets, plus
--- the control names the *executable* (native) scenarios address.
---
--- A native step's `action` is a domain action, not a control: a durable
--- command has no button, and a genre may bind several controls to one action.
--- Studio and playtest click targets address a hand-authored HUD through Studio
--- MCP, which is neither shipped nor gated here (design §4.5), so they are not
--- part of the pack's declared control contract.
local function referencedTargets(entries: { any }, registry: registryLib.Registry, id: string): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, entry in entries do
		if entry.scenario.kind ~= "native" then
			continue
		end
		for _, step in entry.scenario.steps or {} do
			if type(step) == "table" then
				local verb = if type(step.op) == "string" then step.op else step.action
				if isControlTarget(verb, step.target) then
					set[step.target] = true
				end
			end
		end
	end
	local package = registry.packages[id]
	if package ~= nil then
		local declared: { string } = package.generator.qa.targets or {}
		for _, target in declared do
			set[target] = true
		end
	end
	return set
end
--- Evaluates the generated pack's own control list (pure data, no Roblox APIs).
local function loadControls(packDir: string): ({ any }?, string?)
	local path = packDir .. "/src/shared/GenreUI.luau"
	if not fs.isFile(path) then
		return nil, path .. ": missing"
	end
	local ok, result = pcall(function()
		return luau.load(fs.readFile(path))()
	end)
	if not ok then
		return nil, firstLine(result)
	end
	if type(result) ~= "table" then
		return nil, path .. ": did not return a control list"
	end
	return result, nil
end

--- Which client a pack binds: the generic core debug panel, the core HUD kit, a
--- genre-owned runtime client (which owns its own HUD), a pack-authored client,
--- or none.
local function clientKind(clientText: string?, overrideModule: string?): string
	if clientText == nil then
		return "no client entry"
	end
	if string.find(clientText, "genre.HudKit", 1, true) ~= nil then
		return "core HUD kit client"
	end
	-- A declared client override counts even when the client also starts the
	-- generic core client: the crafting bootstrap layers SurvivalHUD on it.
	if type(overrideModule) == "string" then
		local name = string.match(overrideModule, "([%w_]+)$")
		if name ~= nil and string.find(clientText, "module." .. name, 1, true) ~= nil then
			return "genre runtime client"
		end
	end
	if string.find(clientText, "core.infra.genre.Client", 1, true) ~= nil then
		return "core debug panel"
	end
	if string.match(clientText, "genres%[[\"'][^\"']+[\"']%]%.module") ~= nil then
		return "genre runtime client"
	end
	return "pack-authored client"
end

--- A genre module reference (`<genre>`, `a.b`) resolved to its source and path.
local function genreModuleSource(registry: registryLib.Registry, genre: string, tail: string): (string?, string?)
	local package = registry.packages[genre]
	if package == nil then
		return nil, nil
	end
	local path = package.path .. "/module/" .. string.gsub(tail, "%.", "/") .. ".luau"
	return (if fs.isFile(path) then fs.readFile(path) else nil), path
end

--- The relative `require` targets of a module source, as written.
local function relativeRequires(source: string): { string }
	local out: { string } = {}
	for target in string.gmatch(source, 'require%("(%.%.?/[^"]+)"%)') do
		table.insert(out, target)
	end
	return out
end

local function joinPath(directory: string, target: string): string
	local parts: { string } = {}
	for segment in string.gmatch(directory, "[^/]+") do
		table.insert(parts, segment)
	end
	for segment in string.gmatch(target, "[^/]+") do
		if segment == ".." then
			table.remove(parts)
		elseif segment ~= "." then
			table.insert(parts, segment)
		end
	end
	return table.concat(parts, "/")
end

--- The module that actually owns the pack's HUD: the file that creates the
--- ScreenGui. The client's own file wins when it builds its HUD inline (the
--- collect-raid starter does); otherwise the client's genre-module requires are
--- walked two levels deep, which is how a thin binder reaches its genre's HUD.
local function hudOwnerSource(
	hudKind: string,
	clientEntry: string?,
	clientPath: string?,
	registry: registryLib.Registry,
	overrideModule: string?
): (string?, string?)
	if hudKind == "core HUD kit client" then
		local path = project.coreRoot(registry) .. "/ui-kit/genre/HudKit.luau"
		return (if fs.isFile(path) then fs.readFile(path) else nil), path
	end
	if clientEntry ~= nil and string.find(clientEntry, "ScreenGui", 1, true) ~= nil then
		return clientEntry, clientPath
	end
	-- The declared override module is the HUD owner when the client binds it: a
	-- genre may ship several GUI-owning modules (survival-coop's GatheringClient
	-- creates a touch button), and only one of them is the HUD.
	if type(overrideModule) == "string" then
		local genre, tail = string.match(overrideModule, "^genres/([^/]+)/module/(.+)$")
		if genre ~= nil and tail ~= nil then
			local source, path = genreModuleSource(registry, genre, (string.gsub(tail, "/", ".")))
			if source ~= nil and string.find(source, "ScreenGui", 1, true) ~= nil then
				return source, path
			end
		end
	end
	local frontier: { any } = {}
	for genre, tail in string.gmatch(clientEntry or "", 'genres%[%s*"([^"]+)"%s*%]%.module%.([%w_%.]+)') do
		if genre == nil or tail == nil then
			continue
		end
		local source, path = genreModuleSource(registry, genre, tail)
		if path ~= nil then
			table.insert(frontier, { path = path, source = source })
		end
	end
	local visited: { [string]: boolean } = {}
	for _ = 1, 2 do
		local following: { any } = {}
		for _, entry in frontier do
			if visited[entry.path] then
				continue
			end
			visited[entry.path] = true
			if entry.source ~= nil and string.find(entry.source, "ScreenGui", 1, true) ~= nil then
				return entry.source, entry.path
			end
			local directory = string.match(entry.path, "^(.*)/[^/]+$") or ""
			for _, target in relativeRequires(entry.source or "") do
				local path = joinPath(directory, target) .. ".luau"
				if fs.isFile(path) then
					table.insert(following, { path = path, source = fs.readFile(path) })
				end
			end
		end
		frontier = following
	end
	return nil, nil
end
local function hudModules(root: string): { string }
	local out: { string } = {}
	for _, file in listRelative(root) do
		if
			string.match(file, "[Hh][Uu][Dd]") ~= nil
			and string.match(file, "%.luau$") ~= nil
			and string.match(file, "%.spec%.luau$") == nil
		then
			table.insert(out, file)
		end
	end
	table.sort(out)
	return out
end

--- Reads the built place's world: how many parts it carries, the role and zone
--- of each, whether a floor part covers the spawn, whether the place carries
--- the baked lighting environment, and whether a solid decorative/landmark part
--- stands in an interactive node's approach corridor or has been made
--- unqueryable. Returns nil when the artifact cannot be read, so a missing place
--- can never report a world.
local function placeWorldReport(path: string, spawn: { number }?, volume: any?, approach: { any }?): any
	if not fs.isFile(path) then
		return nil
	end
	local ok, place = pcall(function()
		return roblox.deserializePlace(fs.readFile(path))
	end)
	if not ok then
		return nil
	end
	local report: any = {
		parts = 0,
		roles = {},
		zones = {},
		ground = false,
		atmosphere = false,
		sky = false,
		lighting = {},
		clearance = {},
		approach = {},
		unqueryable = {},
	}
	-- The largest Color3 component of a Lighting/Atmosphere colour. A project file's
	-- `Color3` takes 0..1 components, so a value above 1 is a 0..255 triple that
	-- was written straight through and will render clamped to pure white - the
	-- defect that once washed every generated place into a flat white screen.
	local function colorMax(value: any): number?
		local decoded, maxComponent = pcall(function()
			return math.max(value.R, value.G, value.B)
		end)
		return if decoded then maxComponent else nil
	end
	local function record(name: string, value: any): ()
		local maxComponent = colorMax(value)
		if maxComponent ~= nil then
			report.lighting[name] = maxComponent
		end
	end
	local function visit(instance: any)
		if instance:IsA("BasePart") then
			report.parts += 1
			local role = instance:GetAttribute("ForgePartRole")
			local roleKey = tostring(role)
			report.roles[roleKey] = (report.roles[roleKey] or 0) + 1
			local zone = instance:GetAttribute("ForgeZoneId")
			if zone ~= nil then
				report.zones[tostring(zone)] = (report.zones[tostring(zone)] or 0) + 1
			end
			if spawn ~= nil and not report.ground and role == "floor" then
				local rx, ry, rz = instance.CFrame:ToOrientation()
				report.ground = WorldKit.coversGround({
					size = { instance.Size.X, instance.Size.Y, instance.Size.Z },
					position = { instance.CFrame.Position.X, instance.CFrame.Position.Y, instance.CFrame.Position.Z },
					rotation = { math.deg(rx), math.deg(ry), math.deg(rz) },
					role = role,
				}, spawn)
			end
			-- The spawn view is measured on the built place, not on the spec: a world a
			-- runtime builder places is held to the same clearance rule as a baked one.
			if
				volume ~= nil
				and WorldKit.partInClearance({
					size = { instance.Size.X, instance.Size.Y, instance.Size.Z },
					position = {
						instance.CFrame.Position.X,
						instance.CFrame.Position.Y,
						instance.CFrame.Position.Z,
					},
					role = role,
				}, volume)
			then
				table.insert(report.clearance, instance.Name)
			end
			-- A node's approach corridor is measured on the built place for the same
			-- reason: a decor prop or a landmark standing where a player walks up to a
			-- node hides the node (and the character) from the camera behind them.
			local geometry = {
				size = { instance.Size.X, instance.Size.Y, instance.Size.Z },
				position = {
					instance.CFrame.Position.X,
					instance.CFrame.Position.Y,
					instance.CFrame.Position.Z,
				},
				role = role,
			}
			local approachList: { any } = if approach ~= nil then approach else {}
			for _, entry in approachList do
				if WorldKit.partInApproach(geometry, entry.volume) then
					table.insert(report.approach, string.format("%s at node %s", instance.Name, entry.node))
					break
				end
			end
			-- The default camera pops in front of a solid part it can query
			-- (`Camera:GetPartsObscuringTarget` and the popper's raycasts both answer
			-- CanQuery=false with nothing). A solid decorative or landmark part that
			-- is unqueryable therefore lets the camera sit behind it and hide the
			-- character, which is a defect no part count can see.
			if WorldKit.APPROACH_OCCLUDER_ROLES[tostring(role)] and instance.CanCollide and not instance.CanQuery then
				table.insert(report.unqueryable, instance.Name)
			end
		elseif instance:IsA("Lighting") then
			record("ambient", instance.Ambient)
			record("outdoorAmbient", instance.OutdoorAmbient)
		elseif instance:IsA("Atmosphere") then
			report.atmosphere = true
			record("atmosphereColor", instance.Color)
			record("atmosphereDecay", instance.Decay)
		elseif instance:IsA("Sky") then
			report.sky = true
		end
		for _, child in instance:GetChildren() do
			visit(child)
		end
	end
	for _, service in place:GetChildren() do
		visit(service)
	end
	return report
end

-- ---------------------------------------------------------------------------
-- One variant
-- ---------------------------------------------------------------------------

function M.runVariant(
	variant: Variant,
	registry: registryLib.Registry,
	context: cliutil.CommandContext,
	packsDir: string,
	outDir: string
): Report
	local packDir = packsDir .. "/" .. variant.slug
	local pascal = scaffold.pascalCase(variant.slug)
	local report: Report = {
		genre = variant.id,
		label = variant.label,
		slug = variant.slug,
		mode = variant.mode,
		packDir = packDir,
		steps = {},
		ok = false,
	}

	-- (a) generation
	local assembly: any = nil
	local generated, generationError = pcall(function()
		assembly = generate.assemble(registry, { variant.id }, {
			mode = "new",
			slug = variant.slug,
			pascal = pascal,
			title = scaffold.titleCase(variant.slug),
			concept = "",
			seed = 0,
			teams = { "Red", "Blue" },
			debugName = pascal .. "Debug",
			guiName = pascal .. "Gui",
		}, packDir, variant.mode)
		local written, reason = generate.write(assembly, packDir, variant.slug, context)
		assert(written, reason)
	end)
	report.steps.generate = { ok = generated, error = if generated then nil else firstLine(generationError) }

	-- (b) expected files
	local checks = fileChecks(packDir)
	report.steps.files = {
		ok = #checks.missing == 0,
		missing = checks.missing,
		clientEntries = checks.clientEntries,
		serverEntries = checks.serverEntries,
		error = if #checks.missing > 0 then "missing: " .. table.concat(checks.missing, ", ") else nil,
	}

	-- (c)+(d) build and inspect through the shared target runner, into the
	-- sweep's own artifact path.
	local artifact = outDir .. "/" .. variant.artifact .. ".rbxl"
	local projectPath = packDir .. "/default.project.json"
	if not fs.isFile(projectPath) then
		report.steps.build = { ok = false, output = artifact, error = "no default.project.json to build" }
		report.steps.inspect = { ok = false, error = "no default.project.json to inspect" }
	else
		local target: buildtargets.Target = {
			kind = "pack",
			slug = variant.slug,
			packDir = packDir,
			projectPath = projectPath,
			outputPath = artifact,
		}
		local result = buildtargets.runTarget(target)
		report.steps.build = {
			ok = result.built,
			output = artifact,
			sha256 = result.digest,
			error = if result.built then nil else (firstError(result.errors) or "rojo build failed"),
		}
		report.steps.inspect = {
			ok = result.built and result.ok,
			resolvedRequires = result.resolvedRequiresCount,
			errors = result.errors,
			error = if result.built and result.ok then nil else (firstError(result.errors) or "inspection failed"),
		}
	end

	-- (e) declarative spec: the variant's genre spec must validate against its
	-- runtime descriptor and the generated pack must carry its serialized form.
	local genrePackage = registry.packages[variant.id]
	local specFile = packDir .. "/src/shared/GenreSpec.luau"
	local specErrors: { string } = {}
	if genrePackage == nil then
		table.insert(specErrors, variant.id .. ": genre package not loaded")
	else
		for _, err in
			genrespec.validate(genrePackage.spec, genrePackage.runtime, {
				id = variant.id,
				path = genrePackage.path,
			})
		do
			table.insert(specErrors, variant.id .. ": " .. err)
		end
	end
	if not fs.isFile(specFile) then
		table.insert(specErrors, specFile .. ": missing")
	end
	report.steps.spec = {
		ok = #specErrors == 0,
		file = specFile,
		errors = specErrors,
		error = firstError(specErrors),
	}

	-- (f) headless native QA: every executable scenario that applies to THIS pack,
	-- from the pack itself and from the genre directory. A scenario bound to
	-- another pack is not this pack's evidence, so it is excluded rather than
	-- counted as a failure; no applicable scenario at all is still a failure.
	local entries = packScenarios(packDir)
	for _, entry in genreScenarios(registry, variant.id) do
		table.insert(entries, entry)
	end
	local native: { any } = {}
	for _, entry in entries do
		if entry.scenario.kind == "native" and entry.scenario.pack == variant.slug then
			table.insert(native, entry)
		end
	end
	-- The QA target the load proof runs against. Resolved in the native-QA step
	-- (a legacy pack builds it from the config generation already validated) and
	-- reused here, so both columns drive the same pack the same way.
	local qaTarget: any = nil
	if assembly.legacy then
		-- A legacy pack's playable loop is engine-side, so the generic Executor fixture is a parallel
		-- runtime rather than the game. The pack's own smoke - pure, engine-free, driving the real
		-- legacy modules - is its native evidence instead.
		local smokeOk, smokeRows, smokeError, smokeSkipped = runLegacySmoke(packDir)
		local smokePassed = 0
		for _, row in smokeRows do
			if row.ok then
				smokePassed += 1
			end
		end
		report.steps.nativeQa = {
			ok = smokeOk,
			executable = not smokeSkipped,
			legacy = true,
			skipped = smokeSkipped,
			ran = #smokeRows,
			passed = smokePassed,
			scenarios = smokeRows,
			error = if smokeOk then nil else smokeError,
		}
	elseif #native == 0 then
		report.steps.nativeQa = {
			ok = false,
			executable = false,
			ran = 0,
			passed = 0,
			scenarios = {},
			error = "no executable scenarios apply to this pack",
		}
	else
		local loadedTarget, targetErrors = qaCommand.loadTarget(variant.slug, registry, context, packsDir)
		qaTarget = loadedTarget
		if qaTarget == nil and type(assembly.pack) == "table" then
			-- A legacy pack carries no genre_contract document: its pack config is the
			-- one generation just validated, so the native run uses that.
			local contracts: { any } = {}
			for _, id in assembly.order do
				table.insert(contracts, registry.runtimes[id])
			end
			qaTarget = {
				packConfig = assembly.pack,
				contracts = contracts,
				controls = {},
				storeName = string.sub(variant.slug, 1, 40) .. "-qa",
			}
			targetErrors = {}
		end
		if qaTarget == nil then
			report.steps.nativeQa = {
				ok = false,
				executable = true,
				ran = 0,
				passed = 0,
				scenarios = {},
				error = firstLine(targetErrors[1] or "no QA target for the generated pack"),
			}
		else
			local rows: { any } = {}
			local ran, passed = 0, 0
			for _, entry in native do
				ran += 1
				local ok, outcome = pcall(qaharness.runNative, entry.scenario, qaTarget)
				local stepOk = ok and outcome.ok == true
				if stepOk then
					passed += 1
				end
				table.insert(rows, {
					name = entry.name,
					ok = stepOk,
					error = if stepOk
						then nil
						elseif ok then (firstError(outcome.failures) or "failed")
						else firstLine(outcome),
				})
			end
			report.steps.nativeQa = {
				ok = passed == ran,
				executable = true,
				ran = ran,
				passed = passed,
				scenarios = rows,
				error = if passed == ran
					then nil
					else string.format("%d/%d native scenarios failed", ran - passed, ran),
			}
		end
	end

	-- (g) HUD, world and audio probes, then the aggregate surface verdict.
	--
	-- The three probes are independent and each names its own first error; the
	-- surface column is the conjunction the design's §5.1 defines, plus an empty
	-- unmatched-target set, so a pack with a HUD but no world can never read PASS.
	local controls, controlError = loadControls(packDir)
	local spec: any = if genrePackage ~= nil then genrePackage.spec else nil
	local specControls = genrespec.controlIds(spec)
	local declaredIds: { [string]: boolean } = {}
	local declaredActions: { [string]: boolean } = {}
	local controlIds: { string } = {}
	local controlActions: { string } = {}
	local declaredControls: { any } = controls or {}
	for _, control in declaredControls do
		if type(control) == "table" then
			if type(control.id) == "string" then
				declaredIds[control.id] = true
				table.insert(controlIds, control.id)
			end
			if type(control.action) == "string" then
				declaredActions[control.action] = true
				table.insert(controlActions, control.action)
			end
		end
	end
	local manifest = if controls ~= nil then "GenreUI.luau" else "genre spec (declared override)"
	if #controlIds == 0 and #specControls > 0 then
		-- A declared override client enumerates its controls in the spec: its real
		-- controls are HUD instance Names, not derived GenreUI rows.
		for _, id in specControls do
			declaredIds[id] = true
			table.insert(controlIds, id)
		end
	end
	table.sort(controlIds)
	table.sort(controlActions)

	local aliases = genrespec.uiTargets(spec)
	local referenced = referencedTargets(entries, registry, variant.id)
	local referencedList: { string } = {}
	local unmatched: { string } = {}
	for target in referenced do
		local resolved = aliases[target] or target
		table.insert(referencedList, target)
		if not declaredIds[resolved] and not declaredActions[resolved] then
			table.insert(unmatched, target)
		end
	end
	table.sort(referencedList)
	table.sort(unmatched)

	local clientEntry = if #checks.clientEntries > 0
		then fs.readFile(packDir .. "/" .. checks.clientEntries[1])
		else nil
	local worldModules: { string } = {}
	for _, file in checks.files do
		if string.match(file, "[Ww]orld") ~= nil or string.match(file, "[Ll]ayout") ~= nil then
			table.insert(worldModules, file)
		end
	end
	table.sort(worldModules)

	-- HUD: a playable client whose HUD owner declares the safe-area guarantee by
	-- construction, exposing every control the spec's actionButtons names.
	local clientOverride: any = nil
	if type(spec) == "table" and type(spec.overrides) == "table" and type(spec.overrides.client) == "table" then
		local declared = spec.overrides.client
		-- The EFFECTIVE mode-specific owner: an override scoped to a mode applies only to that mode's
		-- pack, so the gate measures the HUD the pack actually binds. SurvivalHUD is the crafting
		-- bootstrap's interface; the default wave mode binds the kit's HUD.
		if declared.mode == nil or declared.mode == variant.mode then
			clientOverride = declared
		end
	end
	local hudKind = clientKind(clientEntry, if type(clientOverride) == "table" then clientOverride.module else nil)
	local clientPath = if #checks.clientEntries > 0 then packDir .. "/" .. checks.clientEntries[1] else nil
	local hudSource, hudPath = hudOwnerSource(
		hudKind,
		clientEntry,
		clientPath,
		registry,
		if type(clientOverride) == "table" then clientOverride.module else nil
	)
	local safeArea = hudSource ~= nil
		and string.find(hudSource, "CoreUISafeInsets", 1, true) ~= nil
		and string.find(hudSource, "SafeArea", 1, true) ~= nil
	-- Stable instance identities: QA and Studio address a control by exact Name, so
	-- the HUD owner must name its controls rather than leaving them anonymous. The
	-- kit names every action control after its declared id; an override module names
	-- its own.
	local stableNames = hudSource ~= nil
		and if hudKind == "core HUD kit client"
			then string.find(hudSource, ".Name = tostring(declaredControl.id)", 1, true) ~= nil
			else string.find(hudSource, ".Name = ", 1, true) ~= nil
	local playable = hudKind == "core HUD kit client"
		or hudKind == "genre runtime client"
		or hudKind == "pack-authored client"
	-- Instantiation, not declaration: the kit must visit every declared control and create it, so a
	-- control the spec declares but the HUD never renders cannot pass. The declared-id list above
	-- stays as static lint; this is the live-manifest half.
	local instantiated = true
	if hudKind == "core HUD kit client" and hudSource ~= nil then
		instantiated = string.find(hudSource, "for _, declaredControl in declared do", 1, true) ~= nil
			and string.find(hudSource, "ensureAction(declaredControl)", 1, true) ~= nil
	end
	local missingControls: { string } = {}
	for _, id in specControls do
		if not declaredIds[id] then
			table.insert(missingControls, id)
		end
	end
	table.sort(missingControls)
	local hudError: string? = nil
	-- Display text: the strings the HUD renders must be the spec's declared
	-- player-facing text, never an id or a locale key. HudText is the same pure
	-- module HudKit renders from, so this measures the real visible text rather
	-- than a copy of it, and it fails on the exact defect a raw-id HUD shows.
	local displayControls: { any } = if controls ~= nil and #controls > 0 then controls else genrespec.controls(spec)
	local displayPlan = HudText.plan(if type(spec) == "table" then spec else {}, displayControls)
	local hudTextErrors = HudText.violations(displayPlan)
	-- Readability is structural, not a matter of taste: every text the HUD draws sits
	-- on a chip or carries a stroke, and the theme's text/chip pairs clear the WCAG AA
	-- floor. The chip is declared by the HUD owner (HudKit passes `chip = true` for
	-- the objective) and the stroke every label carries lives in the shared
	-- Components module, so both are checked where they actually are.
	local hudContrastErrors = HudContrast.violations(Theme.default)
	-- Text fit is structural too: on the 390x844 phone every visual capture uses, an
	-- action label must fit the control the layout gives it. HudFit is the module
	-- HudKit lays the phone row out with, so this measures the real geometry: a
	-- label that needs more than its button is the overflow three 110px buttons
	-- showed in a live rpg-progression capture.
	local localeStrings = genrespec.localeTable(if type(spec) == "table" then spec else {})
	local packLocale = genrespec.localeDefault(spec)
	local actionLabels: { string } = {}
	for _, control in displayControls do
		if type(control) == "table" and control.kind ~= "prompt" then
			local key = nil
			for _, row in (if type(spec) == "table" and type(spec.actions) == "table" then spec.actions else {}) do
				if type(row) == "table" and type(row.control) == "table" and row.control.id == control.id then
					key = row.control.labelKey
				end
			end
			table.insert(actionLabels, HudText.localized(localeStrings, packLocale, key, tostring(control.label or "")))
		end
	end
	local hudFitErrors: { string } = if hudKind == "core HUD kit client"
		then HudFit.surfaceViolations(actionLabels)
		else {}
	-- One capture shows one language. The kit resolves every string through the pack's
	-- locale table at the pack's default locale, so the rendered set is measured here
	-- from the same table: a HUD that shows English resources beside Korean buttons is
	-- the defect this reports, and it is measured offline rather than by eye.
	local hudScriptErrors = HudText.mixedScript(HudText.displaySet(displayPlan, localeStrings, packLocale), packLocale)
	-- Text scale is structural too: a label that scales to its control must be capped by
	-- a UITextSizeConstraint, or it grows to fill the whole control (the survival-coop
	-- bag sheet rendered "Refresh supplies" and "Camera controls" at the button's own
	-- 48px height). Every module that renders a HUD label is measured - the kit, the
	-- shared Components factory, and the pack's and genre's own HUD modules - so a
	-- declared override HUD is held to the same rule as the kit.
	local scaleSources: { { label: string, source: string } } = {}
	if hudSource ~= nil then
		table.insert(scaleSources, { label = tostring(hudPath), source = hudSource })
	end
	if hudKind == "core HUD kit client" then
		local componentsPath = project.coreRoot(registry) .. "/ui-kit/Components.luau"
		if fs.isFile(componentsPath) then
			table.insert(scaleSources, { label = componentsPath, source = fs.readFile(componentsPath) })
		end
	end
	for _, file in hudModules(packDir) do
		table.insert(scaleSources, { label = file, source = fs.readFile(packDir .. "/" .. file) })
	end
	if genrePackage ~= nil then
		for _, file in hudModules(genrePackage.path) do
			table.insert(scaleSources, { label = file, source = fs.readFile(genrePackage.path .. "/" .. file) })
		end
	end
	local hudScaleErrors = HudScale.sourcesViolations(scaleSources)
	local strokedText = true
	if hudKind == "core HUD kit client" then
		local componentsPath = project.coreRoot(registry) .. "/ui-kit/Components.luau"
		local componentsStroke = fs.isFile(componentsPath)
			and string.find(fs.readFile(componentsPath), "UIStroke", 1, true) ~= nil
		local ownerChip = hudSource ~= nil and string.find(hudSource, "chip", 1, true) ~= nil
		strokedText = componentsStroke and ownerChip
	end
	if not playable then
		hudError = "generated client is the generic core debug panel; no HUD beyond the debug Snapshots panel"
	elseif not safeArea then
		hudError = "HUD owner declares no CoreUISafeInsets/SafeArea guarantee: " .. tostring(hudPath)
	elseif not instantiated then
		hudError = "HUD owner declares controls it never instantiates: " .. tostring(hudPath)
	elseif not stableNames then
		hudError = "HUD owner names no control, so no control has a stable Name: " .. tostring(hudPath)
	elseif not strokedText then
		hudError = "HUD owner draws text with no stroke/chip guarantee: " .. tostring(hudPath)
	elseif #missingControls > 0 then
		hudError = "controls not exposed: " .. table.concat(missingControls, ", ")
	elseif #hudTextErrors > 0 then
		hudError = "visible text shows raw identifiers: " .. hudTextErrors[1]
	elseif #hudContrastErrors > 0 then
		hudError = "HUD text is unreadable on its chip: " .. hudContrastErrors[1]
	elseif #hudFitErrors > 0 then
		hudError = "action label overflows its control: " .. hudFitErrors[1]
	elseif #hudScriptErrors > 0 then
		hudError = "HUD text is not one language: " .. hudScriptErrors[1]
	elseif #hudScaleErrors > 0 then
		hudError = "scaled HUD text has no size cap: " .. hudScaleErrors[1]
	end
	report.steps.hud = {
		ok = playable
			and safeArea
			and instantiated
			and stableNames
			and strokedText
			and #missingControls == 0
			and #hudTextErrors == 0
			and #hudContrastErrors == 0
			and #hudFitErrors == 0
			and #hudScriptErrors == 0
			and #hudScaleErrors == 0,
		client = hudKind,
		source = hudPath,
		safeArea = safeArea,
		instantiated = instantiated,
		stableNames = stableNames,
		controls = {
			count = #controlIds,
			ids = controlIds,
			actions = controlActions,
			manifest = manifest,
			missing = missingControls,
			error = controlError,
		},
		packHudModules = hudModules(packDir),
		genreHudModules = if genrePackage ~= nil then hudModules(genrePackage.path) else {},
		text = {
			ok = #hudTextErrors == 0,
			resources = #displayPlan.resources,
			controls = #displayControls,
			objectives = #displayPlan.objectives,
			errors = hudTextErrors,
		},
		contrast = {
			ok = #hudContrastErrors == 0,
			strokedText = strokedText,
			surfaces = #HudContrast.surfaces(Theme.default),
			errors = hudContrastErrors,
		},
		fit = {
			ok = #hudFitErrors == 0,
			viewport = HudFit.PHONE_VIEWPORT,
			room = HudFit.phoneRoom(HudFit.PHONE_VIEWPORT),
			labels = actionLabels,
			errors = hudFitErrors,
		},
		locale = {
			ok = #hudScriptErrors == 0,
			default = packLocale,
			keys = #genrespec.localeEntries(if type(spec) == "table" then spec else {}),
			errors = hudScriptErrors,
		},
		scale = {
			ok = #hudScaleErrors == 0,
			modules = #scaleSources,
			errors = hudScaleErrors,
		},
		error = hudError,
	}

	-- World: the built place must carry a playable world, not just parts. The gate
	-- is the spec's own plan: a part floor for the whole world and for every zone,
	-- ground under the spawn, and the baked lighting environment. A genre that
	-- declares a world override owns its own world builder, so its module is the
	-- evidence and the place parts are that builder's runtime output.
	local worldSpec: any = if type(spec) == "table" and type(spec.world) == "table" then spec.world else nil
	local spawnPoint = if worldSpec ~= nil then WorldKit.spawnPoint(worldSpec) else nil
	local clearanceVolume = if worldSpec ~= nil then WorldKit.clearanceVolume(worldSpec) else nil
	local approachVolumes = if worldSpec ~= nil then WorldKit.approachVolumes(worldSpec) else nil
	local worldReport = placeWorldReport(artifact, spawnPoint, clearanceVolume, approachVolumes)
	local worldParts = if worldReport ~= nil then worldReport.parts else nil
	-- A genre that declares a world override builds its world at runtime, so its
	-- place carries no world parts and the part floors cannot measure it. That is
	-- only true while the place really carries none: a pack whose place carries a
	-- baked world is measured like any other, which is what makes the generic
	-- survival pack prove it has a world rather than a starter floor.
	local worldOverride = type(spec) == "table" and type(spec.overrides) == "table" and spec.overrides.world ~= nil
	local runtimeWorld = worldOverride and (worldParts or 0) == 0
	local worldErrors: { string } = {}
	if worldReport == nil then
		table.insert(worldErrors, "no built place to count world parts")
	elseif #worldModules == 0 then
		table.insert(worldErrors, "the pack declares no world spec or world module")
	elseif not runtimeWorld then
		local worldFloor = if worldSpec ~= nil then WorldKit.minimumParts(worldSpec) else 1
		if worldParts < worldFloor then
			table.insert(
				worldErrors,
				string.format(
					"the built place carries %d world parts, below the %d this world needs",
					worldParts,
					worldFloor
				)
			)
		end
		if worldSpec ~= nil then
			for _, zone in worldSpec.zones do
				local zoneId = tostring(zone.id)
				local count = worldReport.zones[zoneId] or 0
				local zoneFloor = WorldKit.minimumZoneParts(worldSpec, zoneId)
				if count < zoneFloor then
					table.insert(
						worldErrors,
						string.format("zone %s carries %d parts, below its %d part floor", zoneId, count, zoneFloor)
					)
				end
			end
			if spawnPoint ~= nil and not worldReport.ground then
				table.insert(worldErrors, "no floor part covers the spawn: a player would stand in the sky")
			end
		end
		if not (worldReport.atmosphere and worldReport.sky) then
			table.insert(worldErrors, "the place carries no Atmosphere/Sky lighting environment")
		end
	end
	-- The baked environment colours must sit in the project file's 0..1 range: a
	-- 0..255 triple written straight through a Rojo `Color3` clamps every channel
	-- to 1 and renders the whole place flat white, which is a defect the presence
	-- checks above cannot see. This holds for any pack whose place carries the
	-- baked Lighting/Atmosphere - including a genre with a world override - so it
	-- is checked outside the override gate.
	if worldReport ~= nil then
		local outOfRange: { string } = {}
		for _, name in { "ambient", "outdoorAmbient", "atmosphereColor", "atmosphereDecay" } do
			local value = worldReport.lighting[name]
			if type(value) == "number" and value > 1 then
				table.insert(outOfRange, string.format("%s=%.3f", name, value))
			end
		end
		if #outOfRange > 0 then
			table.insert(
				worldErrors,
				"baked Lighting/Atmosphere colours exceed the 0..1 project range ("
					.. table.concat(outOfRange, ", ")
					.. "): a 0..255 triple renders clamped to pure white"
			)
		end
	end
	-- Spawn clearance: the default camera's own volume at spawn must be open. A solid
	-- block there fills the first frame a player ever sees, which is a defect the part
	-- floors, the ground check and the environment check cannot see. Measured on the
	-- built place when it carries a world, and on the spec's plan otherwise - the same
	-- volume both the bake and the runtime world are built from.
	--
	-- A genre whose world is a declared override builds its own world, and its place
	-- carries none of the kit's: neither the built place nor the spec's plan describes
	-- what ships, so the pack's own world module and scenarios are the evidence.
	local occluders: { string } = {}
	if not runtimeWorld then
		if worldReport ~= nil and #(worldReport.clearance or {}) > 0 then
			for _, name in worldReport.clearance do
				table.insert(occluders, tostring(name))
			end
		elseif worldSpec ~= nil then
			for _, entry in WorldKit.clearanceViolations(worldSpec) do
				table.insert(occluders, entry.name)
			end
		end
	end
	if #occluders > 0 then
		table.sort(occluders)
		table.insert(worldErrors, "the spawn view is occluded by " .. table.concat(occluders, ", "))
	end
	-- A node's approach corridor is the same contract for every interactive node: a
	-- decor prop or a landmark in it hides the node (and the character) from the
	-- camera that walks up to it. Measured the same way, and skipped for the same
	-- reason, as the spawn clearance above.
	local approachBlocked: { string } = {}
	if not runtimeWorld then
		if worldReport ~= nil and #(worldReport.approach or {}) > 0 then
			for _, name in worldReport.approach do
				table.insert(approachBlocked, tostring(name))
			end
		elseif worldSpec ~= nil and (worldReport == nil or (worldReport.parts or 0) == 0) then
			for _, entry in WorldKit.approachViolations(worldSpec) do
				table.insert(approachBlocked, string.format("%s at node %s", entry.name, entry.node))
			end
		end
	end
	if #approachBlocked > 0 then
		table.sort(approachBlocked)
		table.insert(worldErrors, "a node approach corridor is blocked by " .. table.concat(approachBlocked, ", "))
	end
	-- A solid decorative or landmark part must stay queryable: the default camera's
	-- occlusion handling answers CanQuery=false with nothing, so an unqueryable
	-- solid prop lets the camera sit behind it and hide the character.
	if worldReport ~= nil and #(worldReport.unqueryable or {}) > 0 then
		local names = table.clone(worldReport.unqueryable)
		table.sort(names)
		table.insert(
			worldErrors,
			"a solid decor/landmark part is unqueryable, so the camera cannot pop in front of it: "
				.. table.concat(names, ", ")
		)
	end
	report.steps.world = {
		ok = #worldErrors == 0,
		modules = worldModules,
		placeParts = worldParts,
		parts = if worldReport ~= nil then worldReport.parts else nil,
		roles = if worldReport ~= nil then worldReport.roles else nil,
		zones = if worldReport ~= nil then worldReport.zones else nil,
		ground = if worldReport ~= nil then worldReport.ground else nil,
		atmosphere = if worldReport ~= nil then worldReport.atmosphere else nil,
		sky = if worldReport ~= nil then worldReport.sky else nil,
		lighting = if worldReport ~= nil then worldReport.lighting else nil,
		clearance = if worldReport ~= nil then worldReport.clearance else nil,
		approach = if worldReport ~= nil then worldReport.approach else nil,
		errors = worldErrors,
		error = firstError(worldErrors),
	}

	-- Audio: every bound action/event must resolve to a cue the spec declares and
	-- the pack actually renders.
	local cueKeys: { [string]: boolean } = {}
	local packCues: { string } = {}
	local audioPath = packDir .. "/assets/audio.yml"
	if fs.isFile(audioPath) then
		local decodedOk, decoded = pcall(function()
			return serde.decode("yaml", fs.readFile(audioPath))
		end)
		if decodedOk and type(decoded) == "table" and type(decoded.cues) == "table" then
			for _, cue in decoded.cues do
				if type(cue) == "table" and type(cue.key) == "string" then
					cueKeys[cue.key] = true
					table.insert(packCues, cue.key)
				end
			end
		end
	end
	table.sort(packCues)
	local specCues: { string } = {}
	local specCueSet: { [string]: boolean } = {}
	local audio: any = if type(spec) == "table" then spec.audio else nil
	if type(audio) == "table" and type(audio.cues) == "table" then
		for _, cue in audio.cues do
			if type(cue) == "table" and type(cue.key) == "string" then
				specCueSet[cue.key] = true
				table.insert(specCues, cue.key)
			end
		end
	end
	table.sort(specCues)
	local audioErrors: { string } = {}
	for _, key in specCues do
		if not cueKeys[key] then
			table.insert(audioErrors, "cue " .. key .. " is not declared by the pack's assets/audio.yml")
		end
	end
	if type(audio) == "table" and type(audio.bindings) == "table" then
		for _, binding in audio.bindings do
			local cue = if type(binding) == "table" then binding.cue else nil
			if type(cue) ~= "string" or not specCueSet[cue] then
				table.insert(audioErrors, "binding " .. tostring(binding.on) .. " has no declared cue")
			end
		end
	end
	if #specCues == 0 then
		table.insert(audioErrors, "the spec declares no audio cues")
	end
	local audioOk = #audioErrors == 0
	-- Declared is not playable: a cue whose published asset id is absent is silent, and silence must
	-- not read as an audio PASS. The pack's own Assets table is the authority on what ships - a local
	-- `rbxasset://` path is not a playback id for a published experience.
	local playableCues: { string } = {}
	local silentCues: { string } = {}
	local assetsPath = packDir .. "/src/shared/Assets.luau"
	if fs.isFile(assetsPath) then
		local assetsOk, assetsTable = pcall(function()
			return luau.load(fs.readFile(assetsPath))()
		end)
		if assetsOk and type(assetsTable) == "table" then
			for _, key in specCues do
				local value = assetsTable[key]
				if type(value) == "string" and string.match(value, "^rbxassetid://[1-9]%d*$") ~= nil then
					table.insert(playableCues, key)
				else
					table.insert(silentCues, key)
				end
			end
		end
	end
	local playableOk = audioOk and #specCues > 0 and #silentCues == 0
	report.steps.audio = {
		ok = audioOk,
		-- Two separate verdicts: declarations valid, and published audio playable. Silence is an
		-- accepted private-playtest limitation, recorded as such - never an audio PASS.
		playable = playableOk,
		verdict = if playableOk then "playable" elseif audioOk then "declared-only" else "invalid",
		acceptedLimitation = audioOk and not playableOk,
		cues = specCues,
		packCues = packCues,
		playableCues = playableCues,
		silentCues = silentCues,
		errors = audioErrors,
		error = if audioOk then nil else firstError(audioErrors),
	}

	-- Surface: the conjunction the design's §5.1 defines.
	local surfaceOk = report.steps.hud.ok and report.steps.world.ok and audioOk and #unmatched == 0
	local surfaceError: string? = nil
	if not surfaceOk then
		if not report.steps.hud.ok then
			surfaceError = hudError
		elseif not report.steps.world.ok then
			surfaceError = firstError(worldErrors)
		elseif not audioOk then
			surfaceError = firstError(audioErrors)
		else
			surfaceError = "unmatched control targets: " .. table.concat(unmatched, ", ")
		end
	end
	report.steps.surface = {
		ok = surfaceOk,
		error = surfaceError,
		controls = {
			count = #controlIds,
			ids = controlIds,
			actions = controlActions,
			manifest = manifest,
			error = controlError,
		},
		referenced = { count = #referencedList, targets = referencedList },
		unmatchedTargets = unmatched,
		hud = { client = hudKind, source = hudPath, safeArea = safeArea },
		world = { modules = worldModules, placeParts = worldParts },
		audio = { cues = specCues, packCues = packCues },
	}
	-- Load: the headless 8-actor proof over the pack's own golden path. It drives
	-- the real Session/Executor with no Studio and no clock sleep, so it is
	-- deterministic and runs in the same pass as every other column.
	local loadResult: any = nil
	local loadError: string? = nil
	if qaTarget == nil and type(assembly.pack) == "table" then
		-- A legacy pack carries no genre_contract document, so the load proof runs
		-- the same validated pack config the native-QA step used. Its playable loop
		-- is engine-side, so the step records that this is the contract runtime.
		local contracts: { any } = {}
		for _, id in assembly.order do
			table.insert(contracts, registry.runtimes[id])
		end
		qaTarget = {
			packConfig = assembly.pack,
			contracts = contracts,
			controls = {},
			storeName = string.sub(variant.slug, 1, 40) .. "-load",
		}
	end
	if qaTarget == nil then
		loadError = "no QA target for the generated pack"
	else
		local scenario, scenarioReason =
			loadproof.scenarioFor(packDir, variant.slug, registry.packages[variant.id].spec, variant.id, variant.mode)
		if scenario == nil then
			loadError = scenarioReason
		else
			local ran, outcome = pcall(loadproof.run, {
				target = qaTarget,
				scenario = scenario,
				actors = loadproof.DEFAULT_ACTORS,
				storeName = string.sub(variant.slug, 1, 32) .. "-load",
			})
			if not ran then
				loadError = firstLine(outcome)
			else
				loadResult = outcome
				if not outcome.ok then
					loadError = outcome.failures[1] or "a load invariant failed"
				end
			end
		end
	end
	report.steps.load = {
		ok = loadResult ~= nil and loadResult.ok == true,
		actors = if loadResult ~= nil then loadResult.actors else 0,
		actions = if loadResult ~= nil then loadResult.actions else 0,
		invariants = if loadResult ~= nil then loadResult.invariants else nil,
		failures = if loadResult ~= nil then loadResult.failures else {},
		-- A legacy pack's playable loop is engine-side, so its proof drives the
		-- genre's contract runtime rather than the hand-authored pack.
		runtime = if assembly.legacy then "legacy-contract" else "generated-pack",
		error = loadError,
	}

	-- Quality: a generated pack declares the starter tier, and the receipt this
	-- run records is the mechanical evidence above plus the load proof. It never
	-- approves fun or visual quality - those stay a human decision - and the
	-- column passes only when the receipt is valid for the declared tier.
	local qualityOk = false
	local qualityError: string? = nil
	local qualityTier: string? = nil
	local qualityReport: any = nil
	local qualityReceiptPath = outDir .. "/quality/" .. variant.slug .. ".json"
	local qualityPath = packDir .. "/quality.yml"
	if not fs.isFile(qualityPath) then
		qualityError = "the generated pack carries no quality.yml"
	else
		local decodedOk, document = pcall(function()
			return serde.decode("yaml", fs.readFile(qualityPath))
		end)
		local profile: any = nil
		local profileErrors: { string } = {}
		if decodedOk then
			profile, profileErrors = qualityprofile.parse(document)
		else
			profileErrors = { "quality.yml: failed to decode: " .. firstLine(document) }
		end
		if profile == nil then
			qualityError = firstError(profileErrors)
		else
			qualityTier = profile.tier
			local columns: { [string]: any } = {}
			for _, name in M.STEP_NAMES do
				if name ~= "quality" then
					local step = report.steps[name]
					columns[name] = {
						ok = step ~= nil and step.ok == true,
						error = if step ~= nil then step.error else "step not recorded",
					}
				end
			end
			columns.load = { ok = report.steps.load.ok == true, error = report.steps.load.error }
			local nativeStep = report.steps.nativeQa
			local receipt = qualityevidence.build({
				pack = variant.slug,
				tier = profile.tier,
				profileDigest = qualityevidence.profileDigest(profile),
				columns = columns,
				captures = {
					present = false,
					reason = "the sweep runs headless; a Studio capture run records its manifest separately",
				},
				av = { present = false, reason = "no captured session in a headless sweep" },
				nativeQa = {
					ran = nativeStep.ran,
					passed = nativeStep.passed,
					skipped = nativeStep.skipped == true,
				},
				load = {
					ok = report.steps.load.ok == true,
					actors = report.steps.load.actors,
					actions = report.steps.load.actions,
					runtime = report.steps.load.runtime,
				},
			})
			local receiptErrors = qualityevidence.validate(receipt, profile)
			qualityReport = receipt
			if #receiptErrors > 0 then
				qualityError = firstError(receiptErrors)
			else
				ensureDir(outDir .. "/quality")
				fs.writeFile(qualityReceiptPath, serde.encode("json", receipt, true) .. "\n")
				qualityOk = true
			end
		end
	end
	report.steps.quality = {
		ok = qualityOk,
		tier = qualityTier,
		receipt = if qualityOk then qualityReceiptPath else nil,
		receiptPath = qualityReceiptPath,
		humanJudgment = qualityevidence.PENDING,
		columns = if qualityReport ~= nil then qualityReport.columns else nil,
		error = qualityError,
	}

	report.ok = true
	for _, name in M.STEP_NAMES do
		local step = report.steps[name]
		if step == nil or not step.ok then
			report.ok = false
		end
	end
	return report
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

function M.stamp(): string
	return os.date("!%Y%m%dT%H%M%SZ")
end

function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local argv = args or process.args
	local options, parseError = M.parseArgs(argv)
	if options == nil then
		stdio.ewrite("sweep: " .. tostring(parseError) .. "\n")
		return false
	end
	local registry, registryErrors = registryLib.discover(if context then context.genresDir else nil)
	if not registry then
		stdio.ewrite(table.concat(registryErrors, "\n") .. "\n")
		return false
	end
	local selected: { [string]: boolean }? = nil
	if options.genres ~= nil then
		local target: { [string]: boolean } = {}
		for _, id in options.genres do
			target[id] = true
		end
		selected = target
	end
	local variants, selectionErrors = M.variants(registry, selected)
	if #selectionErrors > 0 then
		for _, err in selectionErrors do
			stdio.ewrite("sweep: " .. err .. "\n")
		end
		return false
	end
	if #variants == 0 then
		stdio.ewrite("sweep: no genres to sweep\n")
		return false
	end

	local stamp = M.stamp()
	local outDir = options.out or (M.DEFAULT_OUT_ROOT .. "/" .. stamp)
	local packsDir = outDir .. "/packs"
	-- The scratch packs root is the sweep's own output, and a stale pack from an
	-- earlier run into the same directory is not this run's evidence: the crafting
	-- generator preserves an existing authored client, so a leftover
	-- `src/client/*.client.luau` from a previous sweep silently kept the old client
	-- (and its old locale) while every other file was regenerated. Start clean.
	if fs.isDir(packsDir) then
		fs.removeDir(packsDir)
	end
	ensureDir(packsDir)
	local sweepContext: cliutil.CommandContext = {
		packsDir = packsDir,
		genresDir = if context then context.genresDir else nil,
		reportsDir = outDir,
	}

	local command = "lune run cli/forge sweep"
	if options.genres ~= nil then
		command ..= " --genres " .. table.concat(options.genres, ",")
	end
	if options.out ~= nil then
		command ..= " --out " .. options.out
	end

	local reports: { Report } = {}
	for _, variant in variants do
		stdio.write("sweep: " .. variant.label .. "\n")
		local report = M.runVariant(variant, registry, sweepContext, packsDir, outDir)
		table.insert(reports, report)
		stdio.write(string.format("sweep: %s %s\n", variant.label, if report.ok then "PASS" else "FAIL"))
	end

	local summary = M.summarize(reports)
	fs.writeFile(outDir .. "/sweep.json", serde.encode("json", {
		stamp = stamp,
		command = command,
		genres = reports,
		summary = summary,
	}, true) .. "\n")
	fs.writeFile(outDir .. "/sweep.md", M.renderMarkdown(summary, reports, stamp))
	stdio.write(string.format("sweep: %d/%d genres fully passed; report %s\n", summary.passed, summary.total, outDir))
	return summary.failed == 0
end

return M
