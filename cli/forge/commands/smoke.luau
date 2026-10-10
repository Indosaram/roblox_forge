--!strict
-- `forge smoke [--pack <slug>] [--local] [--cloud] [--fixture <save.json>] [--dry-run]`
-- `--local` (default) runs a pack's pure Lune smoke script and reports each check.
-- `--cloud` builds and posts an Open Cloud Luau Execution task for the staging
-- place, then polls it to completion. `--dry-run` prints the request offline.

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local smokePlan = require("../lib/smokeplan")
local deploytarget = require("../lib/deploytarget")
local cliutil = require("../lib/cliutil")
local generate = require("../lib/genregenerate")

local M = {}

local DEFAULT_PACK = "kaiju-egg-raiders"
local POLL_INTERVAL_SECONDS = 5
local POLL_TIMEOUT_SECONDS = 300

local dynamicRequire = require :: any

local function smokeScriptPath(pack: string): string
	return "games/" .. pack .. "/smoke/smoke.luau"
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

--- Loads games/<pack>/smoke/smoke.luau and runs its checks. A pack that does
--- not exist at all is a failure (a mistyped --pack must not report success);
--- an existing pack that just has no smoke script is skipped, not a failure.
local function runLocal(pack: string, fixturePath: string?, context: cliutil.CommandContext?): boolean
	local packDir = (if context and context.packsDir then context.packsDir else "games") .. "/" .. pack
	if not fs.isDir(packDir) then
		stdio.ewrite("Error: unknown game pack '" .. pack .. "' (missing games/" .. pack .. "/)\n")
		return false
	end

	local scriptPath = packDir .. "/smoke/smoke.luau"
	if not fs.isFile(scriptPath) then
		stdio.write("smoke: no smoke script for " .. pack .. "\n")
		return true
	end

	local requireOk, smoke = pcall(function()
		return dynamicRequire("./" .. generate.relative("cli/forge/commands", packDir .. "/smoke/smoke"))
	end)
	if not requireOk then
		stdio.ewrite("smoke: failed to load " .. scriptPath .. ": " .. tostring(smoke) .. "\n")
		return false
	end
	if type(smoke) ~= "table" or type(smoke.run) ~= "function" then
		stdio.ewrite("smoke: " .. scriptPath .. " does not export run()\n")
		return false
	end

	local runOk, checks = pcall(smoke.run, fixturePath)
	if not runOk then
		stdio.ewrite("smoke: smoke script errored: " .. tostring(checks) .. "\n")
		return false
	end
	if type(checks) ~= "table" then
		stdio.ewrite("smoke: smoke script did not return a check list\n")
		return false
	end

	local count = 0
	local failed = 0
	for _, check in checks do
		count += 1
		if check.ok then
			stdio.write("PASS " .. check.name .. "\n")
		else
			failed += 1
			stdio.ewrite("FAIL " .. check.name .. ": " .. tostring(check.detail) .. "\n")
		end
	end

	if failed == 0 and count > 0 then
		stdio.write(string.format("smoke: PASS (%d checks)\n", count))
		return true
	end
	stdio.ewrite("smoke: FAIL\n")
	return false
end

local function stagingIds(pack: string, variables: { [string]: string? }): (number, number, string?)
	local deployPath = "games/" .. pack .. "/deploy.yml"
	if not fs.isFile(deployPath) then
		return 0, 0, "missing " .. deployPath
	end
	local deploy = decodeYaml(deployPath)
	if deploy == nil then
		return 0, 0, "failed to decode " .. deployPath
	end
	local environments = deploy.environments
	local staging = if typeof(environments) == "table" then environments.staging else nil
	if typeof(staging) ~= "table" then
		return 0, 0, "missing environments.staging in " .. deployPath
	end
	-- Literal ids or `${NAME}` environment references; an unset reference reads as
	-- unset target 0, which the --cloud path refuses before any network call.
	local universeId, universeErr = deploytarget.unsettableId(staging.universeId, variables)
	if universeId == nil then
		return 0, 0, "deploy.yml staging.universeId " .. tostring(universeErr)
	end
	local placeId, placeErr = deploytarget.unsettableId(staging.placeId, variables)
	if placeId == nil then
		return 0, 0, "deploy.yml staging.placeId " .. tostring(placeErr)
	end
	return universeId, placeId, nil
end

-- Resolves the returned task path (absolute, root-relative, or bare) to a URL.
local function taskUrl(path: string): string
	if string.sub(path, 1, 4) == "http" then
		return path
	end
	if string.sub(path, 1, 1) == "/" then
		return "https://apis.roblox.com" .. path
	end
	return "https://apis.roblox.com/cloud/v2/" .. path
end

