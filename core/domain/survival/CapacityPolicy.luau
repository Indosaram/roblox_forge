--!strict
-- Content-version opt-in. V1 remains the default for existing callers and saves.
local M = {}
export type Policy = { bagSlots: number, homeSlots: number, clanMembers: number, healthMilli: number }
local V1: Policy = table.freeze({ bagSlots = 20, homeSlots = 20, clanMembers = 4, healthMilli = 1000000 })
-- V2 health is capped at 3,000,000 milli-health, including the 2,600,000 tyrannosaurus.
local V2: Policy = table.freeze({ bagSlots = 30, homeSlots = 45, clanMembers = 50, healthMilli = 3000000 })
function M.forVersion(version: number?): Policy
	assert(version == nil or version == 1 or version == 2, "UNSUPPORTED_CAPACITY_VERSION")
	return if version == 2 then V2 else V1
end
return M
