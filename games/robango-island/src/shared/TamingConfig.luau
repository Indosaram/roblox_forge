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
		-- Capture needs a full gauge. At 1 unit/s, and again at 1 unit/4 s, a full gauge dropped to
		-- 99 before a real player's capture press reached the server (Studio play, 2026-10-18);
		-- one unit per 10 s leaves a full gauge ten seconds to capture.
		decayStepMillis = 10000,
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
-- V2 cargo is slot-based; do not turn slots into a player weight bonus.
table.insert(policy.tameable, "compsognathus")
policy.mounts.species["compsognathus"] = { rideable = false, rideSpeedStuds = 0, carryMilli = 0 }
table.insert(policy.tameable, "oviraptor")
policy.mounts.species["oviraptor"] = { rideable = false, rideSpeedStuds = 0, carryMilli = 0 }
table.insert(policy.tameable, "protoceratops")
policy.mounts.species["protoceratops"] = { rideable = true, rideSpeedStuds = 13, carryMilli = 0 }
table.insert(policy.tameable, "gallimimus")
policy.mounts.species["gallimimus"] = { rideable = true, rideSpeedStuds = 30, carryMilli = 0 }
table.insert(policy.tameable, "parasaurolophus")
policy.mounts.species["parasaurolophus"] = { rideable = true, rideSpeedStuds = 20, carryMilli = 0 }
table.insert(policy.tameable, "stegosaurus")
policy.mounts.species["stegosaurus"] = { rideable = true, rideSpeedStuds = 12, carryMilli = 0 }
table.insert(policy.tameable, "ankylosaurus")
policy.mounts.species["ankylosaurus"] = { rideable = true, rideSpeedStuds = 10, carryMilli = 0 }
table.insert(policy.tameable, "triceratops")
policy.mounts.species["triceratops"] = { rideable = true, rideSpeedStuds = 18, carryMilli = 0 }
table.insert(policy.tameable, "utahraptor")
policy.mounts.species["utahraptor"] = { rideable = true, rideSpeedStuds = 25, carryMilli = 0 }
table.insert(policy.tameable, "velociraptor")
policy.mounts.species["velociraptor"] = { rideable = true, rideSpeedStuds = 24, carryMilli = 0 }
table.insert(policy.tameable, "dilophosaurus")
policy.mounts.species["dilophosaurus"] = { rideable = true, rideSpeedStuds = 20, carryMilli = 0 }
table.insert(policy.tameable, "allosaurus")
policy.mounts.species["allosaurus"] = { rideable = true, rideSpeedStuds = 23, carryMilli = 0 }
table.insert(policy.tameable, "smilodon")
policy.mounts.species["smilodon"] = { rideable = true, rideSpeedStuds = 26, carryMilli = 0 }
table.insert(policy.tameable, "tropicalSmilodon")
policy.mounts.species["tropicalSmilodon"] = { rideable = true, rideSpeedStuds = 27, carryMilli = 0 }
table.insert(policy.tameable, "direWolf")
policy.mounts.species["direWolf"] = { rideable = true, rideSpeedStuds = 25, carryMilli = 0 }
table.insert(policy.tameable, "mammoth")
policy.mounts.species["mammoth"] = { rideable = true, rideSpeedStuds = 16, carryMilli = 0 }
table.insert(policy.tameable, "boar")
policy.mounts.species["boar"] = { rideable = true, rideSpeedStuds = 17, carryMilli = 0 }
table.insert(policy.tameable, "deer")
policy.mounts.species["deer"] = { rideable = true, rideSpeedStuds = 25, carryMilli = 0 }
table.insert(policy.tameable, "elephant")
policy.mounts.species["elephant"] = { rideable = true, rideSpeedStuds = 16, carryMilli = 0 }
table.insert(policy.tameable, "turtle")
policy.mounts.species["turtle"] = { rideable = false, rideSpeedStuds = 0, carryMilli = 0 }
table.insert(policy.tameable, "dodo")
policy.mounts.species["dodo"] = { rideable = false, rideSpeedStuds = 0, carryMilli = 0 }
return policy
