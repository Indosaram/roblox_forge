--!strict
-- `forge report [--pack <slug>] [--events <path>] [--out <path>]`:
-- read a JSON-lines analytics log, summarize the weekly liveops funnel,
-- tutorial completion rate and Robux revenue, and write the markdown report to
-- reports/<pack>-weekly-<YYYY-MM-DD>.md.
--
-- `forge report --all [--out <path>]` instead summarizes every games/<pack>/
-- directory into reports/dashboard-<YYYY-MM-DD>.md.
--
-- Default event log: games/<pack>/analytics/events.jsonl. Nothing here touches
-- the network, so the command is safe to run and test offline.

local datetime = require("@lune/datetime")
local fs = require("@lune/fs")
local stdio = require("@lune/stdio")

local report = require("../lib/report")

local M = {}

local DEFAULT_PACK = "kaiju-egg-raiders"
local FIXTURE_PATH = "cli/forge/fixtures/events-sample.jsonl"

local function ensureDir(path: string)
	if not fs.isDir(path) then
		fs.writeDir(path)
	end
end

-- F11: `--out` may point outside reports/ entirely; fs.writeFile throws on a
-- missing parent directory, so it must be created first.
local function ensureParentDir(path: string)
	local parent = string.match(path, "^(.*)/[^/]+$")
	if parent ~= nil and parent ~= "" then
		ensureDir(parent)
	end
end

--- Reads a pack's analytics log, falling back to the shared fixture for the
--- default pack (and an empty log for any other pack without analytics).
local function eventsFor(pack: string): ({ report.Event }?, string?)
	local source = "games/" .. pack .. "/analytics/events.jsonl"
	if not fs.isFile(source) then
		if pack == DEFAULT_PACK and fs.isFile(FIXTURE_PATH) then
			source = FIXTURE_PATH
		else
			return {}, nil
		end
	end
	local parseOk, eventsOrError = pcall(report.parse, fs.readFile(source))
	if not parseOk then
		return nil, tostring(eventsOrError)
	end
	return eventsOrError, nil
end

--- Summarizes every games/<pack>/ directory into one dashboard row each.
local function runDashboard(out: string?): boolean
	local packs: { string } = {}
	for _, entry in fs.readDir("games") do
		if fs.isDir("games/" .. entry) then
			table.insert(packs, entry)
		end
	end
	table.sort(packs)

	local rows: { report.DashboardRow } = {}
	for _, pack in packs do
		local events, eventsErr = eventsFor(pack)
		if events == nil then
			stdio.ewrite("Error: " .. tostring(eventsErr) .. "\n")
			return false
		end
		table.insert(rows, report.dashboardRow(pack, report.summarize(events)))
	end

	local date = datetime.now():formatUniversalTime("%Y-%m-%d")
	local outPath = out or ("reports/dashboard-" .. date .. ".md")
	ensureParentDir(outPath)
	fs.writeFile(outPath, report.renderDashboard(rows, date))
	stdio.write(string.format("report: dashboard %d packs -> %s\n", #packs, outPath))
	return true
end

function M.run(args: { string }): boolean
	local pack = DEFAULT_PACK
	local eventsPath: string? = nil
	local out: string? = nil
	local all = false
	local index = 2
	while index <= #args do
		local flag = args[index]
		if flag == "--all" then
			all = true
			index += 1
		elseif flag == "--pack" or flag == "--events" or flag == "--out" then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: " .. flag .. " requires a value\n")
				return false
			end
			if flag == "--pack" then
				pack = value
			elseif flag == "--events" then
				eventsPath = value
			else
				out = value
			end
			index += 2
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge report\n")
			return false
		end
	end

	if all then
		return runDashboard(out)
	end

	if not fs.isDir("games/" .. pack) then
		stdio.ewrite("Error: unknown game pack '" .. pack .. "' (missing games/" .. pack .. "/)\n")
		return false
	end

	local source = eventsPath or ("games/" .. pack .. "/analytics/events.jsonl")
	if not fs.isFile(source) then
		stdio.ewrite("Error: events log not found: " .. source .. "\n")
		return false
	end

	local parseOk, eventsOrError = pcall(report.parse, fs.readFile(source))
	if not parseOk then
		stdio.ewrite("Error: " .. tostring(eventsOrError) .. "\n")
		return false
	end
	local events = eventsOrError

	local summary = report.summarize(events)
	local date = datetime.now():formatUniversalTime("%Y-%m-%d")
	local outPath = out or ("reports/" .. pack .. "-weekly-" .. date .. ".md")
	ensureParentDir(outPath)
	fs.writeFile(outPath, report.render(summary, pack, date))

	stdio.write(string.format("report: %d events -> %s\n", #events, outPath))
	stdio.write(
		string.format(
			"report: tutorial %.1f%%, robux R$ %.0f, funnel %d->%d->%d->%d\n",
			summary.tutorialCompletionRate * 100,
			summary.robuxRevenue,
			summary.funnel[1].count,
			summary.funnel[2].count,
			summary.funnel[3].count,
			summary.funnel[4].count
		)
	)
	return true
end

return M
