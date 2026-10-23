--!strict
local graph = require("./contentgraph")
local Content = require("../../../core/domain/survival/Content")
local command = require("../commands/content")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local tempdir = require("./tempdir")

local function fixture(): any
	local document: any = {
		version = 2,
		items = { { id = "wood" }, { id = "plank" }, { id = "beam" }, { id = "hide" } },
		recipes = {
			{
				id = "saw",
				inputs = { { item = "wood", quantity = 3 }, { item = "hide", quantity = 1 } },
				outputs = { { item = "plank", quantity = 1 } },
			},
			{
				id = "beam",
				inputs = { { item = "plank", quantity = 1 } },
				outputs = { { item = "beam", quantity = 1 } },
				station = "bench",
			},
		},
		recipeDetails = {
			{ id = "saw", primaryInputs = { "wood", "hide" }, primaryMaterialLevel = 10, skillNodes = {} },
			{ id = "beam", primaryInputs = { "plank" }, primaryMaterialLevel = 40, stationTier = 2, skillNodes = {} },
		},
		structures = { { id = "bench", station = true, cost = { { item = "wood", quantity = 1 } }, tier = 1 } },
		operations = {
			{
				id = "upgrade",
				kind = "upgrade",
				station = "bench",
				stationTier = 1,
				tier = 2,
				inputs = { { item = "plank", quantity = 1 } },
				outputs = {},
			},
			{
				id = "practice",
				kind = "practice",
				inputs = { { item = "wood", quantity = 1 } },
				outputs = {},
				gates = {},
			},
		} :: { any },
		layouts = {
			{
				id = "shore",
				resourceNodes = { { item = "wood", level = 60 } },
				spawns = { { speciesId = "deer", level = 20 } },
			},
		},
		wildlife = { { id = "deer" } },
		wildlifeDetails = { { id = "deer", level = 20, dropReservoirs = { { item = "hide", quantity = 1 } } } },
		skillCategories = {},
		skillNodes = { { id = "one", prerequisites = {} }, { id = "two", prerequisites = { "one" } } },
		guides = { { id = "guide", gates = {}, objectives = {}, rewards = { development = 200 } } },
		stages = { { id = "stage", gates = { developmentRank = 2 } } },
	}
	for _, id in
		{
			"survival",
			"butchering",
			"gathering",
			"processing",
			"weapon_tool",
			"ranged",
			"melee",
			"construction",
			"farming",
			"tailoring",
			"cooking",
			"defense",
		}
	do
		table.insert(document.skillCategories, { id = id, entryActions = { "practice" } })
	end
	return document
end

