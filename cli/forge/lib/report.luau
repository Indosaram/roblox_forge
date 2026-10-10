--!strict
-- Report: pure logic behind `forge report`. Parses a JSON-lines analytics log
-- (one {"name":..., "fields":{...}} per line), counts events against the core
-- analytics registry, computes the tutorial completion rate, Robux revenue and
-- the purchase funnel, and renders a weekly markdown report. No IO happens
-- here; the command owns reading the log and writing the report file.

local serde = require("@lune/serde")

local Events = require("../../../core/infra/analytics/Events")

local Report = {}

export type Event = {
	name: string,
	fields: { [string]: any },
}

export type FunnelStep = {
	step: string,
	count: number,
	conversion: number,
}

export type Summary = {
	counts: { [string]: number },
	tutorialCompletionRate: number,
	robuxRevenue: number,
	funnel: { FunnelStep },
}

export type DashboardRow = {
	pack: string,
	players: number,
	tutorialCompletionRate: number,
	payers: number,
	robuxRevenue: number,
}

local FUNNEL = { "session_start", "egg_purchase", "egg_hatch", "robux_purchase" }

--- Parses JSON lines into events. Blank lines are skipped; a malformed or
--- nameless line raises, so the caller reports it instead of under-counting.
function Report.parse(text: string): { Event }
	local events: { Event } = {}
	local lines = string.split(text, "\n")
	for index, line in lines do
		local trimmed = string.match(line, "^%s*(.-)%s*$") or line
		if trimmed ~= "" then
			local ok, decoded = pcall(function()
				return serde.decode("json", trimmed)
			end)
			if not ok then
				error(string.format("invalid events JSON on line %d", index))
			end
			if typeof(decoded) ~= "table" or typeof(decoded.name) ~= "string" then
				error(string.format("invalid events JSON on line %d: expected an object with a string name", index))
			end
			local fields = decoded.fields
			table.insert(events, {
				name = decoded.name,
				fields = if typeof(fields) == "table" then fields else {},
			})
		end
	end
	return events
end

--- Counts every registered event name (all 12 keys are present, defaulting to
--- 0); names outside the registry are ignored.
function Report.counts(events: { Event }): { [string]: number }
	local counts: { [string]: number } = {}
	for _, name in Events.NAMES do
		counts[name] = 0
	end
	for _, event in events do
		if counts[event.name] ~= nil then
			counts[event.name] += 1
		end
	end
	return counts
end

--- tutorial_complete / session_start, 0 when there were no sessions.
function Report.tutorialCompletionRate(counts: { [string]: number }): number
	local starts = counts.session_start or 0
	if starts == 0 then
		return 0
	end
	return (counts.tutorial_complete or 0) / starts
end

--- Sum of robux_purchase.fields.price across the log.
function Report.robuxRevenue(events: { Event }): number
	local total = 0
	for _, event in events do
		if event.name == "robux_purchase" then
			local price = event.fields.price
			if typeof(price) == "number" then
				total += price
			end
		end
	end
	return total
end

--- session_start -> egg_purchase -> egg_hatch -> robux_purchase, each step with
--- its conversion against session_start.
function Report.funnel(counts: { [string]: number }): { FunnelStep }
	local steps: { FunnelStep } = {}
	local base = counts[FUNNEL[1]] or 0
	for _, name in FUNNEL do
		local count = counts[name] or 0
		table.insert(steps, {
			step = name,
			count = count,
			conversion = if base == 0 then 0 else count / base,
		})
	end
	return steps
end

function Report.summarize(events: { Event }): Summary
	local counts = Report.counts(events)
	return {
		counts = counts,
		tutorialCompletionRate = Report.tutorialCompletionRate(counts),
		robuxRevenue = Report.robuxRevenue(events),
		funnel = Report.funnel(counts),
	}
end

--- Renders the weekly report: event counts, purchase funnel, and monetization.
function Report.render(summary: Summary, pack: string, date: string): string
	local lines: { string } = {
		"# " .. pack .. " Weekly Liveops Report",
		"",
		"Date: " .. date,
		"",
		"## Event Counts",
		"",
		"| Event | Count |",
		"| --- | ---: |",
	}
	for _, name in Events.NAMES do
		table.insert(lines, string.format("| %s | %d |", name, summary.counts[name] or 0))
	end

	table.insert(lines, "")
	table.insert(lines, "## Purchase Funnel")
	table.insert(lines, "")
	table.insert(lines, "| Step | Count | Conversion |")
	table.insert(lines, "| --- | ---: | ---: |")
	for _, step in summary.funnel do
		table.insert(lines, string.format("| %s | %d | %.1f%% |", step.step, step.count, step.conversion * 100))
	end

	table.insert(lines, "")
	table.insert(lines, "## Monetization")
	table.insert(lines, "")
	table.insert(lines, string.format("- Tutorial completion rate: %.1f%%", summary.tutorialCompletionRate * 100))
	table.insert(lines, string.format("- Robux revenue: R$ %.0f", summary.robuxRevenue))
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

--- Renders the multi-game dashboard: one row per pack with players
--- (session_start), tutorial completion, payers (robux_purchase), and revenue.
function Report.renderDashboard(rows: { DashboardRow }, date: string): string
	local lines: { string } = {
		"# LiveOps Dashboard",
		"",
		"Date: " .. date,
		"",
		"| Pack | Players | Tutorial Completion | Payers | Robux Revenue |",
		"| --- | ---: | ---: | ---: | ---: |",
	}
	for _, row in rows do
		table.insert(
			lines,
			string.format(
				"| %s | %d | %.1f%% | %d | R$ %.0f |",
				row.pack,
				row.players,
				row.tutorialCompletionRate * 100,
				row.payers,
				row.robuxRevenue
			)
		)
	end
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

--- Summarizes one pack into a dashboard row.
function Report.dashboardRow(pack: string, summary: Summary): DashboardRow
	return {
		pack = pack,
		players = summary.counts.session_start or 0,
		tutorialCompletionRate = summary.tutorialCompletionRate,
		payers = summary.counts.robux_purchase or 0,
		robuxRevenue = summary.robuxRevenue,
	}
end

return Report
