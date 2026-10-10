--!strict
-- qualityprofile: pure schema for a pack's quality.yml - the output tier it
-- claims, the reference package that tier is judged against, the anchored
-- rubric criteria, and the first-play goals an evaluation has to reach.
--
-- Nothing here touches the filesystem, the network, or an evaluator: this
-- module only decides whether a *declaration* is well formed and internally
-- consistent. It never decides that a pack is good; `forge quality validate`
-- reports schema violations, and the separate evaluation/receipt commands
-- (plan tasks 4/18/19) are what may ever record an actual verdict.
--
-- Fail-closed rules this module enforces, from plan task 1:
--   * an unknown/unsupported `schema_version` or `tier` is rejected outright,
--     never downgraded to a tolerated default;
--   * every tier needs a reference package with source, capture permission,
--     capture date, and both a desktop and a mobile exemplar;
--   * `release-candidate` (and `vertical-slice`) may not be self-declared:
--     the profile must point at an external evaluation receipt, and a profile
--     that declares `approved: true` for itself is rejected;
--   * asset quality (legal rights/moderation) stays a field set distinct from
--     the integrated-experience rubric, so a licensed asset never implies an
--     approved experience and vice versa.

local M = {}

export type Tier = "starter" | "vertical-slice" | "release-candidate"

export type CheckResult = { ok: boolean, errors: { string } }

--- Schema versions this build understands. A profile written by a newer
--- writer is refused rather than read with the fields this build happens to
--- know (the same rule the plan sets for save envelopes).
M.SUPPORTED_SCHEMA_VERSIONS = { 1 } :: { number }

--- The ordered output tiers. The order is meaningful: a tier may only claim
--- the evidence tiers at or below its own index.
M.TIERS = { "starter", "vertical-slice", "release-candidate" } :: { Tier }

--- Tiers that can never be self-declared: they require a reference to an
--- evaluation receipt produced outside this file.
M.EVALUATED_TIERS = {
	["vertical-slice"] = true,
	["release-candidate"] = true,
} :: { [string]: boolean }

--- Criteria every profile must anchor, judged 1-5 against written examples.
M.CRITERIA = {
	"legibility",
	"coherence",
	"feedback",
	"pacing",
	"meaningful-choice",
} :: { string }

--- The provisional minimum score every criterion has to reach. A profile may
--- raise this per criterion but never lower it: a lower bar would let a
--- failing experience pass its own gate.
M.MIN_CRITERION_SCORE = 4
M.MAX_CRITERION_SCORE = 5

--- Anchors a profile must write for each criterion, so a score is argued from
--- a concrete example instead of a bare number.
M.REQUIRED_ANCHOR_SCORES = { 1, 3, 5 } :: { number }

--- Default first-play goals (plan task 1). Every goal is explicitly
--- provisional: these are the targets a first session is graded against until
--- real play data replaces them, and the profile has to say so.
---
--- Each canonical goal carries a BOUND, not just a suggested value: a profile
--- must declare the goal with a deadline no later than `withinMinutes` and a
--- player count that still exercises the goal (`minPlayers`). Without that,
--- a pack could keep the goal id and weaken it to "shared facility, 9999
--- minutes, 1 player", which is not the gate the plan sets.
export type FirstPlayGoal = {
	id: string,
	description: string,
	withinMinutes: number?,
	players: number?,
}

--- The bound a canonical goal is held to. `withinMinutes` is a maximum (a
--- profile may demand a faster first session but never a slower one) and
--- `minPlayers` is a minimum (a two-player goal cannot be downgraded to solo).
export type GoalBound = {
	id: string,
	withinMinutes: number,
	minPlayers: number,
}

M.REQUIRED_GOAL_BOUNDS = {
	{ id = "objective-identified", withinMinutes = 10, minPlayers = 1 },
	{ id = "first-gather-craft-meal-rest", withinMinutes = 10, minPlayers = 1 },
	{ id = "shared-facility", withinMinutes = 20, minPlayers = 2 },
} :: { GoalBound }

