--!strict
-- Specs for the deploy target resolver: literal ids pass through, `${NAME}`
-- references resolve from the environment, and an unset reference is refused
-- with the variable's name instead of silently defaulting to a real id.
local deploytarget = require("./deploytarget")

local SYNTHETIC_UNIVERSE = "1234567890"
local SYNTHETIC_PLACE = "9876543210"

return {
	["literal ids resolve unchanged"] = function()
		local target, err = deploytarget.target(
			{ environments = { staging = { universeId = 42, placeId = 7 } } },
			"staging",
			{}
		)
		assert(err == nil, tostring(err))
		local resolved = target :: deploytarget.Target
		assert(resolved.universeId == 42 and resolved.placeId == 7, "literal ids resolve unchanged")
	end,

	["environment references resolve and parse as integers"] = function()
		local target, err = deploytarget.target({
			environments = {
				staging = {
					universeId = "${FORGE_STAGING_UNIVERSE_ID}",
					placeId = "${FORGE_STAGING_PLACE_ID}",
				},
			},
		}, "staging", { FORGE_STAGING_UNIVERSE_ID = SYNTHETIC_UNIVERSE, FORGE_STAGING_PLACE_ID = SYNTHETIC_PLACE })
		assert(err == nil, tostring(err))
		local resolved = target :: deploytarget.Target
		assert(resolved.universeId == 1234567890, "universe reference resolves to an integer")
		assert(resolved.placeId == 9876543210, "place reference resolves to an integer")
	end,

	["production references resolve like staging"] = function()
		local target, err = deploytarget.target(
			{
				environments = {
					production = {
						universeId = "${FORGE_PRODUCTION_UNIVERSE_ID}",
						placeId = "${FORGE_PRODUCTION_PLACE_ID}",
					},
				},
			},
			"production",
			{ FORGE_PRODUCTION_UNIVERSE_ID = SYNTHETIC_UNIVERSE, FORGE_PRODUCTION_PLACE_ID = SYNTHETIC_PLACE }
		)
		assert(err == nil, tostring(err))
		local resolved = target :: deploytarget.Target
		assert(resolved.universeId == 1234567890 and resolved.placeId == 9876543210, "production references resolve")
	end,

	["an unset reference names the missing variable"] = function()
		local target, err = deploytarget.target(
			{ environments = { staging = { universeId = "${FORGE_STAGING_UNIVERSE_ID}", placeId = 7 } } },
			"staging",
			{}
		)
		assert(
			target == nil
				and err
					== "environments.staging.universeId references ${FORGE_STAGING_UNIVERSE_ID}, which is not set",
			tostring(err)
		)
	end,

	["an empty reference is refused like an unset one"] = function()
		local target, err = deploytarget.target({
			environments = {
				production = {
					universeId = "${FORGE_PRODUCTION_UNIVERSE_ID}",
					placeId = "${FORGE_PRODUCTION_PLACE_ID}",
				},
			},
		}, "production", { FORGE_PRODUCTION_UNIVERSE_ID = "", FORGE_PRODUCTION_PLACE_ID = "9" })
		assert(
			target == nil
				and err
					== "environments.production.universeId references ${FORGE_PRODUCTION_UNIVERSE_ID}, which is not set",
			tostring(err)
		)
	end,

	["non-integer and missing literal targets are refused"] = function()
		-- Typed as `any` so one list can hold a string id and an absent field.
		local cases: { any } = {
			{ universeId = 0, placeId = 7 },
			{ universeId = 42, placeId = -1 },
			{ universeId = "abc", placeId = 7 },
			{ universeId = 42 },
			{},
		}
		for _, environment in cases do
			local target, err = deploytarget.target({ environments = { staging = environment } }, "staging", {})
			assert(
				target == nil
					and err
						== "environments.staging.universeId/placeId require positive finite integers (literal or ${ENV_VAR})",
				tostring(err)
			)
		end
	end,

	["a missing environment is refused"] = function()
		local target, err = deploytarget.target({ environments = {} }, "staging", {})
		assert(
			target == nil
				and err
					== "environments.staging.universeId/placeId require positive finite integers (literal or ${ENV_VAR})",
			tostring(err)
		)
	end,

	["unsettable ids read an unset reference as zero"] = function()
		local unset, unsetErr = deploytarget.unsettableId("${FORGE_STAGING_UNIVERSE_ID}", {})
		assert(unsetErr == nil and unset == 0, "an unset reference reads as unset target 0")
		local literal, literalErr = deploytarget.unsettableId(0, {})
		assert(literalErr == nil and literal == 0, "a literal 0 stays 0")
		local resolved, resolvedErr = deploytarget.unsettableId(
			"${FORGE_STAGING_UNIVERSE_ID}",
			{ FORGE_STAGING_UNIVERSE_ID = SYNTHETIC_UNIVERSE }
		)
		assert(resolvedErr == nil and resolved == 1234567890, "a set reference resolves")
		local bad, badErr = deploytarget.unsettableId("not-an-id", {})
		assert(bad == nil and badErr ~= nil, "a non-integer literal is refused")
	end,
}
