--!strict
local serde = require("@lune/serde")
local check = require("./check")

local function enabled(options: any): { string }
	local ids = {}
	for _, id in check.STAGES do
		if options.run[id] then
			table.insert(ids, id)
		end
	end
	return ids
end

return {
	["no stage flags run every stage and keep selectors"] = function()
		local options, err = check.parseStageArgs({ "check", "--pack", "kaiju-egg-raiders" }, 2)
		assert(options ~= nil, err)
		assert(#enabled(options) == #check.STAGES, "every stage should run")
		assert(options.jsonPath == nil, "no json path")
		assert(
			#options.rest == 2 and options.rest[1] == "--pack" and options.rest[2] == "kaiju-egg-raiders",
			"expected: #options.rest == 2 and options.rest[1] == '--pack' and options.rest[2] == 'kaiju-egg-raiders'"
		)
	end,
	["--only selects listed stages in canonical order"] = function()
		local options, err = check.parseStageArgs({ "check", "--only", "game,econ" }, 2)
		assert(options ~= nil, err)
		assert(table.concat(enabled(options), ",") == "econ,game", table.concat(enabled(options), ","))
	end,
	["--skip removes stages and --json captures the path"] = function()
		local options, err =
			check.parseStageArgs({ "check", "--skip", "specs,build,luau-lsp", "--json", "/tmp/c.json", "--all" }, 2)
		assert(options ~= nil, err)
		local ids = enabled(options)
		assert(#ids == #check.STAGES - 3, tostring(#ids))
		assert(
			not options.run.specs and not options.run.build and not options.run["luau-lsp"],
			"expected: not options.run.specs and not options.run.build and not options.run['luau-lsp']"
		)
		assert(options.jsonPath == "/tmp/c.json", "expected: options.jsonPath == '/tmp/c.json'")
		assert(
			#options.rest == 1 and options.rest[1] == "--all",
			"expected: #options.rest == 1 and options.rest[1] == '--all'"
		)
	end,
	["unknown stage is a usage error listing every stage"] = function()
		local options, err = check.parseStageArgs({ "check", "--only", "nosuch" }, 2)
		assert(options == nil, "expected: options == nil")
		assert(string.find(err or "", "unknown stage 'nosuch'", 1, true), err)
		for _, id in check.STAGES do
			assert(string.find(err or "", id, 1, true), id)
		end
	end,
	["missing values and duplicate flags are rejected"] = function()
		assert(
			check.parseStageArgs({ "check", "--only" }, 2) == nil,
			"expected: check.parseStageArgs({ 'check', '--only' }, 2) == nil"
		)
		assert(
			check.parseStageArgs({ "check", "--skip", "--all" }, 2) == nil,
			"expected: check.parseStageArgs({ 'check', '--skip', '--all' }, 2) == nil"
		)
		assert(
			check.parseStageArgs({ "check", "--json" }, 2) == nil,
			"expected: check.parseStageArgs({ 'check', '--json' }, 2) == nil"
		)
		assert(
			check.parseStageArgs({ "check", "--only", "econ", "--only", "game" }, 2) == nil,
			"expected: check.parseStageArgs({ 'check', '--only', 'econ', '--only', 'game' }, 2) == nil"
		)
	end,
	["json report encodes an empty failed list as an array"] = function()
		local text = check.encodeReport({
			schemaVersion = 1,
			ok = true,
			stages = { { id = "econ", ok = true, skipped = false, ms = 1 } },
			failed = {},
		})
		local decoded = serde.decode("json", text)
		assert(decoded.schemaVersion == 1 and decoded.ok == true, "report fields lost")
		assert(string.find(text, '"failed": []', 1, true) ~= nil, text)
		local failing = check.encodeReport({ schemaVersion = 1, ok = false, stages = {}, failed = { "econ" } })
		assert(serde.decode("json", failing).failed[1] == "econ", failing)
	end,
	["run rejects an unknown stage before any tool runs"] = function()
		assert(
			check.run({ "check", "--only", "nosuch" }) == false,
			"expected: check.run({ 'check', '--only', 'nosuch' }) == false"
		)
	end,
}
