--!strict
-- JourneyKit (journey6h.spec): pure helpers shared by JourneyRunner and JourneyIsland.
local fs = require("@lune/fs")

local M = {}

-- file:line of the first line matching `pattern` (plain) in `path`; the owner of a stall.
local lineCache: { [string]: { string } } = {}
function M.owner(path: string, pattern: string): string
	local lines = lineCache[path]
	if not lines then
		local ok, text = pcall(fs.readFile, path)
		lines = if ok then string.split(text, "\n") else {}
		lineCache[path] = lines
	end
	for index, line in lines do
		if string.find(line, pattern, 1, true) then
			return path .. ":" .. index
		end
	end
	return path .. ":?"
end

function M.count(items: any, catalogId: string): number
	local total = 0
	for _, item in items or {} do
		total += if item.catalogId == catalogId then item.quantity else 0
	end
	return total
end

function M.anchorOf(layout: any, id: string): any
	-- Waypoint.resolve's lookup (anchors, then resource nodes), without its Vector3.
	for _, list in { layout.anchors or {}, layout.resourceNodes or {} } :: { { any } } do
		for _, entry in list do
			if entry.id == id and entry.position then
				return { x = entry.position.x, y = entry.position.y, z = entry.position.z }
			end
		end
	end
	return nil
end

return M
