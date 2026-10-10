--!strict
-- Specs for qualityprofile: the fail-closed rules a quality profile has to
-- satisfy before any evaluation may read it. Every case asserts the exact
-- field path the CLI prints, so a loosened rule cannot pass silently.

local qualityprofile = require("./qualityprofile")

local function baseDocument(): any
	return {
		schema_version = 1,
		pack = "fixture-quality",
		tier = "starter",
		provisional_targets = true,
		reference = {
			name = "coop-survival-bench",
			source = "first-party capture of games/fixture-quality",
			rights_holder = "forge",
			capture_permission = "first-party build, captured by the framework owner",
			capture_date = "2026-10-01",
			rubric_version = "quality-rubric-v1",
			exemplars = {
				{ surface = "desktop", path = "reference/desktop-first-camp.png" },
				{ surface = "mobile", path = "reference/mobile-first-camp.png", note = "390x844 safe area" },
			},
			disqualifiers = {
				"the player cannot tell which object is interactive",
				"a hit lands with no audible or visible feedback",
			},
		},
		rubric = {
			version = "quality-rubric-v1",
			criteria = {
				{
					id = "legibility",
					target = 4,
					anchors = {
						[1] = "targets are indistinguishable from scenery",
						[3] = "targets read once the player is already adjacent",
						[5] = "targets read instantly at normal camera distance",
					},
				},
				{
					id = "coherence",
					target = 4,
					anchors = {
						[1] = "assets come from unrelated styles",
						[3] = "most assets share a palette, some do not",
						[5] = "every asset shares silhouette, palette and scale rules",
					},
				},
				{
					id = "feedback",
					target = 4,
					anchors = {
						[1] = "actions resolve with no response at all",
						[3] = "actions respond visually but not audibly",
						[5] = "every action resolves with paired visual and audio response",
					},
				},
				{
					id = "pacing",
					target = 4,
					anchors = {
						[1] = "the first minute has nothing to do",
						[3] = "the loop starts but stalls between goals",
						[5] = "each goal hands off to the next without a dead stretch",
					},
				},
				{
					id = "meaningful-choice",
					target = 4,
					anchors = {
						[1] = "only one action is ever worth taking",
						[3] = "choices exist but one dominates",
						[5] = "competing options trade off against each other",
					},
				},
			},
		},
		first_play = {
			goals = {
				{
					id = "objective-identified",
					description = "the player names the current objective without being prompted",
					within_minutes = 10,
					players = 1,
				},
				{
					id = "first-gather-craft-meal-rest",
					description = "one gather, one craft, one meal and one rest are completed",
					within_minutes = 10,
					players = 1,
				},
				{
					id = "shared-facility",
					description = "two players finish one shared facility together",
					within_minutes = 20,
					players = 2,
				},
			},
		},
		asset_quality = {
			rights_source = "forge-procgen first-party output",
			commercial_use = true,
			moderation = "not-applicable",
			platform_approved = false,
		},
		fun_verdict = {
			required = true,
			rationale_required = true,
			confidence_required = true,
		},
	}
end

local function errorsOf(mutate: ((any) -> ())?): { string }
	local document = baseDocument()
	if mutate ~= nil then
		mutate(document)
	end
	return qualityprofile.validate(document).errors
end

local function contains(errors: { string }, needle: string): boolean
	for _, err in errors do
		if string.find(err, needle, 1, true) ~= nil then
			return true
		end
	end
	return false
end

local function assertRejects(needle: string, mutate: (any) -> ())
	local errors = errorsOf(mutate)
	assert(contains(errors, needle), "expected an error naming '" .. needle .. "', got: " .. table.concat(errors, "; "))
end

