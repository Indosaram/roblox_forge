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
-- Reconstructed v2 species values from the approved wildlife catalog.
policy.catalog.species["compsognathus"] = {
	healthMilli = 52000,
	damageMilli = 4000,
	drops = { { item = "meat", quantity = 1 }, { item = "bone", quantity = 1 }, { item = "skull", quantity = 1 } },
}
policy.catalog.species["oviraptor"] = {
	healthMilli = 75000,
	damageMilli = 5000,
	drops = {
		{ item = "meat", quantity = 1 },
		{ item = "hide", quantity = 1 },
		{ item = "feather", quantity = 2 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["protoceratops"] = {
	healthMilli = 135000,
	damageMilli = 8000,
	drops = {
		{ item = "meat", quantity = 2 },
		{ item = "hide", quantity = 2 },
		{ item = "bone", quantity = 1 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["gallimimus"] = {
	healthMilli = 297000,
	damageMilli = 0,
	drops = { { item = "meat", quantity = 2 }, { item = "hide", quantity = 1 }, { item = "feather", quantity = 2 } },
}
policy.catalog.species["parasaurolophus"] = {
	healthMilli = 325000,
	damageMilli = 17000,
	drops = {
		{ item = "meat", quantity = 3 },
		{ item = "hide", quantity = 2 },
		{ item = "bone", quantity = 2 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["stegosaurus"] = {
	healthMilli = 630000,
	damageMilli = 38000,
	drops = {
		{ item = "meat", quantity = 4 },
		{ item = "hide", quantity = 3 },
		{ item = "bone", quantity = 3 },
		{ item = "plate", quantity = 2 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["ankylosaurus"] = {
	healthMilli = 990000,
	damageMilli = 49000,
	drops = {
		{ item = "meat", quantity = 3 },
		{ item = "hide", quantity = 2 },
		{ item = "bone", quantity = 2 },
		{ item = "shell-fragment", quantity = 3 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["triceratops"] = {
	healthMilli = 700000,
	damageMilli = 42000,
	drops = {
		{ item = "meat", quantity = 4 },
		{ item = "hide", quantity = 3 },
		{ item = "bone", quantity = 3 },
		{ item = "horn", quantity = 2 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["brachiosaurus"] = {
	healthMilli = 2200000,
	damageMilli = 71000,
	drops = {
		{ item = "meat", quantity = 8 },
		{ item = "hide", quantity = 5 },
		{ item = "bone", quantity = 6 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["utahraptor"] = {
	healthMilli = 517000,
	damageMilli = 51000,
	drops = {
		{ item = "meat", quantity = 3 },
		{ item = "hide", quantity = 2 },
		{ item = "bone", quantity = 2 },
		{ item = "claw", quantity = 2 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["velociraptor"] = {
	healthMilli = 187000,
	damageMilli = 20000,
	drops = {
		{ item = "meat", quantity = 2 },
		{ item = "hide", quantity = 1 },
		{ item = "bone", quantity = 1 },
		{ item = "claw", quantity = 2 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["dilophosaurus"] = {
	healthMilli = 350000,
	damageMilli = 33000,
	drops = {
		{ item = "meat", quantity = 3 },
		{ item = "hide", quantity = 2 },
		{ item = "bone", quantity = 2 },
		{ item = "tooth", quantity = 2 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["allosaurus"] = {
	healthMilli = 1210000,
	damageMilli = 71000,
	drops = {
		{ item = "meat", quantity = 5 },
		{ item = "hide", quantity = 3 },
		{ item = "bone", quantity = 4 },
		{ item = "tooth", quantity = 3 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["tyrannosaurus"] = {
	healthMilli = 2600000,
	damageMilli = 97000,
	drops = {
		{ item = "meat", quantity = 8 },
		{ item = "hide", quantity = 5 },
		{ item = "bone", quantity = 6 },
		{ item = "tooth", quantity = 4 },
		{ item = "volcanic-bone", quantity = 3 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["smilodon"] = {
	healthMilli = 742000,
	damageMilli = 66000,
	drops = {
		{ item = "meat", quantity = 3 },
		{ item = "hide", quantity = 2 },
		{ item = "fur", quantity = 3 },
		{ item = "fang", quantity = 2 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["tropicalSmilodon"] = {
	healthMilli = 517000,
	damageMilli = 49000,
	drops = {
		{ item = "meat", quantity = 3 },
		{ item = "hide", quantity = 2 },
		{ item = "fang", quantity = 2 },
		{ item = "sinew", quantity = 2 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["direWolf"] = {
	healthMilli = 450000,
	damageMilli = 42000,
	drops = {
		{ item = "meat", quantity = 2 },
		{ item = "hide", quantity = 1 },
		{ item = "fur", quantity = 2 },
		{ item = "fang", quantity = 2 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["mammoth"] = {
	healthMilli = 1650000,
	damageMilli = 66000,
	drops = {
		{ item = "meat", quantity = 7 },
		{ item = "hide", quantity = 4 },
		{ item = "fur", quantity = 5 },
		{ item = "bone", quantity = 4 },
		{ item = "tusk", quantity = 2 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["boar"] = {
	healthMilli = 120000,
	damageMilli = 8000,
	drops = {
		{ item = "meat", quantity = 2 },
		{ item = "hide", quantity = 1 },
		{ item = "bone", quantity = 1 },
		{ item = "tusk", quantity = 1 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["deer"] = {
	healthMilli = 90000,
	damageMilli = 0,
	drops = {
		{ item = "meat", quantity = 2 },
		{ item = "hide", quantity = 2 },
		{ item = "bone", quantity = 1 },
		{ item = "antler", quantity = 1 },
	},
}
policy.catalog.species["elephant"] = {
	healthMilli = 875000,
	damageMilli = 35000,
	drops = {
		{ item = "meat", quantity = 6 },
		{ item = "hide", quantity = 4 },
		{ item = "bone", quantity = 4 },
		{ item = "tusk", quantity = 2 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["crocodile"] = {
	healthMilli = 720000,
	damageMilli = 56000,
	drops = {
		{ item = "meat", quantity = 3 },
		{ item = "hide", quantity = 3 },
		{ item = "bone", quantity = 2 },
		{ item = "tooth", quantity = 3 },
		{ item = "skull", quantity = 1 },
	},
}
policy.catalog.species["turtle"] = {
	healthMilli = 97000,
	damageMilli = 0,
	drops = { { item = "meat", quantity = 1 }, { item = "shell-fragment", quantity = 2 } },
}
policy.catalog.species["dodo"] = {
	healthMilli = 45000,
	damageMilli = 0,
	drops = { { item = "meat", quantity = 1 }, { item = "feather", quantity = 3 } },
}
return policy