M.DEFAULT_FIRST_PLAY_GOALS = {
	{
		id = "objective-identified",
		description = "the player names the current objective without being prompted",
		withinMinutes = 10,
		players = 1,
	},
	{
		id = "first-gather-craft-meal-rest",
		description = "one gather, one craft, one meal and one rest are completed",
		withinMinutes = 10,
		players = 1,
	},
	{
		id = "shared-facility",
		description = "two players finish one shared facility together",
		withinMinutes = 20,
		players = 2,
	},
} :: { FirstPlayGoal }

export type Exemplar = {
	surface: string,
	path: string,
	note: string?,
}

export type Reference = {
	name: string,
	source: string,
	rightsHolder: string,
	capturePermission: string,
	captureDate: string,
	rubricVersion: string,
	exemplars: { Exemplar },
	disqualifiers: { string },
}

export type Criterion = {
	id: string,
	target: number,
	anchors: { [number]: string },
}

export type AssetQuality = {
	rightsSource: string,
	commercialUse: boolean,
	moderation: string,
	-- Local review never means the platform approved an upload.
	platformApproved: boolean,
}

export type FunVerdict = {
	required: boolean,
	rationaleRequired: boolean,
	confidenceRequired: boolean,
}

export type Profile = {
	schemaVersion: number,
	pack: string,
	tier: Tier,
	provisionalTargets: boolean,
	reference: Reference,
	criteria: { Criterion },
	firstPlayGoals: { FirstPlayGoal },
	assetQuality: AssetQuality,
	funVerdict: FunVerdict,
	receiptPath: string?,
}

-- Surfaces a reference package must cover; a reference that only shows one of
-- them cannot judge the other.
M.REQUIRED_SURFACES = { "desktop", "mobile" } :: { string }

-- Moderation states an asset-quality block may declare. These mirror
-- lib/assets.luau's manifest contract but stay a *separate* field set: a
-- manifest value is about upload state, this one records what the local
-- quality review observed, and `not-applicable` is the honest value for an
-- asset that was never uploaded.
M.ASSET_MODERATIONS = {
	["not-applicable"] = true,
	["NotUploaded"] = true,
	["PendingModeration"] = true,
	["Approved"] = true,
	["Rejected"] = true,
} :: { [string]: boolean }

local function isNonEmptyString(value: any): boolean
	return type(value) == "string" and value ~= ""
end

local function has(list: { string }, value: any): boolean
	if type(value) ~= "string" then
		return false
	end
	for _, known in list do
		if known == value then
			return true
		end
	end
	return false
end

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--- A dense (array-like) table of at most `limit` entries: a YAML mapping with
--- numeric-looking keys must not pass as a list.
local function dense(value: any, limit: number): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return false
		end
		count += 1
	end
	if count > limit then
		return false
	end
	return count == #value
end

