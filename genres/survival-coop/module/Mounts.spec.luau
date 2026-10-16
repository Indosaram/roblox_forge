--!strict
local Mounts = require("./Mounts")
local Content = require("../../../core/domain/survival/Content")

local function content(): Content.Document
	local raw: any = {
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		items = { { id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 } },
		wildlife = {
			{ id = "drover", behavior = "herd-grazer" },
			{ id = "stag", behavior = "herd-grazer", dangerBand = 2 },
			{ id = "crest", behavior = "charger", dangerBand = 3 },
			{ id = "deer", behavior = "grazer" },
		},
	}
	local doc, errors = Content.canonicalize(raw)
	assert(doc, table.concat(errors or {}, "; "))
	return doc
end

local function rules(): Mounts.Rules
	return {
		pvpSpeedCapStuds = 24,
		species = {
			drover = { rideable = true, rideSpeedStuds = 20, carryMilli = 8000 },
			stag = { rideable = true, rideSpeedStuds = 40, carryMilli = 5000 },
			crest = { rideable = false, rideSpeedStuds = 0, carryMilli = 0 },
		},
		skins = {
			["drover-gold"] = { species = "drover", paid = true },
			["drover-moss"] = { species = "drover", paid = false },
			["stag-neon"] = { species = "stag", paid = true },
		},
	}
end

local function rideOf(catalog: Mounts.Catalog, species: string, skin: string?, zone: Mounts.Zone): Mounts.Ride
	local resolved = Mounts.resolve(catalog, species, skin, zone)
	assert(resolved ~= nil, "ride resolves for " .. species)
	return resolved
end

local ZONES = { { pvp = false }, { pvp = true } }

local function rejects(mutate: (Mounts.Rules) -> ())
	local r = rules()
	mutate(r)
	assert(not pcall(Mounts.catalog, content(), r), "expected rejection")
end

