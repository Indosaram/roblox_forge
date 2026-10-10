--!strict
-- buildtargets: the shared build/inspect target matrix used by
-- `forge build` and the default `forge check`.
--
-- One resolver answers "which places does this command produce and verify?"
-- for every selector form:
--   * no selector      - the default single pack (build) or every pack (check)
--   * --all            - every declared pack under the packs root
--   * --pack <slug>    - exactly one declared pack
--   * --project <path> - one rojo project file, with no pack config invented
--   * --packs-root <d> - swap the discovery root (QA fixture matrices)
--
-- A declared pack is a directory that has BOTH game.yml and
-- default.project.json. A directory that has only one of the two is a partial
-- pack: it is reported as an error rather than silently omitted, so a pack
-- that loses its project file cannot quietly stop being verified.
--
-- Running a target always: deletes any previous artifact, builds with rojo,
-- hashes the file that was actually produced, and inspects only that fresh
-- file against expectations derived from the target's own project. A failed
-- build leaves no artifact behind and is never inspected, so a stale place
-- from an earlier run can never report a pass.

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local run = require("./run")
local inspector = require("./inspect")
local packidentity = require("./packidentity")
local buildidentity = require("./buildidentity")
local packpublication = require("./packpublication")

local M = {}

M.DEFAULT_PACKS_ROOT = "games"
M.DEFAULT_PACK = "kaiju-egg-raiders"
M.BUILD_DIR = "build"

export type FsLike = {
	isDir: (string) -> boolean,
	isFile: (string) -> boolean,
	readDir: (string) -> { string },
	readFile: (string) -> string,
}

export type Selection = {
	mode: "default" | "all" | "pack" | "project",
	pack: string?,
	projectPath: string?,
	packsRoot: string,
	packsRootExplicit: boolean,
}

export type Target = {
	kind: "pack" | "project",
	slug: string,
	packDir: string?,
	projectPath: string,
	outputPath: string,
}

export type Expectation = { path: string, expected: string }

export type TargetResult = {
	target: Target,
	revision: string,
	built: boolean,
	ok: boolean,
	digest: string?,
	buildIdentity: any?,
	resolvedRequiresCount: number,
	removedStale: boolean,
	logs: { string },
	errors: { string },
}

local function realFs(): FsLike
	return {
		isDir = fs.isDir,
		isFile = fs.isFile,
		readDir = fs.readDir,
		readFile = fs.readFile,
	}
end

local function trim(text: string): string
	return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

local function normalizePath(path: string): string
	local normalized = string.gsub(path, "\\", "/")
	while #normalized > 1 and string.sub(normalized, -1) == "/" do
		normalized = string.sub(normalized, 1, -2)
	end
	return normalized
end

local function lastSegment(path: string): string
	local normalized = normalizePath(path)
	return string.match(normalized, "([^/]+)$") or normalized
end

local function parentDir(path: string): string
	local normalized = normalizePath(path)
	return string.match(normalized, "^(.*)/[^/]+$") or "."
end

--- Lowercases `name` and replaces every character outside [a-z0-9-] so it can
--- be used as a single path segment. This is a *readability* transform only:
--- it is not injective (`a_b`, `a-b` and `A-B` all collapse together), so
--- every caller pairs it with `pathTag` below to reduce collision risk.
function M.sanitizeSegment(name: string): string
	local lowered = string.lower(name)
	local cleaned = string.gsub(lowered, "[^%w%-]", "-")
	cleaned = string.gsub(cleaned, "%-+", "-")
	cleaned = string.gsub(cleaned, "^%-", "")
	cleaned = string.gsub(cleaned, "%-$", "")
	return if cleaned == "" then "target" else cleaned
end

--- A deterministic tag for the normalized path: the first 40 bits of sha256.
--- This separates the known sanitized-path collisions, but does not guarantee
--- injectivity for arbitrary paths.
function M.pathTag(path: string): string
	return string.sub(serde.hash("sha256", normalizePath(path)), 1, 10)
end

--- Where a pack's place file is written. The default packs root keeps the
--- historical `build/<slug>.rbxl` path (so `build/kaiju-egg-raiders.rbxl`
--- stays exactly where every other tool expects it); any other packs root
--- writes under a directory keyed by that root's path tag. This separates
--- similarly spelled roots, subject to the tag's collision risk.
function M.packOutputPath(packsRoot: string, slug: string): string
	local root = normalizePath(packsRoot)
	if root == M.DEFAULT_PACKS_ROOT then
		return M.BUILD_DIR .. "/" .. slug .. ".rbxl"
	end
	return string.format(
		"%s/packs-%s-%s/%s.rbxl",
		M.BUILD_DIR,
		M.sanitizeSegment(lastSegment(root)),
		M.pathTag(root),
		slug
	)