-- ISO 8601 calendar date, the only capture-date form accepted: a free-text
-- date cannot be compared against a build date by a later gate. The day is
-- checked against the real length of that month (leap years included), because
-- a field documented as an ISO date that accepts 2026-02-31 is not a date at
-- all - it silently admits a capture that never happened.
local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function isLeapYear(year: number): boolean
	return (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
end

local function isIsoDate(value: any): boolean
	if type(value) ~= "string" then
		return false
	end
	local year, month, day = string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if year == nil then
		return false
	end
	local y = tonumber(year) :: number
	local m = tonumber(month) :: number
	local d = tonumber(day) :: number
	if m < 1 or m > 12 or d < 1 then
		return false
	end
	local limit = MONTH_DAYS[m]
	if m == 2 and isLeapYear(y) then
		limit = 29
	end
	return d <= limit
end

local function tierIndex(tier: any): number?
	for index, known in M.TIERS do
		if known == tier then
			return index
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Field-path validation. Every error names the exact dotted path of the
-- offending field so the CLI output points at a line a human can fix.
-- ---------------------------------------------------------------------------

local function checkReference(raw: any, errors: { string })
	if type(raw) ~= "table" then
		table.insert(errors, "reference: missing reference package (required for every tier)")
		return
	end
	for _, field in { "name", "source", "rights_holder", "capture_permission", "rubric_version" } do
		if not isNonEmptyString(raw[field]) then
			table.insert(errors, "reference." .. field .. ": must be a non-empty string")
		end
	end
	if not isIsoDate(raw.capture_date) then
		table.insert(errors, "reference.capture_date: must be an ISO date (YYYY-MM-DD)")
	end

	local exemplars = raw.exemplars
	if not dense(exemplars, 64) or #exemplars == 0 then
		table.insert(errors, "reference.exemplars: must be a non-empty list")
	else
		local surfaces: { [string]: boolean } = {}
		for index, entry in exemplars do
			local label = string.format("reference.exemplars[%d]", index)
			if type(entry) ~= "table" then
				table.insert(errors, label .. ": must be a mapping")
				continue
			end
			if not has(M.REQUIRED_SURFACES, entry.surface) then
				table.insert(errors, label .. ".surface: must be one of " .. table.concat(M.REQUIRED_SURFACES, "|"))
			else
				surfaces[entry.surface] = true
			end
			if not isNonEmptyString(entry.path) then
				table.insert(errors, label .. ".path: must be a non-empty capture path")
			end
			if entry.note ~= nil and not isNonEmptyString(entry.note) then
				table.insert(errors, label .. ".note: must be a non-empty string when present")
			end
		end
		for _, surface in M.REQUIRED_SURFACES do
			if not surfaces[surface] then
				table.insert(errors, "reference.exemplars: missing a '" .. surface .. "' exemplar")
			end
		end
	end

	local disqualifiers = raw.disqualifiers
	if not dense(disqualifiers, 64) or #disqualifiers == 0 then
		table.insert(errors, "reference.disqualifiers: must be a non-empty list of blocking defects")
	else
		for index, entry in disqualifiers do
			if not isNonEmptyString(entry) then
				table.insert(errors, string.format("reference.disqualifiers[%d]: must be a non-empty string", index))
			end
		end
	end
end

local function checkCriteria(raw: any, errors: { string })
	if not dense(raw, 64) then
		table.insert(errors, "rubric.criteria: must be a list of anchored criteria")
		return
	end
	local seen: { [string]: boolean } = {}
	for index, entry in raw do
		local label = string.format("rubric.criteria[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, label .. ": must be a mapping")
			continue
		end
		local id = entry.id
		if not has(M.CRITERIA, id) then
			table.insert(errors, label .. ".id: unknown criterion '" .. tostring(id) .. "'")
		elseif seen[id] then
			table.insert(errors, label .. ".id: duplicate criterion '" .. tostring(id) .. "'")
		else
			seen[id] = true
		end

		local target = entry.target
		if not isFiniteNumber(target) or target % 1 ~= 0 then
			table.insert(errors, label .. ".target: must be an integer score")
		elseif target < M.MIN_CRITERION_SCORE then
			table.insert(
				errors,
				string.format("%s.target: must be at least %d (got %s)", label, M.MIN_CRITERION_SCORE, tostring(target))
			)
		elseif target > M.MAX_CRITERION_SCORE then
			table.insert(
				errors,
				string.format("%s.target: must be at most %d (got %s)", label, M.MAX_CRITERION_SCORE, tostring(target))
			)
		end

		local anchors = entry.anchors
		if type(anchors) ~= "table" then
			table.insert(errors, label .. ".anchors: must map scores to written examples")
		else
			for _, score in M.REQUIRED_ANCHOR_SCORES do
				local text = anchors[score]
				if text == nil then
					text = anchors[tostring(score)]
				end
				if not isNonEmptyString(text) then
					table.insert(
						errors,
						string.format("%s.anchors.%d: must describe what a %d looks like", label, score, score)
					)
				end
			end
		end
	end
	for _, id in M.CRITERIA do
		if not seen[id] then
			table.insert(errors, "rubric.criteria: missing required criterion '" .. id .. "'")
		end
	end
end

local function checkFirstPlay(raw: any, errors: { string })
	if not dense(raw, 64) or #raw == 0 then
		table.insert(errors, "first_play.goals: must be a non-empty list")
		return
	end
	-- A canonical goal's declared bounds are recorded by id so the required-goal
	-- sweep below can report a weakened goal against the same field path.
	local declared: { [string]: { index: number, minutes: any, players: any } } = {}
	local seen: { [string]: boolean } = {}
	for index, entry in raw do
		local label = string.format("first_play.goals[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, label .. ": must be a mapping")
			continue
		end
		local id = entry.id
		if not isNonEmptyString(id) then
			table.insert(errors, label .. ".id: must be a non-empty string")
		elseif seen[id] then
			table.insert(errors, label .. ".id: duplicate goal '" .. id .. "'")
		else
			seen[id] = true
			declared[id] = { index = index, minutes = entry.within_minutes, players = entry.players }
		end
		if not isNonEmptyString(entry.description) then
			table.insert(errors, label .. ".description: must describe the observable outcome")
		end
		local minutes = entry.within_minutes
		if minutes ~= nil and (not isFiniteNumber(minutes) or minutes <= 0) then
			table.insert(errors, label .. ".within_minutes: must be a positive number when present")
		end
		local players = entry.players
		if players ~= nil and (not isFiniteNumber(players) or players < 1 or players % 1 ~= 0) then
			table.insert(errors, label .. ".players: must be a positive integer when present")
		end
	end

	-- Every canonical goal must be present AND still be the goal the plan
	-- defines: the deadline may not be relaxed past its bound, the player count
	-- may not drop below it, and neither field may be omitted (an absent field
	-- is an unbounded goal, which is the same weakening by another route).
	for _, bound in M.REQUIRED_GOAL_BOUNDS do
		local entry = declared[bound.id]
		if entry == nil then
			table.insert(errors, "first_play.goals: missing default goal '" .. bound.id .. "'")
			continue
		end
		local label = string.format("first_play.goals[%d]", entry.index)
		if entry.minutes == nil then
			table.insert(
				errors,
				string.format(
					"%s.within_minutes: goal '%s' must declare a deadline of at most %d minutes",
					label,
					bound.id,
					bound.withinMinutes
				)
			)
		elseif isFiniteNumber(entry.minutes) and entry.minutes > bound.withinMinutes then
			table.insert(
				errors,
				string.format(
					"%s.within_minutes: goal '%s' may not be relaxed past %d minutes (got %s)",
					label,
					bound.id,
					bound.withinMinutes,
					tostring(entry.minutes)
				)
			)
		end
		if entry.players == nil then
			table.insert(
				errors,
				string.format(
					"%s.players: goal '%s' must declare at least %d player(s)",
					label,
					bound.id,
					bound.minPlayers
				)
			)
		elseif isFiniteNumber(entry.players) and entry.players < bound.minPlayers then
			table.insert(
				errors,
				string.format(
					"%s.players: goal '%s' needs at least %d player(s) (got %s)",
					label,
					bound.id,
					bound.minPlayers,
					tostring(entry.players)
				)
			)
		end
	end
end

local function checkAssetQuality(raw: any, errors: { string })
	if type(raw) ~= "table" then
		table.insert(errors, "asset_quality: missing (legal rights are tracked separately from the experience rubric)")
		return
	end
	if not isNonEmptyString(raw.rights_source) then
		table.insert(errors, "asset_quality.rights_source: must name where commercial rights come from")
	end
	if type(raw.commercial_use) ~= "boolean" then
		table.insert(errors, "asset_quality.commercial_use: must be a boolean")
	elseif raw.commercial_use == false then
		table.insert(errors, "asset_quality.commercial_use: must be true for a shippable pack")
	end
	local moderation = raw.moderation
	if not isNonEmptyString(moderation) or not M.ASSET_MODERATIONS[moderation] then
		table.insert(errors, "asset_quality.moderation: unknown state '" .. tostring(moderation) .. "'")
	end
	if type(raw.platform_approved) ~= "boolean" then
		table.insert(errors, "asset_quality.platform_approved: must be a boolean")
	elseif raw.platform_approved == true and raw.moderation ~= "Approved" then
		table.insert(
			errors,
			"asset_quality.platform_approved: cannot be true while moderation is '" .. tostring(raw.moderation) .. "'"
		)
	end
end

local function checkFunVerdict(raw: any, errors: { string })
	if type(raw) ~= "table" then
		table.insert(errors, "fun_verdict: missing (the fun verdict is recorded separately from the rubric)")
		return
	end
	for _, field in { "required", "rationale_required", "confidence_required" } do
		if type(raw[field]) ~= "boolean" then
			table.insert(errors, "fun_verdict." .. field .. ": must be a boolean")
		elseif raw[field] == false then
			table.insert(errors, "fun_verdict." .. field .. ": must be true; a fun verdict is never inferred")
		end
	end
	if raw.telemetry ~= nil then
		table.insert(errors, "fun_verdict.telemetry: not allowed; a fun verdict may not cite invented telemetry")
	end
end

--- Validates a decoded quality.yml document. Returns every violation, each
--- prefixed with the dotted path of the offending field, so one run names all
--- of them. An empty error list means the declaration is well formed - never
--- that the pack is approved.
function M.validate(document: any): CheckResult
	local errors: { string } = {}
	if type(document) ~= "table" then
		return { ok = false, errors = { "quality.yml: expected a mapping" } }
	end

	local version = document.schema_version
	if version == nil then
		table.insert(errors, "schema_version: missing (expected 1)")
	elseif not isFiniteNumber(version) or not table.find(M.SUPPORTED_SCHEMA_VERSIONS, version) then
		table.insert(
			errors,
			"schema_version: unsupported version '" .. tostring(version) .. "' (this build supports 1)"
		)
	end

	if not isNonEmptyString(document.pack) then
		table.insert(errors, "pack: must be a non-empty pack slug")
	end

	local tier = document.tier
	local index = tierIndex(tier)
	if index == nil then
		table.insert(
			errors,
			"tier: unsupported tier '" .. tostring(tier) .. "' (expected " .. table.concat(M.TIERS, "|") .. ")"
		)
	end

	if type(document.provisional_targets) ~= "boolean" then
		table.insert(errors, "provisional_targets: must be a boolean stating whether the targets are provisional")
	end

	checkReference(document.reference, errors)

	local rubric = document.rubric
	if type(rubric) ~= "table" then
		table.insert(errors, "rubric: missing anchored rubric")
	else
		if not isNonEmptyString(rubric.version) then
			table.insert(errors, "rubric.version: must be a non-empty version string")
		elseif
			type(document.reference) == "table"
			and isNonEmptyString(document.reference.rubric_version)
			and document.reference.rubric_version ~= rubric.version
		then
			table.insert(
				errors,
				"rubric.version: does not match reference.rubric_version ('"
					.. tostring(document.reference.rubric_version)
					.. "')"
			)
		end
		checkCriteria(rubric.criteria, errors)
	end

	local firstPlay = document.first_play
	if type(firstPlay) ~= "table" then
		table.insert(errors, "first_play: missing first-play goals")
	else
		checkFirstPlay(firstPlay.goals, errors)
	end

	checkAssetQuality(document.asset_quality, errors)
	checkFunVerdict(document.fun_verdict, errors)

	-- Fail closed on release claims. A profile declares the tier it is being
	-- evaluated *for*; it may never carry its own verdict, and anything above
	-- starter has to name the receipt an external evaluation wrote.
	if document.approved ~= nil then
		table.insert(errors, "approved: a profile may not declare its own verdict; see 'forge quality check'")
	end
	if document.verdict ~= nil then
		table.insert(errors, "verdict: a profile may not declare its own verdict; see 'forge quality check'")
	end

	local receipt = document.evaluation_receipt
	if tier ~= nil and M.EVALUATED_TIERS[tier] then
		if not isNonEmptyString(receipt) then
			table.insert(
				errors,
				"evaluation_receipt: tier '"
					.. tostring(tier)
					.. "' cannot be self-declared; it requires an evaluation receipt path"
			)
		end
	elseif receipt ~= nil and not isNonEmptyString(receipt) then
		table.insert(errors, "evaluation_receipt: must be a non-empty path when present")
	end

	return { ok = #errors == 0, errors = errors }
end

--- Normalizes a *valid* document into a typed Profile. Returns (nil, errors)
--- when the document does not validate, so no caller can read a half-checked
--- declaration.
function M.parse(document: any): (Profile?, { string })
	local result = M.validate(document)
	if not result.ok then
		return nil, result.errors
	end

	local rawReference = document.reference
	local exemplars: { Exemplar } = {}
	for _, entry in rawReference.exemplars do
		table.insert(exemplars, { surface = entry.surface, path = entry.path, note = entry.note })
	end
	local disqualifiers: { string } = {}
	for _, entry in rawReference.disqualifiers do
		table.insert(disqualifiers, entry)
	end

	local criteria: { Criterion } = {}
	for _, entry in document.rubric.criteria do
		local anchors: { [number]: string } = {}
		for _, score in M.REQUIRED_ANCHOR_SCORES do
			local text = entry.anchors[score]
			if text == nil then
				text = entry.anchors[tostring(score)]
			end
			anchors[score] = text
		end
		table.insert(criteria, { id = entry.id, target = entry.target, anchors = anchors })
	end

	local goals: { FirstPlayGoal } = {}
	for _, entry in document.first_play.goals do
		table.insert(goals, {
			id = entry.id,
			description = entry.description,
			withinMinutes = entry.within_minutes,
			players = entry.players,
		})
	end

	local rawAssets = document.asset_quality
	local rawFun = document.fun_verdict

	return {
		schemaVersion = document.schema_version,
		pack = document.pack,
		tier = document.tier :: Tier,
		provisionalTargets = document.provisional_targets,
		reference = {
			name = rawReference.name,
			source = rawReference.source,
			rightsHolder = rawReference.rights_holder,
			capturePermission = rawReference.capture_permission,
			captureDate = rawReference.capture_date,
			rubricVersion = rawReference.rubric_version,
			exemplars = exemplars,
			disqualifiers = disqualifiers,
		},
		criteria = criteria,
		firstPlayGoals = goals,
		assetQuality = {
			rightsSource = rawAssets.rights_source,
			commercialUse = rawAssets.commercial_use,
			moderation = rawAssets.moderation,
			platformApproved = rawAssets.platform_approved,
		},
		funVerdict = {
			required = rawFun.required,
			rationaleRequired = rawFun.rationale_required,
			confidenceRequired = rawFun.confidence_required,
		},
		receiptPath = document.evaluation_receipt,
	}, {}
end

--- True when `profile` claims a tier that no evaluation receipt can be skipped
--- for. Exposed so the later gate commands (plan tasks 4/19) share this rule
--- instead of restating it.
function M.requiresEvaluation(profile: Profile): boolean
	return M.EVALUATED_TIERS[profile.tier] == true
end

--- Compares two tiers. Returns true when `claimed` is at or below `proven`,
--- i.e. the claim is covered by the evidence tier. A starter profile may never
--- be read as a release candidate just because its build succeeded.
function M.tierWithin(claimed: Tier, proven: Tier): boolean
	local claimedIndex = tierIndex(claimed)
	local provenIndex = tierIndex(proven)
	if claimedIndex == nil or provenIndex == nil then
		return false
	end
	return claimedIndex <= provenIndex
end

return M
