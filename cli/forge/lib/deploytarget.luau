--!strict
-- Resolves a pack's deploy.yml environment target. A target id is written either
-- as a literal integer or as a lone `${NAME}` environment reference, so a pack
-- never commits a real experience or place id: the value comes from the
-- operator's environment at deploy time (for example
-- `universeId: ${FORGE_STAGING_UNIVERSE_ID}`). A reference that names an unset or
-- empty variable is refused with the variable's name, never silently defaulted.

local M = {}

local REFERENCE_PATTERN = "^%$%{([A-Za-z_][A-Za-z0-9_]*)%}$"
local DIGITS_PATTERN = "^%d+$"

export type Target = { universeId: number, placeId: number }

--- True for a positive finite integer, the only shape a live deploy target takes.
function M.isTargetId(value: any): boolean
	return type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0
end

--- Expands one field. A non-string passes through unchanged; a lone `${NAME}`
--- reference resolves against `variables` and is parsed as an integer when it is
--- one. Returns (value, nil), or (nil, NAME) when the reference is unset/empty.
function M.expand(value: any, variables: { [string]: string? }): (any, string?)
	if type(value) ~= "string" then
		return value, nil
	end
	local text = value
	local name = string.match(value, REFERENCE_PATTERN)
	if name ~= nil then
		local resolved = variables[name]
		if resolved == nil or resolved == "" then
			return nil, name
		end
		text = resolved
	end
	if string.match(text, DIGITS_PATTERN) ~= nil then
		local parsed = tonumber(text)
		if parsed ~= nil then
			return parsed, nil
		end
	end
	return text, nil
end

--- Resolves `environments.<env>` from a decoded deploy.yml. Returns (target, nil)
--- when both ids are positive integers, else (nil, reason) naming the environment
--- and, for an unset reference, the missing variable.
function M.target(deploy: any, env: string, variables: { [string]: string? }): (Target?, string?)
	local environments: any = if type(deploy) == "table" then deploy.environments else nil
	local environment: any = if type(environments) == "table" then environments[env] else nil
	local universeId: any = nil
	local placeId: any = nil
	if type(environment) == "table" then
		universeId = environment.universeId
		placeId = environment.placeId
	end

	local resolvedUniverse, missingUniverse = M.expand(universeId, variables)
	if missingUniverse ~= nil then
		return nil, "environments." .. env .. ".universeId references ${" .. missingUniverse .. "}, which is not set"
	end
	local resolvedPlace, missingPlace = M.expand(placeId, variables)
	if missingPlace ~= nil then
		return nil, "environments." .. env .. ".placeId references ${" .. missingPlace .. "}, which is not set"
	end
	if not M.isTargetId(resolvedUniverse) or not M.isTargetId(resolvedPlace) then
		return nil,
			"environments." .. env .. ".universeId/placeId require positive finite integers (literal or ${ENV_VAR})"
	end
	return { universeId = resolvedUniverse :: number, placeId = resolvedPlace :: number }, nil
end

--- Resolves a single id field where 0 means "unset target" (the liveops/smoke
--- convention). Returns (id, nil) for a literal non-negative integer or a
--- reference resolving to one, (0, nil) when the reference is unset, and
--- (nil, reason) for any other shape.
function M.unsettableId(value: any, variables: { [string]: string? }): (number?, string?)
	local resolved, missing = M.expand(value, variables)
	if missing ~= nil then
		return 0, nil
	end
	if type(resolved) == "number" and resolved >= 0 and resolved < math.huge and resolved % 1 == 0 then
		return resolved, nil
	end
	return nil, "requires a finite nonnegative integer (literal or ${ENV_VAR})"
end

return M
