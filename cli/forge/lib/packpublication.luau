--!strict
local fs = require("@lune/fs")
local M = {}
export type Reader = { isDir: (string) -> boolean, isFile: (string) -> boolean }

-- Consumers never recover or interpret journals. Even a completed transaction
-- remains unavailable until its writer/recovery path finishes cleanup.
function M.pending(packDir: string, reader: Reader?): string?
	local io: Reader = reader or fs
	local path = string.gsub(packDir, "\\", "/")
	path = string.gsub(path, "/+$", "")
	for _, suffix in { ".forge-stage", ".forge-backup" } do
		local marker = path .. suffix
		if io.isDir(marker) or io.isFile(marker) then
			return "FORGE_PUBLICATION_PENDING: " .. path .. "; recover publication before consuming this pack"
		end
	end
	return nil
end
return M
