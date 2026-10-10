--!strict
-- qualityscaffold: the minimal, honest quality.yml a fresh pack is generated with.
--
-- Generation may only declare the tier it can actually back. A brand-new pack
-- has no captured first play, no independent reference and no evaluator, so the
-- only tier it may claim is `starter`: an explicit "not a release claim"
-- declaration. `forge quality validate` proves the declaration is well formed
-- and `forge quality check` refuses to read a starter declaration as a release.
--
-- The document is built as text, not through serde: the rubric anchors are
-- integer-keyed (1/3/5) and a Luau table with those keys is a sparse array that
-- a YAML encoder may serialise as a sequence with nulls. The same choice keeps
-- the emitted bytes deterministic, which generation requires.
--
-- Nothing here invents a verdict: the profile carries no score, no approval and
-- no capture, and every goal keeps the bounds `qualityprofile` enforces. The
-- loop-specific goal text is derived from the pack's own declared golden path,
-- so a grow-harvest pack never claims a survival loop.

local M = {}

--- The declaration date recorded on the generated reference block. It is a
--- constant so generation stays byte-identical for the same input, and the
--- note beside it says plainly that it is a declaration date, not a capture.
M.DECLARATION_DATE = "2026-10-01"
M.RUBRIC_VERSION = "starter-firstplay-1"

local CRITERIA: { { id: string, anchors: { [number]: string } } } = {
	{
		id = "legibility",
		anchors = {
			[1] = "the next objective and the interactive targets are indistinguishable from scenery",
			[3] = "the objective reads, but a target or its resource prompt is only legible once the player is adjacent",
			[5] = "objective, targets and prompts read instantly at the default camera distance on both surfaces",
		},
	},
	{
		id = "coherence",
		anchors = {
			[1] = "debug placeholders or unrelated styles break the pack's setting",
			[3] = "environment and HUD share a palette but silhouettes or scale disagree",
			[5] = "environment, interactables and HUD share one palette, silhouette and scale language",
		},
	},
	{
		id = "feedback",
		anchors = {
			[1] = "the pack's actions resolve with no visible or audible response",
			[3] = "actions respond visually but a refusal or pending state is ambiguous",
			[5] = "every action, refusal and pending state has paired, timely visual and audible feedback",
		},
	},
	{
		id = "pacing",
		anchors = {
			[1] = "the first minute offers nothing to do and progression stalls",
			[3] = "the loop starts but stalls between objectives with unexplained waiting",
			[5] = "each goal hands off to the next with no dead stretch for a first-time player",
		},
	},
	{
		id = "meaningful-choice",
		anchors = {
			[1] = "only one action is ever worth taking and choices do not change the outcome",
			[3] = "alternatives exist but their trade-offs are obscure or one dominates",
			[5] = "competing options offer legible trade-offs a player can explain and exercise",
		},
	},
}

local DISQUALIFIERS: { string } = {
	"an objective, avatar or interaction target is obscured or indistinguishable at a required camera angle",
	"raw debug JSON or placeholder controls replace the player-facing interface",
	"an action, refusal or pending state has no perceptible feedback",
	"scripted grants or teleports substitute for first-play discovery",
	"a missing surface capture, second actor, action trace, audio cue or timed goal observation",
}

local function nonEmpty(value: any): boolean
	return type(value) == "string" and string.find(value, "%S") ~= nil
end

--- The action ids a pack's own golden path drives, in order and deduplicated.
--- Read from the serialized genre spec the pack ships, so the goal text names
--- the pack's real loop rather than a genre template's. An unreadable spec
--- yields no names, and the goal falls back to a genre-neutral description.
function M.loopActions(spec: any): { string }
	local actions: { string } = {}
	local seen: { [string]: boolean } = {}
	local qa = if type(spec) == "table" then spec.qa else nil
	if type(qa) ~= "table" or type(qa.goldenPath) ~= "table" then
		return actions
	end
	for _, step in qa.goldenPath do
		if type(step) == "table" and nonEmpty(step.action) and not seen[step.action] then
			seen[step.action] = true
			table.insert(actions, step.action)
		end
	end
	return actions
