--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local tempdir = require("./tempdir")
local treeguard = require("./treeguard")

-- Throwaway git repos live under the git-ignored build/ directory; only the
-- unique leaf name comes from tempdir.path. The nested repo has its own .git,
-- so the outer worktree never sees its files.
local function git(root: string, args: { string })
	local argv =
		{ "-c", "user.name=treeguard-spec", "-c", "user.email=spec@example.invalid", "-c", "commit.gpgsign=false" }
	for _, arg in args do
		table.insert(argv, arg)
	end
	local result = process.exec("git", argv, { cwd = root })
	assert(result.ok, "git " .. table.concat(args, " ") .. " failed: " .. result.stderr)
end

local function withRepo(body: (root: string) -> ())
	local root = "build/" .. (string.match(tempdir.path(".treeguard-fixture"), "[^/]+$") :: string)
	fs.writeDir(root)
	local ok, reason = xpcall(function()
		git(root, { "init", "-q" })
		fs.writeFile(root .. "/.gitignore", "ignored/\n")
		fs.writeFile(root .. "/tracked.txt", "one\n")
		git(root, { "add", "-A" })
		git(root, { "commit", "-q", "-m", "initial" })
		body(root)
	end, debug.traceback)
	fs.removeDir(root)
	assert(ok, reason)
end

local function fingerprint(root: string): treeguard.Fingerprint
	local fp, err = treeguard.fingerprint(root)
	assert(fp ~= nil, err)
	return fp
end

local function has(list: { string }, prefix: string): boolean
	for _, entry in list do
		if string.sub(entry, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

return {
	["clean tree digest is stable and lists no paths"] = function()
		withRepo(function(root)
			local a = fingerprint(root)
			local b = fingerprint(root)
			assert(a.digest == b.digest, "clean digest changed between calls")
			assert(#a.paths == 0, table.concat(a.paths, "\n"))
			assert(string.match(a.head, "^%x+$") and #a.head >= 40, a.head)
			assert(#treeguard.diff(a, b) == 0, "clean diff must be empty")
		end)
	end,

	["untracked file changes digest, and editing it again changes it again"] = function()
		withRepo(function(root)
			local clean = fingerprint(root)
			fs.writeFile(root .. "/new.txt", "first\n")
			local dirty = fingerprint(root)
			assert(dirty.digest ~= clean.digest, "untracked file did not change the digest")
			local changed = treeguard.diff(clean, dirty)
			assert(#changed == 1 and has(changed, "?? new.txt #"), table.concat(changed, "\n"))

			fs.writeFile(root .. "/new.txt", "second\n")
			local edited = fingerprint(root)
			assert(edited.digest ~= dirty.digest, "editing an already-dirty file did not change the digest")
			changed = treeguard.diff(dirty, edited)
			assert(#changed == 2, table.concat(changed, "\n"))
			assert(has(changed, "?? new.txt #"), table.concat(changed, "\n"))
		end)
	end,

	["tracked edit changes digest and diff names it"] = function()
		withRepo(function(root)
			local clean = fingerprint(root)
			fs.writeFile(root .. "/tracked.txt", "two\n")
			local dirty = fingerprint(root)
			assert(dirty.digest ~= clean.digest, "tracked edit did not change the digest")
			local changed = treeguard.diff(clean, dirty)
			assert(#changed == 1 and has(changed, " M tracked.txt #"), table.concat(changed, "\n"))
		end)
	end,

	["files under an ignored directory never count"] = function()
		withRepo(function(root)
			local clean = fingerprint(root)
			fs.writeDir(root .. "/ignored/deep")
			fs.writeFile(root .. "/ignored/deep/out.txt", "noise\n")
			local after = fingerprint(root)
			assert(after.digest == clean.digest, "ignored file changed the digest")
			assert(#treeguard.diff(clean, after) == 0, table.concat(treeguard.diff(clean, after), "\n"))
		end)
	end,

	["a new commit changes head and diff reports HEAD"] = function()
		withRepo(function(root)
			local before = fingerprint(root)
			fs.writeFile(root .. "/tracked.txt", "committed\n")
			git(root, { "commit", "-q", "-am", "second" })
			local after = fingerprint(root)
			assert(after.head ~= before.head, "head did not change")
			assert(after.digest ~= before.digest, "digest did not change")
			assert(#after.paths == 0, table.concat(after.paths, "\n"))
			local changed = treeguard.diff(before, after)
			assert(#changed == 1, table.concat(changed, "\n"))
			assert(changed[1] == "HEAD " .. before.head .. " -> " .. after.head, changed[1])
		end)
	end,

	["a staged rename lists only the destination path"] = function()
		withRepo(function(root)
			local clean = fingerprint(root)
			git(root, { "mv", "tracked.txt", "renamed.txt" })
			local renamed = fingerprint(root)
			assert(renamed.digest ~= clean.digest, "rename did not change the digest")
			assert(#renamed.paths == 1, table.concat(renamed.paths, "\n"))
			assert(has(renamed.paths, "R  renamed.txt #"), renamed.paths[1])
			-- The destination exists, so it is hashed by content, not "<absent>".
			assert(not has(renamed.paths, "R  tracked.txt"), renamed.paths[1])

			fs.writeFile(root .. "/renamed.txt", "edited after rename\n")
			local edited = fingerprint(root)
			assert(#edited.paths == 1 and edited.digest ~= renamed.digest, table.concat(edited.paths, "\n"))
		end)
	end,
}
