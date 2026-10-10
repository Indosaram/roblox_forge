--!strict
local cloud = require("./opencloud")
local serde = require("@lune/serde")

return {
	["unavailable transport classification does not claim a request occurred"] = function()
		local result = cloud.publish(function()
			error("PUBLISH_TRANSPORT_UNSUPPORTED", 0)
		end, "place")
		assert(
			not result.ok and result.code == "PUBLISH_TRANSPORT_UNSUPPORTED",
			'not result.ok and result.code == "PUBLISH_TRANSPORT_UNSUPPORTED"'
		)
		assert(result.status == nil and result.version == nil, "result.status == nil and result.version == nil")
	end,
	["credentials bind environment universe and place without generic fallback"] = function()
		local env: { [string]: string? } = { ROBLOX_API_KEY = "generic", ROBLOX_PRODUCTION_API_KEY = "production" }
		local key, code = cloud.credential(env, "staging", 42, 7)
		assert(key == nil and code == "CREDENTIAL_MISSING", 'key == nil and code == "CREDENTIAL_MISSING"')
		local scoped: { [string]: string? } = {
			ROBLOX_STAGING_API_KEY = "staging",
			ROBLOX_PRODUCTION_API_KEY = "production",
			ROBLOX_STAGING_UNIVERSE_ID = "42",
			ROBLOX_STAGING_PLACE_ID = "7",
		}
		assert(
			cloud.credential(scoped, "staging", 42, 7) == "staging",
			'cloud.credential(scoped, "staging", 42, 7) == "staging"'
		)
		assert(cloud.credential(scoped, "staging", 43, 7) == nil, 'cloud.credential(scoped, "staging", 43, 7) == nil')
		assert(cloud.credential(scoped, "staging", 42, 8) == nil, 'cloud.credential(scoped, "staging", 42, 8) == nil')
		scoped.ROBLOX_PRODUCTION_API_KEY = "staging"
		local sharedKey, sharedCode = cloud.credential(scoped, "staging", 42, 7)
		assert(
			sharedKey == nil and sharedCode == "CREDENTIAL_SHARED",
			'sharedKey == nil and sharedCode == "CREDENTIAL_SHARED"'
		)
	end,
	["publish failures are distinct sanitized and attempted exactly once"] = function()
		for _, case in
			{
				{ status = 401, code = "PUBLISH_PERMISSION_DENIED" },
				{ status = 403, code = "PUBLISH_PERMISSION_DENIED" },
				{ status = 429, code = "PUBLISH_RATE_LIMITED" },
				{ status = 504, code = "PUBLISH_TIMEOUT_AMBIGUOUS" },
				{ status = 500, code = "PUBLISH_HTTP_ERROR" },
				{ status = 200, code = "PUBLISH_MALFORMED_REPLY" },
			}
		do
			local calls = 0
			local result = cloud.publish(function()
				calls += 1
				return { statusCode = case.status, ok = case.status == 200, body = "secret-provider-body" }
			end, "place")
			assert(
				not result.ok and result.code == case.code and calls == 1,
				"not result.ok and result.code == case.code and calls == 1"
			)
			assert(
				not string.find(serde.encode("json", result), "secret", 1, true),
				"provider reply never leaks the secret body"
			)
		end
		for _, message in { "timeout secret", "connection reset secret" } do
			local calls = 0
			local result = cloud.publish(function()
				calls += 1
				error(message)
			end, "message")
			assert(calls == 1 and not result.ok, "calls == 1 and not result.ok")
			assert(
				result.code
					== (
						if message == "timeout secret"
							then "PUBLISH_TIMEOUT_AMBIGUOUS"
							else "PUBLISH_TRANSPORT_AMBIGUOUS"
					),
				'result.code == (if message == "timeout secret" then "PUBLISH_TIMEOUT_AMBIGUOUS" else "PUBLISH_TRANSPORT_AMBIGUOUS")'
			)
			assert(
				not string.find(serde.encode("json", result), "secret", 1, true),
				"provider error message never leaks the secret body"
			)
		end
	end,
	["publish validates success schemas and never trusts ok alone"] = function()
		for _, body in { "", "[]", "null", "true", "{}", '{"versionNumber":0}', '{"versionNumber":"1"}' } do
			assert(not cloud.publish(function()
				return { statusCode = 200, ok = true, body = body }
			end, "place").ok, "invalid success payload must be rejected")
		end
		local accepted = cloud.publish(function()
			return { statusCode = 200, ok = true, body = '{"versionNumber":17,"ignored":"secret"}' }
		end, "place")
		assert(accepted.ok and accepted.version == 17, "accepted.ok and accepted.version == 17")
		assert(
			not string.find(serde.encode("json", accepted), "secret", 1, true),
			'not string.find(serde.encode("json", accepted), "secret", 1, true)'
		)
		assert(
			cloud.publish(function()
				return { statusCode = 200, ok = true, body = "{}" }
			end, "message").ok,
			"valid success payload must be accepted"
		)
		for _, body in { "[]", '{"error":"secret"}', "" } do
			assert(not cloud.publish(function()
				return { statusCode = 200, ok = true, body = body }
			end, "message").ok, "error body without a version must be rejected")
		end
	end,
}
