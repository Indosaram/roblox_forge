--!strict
-- tempdir: portable scratch-directory resolution for specs. The root is the first
-- non-empty TEMP, TMP or TMPDIR, else "/tmp" (or "C:/Windows/Temp" on Windows), with
-- backslashes normalized to "/" so the result is a plain absolute path on every host.

local process = require("@lune/process")
local serde = require("@lune/serde")

local M = {}

local counter = 0

local function fromEnv(name: string): string?
	local value = process.env[name]
	if value ~= nil and value ~= "" then
		return value
	end
	return nil
end

--- The scratch root directory, using forward slashes only.
function M.root(): string
	local raw: string = fromEnv("TEMP")
		or fromEnv("TMP")
		or fromEnv("TMPDIR")
		or (if process.os == "windows" then "C:/Windows/Temp" else "/tmp")
	return (string.gsub(raw, "\\", "/"))
end

--- A fresh, not-yet-created path under root(): "<root>/<prefix>-<16 hex chars>".
function M.path(prefix: string): string
	counter += 1
	local digest = serde.hash("sha256", tostring(os.clock()) .. ":" .. tostring(counter))
	return M.root() .. "/" .. prefix .. "-" .. string.sub(digest, 1, 16)
end

return M