end

--- Where a bare `--project` target's place file is written. Keyed by the hash
--- of the whole normalized project path, so two project files in the same
--- directory (`a/default.project.json`, `a/other.project.json`) and two
--- similarly-spelled directories are separated, subject to tag collision risk.
function M.projectOutputPath(projectPath: string): string
	local path = normalizePath(projectPath)
	return string.format(
		"%s/project-%s-%s.rbxl",
		M.BUILD_DIR,
		M.sanitizeSegment(lastSegment(parentDir(path))),
		M.pathTag(path)
	)
end

-- ---------------------------------------------------------------------------
-- Selector parsing (pure)
-- ---------------------------------------------------------------------------

local function optionValue(args: { string }, index: number, flag: string): (string?, string?)
	local value = args[index + 1]
	if value == nil or value == "" or string.sub(value, 1, 2) == "--" then
		return nil, flag .. " requires a value"
	end
	return value, nil
end

--- Parses the target selectors out of `args`, starting at `startIndex`
--- (1-based; commands pass 2 to skip their own verb). Returns (nil, reason)
--- for an unknown option, a missing value, an invalid slug/project path, or
--- two target selectors at once.
function M.parseSelectors(args: { string }, startIndex: number?): (Selection?, string?)
	local selection: Selection = {
		mode = "default",
		pack = nil,
		projectPath = nil,
		packsRoot = M.DEFAULT_PACKS_ROOT,
		packsRootExplicit = false,
	}
	local chosen: string? = nil
	local index = startIndex or 1
	while index <= #args do
		local arg = args[index]
		if arg == "--all" or arg == "--pack" or arg == "--project" then
			if chosen ~= nil then
				return nil, string.format("duplicate target selector: %s cannot be combined with %s", arg, chosen)
			end
		end
		if arg == "--all" then
			chosen = arg
			selection.mode = "all"
			index += 1
		elseif arg == "--pack" then
			local value, err = optionValue(args, index, arg)
			if value == nil then
				return nil, err
			end
			if not packidentity.isValidSlug(value) then
				return nil, "invalid pack slug '" .. value .. "'"
			end
			chosen = arg
			selection.mode = "pack"
			selection.pack = value
			index += 2
		elseif arg == "--project" then
			local value, err = optionValue(args, index, arg)
			if value == nil then
				return nil, err
			end
			if string.match(value, "%.project%.json$") == nil then
				return nil, "--project requires a path to a *.project.json file, got '" .. value .. "'"
			end
			chosen = arg
			selection.mode = "project"
			selection.projectPath = normalizePath(value)
			index += 2
		elseif arg == "--packs-root" then
			local value, err = optionValue(args, index, arg)
			if value == nil then
				return nil, err
			end
			if selection.packsRootExplicit then
				return nil, "duplicate --packs-root"
			end
			selection.packsRoot = normalizePath(value)
			selection.packsRootExplicit = true
			index += 2
		else
			return nil, "unknown option '" .. tostring(arg) .. "'"
		end
	end
	if selection.mode == "project" and selection.packsRootExplicit then
		return nil, "--packs-root cannot be combined with --project"
	end
	return selection, nil
end

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------

--- The first line of `value` rendered as text. Decode failures arrive as a
--- multi-line Luau error with a stack traceback; only the reason belongs in a
--- per-target report line.
local function firstLine(value: any): string
	local text = tostring(value)
	return string.match(text, "^[^\r\n]+") or text
end

--- Why `gamePath` is not a usable pack declaration, or nil when it is. A pack
--- is only eligible when its game.yml actually decodes to a YAML mapping with
--- a name: a valid rojo project next to an unreadable or malformed game.yml is
--- a malformed pack, not an eligible target.
function M.gameDeclarationError(io: FsLike, gamePath: string): string?
	local readOk, text = pcall(io.readFile, gamePath)
	if not readOk then
		return gamePath .. ": could not be read: " .. firstLine(text)
	end
	local decodeOk, decoded = pcall(function()
		return serde.decode("yaml", text)
	end)
	if not decodeOk then
		return gamePath .. ": is not valid YAML: " .. firstLine(decoded)
	end
	if typeof(decoded) ~= "table" then
		return gamePath .. ": does not declare a mapping"
	end
	local name = (decoded :: any).name
	if typeof(name) ~= "string" or name == "" then
		return gamePath .. ": declares no name"
	end
	return nil
