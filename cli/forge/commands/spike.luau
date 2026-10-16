--!strict
-- `forge spike [--players N] [--seed S] [--out <path>]`: QA-SPIKE-01 layer 1.
-- Runs the spikesim join-spike simulation (simulated clock, no sleeps, no
-- network), writes its schemaVersion 1 JSON report (default
-- .omo/evidence/robango/spike-64.json, gitignored) and exits 1 when any gate
-- fails (p95 over target, lost players, overfull islands, split-brain lease,
-- leaked internal text).

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local cliutil = require("../lib/cliutil")
local spikesim = require("../lib/spikesim")

local M = {}

M.DEFAULT_OUT = ".omo/evidence/robango/spike-64.json"
local MAX_PLAYERS = 100000

local function usage()
	stdio.ewrite("Usage: lune run cli/forge spike [--players N] [--seed S] [--out <path>]\n")
end

local function ensureParentDir(path: string)
	local parent = string.match(path, "^(.*)/[^/]+$")
	if parent ~= nil and parent ~= "" and not fs.isDir(parent) then
		fs.writeDir(parent)
	end
end

function M.run(args: { string }): boolean
	local options: spikesim.Options = {}
	local out = M.DEFAULT_OUT
	local seen: { [string]: boolean } = {}
	local index = 2
	while index <= #args do
		local flag = args[index]
		local value = args[index + 1]
		if flag ~= "--players" and flag ~= "--seed" and flag ~= "--out" then
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge spike\n")
			usage()
			return false
		end
		if seen[flag] then
			stdio.ewrite("Error: duplicate flag " .. flag .. "\n")
			return false
		end
		seen[flag] = true
		if value == nil or value == "" or string.sub(value, 1, 2) == "--" then
			stdio.ewrite("Error: " .. flag .. " requires a value\n")
			return false
		end
		if flag == "--out" then
			out = value
		else
			local number, reason = cliutil.parseFiniteInt(value)
			if number == nil then
				stdio.ewrite("Error: " .. flag .. " requires an integer: " .. tostring(reason) .. "\n")
				return false
			end
			if flag == "--players" then
				if number < 1 or number > MAX_PLAYERS then
					stdio.ewrite(string.format("Error: --players must be in 1..%d\n", MAX_PLAYERS))
					return false
				end
				options.players = number
			else
				if number < 0 then
					stdio.ewrite("Error: --seed must be >= 0\n")
					return false
				end
				options.seed = number
			end
		end
		index += 2
	end

	local report = spikesim.run(options)
	ensureParentDir(out)
	fs.writeFile(out, serde.encode("json", report, true) .. "\n")
	local line = string.format(
		"spike: %s players=%d p50=%ss p95=%ss (target %ss) max=%ss lost=%d overfull=%d leaks=%d -> %s\n",
		if report.ok then "PASS" else "FAIL",
		report.players,
		tostring(report.wait.p50),
		tostring(report.wait.p95),
		tostring(report.targetP95),
		tostring(report.wait.max),
		report.lost,
		report.overfull,
		report.leaks,
		out
	)
	if report.ok then
		stdio.write(line)
	else
		stdio.ewrite(line .. "failed: " .. table.concat(report.failures, ",") .. "\n")
	end
	return report.ok
end

return M
