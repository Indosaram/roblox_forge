--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local dependencies: { [string]: any } = {
	["../../../core/infra/data/FencedStore"] = require("../../../core/infra/data/FencedStore"),
	["../../../core/domain/brawl/Match"] = require("../../../core/domain/brawl/Match"),
	["../../../core/domain/genre/SerializedData"] = require("../../../core/domain/genre/SerializedData"),
	["../../../games/robango-island/src/shared/SurvivalContent"] = require(
		"../../../games/robango-island/src/shared/SurvivalContent"
	),
	["./Combat"] = require("./Combat"),
	["./BrawlLedger"] = require("./BrawlLedger"),
}
local function killed(name: string, before: string, after: string)
	local path = "genres/survival-coop/module/" .. name
	local source = fs.readFile(path .. ".luau")
	local first, last = string.find(source, before, 1, true)
	assert(first and last, "mutation anchor " .. name)
	local mutant = luau.load(string.sub(source, 1, first - 1) .. after .. string.sub(source, last + 1), {
		environment = {
			require = function(key: string): any
				return assert(dependencies[key], key)
			end,
		},
	})()
	local tests = luau.load(fs.readFile(path .. ".spec.luau"), {
		environment = {
			require = function(key: string): any
				return if key == "./" .. name then mutant else assert(dependencies[key], key)
			end,
		},
	})()
	local failures = 0
	for _, test in tests do
		if not pcall(test) then
			failures += 1
		end
	end
	assert(failures > 0, "surviving mutation " .. name .. ": " .. before)
end
return {
	["desertion omission killed"] = function()
		killed("BrawlController", "frame.connected[actor] ~= true", "false")
	end,
	["sparse position bypass killed"] = function()
		killed("BrawlController", "elseif not frame.positions[actor] then", "elseif false then")
	end,
	["storm dismount omission killed"] = function()
		killed("BrawlController", "player.mounted = false", "player.mounted = true")
	end,
	["combat resolution omission killed"] = function()
		killed("BrawlController", "milli / 1000", "0")
	end,
	["unsettled replacement bypass killed"] = function()
		killed("BrawlController", "or not document.settled[state.id]", "or false")
	end,
	["personal writer exclusion bypass killed"] = function()
		killed("BrawlLedger", "if not env.authorize(old, actor) then", "if false then")
	end,
	["failed personal save acknowledgement killed"] = function()
		killed("BrawlLedger", "if not ok then", "if false then")
	end,
	["mobile viewport clipping killed"] = function()
		killed("BrawlPanel", "math.min(440, width - 24)", "440")
	end,
}
