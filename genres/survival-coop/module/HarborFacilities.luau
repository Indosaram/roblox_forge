--!strict
local M = {}
function M.describe(content: any): { any }
	local layout = nil
	for _, candidate in content.layouts do
		if candidate.id == "rw.harbor" then
			layout = candidate
			break
		end
	end
	assert(layout, "HARBOR_LAYOUT_REQUIRED")
	local result = {}
	for _, anchor in layout.anchors do
		local kind = if string.sub(anchor.id, 1, 4) == "npc."
			then "npc"
			elseif string.sub(anchor.id, 1, 8) == "station." then "station"
			elseif anchor.id == "entry" or anchor.id == "exit" then "dock"
			elseif anchor.id == "objective" then "market"
			else "interaction"
		table.insert(result, {
			id = layout.id .. "." .. anchor.id,
			anchor = anchor.id,
			kind = kind,
			position = table.clone(anchor.position),
			role = "harbor",
			panel = if anchor.id == "npc.marit"
				then "contracts"
				elseif anchor.id == "npc.tuck" then "craft"
				elseif anchor.id == "npc.hop" then "journal"
				elseif anchor.id == "npc.bram" then "clan-membership"
				elseif anchor.id == "npc.ines" then "craft"
				elseif anchor.id == "npc.pip" then "shop"
				elseif anchor.id == "practice-seedbed" or anchor.id == "practice-fiber-stitch" then "craft"
				elseif anchor.id == "rescue-beacon" then "journal"
				elseif anchor.id == "station.workbench.t1" then "craft"
				elseif anchor.id == "station.signal-relay.t1" then "journal"
				elseif anchor.id == "objective" then "market"
				else nil,
			destination = if anchor.id == "visitor-portal" then "home" else nil,
			-- Stations that talk first (ui.dialogue): workbench, communication station, market board.
			talk = if anchor.id == "station.workbench.t1"
				then "station.workbench"
				elseif anchor.id == "station.signal-relay.t1" then "station.relay"
				elseif anchor.id == "objective" then "station.market"
				else nil,
		})
	end
	return result
end
function M.stages(content: any): { any }
	local layouts = {}
	for _, layout in content.layouts do
		layouts[layout.id] = layout
	end
	local result = {}
	local definitions = table.clone(content.stages)
	for _, region in content.supportRegions or {} do
		table.insert(definitions, region)
	end
	for _, stage in definitions do
		local layout = assert(layouts[stage.layout], "STAGE_LAYOUT_REQUIRED")
		local materials, seen = {}, {}
		for _, node in layout.resourceNodes or {} do
			if not seen[node.item] then
				table.insert(materials, node.item)
				seen[node.item] = true
			end
		end
		table.sort(materials)
		local objectives = {}
		for _, objective in stage.objectives or {} do
			table.insert(objectives, table.clone(objective))
		end
		table.insert(result, {
			id = stage.id,
			level = stage.gates.characterLevel or 1,
			region = stage.layout,
			role = stage.role,
			materials = materials,
			objectives = objectives,
			gates = stage.gates,
		})
	end
	table.sort(result, function(a, b)
		return if a.level == b.level then a.id < b.id else a.level < b.level
	end)
	return result
end
return M
