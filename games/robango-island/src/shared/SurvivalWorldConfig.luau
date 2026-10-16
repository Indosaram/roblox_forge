--!strict
export type Node = {
	id: string,
	catalogId: string,
	position: { x: number, y: number, z: number },
	charges: number,
	qualityMilli: number,
	requiredToolTag: string?,
}
local nodes: { Node } = {
	[1] = {
		["catalogId"] = "fallen-tree",
		["charges"] = 3,
		["id"] = "fallen-tree-01",
		["position"] = { ["x"] = -20, ["y"] = 2, ["z"] = 14 },
		["qualityMilli"] = 1000,
	},
	[2] = {
		["catalogId"] = "flint-outcrop",
		["charges"] = 3,
		["id"] = "flint-outcrop-01",
		["position"] = { ["x"] = -10, ["y"] = 2, ["z"] = 14 },
		["qualityMilli"] = 1000,
	},
	[3] = {
		["catalogId"] = "fiber-bush",
		["charges"] = 3,
		["id"] = "fiber-bush-01",
		["position"] = { ["x"] = 0, ["y"] = 2, ["z"] = 14 },
		["qualityMilli"] = 1000,
	},
	[4] = {
		["catalogId"] = "berry-bush",
		["charges"] = 3,
		["id"] = "berry-bush-01",
		["position"] = { ["x"] = 10, ["y"] = 2, ["z"] = 14 },
		["qualityMilli"] = 1000,
	},
	[5] = {
		["catalogId"] = "meat-cache",
		["charges"] = 3,
		["id"] = "meat-cache-01",
		["position"] = { ["x"] = 20, ["y"] = 2, ["z"] = 14 },
		["qualityMilli"] = 1000,
	},
}
return {
	["nodes"] = nodes,
	["persistencePrefix"] = "s:24ec98ed6876c584",
	["sourceKey"] = "nodes-v1",
	["tribe"] = {
		["config"] = { ["cellStuds"] = 4, ["depth"] = 12, ["maxMembers"] = 4, ["tribeId"] = "camp", ["width"] = 16 },
		["key"] = "camp-v1",
		["origin"] = { ["x"] = -32, ["y"] = 0, ["z"] = -16 },
		["warehouseId"] = "warehouse",
		["warehousePosition"] = { ["x"] = 0, ["y"] = 2, ["z"] = -22 },
		["workshopRevision"] = "development-workshop-v1",
	},
	["worldRevision"] = "development-island-v1",
}
