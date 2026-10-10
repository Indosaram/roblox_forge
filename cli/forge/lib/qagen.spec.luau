--!strict
-- Specs for the derived native scenario: the document a spec's golden path
-- implies, and the namespaced resolution a pack-local artifact is addressed by.
-- No sleeps, no network; the registry and packs are temporary directories.

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local qagen = require("./qagen")
local qascenario = require("./qascenario")
local qaCommand = require("../commands/qa")

local function spec(): any
	return {
		api = 1,
		id = "counter",
		runtime = "counter",
		qa = {
			name = "golden-path",
			players = { "alpha", "beta" },
			starterState = { count = 0 },
			goldenPath = {
				{ op = "begin_clock" },
				{ op = "join", player = "alpha" },
				{
					op = "dispatch",
					player = "alpha",
					action = "counter:increment",
					args = {},
					expect = "ok",
				},
				{
					op = "expect_snapshot",
					player = "alpha",
					genre = "counter",
					field = "count",
					equals = 1,
				},
			},
			crafting = {
				goldenPath = {
					{ op = "begin_clock" },
					{ op = "join", player = "alpha" },
					{
						op = "expect_snapshot",
						player = "alpha",
						genre = "counter",
						field = "count",
						equals = 0,
					},
				},
			},
		},
	}
end

local function identity(): any
	return { name = qagen.name(spec()), genre = "counter", pack = "counter-sweep" }
end

local function sandbox(): string
	local root = ".omo/fixtures/qagen-" .. serde.hash("sha256", tostring(os.clock())):sub(1, 12)
	local function write(path: string, text: string): ()
		local directory = string.match(path, "^(.*)/[^/]+$")
		if directory ~= nil then
			fs.writeDir(directory)
		end
		fs.writeFile(path, text)
	end
	write(root .. "/games/counter-pack/game.yml", "name: Counter\nslug: counter-pack\ngenres: [counter]\n")
	write(root .. "/games/both-pack/game.yml", "name: Both\nslug: both-pack\ngenres: [counter, other]\n")
	write(root .. "/games/counter-pack/qa-scenarios/counter.golden-path.yml", "name: golden-path\n")
	write(root .. "/genres/counter/qa-scenarios/contract-loop.yml", "name: contract-loop\n")
	write(root .. "/genres/counter/qa-scenarios/shared.yml", "name: shared\n")
	write(root .. "/genres/other/qa-scenarios/shared.yml", "name: shared\n")
	return root
end

local function registry(root: string): any
	return {
		root = root .. "/genres",
		order = { "counter", "other" },
		packages = {
			counter = { id = "counter", path = root .. "/genres/counter" },
			other = { id = "other", path = root .. "/genres/other" },
		},
		runtimes = {},
	}
end

local function withSandbox(body: (string, any) -> ()): ()
	local root = sandbox()
	local ok, reason = pcall(function()
		body(root, registry(root))
		return nil
	end)
	if fs.isDir(root) then
		fs.removeDir(root)
	end
	assert(ok, tostring(reason))
end

