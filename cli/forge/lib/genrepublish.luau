--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local cliutil = require("./cliutil")
local run = require("./run")
local project = require("./genreproject")
local scaffold = require("./scaffold")
local M = {}
-- Parsed YAML documents are acyclic; comparison must not impose game-state limits.
local function sameDocument(left: any, right: any): boolean
	if type(left) ~= type(right) then
		return false
	end
	if type(left) ~= "table" then
		return left == right
	end
	for key, value in left do
		if not sameDocument(value, right[key]) then
			return false
		end
	end
	for key in right do
		if left[key] == nil then
			return false
		end
	end
	return true
end
export type Assembly = { files: { [string]: string }, order: { string }, generation: { string }, legacy: boolean }
function M.ensureDir(path: string)
	if fs.isDir(path) then
		return
	end
	local parent = string.match(path, "^(.*)/[^/]+$")
	if parent and parent ~= "" then
		M.ensureDir(parent)
	end
	fs.writeDir(path)
end
local function stage(
	assembly: Assembly,
	destination: string,
	slug: string,
	context: cliutil.CommandContext?
): (boolean, string?)
	local gen = require("../commands/gen")
	local assetsCommand = require("../commands/assets")
	local fields = {}
	local published: { [string]: any } = {}
	local oldEntries: { any } = {}
	local manifestPath = destination .. "/assets/manifest.yml"
	if fs.isFile(manifestPath) then
		local text = fs.readFile(manifestPath)
		local decoded = serde.decode("yaml", text)
		assert(type(decoded) == "table" and type(decoded.assets) == "table", "invalid existing asset manifest")
		oldEntries = decoded.assets
		local keys = {}
		for _, entry in decoded.assets do
			assert(type(entry) == "table" and type(entry.key) == "string", "invalid existing asset entry")
			keys[entry.key] = true
			published[entry.key] = { assetId = entry.assetId, moderation = entry.moderation }
		end
		fields = cliutil.readAssetFields(text, keys)
		assembly.files["assets/manifest.yml"] = text
	end
	local gamePath = destination .. "/game.yml"
	if fs.isFile(gamePath) then
		local oldText = fs.readFile(gamePath)
		local old = serde.decode("yaml", oldText)
		assert(
			type(old) == "table" and (old.monetization == nil or type(old.monetization) == "table"),
			"invalid existing game publication data"
		)
		local new = serde.decode("yaml", assembly.files["game.yml"])
		local generated = serde.decode("yaml", assembly.files["game.yml"])
		-- Generated fields remain authoritative; retain unknown authored map fields.
		-- Arrays are generated collections, not maps to merge by positional index.
		local function preserveFields(target: any, prior: any)
			for key, value in prior do
				if type(key) == "string" then
					if target[key] == nil then
						target[key] = value
					elseif type(target[key]) == "table" and type(value) == "table" then
						preserveFields(target[key], value)
					end
				end
			end
		end
		preserveFields(new, old)
		for _, section in { "gamepasses", "products", "subscriptions" } do
			local entries = {}
			for _, entry in (if old.monetization then old.monetization[section] else nil) or {} do
				assert(type(entry) == "table" and type(entry.key) == "string", "invalid monetization entry")
				entries[entry.key] = entry
			end
			for _, entry in (if new.monetization then new.monetization[section] else nil) or {} do
				local prior = entries[entry.key]
				if prior then
					preserveFields(entry, prior)
				end
				entry.id = if prior then prior.id else nil
			end
		end
		if sameDocument(new, old) then
			assembly.files["game.yml"] = oldText
		elseif not sameDocument(new, generated) then
			assembly.files["game.yml"] = serde.encode("yaml", new)
		end
	end
	local paths = {}
	for path in assembly.files do
		table.insert(paths, path)
	end
	table.sort(paths)
	for _, path in paths do
		if path == "deploy.yml" and fs.isFile(destination .. "/deploy.yml") then
			continue
		end
		local target = destination .. "/" .. path
		M.ensureDir(string.match(target, "^(.*)/[^/]+$") :: string)
		fs.writeFile(target, assembly.files[path])
	end
	for _, step in assembly.generation do
		if not gen.run({ "gen", step, "--pack", slug }, context) then
			return false, "gen " .. step .. ": " .. destination
		end
	end
	if fs.isFile(manifestPath) then
		local restored = cliutil.applyAssetFields(fs.readFile(manifestPath), fields)
		local document = serde.decode("yaml", restored)
		local currentKeys = {}
		for _, entry in document.assets do
			currentKeys[entry.key] = true
		end
		for _, entry in oldEntries do
			if not currentKeys[entry.key] then
				table.insert(document.assets, entry)
			end
		end
		for _, entry in document.assets do
			local old = published[entry.key]
			if old then
				entry.assetId, entry.moderation = old.assetId, old.moderation
			end
		end
		fs.writeFile(manifestPath, serde.encode("yaml", document))
		if not assetsCommand.run({ "assets", "codegen", "--pack", slug }, context) then
			return false, "assets codegen: " .. destination
		end
	end
	local formatted = run.exec("stylua", { "--config-path", "stylua.toml", destination })
	return formatted.ok, if formatted.ok then nil else "stylua: " .. destination .. ": " .. formatted.stderr
