--!strict
-- Specs for `forge spec init`: the draft it writes is a valid but incomplete
-- binding document, so the catalog keeps loading while an agent fills it in.
-- No filesystem outside a temporary sandbox, no network, no sleeps.

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local specCommand = require("./spec")
local genrespec = require("../lib/genrespec")

local function runtime(): any
	return {
		api = 1,
		id = "counter",
		configVersion = 1,
		saveVersion = 1,
		actions = {
			{ id = "increment", args = {}, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		},
		events = { "CountChanged" },
		hooks = { "CountChanged" },
		validateConfig = function()
			return {}
		end,
		validateSave = function()
			return {}
		end,
		create = function()
			return {}
		end,
	}
end

--- A scratch genre directory with the templates `init` seeds from.
local function genreDir(): string
	local root = ".omo/fixtures/spec-init-" .. serde.hash("sha256", tostring(os.clock())):sub(1, 12)
	fs.writeDir(root)
	fs.writeFile(
		root .. "/econ-template.yml",
		serde.encode("yaml", {
			currencies = { { id = "Coins", kind = "free", starting = 0 } },
			sources = { { id = "sell-crop", currency = "Coins" } },
		})
	)
	fs.writeFile(root .. "/design-template.md", "# counter design template\n\nPress the button.\n")
	return root
end

return {
	["the draft loads and validates as a draft"] = function()
		local root = genreDir()
		local text = specCommand.draft("counter", "a counting game", "counter-pack", root)
		local path = root .. "/genre-spec.yml"
		fs.writeFile(path, text)
		local draft = assert(genrespec.load(path))
		assert(draft.draft == true, "the draft is marked")
		assert(draft.id == "counter" and draft.runtime == "counter", "identity comes from the genre")
		assert(draft.resources[1].id == "coins", "the resource is seeded from the econ template")
		assert(draft.qa.goldenPath ~= nil and #draft.qa.goldenPath == 0, "the draft asserts nothing yet")
		assert(#genrespec.validate(draft, runtime(), { id = "counter", path = root }) == 0, "the draft is valid")
		fs.removeDir(root)
	end,

	["the draft records the concept and the pack it was seeded for"] = function()
		local root = genreDir()
		local text = specCommand.draft("counter", "a counting game", "counter-pack", root)
		assert(string.find(text, "# concept: a counting game", 1, true) ~= nil, "the concept is recorded")
		assert(string.find(text, "# pack: counter-pack", 1, true) ~= nil, "the pack is recorded")
		assert(string.find(text, "Press the button.", 1, true) ~= nil, "the design template's loop is recorded")
		fs.removeDir(root)
	end,

	["a genre with no templates still gets a draft that loads"] = function()
		local root = ".omo/fixtures/spec-init-empty-" .. serde.hash("sha256", tostring(os.clock())):sub(1, 12)
		fs.writeDir(root)
		local text = specCommand.draft("counter", nil, nil, root)
		local path = root .. "/genre-spec.yml"
		fs.writeFile(path, text)
		local draft = assert(genrespec.load(path))
		assert(draft.resources[1].id == "coins", "the fallback currency keeps the draft loadable")
		assert(#genrespec.validate(draft, runtime(), { id = "counter", path = root }) == 0, "the draft is valid")
		fs.removeDir(root)
	end,

	["init refuses to overwrite an existing spec without --force"] = function()
		-- Against the real catalog: every shipped genre already declares a spec, so
		-- init must refuse and leave those bytes untouched.
		local before = fs.readFile("genres/grow-harvest/genre-spec.yml")
		local ok = specCommand.run({ "spec", "init", "--genre", "grow-harvest", "--concept", "overwrite attempt" })
		assert(not ok, "an existing spec is never silently replaced")
		assert(fs.readFile("genres/grow-harvest/genre-spec.yml") == before, "the shipped spec is unchanged")
		assert(specCommand.run({ "spec", "validate", "--genre", "grow-harvest" }), "the spec still validates")
	end,
}