return {
	["the derived document carries identity, players and the golden path verbatim"] = function()
		local derived = qagen.derive(spec(), identity(), nil)
		assert(derived.name == "golden-path" and derived.kind == "native", "identity")
		assert(derived.genre == "counter" and derived.pack == "counter-sweep", "binding")
		assert(derived.contract_api == qascenario.CONTRACT_API, "contract api")
		assert(#derived.players == 2 and derived.players[1] == "alpha", "players")
		assert(#derived.steps == #spec().qa.goldenPath, "steps are copied verbatim")
		assert(#qascenario.validate(derived) == 0, table.concat(qascenario.validate(derived), "; "))
	end,

	["a mode block is merged over the shared keys"] = function()
		local shared: any = { name = "golden-path", players = { "alpha" }, goldenPath = { { op = "begin_clock" } } }
		local merged = qagen.block({ qa = shared }, nil)
		assert(merged == shared, "no mode selects the shared block")
		local raw = spec()
		local crafting = qagen.block(raw, "crafting")
		assert(#crafting.goldenPath == 3, "the crafting mode selects its own path")
		assert(crafting.players[1] == "alpha", "shared keys are inherited")
		assert(#raw.qa.goldenPath == 4, "the spec is not mutated")
	end,

	["the pack-local artifact name uses the dotted form"] = function()
		assert(qagen.fileName("counter", "golden-path") == "counter.golden-path.yml", "dotted file name")
	end,

	["a derived scenario survives the YAML round trip the pack artifact takes"] = function()
		local derived = qagen.derive(spec(), identity(), nil)
		local encoded = serde.encode("yaml", derived)
		local decoded = serde.decode("yaml", encoded)
		assert(#qascenario.validate(decoded) == 0, table.concat(qascenario.validate(decoded), "; "))
		assert(decoded.steps[3].action == "counter:increment", "action identity survives")
		assert(decoded.steps[4].equals == 1, "expectations survive")
	end,

	["a namespaced reference resolves pack-local first, then the genre directory"] = function()
		withSandbox(function(root, reg)
			local localArtifact =
				qaCommand.resolveScenario("counter:golden-path", "counter-pack", root .. "/games", reg)
			assert(localArtifact ~= nil, "pack-local artifact resolves")
			assert(
				string.find(localArtifact.path, "games/counter%-pack/qa%-scenarios/counter%.golden%-path%.yml") ~= nil,
				"pack-local path: " .. localArtifact.path
			)
			assert(
				localArtifact.genre == "counter" and localArtifact.name == "golden-path",
				"identity from the file name"
			)
			local genreFile = qaCommand.resolveScenario("counter:contract-loop", "counter-pack", root .. "/games", reg)
			assert(genreFile ~= nil, "genre scenario resolves")
			assert(
				string.find(genreFile.path, "genres/counter/qa%-scenarios/contract%-loop%.yml") ~= nil,
				"genre path: " .. genreFile.path
			)
			local unknown = qaCommand.resolveScenario("absent:contract-loop", "counter-pack", root .. "/games", reg)
			assert(unknown == nil, "an unknown genre is refused")
		end)
	end,

	["a bare name resolves only when the pack's genres make it unambiguous"] = function()
		withSandbox(function(root, reg)
			local unique = qaCommand.resolveScenario("contract-loop", "counter-pack", root .. "/games", reg)
			assert(unique ~= nil and unique.genre == "counter", "one candidate resolves")
			local ambiguous, errors = qaCommand.resolveScenario("shared", "both-pack", root .. "/games", reg)
			assert(ambiguous == nil, "two candidates do not resolve")
			assert(
				string.find(table.concat(errors, "; "), "counter:shared or other:shared", 1, true) ~= nil,
				"the ambiguity names the namespaced forms: " .. table.concat(errors, "; ")
			)
			-- The pack's own genre list is what narrows a bare name: a pack that
			-- declares one genre has no ambiguity to report.
			local narrowed = qaCommand.resolveScenario("shared", "counter-pack", root .. "/games", reg)
			assert(narrowed ~= nil and narrowed.genre == "counter", "the pack's genres narrow the search")
			local missing, missingErrors = qaCommand.resolveScenario("absent", "counter-pack", root .. "/games", reg)
			assert(
				missing == nil and string.find(missingErrors[1], "not found", 1, true) ~= nil,
				"a missing name fails"
			)
			local unsafe = qaCommand.resolveScenario("../escape", "counter-pack", root .. "/games", reg)
			assert(unsafe == nil, "an unsafe name is refused")
		end)
	end,

	["a namespaced name that is not a genre scenario fails loudly"] = function()
		withSandbox(function(root, reg)
			local resolution, errors =
				qaCommand.resolveScenario("counter:absent", "counter-pack", root .. "/games", reg)
			assert(resolution == nil and #errors == 1, "missing namespaced scenario fails")
			assert(string.find(errors[1], "not found", 1, true) ~= nil, errors[1])
		end)
	end,
}
