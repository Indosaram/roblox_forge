--!strict
-- qualityevidence: the evidence receipt Forge records for a generated pack.
--
-- This is deliberately NOT the release receipt `qualityreceipt` admits. That
-- receipt is minted by an independent evaluator over a Studio session and its
-- attestation, and only it can ever approve a vertical-slice or
-- release-candidate claim. A generated pack declares the `starter` tier, which
-- is explicitly not a release claim, so what Forge can honestly record for it
-- is the mechanical evidence it already produces: the sweep's own columns, the
-- Studio capture manifest and its visual-content gate results where a capture
-- run exists, the AV source receipt where one exists, and the native QA results.
--
-- The receipt never mints human approval. Fun and visual quality are recorded
-- as `human-judgment-pending` and the validator fails closed if a document
-- claims anything else. A mechanical column is a fact ("the place built", "the
-- frame was not uniform"); it is never a verdict about whether the game is good.

local qualityprofile = require("./qualityprofile")
local qualityreceipt = require("./qualityreceipt")

local M = {}

M.SCHEMA = "forge-quality-evidence/v1"

--- The columns the receipt must carry a verdict for. `load` is the headless
--- 8-actor proof; every other name is a sweep column, so a receipt can only
--- ever restate evidence the same run produced.
M.REQUIRED_COLUMNS = {
	"generate",
	"files",
	"build",
	"inspect",
	"spec",
	"hud",
	"world",
	"audio",
	"nativeQa",
	"surface",
	"load",
} :: { string }

--- The only verdict a human-judgment field may carry here. Kept as a named
--- constant so the validator, the builder and the sweep's markdown agree.
M.PENDING = "human-judgment-pending"

export type Column = { ok: boolean, error: string? }
export type Options = {
	pack: string,
	tier: string,
	profileDigest: string,
	columns: { [string]: Column },
	-- Optional mechanical evidence, recorded only when the run actually
	-- produced it. Absent evidence is recorded as absent with a reason; it is
	-- never inferred from another column.
	captures: any?,
	av: any?,
	nativeQa: any?,
	load: any?,
}

local function text(value: any): boolean
	return type(value) == "string" and string.find(value, "%S") ~= nil
end

local function tierKnown(tier: any): boolean
	return type(tier) == "string" and table.find(qualityprofile.TIERS, tier) ~= nil
end

--- The canonical digest of a parsed profile, so a receipt is bound to the exact
--- declaration it was produced against. Reuses the receipt module's canonical
--- algorithm rather than inventing a second one.
function M.profileDigest(profile: qualityprofile.Profile): string
	return qualityreceipt.digest(profile)
end

--- The same canonical digest, for a caller binding an evidence artifact (a
--- capture manifest, an AV source receipt) to the receipt that records it.
function M.digest(value: any): string
	return qualityreceipt.digest(value)
end

--- Builds the receipt document for a run. Raises on an unusable request: a
--- receipt that cannot name its pack, its declared tier or every column verdict
--- is not worth writing, and a caller that passed one has a bug, not a
--- judgment call to make.
function M.build(options: Options): any
	assert(text(options.pack), "quality evidence requires a pack slug")
	assert(tierKnown(options.tier), "quality evidence requires a declared tier")
	assert(text(options.profileDigest), "quality evidence requires a profile digest")
	for _, name in M.REQUIRED_COLUMNS do
		local column = options.columns[name]
		assert(type(column) == "table" and type(column.ok) == "boolean", "quality evidence is missing column: " .. name)
	end
	local columns: { [string]: any } = {}
	for _, name in M.REQUIRED_COLUMNS do
		local column = options.columns[name]
		columns[name] = { ok = column.ok, error = column.error }
	end
	return {
		schema = M.SCHEMA,
		pack = options.pack,
		tier = options.tier,
		profileDigest = options.profileDigest,
		-- A starter declaration is not a release claim, and this receipt is not a
		-- release approval. The field is written explicitly so no reader can infer one.
		releaseApproved = false,
		generated = true,
		columns = columns,
		captures = options.captures,
		av = options.av,
		nativeQa = options.nativeQa,
		load = options.load,
		fun = { verdict = M.PENDING, note = "a fun verdict is recorded by a human, never inferred from a build" },
		visual = {
			verdict = M.PENDING,
			note = "visual quality is a human judgment; the visual-content gate only proves a frame is not uniform",
		},
		humanJudgment = {
			required = true,
			verdict = "pending",
			note = "no receipt here approves fun or visual quality; that stays a human decision",
		},
	}
end

--- Validates a receipt against the pack's declared profile. Returns every
--- violation, each prefixed with the field path, so one run names all of them.
--- An empty error list means the receipt is a valid, non-approving record of
--- mechanical evidence for the declared tier - never that the pack is approved.
function M.validate(document: any, profile: qualityprofile.Profile): { string }
	local errors: { string } = {}
	local function demand(condition: boolean, message: string)
		if not condition then
			table.insert(errors, message)
		end
	end
	if type(document) ~= "table" then
		return { "quality evidence: expected a mapping" }
	end
	demand(document.schema == M.SCHEMA, "schema: expected " .. M.SCHEMA)
	demand(document.pack == profile.pack, "pack: does not match the declared profile")
	demand(tierKnown(document.tier), "tier: unknown tier")
	demand(document.tier == profile.tier, "tier: does not match the declared profile tier")
	demand(document.profileDigest == M.profileDigest(profile), "profileDigest: does not bind the declared profile")
	-- The receipt records mechanical evidence only; a release approval can never
	-- come from it, and a document that claims one is refused outright.
	demand(document.releaseApproved == false, "releaseApproved: an evidence receipt never approves a release")
	demand(document.generated == true, "generated: an evidence receipt describes a generated pack")
	local columns = document.columns
	if type(columns) ~= "table" then
		table.insert(errors, "columns: missing column verdicts")
	else
		for _, name in M.REQUIRED_COLUMNS do
			local column = columns[name]
			if type(column) ~= "table" then
				table.insert(errors, "columns." .. name .. ": missing")
			elseif column.ok ~= true then
				table.insert(errors, "columns." .. name .. ": not ok (" .. tostring(column.error) .. ")")
			end
		end
	end
	-- Human judgment is never supplied by this document. Both fields must say so.
	for _, field in { "fun", "visual" } do
		local verdict = if type(document[field]) == "table" then document[field].verdict else nil
		demand(verdict == M.PENDING, field .. ".verdict: must be '" .. M.PENDING .. "'")
	end
	local judgment = document.humanJudgment
	demand(
		type(judgment) == "table" and judgment.required == true and judgment.verdict == "pending",
		"humanJudgment: must record that a human decision is still pending"
	)
	-- Capture and AV evidence is optional, but an absent one has to say so
	-- rather than be silently missing, and a present one has to be bound to the
	-- artifact it summarizes and must never carry a quality verdict.
	for _, field in { "captures", "av" } do
		local value = document[field]
		if value ~= nil then
			demand(
				type(value) == "table" and type(value.present) == "boolean",
				field .. ": must record whether the evidence is present"
			)
			if type(value) == "table" and value.present == false then
				demand(text(value.reason), field .. ".reason: an absent evidence record must say why")
			elseif type(value) == "table" then
				demand(text(value.source), field .. ".source: present evidence must name its artifact")
				demand(text(value.digest), field .. ".digest: present evidence must be bound by digest")
				demand(value.verdict == nil, field .. ".verdict: this receipt never judges quality")
			end
		end
	end
	local load = document.load
	demand(
		type(load) == "table" and type(load.ok) == "boolean" and type(load.actors) == "number",
		"load: must record the actor count and verdict"
	)
	return errors
end

--- One short line per column plus the two pending human judgments, for the
--- sweep's markdown report.
function M.render(document: any): string
	local lines: { string } = { "| column | verdict |", "| --- | --- |" }
	for _, name in M.REQUIRED_COLUMNS do
		local column = document.columns[name]
		table.insert(lines, string.format("| %s | %s |", name, if column.ok then "PASS" else "FAIL"))
	end
	table.insert(lines, string.format("| fun | %s |", document.fun.verdict))
	table.insert(lines, string.format("| visual | %s |", document.visual.verdict))
	return table.concat(lines, "\n") .. "\n"
end

return M
