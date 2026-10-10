--!strict
-- UNIT-only process seam. Load unchanged production modules; never install this
-- loader in the CLI or mutate the ordinary require cache. No repository is created.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local imports: { [string]: any } = {
	["@lune/fs"] = fs,
	["@lune/net"] = require("@lune/net"),
	["@lune/process"] = require("@lune/process"),
	["@lune/serde"] = require("@lune/serde"),
	["@lune/stdio"] = require("@lune/stdio"),
	["./qualityprofile"] = require("../lib/qualityprofile"),
	["./qualityregistration"] = require("../lib/qualityregistration"),
	["./buildidentity"] = require("../lib/buildidentity"),
	["../../../core/domain/genre/Validation"] = require("../../../core/domain/genre/Validation"),
	["./qastudio"] = require("../lib/qastudio"),
	["./licenses"] = require("../lib/licenses"),
	["./qualityevaluate"] = require("../lib/qualityevaluate"),
	["../lib/cliutil"] = require("../lib/cliutil"),
	["../lib/buildtargets"] = require("../lib/buildtargets"),
	["../lib/opencloud"] = require("../lib/opencloud"),
}

local function load(path: string, dependencies: { [string]: any }): any
	return luau.load(fs.readFile("cli/forge/" .. path .. ".luau"), {
		debugName = "UNIT/" .. path,
		environment = {
			require = function(name: string): any
				if dependencies[name] ~= nil then
					return dependencies[name]
				end
				assert(imports[name] ~= nil, "unmapped UNIT dependency: " .. name)
				return imports[name]
			end,
		},
	})()
end

return function(root: string)
	local tree: string? = string.rep("1", 40)
	local process = {
		exec = function(command: string, args: { string })
			assert(
				command == "git"
					and #args == 4
					and args[1] == "-C"
					and args[2] == root
					and args[3] == "rev-parse"
					and args[4] == "HEAD^{tree}",
				"UNIT tree seam accepts only the fixture root's production tree query"
			)
			return {
				ok = tree ~= nil,
				code = if tree then 0 else 128,
				stdout = if tree then tree .. "\n" else "",
				stderr = if tree then "" else "UNIT missing Git tree",
			}
		end,
	}
	local receipt = load("lib/qualityreceipt", { ["@lune/process"] = process })
	local gate = load("lib/qualitygate", { ["./qualityreceipt"] = receipt })
	local assets = load("lib/assets", { ["./qualityreceipt"] = receipt })
	local plan = load("lib/deployplan", { ["./qualitygate"] = gate })
	local deploy = load("commands/deploy", { ["../lib/qualitygate"] = gate, ["../lib/deployplan"] = plan })
	return {
		receipt = receipt,
		gate = gate,
		assets = assets,
		deploy = deploy,
		setTree = function(value: string?)
			tree = value
		end,
	}
end
