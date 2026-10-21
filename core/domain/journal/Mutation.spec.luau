--!strict
-- Mutate source only in memory: never alter the shared working tree.
local fs = require("@lune/fs")
local Content = require("../../../games/robango-island/src/shared/SurvivalContent")
local Ledger = require("../command/Ledger")
local Chapters = require("./Chapters")
local function compile(path: string, substitutions: any, source: string?): any
	local chunk = assert(loadstring(source or fs.readFile(path), "@" .. path), "compile mutation")
	local environment: { [string]: any } = {
		require = function(name: string): any
			assert(substitutions[name] ~= nil, "unmapped dependency: " .. name)
			return substitutions[name]
		end,
	}
	for key, value in getfenv() do
		if environment[key] == nil then
			environment[key] = value
		end
	end
	setfenv(chunk, environment)
	return chunk()
end
return {
	["negative guards are killed by deterministic source mutations"] = function()
		local cases: { { any } } = {
			{
				"core/domain/journal/Chapters.luau",
				"core/domain/journal/Chapters.spec.luau",
				"./Chapters",
				"level < found.gates.characterLevel",
				"false",
				{},
			},
			{
				"core/domain/journal/Chapters.luau",
				"core/domain/journal/Chapters.spec.luau",
				"./Chapters",
				"elseif state.completed[id] then",
				"elseif false then",
				{},
			},
			{
				"core/domain/journal/Chapters.luau",
				"core/domain/journal/Chapters.spec.luau",
				"./Chapters",
				"or out.markers[marker]",
				"or false",
				{},
			},
			{
				"core/domain/settlement/Multistorey.luau",
				"core/domain/settlement/Multistorey.spec.luau",
				"./Multistorey",
				"if not supported(out, part) then",
				"if false then",
				{},
			},
			{
				"core/domain/settlement/Multistorey.luau",
				"core/domain/settlement/Multistorey.spec.luau",
				"./Multistorey",
				"if other.kind == part.kind",
				"if false",
				{},
			},
			{
				"genres/survival-coop/module/AerialView.luau",
				"genres/survival-coop/module/AerialView.spec.luau",
				"./AerialView",
				"radius * 1.1",
				"radius * 0.9",
				{},
			},
			{
				"genres/survival-coop/module/JournalExtension.luau",
				"genres/survival-coop/module/JournalExtension.spec.luau",
				"./JournalExtension",
				"if not result.ok then",
				"if false then",
				{
					["../../../core/domain/journal/Chapters"] = Chapters,
					["../../../core/domain/command/Ledger"] = Ledger,
				},
			},
		}
		for _, case in cases do
			local source = fs.readFile(case[1])
			local start, finish = string.find(source, case[4], 1, true)
			assert(start and finish, "mutation anchor missing: " .. case[4])
			local mutated = string.sub(source, 1, start - 1) .. case[5] .. string.sub(source, finish + 1)
			local module = compile(case[1], case[6], mutated)
			local tests = compile(case[2], {
				[case[3]] = module,
				["../../../games/robango-island/src/shared/SurvivalContent"] = Content,
				["../../../core/domain/journal/Chapters"] = Chapters,
			})
			local killed = false
			for _, test in tests do
				if not pcall(test) then
					killed = true
				end
			end
			assert(killed, "mutation survived: " .. case[4])
		end
	end,
}
