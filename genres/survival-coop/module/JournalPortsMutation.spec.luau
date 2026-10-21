--!strict
-- Source mutations execute in memory and never touch shared runtime files.
local fs = require("@lune/fs")
local Data = require("../../../core/domain/genre/SerializedData")
local Chapters = require("../../../core/domain/journal/Chapters")
local Ledger = require("../../../core/domain/command/Ledger")
local Topology = require("../../../core/domain/settlement/Multistorey")
local Documents = require("../../../core/infra/data/ActorDocumentStore")
local Fenced = require("../../../core/infra/data/FencedStore")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Content = require("../../../games/robango-island/src/shared/SurvivalContent")
local Extension = require("./JournalExtension")
local Ports = require("./JournalPorts")
local Feed = require("./JournalObjectiveFeed")
local Aerial = require("./AerialView")

local dependencies: any = {
	["../../../core/domain/genre/SerializedData"] = Data,
	["../../../core/domain/journal/Chapters"] = Chapters,
	["../../../core/domain/command/Ledger"] = Ledger,
	["../../../core/domain/settlement/Multistorey"] = Topology,
	["../../../core/infra/data/ActorDocumentStore"] = Documents,
	["../../../core/infra/data/FencedStore"] = Fenced,
	["../../../core/infra/data/MemoryBackend"] = Memory,
	["../../../games/robango-island/src/shared/SurvivalContent"] = Content,
	["./JournalExtension"] = Extension,
	["./JournalPorts"] = Ports,
	["./JournalObjectiveFeed"] = Feed,
	["../../../../genres/survival-coop/module/AerialView"] = Aerial,
}
local function compile(path: string, source: string, overrides: any): any
	local chunk = assert(loadstring(source, "@" .. path), "mutation compiles")
	local environment: any = table.clone(getfenv())
	environment.require = function(name: string): any
		return assert(overrides[name] or dependencies[name], "unmapped dependency " .. name)
	end
	setfenv(chunk, environment)
	return chunk()
end

return {
	["production negatives kill removed commit permission reward and restoration guards"] = function()
		local root = "genres/survival-coop/module/"
		local camera = "games/robango-island/src/client/"
		local cases = {
			{
				root .. "JournalPorts.luau",
				root .. "JournalPorts.spec.luau",
				"./JournalPorts",
				"if document.journalGrants[chapter] then",
				"if false then",
			},
			{
				root .. "JournalObjectiveFeed.luau",
				root .. "JournalPorts.spec.luau",
				"./JournalObjectiveFeed",
				"event.committed ~= true",
				"false",
			},
			{
				root .. "JournalObjectiveFeed.luau",
				root .. "JournalPorts.spec.luau",
				"./JournalObjectiveFeed",
				"event.chapterId ~= state.active",
				"false",
			},
			{
				root .. "MultistoreyCommands.luau",
				root .. "MultistoreyCommands.spec.luau",
				"./MultistoreyCommands",
				"if not authority.allowed then",
				"if false then",
			},
			{
				camera .. "AerialCamera.luau",
				camera .. "AerialCamera.spec.luau",
				"./AerialCamera",
				"camera.CameraType = value.CameraType",
				"camera.CameraType = ctx.scriptable",
			},
		}
		for _, case in cases do
			local source = fs.readFile(case[1])
			local first, last = string.find(source, case[4], 1, true)
			assert(first and last, "mutation anchor " .. case[4])
			local module =
				compile(case[1], string.sub(source, 1, first - 1) .. case[5] .. string.sub(source, last + 1), {})
			local tests = compile(case[2], fs.readFile(case[2]), { [case[3]] = module })
			local killed = false
			for _, test in tests do
				if not pcall(test) then
					killed = true
				end
			end
			assert(killed, "surviving mutation " .. case[4])
		end
	end,
}
