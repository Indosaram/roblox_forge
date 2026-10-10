--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local lock = require("../forge/lib/lock")
local publication = require("../forge/lib/packpublication")
local contract = require("../forge/lib/genrecontract")

local M = {}
local INVENTORY = "docs/release/shipped-licenses.json"
local MANIFEST = "forge-release-manifest.json"
local ROOT_FILES = {
	["CHANGELOG.md"] = true,
	["README.md"] = true,
	["LICENSE.md"] = true,
	["RUNTIME-LICENSE.md"] = true,
	["THIRD_PARTY_NOTICES.md"] = true,
	["AGENTS.md"] = true,
	["rokit.toml"] = true,
	["selene.toml"] = true,
	["stylua.toml"] = true,
	[".luaurc"] = true,
	[".styluaignore"] = true,
	[".gitattributes"] = true,
	[".gitignore"] = true,
}

export type Entry = { path: string, bytes: string }

local function fail(code: string, detail: string)
	error(code .. ": " .. detail, 0)
end

function M.safePath(path: string): boolean
	if path == "" or string.find(path, "[^%w%._%-/]") or string.sub(path, 1, 1) == "/" then
		return false
	end
	for segment in string.gmatch(path, "[^/]+") do
		if segment == "." or segment == ".." or string.sub(segment, -1) == "." then
			return false
		end
		local stem = string.upper(string.match(segment, "^[^.]+") or segment)
		if
			stem == "CON"
			or stem == "PRN"
			or stem == "AUX"
			or stem == "NUL"
			or string.match(stem, "^COM[1-9]$")
			or string.match(stem, "^LPT[1-9]$")
		then
			return false
		end
	end
	return string.find(path, "//", 1, true) == nil
end

function M.included(path: string): boolean
	if not M.safePath(path) then
		return false
	end
	local lower = string.lower(path)
	for segment in string.gmatch(lower, "[^/]+") do
		if
			segment == "build"
			or segment == "reports"
			or segment == "scratch"
			or segment == "secrets"
			or segment == "node_modules"
			or segment == "vendor"
			or segment == "packages"
			or string.find(segment, ".forge-", 1, true)
			or string.find(segment, ".tmp", 1, true)
			or string.find(segment, "secret", 1, true)
			or string.find(segment, "credential", 1, true)
			or (string.sub(segment, 1, 1) == "." and not ROOT_FILES[path])
		then
			return false
		end
	end
	if
		string.match(lower, "%.pem$")
		or string.match(lower, "%.key$")
		or string.match(lower, "%.zip$")
		or string.match(lower, "%.rbxl[x]?$")
		or string.match(lower, "%.bak$")
		or string.match(lower, "%.log$")
	then
		return false
	end
	return ROOT_FILES[path] == true
		or string.match(path, "^cli/") ~= nil
		or string.match(path, "^core/") ~= nil
		or string.match(path, "^genres/") ~= nil
		or string.match(path, "^games/") ~= nil
		or string.match(path, "^skills/") ~= nil
		or string.match(path, "^docs/release/") ~= nil
end

-- Canonical JSON objects, independent of table iteration order. Arrays in the
-- manifest are nonempty or represented as objects when empty.
function M.canonical(value: any): string
	if type(value) ~= "table" then
		return serde.encode("json", value)
	end
	local parts = {}
	if #value > 0 then
		for _, item in value do
			table.insert(parts, M.canonical(item))
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = {}
	for key in value do
		assert(type(key) == "string", "JSON object keys must be strings")
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		table.insert(parts, serde.encode("json", key) .. ":" .. M.canonical(value[key]))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function sorted(entries: { Entry }): { Entry }
	local result = table.clone(entries)
	table.sort(result, function(a, b)
		return a.path < b.path
	end)
	local seen = {}
	for _, entry in result do
		assert(M.safePath(entry.path), "unsafe archive path")
		local key = string.lower(entry.path)
		assert(not seen[key], "duplicate or case-colliding archive path")
		seen[key] = true
	end
	return result
end

local CRC = {}
for n = 0, 255 do
	local c = n
	for _ = 1, 8 do
		c = if bit32.band(c, 1) == 1 then bit32.bxor(0xEDB88320, bit32.rshift(c, 1)) else bit32.rshift(c, 1)
	end
	CRC[n] = c
end

