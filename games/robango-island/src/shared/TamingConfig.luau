--!strict
-- Robango Island taming and mount policy: content/config only. All behaviour lives in
-- genres/survival-coop/module/TamingExtension (+ core/domain/taming, Mounts).
-- Pen times and feed values are provisional catalog numbers, not a balance verdict.
local policy = {
	version = 1,
	seed = 4242,
	carriedContainer = "bag",
	captureTool = "capture-bola",
	tameable = { "ridge-strider", "fen-trotter", "bluff-bounder" },
	taming = {
		gaugeMax = 100,
		fillPerHit = 25,
		decayStepMillis = 1000,
		successPermille = 700,
		toolWearMilli = 25000,
		penMillis = 120000,
		feedShortenMillis = { berry = 45000, ["berry-meal"] = 90000 },
	},
	mounts = {
		pvpSpeedCapStuds = 24,
		species = {
			["ridge-strider"] = { rideable = true, rideSpeedStuds = 28, carryMilli = 30000 },
			["fen-trotter"] = { rideable = true, rideSpeedStuds = 24, carryMilli = 20000 },
			["bluff-bounder"] = { rideable = true, rideSpeedStuds = 32, carryMilli = 10000 },
		},
		-- Cosmetic only: a skin names a species and a paid marker, nothing else.
		skins = { ["ridge-strider-gold"] = { species = "ridge-strider", paid = true } },
	},
	maxWild = 8,
	maxAnimalsPerOwner = 6,
	maxReceipts = 128,
	reachStuds = 10,
	hitCooldownMillis = 500,
	wildRespawnMillis = 300000,
}
return policy
