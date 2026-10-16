--!strict
local Content = require("./Content")
local Vitals = require("./Vitals")
local contract = require("../../../cli/forge/lib/genrecontract")
local luau = require("@lune/luau")

local function valid(): any
	return {
		survival_content = 1,
		rules = {
			inheritance = "avg-quality-v1",
			durability = "quality-scaled-v1",
			ingredientSelection = "item-id-ascending",
			demolitionRefund = "full-storage-v1",
		},
		limits = {
			slots = 20,
			hardWeightMilli = 90000,
			softWeightMilli = 60000,
			qualityMilliMin = 1,
			qualityMilliMax = 5000,
			tribeMaxMembers = 4,
		},
		tags = { "tool", "fuel" },
		items = {
			{ id = "wood", name = "Wood", stackMax = 50, weightMilli = 1200, tags = { "fuel" } },
			{ id = "fiber", name = "Fiber", stackMax = 100, weightMilli = 200, tags = {} },
			{ id = "cord", name = "Cord", stackMax = 50, weightMilli = 300, tags = {} },
			{
				id = "axe",
				name = "Stone Axe",
				stackMax = 1,
				weightMilli = 2500,
				maxDurabilityMilli = 100000,
				tags = { "tool" },
			},
		},
		structures = {
			{
				id = "workbench",
				footprintX = 4,
				footprintZ = 2,
				station = true,
				cost = { { item = "wood", quantity = 10 } },
			},
		},
		recipes = {
			{
				id = "cord-from-fiber",
				craftMillis = 3000,
				inputs = { { item = "fiber", quantity = 3 } },
				outputs = { { item = "cord", quantity = 1 } },
			},
			{
				id = "stone-axe",
				craftMillis = 8000,
				station = "workbench",
				requiredToolTag = "tool",
				inputs = { { item = "wood", quantity = 2 }, { item = "cord", quantity = 1 } },
				outputs = { { item = "axe", quantity = 1 } },
			},
		},
		nodes = {
			{ id = "oak", harvest = { { item = "wood", quantity = 3 } }, respawnMillis = 60000 },
		},
		wildlife = {
			{ id = "deer", behavior = "grazer" },
			{ id = "wolf", behavior = "hunter", attackStuds = 4 },
		},
	}
end

local function mutate(change: (any) -> ()): { string }
	local document = valid()
	change(document)
	return Content.validate(document)
end

local function hasError(errors: { string }, fragment: string): boolean
	for _, err in errors do
		if string.find(err, fragment, 1, true) ~= nil then
			return true
		end
	end
	return false
end

