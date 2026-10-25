--!strict
-- `forge deploy [plan] --env staging|production [--pack <slug>] [--pack-dir <path>] [--dry-run]`:
-- publish the assessed artifact; build development places through buildtargets.
-- --pack-dir names the pack directory directly (a scratch sweep pack), so a
-- generated pack outside games/ can be published without editing games/.
-- Local quality, human gate, API key and deploy ids precede any network call.
-- --development is explicit staging-only status, never release approval.
-- `--dry-run` plans the product create/update actions and asset list offline
-- (no API key, no ids, no network) and writes reports/deploy-plan-<pack>-<env>.md.

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local deployPlan = require("../lib/deployplan")
local deploytarget = require("../lib/deploytarget")
local cliutil = require("../lib/cliutil")
local qualitygate = require("../lib/qualitygate")
local buildtargets = require("../lib/buildtargets")
local opencloud = require("../lib/opencloud")

local M = {}

function M.roleTarget(
	deploy: any,
	environment: string,
	role: string,
	variables: { [string]: string? }?
): (any?, string?)
	local Topology = require("../../../core/domain/island/Topology")
	if Topology.ROLES[role] == nil then
		return nil, "unknown_role"
	end
	local selected = deploy.environments and deploy.environments[environment]
	local roles = selected and selected.roles
	if type(roles) ~= "table" then
		return nil, "missing_role_config"
	end
	if variables then
		-- `${NAME}` role ids (onboarding usually names the start place) resolve
		-- like the environment ids; an unset reference counts as unconfigured.
		local expanded = {}
		for name, value in roles do
			local id, unset = deploytarget.expand(value, variables)
			expanded[name] = if unset then 0 else id
		end
		roles = expanded
	end
	local resolved, reason = Topology.resolveRole(roles, roles[role] or 0)
	if resolved ~= role then
		return nil, reason or "unconfigured_role"
	end
	local result = table.clone(selected)
	result.placeId = roles[role]
	return { environments = { [environment] = result } }, nil
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
	local universe = deploytarget.expand(selected.universeId, variables)
	local start = deploytarget.expand(selected.placeId, variables)
	result.universeId = if deploytarget.isTargetId(universe) then universe else nil
	result.startPlaceId = if deploytarget.isTargetId(start) then start else nil
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
		local id, unset = deploytarget.expand(selected.roles[role], variables)
		if unset ~= nil or id == nil or id == 0 then
			table.insert(result.missing, role)
		elseif not deploytarget.isTargetId(id) then
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