end

--- Lists every declared pack under `packsRoot`, plus one error per malformed
--- directory. A directory is a declared pack when it has game.yml; from there
--- it must also have a default.project.json AND a game.yml that decodes to a
--- named mapping. A partial or malformed pack is reported as an error instead
--- of being dropped, so a pack that loses its project file or gains a YAML
--- syntax error cannot quietly stop being verified: a valid rojo project is
--- not on its own enough to make a pack eligible. Valid targets are still
--- returned alongside the errors, so the caller can build/inspect them and
--- aggregate every independent outcome.
function M.discover(packsRoot: string, fsImpl: FsLike?): ({ Target }, { string })
	local io = fsImpl or realFs()
	local root = normalizePath(packsRoot)
	local targets: { Target } = {}
	if not io.isDir(root) then
		return targets, { "packs root does not exist: " .. root }
	end
	local names = io.readDir(root)
	table.sort(names)
	local errors: { string } = {}
	for _, name in names do
		local dir = root .. "/" .. name
		if io.isDir(dir) then
			local pending = packpublication.pending(dir, io)
			if pending then
				table.insert(errors, dir .. ": " .. pending)
				continue
			end
			local gamePath = dir .. "/game.yml"
			local hasGame = io.isFile(gamePath)
			local hasProject = io.isFile(dir .. "/default.project.json")
			if hasGame and hasProject then
				local declarationError = M.gameDeclarationError(io, gamePath)
				if declarationError ~= nil then
					table.insert(errors, declarationError)
				else
					table.insert(targets, {
						kind = "pack" :: "pack",
						slug = name,
						packDir = dir,
						projectPath = dir .. "/default.project.json",
						outputPath = M.packOutputPath(root, name),
					})
				end
			elseif hasGame then
				table.insert(errors, dir .. ": declares game.yml but has no default.project.json")
			elseif hasProject then
				table.insert(errors, dir .. ": declares default.project.json but has no game.yml")
			end
		end
	end
	if #targets == 0 and #errors == 0 then
		table.insert(errors, "no declared packs found under " .. root)
	end
	return targets, errors
end

--- Turns a parsed selection into the exact target list to build and inspect,
--- plus any resolution errors. `defaultMode` decides what "no selector" means:
--- "single" (forge build) uses the default pack, "all" (forge check) uses
--- every declared pack. Errors come back beside the resolvable targets so one
--- malformed pack fails the run without hiding the rest of the matrix.
function M.resolveTargets(
	selection: Selection,
	defaultMode: ("single" | "all")?,
	fsImpl: FsLike?
): ({ Target }, { string })
	local io = fsImpl or realFs()
	local mode = selection.mode
	if mode == "default" then
		mode = if (defaultMode or "single") == "all" then "all" else "pack"
	end

	if mode == "project" then
		local projectPath = selection.projectPath :: string
		local pending = packpublication.pending(parentDir(projectPath), io)
		if pending then
			return {}, { projectPath .. ": " .. pending }
		end
		if not io.isFile(projectPath) then
			return {}, { "project file does not exist: " .. projectPath }
		end
		return {
			{
				kind = "project" :: "project",
				slug = M.sanitizeSegment(lastSegment(parentDir(projectPath))),
				packDir = nil,
				projectPath = projectPath,
				outputPath = M.projectOutputPath(projectPath),
			},
		}, {}
	end

	local discovered, errors = M.discover(selection.packsRoot, io)
	if mode == "all" then
		return discovered, errors
	end

	local wanted = if selection.pack ~= nil then selection.pack else M.DEFAULT_PACK
	local available: { string } = {}
	for _, target in discovered do
		if target.slug == wanted then
			return { target }, errors
		end
		table.insert(available, target.slug)
	end
	table.insert(
		errors,
		string.format(
			"no declared pack '%s' under %s (available: %s)",
			wanted,
			selection.packsRoot,
			table.concat(available, ", ")
		)
	)
	return {}, errors
end

-- ---------------------------------------------------------------------------
-- Project-derived inspection expectations
-- ---------------------------------------------------------------------------

local SKIPPED_CLASSES: { [string]: boolean } = { Folder = true, DataModel = true }

