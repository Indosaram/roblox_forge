--!strict
-- Resolves a pack's deploy.yml environment target. A target id is written either
-- as a literal integer or as a lone `${NAME}` environment reference, so a pack
-- never commits a real experience or place id: the value comes from the
-- operator's environment at deploy time (for example
-- `universeId: ${FORGE_STAGING_UNIVERSE_ID}`). A reference that names an unset or
-- empty variable is refused with the variable's name, never silently defaulted.

local serde = require("@lune/serde")

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

export type RolePlace = { role: string, placeId: number, url: string? }
export type RolePlan = {
	universeId: number?,
	startPlaceId: number?,
	places: { RolePlace },
	missing: { string },
	map: { [string]: number },
	errors: { string },
}

--- Resolves every role of a role-configured environment into the publish list
--- used by `--all-roles` and by the dry run. Ids are literal integers or
--- `${NAME}` references. Every Topology role needs its own positive distinct
--- place id (IslandBootstrap refuses a duplicate), and `onboarding` must be the
--- environment's start place because new players join there. The start place
--- is published last so it never routes players to a stale role place.
function M.rolePlan(deploy: any, environment: string, variables: { [string]: string? }): RolePlan?
	local Topology = require("../../../core/domain/island/Topology")
	local selected = if type(deploy) == "table" and type(deploy.environments) == "table"
		then deploy.environments[environment]
		else nil
	if type(selected) ~= "table" or type(selected.roles) ~= "table" then
		return nil
	end
	local result: RolePlan = { places = {}, missing = {}, map = {}, errors = {} }
	local universe = M.expand(selected.universeId, variables)
	local start = M.expand(selected.placeId, variables)
	result.universeId = if M.isTargetId(universe) then universe else nil
	result.startPlaceId = if M.isTargetId(start) then start else nil
	local names: { string } = {}
	for role in Topology.ROLES do
		table.insert(names, role :: string)
	end
	for role in selected.roles do
		if Topology.ROLES[role] == nil then
			table.insert(result.errors, "unknown_role:" .. tostring(role))
		end
	end
	table.sort(names, function(a, b)
		if (a == "onboarding") ~= (b == "onboarding") then
			return b == "onboarding"
		end
		return a < b
	end)
	local owners: { [number]: string } = {}
	for _, role in names do
		local id, unset = M.expand(selected.roles[role], variables)
		if unset ~= nil or id == nil or id == 0 then
			table.insert(result.missing, role)
		elseif not M.isTargetId(id) then
			table.insert(result.errors, "invalid_place_id:" .. role)
		elseif owners[id] then
			table.insert(result.errors, "duplicate_place_id:" .. owners[id] .. "," .. role)
		else
			owners[id] = role
			result.map[role] = id
			table.insert(result.places, {
				role = role,
				placeId = id,
				url = if result.universeId
					then string.format(
						"https://apis.roblox.com/universes/v1/%d/places/%d/versions?versionType=Published",
						result.universeId,
						id
					)
					else nil,
			})
		end
	end
	if result.startPlaceId and result.map.onboarding and result.map.onboarding ~= result.startPlaceId then
		table.insert(result.errors, "onboarding_not_start_place")
	end
	return result
end

--- Product ids for `environments.<env>.monetization`, keyed by game.yml monetization key.
--- Values are literal ids or `${NAME}` references; an unset reference or 0 maps to 0, which the
--- shop lists but never prompts, so a missing production product can never sell the staging item.
--- Returns nil when the environment declares no monetization block.
function M.monetizationIds(deploy: any, environment: string, variables: { [string]: string? }): { [string]: any }?
	local selected = if type(deploy) == "table" and type(deploy.environments) == "table"
		then deploy.environments[environment]
		else nil
	if type(selected) ~= "table" or type(selected.monetization) ~= "table" then
		return nil
	end
	local ids: { [string]: any } = {}
	for key, value in selected.monetization do
		local id, unset = M.expand(value, variables)
		ids[tostring(key)] = if unset ~= nil or id == nil or id == "" then 0 else id
	end
	return ids
end

--- The ServerStorage StringValues (name -> JSON text) an environment build embeds:
--- `ForgePlaceRoles` from the resolved role plan and `ForgeMonetizationIds` from
--- the monetization block, the exact maps `deploy` later requires in the artifact.
--- An environment that declares neither yields an empty table. Role plan errors
--- (unknown role, duplicate id, onboarding not the start place) refuse; missing
--- roles are left out of the map (and `deploy --all-roles` refuses them).
function M.environmentStorage(
	deploy: any,
	environment: string,
	variables: { [string]: string? }
): ({ [string]: string }?, string?)
	if type(deploy) ~= "table" or type(deploy.environments) ~= "table" or deploy.environments[environment] == nil then
		return nil, "deploy.yml declares no environments." .. environment
	end
	local values: { [string]: string } = {}
	local plan = M.rolePlan(deploy, environment, variables)
	if plan ~= nil then
		if #plan.errors > 0 then
			return nil, "environments." .. environment .. ".roles: " .. table.concat(plan.errors, ",")
		end
		values.ForgePlaceRoles = serde.encode("json", plan.map)
	end
	local ids = M.monetizationIds(deploy, environment, variables)
	if ids ~= nil then
		values.ForgeMonetizationIds = serde.encode("json", ids)
	end
	return values, nil
end

return M