return {
	["rideable is a species flag and unlisted or unrideable species refuse"] = function()
		local catalog = Mounts.catalog(content(), rules())
		assert(Mounts.isRideable(catalog, "drover") and Mounts.isRideable(catalog, "stag"), "flagged species ride")
		assert(not Mounts.isRideable(catalog, "crest"), "explicitly unrideable")
		assert(not Mounts.isRideable(catalog, "deer"), "unlisted species is not rideable")
		local crestRide, crestReason = Mounts.resolve(catalog, "crest", nil, { pvp = false })
		assert(crestRide == nil and crestReason == "NOT_RIDEABLE", "unrideable refused")
		local deerRide, deerReason = Mounts.resolve(catalog, "deer", nil, { pvp = false })
		assert(deerRide == nil and deerReason == "UNKNOWN_SPECIES", "unlisted refused")
	end,
	["ride speed and carry come from the species values"] = function()
		local catalog = Mounts.catalog(content(), rules())
		local drover = rideOf(catalog, "drover", nil, { pvp = false })
		assert(drover.speedStuds == 20 and drover.carryMilli == 8000 and not drover.clamped, "drover values")
		local stag = rideOf(catalog, "stag", nil, { pvp = false })
		assert(stag.speedStuds == 40 and stag.carryMilli == 5000, "stag values differ per species")
		assert(
			Mounts.carryCapacity(30000, drover) == 38000 and Mounts.carryCapacity(30000, nil) == 30000,
			"carry adds species value"
		)
	end,
	["PvP opt-in zones clamp every ride to the shared cap and safe zones do not"] = function()
		local catalog = Mounts.catalog(content(), rules())
		local fast = rideOf(catalog, "stag", nil, { pvp = true })
		assert(fast.speedStuds == 24 and fast.clamped, "fast species clamped")
		local safe = rideOf(catalog, "stag", nil, { pvp = false })
		assert(safe.speedStuds == 40 and not safe.clamped, "no clamp outside PvP")
		local slow = rideOf(catalog, "drover", nil, { pvp = true })
		assert(slow.speedStuds == 20 and not slow.clamped, "slower species keeps its own value")
		assert(fast.carryMilli == 5000, "the clamp never touches carry")
	end,
	["paid skins record identical speed and carry to the free same species in every zone"] = function()
		local catalog = Mounts.catalog(content(), rules())
		for _, zone in ZONES do
			local skinsOf: { [string]: { string } } =
				{ drover = { "drover-gold", "drover-moss" }, stag = { "stag-neon" } }
			for species, skins in skinsOf do
				local base = rideOf(catalog, species, nil, zone)
				for _, skin in skins do
					local ride = rideOf(catalog, species, skin, zone)
					assert(ride.speedStuds == base.speedStuds, `{skin} speed equals free {species} (pvp={zone.pvp})`)
					assert(ride.carryMilli == base.carryMilli, `{skin} carry equals free {species} (pvp={zone.pvp})`)
					assert(ride.clamped == base.clamped, `{skin} clamp equals free {species}`)
				end
			end
		end
		local paid = rideOf(catalog, "drover", "drover-gold", { pvp = false })
		assert(paid.paid and paid.skin == "drover-gold", "the skin is recorded as appearance only")
	end,
	["paid skins never increase carry capacity (SYS-051)"] = function()
		local catalog = Mounts.catalog(content(), rules())
		for _, zone in ZONES do
			for _, base in { 0, 12000, 30000 } do
				local free = Mounts.carryCapacity(base, rideOf(catalog, "drover", nil, zone))
				local paid = Mounts.carryCapacity(base, rideOf(catalog, "drover", "drover-gold", zone))
				assert(paid == free and paid == base + 8000, "paid carry equals free carry")
			end
		end
		rejects(function(r)
			(r.skins :: any)["drover-big"] = { species = "drover", paid = true, carryMilli = 99999 }
		end)
		rejects(function(r)
			(r.skins :: any)["drover-fast"] = { species = "drover", paid = true, rideSpeedStuds = 99 }
		end)
	end,
	["skins must name the matching rideable species"] = function()
		local catalog = Mounts.catalog(content(), rules())
		local wrongRide, wrongReason = Mounts.resolve(catalog, "drover", "stag-neon", { pvp = false })
		assert(wrongRide == nil and wrongReason == "SKIN_SPECIES_MISMATCH", "skin of another species refused")
		local ghostRide, ghostReason = Mounts.resolve(catalog, "drover", "ghost", { pvp = false })
		assert(ghostRide == nil and ghostReason == "UNKNOWN_SKIN", "unknown skin refused")
		rejects(function(r)
			r.skins = { x = { species = "crest", paid = true } }
		end)
		rejects(function(r)
			r.skins = { x = { species = "deer", paid = true } }
		end)
	end,
	["rules are validated against canonical wildlife content and frozen"] = function()
		local catalog = Mounts.catalog(content(), rules())
		assert(
			table.isfrozen(catalog) and table.isfrozen(catalog.species) and table.isfrozen(catalog.species.drover),
			"frozen"
		)
		assert(catalog.species.drover.flag == "passive", "species carries its archetype flag")
		rejects(function(r)
			r.species.unicorn = { rideable = true, rideSpeedStuds = 10, carryMilli = 1 }
		end)
		rejects(function(r)
			r.species.deer = { rideable = true, rideSpeedStuds = 10, carryMilli = 1 }
		end)
		rejects(function(r)
			r.pvpSpeedCapStuds = 0
		end)
		rejects(function(r)
			r.species.drover.rideSpeedStuds = 0
		end)
		rejects(function(r)
			r.species.crest = { rideable = false, rideSpeedStuds = 5, carryMilli = 0 }
		end)
		rejects(function(r)
			(r.species.drover :: any).entitlement = "vip"
		end)
		rejects(function(r)
			(r :: any).robuxBonus = 10
		end)
		assert(not pcall(Mounts.resolve, catalog, "drover", nil, {} :: any), "zone must declare pvp")
	end,
}
