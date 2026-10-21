--!strict
-- Fixture injection until the integrator authors these missing policy fields in
-- content.yml and regenerates SurvivalContent. Not a production fallback.
return {
	tree = { maxLevel = 60, spPerLevel = 3, maxMastery = 60, actionXP = 10, xpBase = 50, xpStep = 10 },
	sharpnessPerPoint = 0.02,
	insulationCold = 0.1,
	minimumWear = 0.5,
	flexibilityWear = 0.03,
	precision = 1000,
	clothing = { ["temperate-top"] = { cold = 1, heat = 1 }, ["cold-top"] = { cold = 2, heat = 0 } },
	maxVital = 100,
	energyBase = 10,
	energyNutrition = 2,
	healthBase = 5,
	feed = { ["herbivore-feed"] = true, ["carnivore-feed"] = true, ["recovery-feed"] = true },
	foodFamilies = {
		["baked-apple"] = "resistance",
		["rex-meat-stew"] = "resistance",
		["corn-porridge"] = "stamina",
		["onion-soup"] = "recovery",
	},
	buffStrength = { resistance = 2, stamina = 0.05, recovery = 1 },
	buffSeconds = 300,
	exposureHealth = 0.2,
	exposureFatigue = 0.4,
}