end
local function snapshot(directory: string): { [string]: string }
	local files: { [string]: string } = {}
	local function visit(root: string, prefix: string)
		local names = fs.readDir(root)
		table.sort(names)
		for _, name in names do
			local relative = prefix .. name
			if fs.isDir(root .. "/" .. name) then
				visit(root .. "/" .. name, relative .. "/")
			else
				files[relative] = fs.readFile(root .. "/" .. name)
			end
		end
	end
	if fs.isDir(directory) then
		visit(directory, "")
	end
	return files
end

local function cleanup(destination: string, observer: ((string, number) -> ())?)
	local root = destination .. ".forge-stage"
	local marker = destination .. ".forge-backup"
	-- Keep ownership outside the recursively removed tree until removal finishes.
	fs.writeFile(
		root .. "/cleanup.tmp",
		serde.encode("json", {
			api = 1,
			kind = "forge-publication-cleanup",
			destination = project.absolute(destination),
		})
	)
	fs.move(root .. "/cleanup.tmp", marker)
	if observer then
		observer("cleanup-marked", 0)
	end
	fs.removeDir(root)
	if observer then
		observer("cleanup-removed", 0)
	end
	fs.removeFile(marker)
	if observer then
		observer("cleanup-finished", 0)
	end
end

function M.recover(destination: string, observer: ((string, number) -> ())?): (boolean, string?)
	local root = destination .. ".forge-stage"
	local marker = destination .. ".forge-backup"
	if fs.isFile(marker) then
		local ok, reason = pcall(function()
			local owner = serde.decode("json", fs.readFile(marker))
			assert(
				type(owner) == "table"
					and owner.api == 1
					and owner.kind == "forge-publication-cleanup"
					and owner.destination == project.absolute(destination),
				"invalid cleanup ownership"
			)
			if fs.isDir(root) then
				fs.removeDir(root)
			end
			if observer then
				observer("cleanup-removed", 0)
			end
			fs.removeFile(marker)
			if observer then
				observer("cleanup-finished", 0)
			end
		end)
		return ok, if ok then nil else "FORGE_RECOVERY_REQUIRED: " .. tostring(reason)
	end
	if not fs.isDir(root) and not fs.isFile(root) then
		return true, nil
	end
	local ok, reason = pcall(function()
		assert(fs.isFile(root .. "/owner.json"), "unowned staging path; inspection required")
		local owner = serde.decode("json", fs.readFile(root .. "/owner.json"))
		assert(
			type(owner) == "table"
				and owner.api == 1
				and owner.kind == "forge-publication"
				and owner.destination == project.absolute(destination),
			"invalid staging ownership"
		)
		if fs.isFile(root .. "/complete") then
			assert(fs.readFile(root .. "/complete") == "1", "invalid completion marker")
			cleanup(destination, observer)
			return nil
		end
		if not fs.isFile(root .. "/journal.json") then
			-- Ownership is installed before generation. Without a published
			-- journal no destination file has been replaced.
			cleanup(destination, observer)
			return nil
		end
		local journal = serde.decode("json", fs.readFile(root .. "/journal.json"))
		assert(type(journal) == "table" and journal.api == 1 and type(journal.entries) == "table", "invalid journal")
		local seen = {}
		for _, entry in journal.entries do
			assert(
				type(entry) == "table"
					and type(entry.path) == "string"
					and string.match(entry.path, "^[%w_%-][%w_%-%./]*$")
					and not string.find(entry.path, "..", 1, true)
					and not seen[entry.path]
					and type(entry.old) == "boolean"
					and type(entry.digest) == "string",
				"invalid journal entry"
			)
			seen[entry.path] = true
			local target = destination .. "/" .. entry.path
			local prior = root .. "/prior/" .. entry.path
			local current = if fs.isFile(target) then fs.readFile(target) else nil
			assert(not entry.old or fs.isFile(prior), "missing prior file")
			assert(
				current == nil
					or serde.hash("sha256", current) == entry.digest
					or (entry.old and current == fs.readFile(prior)),
				"authored edit conflicts with recovery"
			)
		end
		if not fs.isFile(root .. "/complete") then
			for index, entry in journal.entries do
				local target = destination .. "/" .. entry.path
				if entry.old then
					local temporary = root .. "/restore-" .. tostring(index)
					fs.copy(root .. "/prior/" .. entry.path, temporary, true)
					if observer then
						observer("restore-staged", index)
					end
					M.ensureDir(string.match(target, "^(.*)/[^/]+$") :: string)
					fs.move(temporary, target, true)
				elseif fs.isFile(target) then
					fs.removeFile(target)
				end
				if observer then
					observer("restored", index)
				end
			end
		end
		fs.writeFile(root .. "/complete.tmp", "1")
		if observer then
			observer("recovery-complete-staged", 0)
		end
		fs.move(root .. "/complete.tmp", root .. "/complete")
		if observer then
			observer("recovery-complete", 0)
		end
		cleanup(destination, observer)
		return nil
	end)
	return ok, if ok then nil else "FORGE_RECOVERY_REQUIRED: " .. tostring(reason)
