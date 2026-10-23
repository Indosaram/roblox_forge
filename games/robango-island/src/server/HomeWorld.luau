--!strict
-- Server role builder. The renderer port owns Roblox Instances; plan() is also
-- usable by headless QA without loading game or touching a desktop window.
local Dressing = require("./WorldDressing")
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
			-- Chosen terrain preset (home-preset, capped by HomeState.presetSlots); 1 by default.
			preset = home.terrainPreset or 1,
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
	Dressing.home(parts, home, rules)
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

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in value do
		out[key] = copy(child)
	end
	return out
end

local function same(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not same(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

function M.live(content: any, source: any, wildlife: any, nowMillis: any): any
	local world = source.renderRole(content, source, wildlife, nowMillis, "rw.home", source.seed)
	-- Every durable home snapshot publishes, and the survival/wildlife Heartbeats read snapshots
	-- each server frame. The plan is pure in (home, rules), so an unchanged state re-renders
	-- nothing: renderHome rewrites the whole land's Terrain, which halved the home frame rate.
	local lastHome, lastRules = nil, nil
	world.publishHome = function(home: any, rules: any)
		if rules == lastRules and same(home, lastHome) then
			return
		end
		lastHome, lastRules = copy(home), rules
		world.renderHome(M.plan(content, home, rules))
	end
	return world
end
return M
