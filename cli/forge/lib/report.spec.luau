--!strict
-- Specs for report: event counts against the analytics registry, tutorial
-- completion rate, Robux revenue, the purchase funnel, and report headings.
-- No network access.

local Events = require("../../../core/infra/analytics/Events")
local report = require("./report")

local SAMPLE = table.concat({
	'{"name":"session_start","fields":{}}',
	'{"name":"session_start","fields":{}}',
	'{"name":"session_start","fields":{}}',
	'{"name":"session_start","fields":{}}',
	'{"name":"tutorial_complete","fields":{}}',
	'{"name":"tutorial_complete","fields":{}}',
	'{"name":"egg_purchase","fields":{"eggId":"basic","price":100}}',
	'{"name":"egg_purchase","fields":{"eggId":"basic","price":100}}',
	'{"name":"egg_purchase","fields":{"eggId":"rare","price":500}}',
	'{"name":"egg_hatch","fields":{"eggId":"basic","kaijuId":"k1","rarity":"common"}}',
	'{"name":"egg_hatch","fields":{"eggId":"rare","kaijuId":"k2","rarity":"epic"}}',
	'{"name":"robux_purchase","fields":{"productKey":"gems_small","price":99}}',
	'{"name":"robux_purchase","fields":{"productKey":"gems_large","price":499}}',
	'{"name":"kaiju_merge","fields":{"fromKaijuId":"k1","toKaijuId":"k2"}}',
	'{"name":"not_a_real_event","fields":{}}',
	"",
}, "\n")

local function contains(haystack: string, needle: string): boolean
	return string.find(haystack, needle, 1, true) ~= nil
end

return {
	["report errors and rendered aggregates omit raw event secrets"] = function()
		local ok, reason = pcall(report.parse, '{"name":"secret-value", broken')
		assert(
			not ok and not contains(tostring(reason), "secret-value"),
			'not ok and not contains(tostring(reason), "secret-value")'
		)
		local summary = report.summarize(report.parse('{"name":"session_start","fields":{"token":"secret-value"}}'))
		assert(summary.counts.session_start == 1, "summary.counts.session_start == 1")
		assert(
			not contains(report.render(summary, "pack", "2026-10-04"), "secret-value"),
			'not contains(report.render(summary, "pack", "2026-10-04"), "secret-value")'
		)
		assert(
			not contains(report.renderDashboard({ report.dashboardRow("pack", summary) }, "2026-10-04"), "secret-value"),
			'not contains(report.renderDashboard({ report.dashboardRow("pack", summary) }, "2026-10-04"), "secret-value")'
		)
	end,
	["parse reads one event per JSON line"] = function()
		local events = report.parse(SAMPLE)
		assert(#events == 15, "15 non-blank lines parse, got " .. #events)
		assert(events[1].name == "session_start", "first event is a session_start")
		assert(events[14].name == "kaiju_merge", "kaiju_merge is the 14th event")
		assert(events[15].name == "not_a_real_event", "unknown names still parse")
		assert(events[8].fields.eggId == "basic", "fields are preserved")
	end,

	["parse rejects a malformed line instead of under-counting"] = function()
		local ok = pcall(report.parse, '{"name":"session_start","fields":{}}\nnot json\n')
		assert(not ok, "a malformed line must raise")
	end,

	["counts includes every registered event name"] = function()
		local counts = report.counts(report.parse(SAMPLE))
		for _, name in Events.NAMES do
			assert(counts[name] ~= nil, "counts must include a key for " .. name)
		end
		assert(counts.session_start == 4, "session_start count")
		assert(counts.egg_purchase == 3, "egg_purchase count")
		assert(counts.egg_hatch == 2, "egg_hatch count")
		assert(counts.robux_purchase == 2, "robux_purchase count")
		assert(counts.kaiju_merge == 1, "kaiju_merge count")
		assert(counts.quest_claim == 0, "unseen registered events default to 0")
		assert(counts.not_a_real_event == nil, "unregistered names are ignored")
	end,

	["tutorialCompletionRate is tutorial_complete over session_start"] = function()
		local counts = report.counts(report.parse(SAMPLE))
		assert(report.tutorialCompletionRate(counts) == 0.5, "2 of 4 sessions completed the tutorial")
		assert(report.tutorialCompletionRate({ session_start = 0 }) == 0, "no sessions means a 0 rate")
	end,

	["robuxRevenue sums robux_purchase prices"] = function()
		assert(report.robuxRevenue(report.parse(SAMPLE)) == 598, "99 + 499 = 598")
		assert(report.robuxRevenue({}) == 0, "no purchases means no revenue")
	end,

	["funnel walks session_start to robux_purchase"] = function()
		local steps = report.funnel(report.counts(report.parse(SAMPLE)))
		assert(#steps == 4, "funnel has four steps")
		assert(steps[1].step == "session_start" and steps[1].count == 4, "funnel starts at sessions")
		assert(steps[2].step == "egg_purchase" and steps[2].count == 3, "second step is egg_purchase")
		assert(steps[3].step == "egg_hatch" and steps[3].count == 2, "third step is egg_hatch")
		assert(steps[4].step == "robux_purchase" and steps[4].count == 2, "fourth step is robux_purchase")
		assert(steps[4].conversion == 0.5, "robux conversion is 2/4")
	end,

	["render emits the count, funnel, and monetization headings"] = function()
		local summary = report.summarize(report.parse(SAMPLE))
		local markdown = report.render(summary, "kaiju-egg-raiders", "2026-09-29")
		assert(contains(markdown, "# kaiju-egg-raiders Weekly Liveops Report"), "report title names the pack")
		assert(contains(markdown, "## Event Counts"), "report has an event-count heading")
		assert(contains(markdown, "## Purchase Funnel"), "report has a funnel heading")
		assert(contains(markdown, "## Monetization"), "report has a monetization heading")
		assert(contains(markdown, "| robux_purchase | 2 |"), "counts table includes robux_purchase")
		assert(contains(markdown, "R$ 598"), "revenue line includes the summed total")
	end,

	["renderDashboard emits one row per pack"] = function()
		local rows = {
			report.dashboardRow("kaiju-egg-raiders", report.summarize(report.parse(SAMPLE))),
			report.dashboardRow("grow-and-defend-garden", report.summarize({})),
		}
		local markdown = report.renderDashboard(rows, "2026-09-29")
		assert(contains(markdown, "# LiveOps Dashboard"), "dashboard has a title")
		assert(
			contains(markdown, "| kaiju-egg-raiders | 4 | 50.0% | 2 | R$ 598 |"),
			"kaiju row carries players, completion, payers, and revenue"
		)
		assert(
			contains(markdown, "| grow-and-defend-garden | 0 | 0.0% | 0 | R$ 0 |"),
			"an empty pack renders a zero row"
		)
	end,
}
