--!strict
local fs = require("@lune/fs")
local liveops = require("./liveops")

return {
	["liveops caller isolates credentials and makes one publish attempt per invocation"] = function()
		local pack = "fixture-task-fifteen-operations"
		local directory = "games/" .. pack
		assert(not fs.isDir(directory) and not fs.isFile(directory), "fixture path already owned")
		local ok, reason = xpcall(function()
			fs.writeDir(directory)
			fs.writeFile(
				directory .. "/deploy.yml",
				"environments:\n  staging:\n    universeId: 42\n  production:\n    universeId: 99\n"
			)
			fs.writeFile(directory .. "/liveops.yml", "events:\n  - id: fixture\n    kind: fixture\n    data: {}\n")
			local args = { "liveops", "push", "--pack", pack, "--event", "fixture" }
			local calls = 0
			local ports: { env: { [string]: string? }?, request: ((any) -> any)? } = {
				env = { ROBLOX_API_KEY = "generic" } :: { [string]: string? },
				request = function(_request: any): any
					calls += 1
					error("unexpected request")
				end,
			}
			assert(not liveops.run(args, ports) and calls == 0, "not liveops.run(args, ports) and calls == 0")
			assert(liveops.run({ "liveops", "push", "--pack", pack, "--event", "fixture", "--dry-run" }, ports))
			assert(calls == 0, "calls == 0")
			local env: { [string]: string? } = { ROBLOX_STAGING_API_KEY = "staging", ROBLOX_STAGING_UNIVERSE_ID = "42" }
			for _, status in { 200, 401, 403, 429, 500, 504 } do
				local before = calls
				local accepted = liveops.run(args, {
					env = env,
					request = function(request: any)
						calls += 1
						assert(
							request.url == "https://apis.roblox.com/cloud/v2/universes/42/:publishMessage",
							'request.url == "https://apis.roblox.com/cloud/v2/universes/42/:publishMessage"'
						)
						assert(request.headers["x-api-key"] == "staging", 'request.headers["x-api-key"] == "staging"')
						return { statusCode = status, ok = status == 200, body = "{}" }
					end,
				})
				assert(
					accepted == (status == 200) and calls == before + 1,
					"accepted == (status == 200) and calls == before + 1"
				)
			end
			for _, reply in { "malformed", "timeout" } do
				local before = calls
				assert(not liveops.run(args, {
					env = env,
					request = function(_request: any): any
						calls += 1
						if reply == "timeout" then
							error("timeout secret")
						end
						return { statusCode = 200, ok = true, body = "secret" }
					end,
				}), "ambiguous success reply must fail closed")
				assert(calls == before + 1, "calls == before + 1")
			end
		end, debug.traceback)
		local cleaned, cleanupError = pcall(function()
			if fs.isDir(directory) then
				fs.removeDir(directory)
			end
		end)
		assert(cleaned, tostring(cleanupError))
		assert(ok, tostring(reason))
	end,
}
