--!strict
-- `forge liveops push --pack <slug> --event <id> [--dry-run]`:
-- publish a LiveOps event to a pack's staging universe over Open Cloud.
-- The message is the same v1 JSON envelope the runtime Broadcast module speaks
-- (from = "forge-cli"), so live servers decode it exactly like a peer server.
--
-- `--dry-run` prints the POST target and payload digest without any network call, even
-- when the staging universe id is still unset (0).

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local Broadcast = require("../../../core/infra/liveops/Broadcast")
local liveopsplan = require("../lib/liveopsplan")
local opencloud = require("../lib/opencloud")
local cliutil = require("../lib/cliutil")

local M = {}

local DEFAULT_PACK = "kaiju-egg-raiders"
local TOPIC = "forge-liveops"

local function decodeYaml(path: string): any
	local ok, decoded = pcall(function()
		return serde.decode("yaml", fs.readFile(path))
	end)
	if not ok or typeof(decoded) ~= "table" then
		return nil
	end
	return decoded
end

local function stagingUniverseId(pack: string): (number?, string?)
	local deployPath = "games/" .. pack .. "/deploy.yml"
	if not fs.isFile(deployPath) then
		return nil, "missing " .. deployPath
	end
	local deploy = decodeYaml(deployPath)
	if deploy == nil then
		return nil, "failed to decode " .. deployPath
	end
	local environments: any = deploy.environments
	local staging: any = nil
	if typeof(environments) == "table" then
		staging = environments.staging
	end
	local universeId: any = nil
	if typeof(staging) == "table" then
		universeId = staging.universeId
	end
	if typeof(universeId) ~= "number" then
		return nil, "deploy.yml staging.universeId is missing"
	end
	if universeId < 0 or universeId >= math.huge or universeId % 1 ~= 0 then
		return nil, "deploy.yml staging.universeId must be a finite nonnegative integer"
	end
	local production = environments.production
	if type(production) == "table" and universeId > 0 and production.universeId == universeId then
		return nil, "TARGET_ENVIRONMENT_OVERLAP"
	end
	return universeId, nil
end

local function findEvent(pack: string, eventId: string): ({ [string]: any }?, string?)
	local path = "games/" .. pack .. "/liveops.yml"
	if not fs.isFile(path) then
		return nil, "missing " .. path
	end
	local liveops = decodeYaml(path)
	if liveops == nil then
		return nil, "failed to decode " .. path
	end
	local events: any = liveops.events
	if typeof(events) ~= "table" then
		return nil, path .. " has no events list"
	end
	for _, entry in events do
		if typeof(entry) == "table" and entry.id == eventId then
			return entry, nil
		end
	end
	return nil, "event '" .. eventId .. "' not found in " .. path
end

function M.run(args: { string }, ports: { env: { [string]: string? }?, request: ((net.FetchParams) -> any)? }?): boolean
	if args[2] ~= "push" then
		stdio.ewrite("Error: forge liveops requires the 'push' subcommand\n")
		return false
	end

	local pack = DEFAULT_PACK
	local eventId: string? = nil
	local dryRun = false
	local index = 3
	while index <= #args do
		local flag = args[index]
		if flag == "--dry-run" then
			dryRun = true
			index += 1
		elseif flag == "--pack" or flag == "--event" then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: " .. flag .. " requires a value\n")
				return false
			end
			if flag == "--pack" then
				pack = value
			else
				eventId = value
			end
			index += 2
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge liveops push\n")
			return false
		end
	end

	if not cliutil.isValidKey(pack) then
		stdio.ewrite("Error: invalid pack slug\n")
		return false
	end
	if eventId == nil then
		stdio.ewrite("Error: forge liveops push requires --event <id>\n")
		return false
	end

	local universeId, universeErr = stagingUniverseId(pack)
	if universeId == nil then
		stdio.ewrite("Error: " .. tostring(universeErr) .. "\n")
		return false
	end
	local event, eventErr = findEvent(pack, eventId)
	if event == nil then
		stdio.ewrite("Error: " .. tostring(eventErr) .. "\n")
		return false
	end

	local kind: any = event.kind
	local data: any = event.data
	if typeof(kind) ~= "string" or typeof(data) ~= "table" then
		stdio.ewrite("Error: event '" .. eventId .. "' needs a string kind and a data table\n")
		return false
	end

	local message = Broadcast.encodeEnvelope(kind, "forge-cli", data)

	if dryRun then
		if universeId == 0 then
			stdio.write("universeId unset (0)\n")
		end
		stdio.write("POST " .. liveopsplan.publishUrl(universeId) .. "\n")
		stdio.write(serde.encode("json", {
			topic = TOPIC,
			messageBytes = #message,
			messageSha256 = serde.hash("sha256", message),
		}) .. "\n")
		return true
	end

	if universeId == 0 then
		stdio.ewrite("Error: staging universeId is 0 in deploy.yml\n")
		return false
	end

	local plan, planErr = liveopsplan.buildPublish(universeId, TOPIC, message)
	if plan == nil then
		stdio.ewrite("Error: " .. tostring(planErr) .. "\n")
		return false
	end
	local publish = plan :: liveopsplan.Publish
	local apiKey, credentialError =
		opencloud.credential(if ports and ports.env then ports.env else process.env, "staging", universeId, nil)
	if apiKey == nil then
		stdio.ewrite("liveops: " .. tostring(credentialError) .. "\n")
		return false
	end

	local headers: { [string]: string } = {
		["x-api-key"] = apiKey,
		["content-type"] = "application/json",
	}
	local response = opencloud.publish(function()
		local request: (net.FetchParams) -> any = if ports and ports.request then ports.request else opencloud.request
		return request({
			url = publish.url,
			method = "POST",
			headers = headers,
			body = publish.body,
		})
	end, "message")
	stdio.write(
		"liveops: " .. response.code .. (if response.status then " HTTP " .. tostring(response.status) else "") .. "\n"
	)
	if not response.ok then
		return false
	end
	stdio.write(
		string.format(
			"liveops: accepted message sha256=%s for universe %d\n",
			serde.hash("sha256", message),
			universeId
		)
	)
	return true
end

return M