--- Derives the instances a built place must contain from the target's own
--- rojo project: every `$path` to a .luau file becomes its script class, and
--- every explicitly classed leaf (RemoteFunction, RemoteEvent, Lighting, ...)
--- must exist with that class. A project that declares neither is rejected
--- rather than inspected vacuously.
function M.expectedInstances(projectText: string, projectPath: string): ({ Expectation }?, string?)
	local decodeOk, doc = pcall(function()
		return serde.decode("json", projectText)
	end)
	if not decodeOk or typeof(doc) ~= "table" or typeof(doc.tree) ~= "table" then
		return nil, projectPath .. ": not a decodable rojo project file"
	end
	local expected: { Expectation } = {}
	local function collect(node: any, path: string)
		if typeof(node) ~= "table" then
			return
		end
		local nodePath = node["$path"]
		local className = node["$className"]
		if typeof(nodePath) == "string" and string.match(nodePath, "%.luau$") ~= nil then
			local class = if string.match(nodePath, "%.server%.luau$") ~= nil
				then "Script"
				elseif string.match(nodePath, "%.client%.luau$") ~= nil then "LocalScript"
				else "ModuleScript"
			table.insert(expected, { path = path, expected = class })
		elseif nodePath == nil and typeof(className) == "string" and not SKIPPED_CLASSES[className] then
			table.insert(expected, { path = path, expected = className })
		end
		for name, child in node do
			if typeof(name) == "string" and string.sub(name, 1, 1) ~= "$" then
				collect(child, if path == "" then name else path .. "." .. name)
			end
		end
	end
	collect(doc.tree, "")
	if #expected == 0 then
		return nil, projectPath .. ": project declares no script entrypoints or typed instances"
	end
	table.sort(expected, function(a, b)
		return a.path < b.path
	end)
	return expected, nil
end

-- ---------------------------------------------------------------------------
-- Running the matrix
-- ---------------------------------------------------------------------------

local cachedHead: string? = nil
local cachedDirty: boolean? = nil

local function headRevision(): string
	if cachedHead == nil then
		local res = run.exec("git", { "rev-parse", "--short=12", "HEAD" })
		local value = trim(res.stdout)
		cachedHead = if res.ok and value ~= "" then value else "unknown"
	end
	return cachedHead :: string
end

--- The revision an artifact built now comes from: the repository revision,
--- marked `-dirty` when the worktree has uncommitted changes. The scope is the
--- whole worktree on purpose - a place file is built from the pack *and* from
--- core/genres/project sources, so a pack-only scope would label an artifact
--- with a revision that does not reproduce it.
function M.targetRevision(_target: Target?): string
	if cachedDirty == nil then
		local res = run.exec("git", { "status", "--porcelain" })
		cachedDirty = res.ok and trim(res.stdout) ~= ""
	end
	return headRevision() .. (if cachedDirty then "-dirty" else "")
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

