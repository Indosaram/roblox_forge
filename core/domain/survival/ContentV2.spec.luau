--!strict
local Content = require("./Content")
local V2 = require("./ContentV2")
local contract = require("../../../cli/forge/lib/genrecontract")

local function fixture(): any
	local provenance = { classification = "RECONSTRUCTED" }
	return {
		survival_content = 2,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		items = { { id = "fiber", name = "Fiber", stackMax = 50, weightMilli = 1 } },
		skillCategories = {
			{
				id = "tailoring",
				provenance = provenance,
				nameKey = "skills.tailoring",
				entryActions = { "practice-stitch" },
			},
		},
		skillNodes = {
			{
				id = "tailoring_1",
				provenance = provenance,
				category = "tailoring",
				rank = 1,
				cost = 2,
				proficiency = 1,
				prerequisites = {},
				effects = { { id = "recipes", value = 1, unit = "tier" } },
			},
		},
		operations = {
			{
				id = "practice-stitch",
				provenance = provenance,
				kind = "practice",
				inputs = { { item = "fiber", quantity = 2 } },
				outputs = {},
				seconds = 3,
				effects = {},
			},
		},
	}
end

local function rejected(change: (any) -> (), fragment: string)
	local raw = fixture()
	change(raw)
	local errors = Content.validate(raw)
	assert(string.find(table.concat(errors, "\n"), fragment, 1, true), table.concat(errors, "\n"))
end

