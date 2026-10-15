--!strict
local registryLib = require("./genreregistry")
local generate = require("./genregenerate")
local serde = require("@lune/serde")
local checkCommand = require("../commands/check")
local contract = require("./genrecontract")
local localeSync = require("./localesync")
local qualityprofile = require("./qualityprofile")
local fs = require("@lune/fs")
local tempdir = require("./tempdir")
local publish = require("./genrepublish")
local function fixture(callback: (string) -> ())
	local root = generate.absolute(
		tempdir.root() .. "/forge-regeneration-" .. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
	)
	assert(not fs.isDir(root), "fixture collision")
	generate.ensureDir(root)
	local original = publish.write
	local ok, reason = xpcall(function()
		callback(root)
	end, debug.traceback)
	publish.write = original
	fs.removeDir(root)
	assert(ok, tostring(reason))
end
local function registry(): registryLib.Registry
	local found, errors = registryLib.discover("cli/forge/fixtures/genres")
	assert(found ~= nil, table.concat(errors, "; "))
	return found
end
local input = {
	mode = "new" :: "new",
	slug = "counter",
	pascal = "Counter",
	title = "Counter",
	concept = "",
	seed = 7,
	teams = { "Red", "Blue" },
	debugName = "CounterDebug",
	guiName = "CounterGui",
}
return {
	["six registered genres retain deterministic plan contracts"] = function()
		local found = assert(registryLib.discover())
		local value: contract.GenerateInput = table.clone(input)
		value.mode = "plan"
		value.concept = "Crystal island explorers"
		for _, id in
			{ "collect-raid", "grow-harvest", "survival-coop", "rpg-progression", "social-rp-fashion", "pvp-arena" }
		do
			local a = generate.assemble(found, { id }, value, ".omo/wip/counter")
			local b = generate.assemble(found, { id }, value, ".omo/wip/counter")
			for path, text in a.files do
				assert(b.files[path] == text, id .. ": " .. path)
			end
			for path in b.files do
				assert(a.files[path] ~= nil, id .. ": unexpected " .. path)
			end
			assert(a.order[1] == id and #a.order == 1, "genre contract retained")
		end
	end,
	["authored hooks survive and unknown hook versions fail before writes"] = function()
		fixture(function(root)
			local destination = root .. "/counter"
			generate.ensureDir(destination .. "/src/server")
			local a = generate.assemble(registry(), { "fixture-counter" }, input, destination)
			local path = destination .. "/src/server/GenreHooks.luau"
			local authored = a.files["src/server/GenreHooks.luau"] .. "-- authored callback\n"
			fs.writeFile(path, authored)
			local b = generate.assemble(registry(), { "fixture-counter" }, input, destination)
			assert(b.files["src/server/GenreHooks.luau"] == authored, "authored bytes lost")
			local future = string.gsub(authored, "forge%-hooks:1:", "forge-hooks:99:")
			fs.writeFile(path, future)
			local ok, reason = pcall(generate.assemble, registry(), { "fixture-counter" }, input, destination)
			assert(not ok and string.find(tostring(reason), "FORGE_REGEN_CONFLICT:", 1, true), tostring(reason))
			assert(fs.readFile(path) == future, "rejection wrote hooks")
		end)
	end,
	["stale transaction and unsafe artifact paths reject without publication"] = function()
		fixture(function(root)
			local destination = root .. "/counter"
			local assembly = {
				files = { ["../escape"] = "bad" } :: { [string]: string },
				order = {},
				generation = {},
				legacy = false,
			}
			publish.write = function()
				error("publisher must not run")
			end
			local ok, reason = generate.write(assembly, destination, "counter", { packsDir = root })
			assert(
				not ok and string.find(reason :: string, "FORGE_INVALID_CATALOG:", 1, true),
				'not ok and string.find(reason :: string, "FORGE_INVALID_CATALOG:", 1, true)'
			)
			assert(not fs.isDir(destination .. ".forge-stage"), "invalid input staged")
			generate.ensureDir(destination .. ".forge-backup")
			fs.writeFile(destination .. ".forge-backup/prior", "preserved")
			assembly.files = { ["game.yml"] = "new" }
			ok, reason = generate.write(assembly, destination, "counter", { packsDir = root })
			assert(
				not ok and string.find(reason :: string, "FORGE_REGEN_CONFLICT:", 1, true),
				'not ok and string.find(reason :: string, "FORGE_REGEN_CONFLICT:", 1, true)'
			)
			assert(
				fs.readFile(destination .. ".forge-backup/prior") == "preserved",
				'fs.readFile(destination .. ".forge-backup/prior") == "preserved"'
			)
		end)
	end,
	["generated locale supports actual offline sync payload"] = function()
		local assembly = generate.assemble(registry(), { "fixture-counter" }, input, ".omo/wip/counter")
		local csv = assembly.files["locale/strings.csv"]
		-- The pack's localization table is generated from the spec's declared keys, so every
		-- key the HUD renders is present with its display string as the source text: a key
		-- the spec declares can never be missing from the pack.
		local payload, reason = localeSync.buildPayload(csv)
		assert(payload ~= nil, tostring(reason))
		assert(#payload.locales == 2, "two locale columns")
		local byKey: { [string]: any } = {}
		for _, entry in payload.entries do
			byKey[entry.key] = entry
		end
		assert(#payload.entries == 4, "one entry per declared key, got " .. tostring(#payload.entries))
		assert(
			byKey["increment_label"] ~= nil
				and byKey["increment_label"].source == "Increment"
				and byKey["increment_label"].translations["en-us"] == "Increment"
				and byKey["increment_label"].translations["ko-kr"] == "증가",
			"the control key carries its display text in both languages"
		)
		assert(
			byKey["loop_count"] ~= nil and byKey["loop_count"].source == "Count once",
			"the objective key carries its display text"
		)
		local appended, err = localeSync.buildPayload(csv .. "greeting,Hello,menu,Hello,Annyeong\n")
		assert(appended ~= nil, tostring(err))
		local greeting = appended.entries[#appended.entries]
		assert(
			greeting.key == "greeting" and greeting.source == "Hello" and greeting.context == "menu",
			"identity fields parsed"
		)
		assert(
			greeting.translations["en-us"] == "Hello" and greeting.translations["ko-kr"] == "Annyeong",
			"translations parsed"
		)
	end,
	["prop-only launchart is rejected before publication"] = function()
		local found = registry()
		local generator = table.clone(found.packages["fixture-counter"].generator)
		local original = generator.generate
		generator.generate = function(value)
			local generated = original(value)
			generated.generation = { "procedural", "launchart", "audio" }
			return generated
		end
		found.packages["fixture-counter"].generator = generator
		local ok, reason = pcall(generate.assemble, found, { "fixture-counter" }, input, ".omo/wip/counter")
		assert(not ok, "prop-only launchart accepted")
		assert(string.find(tostring(reason), "no creature entries", 1, true), tostring(reason))
	end,
	["procedural preflight resolves actual legacy poly budget"] = function()
		local found = registry()
		local generator = table.clone(found.packages["fixture-counter"].generator)
		local original = generator.generate
		generator.legacy = {
			generate = function(value)
				local generated = original(value)
				for _, artifact in generated.artifacts do
					artifact.path = string.gsub(artifact.path, "assets/fixture%-counter/", "assets/")
				end
				table.insert(generated.artifacts, { path = "game.yml", content = "poly_budget: {prop: 1}\n" })
				table.insert(generated.artifacts, { path = "econ.yml", content = "{}\n" })
				table.insert(generated.artifacts, { path = "design/README.md", content = "# Counter\n" })
				return generated
			end,
			codegen = function(_text)
				return "--!strict\nreturn {}\n"
			end,
		}
		found.packages["fixture-counter"].generator = generator
		local ok, reason = pcall(generate.assemble, found, { "fixture-counter" }, input, ".omo/wip/counter")
		assert(not ok, "over-budget procedural input accepted")
		assert(string.find(tostring(reason), "exceeds budget", 1, true), tostring(reason))
	end,
	["recipe metadata requires declared owner and complete driver"] = function()
		local generator = table.clone(registry().packages["fixture-counter"].generator)
		generator.recipes = {
			unknown = {
				normalize = function(configs)
					return configs
				end,
				driver = generator.driver,
			},
		}
		assert(#contract.validateGenerator(generator, generator.runtime) > 0, "undeclared recipe accepted")
		local runtime = table.clone(generator.runtime)
		runtime.recipe = {
			id = "paired",
			partners = { "fixture-counter", "other" },
			create = function(_configs, _services)
				return {}
			end,
		}
		generator.runtime = runtime
		generator.recipes = {
			paired = {
				normalize = function(configs)
					return configs
				end,
				driver = { run = generator.driver.run, simulate = nil :: any },
			},
		}
		assert(#contract.validateGenerator(generator, runtime) > 0, "incomplete recipe driver accepted")
	end,
	["legacy asset syntax is capability gated and rejects paths"] = function()
		local generator = table.clone(registry().packages["fixture-counter"].generator)
		generator.legacy = {
			generate = generator.generate,
			codegen = function(_text)
				return ""
			end,
		}
		local generated = generator.generate(input)
		generated.assetKeys = { "musicExplore", "sfxHatch", "sfxCoin" }
		assert(#contract.validateGenerated(generated, generator) == 0, "legacy camelCase keys rejected")
		generated.assetKeys = { "../musicExplore" }
		assert(#contract.validateGenerated(generated, generator) > 0, "legacy path key accepted")
		generator.legacy = nil
		generated.assetKeys = { "musicExplore" }
		assert(#contract.validateGenerated(generated, generator) > 0, "new format accepted legacy keys")
	end,
	["check contract stage validates new config and qualified QA in memory"] = function()
		local found = registry()
		local assembly = generate.assemble(found, { "fixture-counter" }, input, ".omo/wip/counter")
		local game = serde.decode("yaml", assembly.files["game.yml"])
		local config = serde.decode("yaml", assembly.files["econ.yml"])
		assert(#checkCommand.validatePackContract(game, config, found) == 0, "valid generated config rejected")
		config.genre_contract.configs["fixture-counter"].target = 0
		assert(#checkCommand.validatePackContract(game, config, found) > 0, "invalid config bypassed check")
	end,
	["same input emits same machine bytes"] = function()
		local a = generate.assemble(registry(), { "fixture-counter" }, input, ".omo/wip/counter")
		local b = generate.assemble(registry(), { "fixture-counter" }, input, ".omo/wip/counter")
		for path, text in a.files do
			assert(b.files[path] == text, path)
		end
		assert(a.files["src/shared/EconConfig.luau"] == nil, "new format emitted legacy economy")
		local doc = serde.decode("yaml", a.files["econ.yml"])
		local project = serde.decode("json", a.files["default.project.json"])
		assert(
			project.tree.ServerScriptService.GenreHooks["$path"] == "src/server/GenreHooks.luau",
			"server hooks not mounted"
		)
		assert(
			project.tree.ServerScriptService.PersistenceConfig["$path"] == "src/server/PersistenceConfig.luau"
				and a.files["src/server/PersistenceConfig.luau"] ~= nil,
			"generated persistence config not mounted"
		)
		assert(doc.genre_contract.configs["fixture-counter"].target == 2, "config not persisted")
		-- Generation emits the honest starter declaration: a pack that cannot back a
		-- higher tier must not claim one, and the emitted document has to validate.
		assert(a.files["quality.yml"] ~= nil, "generated pack carries no quality profile")
		local profile = qualityprofile.parse(serde.decode("yaml", a.files["quality.yml"]))
		assert(profile ~= nil, "generated quality profile does not validate")
		assert(profile.tier == "starter", "a generated pack may only declare the starter tier")
		assert(profile.pack == "counter", "generated profile names the wrong pack")
	end,
	["unknown and repeated selections fail in memory"] = function()
		assert(not pcall(generate.assemble, registry(), { "unknown" }, input, ".omo/wip/counter"), "unknown accepted")
		assert(
			not pcall(
				generate.assemble,
				registry(),
				{ "fixture-counter", "fixture-counter" },
				input,
				".omo/wip/counter"
			),
			"duplicate accepted"
		)
	end,
	["common output cannot be claimed by package artifact"] = function()
		local found = registry()
		local generator = table.clone(found.packages["fixture-counter"].generator)
		local original = generator.generate
		generator.generate = function(value)
			local generated = original(value)
			table.insert(generated.artifacts, { path = "game.yml", content = "invalid" })
			return generated
		end
		found.packages["fixture-counter"].generator = generator
		assert(
			not pcall(generate.assemble, found, { "fixture-counter" }, input, ".omo/wip/counter"),
			"common collision accepted"
		)
	end,
	["unsafe paths and undeclared action controls fail before writes"] = function()
		for _, mutation in
			{
				function(generated: any)
					generated.artifacts[1].path = "assets/fixture-counter/../escape.yml"
				end,
				function(generated: any)
					generated.controls[1].action = "fixture-counter:unknown"
				end,
				function(generated: any)
					generated.config.target = 0
				end,
			}
		do
			local found = registry()
			local generator = table.clone(found.packages["fixture-counter"].generator)
			local original = generator.generate
			generator.generate = function(value)
				local generated = original(value)
				mutation(generated)
				return generated
			end
			found.packages["fixture-counter"].generator = generator
			assert(
				not pcall(generate.assemble, found, { "fixture-counter" }, input, ".omo/wip/counter"),
				"invalid generation accepted"
			)
		end
	end,
}