--- Builds and inspects one target. Any previous artifact at the output path is
--- deleted first and, when the build fails, no artifact is left behind: a
--- failed target is never inspected and can never report a stale pass.
function M.runTarget(target: Target, ownedQaToken: string?): TargetResult
	local result: TargetResult = {
		target = target,
		revision = "unknown",
		built = false,
		ok = false,
		digest = nil,
		resolvedRequiresCount = 0,
		removedStale = false,
		logs = {},
		errors = {},
	}

	local pending = packpublication.pending(target.packDir or parentDir(target.projectPath))
	if pending then
		table.insert(result.errors, target.slug .. ": " .. pending)
		return result
	end
	local ready, prerequisiteError = run.preflight({ "rojo" })
	if not ready then
		table.insert(result.errors, tostring(prerequisiteError))
		return result
	end
	result.revision = M.targetRevision(target)
	ensureDir(parentDir(target.outputPath))
	if fs.isFile(target.outputPath) then
		fs.removeFile(target.outputPath)
		result.removedStale = true
	end

	local identityPath = target.outputPath .. ".identity.json"
	if fs.isFile(identityPath) then
		fs.removeFile(identityPath)
	end
	local prepared, overlay =
		pcall(buildidentity.prepare, target.projectPath, target.packDir, target.outputPath, ownedQaToken)
	if not prepared then
		table.insert(result.errors, target.slug .. ": build identity failed: " .. tostring(overlay))
		return result
	end
	result.buildIdentity = overlay.identity
	local invoked, res = pcall(run.exec, "rojo", { "build", overlay.projectPath, "-o", target.outputPath })
	local cleaned, cleanupError = pcall(fs.removeDir, overlay.directory)
	if not cleaned then
		table.insert(result.errors, target.slug .. ": identity overlay cleanup failed: " .. tostring(cleanupError))
		if fs.isFile(target.outputPath) then
			local removed, removeError = pcall(fs.removeFile, target.outputPath)
			if not removed then
				table.insert(result.errors, "artifact cleanup failed: " .. tostring(removeError))
			end
		end
		return result
	end
	if not invoked then
		table.insert(result.errors, target.slug .. ": rojo invocation failed: " .. tostring(res))
		if fs.isFile(target.outputPath) then
			fs.removeFile(target.outputPath)
		end
		return result
	end
	local output = trim(res.stdout)
	local errOutput = trim(res.stderr)
	if errOutput ~= "" then
		output = if output == "" then errOutput else output .. "\n" .. errOutput
	end
	if output ~= "" then
		table.insert(result.logs, output)
	end

	if not res.ok then
		table.insert(result.errors, target.slug .. ": rojo build failed for " .. target.projectPath)
		if fs.isFile(target.outputPath) then
			fs.removeFile(target.outputPath)
		end
		return result
	end
	if not fs.isFile(target.outputPath) then
		table.insert(result.errors, target.slug .. ": rojo reported success but wrote no " .. target.outputPath)
		return result
	end

	result.built = true
	local artifact = fs.readFile(target.outputPath)
	local inspected, matches = pcall(buildidentity.inspectArtifact, artifact, overlay.identity, overlay.ownedQaToken)
	if not inspected or not matches then
		table.insert(result.errors, target.slug .. ": emitted identity source mismatch")
		fs.removeFile(target.outputPath)
		result.built = false
		return result
	end
	result.digest = serde.hash("sha256", artifact)
	local currentOk, current = pcall(buildidentity.snapshot, target.projectPath, target.packDir, target.outputPath)
	if not currentOk or current.id ~= overlay.identity.id then
		table.insert(result.errors, target.slug .. ": build inputs changed during Rojo build")
		fs.removeFile(target.outputPath)
		result.built = false
		return result
	end

	local projectReadOk, projectText = pcall(fs.readFile, target.projectPath)
	if not projectReadOk then
		table.insert(result.errors, target.slug .. ": could not read " .. target.projectPath)
		return result
	end
	local expected, expectErr = M.expectedInstances(projectText, target.projectPath)
	if expected == nil then
		table.insert(result.errors, target.slug .. ": " .. tostring(expectErr))
		return result
	end

	table.insert(expected, { path = "ServerScriptService.ForgeBuildIdentity", expected = "Script" })
	table.insert(expected, { path = "StarterPlayer.StarterPlayerScripts.ForgeBuildIdentity", expected = "LocalScript" })
	local inspectRes = inspector.inspectPlaceFile(target.outputPath, expected)
	result.resolvedRequiresCount = inspectRes.resolvedRequiresCount
	if not inspectRes.ok then
		for _, err in inspectRes.errors do
			table.insert(result.errors, target.slug .. ": " .. err)
		end
		return result
	end

	fs.writeFile(
		identityPath,
		serde.encode("json", {
			schemaVersion = 1,
			identity = overlay.identity,
			build = "sha256:" .. (result.digest :: string),
			revision = result.revision,
			ownedQaToken = overlay.ownedQaToken,
		}, true)
	)
	result.ok = true
	return result
end

--- Runs every target, independently: one failing target never stops the rest,
--- and every target is reported.
function M.runTargets(targets: { Target }): { TargetResult }
	local results: { TargetResult } = {}
	for _, target in targets do
		table.insert(results, M.runTarget(target))
	end
	return results
end

--- One build line per target, naming the project and the revision it was
--- built from plus the digest of the artifact that was actually produced.
function M.formatBuild(result: TargetResult): string
	local status = if result.built then "PASS" else "FAIL"
	return string.format(
		"%s: build %s project=%s revision=%s output=%s sha256=%s",
		result.target.slug,
		status,
		result.target.projectPath,
		result.revision,
		result.target.outputPath,
		result.digest or "none"
	)
end

--- One inspect line per target. A target whose build failed is reported as
--- SKIPPED (not inspected) so a stale artifact can never look verified.
function M.formatInspect(result: TargetResult): string
	if not result.built then
		return string.format(
			"%s: inspect SKIPPED (build failed, no fresh %s)",
			result.target.slug,
			result.target.outputPath
		)
	end
	local status = if result.ok then "PASS" else "FAIL"
	return string.format(
		"%s: inspect %s output=%s sha256=%s (%d requires resolved)",
		result.target.slug,
		status,
		result.target.outputPath,
		result.digest or "none",
		result.resolvedRequiresCount
	)
end

return M
