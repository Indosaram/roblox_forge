--!strict
export type Spawn = { id: string, catalogId: string, position: { x: number, y: number, z: number } }
export type Species = { healthMilli: number, damageMilli: number, drops: { { item: string, quantity: number } } }
export type Weapon = {
	damageMilli: number,
	wearMilli: number,
	rangeStuds: number,
	facingDot: number,
	cooldownMillis: number,
}
local policy: {
	version: number,
	sourceKey: string,
	maximum: number,
	maxReceipts: number,
	catalog: { species: { [string]: Species }, weapons: { [string]: Weapon } },
	spawns: { Spawn },
} =
	{
		["catalog"] = {
			["species"] = {
				["leaper-fernhop"] = {
					["damageMilli"] = 7000,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 2 },
						[2] = { ["item"] = "hide", ["quantity"] = 1 },
					},
					["healthMilli"] = 45000,
				},
				["leaper-reedvault"] = {
					["damageMilli"] = 7000,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 2 },
						[2] = { ["item"] = "hide", ["quantity"] = 1 },
					},
					["healthMilli"] = 42000,
				},
				["charger-oakbrow"] = {
					["damageMilli"] = 12000,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 4 },
						[2] = { ["item"] = "hide", ["quantity"] = 2 },
					},
					["healthMilli"] = 90000,
				},
				["charger-mudbrow"] = {
					["damageMilli"] = 12000,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 4 },
						[2] = { ["item"] = "hide", ["quantity"] = 2 },
					},
					["healthMilli"] = 85000,
				},
				["tailswing-mossback"] = {
					["damageMilli"] = 9000,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 3 },
						[2] = { ["item"] = "hide", ["quantity"] = 2 },
					},
					["healthMilli"] = 110000,
				},
				["tailswing-shellclub"] = {
					["damageMilli"] = 9000,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 3 },
						[2] = { ["item"] = "shell-fragment", ["quantity"] = 2 },
					},
					["healthMilli"] = 100000,
				},
				["roarer-thicket"] = {
					["damageMilli"] = 14000,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 3 },
						[2] = { ["item"] = "hide", ["quantity"] = 1 },
					},
					["healthMilli"] = 75000,
				},
				["roarer-tidecall"] = {
					["damageMilli"] = 14000,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 3 },
						[2] = { ["item"] = "hide", ["quantity"] = 1 },
					},
					["healthMilli"] = 70000,
				},
				["scavenger-barkpicker"] = {
					["damageMilli"] = 0,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 1 },
						[2] = { ["item"] = "birch-bark", ["quantity"] = 1 },
					},
					["healthMilli"] = 30000,
				},
				["scavenger-flotsam"] = {
					["damageMilli"] = 0,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 1 },
						[2] = { ["item"] = "shell-fragment", ["quantity"] = 1 },
					},
					["healthMilli"] = 30000,
				},
				["herd-acorncrest"] = {
					["damageMilli"] = 0,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 2 },
						[2] = { ["item"] = "hide", ["quantity"] = 1 },
					},
					["healthMilli"] = 55000,
				},
				["herd-sedgewader"] = {
					["damageMilli"] = 0,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 2 },
						[2] = { ["item"] = "hide", ["quantity"] = 1 },
					},
					["healthMilli"] = 50000,
				},
				["ridge-strider"] = {
					["damageMilli"] = 0,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 2 },
						[2] = { ["item"] = "hide", ["quantity"] = 1 },
					},
					["healthMilli"] = 50000,
				},
				["fen-trotter"] = {
					["damageMilli"] = 0,
					["drops"] = { [1] = { ["item"] = "meat", ["quantity"] = 2 } },
					["healthMilli"] = 45000,
				},
				["bluff-bounder"] = {
					["damageMilli"] = 7000,
					["drops"] = {
						[1] = { ["item"] = "meat", ["quantity"] = 2 },
						[2] = { ["item"] = "hide", ["quantity"] = 1 },
					},
					["healthMilli"] = 42000,
				},
				["grazer"] = {
					["damageMilli"] = 0,
					["drops"] = { [1] = { ["item"] = "meat", ["quantity"] = 2 } },
					["healthMilli"] = 40000,
				},
				["hunter"] = {
					["damageMilli"] = 10000,
					["drops"] = { [1] = { ["item"] = "meat", ["quantity"] = 3 } },
					["healthMilli"] = 60000,
				},
			},
			["weapons"] = {
				["spear"] = {
					["cooldownMillis"] = 2000,
					["damageMilli"] = 20000,
					["facingDot"] = 0,
					["rangeStuds"] = 8,
					["wearMilli"] = 1000,
				},
			},
		},
		["maxReceipts"] = 512,
		["maximum"] = 24,
		["sourceKey"] = "wildlife-v2",
		["spawns"] = {
			[1] = {
				["catalogId"] = "grazer",
				["id"] = "grazer-01",
				["position"] = { ["x"] = -20, ["y"] = 4, ["z"] = 24 },
			},
			[2] = {
				["catalogId"] = "hunter",
				["id"] = "hunter-01",
				["position"] = { ["x"] = 22, ["y"] = 4, ["z"] = 24 },
			},
			[3] = {
				["catalogId"] = "ridge-strider",
				["id"] = "ridge-strider-01",
				["position"] = { ["x"] = -66, ["y"] = 7, ["z"] = 34 },
			},
			[4] = {
				["catalogId"] = "herd-acorncrest",
				["id"] = "herd-acorncrest-01",
				["position"] = { ["x"] = -74, ["y"] = 8, ["z"] = -46 },
			},
			[5] = {
				["catalogId"] = "scavenger-barkpicker",
				["id"] = "scavenger-barkpicker-01",
				["position"] = { ["x"] = -76, ["y"] = 4, ["z"] = -4 },
			},
			[6] = {
				["catalogId"] = "leaper-fernhop",
				["id"] = "leaper-fernhop-01",
				["position"] = { ["x"] = -100, ["y"] = 6, ["z"] = -14 },
			},
			[7] = {
				["catalogId"] = "charger-oakbrow",
				["id"] = "charger-oakbrow-01",
				["position"] = { ["x"] = -102, ["y"] = 7, ["z"] = 18 },
			},
			[8] = {
				["catalogId"] = "tailswing-mossback",
				["id"] = "tailswing-mossback-01",
				["position"] = { ["x"] = -90, ["y"] = 6, ["z"] = -44 },
			},
			[9] = {
				["catalogId"] = "roarer-thicket",
				["id"] = "roarer-thicket-01",
				["position"] = { ["x"] = -94, ["y"] = 6, ["z"] = 40 },
			},
			[10] = {
				["catalogId"] = "bluff-bounder",
				["id"] = "bluff-bounder-01",
				["position"] = { ["x"] = -108, ["y"] = 7, ["z"] = -4 },
			},
			[11] = {
				["catalogId"] = "fen-trotter",
				["id"] = "fen-trotter-01",
				["position"] = { ["x"] = 68, ["y"] = 2, ["z"] = -4 },
			},
			[12] = {
				["catalogId"] = "herd-sedgewader",
				["id"] = "herd-sedgewader-01",
				["position"] = { ["x"] = 72, ["y"] = 2, ["z"] = 40 },
			},
			[13] = {
				["catalogId"] = "scavenger-flotsam",
				["id"] = "scavenger-flotsam-01",
				["position"] = { ["x"] = 76, ["y"] = 2, ["z"] = -30 },
			},
			[14] = {
				["catalogId"] = "leaper-reedvault",
				["id"] = "leaper-reedvault-01",
				["position"] = { ["x"] = 100, ["y"] = 2, ["z"] = -24 },
			},
			[15] = {
				["catalogId"] = "charger-mudbrow",
				["id"] = "charger-mudbrow-01",
				["position"] = { ["x"] = 104, ["y"] = 2, ["z"] = 4 },
			},
			[16] = {
				["catalogId"] = "tailswing-shellclub",
				["id"] = "tailswing-shellclub-01",
				["position"] = { ["x"] = 90, ["y"] = 2, ["z"] = -42 },
			},
			[17] = {
				["catalogId"] = "roarer-tidecall",
				["id"] = "roarer-tidecall-01",
				["position"] = { ["x"] = 98, ["y"] = 1, ["z"] = 30 },
			},
		},
		["version"] = 1,
	}
-- Gameplay numbers come only from generated content.
local content = require("./SurvivalContent")
for _, species in assert(content.wildlifeDetails, "species catalog") do
	local drops = {}
	for _, reservoir in species.dropReservoirs do
		table.insert(drops, { item = reservoir.item, quantity = reservoir.quantity })
	end
	policy.catalog.species[species.id] =
		{ healthMilli = species.health * 1000, damageMilli = species.damage * 1000, drops = drops }
end
return policy
