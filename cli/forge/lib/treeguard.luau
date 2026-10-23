--!strict
-- treeguard: fingerprint the working tree (HEAD + every tracked change and
-- untracked, non-ignored file's bytes) so a long gate can prove nobody edited
-- sources while it ran. Ignored paths (build/, .omo/, reports/) never count.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local M = {}

export type Fingerprint = { head: string, digest: string, paths: { string } }

function M.fingerprint(root: string?): (Fingerprint?, string?)
	local cwd = root or process.cwd
	local head = process.exec("git", { "rev-parse", "HEAD" }, { cwd = cwd })
	if not head.ok then
		return nil, "git rev-parse failed: " .. head.stderr
	end
	local status = process.exec("git", { "status", "--porcelain=v1", "-z", "-uall" }, { cwd = cwd })
	if not status.ok then
		return nil, "git status failed: " .. status.stderr
	end
	local paths: { string } = {}
	local entries = string.split(status.stdout, "\0")
	local index = 1
	while index <= #entries do
		local entry = entries[index]
		if #entry > 3 then
			local code = string.sub(entry, 1, 2)
			table.insert(paths, code .. " " .. string.sub(entry, 4))
			-- Renames and copies carry the source path as the next field.
			if string.find(code, "[RC]") then
				index += 1
			end
		end
		index += 1
	end
	table.sort(paths)
	-- Each entry carries its content hash, so an edit to an already-dirty file
	-- still changes the entry.
	local hashed: { string } = {}
	for _, line in paths do
		local full = cwd .. "/" .. string.sub(line, 4)
		local bytes = if fs.isFile(full) then fs.readFile(full) else "<absent>"
		table.insert(hashed, line .. " #" .. string.sub(serde.hash("sha256", bytes), 1, 16))
	end
	local headSha = (string.gsub(head.stdout, "%s+$", ""))
	return {
		head = headSha,
		digest = serde.hash("sha256", headSha .. "\n" .. table.concat(hashed, "\n")),
		paths = hashed,
	},
		nil
end

-- Paths whose state differs between two fingerprints (for the report).
function M.diff(before: Fingerprint, after: Fingerprint): { string }
	local seen: { [string]: boolean } = {}
	for _, path in before.paths do
		seen[path] = true
	end
	local changed: { string } = {}
	for _, path in after.paths do
		if not seen[path] then
			table.insert(changed, path)
		end
		seen[path] = nil
	end
	for path in seen do
		table.insert(changed, path)
	end
	table.sort(changed)
	if before.head ~= after.head then
		table.insert(changed, 1, "HEAD " .. before.head .. " -> " .. after.head)
	end
	return changed
end

return M