local tests = {
	["valid catalog closes transitive supply and reports counts"] = function()
		local result = graph.check(fixture())
		assert(result.ok and result.schemaVersion == 1, "graph invariant")
		assert(result.counts.recipes == 2 and result.counts.skillCategories == 12, "graph invariant")
		assert(result.rankPrefix[1].available == 200, "graph invariant")
	end,
	["removing raw supply fails closure even with a material profile"] = function()
		local doc = fixture()
		doc.layouts[1].resourceNodes = {}
		doc.materials = { { id = "wood", item = "wood", levels = { 60 }, sources = { "shore" } } }
		local result = graph.check(doc)
		assert(not result.ok and #result.unresolved == 4, "both recipes and both operations lose their supply")
		assert(result.unresolved[1].item == "wood", "graph invariant")
	end,
	["quantity weighted inherited level excludes auxiliary inputs"] = function()
		local doc = fixture()
		-- (3*60 + 1*20)/4 = 50, not the unweighted average 40.
		doc.recipeDetails[2].primaryMaterialLevel = 50
		assert(graph.check(doc).ok, "graph invariant")
		doc.recipeDetails[2].primaryMaterialLevel = 51
		local result = graph.check(doc)
		assert(not result.ok and result.levelFailures[1].available == 50, "graph invariant")
		doc.recipeDetails[1].primaryInputs = { "wood" }
		assert(graph.check(doc).ok, "auxiliary hide cannot lower inherited level")
	end,
	["each primary input must meet gate rather than just the average"] = function()
		local doc = fixture()
		doc.recipeDetails[1].primaryMaterialLevel = 30
		local result = graph.check(doc)
		assert(not result.ok and result.levelFailures[1].item == "hide", "graph invariant")
		assert(#result.unresolved == 0, "graph invariant")
	end,
	["station upgrade cannot require its own exclusive output"] = function()
		local doc = fixture()
		doc.operations[1].inputs[1].item = "beam"
		local result = graph.check(doc)
		assert(not result.ok and #result.stationCycles == 1, "graph invariant")
		assert(result.stationCycles[1].items[1] == "beam", "graph invariant")
		-- A hand producer is a genuine alternative, not a cycle.
		table.insert(doc.operations, {
			id = "hand-beam",
			inputs = { { item = "wood", quantity = 1 } },
			outputs = { { item = "beam", quantity = 1 } },
		})
		assert(graph.check(doc).ok, "graph invariant")
	end,
	["skill prerequisite cycle is reported with path"] = function()
		local doc = fixture()
		doc.skillNodes[1].prerequisites = { "two" }
		local result = graph.check(doc)
		assert(not result.ok and #result.skillCycles == 1 and #result.skillCycles[1] == 3, "graph invariant")
	end,
	["base station cannot require its own exclusive output"] = function()
		local doc = fixture()
		doc.structures[1].cost[1].item = "beam"
		assert(#graph.check(doc).stationCycles == 1, "base station construction is circular")
	end,
	["species provenance cannot borrow another species high level drops"] = function()
		local doc = fixture()
		table.insert(doc.layouts[1].resourceNodes, { item = "hide", level = 60 })
		doc.recipeDetails[1].sourceSpeciesId = "deer"
		doc.recipeDetails[1].primaryMaterialLevel = 30
		local result = graph.check(doc)
		assert(not result.ok and result.levelFailures[1].available == 20, "deer hide stays level twenty")
	end,
	["all twelve categories need a resolvable ungated entry action"] = function()
		local doc = fixture()
		doc.skillCategories[1].entryActions = { "unknown" }
		local result = graph.check(doc)
		assert(not result.ok and result.missingEntryActions[1] == "survival", "graph invariant")
		doc = fixture()
		doc.operations[2].gates.skillNodes = { "one" }
		assert(#graph.check(doc).missingEntryActions == 12, "graph invariant")
		doc = fixture()
		table.remove(doc.skillCategories)
		assert(#graph.check(doc).missingEntryActions == 1, "graph invariant")
	end,
	["every entry action is an engine event, a recipe or an executable operation kind"] = function()
		local doc = fixture()
		assert(#graph.check(doc).unhandledEntryActions == 0, "practice operations are executable")
		doc.operations[2].kind = "upgrade"
		local result = graph.check(doc)
		assert(not result.ok and #result.unhandledEntryActions == 12, "an upgrade row has no executor")
		assert(result.unhandledEntryActions[1].action == "practice", "graph invariant")
		doc = fixture()
		table.insert(doc.skillCategories[1].entryActions, "never-emitted")
		result = graph.check(doc)
		assert(not result.ok and result.unhandledEntryActions[1].category == "survival", "unknown event reported")
		assert(#result.missingEntryActions == 0, "the category itself still has a valid entry")
	end,
	["rank prefix excludes awards behind their own rank and stage gates"] = function()
		local doc = fixture()
		doc.guides[1].gates.developmentRank = 2
		local result = graph.check(doc)
		assert(not result.ok and not result.rankPrefix[1].ok and result.rankPrefix[1].available == 0, "graph invariant")
		doc.guides[1].gates = {}
		doc.guides[1].objectives = { { stageId = "stage" } }
		assert(not graph.check(doc).rankPrefix[1].ok, "graph invariant")
		doc.guides[1].objectives = {}
		doc.guides[1].gates.completed = { "missing" }
		assert(not graph.check(doc).rankPrefix[1].ok, "graph invariant")
	end,
	["wildlife must be placed and unplaced drops cannot seed materials"] = function()
		local doc = fixture()
		doc.layouts[1].spawns = {}
		local result = graph.check(doc)
		assert(not result.ok and result.unplacedSpecies[1] == "deer", "graph invariant")
		assert(result.unresolved[1].item == "hide", "graph invariant")
	end,
	["v1 remains compatible and CLI graph JSON round trips"] = function()
		local raw = {
			survival_content = 1,
			rules = table.clone(Content.RULES),
			limits = table.clone(Content.DEFAULT_LIMITS),
			items = { { id = "wood", name = "Wood", stackMax = 10, weightMilli = 1 } },
		}
		local canonical = assert(Content.canonicalize(raw))
		assert(graph.check(canonical).ok, "graph invariant")
		local dir = tempdir.path("contentgraph")
		fs.writeDir(dir)
		fs.writeFile(dir .. "/content.yml", serde.encode("yaml", raw))
		local ok, reason = pcall(function()
			assert(
				command.run({
					"content",
					"check",
					"--file",
					dir .. "/content.yml",
					"--graph-json",
					dir .. "/graph.json",
				}),
				"CLI check succeeds"
			)
			local result = serde.decode("json", fs.readFile(dir .. "/graph.json"))
			assert(result.ok and result.schemaVersion == 1 and result.counts.items == 1, "graph invariant")
			assert(
				fs.readFile(dir .. "/graph.json"):match('"unresolved"%s*:%s*%[%]'),
				"empty diagnostic list is a JSON array"
			)
			raw.survival_content = 2
			fs.writeFile(dir .. "/content.yml", serde.encode("yaml", raw))
			assert(not command.check(dir .. "/content.yml", dir .. "/graph.json"), "broken v2 graph rejects CLI check")
			local broken = serde.decode("json", fs.readFile(dir .. "/graph.json"))
			assert(not broken.ok and #broken.missingEntryActions == 12, "failure JSON is written before rejection")
		end)
		fs.removeDir(dir)
		assert(ok, tostring(reason))
	end,
}

tests["deliberate diagnostic mutations are killed by failure fixtures"] = function()
	local original = graph.check
	local cases = {
		{ field = "unresolved", test = "removing raw supply fails closure even with a material profile" },
		{ field = "levelFailures", test = "each primary input must meet gate rather than just the average" },
		{ field = "stationCycles", test = "station upgrade cannot require its own exclusive output" },
		{ field = "skillCycles", test = "skill prerequisite cycle is reported with path" },
		{ field = "missingEntryActions", test = "all twelve categories need a resolvable ungated entry action" },
		{ field = "rankPrefix", test = "rank prefix excludes awards behind their own rank and stage gates" },
		{
			field = "unhandledEntryActions",
			test = "every entry action is an engine event, a recipe or an executable operation kind",
		},
		{ field = "unplacedSpecies", test = "wildlife must be placed and unplaced drops cannot seed materials" },
	}
	for _, case in cases do
		graph.check = function(document: any): any
			local result = original(document)
			result[case.field] = if case.field == "rankPrefix" then { { ok = true, available = 200 } } else {}
			return result
		end
		local survived = pcall(tests[case.test])
		graph.check = original
		assert(not survived, "diagnostic mutation survived: " .. case.field)
		print("KILLED graph diagnostic mutation: " .. case.field)
	end
end

return tests