function M.crc32(bytes: string): number
	local crc = 0xFFFFFFFF
	for i = 1, #bytes do
		crc = bit32.bxor(CRC[bit32.band(bit32.bxor(crc, string.byte(bytes, i)), 255)], bit32.rshift(crc, 8))
	end
	return bit32.bxor(crc, 0xFFFFFFFF)
end

local function le(value: number, count: number): string
	local bytes = {}
	for _ = 1, count do
		table.insert(bytes, string.char(value % 256))
		value = math.floor(value / 256)
	end
	assert(value == 0, "ZIP32 limit exceeded")
	return table.concat(bytes)
end

-- ZIP STORE, DOS epoch 1980-01-01, no extras/comments/platform attributes.
-- No compressor, filesystem timestamps, locale, or absolute paths enter bytes.
function M.zip(entries: { Entry }): string
	local locals = {}
	local central = {}
	local offset = 0
	local ordered = sorted(entries)
	assert(#ordered < 65535, "ZIP32 entry limit exceeded")
	for _, entry in ordered do
		local name, bytes = entry.path, entry.bytes
		local crc = M.crc32(bytes)
		local common = le(0, 2)
			.. le(0, 2)
			.. le(0, 2)
			.. le(33, 2)
			.. le(crc, 4)
			.. le(#bytes, 4)
			.. le(#bytes, 4)
			.. le(#name, 2)
			.. le(0, 2)
		local header = "PK\003\004" .. le(20, 2) .. common .. name
		table.insert(locals, header .. bytes)
		table.insert(
			central,
			"PK\001\002"
				.. le(20, 2)
				.. le(20, 2)
				.. common
				.. le(0, 2)
				.. le(0, 2)
				.. le(0, 2)
				.. le(0, 4)
				.. le(offset, 4)
				.. name
		)
		offset += #header + #bytes
	end
	local directory = table.concat(central)
	return table.concat(locals)
		.. directory
		.. "PK\005\006"
		.. le(0, 4)
		.. le(#ordered, 2)
		.. le(#ordered, 2)
		.. le(#directory, 4)
		.. le(offset, 4)
		.. le(0, 2)
end

-- Pure inventory authoring: an explicit owner-approved source scope grants
-- first-party rights. Media and third-party overrides never inherit that scope.
-- Returns all unresolved paths instead of stopping at the first unknown asset.
function M.freezeInventory(entries: { Entry }, policy: any): (any, { string })
	local frozen = table.clone(policy)
	frozen.files = {}
	local unknown = {}
	for _, entry in sorted(entries) do
		if entry.path == INVENTORY then
			continue
		end
		assert(M.included(entry.path), "FORGE_PACKAGE_EXCLUDED: " .. entry.path)
		local record = (policy.assetRecords or {})[entry.path]
		if record then
			record = table.clone(record)
			if record.status ~= "verified" or record.sha256 ~= serde.hash("sha256", entry.bytes) then
				table.insert(unknown, entry.path)
				record.status = "unknown"
			end
		else
			local kind: string? = nil
			if not table.find(policy.coveredSourcePaths or {}, entry.path) then
				kind = nil
			elseif table.find(policy.sourceRootFiles or {}, entry.path) then
				kind = "first-party-tooling"
			elseif table.find(policy.sourceExtensions or {}, string.match(entry.path, "%.([^.]+)$")) then
				for _, scope in policy.sourceScopes or {} do
					if string.sub(entry.path, 1, #scope.prefix) == scope.prefix then
						kind = scope.kind
					end
				end
			end
			if kind then
				record = {
					status = "verified",
					kind = kind,
					verifiedBy = "project-owner license scope",
					evidence = policy.sourceEvidence,
					license = if kind == "first-party-runtime"
						then "LicenseRef-Forge-SUL-1.0-Runtime-Exception"
						else "LicenseRef-Forge-SUL-1.0",
				}
			else
				record = { status = "unknown", reason = "No explicit source scope or asset rights record" }
				table.insert(unknown, entry.path)
			end
		end
		-- Keep the approved media hash in assetRecords; files records capture the
		-- actual candidate bytes and cannot re-approve a changed media payload.
		record.sha256 = serde.hash("sha256", entry.bytes)
		frozen.files[entry.path] = record
	end
	frozen.status = if #unknown == 0 then "FROZEN" else "BLOCKED_UNKNOWN_RIGHTS"
	return frozen, unknown
end

function M.validateRights(entries: { Entry }, inventory: any)
	assert(
		type(inventory) == "table" and inventory.schemaVersion == 1 and type(inventory.files) == "table",
		"FORGE_LICENSE_INVENTORY: expected schemaVersion 1 and files mapping"
	)
	local shipped = {}
	for _, entry in entries do
		shipped[entry.path] = entry.bytes
	end
	if inventory.coveredSourcePaths then
		local expected, unknown = M.freezeInventory(entries, inventory)
		assert(#unknown == 0, "FORGE_LICENSE_UNKNOWN: " .. table.concat(unknown, ", "))
		assert(
			M.canonical(expected.files) == M.canonical(inventory.files),
			"FORGE_LICENSE_INVENTORY: frozen records differ from policy or bytes"
		)
	end
	for _, entry in entries do
		-- The inventory is the declaration itself, not a self-hash recursion.
		if entry.path == INVENTORY then
			continue
		end
		local record = inventory.files[entry.path]
		if
			type(record) ~= "table"
			or record.sha256 ~= serde.hash("sha256", entry.bytes)
			or record.status ~= "verified"
			or type(record.evidence) ~= "string"
			or record.evidence == ""
			or type(record.verifiedBy) ~= "string"
			or record.verifiedBy == ""
		then
			fail("FORGE_LICENSE_UNKNOWN", entry.path)
		end
		if record.kind == "first-party-tooling" then
			assert(record.license == "LicenseRef-Forge-SUL-1.0", "FORGE_LICENSE_BOUNDARY: tooling")
		elseif record.kind == "first-party-runtime" then
			assert(record.license == "LicenseRef-Forge-SUL-1.0-Runtime-Exception", "FORGE_LICENSE_BOUNDARY: runtime")
		elseif record.kind == "third-party" then
			assert(
				type(record.license) == "string"
					and record.license ~= ""
					and not string.find(record.license, "LicenseRef-Forge", 1, true)
					and record.redistribution == true
					and type(record.notice) == "string"
					and shipped[record.notice],
				"FORGE_LICENSE_BOUNDARY: third-party notice and redistribution grant required"
			)
		else
			fail("FORGE_LICENSE_UNKNOWN", entry.path)
		end
	end
	for path in inventory.files do
		assert(shipped[path] ~= nil and path ~= INVENTORY, "FORGE_LICENSE_INVENTORY: stale or self entry " .. path)
	end
end

function M.versions(entries: { Entry }): any
	local source = {}
	for _, entry in entries do
		source[entry.path] = entry.bytes
	end
	local function yaml(path: string): any
		assert(source[path], "FORGE_PACKAGE_MANIFEST: missing " .. path)
		return serde.decode("yaml", source[path])
	end
	local versions = { core = "", genres = {} }
	for path in source do
		local genre = string.match(path, "^genres/([^/]+)/forge%-package%.yml$")
		if path == "core/forge-package.yml" or genre then
			local doc = yaml(path)
			assert(
				type(doc) == "table"
					and doc.name == (genre or "core")
					and type(doc.version) == "string"
					and string.match(doc.version, "^%d+%.%d+%.%d+$"),
				"FORGE_PACKAGE_MANIFEST: " .. path
			)
			if genre then
				versions.genres[genre] = doc.version
			else
				versions.core = doc.version
			end
		end
	end
	assert(versions.core ~= "" and next(versions.genres) ~= nil, "FORGE_PACKAGE_MANIFEST: missing packages")
	for genre in versions.genres do
		local doc = yaml("genres/" .. genre .. "/forge-package.yml")
		assert(
			type(doc.requires) == "table" and contract.coreCompatible(versions.core, doc.requires.core),
			"FORGE_PACKAGE_MANIFEST: incompatible core requirement " .. genre
		)
	end
	local packs = 0
	for path in source do
		local pack = string.match(path, "^games/([^/]+)/game%.yml$")
		if pack then
			packs += 1
			local base = "games/" .. pack .. "/"
			assert(source[base .. "default.project.json"], "FORGE_PACKAGE_MANIFEST: missing project " .. pack)
			local game = yaml(path)
			assert(
				type(game) == "table" and type(game.genres) == "table" and #game.genres > 0,
				"FORGE_PACKAGE_MANIFEST: invalid genres " .. pack
			)
			local seen = {}
			for index, id in game.genres do
				assert(
					type(index) == "number"
						and index >= 1
						and index <= #game.genres
						and index % 1 == 0
						and type(id) == "string"
						and not seen[id]
						and versions.genres[id],
					"FORGE_PACKAGE_MANIFEST: invalid genre " .. pack
				)
				seen[id] = true
			end
			local errors = lock.validate(lock.fromTable(yaml(base .. "forge-lock.yml")), {
				core = versions.core,
				genres = versions.genres,
				packGenres = game.genres,
			})
			assert(#errors == 0, "FORGE_PACKAGE_PIN: " .. pack .. ": " .. table.concat(errors, "; "))
		elseif string.match(path, "^games/[^/]+/default%.project%.json$") then
			assert(
				source[string.gsub(path, "default%.project%.json$", "game.yml")],
				"FORGE_PACKAGE_MANIFEST: orphan project"
			)
		end
	end
	assert(packs > 0, "FORGE_PACKAGE_MANIFEST: no packs")
	return versions
end

function M.assemble(entries: { Entry }, revision: string, candidateDigest: string?): (string, string)
	assert(string.match(revision, "^[0-9a-f]+$") and (#revision == 40 or #revision == 64), "invalid source revision")
	local ordered = sorted(entries)
	local byPath = {}
	for _, entry in ordered do
		assert(M.included(entry.path), "FORGE_PACKAGE_EXCLUDED: " .. entry.path)
		byPath[entry.path] = entry.bytes
	end
	for path in ROOT_FILES do
		local manifestPath = path :: string
		assert(byPath[manifestPath], "FORGE_PACKAGE_MANIFEST: missing " .. manifestPath)
	end
	assert(byPath[INVENTORY], "FORGE_LICENSE_INVENTORY: missing")
	local inventory = serde.decode("json", byPath[INVENTORY])
	M.validateRights(ordered, inventory)
	local contents = {}
	for _, entry in ordered do
		contents[entry.path] = { sha256 = serde.hash("sha256", entry.bytes), size = #entry.bytes }
	end
	local manifest = M.canonical({
		schemaVersion = 1,
		sourceRevision = revision,
		sourceState = if candidateDigest then "immutable-candidate-not-committed" else "clean-git-tree",
		candidateDigest = candidateDigest,
		versions = M.versions(ordered),
		files = contents,
		licenseInventory = INVENTORY,
		contentDigest = serde.hash("sha256", M.canonical(contents)),
		toolchain = serde.decode("toml", byPath["rokit.toml"]).tools,
	}) .. "\n"
	table.insert(ordered, { path = MANIFEST, bytes = manifest })
	return M.zip(ordered), manifest
end

-- Task16 library entrypoint, never a CLI dirty-tree bypass. The harness captures
-- and freezes its complete selected byte map before calling this function.
-- Both archive creation and consumer use operate on these strings, not live IO.
function M.captureCandidate(entries: { Entry }, baselineRevision: string): any
	local captured = {}
	local content = {}
	for _, entry in sorted(entries) do
		assert(M.included(entry.path), "FORGE_PACKAGE_EXCLUDED: " .. entry.path)
		table.insert(captured, table.freeze({ path = entry.path, bytes = entry.bytes }))
		content[entry.path] = { sha256 = serde.hash("sha256", entry.bytes), size = #entry.bytes }
	end
	return table.freeze({
		entries = table.freeze(captured),
		baselineRevision = baselineRevision,
		contentDigest = serde.hash("sha256", M.canonical(content)),
	})
end

function M.assembleCandidate(candidate: any): (string, string)
	local captured = M.captureCandidate(candidate.entries, candidate.baselineRevision)
	assert(captured.contentDigest == candidate.contentDigest, "FORGE_PACKAGE_CANDIDATE: changed captured bytes")
	return M.assemble(captured.entries, captured.baselineRevision, captured.contentDigest)
end

function M.assertNoPublication(root: string, reader: any?)
	local io = reader or fs
	if not io.isDir(root .. "/games") then
		fail("FORGE_PACKAGE_MANIFEST", "games directory missing")
	end
	for _, name in io.readDir(root .. "/games") do
		if string.find(name, ".forge-stage", 1, true) or string.find(name, ".forge-backup", 1, true) then
			fail("FORGE_PUBLICATION_PENDING", "games/" .. name .. "; finish publication recovery and cleanup")
		end
		local pending = publication.pending(root .. "/games/" .. name, io)
		if pending then
			error(pending, 0)
		end
	end
end

local function git(root: string, args: { string }): string
	local argv = { "-C", root }
	for _, arg in args do
		table.insert(argv, arg)
	end
	local result = process.exec("git", argv)
	assert(result.ok, "FORGE_PACKAGE_GIT: git read failed")
	return result.stdout
end

function M.snapshot(root: string): ({ Entry }, string)
	M.assertNoPublication(root)
	local revision = string.gsub(git(root, { "rev-parse", "HEAD" }), "%s+$", "")
	for _, args in
		{
			{ "diff", "--name-only", "-z", "HEAD", "--" },
			{ "diff", "--cached", "--name-only", "-z", "HEAD", "--" },
		}
	do
		for path in string.gmatch(git(root, args), "[^%z]+") do
			assert(not M.included(path), "FORGE_PACKAGE_DIRTY: " .. path)
		end
	end
	local entries = {}
	local tracked = {}
	for record in string.gmatch(git(root, { "ls-tree", "-rz", "--full-tree", revision }), "[^%z]+") do
		local mode, object, path = string.match(record, "^(%d+) blob ([0-9a-f]+)\t(.+)$")
		if path and M.included(path) then
			assert(mode == "100644" or mode == "100755", "FORGE_PACKAGE_FILE: no symlinks")
			assert(object, "FORGE_PACKAGE_FILE: missing blob identity")
			local bytes = git(root, { "cat-file", "blob", object })
			assert(
				fs.isFile(root .. "/" .. path) and fs.readFile(root .. "/" .. path) == bytes,
				"FORGE_PACKAGE_DIRTY: " .. path
			)
			tracked[path] = true
			table.insert(entries, { path = path, bytes = bytes })
		elseif not path then
			fail("FORGE_PACKAGE_FILE", "unsupported git tree entry")
		end
	end
	-- Without --exclude-standard, Git lists ignored files too. Git does not
	-- follow directory symlinks into arbitrary user trees during this scan.
	for path in string.gmatch(git(root, { "ls-files", "--others", "-z" }), "[^%z]+") do
		if M.included(path) then
			assert(tracked[path], "FORGE_PACKAGE_DIRTY: unrecorded " .. path)
		end
	end
	M.assertNoPublication(root)
	return sorted(entries), revision
end

function M.run(args: { string }): boolean
	local ok, result = pcall(function()
		assert(
			#args == 2 and args[1] == "--out" and string.match(args[2], "^build/[%w_-]+%.zip$"),
			"FORGE_PACKAGE_USAGE: lune run cli/release/package --out build/forge-release.zip"
		)
		local out = args[2]
		local manifestOut = string.gsub(out, "%.zip$", "-manifest.json")
		assert(
			not fs.isFile(out) and not fs.isFile(manifestOut),
			"FORGE_PACKAGE_OUTPUT_EXISTS: choose fresh output names"
		)
		local entries, revision = M.snapshot(".")
		local archive, manifest = M.assemble(entries, revision)
		-- The archive uses committed blob bytes, never a mixed live pack. Recheck
		-- all source bytes and markers before writing; no generation is started.
		local current, currentRevision = M.snapshot(".")
		assert(revision == currentRevision and #current == #entries, "FORGE_PACKAGE_DIRTY: source changed")
		for i, entry in entries do
			assert(
				current[i].path == entry.path and current[i].bytes == entry.bytes,
				"FORGE_PACKAGE_DIRTY: source changed"
			)
		end
		if not fs.isDir("build") then
			fs.writeDir("build")
		end
		local written, err = pcall(function()
			fs.writeFile(out, archive)
			fs.writeFile(manifestOut, manifest)
		end)
		if not written then
			if fs.isFile(out) then
				fs.removeFile(out)
			end
			if fs.isFile(manifestOut) then
				fs.removeFile(manifestOut)
			end
			error(err, 0)
		end
		return M.canonical({ ok = true, output = out, manifest = manifestOut, sha256 = serde.hash("sha256", archive) })
	end)
	if ok then
		stdio.write(result .. "\n")
	else
		stdio.ewrite(M.canonical({ ok = false, error = tostring(result) }) .. "\n")
	end
	return ok
end

-- Specs load this chunk with an explicit module argument. Normal CLI execution
-- always validates arguments, including the no-argument error path.
if ... ~= "module" then
	if not M.run(process.args) then
		process.exit(1)
	end
end

return M