-- Bundles the pack's smoke script into one self-contained source string. A
-- pack that does not exist is a failure via runCloud's caller check below;
-- here only "no smoke script for an existing pack" is treated as a skip.
local function buildBundledBody(pack: string): (string?, string?)
	local scriptPath = smokeScriptPath(pack)
	if not fs.isFile(scriptPath) then
		stdio.write("smoke: no smoke script for " .. pack .. "\n")
		return nil, nil
	end
	return smokePlan.bundle(scriptPath, function(path: string): string?
		if fs.isFile(path) then
			return fs.readFile(path)
		end
		return nil
	end)
end

local function runCloud(pack: string, dryRun: boolean): boolean
	if not fs.isDir("games/" .. pack) then
		stdio.ewrite("Error: unknown game pack '" .. pack .. "' (missing games/" .. pack .. "/)\n")
		return false
	end

	local bundled, bundleErr = buildBundledBody(pack)
	if bundled == nil then
		if bundleErr ~= nil then
			stdio.ewrite("Error: " .. bundleErr .. "\n")
			return false
		end
		return true -- no smoke script: skipped, not a failure
	end

	local universeId, placeId, idErr = stagingIds(pack, process.env)
	if idErr ~= nil then
		stdio.ewrite("Error: " .. idErr .. "\n")
		return false
	end

	if dryRun then
		local url = smokePlan.buildUrl(universeId, placeId)
		local body = smokePlan.buildBody(bundled, smokePlan.DEFAULT_TIMEOUT)
		stdio.write("POST " .. url .. "\n")
		stdio.write(string.sub(body, 1, 400) .. "\n")
		return true
	end

	local apiKey = process.env["ROBLOX_API_KEY"]
	if apiKey == nil or apiKey == "" then
		stdio.ewrite("Error: ROBLOX_API_KEY is not set; cloud smoke needs Open Cloud access\n")
		return false
	end
	local key = apiKey :: string

	local request, requestErr = smokePlan.buildRequest(universeId, placeId, bundled, smokePlan.DEFAULT_TIMEOUT)
	if request == nil then
		stdio.ewrite("Error: " .. (requestErr or "invalid smoke request") .. "\n")
		return false
	end

	local headers: { [string]: string } = {
		["x-api-key"] = key,
		["Content-Type"] = "application/json",
	}
	local response = net.request({
		url = request.url,
		method = "POST",
		headers = headers,
		body = request.body,
	})
	stdio.write(string.format("smoke: HTTP %d %s\n", response.statusCode, response.statusMessage))
	if not response.ok then
		stdio.write(response.body .. "\n")
		return false
	end

	local decodedOk, decoded = pcall(function()
		return serde.decode("json", response.body)
	end)
	if not decodedOk or typeof(decoded) ~= "table" then
		stdio.ewrite("Error: could not decode Luau Execution response\n")
		return false
	end
	local taskPath = decoded.path
	if typeof(taskPath) ~= "string" or taskPath == "" then
		stdio.ewrite("Error: Luau Execution response had no task path\n")
		return false
	end

	local url = taskUrl(taskPath)
	local elapsed = 0
	while elapsed < POLL_TIMEOUT_SECONDS do
		task.wait(POLL_INTERVAL_SECONDS)
		elapsed += POLL_INTERVAL_SECONDS

		local pollHeaders: { [string]: string } = { ["x-api-key"] = key }
		local poll = net.request({
			url = url,
			method = "GET",
			headers = pollHeaders,
		})
		if not poll.ok then
			stdio.write(string.format("smoke: poll HTTP %d %s\n", poll.statusCode, poll.statusMessage))
			return false
		end

		local pollOk, pollBody = pcall(function()
			return serde.decode("json", poll.body)
		end)
		if not pollOk or typeof(pollBody) ~= "table" then
			stdio.ewrite("Error: could not decode Luau Execution poll response\n")
			return false
		end

		local state = pollBody.state
		stdio.write("smoke: task state " .. tostring(state) .. "\n")
		if state == "COMPLETE" then
			return true
		elseif state == "FAILED" or state == "CANCELLED" then
			return false
		end
	end

	stdio.ewrite(string.format("Error: Luau Execution task did not finish within %d seconds\n", POLL_TIMEOUT_SECONDS))
	return false
end

function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local pack = DEFAULT_PACK
	local fixturePath: string? = nil
	local localRun = false
	local cloudRun = false
	local dryRun = false

	local index = 2
	while index <= #args do
		local flag = args[index]
		if flag == "--local" then
			localRun = true
			index += 1
		elseif flag == "--cloud" then
			cloudRun = true
			index += 1
		elseif flag == "--dry-run" then
			dryRun = true
			index += 1
		elseif flag == "--pack" or flag == "--fixture" then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: " .. flag .. " requires a value\n")
				return false
			end
			if flag == "--pack" then
				pack = value
			else
				fixturePath = value
			end
			index += 2
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge smoke\n")
			return false
		end
	end

	if not localRun and not cloudRun then
		localRun = true
	end

	local success = true
	if localRun then
		if not runLocal(pack, fixturePath, context) then
			success = false
		end
	end
	if cloudRun then
		if not runCloud(pack, dryRun) then
			success = false
		end
	end
	return success
end

return M
