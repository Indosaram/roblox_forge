--!strict
-- A gather node that names a tool is served only while that tool is held, and the world registers a
-- held Tool only for items tagged "tool" with durability (SurvivalWorld toolDefinitions). The tiered
-- weapon-tools (starter-pickaxe, pickaxe-t1..t3, bow-t1, ...) lacked the tag, so no flint or copper
-- node could ever be gathered (journey6h: TOOL_UNAVAILABLE from 92 min with a starter pickaxe in the bag).
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Rules = require("../../core/domain/survival/Content")

local Content: any = assert(Rules.canonicalize(serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))))

local function holdable(id: string): boolean
	for _, item in Content.items do
		if item.id == id then
			return table.find(item.tags, "tool") ~= nil and (item.maxDurabilityMilli or 0) > 0
		end
	end
	return false
end

return {
	["every weapon-tool item can be held as a hand tool"] = function()
		for _, item in Content.items do
			if table.find(item.tags, "weapon-tool") then
				assert(holdable(item.id), item.id .. " is a weapon-tool the world cannot register as held")
			end
		end
	end,
	["every tool a gather node names can be held"] = function()
		local checked = 0
		local function walk(value: any)
			if type(value) ~= "table" then
				return
			end
			if type(value.tool) == "string" and type(value.item) == "string" then
				checked += 1
				assert(holdable(value.tool), "node for " .. value.item .. " needs unholdable " .. value.tool)
			end
			for _, child in value do
				walk(child)
			end
		end
		walk(serde.decode("yaml", fs.readFile("games/robango-island/content.yml")))
		assert(checked > 0, "no tool-gated nodes found")
	end,
}
