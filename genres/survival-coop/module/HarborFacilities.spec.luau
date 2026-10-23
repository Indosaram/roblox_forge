--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Harbor = require("./HarborFacilities")
local function content(): any
	return serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
end
return {
	["harbor facilities retain every authored anchor with NPC dock market and stations"] = function()
		local data = content()
		local facilities = Harbor.describe(data)
		local kinds = {}
		local panels = {}
		for _, facility in facilities do
			assert(facility.role == "harbor" and facility.position.x ~= nil, "trade invariant")
			kinds[facility.kind] = (kinds[facility.kind] or 0) + 1
			panels[facility.anchor] = facility.panel or facility.destination
		end
		assert(
			panels["npc.bram"] == "clan-membership" and panels["npc.hop"] == "journal",
			"social and journal launchers"
		)
		assert(panels["npc.tuck"] == "craft" and panels["npc.ines"] == "craft", "craft and remedy interaction")
		assert(panels["visitor-portal"] == "home", "server travel destination")
		for _, facility in facilities do
			if facility.anchor == "practice-seedbed" or facility.anchor == "practice-fiber-stitch" then
				local row = nil
				for _, operation in data.operations do
					row = if operation.id == facility.operation then operation else row
				end
				assert(row and row.kind == "practice", facility.anchor .. " runs its practice operation")
				assert(facility.panel == "operations", facility.anchor .. " opens the operations sheet")
			end
		end
		assert(kinds.npc == 7 and kinds.dock == 2 and kinds.market == 1 and kinds.station == 6, "trade invariant")
		assert(not pcall(Harbor.describe, { layouts = {} }), "trade invariant")
	end,
	["fresh journey table covers every content stage without duplicate catalog numbers"] = function()
		local data = content()
		local stages = Harbor.stages(data)
		assert(#stages == #data.stages + #data.supportRegions, "trade invariant")
		local previous = 0
		for _, row in stages do
			assert(row.level >= previous, "stage levels are sorted")
			previous = row.level
			local source = nil
			for _, candidate in data.stages do
				if candidate.id == row.id then
					source = candidate
				end
			end
			for _, candidate in data.supportRegions do
				if candidate.id == row.id then
					source = candidate
				end
			end
			assert(source and #(source.objectives or {}) == #row.objectives, "trade invariant")
			local authoredMaterials = {}
			for _, layout in data.layouts do
				if layout.id == row.region then
					for _, node in layout.resourceNodes or {} do
						authoredMaterials[node.item] = true
					end
				end
			end
			local count = 0
			for _ in authoredMaterials do
				count += 1
			end
			assert(#row.materials == count, "stage materials match authored resource nodes")
		end
		assert(previous == 60, "trade invariant")
	end,
}