--- Byte-stable markdown section listing every role place the publish touches.
function M.renderRolePlan(plan: RolePlan, environment: string): string
	local lines = { "## Role places (" .. environment .. ")", "" }
	table.insert(
		lines,
		"universeId: " .. (if plan.universeId then string.format("%d", plan.universeId) else "UNRESOLVED")
	)
	table.insert(
		lines,
		"startPlaceId: " .. (if plan.startPlaceId then string.format("%d", plan.startPlaceId) else "UNRESOLVED")
	)
	table.insert(lines, "")
	table.insert(lines, "| order | role | placeId | publish |")
	table.insert(lines, "| --- | --- | --- | --- |")
	for index, place in plan.places do
		table.insert(
			lines,
			string.format("| %d | %s | %d | POST %s |", index, place.role, place.placeId, place.url or "UNRESOLVED")
		)
	end
	for _, role in plan.missing do
		table.insert(
			lines,
			string.format(
				"| - | %s | MISSING | owner creates the place, then `deploy roles --set %s=<id>` |",
				role,
				role
			)
		)
	end
	table.insert(lines, "")
	local keys: { string } = {}
	for role in plan.map do
		table.insert(keys, role)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, role in keys do
		table.insert(parts, string.format("%q:%d", role, plan.map[role]))
	end
	table.insert(lines, "ServerStorage.ForgePlaceRoles = {" .. table.concat(parts, ",") .. "}")
	table.insert(lines, "missing: " .. (if #plan.missing > 0 then table.concat(plan.missing, ",") else "none"))
	table.insert(lines, "errors: " .. (if #plan.errors > 0 then table.concat(plan.errors, ",") else "none"))
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

local REFERENCE_VALUE = "^%$%{([A-Za-z_][A-Za-z0-9_]*)%}%s*$"

--- Visits every `      <role>: <value>` line under `environments.<env>.roles`.
local function eachRoleLine(lines: { string }, env: string, visit: (index: number, role: string, value: string) -> ())
	local inEnv, inRoles = false, false
	for i, line in lines do
		local envName = string.match(line, "^  ([%w%-]+):%s*$")
		if envName then
			inEnv, inRoles = envName == env, false
		elseif inEnv and string.match(line, "^    roles:%s*$") then
			inRoles = true
		elseif inRoles and string.match(line, "^      %S") then
			local role, value = string.match(line, "^      ([%w%-]+):%s*(.-)%s*$")
			if role then
				visit(i, role, value or "")
			end
		elseif string.match(line, "^%S") then
			inEnv, inRoles = false, false
		elseif string.match(line, "^    %S") then
			inRoles = false
		end
	end
end

--- Maps each role in `sets` whose deploy.yml value is a `${NAME}` reference to
--- NAME. Those rows are never rewritten: the id belongs in the environment.
function M.roleReferences(source: string, env: string, sets: { [string]: number }): { [string]: string }
	local result: { [string]: string } = {}
	eachRoleLine(string.split(source, "\n"), env, function(_index, role, value)
		local name = string.match(value, REFERENCE_VALUE)
		if sets[role] ~= nil and name ~= nil then
			result[role] = name
		end
	end)
	return result
end

--- `deploy roles --env <env> [--pack <slug> | --pack-dir <dir>] --set role=id [...]`:
--- writes owner-created role place ids back into deploy.yml in place (comments
--- and layout are kept; only the named literal `      <role>: <n>` lines change).
--- A role whose value is a `${NAME}` reference keeps the reference; the command
--- prints `NAME=<id>` for the operator's .env.local instead.
function M.setRoles(args: { string }, variables: { [string]: string? }): boolean
	local Topology = require("../../../core/domain/island/Topology")
	local env: string? = nil
	local packDir: string? = nil
	local sets: { [string]: number } = {}
	local index = 3
	while index <= #args do
		local flag, value = args[index], args[index + 1]
		if value == nil or string.sub(value, 1, 2) == "--" then
			stdio.ewrite("Error: " .. tostring(flag) .. " requires a value\n")
			return false
		end
		if flag == "--env" then
			env = value
		elseif flag == "--pack" and cliutil.isValidKey(value) then
			packDir = "games/" .. value
		elseif flag == "--pack-dir" then
			packDir = value
		elseif flag == "--set" then
			local role, id = string.match(value, "^([%w%-]+)=(%d+)$")
			local number = tonumber(id)
			if role == nil or Topology.ROLES[role] == nil or not deploytarget.isTargetId(number) then
				stdio.ewrite("Error: --set expects <role>=<positive place id>, got " .. value .. "\n")
				return false
			end
			sets[role :: string] = number :: number
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge deploy roles\n")
			return false
		end
		index += 2
	end
	if (env ~= "staging" and env ~= "production") or packDir == nil or next(sets) == nil then
		stdio.ewrite("Error: deploy roles requires --env staging|production, --pack and --set role=id\n")
		return false
	end
	local path = (packDir :: string) .. "/deploy.yml"
	if not fs.isFile(path) then
		stdio.ewrite("Error: missing " .. path .. "\n")
		return false
	end
	local source = fs.readFile(path)
	local lines = string.split(source, "\n")
	local references = M.roleReferences(source, env :: string, sets)
	local written: { [string]: boolean } = {}
	eachRoleLine(lines, env :: string, function(i, role, _value)
		if sets[role] then
			if references[role] == nil then
				lines[i] = string.format("      %s: %d", role, sets[role])
			end
			written[role] = true
		end
	end)
	for role in sets do
		if not written[role] then
			stdio.ewrite("Error: " .. path .. " has no environments." .. env .. ".roles." .. role .. " line\n")
			return false
		end
	end
	local updated = table.concat(lines, "\n")
	local decoded = serde.decode("yaml", updated)
	-- Validate as if the referenced variables already held the new ids.
	local planVariables: { [string]: string? } = table.clone(variables)
	for role, name in references do
		planVariables[name] = string.format("%d", sets[role])
	end
	local plan = M.rolePlan(decoded, env, planVariables)
	if plan == nil or #plan.errors > 0 then
		stdio.ewrite(
			"Error: refusing role ids: " .. (if plan then table.concat(plan.errors, ",") else "no roles") .. "\n"
		)
		return false
	end
	if updated ~= source then
		fs.writeFile(path, updated)
	end
	local referenced: { string } = {}
	for role in references do
		table.insert(referenced, role)
	end
	table.sort(referenced)
	for _, role in referenced do
		stdio.write(
			string.format(
				"deploy roles: %s references ${%s}; kept the reference - set %s=%d in .env.local (or the process environment)\n",
				role,
				references[role],
				references[role],
				sets[role]
			)
		)
	end
	stdio.write(
		string.format(
			"deploy roles: %s %s; missing: %s\n",
			if updated ~= source then "wrote" else "left unchanged",
			path,
			if #plan.missing > 0 then table.concat(plan.missing, ",") else "none"
		)
	)
	return true
end

local DEFAULT_PACK = "kaiju-egg-raiders"
local ENVS = { "staging", "production" }

local function isEnv(value: string): boolean
	for _, known in ENVS do
		if known == value then
			return true
		end
	end
	return false
end

local function ensureDir(path: string)
	if not fs.isDir(path) then
		fs.writeDir(path)
	end
end

local function decodeYaml(path: string): any
	local ok, decoded = pcall(function()
		return serde.decode("yaml", fs.readFile(path))
	end)
	if not ok or typeof(decoded) ~= "table" then
		return nil
	end
	return decoded
end

--- Offline planning path: reads game.yml monetization and deploy.yml assets,
--- refuses paid random items, and writes the deterministic plan report.
local function runDryRun(
	pack: string,
	packDir: string,
	env: string,
	quality: qualitygate.Result,
	out: string?,
	variables: { [string]: string? }
): boolean
	local gamePath = packDir .. "/game.yml"
	if not fs.isDir(packDir) or not fs.isFile(gamePath) then
		stdio.ewrite("Error: missing " .. gamePath .. "\n")
		return false
	end
	local game = decodeYaml(gamePath)
	if game == nil then
		stdio.ewrite("Error: failed to decode " .. gamePath .. "\n")
		return false
	end

	local assets: any = nil
	local rolePlan: RolePlan? = nil
	local deployPath = packDir .. "/deploy.yml"
	if fs.isFile(deployPath) then
		local deploy = decodeYaml(deployPath)
		if deploy == nil then
			stdio.ewrite("Error: failed to decode " .. deployPath .. "\n")
			return false
		end
		assets = deploy.assets
		rolePlan = M.rolePlan(deploy, env, variables)
	end

	local plan, err = deployPlan.buildPlan(pack, env, game.monetization, assets, quality)
	if plan == nil then
		stdio.ewrite((err or "invalid deploy plan") .. "\n")
		return false
	end

	local built = plan :: deployPlan.Plan
	local reportPath = out or "reports/deploy-plan-" .. pack .. "-" .. env .. ".md"
	local directory = string.match(reportPath, "^(.*)/[^/]+$")
	if directory then
		ensureDir(directory)
	end
	local text = deployPlan.render(built)
	local encoded: any = built
	if rolePlan then
		text ..= "\n" .. M.renderRolePlan(rolePlan, env)
		encoded = table.clone(built) :: any
		encoded.rolePlaces = rolePlan
	end
	fs.writeFile(reportPath, if out then serde.encode("json", encoded, true) .. "\n" else text)
	stdio.write(text)
	stdio.write(string.format("deploy plan: %d items, %d assets -> %s\n", #built.items, #built.assets, reportPath))
	if rolePlan then
		stdio.write(
			string.format(
				"deploy plan: %d role places publishable, %d missing, %d errors (deploy --all-roles %s)\n",
				#rolePlan.places,
				#rolePlan.missing,
				#rolePlan.errors,
				if #rolePlan.missing == 0 and #rolePlan.errors == 0 then "ready" else "refused"
			)
		)
	end
	return true
end

--- Publishes the one assessed artifact to every role place in plan order
--- (start place last). One attempt per place, never retried; the first
--- failure stops the run so the start place never routes to a stale role.
function M.publishRoles(
	plan: RolePlan,
	artifact: string,
	apiKey: string,
	request: (net.FetchParams) -> any,
	outputPath: string,
	env: string
): boolean
	local sha = serde.hash("sha256", artifact)
	for index, place in plan.places do
		local headers: { [string]: string } = {
			["x-api-key"] = apiKey,
			["Content-Type"] = "application/octet-stream",
		}
		local response = opencloud.publish(function()
			return request({
				url = place.url :: string,
				method = "POST",
				headers = headers,
				body = artifact,
			})
		end, "place")
		stdio.write(
			string.format(
				"deploy: [%d/%d] %s place %d %s%s\n",
				index,
				#plan.places,
				place.role,
				place.placeId,
				response.code,
				if response.status then " HTTP " .. tostring(response.status) else ""
			)
		)
		if not response.ok then
			stdio.ewrite(
				"deploy --all-roles: stopped at " .. place.role .. "; later places keep their previous version\n"
			)
			return false
		end
		stdio.write(
			string.format(
				"deploy: accepted role=%s version=%s artifactSha256=%s\n",
				place.role,
				tostring(response.version),
				sha
			)
		)
	end
	stdio.write(
		string.format(
			"deploy: published %s to %d role places of universe %d (%s)\n",
			outputPath,
			#plan.places,
			plan.universeId :: number,
			env
		)
	)
	return true
end

--- Builds and publishes a pack. Returns false with a stderr message on refusal;
--- only reaches the network after every pre-flight check passes.
function M.run(args: { string }, ports: { env: { [string]: string? }?, request: ((net.FetchParams) -> any)? }?): boolean
	local variables = if ports and ports.env then ports.env else process.env
	local env: string? = nil
	local pack = DEFAULT_PACK
	local namedPack = false
	local seen: { [string]: boolean } = {}
	local dryRun = false
	local development = false
	local out: string? = nil
	local packDirOverride: string? = nil
	local role: string? = nil
	local allRoles = false
	if args[2] == "roles" then
		return M.setRoles(args, variables)
	end
	local index = if args[2] == "plan" then 3 else 2
	if args[2] == "plan" then
		dryRun = true
	end
	while index <= #args do
		local flag = args[index]
		if seen[flag] then
			stdio.ewrite("Error: duplicate deploy option " .. flag .. "\n")
			return false
		end
		seen[flag] = true
		if flag == "--dry-run" or flag == "--development" or flag == "--all-roles" then
			if flag == "--dry-run" then
				dryRun = true
			elseif flag == "--all-roles" then
				allRoles = true
			else
				development = true
			end
			index += 1
		elseif flag == "--env" or flag == "--pack" or flag == "--out" or flag == "--pack-dir" or flag == "--role" then
			local value = args[index + 1]
			if value == nil or value == "" or string.sub(value, 1, 2) == "--" then
				stdio.ewrite("Error: " .. flag .. " requires a value\n")
				return false
			end
			if flag == "--role" then
				role = value
			elseif flag == "--env" then
				env = value
			elseif flag == "--out" then
				out = value
			elseif flag == "--pack-dir" then
				packDirOverride = value
			else
				pack = value
				namedPack = true
			end
			index += 2
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge deploy\n")
			return false
		end
	end

	if env == nil or not isEnv(env) then
		stdio.ewrite("Error: forge deploy requires --env " .. table.concat(ENVS, "|") .. "\n")
		return false
	end

	if not cliutil.isValidKey(pack) or (out ~= nil and not dryRun) then
		stdio.ewrite("Error: invalid pack slug or --out without plan/--dry-run\n")
		return false
	end
	if allRoles and role ~= nil then
		stdio.ewrite("Error: --all-roles and --role are exclusive\n")
		return false
	end
	if development and not namedPack then
		stdio.ewrite("Error: --development requires explicit --pack\n")
		return false
	end
	local packDir = packDirOverride or ("games/" .. pack)
	local function checkQuality(): qualitygate.Result
		return qualitygate.check({
			pack = pack,
			packDir = packDir,
			environment = env,
			development = development,
			buildPath = "build/" .. pack .. ".rbxl",
			authority = {
				identity = variables.FORGE_QUALITY_EVALUATOR or "",
				attestationPath = variables.FORGE_QUALITY_ATTESTATION or "",
			},
		})
	end
	local quality = checkQuality()
	if not quality.ok or (not development and not quality.releaseApproved) then
		stdio.ewrite("deploy quality: " .. quality.code .. "\n" .. table.concat(quality.errors, "\n") .. "\n")
		return false
	end
	stdio.write("deploy quality: " .. quality.code .. "; releaseApproved=" .. tostring(quality.releaseApproved) .. "\n")
	if dryRun then
		return runDryRun(pack, packDir, env, quality, out, variables)
	end

	if env == "production" and variables["FORGE_ALLOW_PRODUCTION"] ~= "1" then
		stdio.ewrite("refusing production deploy: set FORGE_ALLOW_PRODUCTION=1 to pass the human gate\n")
		return false
	end

	local deployPath = packDir .. "/deploy.yml"
	if not fs.isDir(packDir) or not fs.isFile(deployPath) then
		stdio.ewrite("Error: missing " .. deployPath .. "\n")
		return false
	end

	local ok, deploy = pcall(function()
		return serde.decode("yaml", fs.readFile(deployPath))
	end)
	if not ok or typeof(deploy) ~= "table" then
		stdio.ewrite("Error: failed to decode " .. deployPath .. "\n")
		return false
	end

	-- The selected environment's ids are literal integers or `${NAME}`
	-- references resolved from the operator's environment; an unset reference is
	-- refused by name so a missing variable never becomes a wrong target.
	local selectedDeploy = deploy
	local rolePlan: RolePlan? = nil
	local roleMap: { [string]: number }? = nil
	if allRoles then
		local plan = M.rolePlan(deploy, env, variables)
		if plan == nil then
			stdio.ewrite("deploy --all-roles: environments." .. env .. ".roles is not configured\n")
			return false
		end
		local resolved = plan :: RolePlan
		if #resolved.errors > 0 or #resolved.missing > 0 or resolved.map.onboarding == nil then
			stdio.ewrite(
				"deploy --all-roles: refused; missing role places: "
					.. (if #resolved.missing > 0 then table.concat(resolved.missing, ",") else "none")
					.. "; errors: "
					.. (if #resolved.errors > 0 then table.concat(resolved.errors, ",") else "none")
					.. "\n"
			)
			return false
		end
		rolePlan = resolved
		roleMap = resolved.map
	elseif role then
		local roleDeploy, roleError = M.roleTarget(deploy, env, role, variables)
		if roleDeploy == nil then
			stdio.ewrite("invalid role deploy target: " .. tostring(roleError) .. "\n")
			return false
		end
		selectedDeploy = roleDeploy
		local resolved = M.rolePlan(deploy, env, variables) :: RolePlan
		if #resolved.errors > 0 then
			stdio.ewrite("invalid role deploy target: " .. table.concat(resolved.errors, ",") .. "\n")
			return false
		end
		roleMap = resolved.map
	elseif deploy.environments[env].roles ~= nil then
		stdio.ewrite("role-configured deploy requires --role\n")
		return false
	end
	local target, targetError = deploytarget.target(selectedDeploy, env, variables)
	if target == nil then
		stdio.ewrite("invalid deploy target: " .. deployPath .. " " .. tostring(targetError) .. "\n")
		return false
	end
	local resolvedTarget = target :: deploytarget.Target
	local universeId = resolvedTarget.universeId
	local placeId = resolvedTarget.placeId

	local apiKey, credentialError = opencloud.credential(variables, env, universeId, placeId)
	if apiKey == nil then
		stdio.ewrite("deploy: " .. tostring(credentialError) .. "\n")
		return false
	end
	if not (ports and ports.request) then
		-- The default transport spawns bun; refuse before building or publishing
		-- the first place when it is absent.
		local ready, transportError = opencloud.transportReady()
		if not ready then
			stdio.ewrite("deploy: " .. tostring(transportError) .. "\n")
			return false
		end
	end
	local otherEnv = if env == "staging" then "production" else "staging"
	local other = deploytarget.target(deploy, otherEnv, variables)
	if other ~= nil then
		local otherTarget = other :: deploytarget.Target
		if otherTarget.universeId == universeId or otherTarget.placeId == placeId then
			stdio.ewrite("deploy: TARGET_ENVIRONMENT_OVERLAP\n")
			return false
		end
	end

	local projectPath = packDir .. "/default.project.json"
	if not fs.isFile(projectPath) then
		stdio.ewrite("Error: missing " .. projectPath .. "\n")
		return false
	end

	local outputPath = "build/" .. pack .. ".rbxl"
	if development then
		local buildRes = buildtargets.runTarget({
			kind = "pack",
			slug = pack,
			packDir = packDir,
			projectPath = projectPath,
			outputPath = outputPath,
		})
		if not buildRes.ok then
			stdio.ewrite(table.concat(buildRes.errors, "\n") .. "\n")
			return false
		end
		stdio.write("deploy: built " .. outputPath .. "\n")
		if roleMap then
			local roblox = require("@lune/roblox")
			local place = roblox.deserializePlace(fs.readFile(outputPath))
			local storage = place:FindFirstChild("ServerStorage")
			if storage == nil then
				local created = roblox.Instance.new("ServerStorage")
				created.Parent = place
				storage = created
			end
			local config = roblox.Instance.new("StringValue")
			config.Name = "ForgePlaceRoles"
			config.Value = serde.encode("json", roleMap)
			config.Parent = storage
			fs.writeFile(outputPath, roblox.serializePlace(place))
		end
	end
	-- Release publishes the assessed artifact, never an unassessed rebuild.
	-- Hold the upload bytes across the final gate to detect artifact replacement.
	local artifact = fs.readFile(outputPath)
	if roleMap then
		-- The same assessed bytes serve every role. Refuse a mismatched map instead
		-- of silently rewriting an approved artifact during publication.
		local place = require("@lune/roblox").deserializePlace(artifact)
		local storage = place:FindFirstChild("ServerStorage")
		local config = if storage then storage:FindFirstChild("ForgePlaceRoles") else nil
		local expected = roleMap :: { [string]: number }
		local actual = if config and config:IsA("StringValue") then serde.decode("json", (config :: any).Value) else nil
		for name, id in expected do
			if actual == nil or actual[name] ~= id then
				stdio.ewrite("role artifact configuration mismatch: " .. name .. "\n")
				return false
			end
		end
	end
	quality = checkQuality()
	if not quality.ok or (not development and not quality.releaseApproved) then
		stdio.ewrite("deploy quality: " .. quality.code .. "\n" .. table.concat(quality.errors, "\n") .. "\n")
		return false
	end
	if fs.readFile(outputPath) ~= artifact then
		stdio.ewrite("deploy quality: artifact changed during final authorization\n")
		return false
	end

	if rolePlan then
		local request: (net.FetchParams) -> any = if ports and ports.request then ports.request else opencloud.request
		return M.publishRoles(rolePlan, artifact, apiKey :: string, request, outputPath, env)
	end

	local url = string.format(
		"https://apis.roblox.com/universes/v1/%d/places/%d/versions?versionType=Published",
		universeId,
		placeId
	)
	local headers: { [string]: string } = {
		["x-api-key"] = apiKey,
		["Content-Type"] = "application/octet-stream",
	}
	local response = opencloud.publish(function()
		local request: (net.FetchParams) -> any = if ports and ports.request then ports.request else opencloud.request
		return request({
			url = url,
			method = "POST",
			headers = headers,
			body = artifact,
		})
	end, "place")

	stdio.write(
		"deploy: " .. response.code .. (if response.status then " HTTP " .. tostring(response.status) else "") .. "\n"
	)
	if not response.ok then
		return false
	end
	stdio.write(
		"deploy: accepted version="
			.. tostring(response.version)
			.. " artifactSha256="
			.. serde.hash("sha256", artifact)
			.. "\n"
	)
	stdio.write(
		string.format("deploy: published %s to universe %d place %d (%s)\n", outputPath, universeId, placeId, env)
	)
	return true
end

return M
