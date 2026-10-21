--!strict
-- Server role builder. The renderer port owns Roblox Instances; plan() is also
-- usable by headless QA without loading game or touching a desktop window.
local M = {}
function M.plan(content: any, home: any, rules: any): { any }
	local layout: any = nil
	for _, candidate in content.layouts do
		if candidate.id == "rw.home" then
			layout = candidate
			break
		end
	end
	assert(layout, "HOME_LAYOUT_MISSING")
	local parts: { any } = {
		{
			id = "home-land",
			kind = "land",
			position = { x = 0, y = 0, z = 0 },
			size = { x = rules.landSizes[home.landRank], y = 2, z = rules.landSizes[home.landRank] },
		},
		{ id = "home-dock", kind = "dock", position = home.dock, size = rules.dockSize },
	}
	for _, anchor in layout.anchors do
		if
			string.match(anchor.id, "%-pad$")
			and (anchor.id ~= "laboratory-pad" or home.developmentRank >= rules.labRank)
		then
			table.insert(
				parts,
				{ id = anchor.id, kind = "starter-pad", position = anchor.position, size = rules.padSize }
			)
		end
	end
	local ids = {}
	for id in home.structures do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local record = home.structures[id]
		table.insert(parts, { id = id, kind = record.kind, position = record.position, size = rules.structureSize })
	end
	return parts
end

function M.build(config: any): any
	assert(config.isServer(), "HOME_SERVER_ONLY")
	local parts = M.plan(config.content, config.home, config.rules)
	for _, part in parts do
		config.render(part)
	end
	return parts
end

function M.live(content: any, source: any, wildlife: any, nowMillis: any): any
	local world = source.renderRole(content, source, wildlife, nowMillis, "rw.home", source.seed)
	world.publishHome = function(home: any, rules: any)
		world.renderHome(M.plan(content, home, rules))
	end
	return world
end
return M
