--!strict
local fs = require("@lune/fs")
local gate = require("./gate")
local registryLib = require("../lib/genreregistry")

local function parse(args: { string }): gate.Options
	local options, err = gate.parseArgs(args)
	assert(options ~= nil, err)
	return options :: gate.Options
end

return {
	["two default runs get distinct fresh output directories under build/gate"] = function()
		local a = parse({ "gate" })
		local b = parse({ "gate", "--pack", "robango-island" })
		assert(a.out ~= b.out, "two runs share " .. a.out)
		for _, out in { a.out, b.out } do
			assert(string.match(out, "^build/gate/%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ%-%x+$"), out)
			assert(not fs.isDir(out), "run dir already exists: " .. out)
		end
	end,

	["runDir skips a directory that already exists"] = function()
		local root = "build/gate-spec-" .. string.sub(tostring(os.clock()), -6)
		fs.writeDir(root)
		local ok, reason = pcall(function()
			local seen: { [string]: boolean } = {}
			for _ = 1, 20 do
				local dir = gate.runDir(root)
				assert(not seen[dir], "runDir repeated " .. dir)
				assert(not fs.isDir(dir), "runDir returned an existing dir " .. dir)
				seen[dir] = true
				fs.writeDir(dir)
			end
		end)
		fs.removeDir(root)
		assert(ok, reason)
	end,

	["explicit --out is kept and flags parse"] = function()
		local options = parse({ "gate", "--out", "build/mine", "--jobs", "3", "--json", "g.json", "--no-fail-fast" })
		assert(options.out == "build/mine", options.out)
		assert(options.jobs == 3 and options.json == "g.json" and options.failFast == false, "flags")
		assert(options.pack == "robango-island", options.pack)
	end,

	["bad arguments are refused"] = function()
		for _, args in
			{ { "gate", "--jobs", "0" }, { "gate", "--jobs", "1.5" }, { "gate", "--out" }, { "gate", "--x", "y" } }
		do
			local options, err = gate.parseArgs(args)
			assert(options == nil and type(err) == "string", table.concat(args, " "))
		end
	end,

	["robango native scenarios include pack-local and genre scenarios, sorted and unique"] = function()
		local registry = registryLib.discover()
		assert(registry ~= nil, "registry")
		local refs = gate.nativeScenarios("robango-island", registry)
		assert(#refs >= 38, "expected at least the 38 hand-listed scenarios, got " .. #refs)
		local seen: { [string]: boolean } = {}
		for index, ref in refs do
			assert(string.match(ref, "^[a-z][a-z0-9%-]*:[a-z][a-z0-9%-]*$"), ref)
			assert(not seen[ref], "duplicate " .. ref)
			seen[ref] = true
			if index > 1 then
				assert(refs[index - 1] < ref, "not sorted at " .. ref)
			end
		end
		-- Bound to another pack or not native, and not selected by game.yml: never gated for robango.
		for _, excluded in
			{
				"survival-coop:command-replay",
				"survival-coop:full-coop-rejoin",
				"survival-coop:contract-loop",
				"survival-coop:tutorial",
			}
		do
			assert(not seen[excluded], "gated a scenario that is not robango-native: " .. excluded)
		end
		-- Bound to another pack but selected explicitly in game.yml qa_scenarios: gated.
		assert(seen["survival-coop:bootstrap-crafting"], "game.yml-selected scenario missing")
		-- A native genre scenario bound to robango, and a pack-local one, are gated.
		assert(seen["survival-coop:archipelago-chain"], "missing robango-bound genre scenario")
		local localCount = 0
		for _, file in fs.readDir("games/robango-island/qa-scenarios") do
			local genre, name = string.match(file, "^([a-z][a-z0-9%-]*)%.([a-z][a-z0-9%-]*)%.yml$")
			if genre ~= nil and name ~= nil and seen[genre .. ":" .. name] then
				localCount += 1
			end
		end
		assert(localCount > 0, "no pack-local scenario gated")
	end,
}
