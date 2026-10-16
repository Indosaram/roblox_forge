--!strict
local Archetype = require("./Archetype")
local Content = require("./Content")

local function document(wildlife: { any }): any
	return {
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		items = { { id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 } },
		wildlife = wildlife,
	}
end

local function hasError(errors: { string }, fragment: string): boolean
	for _, err in errors do
		if string.find(err, fragment, 1, true) then
			return true
		end
	end
	return false
end

return {
	["six original archetypes map onto the two engines with default flags"] = function()
		assert(#Archetype.IDS == 6, "exactly six P0 archetypes")
		local expected = {
			leaper = "hunter",
			charger = "hunter",
			["tail-sweeper"] = "hunter",
			roarer = "hunter",
			scavenger = "hunter",
			["herd-grazer"] = "grazer",
		}
		for id, engine in expected :: { [string]: string } do
			local definition = assert(Archetype.get(id), id)
			assert(definition.engine == engine and Archetype.isArchetype(id), id)
			assert(Archetype.allowsFlag(engine, definition.flag), id .. " default flag fits its engine")
		end
		local grazer = assert(Archetype.get("herd-grazer"), "herd-grazer")
		assert(grazer.flag == "passive", "grazers are passive")
		assert(not Archetype.isArchetype("grazer") and Archetype.engine("hunter") == "hunter", "legacy names resolve")
		assert(Archetype.get("raptor") == nil, "unknown names are not archetypes")
		assert(not Archetype.allowsFlag("grazer", "aggressive"), "a grazer cannot attack")
		assert(not Archetype.allowsFlag("hunter", "passive"), "a hunter always fights back")
	end,
	["danger band scales detection upward and band one is the authored radius"] = function()
		assert(Archetype.detection(12, 1) == 12, "band 1 unchanged")
		local previous = 0
		for band = 1, 4 do
			local radius = Archetype.detection(12, band)
			assert(radius > previous, "riskier bands detect further")
			previous = radius
		end
		assert(Archetype.detection(12, 4) == 24, "band 4 doubles")
		assert(not pcall(Archetype.detection, 12, 0), "band below range")
		assert(not pcall(Archetype.detection, 12, 5), "band above range")
		assert(not pcall(Archetype.detection, 12, 1.5), "fractional band")
	end,
	["content accepts archetype behaviours with flags and bands and keeps legacy output"] = function()
		local canonical, errors = Content.canonicalize(document({
			{ id = "deer", behavior = "grazer" },
			{ id = "wolf", behavior = "hunter" },
			{ id = "crest", behavior = "leaper", dangerBand = 3 },
			{ id = "drover", behavior = "herd-grazer" },
			{ id = "sweeper", behavior = "tail-sweeper", flag = "aggressive" },
		}))
		local doc = assert(canonical, table.concat(errors, "; "))
		local byId: { [string]: any } = {}
		for _, entry in doc.wildlife do
			byId[entry.id] = entry
		end
		assert(byId.deer.flag == nil and byId.deer.dangerBand == nil, "legacy grazer gains no fields")
		assert(byId.wolf.flag == nil and byId.wolf.leashStuds == 40, "legacy hunter unchanged")
		assert(byId.crest.flag == "aggressive" and byId.crest.dangerBand == 3, "archetype resolves flag and band")
		assert(byId.crest.warnStuds == 12 and byId.crest.leashStuds == 40, "archetype inherits hunter defaults")
		assert(byId.drover.flag == "passive" and byId.drover.senseStuds == 12, "grazer archetype defaults")
		assert(byId.drover.warnStuds == nil, "grazer archetype carries no hunter fields")
		assert(byId.sweeper.flag == "aggressive", "authored flag wins")
	end,
	["content refuses unknown behaviours foreign fields and bad flags or bands"] = function()
		assert(
			hasError(
				Content.validate(document({ { id = "x", behavior = "raptor" } })),
				"behavior: expected grazer|hunter or an archetype id"
			),
			"unknown behaviour"
		)
		assert(
			hasError(
				Content.validate(document({ { id = "x", behavior = "herd-grazer", warnStuds = 12 } })),
				"warnStuds: not valid for herd-grazer"
			),
			"hunter field on a grazer archetype"
		)
		assert(
			hasError(
				Content.validate(document({ { id = "x", behavior = "herd-grazer", flag = "aggressive" } })),
				"flag: aggressive not valid for grazer engine"
			),
			"aggressive grazer"
		)
		assert(
			hasError(
				Content.validate(document({ { id = "x", behavior = "charger", flag = "passive" } })),
				"flag: passive not valid for hunter engine"
			),
			"passive hunter"
		)
		assert(
			hasError(
				Content.validate(document({ { id = "x", behavior = "charger", dangerBand = 5 } })),
				"dangerBand: expected integer 1..4"
			),
			"band out of range"
		)
	end,
}
