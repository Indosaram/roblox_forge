--!strict
-- Regions: level-gated region unlocks for rpg-progression games. A region opens
-- when the player's level meets its threshold, or once force-unlocked.

export type RegionDef = {
	id: string,
	name: string,
	requiredLevel: number,
}

export type Regions = {
	defs: { RegionDef },
	byId: { [string]: RegionDef },
	unlocked: { [string]: boolean },
}

local Regions = {}

local function checkDef(def: RegionDef): ()
	if type(def.id) ~= "string" or def.id == "" then
		error("invalid region id")
	end
	if type(def.name) ~= "string" or def.name == "" then
		error("invalid region name")
	end
	if type(def.requiredLevel) ~= "number" or def.requiredLevel % 1 ~= 0 or def.requiredLevel < 1 then
		error("invalid requiredLevel")
	end
end

local function findRegion(self: Regions, id: string): RegionDef
	if type(id) ~= "string" or id == "" then
		error("invalid region id")
	end
	local def: RegionDef? = self.byId[id]
	if def == nil then
		error("unknown region: " .. id)
	end
	return def
end

function Regions.new(defs: { RegionDef }): Regions
	if type(defs) ~= "table" or #defs == 0 then
		error("invalid region defs")
	end
	local self: Regions = { defs = {}, byId = {}, unlocked = {} }
	for _, def in defs do
		checkDef(def)
		if self.byId[def.id] ~= nil then
			error("duplicate region id: " .. def.id)
		end
		local copy = { id = def.id, name = def.name, requiredLevel = def.requiredLevel }
		table.insert(self.defs, copy)
		self.byId[def.id] = copy
	end
	return self
end

function Regions.requiredLevel(self: Regions, id: string): number
	return findRegion(self, id).requiredLevel
end

function Regions.isUnlocked(self: Regions, id: string, level: number): boolean
	local def = findRegion(self, id)
	if self.unlocked[id] then
		return true
	end
	if type(level) ~= "number" or level ~= level or level % 1 ~= 0 then
		error("invalid level")
	end
	return level >= def.requiredLevel
end

-- Ids of every open region, in definition order.
function Regions.unlockedIds(self: Regions, level: number): { string }
	local ids: { string } = {}
	for _, def in self.defs do
		if Regions.isUnlocked(self, def.id, level) then
			table.insert(ids, def.id)
		end
	end
	return ids
end

-- Opens a region regardless of level; used for quest-gated content.
function Regions.unlock(self: Regions, id: string): ()
	findRegion(self, id)
	self.unlocked[id] = true
end

return Regions
