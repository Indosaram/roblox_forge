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

function M.roleTarget(deploy: any, environment: string, role: string): (any?, string?)
	local Topology = require("../../../core/domain/island/Topology")
	if Topology.ROLES[role] == nil then
		return nil, "unknown_role"
	end
	local selected = deploy.environments and deploy.environments[environment]
	local roles = selected and selected.roles
	if type(roles) ~= "table" then
		return nil, "missing_role_config"
	end
	local resolved, reason = Topology.resolveRole(roles, roles[role] or 0)
	if resolved ~= role then
		return nil, reason or "unconfigured_role"
	end
	local result = table.clone(selected)
	result.placeId = roles[role]
	return { environments = { [environment] = result } }, nil
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
local function runDryRun(pack: string, packDir: string, env: string, quality: qualitygate.Result, out: string?): boolean
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
	local deployPath = packDir .. "/deploy.yml"
	if fs.isFile(deployPath) then
		local deploy = decodeYaml(deployPath)
		if deploy == nil then
			stdio.ewrite("Error: failed to decode " .. deployPath .. "\n")
			return false
		end
		assets = deploy.assets
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
	fs.writeFile(reportPath, if out then serde.encode("json", built, true) .. "\n" else text)
	stdio.write(text)
	stdio.write(string.format("deploy plan: %d items, %d assets -> %s\n", #built.items, #built.assets, reportPath))
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
		if flag == "--dry-run" or flag == "--development" then
			if flag == "--dry-run" then
				dryRun = true
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
		return runDryRun(pack, packDir, env, quality, out)
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
	if role then
		local roleDeploy, roleError = M.roleTarget(deploy, env, role)
		if roleDeploy == nil then
			stdio.ewrite("invalid role deploy target: " .. tostring(roleError) .. "\n")
			return false
		end
		selectedDeploy = roleDeploy
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
		if role then
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
			config.Value = serde.encode("json", deploy.environments[env].roles)
			config.Parent = storage
			fs.writeFile(outputPath, roblox.serializePlace(place))
		end
	end
	-- Release publishes the assessed artifact, never an unassessed rebuild.
	-- Hold the upload bytes across the final gate to detect artifact replacement.
	local artifact = fs.readFile(outputPath)
	if role then
		-- The same assessed bytes serve every role. Refuse a mismatched map instead
		-- of silently rewriting an approved artifact during publication.
		local place = require("@lune/roblox").deserializePlace(artifact)
		local storage = place:FindFirstChild("ServerStorage")
		local config = if storage then storage:FindFirstChild("ForgePlaceRoles") else nil
		local expected = deploy.environments[env].roles
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
