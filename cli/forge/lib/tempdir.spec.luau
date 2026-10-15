--!strict
local process = require("@lune/process")
local tempdir = require("./tempdir")

return {
	["root never falls back to the Windows path off Windows"] = function()
		local root = tempdir.root()
		if process.os ~= "windows" then
			assert(root ~= "C:/Windows/Temp", "non-Windows root must not be C:/Windows/Temp")
		end
		assert(root ~= "", "root is non-empty")
		assert(not string.find(root, "\\", 1, true), "root has no backslashes")
	end,
	["root is absolute"] = function()
		local root = tempdir.root()
		assert(string.sub(root, 1, 1) == "/" or string.match(root, "^%a:/") ~= nil, "root must be absolute: " .. root)
	end,
	["path is rooted, prefixed and unique"] = function()
		local first = tempdir.path("forge-tempdir-spec")
		local second = tempdir.path("forge-tempdir-spec")
		assert(first ~= second, "consecutive paths must differ")
		local prefix = tempdir.root() .. "/forge-tempdir-spec-"
		assert(string.sub(first, 1, #prefix) == prefix, "path starts with root and prefix: " .. first)
		local suffix = string.sub(first, #prefix + 1)
		assert(string.match(suffix, "^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil, "16 hex suffix: " .. suffix)
	end,
}
