--!strict
-- Capabilities: the survival-coop genre's declared mode descriptors.
--
-- Kept beside the runtime Contract rather than inside it: `RuntimeContract` is
-- a closed shared type validated by core/domain/genre/Validation, and bolting
-- extra fields onto it would make every genre's descriptor validation laxer.
-- The CLI reads this module directly when it reports a pack's capabilities.

local Capability = require("../../../core/domain/survival/Capability")

local M = {}

M.genre = "survival-coop"

--- Declared modes in selection order. `wave` is the legacy default a config
--- with no `mode` key resolves to.
M.modes = { "wave", "crafting" }

--- Descriptor copies, keyed by mode.
M.descriptors = {
	wave = Capability.describe("wave"),
	crafting = Capability.describe("crafting"),
}

--- Features a mode declares but has not implemented. Non-empty for `crafting`
--- until the wave 2-3 mechanism tasks land.
function M.missing(mode: string): { string }
	return Capability.missingFeatures(mode :: any)
end

return M