end

function M.write(
	assembly: Assembly,
	destination: string,
	slug: string,
	context: cliutil.CommandContext?,
	observer: ((string, number) -> ())?,
	selected: { [string]: boolean }?
): (boolean, string?)
	local ready, prerequisiteError = run.preflight({ "stylua" })
	if not ready then
		return false, prerequisiteError
	end
	local root = destination .. ".forge-stage"
	local backup = root .. "/prior"
	local staged = root .. "/" .. slug
	if
		not scaffold.isValidSlug(slug)
		or project.absolute((if context and context.packsDir then context.packsDir else "games") .. "/" .. slug)
			~= project.absolute(destination)
	then
		return false, "FORGE_REGEN_CONFLICT: destination does not match pack context"
	end
	local recovered, recoveryError = M.recover(destination)
	if not recovered then
		return false, recoveryError
	end
	if fs.isFile(destination) or fs.isDir(root) or fs.isFile(root) or fs.isDir(destination .. ".forge-backup") then
		return false, "FORGE_REGEN_CONFLICT: destination or pending transaction requires recovery"
	end
	for path, text in assembly.files do
		if
			type(path) ~= "string"
			or type(text) ~= "string"
			or not string.match(path, "^[%w_%-][%w_%-%./]*$")
			or string.find(path, "..", 1, true)
			or string.find(path, "//", 1, true)
		then
			return false, "FORGE_INVALID_CATALOG: unsafe artifact path"
		end
	end
	local before = snapshot(destination)
	local hookPath = "src/server/GenreHooks.luau"
	if before[hookPath] and assembly.files[hookPath] ~= before[hookPath] then
		return false, "FORGE_REGEN_CONFLICT: hooks changed since assembly"
	end
	local existed = fs.isDir(destination)
	local owned = false
	local committing = false
	local ok, reason = pcall(function()
		M.ensureDir(string.match(root, "^(.*)/[^/]+$") :: string)
		fs.writeDir(root)
		owned = true
		fs.writeFile(
			root .. "/owner.tmp",
			serde.encode("json", {
				api = 1,
				kind = "forge-publication",
				destination = project.absolute(destination),
			})
		)
		fs.move(root .. "/owner.tmp", root .. "/owner.json")
		if observer then
			observer("owned", 0)
		end
		if existed then
			fs.copy(destination, staged)
		end
		local working = table.clone(assembly)
		working.files = table.clone(assembly.files)
		local settings: cliutil.CommandContext = if context then table.clone(context) else {}
		settings.packsDir = root
		if selected then
			assert(#assembly.generation == 0, "SELECTED_PUBLICATION_CANNOT_GENERATE_ASSETS")
			for path in assembly.files do
				assert(selected[path], "UNSELECTED_PUBLICATION_FILE")
			end
			for path in selected do
				assert(assembly.files[path] and before[path], "SELECTED_EXISTING_FILE_REQUIRED")
				if assembly.files[path] == before[path] then
					continue
				end
				fs.writeFile(staged .. "/" .. path, assembly.files[path])
				local formatted = run.exec("stylua", { "--config-path", "stylua.toml", staged .. "/" .. path })
				assert(formatted.ok, "FORGE_GENERATION_FAILED: " .. formatted.stderr)
			end
		else
			local written, failure = stage(working, staged, slug, settings)
			assert(written, "FORGE_GENERATION_FAILED: " .. tostring(failure))
		end
		-- The publisher formats the whole staging tree. Restore authored bytes,
		-- including files outside its generated map, before promotion.
		for path, text in before do
			if assembly.files[path] == nil or path == "src/server/GenreHooks.luau" or path == "deploy.yml" then
				-- Capability outputs must retain their newly generated bytes.
				if
					(path :: string) ~= "src/shared/Assets.luau"
					and (path :: string) ~= "asphalt.toml"
					and (path :: string) ~= "src/shared/ProcAssets.luau"
					and not string.match(path, "^assets/audio/")
					and not string.match(path, "^assets/icon/")
					and not string.match(path, "^assets/thumbnails/")
				then
					fs.writeFile(staged .. "/" .. path, text)
				end
			end
		end
		local current = snapshot(destination)
		assert(fs.isDir(destination) == existed, "FORGE_REGEN_CONFLICT: destination changed during generation")
		for path, text in before do
			assert(current[path] == text, "FORGE_REGEN_CONFLICT: destination changed during generation")
			current[path] = nil
		end
		assert(next(current) == nil, "FORGE_REGEN_CONFLICT: destination changed during generation")
		if existed then
			fs.copy(destination, backup)
		end
		if observer then
			observer("backed-up", 0)
		end
		local after = snapshot(staged)
		if selected then
			for path, text in before do
				assert(selected[path] or after[path] == text, "UNSELECTED_FILE_CHANGED")
			end
			for path in after do
				assert(before[path] ~= nil or selected[path], "UNSELECTED_FILE_CREATED")
			end
		end
		local entries = {}
		for path, text in after do
			if before[path] ~= text then
				table.insert(entries, { path = path, old = before[path] ~= nil, digest = serde.hash("sha256", text) })
			end
		end
		table.sort(entries, function(a, b)
			return a.path < b.path
		end)
		fs.writeFile(root .. "/journal.tmp", serde.encode("json", { api = 1, entries = entries }))
		if observer then
			observer("journal-staged", 0)
		end
		fs.move(root .. "/journal.tmp", root .. "/journal.json")
		if observer then
			observer("journal-installed", 0)
		end
		committing = true
		for index, entry in entries do
			local target = destination .. "/" .. entry.path
			M.ensureDir(string.match(target, "^(.*)/[^/]+$") :: string)
			fs.move(staged .. "/" .. entry.path, target, true)
			if observer then
				observer("replaced", index)
			end
		end
		fs.writeFile(root .. "/complete.tmp", "1")
		if observer then
			observer("complete-staged", 0)
		end
		fs.move(root .. "/complete.tmp", root .. "/complete")
		if observer then
			observer("complete", 0)
		end
	end)
	if not ok and committing then
		local restored, recoveryDetail = M.recover(destination)
		if not restored then
			return false, recoveryDetail
		end
	end
	local cleaned = pcall(function()
		if owned and fs.isDir(root) then
			cleanup(destination, observer)
		end
	end)
	if not cleaned then
		return false, "FORGE_RECOVERY_REQUIRED: transaction cleanup failed at " .. root
	end
	return ok, if ok then nil else tostring(reason)
end
return M
