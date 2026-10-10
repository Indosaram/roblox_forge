--!strict
local luau = require("@lune/luau")
local Smoke = require("./smokeplan")

local function execute(files: { [string]: string }, entry: string)
	local bundle, err = Smoke.bundle(entry, function(path)
		return files[path]
	end)
	assert(bundle ~= nil, tostring(err))
	luau.load(bundle :: string)()
end

return {
	["init modules resolve nested children rather than colliding siblings"] = function()
		execute({
			["root/entry.luau"] = 'local value = require("./pkg") return {run=function() assert(value == 42) return {{name="nested",ok=true}} end}',
			["root/pkg/init.luau"] = 'return require("./nested")',
			["root/pkg/nested/init.luau"] = 'return require("./child")',
			["root/pkg/nested/child.luau"] = "return 42",
			["root/nested.luau"] = "return -1",
			["root/pkg/child.luau"] = "return -2",
		}, "root/entry.luau")
	end,
	["direct files win over init and resolve children from their own directory"] = function()
		execute({
			["root/entry.luau"] = 'local value = require("./pkg") return {run=function() assert(value == 7) return {{name="direct",ok=true}} end}',
			["root/pkg.luau"] = 'return require("./child")',
			["root/pkg/init.luau"] = 'error("init must not be selected")',
			["root/child.luau"] = "return 7",
			["root/pkg/child.luau"] = "return -1",
		}, "root/entry.luau")
	end,
	["explicit init entry resolves its children"] = function()
		execute({
			["root/pkg/init.luau"] = 'local value = require("./child") return {run=function() assert(value == 3) return {} end}',
			["root/pkg/child.luau"] = "return 3",
		}, "root/pkg/init.luau")
	end,
}