return {
	["optional food and vitals survive canonical serialization without aliasing"] = function()
		local raw = valid()
		raw.items[1].foodEffects = { hungerMilli = 100000, healthMilli = 1234, fatigueMilli = 0 }
		raw.vitals = { fatigueMilliPerAction = 0 }
		local document = Content.canonicalize(raw)
		assert(document ~= nil and document.vitals ~= nil, "optional config canonicalizes")
		local encoded = contract.serialize(document)
		local decoded = luau.load("return " .. encoded)()
		assert(contract.serialize(decoded) == encoded, "canonical data roundtrips byte-identically")
		assert(decoded.items[4].foodEffects.hungerMilli == 100000, "hunger restoration retained")
		assert(decoded.items[4].foodEffects.healthMilli == 1234, "health restoration retained")
		assert(decoded.items[4].foodEffects.fatigueMilli == 0, "zero fatigue reduction retained")
		assert(decoded.items[1].foodEffects == nil, "nonfood has no implicit effect")
		local defaults = Vitals.new(0).config
		assert(decoded.vitals.hungerMillisPerUnit == defaults.hungerMillisPerUnit, "hunger default")
		assert(decoded.vitals.starvationMillisPerUnit == defaults.starvationMillisPerUnit, "starvation default")
		assert(decoded.vitals.restMilliPerSecond == defaults.restMilliPerSecond, "rest default")
		assert(decoded.vitals.fatigueMilliPerAction == 0, "explicit zero overrides default")
		assert(Vitals.new(0, decoded.vitals).config.fatigueMilliPerAction == 0, "exact Vitals.Config contract")
		raw.items[1].foodEffects.healthMilli = 0
		raw.vitals.fatigueMilliPerAction = 1
		assert(contract.serialize(document) == encoded, "canonical data owns its effects and config")
		decoded.survival_content = decoded.version
		decoded.version = nil
		local again = Content.canonicalize(decoded)
		assert(again ~= nil and contract.serialize(again) == encoded, "serialized data revalidates")
	end,

	["legacy catalogs retain absent optional fields and serialize unchanged"] = function()
		local document = Content.canonicalize(valid())
		assert(document ~= nil and document.vitals == nil, "legacy config remains absent")
		for _, item in document.items do
			assert(item.foodEffects == nil, "legacy items are not food")
		end
		local encoded = contract.serialize(document)
		assert(contract.serialize(luau.load("return " .. encoded)()) == encoded, "legacy serialization roundtrip")
		local raw = valid()
		raw.vitals = {}
		local configured = Content.canonicalize(raw)
		assert(configured ~= nil, "empty optional config resolves defaults")
		assert(contract.serialize(configured.vitals) == contract.serialize(Vitals.new(0).config), "exact defaults")
	end,

	["food effects reject missing unknown nonintegral and out of range data"] = function()
		for _, field in { "hungerMilli", "healthMilli", "fatigueMilli" } do
			local invalid: { any } = { -1, 100001, 0.5, math.huge, -math.huge, 0 / 0, "1", false }
			for _, bad in invalid do
				local errors = mutate(function(raw)
					raw.items[1].foodEffects = { hungerMilli = 0, healthMilli = 0, fatigueMilli = 0 }
					raw.items[1].foodEffects[field] = bad
				end)
				assert(hasError(errors, "foodEffects." .. field), "invalid food field rejected")
			end
			assert(
				hasError(
					mutate(function(raw)
						raw.items[1].foodEffects = { hungerMilli = 0, healthMilli = 0, fatigueMilli = 0 }
						raw.items[1].foodEffects[field] = nil
					end),
					"foodEffects." .. field
				),
				"food mapping must be complete"
			)
		end
		assert(
			hasError(
				mutate(function(raw)
					raw.items[1].foodEffects = { hungerMilli = 0, healthMilli = 0, fatigueMilli = 0, poisonMilli = 1 }
				end),
				"unknown field poisonMilli"
			),
			"unplanned effects rejected"
		)
		assert(
			hasError(
				mutate(function(raw)
					raw.items[1].foodEffects = true
				end),
				"foodEffects: expected mapping"
			),
			"nonmapping rejected"
		)
	end,

	["vitals config enforces exact runtime bounds and rejects unknown revisions"] = function()
		for _, field in
			{ "hungerMillisPerUnit", "starvationMillisPerUnit", "fatigueMilliPerAction", "restMilliPerSecond" }
		do
			local period = field == "hungerMillisPerUnit" or field == "starvationMillisPerUnit"
			local low, high = if period then 1 else 0, if period then 86400000 else 100000
			for _, bound in { low, high } do
				local raw = valid()
				raw.vitals = { [field] = bound }
				local document = Content.canonicalize(raw)
				assert(document ~= nil and document.vitals ~= nil, "runtime boundary accepted")
				assert((Vitals.new(0, document.vitals).config :: any)[field] == bound, "runtime accepts boundary")
			end
			local invalid: { any } = { low - 1, high + 1, 0.5, math.huge, -math.huge, 0 / 0, "1", false }
			for _, bad in invalid do
				assert(
					hasError(
						mutate(function(raw)
							raw.vitals = { [field] = bad }
						end),
						"vitals." .. field
					),
					"invalid config field rejected"
				)
			end
		end
		assert(
			hasError(
				mutate(function(raw)
					raw.vitals = { version = 2 }
				end),
				"vitals: unknown field version"
			),
			"unknown config revision rejected"
		)
		assert(
			hasError(
				mutate(function(raw)
					raw.vitals = false
				end),
				"vitals: expected mapping"
			),
			"nonmapping rejected"
		)
		local raw = valid()
		raw.survival_content = 2
		raw.vitals = {}
		raw.items[1].foodEffects = { hungerMilli = 1, healthMilli = 0, fatigueMilli = 0 }
		assert(Content.canonicalize(raw) == nil, "optional fields never downgrade newer content")
	end,

	["a complete catalog validates and canonicalizes deterministically"] = function()
		assert(#Content.validate(valid()) == 0, table.concat(Content.validate(valid()), "; "))
		local first, firstErrors = Content.canonicalize(valid())
		local second = Content.canonicalize(valid())
		assert(first ~= nil and second ~= nil and #firstErrors == 0, "valid catalog canonicalizes")
		local document = first :: any
		assert(document.version == 1, "canonical document pins the envelope version")
		local ids = {}
		for _, item in document.items do
			table.insert(ids, item.id)
		end
		assert(table.concat(ids, ",") == "axe,cord,fiber,wood", "items sort by id: " .. table.concat(ids, ","))
		local inputs = (second :: any).recipes[2].inputs
		assert(
			(second :: any).recipes[2].id == "stone-axe" and inputs[1].item == "cord" and inputs[2].item == "wood",
			"ingredients are selected in ascending item id order"
		)
	end,

	["skills section validates six disciplines and canonicalizes deterministically"] = function()
		local function withSkills(): any
			local document = valid()
			local disciplines = {}
			for _, id in { "woodcraft", "gathering", "tailoring", "hearth", "building", "butchery" } do
				table.insert(disciplines, { id = id, thresholds = { 100, 250, 450 } })
			end
			disciplines[1].tools = { { item = "axe", tier = 2 } }
			document.skills = { baseStep = 1, disciplines = disciplines }
			document.recipes[2].skill = { id = "woodcraft", xp = 40 }
			document.nodes[1].skill = { id = "gathering", xp = 5 }
			return document
		end
		local document, errors = Content.canonicalize(withSkills())
		assert(document ~= nil, table.concat(errors, "; "))
		local skills = (document :: any).skills
		assert(skills.baseStep == 1 and #skills.disciplines == 6, "six disciplines ship")
		assert(skills.disciplines[1].id == "building", "disciplines sorted by id")
		local woodcraft = skills.disciplines[6]
		assert(woodcraft.id == "woodcraft" and woodcraft.tools[1].tier == 2, "tool tiers ship")
		assert((document :: any).nodes[1].skill.xp == 5, "node grant ships")
		local again = assert(Content.canonicalize(withSkills()))
		assert(contract.serialize(again) == contract.serialize(document), "deterministic canonical skills")
		local legacy = assert(Content.canonicalize(valid()))
		assert(legacy.skills == nil and legacy.recipes[1].skill == nil, "absent skills stay absent")

		local function broken(change: (any) -> ()): { string }
			local raw = withSkills()
			change(raw)
			return Content.validate(raw)
		end
		assert(
			hasError(
				broken(function(d)
					table.remove(d.skills.disciplines)
				end),
				"expected exactly 6 disciplines"
			),
			"five disciplines refused"
		)
		assert(
			hasError(
				broken(function(d)
					d.skills.disciplines[2].thresholds = { 100, 100 }
				end),
				"strictly ascending"
			),
			"non-ascending thresholds refused"
		)
		assert(
			hasError(
				broken(function(d)
					d.skills.disciplines[2].id = "woodcraft"
				end),
				"duplicate discipline"
			),
			"duplicate discipline refused"
		)
		assert(
			hasError(
				broken(function(d)
					d.skills.respec = "reroll"
				end),
				"skills: unknown field respec"
			),
			"unknown skills field refused"
		)
		assert(
			hasError(
				broken(function(d)
					d.skills.disciplines[1].bonus = 1
				end),
				"unknown field bonus"
			),
			"unknown discipline field refused"
		)
		assert(
			hasError(
				broken(function(d)
					d.skills.disciplines[1].tools[1].item = "ghost"
				end),
				"unknown item ghost"
			),
			"unknown tool item refused"
		)
		assert(
			hasError(
				broken(function(d)
					d.recipes[2].skill.id = "alchemy"
				end),
				"unknown discipline alchemy"
			),
			"grant must name a declared discipline"
		)
		assert(
			hasError(
				broken(function(d)
					d.nodes[1].skill.xp = 0
				end),
				"skill.xp: expected integer"
			),
			"zero xp grant refused"
		)
		assert(
			hasError(
				broken(function(d)
					d.recipes[2].skill.bonus = 2
				end),
				"skill: unknown field bonus"
			),
			"unknown grant field refused"
		)
		assert(
			hasError(
				mutate(function(d)
					d.nodes[1].skill = { id = "gathering", xp = 5 }
				end),
				"requires a skills section"
			),
			"grant without skills section refused"
		)
	end,

	["a newer envelope version is refused rather than downgraded"] = function()
		local errors = mutate(function(document)
			document.survival_content = 2
		end)
		assert(hasError(errors, "survival_content: unsupported version 2"), table.concat(errors, "; "))
		assert(hasError(Content.validate({}), "survival_content"), "a missing version is refused too")
	end,

	["pinned rule identities cannot drift"] = function()
		local errors = mutate(function(document)
			document.rules.inheritance = "avg-quality-v2"
		end)
		assert(hasError(errors, "rules.inheritance: expected pinned"), table.concat(errors, "; "))
		assert(
			hasError(
				mutate(function(document)
					document.rules.inheritance = nil
				end),
				"rules.inheritance"
			),
			"an absent rule is not an implicit default"
		)
		assert(Content.RULES.ingredientSelection == "item-id-ascending", "deterministic selection rule is pinned")
	end,

	["catalog references must resolve to declared entries"] = function()
		assert(
			hasError(
				mutate(function(document)
					document.recipes[1].inputs[1].item = "ghost"
				end),
				"unknown item ghost"
			),
			"unknown recipe input"
		)
		assert(
			hasError(
				mutate(function(document)
					document.recipes[2].station = "forge"
				end),
				"unknown station forge"
			),
			"unknown station"
		)
		assert(
			hasError(
				mutate(function(document)
					document.recipes[2].requiredToolTag = "magic"
				end),
				"undeclared tag magic"
			),
			"undeclared tool tag"
		)
		assert(
			hasError(
				mutate(function(document)
					document.items[1].tags = { "shiny" }
				end),
				"undeclared tag shiny"
			),
			"undeclared item tag"
		)
		assert(
			hasError(
				mutate(function(document)
					document.nodes[1].harvest[1].item = "ghost"
				end),
				"unknown item ghost"
			),
			"unknown node harvest"
		)
		assert(
			hasError(
				mutate(function(document)
					document.structures[1].cost[1].item = "ghost"
				end),
				"unknown item ghost"
			),
			"unknown structure cost"
		)
	end,

	["a recipe cycle is malformed content, not a runtime failure"] = function()
		local errors = mutate(function(document)
			-- cord-from-fiber consumes fiber to produce cord; this consumes cord to
			-- produce fiber, so neither is reachable from gathered inputs.
			table.insert(document.recipes, {
				id = "fiber-from-cord",
				craftMillis = 1000,
				inputs = { { item = "cord", quantity = 1 } },
				outputs = { { item = "fiber", quantity = 2 } },
			})
		end)
		assert(hasError(errors, "recipes: cyclic dependency"), table.concat(errors, "; "))
		local selfCycle = mutate(function(document)
			table.insert(document.recipes, {
				id = "wood-refine",
				craftMillis = 1000,
				inputs = { { item = "wood", quantity = 2 } },
				outputs = { { item = "wood", quantity = 1 } },
			})
		end)
		assert(hasError(selfCycle, "cyclic dependency through wood-refine"), table.concat(selfCycle, "; "))
	end,

	["quantities and bounds stay finite integral fixed point"] = function()
		for _, bad in { 0, -1, 1.5, 0 / 0, math.huge } do
			assert(#mutate(function(document)
				document.recipes[1].inputs[1].quantity = bad
			end) > 0, "quantity must be a bounded positive integer: " .. tostring(bad))
			assert(#mutate(function(document)
				document.items[1].stackMax = bad
			end) > 0, "stackMax must be a bounded positive integer: " .. tostring(bad))
		end
		assert(#mutate(function(document)
			document.items[1].weightMilli = 1200.5
		end) > 0, "weight is integral milli-units")
		assert(#mutate(function(document)
			document.items[4].maxDurabilityMilli = 0
		end) > 0, "durability is a positive integral milli-unit")
		assert(#mutate(function(document)
			document.items[1].weightMilli = Content.CAPS.weightMilli + 1
		end) > 0, "weight is capped")
		assert(#mutate(function(document)
			document.recipes[1].craftMillis = Content.CAPS.millis + 1
		end) > 0, "craft duration is capped")
	end,

	["inventory and quality limits respect the approved caps"] = function()
		assert(Content.DEFAULT_LIMITS.slots == 20, "20 inbound slots")
		assert(Content.DEFAULT_LIMITS.hardWeightMilli == 90000, "90 hard weight")
		assert(Content.DEFAULT_LIMITS.softWeightMilli == 60000, "60 soft penalty threshold")
		assert(Content.DEFAULT_LIMITS.qualityMilliMax == 5000, "quality clamps at 5000 milliunits")
		assert(Content.DEFAULT_LIMITS.tribeMaxMembers == 4, "tribe max 4")
		-- The approved inventory contract is a CEILING, not merely a default:
		-- a catalog may tighten a limit but must never widen one.
		assert(
			hasError(
				mutate(function(document)
					document.limits.slots = 21
				end),
				"limits.slots"
			),
			"a catalog cannot raise the 20 slot policy"
		)
		assert(
			hasError(
				mutate(function(document)
					document.limits.hardWeightMilli = 90001
				end),
				"limits.hardWeightMilli"
			),
			"a catalog cannot raise the 90 hard weight policy"
		)
		assert(#mutate(function(document)
			document.limits.slots = 10
			document.limits.hardWeightMilli = 45000
			document.limits.softWeightMilli = 30000
		end) == 0, "a pack may still tighten its own bag")
		assert(
			hasError(
				mutate(function(document)
					document.limits.softWeightMilli = 95000
				end),
				"limits.softWeightMilli"
			),
			"a soft threshold above the policy maximum is refused"
		)
		assert(
			hasError(
				mutate(function(document)
					document.limits.softWeightMilli = 90000
					document.limits.hardWeightMilli = 45000
				end),
				"softWeightMilli: must not exceed hardWeightMilli"
			),
			"within policy, the soft threshold still cannot exceed the hard refusal"
		)
		assert(
			hasError(
				mutate(function(document)
					document.limits.qualityMilliMax = 5001
				end),
				"limits.qualityMilliMax"
			),
			"quality clamp cannot exceed 5000"
		)
		assert(
			hasError(
				mutate(function(document)
					document.limits.tribeMaxMembers = 5
				end),
				"limits.tribeMaxMembers"
			),
			"tribe cap is 4"
		)
	end,

	["wildlife defaults resolve and contradictory ranges fail"] = function()
		local document = Content.canonicalize(valid())
		assert(document ~= nil, "valid wildlife canonicalizes")
		local deer, wolf = (document :: any).wildlife[1], (document :: any).wildlife[2]
		assert(deer.id == "deer" and deer.senseStuds == 12 and deer.fleeStuds == 24, "grazer defaults 12/24")
		assert(
			wolf.warnStuds == 12 and wolf.attackStuds == 4 and wolf.leashStuds == 40,
			"hunter defaults warn 12 attack 4 leash 40"
		)
		assert(wolf.telegraphMillis == 1000 and wolf.cooldownMillis == 2000, "1s telegraph, 2s cooldown")
		assert(deer.warnStuds == nil, "grazer carries no hunter fields")
		assert(
			hasError(
				mutate(function(doc)
					doc.wildlife[2].attackStuds = 20
				end),
				"expected attackStuds < warnStuds <= leashStuds"
			),
			"attack range beyond warn range is contradictory"
		)
		assert(
			hasError(
				mutate(function(doc)
					doc.wildlife[1].warnStuds = 12
				end),
				"not valid for grazer"
			),
			"hunter field on a grazer is refused"
		)
		assert(
			hasError(
				mutate(function(doc)
					doc.wildlife[1].senseStuds = 30
				end),
				"senseStuds: must be below fleeStuds"
			),
			"a grazer that senses beyond its flee range is contradictory"
		)
	end,

	["duplicate and unknown entries are reported with their field path"] = function()
		assert(
			hasError(
				mutate(function(document)
					document.items[2].id = "wood"
				end),
				"items[2].id: duplicate item wood"
			),
			"duplicate item id"
		)
		assert(
			hasError(
				mutate(function(document)
					document.recipes[2].id = "cord-from-fiber"
				end),
				"duplicate recipe cord-from-fiber"
			),
			"duplicate recipe id"
		)
		assert(
			hasError(
				mutate(function(document)
					document.items[1].colour = "brown"
				end),
				"items[1]: unknown field colour"
			),
			"unknown item field"
		)
		assert(
			hasError(
				mutate(function(document)
					document.extra = true
				end),
				"content: unknown field extra"
			),
			"unknown top-level field"
		)
		assert(
			hasError(
				mutate(function(document)
					document.recipes[1].inputs = { { item = "fiber", quantity = 1 }, { item = "fiber", quantity = 2 } }
				end),
				"duplicate item fiber"
			),
			"a recipe cannot list one item twice"
		)
	end,

	["canonicalize refuses to publish a malformed document"] = function()
		local document, errors = Content.canonicalize({ survival_content = 1 })
		assert(document == nil and #errors > 0, "malformed input yields no canonical document")
	end,
}
