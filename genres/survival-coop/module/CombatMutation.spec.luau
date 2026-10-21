--!strict
-- Mutation proof uses detached compiled modules, never edits production files.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local dependencies: { [string]: any } = {
	["../../../core/domain/survival/Content"] = require("../../../core/domain/survival/Content"),
	["../../../core/domain/survival/Archetype"] = require("../../../core/domain/survival/Archetype"),
	["../../../core/domain/inventory/Inventory"] = require("../../../core/domain/inventory/Inventory"),
	["../../../core/domain/survival/CapacityPolicy"] = require("../../../core/domain/survival/CapacityPolicy"),
	["../../../core/domain/taming/Taming"] = require("../../../core/domain/taming/Taming"),
	["../../../core/domain/crafting/Job"] = require("../../../core/domain/crafting/Job"),
	["../../../core/domain/genre/Contract"] = require("../../../core/domain/genre/Contract"),
	["../../../core/infra/data/FencedStore"] = require("../../../core/infra/data/FencedStore"),
	["../../../core/infra/data/MemoryBackend"] = require("../../../core/infra/data/MemoryBackend"),
	["../../../core/infra/genre/Session"] = require("../../../core/infra/genre/Session"),
	["./Mounts"] = require("./Mounts"),
	["./TamingRuntime"] = require("./TamingRuntime"),
	["@lune/serde"] = require("@lune/serde"),
}
local function dependency(name: string): any
	return assert(dependencies[name], "unknown mutation dependency " .. name)
end
local function killed(moduleName: string, specName: string, before: string, after: string)
	local path = "genres/survival-coop/module/"
	local source = fs.readFile(path .. moduleName .. ".luau")
	local first, last = string.find(source, before, 1, true)
	assert(first and last, "mutation anchor")
	local mutant = string.sub(source, 1, first - 1) .. after .. string.sub(source, last + 1)
	local loaded = luau.load(mutant, { environment = { require = dependency } })()
	local specs = luau.load(fs.readFile(path .. specName .. ".spec.luau"), {
		environment = {
			require = function(name: string): any
				if name == "./" .. moduleName then
					return loaded
				end
				return dependency(name)
			end,
		},
	})()
	local failures = 0
	for _, test in specs do
		if not pcall(test) then
			failures += 1
		end
	end
	assert(failures > 0, "surviving mutation: " .. moduleName)
end
return {
	["negative ammunition mutation is killed"] = function()
		killed("Combat", "Combat", "and integer(ammunition, 0, 2 ^ 31)", "and integer(ammunition, -1, 2 ^ 31)")
	end,
	["duplicate capture mutation is killed"] = function()
		killed("Wildlife", "Wildlife", "if state.captureId then", "if false then")
	end,
	["unpaid taming mutation is killed"] = function()
		killed(
			"TamingExtension",
			"TamingExtension",
			"if open(receipt) then\n\t\t\t\treturn { ok = false",
			"if false then\n\t\t\t\treturn { ok = false"
		)
	end,
	["free companion training mutation is killed"] = function()
		killed("CombatCompanion", "CombatCompanion", "if quantity < 1 then", "if false then")
	end,
	["late dodge mutation is killed"] = function()
		killed("Combat", "Combat", "strike >= defense.dodgeStart", "true")
	end,
	["negative companion material mutation is killed"] = function()
		killed("CombatCompanion", "CombatCompanion", "quantity >= 0 and quantity % 1 == 0", "quantity % 1 == 0")
	end,
}