return {
	["a complete starter profile validates"] = function()
		local errors = errorsOf(nil)
		assert(#errors == 0, "expected no errors, got: " .. table.concat(errors, "; "))
	end,

	["a complete profile parses into typed fields"] = function()
		local profile, errors = qualityprofile.parse(baseDocument())
		assert(profile ~= nil, "valid document must parse: " .. table.concat(errors, "; "))
		local parsed = profile :: qualityprofile.Profile
		assert(parsed.tier == "starter", "tier is carried through")
		assert(parsed.reference.captureDate == "2026-10-01", "capture date is carried through")
		assert(#parsed.criteria == 5, "all five criteria are parsed")
		assert(parsed.criteria[1].anchors[5] ~= nil, "the 5 anchor survives normalization")
		assert(#parsed.firstPlayGoals == 3, "all three first-play goals are parsed")
		assert(parsed.assetQuality.platformApproved == false, "local review does not imply platform approval")
		assert(parsed.funVerdict.required, "the fun verdict stays required")
	end,

	["an invalid document never parses"] = function()
		local document = baseDocument()
		document.reference = nil
		local profile, errors = qualityprofile.parse(document)
		assert(profile == nil, "a document missing its reference must not parse")
		assert(#errors > 0, "parse reports why")
	end,

	["a missing reference is rejected with its field path"] = function()
		assertRejects("reference: missing reference package", function(document)
			document.reference = nil
		end)
	end,

	["a reference without capture permission is rejected"] = function()
		assertRejects("reference.capture_permission", function(document)
			document.reference.capture_permission = nil
		end)
	end,

	["a reference without a rights holder is rejected"] = function()
		assertRejects("reference.rights_holder", function(document)
			document.reference.rights_holder = ""
		end)
	end,

	["a free-text capture date is rejected"] = function()
		assertRejects("reference.capture_date", function(document)
			document.reference.capture_date = "last tuesday"
		end)
	end,

	["an impossible capture date is rejected"] = function()
		assertRejects("reference.capture_date", function(document)
			document.reference.capture_date = "2026-13-01"
		end)
	end,

	-- Parent finding: a field documented as an ISO date must not accept a day
	-- that never existed, or a "capture" can be dated to a day nobody captured.
	["a day past the end of its month is rejected"] = function()
		assertRejects("reference.capture_date", function(document)
			document.reference.capture_date = "2026-02-31"
		end)
	end,

	["a thirty-first of a thirty-day month is rejected"] = function()
		assertRejects("reference.capture_date", function(document)
			document.reference.capture_date = "2026-04-31"
		end)
	end,

	["february 29 is rejected in a common year"] = function()
		assertRejects("reference.capture_date", function(document)
			document.reference.capture_date = "2026-02-29"
		end)
	end,

	["february 29 is accepted in a leap year"] = function()
		local errors = errorsOf(function(document)
			document.reference.capture_date = "2024-02-29"
		end)
		assert(#errors == 0, "2024 is a leap year: " .. table.concat(errors, "; "))
	end,

	["february 29 is rejected in a century that is not a leap year"] = function()
		assertRejects("reference.capture_date", function(document)
			document.reference.capture_date = "1900-02-29"
		end)
	end,

	["february 29 is accepted in a four-hundred year leap year"] = function()
		local errors = errorsOf(function(document)
			document.reference.capture_date = "2000-02-29"
		end)
		assert(#errors == 0, "2000 is a leap year: " .. table.concat(errors, "; "))
	end,

	["a day zero is rejected"] = function()
		assertRejects("reference.capture_date", function(document)
			document.reference.capture_date = "2026-01-00"
		end)
	end,

	["the last day of each month is accepted"] = function()
		local lastDays =
			{ "2026-01-31", "2026-03-31", "2026-05-31", "2026-07-31", "2026-08-31", "2026-10-31", "2026-12-31" }
		for _, date in lastDays do
			local errors = errorsOf(function(document)
				document.reference.capture_date = date
			end)
			assert(#errors == 0, date .. " is a real date: " .. table.concat(errors, "; "))
		end
	end,

	["a desktop-only reference is rejected"] = function()
		assertRejects("missing a 'mobile' exemplar", function(document)
			table.remove(document.reference.exemplars, 2)
		end)
	end,

	["a reference without disqualifiers is rejected"] = function()
		assertRejects("reference.disqualifiers", function(document)
			document.reference.disqualifiers = {}
		end)
	end,

	["an unsupported schema version is rejected, not downgraded"] = function()
		assertRejects("schema_version: unsupported version '2'", function(document)
			document.schema_version = 2
		end)
	end,

	["a missing schema version is rejected"] = function()
		assertRejects("schema_version: missing", function(document)
			document.schema_version = nil
		end)
	end,

	["an unsupported tier is rejected"] = function()
		assertRejects("tier: unsupported tier 'shipped'", function(document)
			document.tier = "shipped"
		end)
	end,

	["a missing rubric criterion is rejected by name"] = function()
		assertRejects("missing required criterion 'pacing'", function(document)
			for index, criterion in document.rubric.criteria do
				if criterion.id == "pacing" then
					table.remove(document.rubric.criteria, index)
					break
				end
			end
		end)
	end,

	["a criterion target below 4 is rejected"] = function()
		assertRejects("target: must be at least 4", function(document)
			document.rubric.criteria[1].target = 3
		end)
	end,

	["a criterion without anchored examples is rejected"] = function()
		assertRejects("anchors.5", function(document)
			document.rubric.criteria[1].anchors[5] = nil
		end)
	end,

	["string-keyed anchors from YAML are accepted"] = function()
		local errors = errorsOf(function(document)
			local anchors = document.rubric.criteria[1].anchors
			anchors["1"] = anchors[1]
			anchors["3"] = anchors[3]
			anchors["5"] = anchors[5]
			anchors[1], anchors[3], anchors[5] = nil, nil, nil
		end)
		assert(#errors == 0, "YAML may decode numeric keys as strings: " .. table.concat(errors, "; "))
	end,

	["a rubric version that disagrees with the reference is rejected"] = function()
		assertRejects("does not match reference.rubric_version", function(document)
			document.rubric.version = "quality-rubric-v2"
		end)
	end,

	["a missing default first-play goal is rejected by id"] = function()
		assertRejects("missing default goal 'shared-facility'", function(document)
			table.remove(document.first_play.goals, 3)
		end)
	end,

	-- Parent finding: keeping the canonical goal ids while relaxing their bounds
	-- weakened the plan's 10/20-minute and two-player gates. A goal is the goal
	-- the plan defines, or it is rejected.
	["a canonical goal may not relax its deadline"] = function()
		assertRejects("may not be relaxed past 20 minutes", function(document)
			document.first_play.goals[3].within_minutes = 9999
		end)
	end,

	["a solo-time goal may not relax its ten minute deadline"] = function()
		assertRejects("may not be relaxed past 10 minutes", function(document)
			document.first_play.goals[1].within_minutes = 45
		end)
	end,

	["the shared facility goal may not drop to one player"] = function()
		assertRejects("needs at least 2 player(s)", function(document)
			document.first_play.goals[3].players = 1
		end)
	end,

	["a canonical goal may not omit its deadline"] = function()
		assertRejects("must declare a deadline of at most 20 minutes", function(document)
			document.first_play.goals[3].within_minutes = nil
		end)
	end,

	["a canonical goal may not omit its player count"] = function()
		assertRejects("must declare at least 2 player(s)", function(document)
			document.first_play.goals[3].players = nil
		end)
	end,

	["a canonical goal may be tightened past its bound"] = function()
		local errors = errorsOf(function(document)
			document.first_play.goals[3].within_minutes = 15
			document.first_play.goals[3].players = 3
		end)
		assert(#errors == 0, "a stricter target is allowed: " .. table.concat(errors, "; "))
	end,

	["the declared bounds match the default goals"] = function()
		assert(
			#qualityprofile.REQUIRED_GOAL_BOUNDS == #qualityprofile.DEFAULT_FIRST_PLAY_GOALS,
			"every default goal carries a bound"
		)
		for index, bound in qualityprofile.REQUIRED_GOAL_BOUNDS do
			local goal = qualityprofile.DEFAULT_FIRST_PLAY_GOALS[index]
			assert(goal.id == bound.id, "bound " .. bound.id .. " matches default goal " .. goal.id)
			assert(goal.withinMinutes == bound.withinMinutes, "the default goal sits exactly on its deadline bound")
			assert(goal.players == bound.minPlayers, "the default goal sits exactly on its player bound")
		end
	end,

	["a first-play goal without a description is rejected"] = function()
		assertRejects("description", function(document)
			document.first_play.goals[1].description = nil
		end)
	end,

	["a non-positive goal deadline is rejected"] = function()
		assertRejects("within_minutes", function(document)
			document.first_play.goals[1].within_minutes = 0
		end)
	end,

	["targets must say whether they are provisional"] = function()
		assertRejects("provisional_targets", function(document)
			document.provisional_targets = nil
		end)
	end,

	["asset rights are a separate required block"] = function()
		assertRejects("asset_quality: missing", function(document)
			document.asset_quality = nil
		end)
	end,

	["an asset block without a rights source is rejected"] = function()
		assertRejects("asset_quality.rights_source", function(document)
			document.asset_quality.rights_source = nil
		end)
	end,

	["non-commercial asset rights are rejected"] = function()
		assertRejects("asset_quality.commercial_use", function(document)
			document.asset_quality.commercial_use = false
		end)
	end,

	["local review cannot claim platform approval"] = function()
		assertRejects("asset_quality.platform_approved", function(document)
			document.asset_quality.platform_approved = true
		end)
	end,

	["a fun verdict may not be waived"] = function()
		assertRejects("fun_verdict.required", function(document)
			document.fun_verdict.required = false
		end)
	end,

	["a fun verdict may not cite invented telemetry"] = function()
		assertRejects("fun_verdict.telemetry", function(document)
			document.fun_verdict.telemetry = { retention = 0.4 }
		end)
	end,

	["a starter may not self-declare approval"] = function()
		assertRejects("approved: a profile may not declare its own verdict", function(document)
			document.approved = true
		end)
	end,

	["a profile may not carry its own verdict"] = function()
		assertRejects("verdict: a profile may not declare its own verdict", function(document)
			document.verdict = "release-candidate"
		end)
	end,

	["a release-candidate claim without a receipt is rejected"] = function()
		assertRejects("evaluation_receipt", function(document)
			document.tier = "release-candidate"
		end)
	end,

	["a vertical-slice claim without a receipt is rejected"] = function()
		assertRejects("evaluation_receipt", function(document)
			document.tier = "vertical-slice"
		end)
	end,

	["a release-candidate claim with a receipt path validates"] = function()
		local errors = errorsOf(function(document)
			document.tier = "release-candidate"
			document.evaluation_receipt = ".omo/evidence/forge-output-quality-survival/quality.json"
		end)
		assert(#errors == 0, "expected no errors, got: " .. table.concat(errors, "; "))
	end,

	["requiresEvaluation separates starter from the evaluated tiers"] = function()
		local starter = assert(qualityprofile.parse(baseDocument()), "starter parses")
		assert(not qualityprofile.requiresEvaluation(starter), "starter needs no receipt")

		local document = baseDocument()
		document.tier = "release-candidate"
		document.evaluation_receipt = "receipt.json"
		local candidate = assert(qualityprofile.parse(document), "candidate parses")
		assert(qualityprofile.requiresEvaluation(candidate), "a release candidate needs a receipt")
	end,

	["a starter is never within a release-candidate claim"] = function()
		assert(qualityprofile.tierWithin("starter", "release-candidate"), "a starter claim is covered by more proof")
		assert(
			not qualityprofile.tierWithin("release-candidate", "starter"),
			"starter evidence can never carry a release-candidate claim"
		)
		assert(
			not qualityprofile.tierWithin("release-candidate", "bogus" :: any),
			"an unknown tier is never within anything"
		)
	end,

	["a non-mapping document is rejected"] = function()
		local result = qualityprofile.validate("tier: starter")
		assert(not result.ok, "a string is not a profile")
		assert(contains(result.errors, "expected a mapping"), table.concat(result.errors, "; "))
	end,

	["a mapping with numeric-looking keys is not accepted as a list"] = function()
		assertRejects("reference.exemplars", function(document)
			document.reference.exemplars = { foo = { surface = "desktop", path = "x.png" } }
		end)
	end,

	["every violation is reported in one run"] = function()
		local errors = errorsOf(function(document)
			document.tier = "unknown-tier"
			document.reference.capture_date = "yesterday"
			document.asset_quality.commercial_use = false
		end)
		assert(contains(errors, "tier:"), "tier reported")
		assert(contains(errors, "reference.capture_date"), "capture date reported")
		assert(contains(errors, "asset_quality.commercial_use"), "rights reported")
	end,
}
