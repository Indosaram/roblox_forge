--!strict
-- `forge build [--all | --pack <slug> | --project <path>] [--packs-root <dir>] [--env staging|production]`
--
-- Every selector resolves through lib/buildtargets, so build and the default
-- check verify exactly the same target matrix. With no selector this builds the
-- default pack to build/kaiju-egg-raiders.rbxl, byte-for-byte the same output
-- the old fixed-path command produced.
--
-- Each target is built and inspected independently: one failing target never
-- stops the others, and the command's exit code reports the aggregate.

local process = require("@lune/process")
local stdio = require("@lune/stdio")

local buildtargets = require("../lib/buildtargets")

local M = {}

export type BuildResult = {
	ok: boolean,
	output: string,
	results: { buildtargets.TargetResult },
}

local function failure(lines: { string }): BuildResult
	return { ok = false, output = table.concat(lines, "\n"), results = {} }
end

--- Runs the build matrix selected by `args` (the raw process args; index 1 is
--- the `build` verb itself). Falls back to `process.args` so the shared
--- dispatcher's argument-less `run()` call still reaches every selector.
function M.run(args: { string }?): BuildResult
	local argv = args or process.args
	-- `--env <staging|production>` (with an explicit --pack) embeds that
	-- environment's deploy.yml role and product maps before the identity hash.
	local environment: string? = nil
	local selectorArgs: { string } = {}
	local index = 1
	while index <= #argv do
		if argv[index] == "--env" and index >= 2 then
			local value = argv[index + 1]
			if environment ~= nil or (value ~= "staging" and value ~= "production") then
				return failure({ "build: --env requires exactly one of staging|production" })
			end
			environment = value
			index += 2
		else
			table.insert(selectorArgs, argv[index])
			index += 1
		end
	end
	local selection, selectorErr = buildtargets.parseSelectors(selectorArgs, 2)
	if selection == nil then
		return failure({ "build: " .. tostring(selectorErr) })
	end
	if environment ~= nil and selection.mode ~= "pack" then
		return failure({ "build: --env requires --pack <slug>" })
	end

	local targets, resolveErrors = buildtargets.resolveTargets(selection, "single")
	local lines: { string } = {}
	for _, err in resolveErrors do
		table.insert(lines, "build: " .. err)
	end

	local results = buildtargets.runTargets(targets, environment)
	local ok = #resolveErrors == 0
	for _, result in results do
		for _, log in result.logs do
			table.insert(lines, log)
		end
		table.insert(lines, buildtargets.formatBuild(result))
		table.insert(lines, buildtargets.formatInspect(result))
		for _, err in result.errors do
			table.insert(lines, "ERROR: " .. err)
		end
		if not result.ok then
			ok = false
		end
	end

	return { ok = ok, output = table.concat(lines, "\n"), results = results }
end

--- CLI entry point: prints the matrix and reports success.
function M.main(args: { string }): boolean
	local res = M.run(args)
	if res.output ~= "" then
		stdio.write(res.output .. "\n")
	end
	return res.ok
end

return M
