--!strict
-- Specs for SmokePlan: request URL, JSON body, unset-id refusal, timeout, and
-- the self-contained smoke bundle uploaded by the cloud path.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local runner = require("./run")
local SmokePlan = require("./smokeplan")

local BUNDLE_ENTRY = "games/kaiju-egg-raiders/smoke/smoke.luau"

local function readSource(path: string): string?
	if fs.isFile(path) then
		return fs.readFile(path)
	end
	return nil
end

local function linesOf(text: string): { string }
	local lines: { string } = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		table.insert(lines, line)
	end
	return lines
end

return {
	["the request targets the Luau Execution task endpoint"] = function()
		local request, err = SmokePlan.buildRequest(123, 456, "print('hi')")
		assert(err == nil, "unexpected refusal: " .. tostring(err))
		local built = request :: SmokePlan.Request
		assert(built.method == "POST", "method is POST")
		assert(
			built.url == "https://apis.roblox.com/cloud/v2/universes/123/places/456/luau-execution-session-tasks",
			"url: " .. built.url
		)
	end,

	["the body carries the script and default timeout as JSON"] = function()
		local body = SmokePlan.buildBody("return 1")
		local decoded = serde.decode("json", body)
		assert(decoded.script == "return 1", "script round-trips through JSON")
		assert(decoded.timeout == "300s", "default timeout is 300s, got " .. tostring(decoded.timeout))
	end,

	["an unset staging place id is refused"] = function()
		local request, err = SmokePlan.buildRequest(123, 0, "return 1")
		assert(request == nil, "an unset place id must not produce a request")
		assert(err == "staging placeId is 0 in deploy.yml", "reason: " .. tostring(err))
	end,

	["an explicit timeout is carried into the body"] = function()
		local request, err = SmokePlan.buildRequest(1, 2, "return 1", "120s")
		assert(err == nil, "unexpected refusal: " .. tostring(err))
		local built = request :: SmokePlan.Request
		local decoded = serde.decode("json", built.body)
		assert(decoded.timeout == "120s", "explicit timeout is preserved, got " .. tostring(decoded.timeout))
	end,

	["the bundle inlines every relative require"] = function()
		local bundle, err = SmokePlan.bundle(BUNDLE_ENTRY, readSource)
		assert(bundle ~= nil, "bundle failed: " .. tostring(err))
		local source = bundle :: string
		assert(string.find(source, 'require("./', 1, true) == nil, 'bundle still has a require("./ call')
		assert(string.find(source, 'require("../', 1, true) == nil, 'bundle still has a require("../ call')
		assert(string.find(source, "__require(", 1, true) ~= nil, "bundle should route requires through __require")
	end,

	["the bundle runs standalone and prints the local smoke PASS lines"] = function()
		local bundle, err = SmokePlan.bundle(BUNDLE_ENTRY, readSource)
		assert(bundle ~= nil, "bundle failed: " .. tostring(err))

		local localResult = runner.exec("lune", { "run", "cli/forge", "smoke", "--local" })
		assert(localResult.ok, "local smoke failed (" .. tostring(localResult.code) .. "): " .. localResult.stderr)
		local expected = linesOf(localResult.stdout)
		assert(#expected > 0, "local smoke printed no PASS lines")

		local tempDir = process.env["TEMP"] or process.env["TMPDIR"] or "/tmp"
		local tempPath = tempDir .. "/forge-smoke-bundle-spec.luau"
		fs.writeFile(tempPath, bundle :: string)

		local result = runner.exec("lune", { "run", tempPath })
		pcall(fs.removeFile, tempPath)
		assert(result.ok, "bundle run failed (" .. tostring(result.code) .. "): " .. result.stderr)

		local actual = linesOf(result.stdout)
		assert(#actual == #expected, "expected " .. #expected .. " lines, got " .. #actual .. ":\n" .. result.stdout)
		for index, line in expected do
			assert(actual[index] == line, "line " .. index .. ": expected " .. line .. ", got " .. actual[index])
		end
	end,
}