return {
	["v2 policy rejects missing tree fields and unknown item policy references"] = function()
		rejected(function(raw)
			raw.progressionPolicy = { tree = {} }
		end, "progressionPolicy.tree.maxLevel")
		rejected(function(raw)
			raw.progressionPolicy = { feed = { missing = true } }
		end, "unknown item reference missing")
		rejected(function(raw)
			raw.progressionPolicy = { foodFamilies = { fiber = "unknown" } }
		end, "expected stamina, recovery or resistance")
	end,
	["v2 carries every detailed catalog and validates recipe projection constraints"] = function()
		local raw = fixture()
		local p = { classification = "RECONSTRUCTED" }
		local point = { x = 0, y = 2, z = 0 }
		local bounds = { min = { x = -384, y = 0, z = -320 }, max = { x = 384, y = 64, z = 320 } }
		raw.recipes = {
			{
				id = "sample",
				craftMillis = 3000,
				inputs = { { item = "fiber", quantity = 2 } },
				outputs = { { item = "fiber", quantity = 1 } },
			},
		}
		-- Use a separate output so the legacy production graph has no self-cycle.
		table.insert(raw.items, { id = "sample", name = "Sample", stackMax = 1, weightMilli = 1 })
		raw.recipes[1].outputs[1].item = "sample"
		raw.wildlife = { { id = "direWolf", behavior = "hunter" } }
		raw.materials = {
			{
				id = "fiber",
				provenance = p,
				item = "fiber",
				attributes = {
					hardness = 0,
					flexibility = 4,
					sharpness = 0,
					insulation = 1,
					nutrition = 0,
					fertility = 1,
				},
				levels = { 60, 1 },
				quality = 0,
				processingBudget = 3,
				sources = { "shore" },
			},
		}
		raw.recipeDetails = {
			{
				id = "sample",
				provenance = p,
				minCharacterLevel = 1,
				primaryMaterialLevel = 0,
				primaryInputs = { "fiber" },
				auxiliaryInputs = {},
				skillNodes = { "tailoring_1" },
				seconds = 3,
				sourceSpeciesId = "direWolf",
			},
		}
		raw.wildlifeDetails = {
			{
				id = "direWolf",
				provenance = p,
				level = 40,
				health = 450,
				damage = 42,
				walkSpeed = 8,
				runSpeed = 25,
				biomes = { "snow" },
				behaviour = "predator",
				sense = 24,
				leash = 60,
				attacks = {
					{ id = "bite", damage = 42, windupSeconds = 0.7, range = 5, recoverySeconds = 2, shape = "cone" },
				},
				dropReservoirs = { { item = "fiber", quantity = 1 } },
				captureClass = "advanced",
				mount = { enabled = true, cargoSlots = 8, walkSpeed = 8, runSpeed = 25, stamina = 100, effects = {} },
			},
		}
		raw.layouts = {
			{
				id = "rw.a1.s1",
				provenance = p,
				bounds = bounds,
				biomes = { "snow" },
				anchors = { { id = "entry", position = point } },
				resourceNodes = {
					{
						id = "fiber",
						item = "fiber",
						position = point,
						stock = 20,
						level = 40,
						yield = 3,
						respawnSeconds = 120,
					},
				},
				spawns = {
					{ id = "wolf", speciesId = "direWolf", position = point, count = 1, level = 40, radius = 8 },
				},
				hazards = {
					{ id = "cold", kind = "cold", position = point, radius = 16, intensity = 10, effects = {} },
				},
				refuges = { { id = "refuge", bounds = bounds } },
				paths = { { id = "route", points = { point, { x = 10, y = 2, z = 0 } }, width = 16 } },
			},
		}
		raw.stages = {
			{
				id = "stage",
				provenance = p,
				layout = "rw.a1.s1",
				gates = { characterLevel = 40 },
				objectives = { { id = "hunt", action = "hunt", target = "direWolf", quantity = 1 } },
			},
		}
		raw.supportRegions =
			{ { id = "frontier40", provenance = p, layout = "rw.a1.s1", gates = {}, role = "frontier" } }
		for _, section in { "missions", "guides", "chapters" } do
			raw[section] = {
				{
					id = section .. ".one",
					provenance = p,
					gates = { skillNodes = { "tailoring_1" } },
					objectives = {
						{ id = "craft", action = "craft", target = "sample", quantity = 1, stageId = "stage" },
					},
					rewards = { xp = 10, coins = 25, items = { { item = "fiber", quantity = 1 } } },
					dialogueKeys = { "quest.offer", "quest.complete" },
				},
			}
		end
		local document, errors = Content.canonicalize(raw)
		assert(document, table.concat(errors, "\n"))
		for _, section in V2.SECTIONS do
			assert((document :: any)[section] ~= nil, "detailed section retained " .. section)
		end
		raw.recipeDetails[1].seconds = 4
		assert(Content.canonicalize(raw) == nil, "inconsistent recipe timing rejected")
		raw.recipeDetails[1].seconds = 3
		raw.recipeDetails[1].auxiliaryInputs = { "fiber" }
		assert(Content.canonicalize(raw) == nil, "primary and auxiliary ingredient roles cannot overlap")
	end,
	["v2 canonicalizes catalogs deterministically and preserves v1 projection"] = function()
		local raw = fixture()
		raw.limits.slots = 30
		raw.limits.tribeMaxMembers = 50
		local document, errors = Content.canonicalize(raw)
		assert(document, table.concat(errors, "\n"))
		assert(
			document.version == 2 and document.limits.slots == 30 and document.limits.tribeMaxMembers == 50,
			"explicit v2 policy"
		)
		local encoded = contract.serialize(document)
		raw.skillNodes[1].cost = 4
		assert(contract.serialize(document) == encoded, "canonical data owns every nested authored value")
		local projected = Content.projectV1(document)
		assert(
			projected.survival_content == 2 and projected.skillNodes == nil and projected.version == nil,
			"runtime projection retains explicit v2 policy opt-in without detailed catalogs"
		)
		local restored, projectionErrors = Content.canonicalize(projected)
		assert(restored, table.concat(projectionErrors, "; "))
		assert(restored.limits.slots == 30 and restored.limits.tribeMaxMembers == 50, "runtime limits round trip")
		assert(
			contract.serialize(V2.canonical({ { id = "z" }, { id = "a" } }))
				== contract.serialize({ { id = "a" }, { id = "z" } }),
			"catalogs sorted by identity"
		)
		local old = fixture()
		old.survival_content = 1
		for _, section in V2.SECTIONS do
			old[section] = nil
		end
		assert(#Content.validate(old) == 0, "legacy fixture remains valid")
		old.limits.slots = 30
		assert(#Content.validate(old) > 0, "v1 defaults and policy stay unchanged")
	end,
	["v2 rejects duplicate ids"] = function()
		rejected(function(raw)
			table.insert(raw.skillNodes, table.clone(raw.skillNodes[1]))
		end, "duplicate id tailoring_1")
	end,
	["v2 rejects unknown ingredients"] = function()
		rejected(function(raw)
			raw.operations[1].inputs[1].item = "missing"
		end, "unknown items reference missing")
	end,
	["v2 rejects unknown skill node prerequisites"] = function()
		rejected(function(raw)
			raw.skillNodes[1].prerequisites = { "missing" }
		end, "unknown skillNodes reference missing")
	end,
	["v2 rejects reconstructed values claimed confirmed without a source"] = function()
		rejected(function(raw)
			raw.skillNodes[1].provenance = { classification = "CONFIRMED" }
		end, "CONFIRMED requires sourceId")
	end,
	["v2 refuses malformed objects enums nonfinite values and prerequisite cycles"] = function()
		rejected(function(raw)
			raw.skillNodes[1].extra = true
		end, "unknown field extra")
		rejected(function(raw)
			raw.operations[1].kind = "free-money"
		end, "expected practice")
		rejected(function(raw)
			raw.operations[1].seconds = math.huge
		end, "expected duration")
		rejected(function(raw)
			raw.skillNodes[1].prerequisites = { "tailoring_1" }
		end, "prerequisite cycle")
	end,
}
