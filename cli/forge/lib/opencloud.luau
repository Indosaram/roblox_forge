--!strict
-- One attempt only. Provider text and credentials never become audit output.
local serde = require("@lune/serde")
local process = require("@lune/process")

local M = {}

-- Bun native fetch owns its 30-second abort; Lune owns a 35-second process
-- watchdog covering startup, stdin and output. Never retry an uncertain POST.
function M.request(request: any): any
	local started, child = pcall(process.create, "bun", { "cli/forge/lib/opencloud-transport.mjs" })
	if not started then
		error("PUBLISH_TRANSPORT_UNSUPPORTED", 0)
	end
	local lifecycle = require("./opencloud-process").exchange(
		child,
		serde.encode("json", { url = request.url, headers = request.headers }) .. "\n" .. request.body
	)
	if not lifecycle.cleaned then
		error({
			code = "PUBLISH_CLEANUP_FAILED",
			residual = lifecycle.residual,
			killFailed = lifecycle.killFailed == true,
			reapFailed = lifecycle.reapFailed == true,
			exitCode = if lifecycle.status then lifecycle.status.code else nil,
		}, 0)
	end
	if lifecycle.expired then
		error("PUBLISH_TIMEOUT_AMBIGUOUS", 0)
	end
	if not lifecycle.status.ok then
		error("PUBLISH_HELPER_NONZERO", 0)
	end
	local ok, response = pcall(function()
		return serde.decode("json", lifecycle.stdout)
	end)
	if not ok or type(response) ~= "table" then
		error("PUBLISH_TRANSPORT_AMBIGUOUS", 0)
	end
	if response.error ~= nil then
		local code = response.error
		if
			code == "PUBLISH_TIMEOUT_AMBIGUOUS"
			or code == "PUBLISH_MALFORMED_REPLY"
			or code == "PUBLISH_TRANSPORT_UNSUPPORTED"
		then
			error(code, 0)
		end
		error("PUBLISH_TRANSPORT_AMBIGUOUS", 0)
	end
	return response
end

function M.credential(
	env: { [string]: string? },
	target: string,
	universeId: number,
	placeId: number?
): (string?, string?)
	if target ~= "staging" and target ~= "production" then
		return nil, "CREDENTIAL_TARGET_INVALID"
	end
	local prefix = "ROBLOX_" .. string.upper(target)
	local key = env[prefix .. "_API_KEY"]
	if key == nil or string.match(key, "^%s*$") then
		return nil, "CREDENTIAL_MISSING"
	end
	local other = if target == "staging" then "ROBLOX_PRODUCTION_API_KEY" else "ROBLOX_STAGING_API_KEY"
	if key == env[other] then
		return nil, "CREDENTIAL_SHARED"
	end
	if
		env[prefix .. "_UNIVERSE_ID"] ~= string.format("%.0f", universeId)
		or (placeId ~= nil and env[prefix .. "_PLACE_ID"] ~= string.format("%.0f", placeId))
	then
		return nil, "CREDENTIAL_TARGET_MISMATCH"
	end
	return key, nil
end

export type Result = {
	ok: boolean,
	code: string,
	status: number?,
	version: number?,
	residual: boolean?,
	killFailed: boolean?,
	reapFailed: boolean?,
	exitCode: number?,
}

function M.publish(request: () -> any, kind: "place" | "message"): Result
	local sent, response = pcall(request)
	if not sent then
		if type(response) == "table" and response.code == "PUBLISH_CLEANUP_FAILED" then
			return {
				ok = false,
				code = response.code,
				residual = response.residual,
				killFailed = response.killFailed,
				reapFailed = response.reapFailed,
				exitCode = response.exitCode,
			}
		end
		if
			response == "PUBLISH_TRANSPORT_UNSUPPORTED"
			or response == "PUBLISH_MALFORMED_REPLY"
			or response == "PUBLISH_CLEANUP_FAILED"
			or response == "PUBLISH_HELPER_NONZERO"
		then
			return { ok = false, code = response }
		end
		local text = string.lower(tostring(response))
		local timeout = string.find(text, "timeout", 1, true) or string.find(text, "timed out", 1, true)
		return { ok = false, code = if timeout then "PUBLISH_TIMEOUT_AMBIGUOUS" else "PUBLISH_TRANSPORT_AMBIGUOUS" }
	end
	if
		type(response) ~= "table"
		or type(response.statusCode) ~= "number"
		or response.statusCode % 1 ~= 0
		or response.statusCode < 100
		or response.statusCode > 599
	then
		return { ok = false, code = "PUBLISH_MALFORMED_REPLY" }
	end
	local status = response.statusCode
	if status == 401 or status == 403 then
		return { ok = false, code = "PUBLISH_PERMISSION_DENIED", status = status }
	elseif status == 429 then
		return { ok = false, code = "PUBLISH_RATE_LIMITED", status = status }
	elseif status == 408 or status == 504 then
		return { ok = false, code = "PUBLISH_TIMEOUT_AMBIGUOUS", status = status }
	elseif status < 200 or status >= 300 then
		return { ok = false, code = "PUBLISH_HTTP_ERROR", status = status }
	end
	if response.ok ~= true or type(response.body) ~= "string" then
		return { ok = false, code = "PUBLISH_MALFORMED_REPLY", status = status }
	end
	local decodedOk, decoded = pcall(function()
		return serde.decode("json", response.body)
	end)
	if
		not decodedOk
		or type(decoded) ~= "table"
		or string.sub(string.match(response.body, "^%s*(.*)") or "", 1, 1) ~= "{"
	then
		return { ok = false, code = "PUBLISH_MALFORMED_REPLY", status = status }
	end
	if kind == "place" then
		local version = decoded.versionNumber
		if type(version) ~= "number" or version <= 0 or version >= math.huge or version % 1 ~= 0 then
			return { ok = false, code = "PUBLISH_MALFORMED_REPLY", status = status }
		end
		return { ok = true, code = "PUBLISH_ACCEPTED", status = status, version = version }
	end
	if next(decoded) ~= nil then
		return { ok = false, code = "PUBLISH_MALFORMED_REPLY", status = status }
	end
	return { ok = true, code = "PUBLISH_ACCEPTED", status = status }
end

return M