end

--- The honest description of the pack's own first loop, naming the actions the
--- pack actually drives. The canonical goal id stays (the schema's required
--- goal), while the text says what this pack's loop is.
function M.loopDescription(actions: { string }): string
	if #actions == 0 then
		return "one full pass of the pack's primary loop is completed through its real controls"
	end
	return "one full pass of the pack's primary loop (" .. table.concat(actions, ", ") .. ") is completed"
end

--- The generated quality.yml text for `pack`. `spec` is the owning genre's
--- serialized spec (the pack's own loop); an absent spec still yields a valid
--- starter declaration with a genre-neutral loop description.
function M.profile(pack: string, spec: any): string
	assert(nonEmpty(pack), "qualityscaffold requires a pack slug")
	local actions = M.loopActions(spec)
	local lines: { string } = {
		"schema_version: 1",
		"pack: " .. pack,
		"# Generated by `forge new`/`forge plan`. A fresh pack has no captured first play,",
		"# no independent reference and no evaluator, so it declares only the starter tier:",
		"# an explicit statement that this is not a release claim. `forge quality check`",
		"# refuses to read a starter declaration as release approval.",
		"tier: starter",
		"provisional_targets: true",
		"reference:",
		"  name: starter-experience-benchmark",
		"  source: first-party local capture of games/" .. pack .. "; capture acquisition pending",
		"  rights_holder: Roblox Game Forge project contributors",
		"  capture_permission: first-party build, captured by the framework owner only",
		"  # The declaration date of this block, not proof that a capture happened.",
		"  capture_date: '" .. M.DECLARATION_DATE .. "'",
		"  rubric_version: " .. M.RUBRIC_VERSION,
		"  exemplars:",
		"    - surface: desktop",
		"      path: reference/desktop.png",
		"      note: pending 1280x720 benchmark capture; the date above is the declaration date",
		"    - surface: mobile",
		"      path: reference/mobile.png",
		"      note: pending 390x844 safe-area capture",
		"  disqualifiers:",
	}
	for _, disqualifier in DISQUALIFIERS do
		table.insert(lines, "    - " .. disqualifier)
	end
	table.insert(lines, "rubric:")
	table.insert(lines, "  version: " .. M.RUBRIC_VERSION)
	table.insert(lines, "  criteria:")
	for _, criterion in CRITERIA do
		table.insert(lines, "    - id: " .. criterion.id)
		table.insert(lines, "      target: 4")
		table.insert(lines, "      anchors:")
		for _, score in { 1, 3, 5 } do
			table.insert(lines, "        " .. tostring(score) .. ": " .. criterion.anchors[score])
		end
	end
	for _, line in
		{
			"first_play:",
			"  goals:",
			"    - id: objective-identified",
			"      description: the player names the current objective from visible cues without being prompted",
			"      within_minutes: 10",
			"      players: 1",
			"    - id: first-gather-craft-meal-rest",
			"      description: " .. M.loopDescription(actions),
			"      within_minutes: 10",
			"      players: 1",
			"    - id: shared-facility",
			"      description: two players contribute to and complete one shared facility together",
			"      within_minutes: 20",
			"      players: 2",
			"asset_quality:",
			"  # Rights authority stays assets/manifest.yml; this records the local review only.",
			"  rights_source: first-party procedural output, recorded in assets/manifest.yml",
			"  commercial_use: true",
			"  moderation: not-applicable",
			"  platform_approved: false",
			"fun_verdict:",
			"  # A fun verdict is never inferred: a human records it, and nothing here grants it.",
			"  required: true",
			"  rationale_required: true",
			"  confidence_required: true",
		}
	do
		table.insert(lines, line)
	end
	return table.concat(lines, "\n") .. "\n"
end

return M
