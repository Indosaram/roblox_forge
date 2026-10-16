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
		},
		["version"] = 1,
	}
return policy
