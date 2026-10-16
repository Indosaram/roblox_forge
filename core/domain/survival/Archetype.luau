--!strict
-- Archetype: the original wildlife archetype roster and behaviour flags.
--
-- Pure data plus integer arithmetic. An archetype names which sensing engine a
-- species runs ("grazer" flees, "hunter" warns/chases/strikes) and its default
-- engagement flag. Danger bands scale detection radii with fixed-point
-- multipliers so higher-risk islands notice players from further away. Ids
-- are original names; no source-game roster is reproduced here.

local M = {}

export type Engine = "grazer" | "hunter"
export type Flag = "passive" | "retaliate" | "aggressive"
export type Definition = { id: string, engine: Engine, flag: Flag, herd: boolean }

local ARCHETYPES: { [string]: Definition } = {
	leaper = { id = "leaper", engine = "hunter", flag = "aggressive", herd = false },
	charger = { id = "charger", engine = "hunter", flag = "aggressive", herd = false },
	["tail-sweeper"] = { id = "tail-sweeper", engine = "hunter", flag = "retaliate", herd = false },
	roarer = { id = "roarer", engine = "hunter", flag = "aggressive", herd = true },
	scavenger = { id = "scavenger", engine = "hunter", flag = "retaliate", herd = false },
	["herd-grazer"] = { id = "herd-grazer", engine = "grazer", flag = "passive", herd = true },
}

--- Archetype ids in ascending order.
M.IDS = { "charger", "herd-grazer", "leaper", "roarer", "scavenger", "tail-sweeper" }

--- Flags in escalating order: passive never engages, retaliate engages only
--- once provoked, aggressive engages anything inside its detection radius.
M.FLAGS = { "passive", "retaliate", "aggressive" }

--- Flags each engine may run. A grazer has no attack fields, so it can only
--- be passive; a hunter engine always fights back.
local ENGINE_FLAGS: { [string]: { string } } = {
	grazer = { "passive" },
	hunter = { "retaliate", "aggressive" },
}

--- Legacy behaviour names keep their original meaning: band 1, the engine's
--- historical flag.
local LEGACY: { [string]: Definition } = {
	grazer = { id = "grazer", engine = "grazer", flag = "passive", herd = false },
	hunter = { id = "hunter", engine = "hunter", flag = "aggressive", herd = false },
}

--- Detection multiplier per danger band, in permille. Band 1 is exactly the
--- authored radius so legacy content behaves as before.
M.BAND_DETECTION_PERMILLE = { 1000, 1250, 1500, 2000 }
M.BAND_MIN, M.BAND_MAX = 1, 4

--- Engagement ends after this long without the target in strike range, so no
--- creature can keep an aggro it can never resolve (teleport, death, stuck).
M.DISENGAGE_MILLIS = 20000
--- Fraction of max health restored per second while returning to its leash
--- home, in permille; arriving home restores the remainder.
M.RETURN_REGEN_PERMILLE_PER_SECOND = 250
--- No living actor within this many studs: the creature hibernates.
M.HIBERNATE_STUDS = 160
--- A sleeping creature wakes when an actor is inside this permille of its
--- detection radius.
M.WAKE_PERMILLE = 500

--- Resolves an authored behaviour (legacy engine name or archetype id).
function M.get(behavior: string): Definition?
	local found = ARCHETYPES[behavior] or LEGACY[behavior]
	return if found then table.clone(found) else nil
end

function M.isArchetype(behavior: string): boolean
	return ARCHETYPES[behavior] ~= nil
end

function M.engine(behavior: string): Engine?
	local found = ARCHETYPES[behavior] or LEGACY[behavior]
	return if found then found.engine else nil
end

function M.allowsFlag(engine: string, flag: string): boolean
	local allowed = ENGINE_FLAGS[engine]
	return allowed ~= nil and table.find(allowed, flag) ~= nil
end

function M.isBand(band: any): boolean
	return type(band) == "number" and band % 1 == 0 and band >= M.BAND_MIN and band <= M.BAND_MAX
end

--- Scales a base radius by the band's detection multiplier (integer studs,
--- rounded down, never below the base).
function M.detection(baseStuds: number, band: number): number
	assert(M.isBand(band), "INVALID_BAND")
	return baseStuds * M.BAND_DETECTION_PERMILLE[band] // 1000
end

return M
