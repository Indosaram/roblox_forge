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
					["facingDot"] = 0.5,
					["rangeStuds"] = 8,
					["wearMilli"] = 1000,
				},
			},
		},
		["maxReceipts"] = 512,
		["maximum"] = 8,
		["sourceKey"] = "wildlife-v1",
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
				["position"] = { ["x"] = -34, ["y"] = 4, ["z"] = 30 },
			},
			[4] = {
				["catalogId"] = "fen-trotter",
				["id"] = "fen-trotter-01",
				["position"] = { ["x"] = -8, ["y"] = 4, ["z"] = 36 },
			},
			[5] = {
				["catalogId"] = "bluff-bounder",
				["id"] = "bluff-bounder-01",
				["position"] = { ["x"] = 36, ["y"] = 4, ["z"] = 34 },
			},
		},
		["version"] = 1,
	}
return policy
