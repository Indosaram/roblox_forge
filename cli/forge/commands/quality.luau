--!strict
-- `forge quality validate [--file <path>] [--pack <slug>]`: decode a quality
-- profile document and report every schema violation with its field path.
--
-- This command validates a *declaration* only. It never evaluates a pack, and
-- a profile that passes here is not approved: `validate` says the pack's
-- quality claim is well formed and fails closed on any self-declared verdict.
-- `check` verifies the declared tier through the shared digest-bound gate.
--
-- Two further paths record what Forge can honestly say about a generated pack:
--   * `evaluate --pack <slug> --sweep <dir> [--out <path>]` turns a sweep run's
--     own columns and its headless load proof into an evidence receipt;
--   * `check --pack <slug> --evidence <path>` (or `--sweep <dir>`) validates that
--     receipt against the pack's declared tier.
-- Neither ever approves fun or visual quality: both stay human-judgment-pending,
-- and a receipt that claims otherwise is refused.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local cliutil = require("../lib/cliutil")
local qualityprofile = require("../lib/qualityprofile")
local qualitygate = require("../lib/qualitygate")
local qualityevidence = require("../lib/qualityevidence")

local M = {}

local DEFAULT_PACK = "kaiju-egg-raiders"
local NL = string.char(10)

export type ValidateOptions = { file: string?, pack: string? }

--- Parses `forge quality validate`'s arguments (args[1] = "quality",
--- args[2] = "validate"). Returns (options, nil) or (nil, reason). Exported so
--- the specs drive the exact parser the command runs.
function M.parseValidateArgs(args: { string }): (ValidateOptions?, string?)
	local options: ValidateOptions = {}
	local index = 3
	while index <= #args do
		local flag = args[index]
		local value = args[index + 1]
		if flag == "--file" or flag == "--pack" then
			if value == nil or value == "" then
				return nil, "Error: " .. flag .. " requires a value"
			end
			if flag == "--file" then
				if options.file ~= nil then
					return nil, "Error: --file given twice"
				end
				options.file = value
			else
				if options.pack ~= nil then
					return nil, "Error: --pack given twice"
				end
				options.pack = value
			end
			index += 2
		else
			return nil, "Error: unknown argument '" .. tostring(flag) .. "' for forge quality validate"
		end
	end
	if options.file ~= nil and options.pack ~= nil then
		return nil, "Error: --file and --pack are mutually exclusive"
	end
	if options.pack ~= nil and not cliutil.isValidKey(options.pack) then
		return nil, "Error: invalid pack slug '" .. options.pack .. "'"
	end
	return options, nil
end

--- Resolves which document a run reads: an explicit --file, else the selected
--- pack's games/<pack>/quality.yml.
function M.resolvePath(options: ValidateOptions, context: cliutil.CommandContext?): string
	if options.file ~= nil then
		return options.file
	end
	local pack = options.pack or DEFAULT_PACK
	local packsDir = if context and context.packsDir then context.packsDir else "games"
	return packsDir .. "/" .. pack .. "/quality.yml"
end

local function runValidate(args: { string }, context: cliutil.CommandContext?): boolean
	local options, reason = M.parseValidateArgs(args)
	if options == nil then
		stdio.ewrite(tostring(reason) .. NL)
		return false
	end

	local path = M.resolvePath(options, context)
	if not fs.isFile(path) then
		stdio.ewrite("Error: missing quality profile " .. path .. NL)
		return false
	end

	local decodeOk, decoded = pcall(function()
		return serde.decode("yaml", fs.readFile(path))
	end)
	if not decodeOk then
		stdio.ewrite("Error: failed to decode " .. path .. ": " .. tostring(decoded) .. NL)
		return false
	end

	local result = qualityprofile.validate(decoded)
	if not result.ok then
		for _, err in result.errors do
			stdio.ewrite(path .. ": " .. err .. NL)
		end
		stdio.ewrite("quality validate: FAIL" .. NL)
		return false
	end

	local profile = assert(qualityprofile.parse(decoded), "a valid document parses")
	stdio.write(
		string.format(
			"quality validate: PASS (%s, tier=%s, reference=%s, criteria=%d, first-play goals=%d)%s",
			profile.pack,
			profile.tier,
			profile.reference.name,
			#profile.criteria,
			#profile.firstPlayGoals,
			NL
		)
	)
	if qualityprofile.requiresEvaluation(profile) then
		stdio.write(
			"quality validate: tier '"
				.. profile.tier
				.. "' is a claim only; it is approved by an evaluation receipt, not by this check"
				.. NL
		)
	else
		stdio.write("quality validate: starter tier declared; this is not a release claim" .. NL)
	end
	return true
end

function M.parseCheckArgs(args: { string }): ({ [string]: string }?, string?)
	local options: { [string]: string } = {}
	for index = 3, #args, 2 do
		local flag, value = args[index], args[index + 1]
		if
			flag ~= "--pack"
			and flag ~= "--receipt"
			and flag ~= "--target"
			and flag ~= "--packs-root"
			and flag ~= "--evidence"
			and flag ~= "--sweep"
			and flag ~= "--out"
		then
			return nil, "unknown quality check argument: " .. flag
		end
		if value == nil or value == "" or string.sub(value, 1, 2) == "--" or options[flag] ~= nil then
			return nil, "missing value or repeated argument: " .. flag
		end
		options[flag] = value
	end
	if not cliutil.isValidKey(options["--pack"] or "") then
		return nil, "invalid or missing pack slug"
	end
	if options["--target"] ~= nil and not table.find(qualityprofile.TIERS, options["--target"] :: any) then
		return nil, "unsupported target"
	end
	if options["--evidence"] ~= nil and options["--sweep"] ~= nil then
		return nil, "--evidence and --sweep are mutually exclusive"
	end
	return options, nil
end

function M.checkPacksRoot(options: { [string]: string }, environment: { [string]: string }): string
	return options["--packs-root"] or environment.FORGE_QUALITY_PACKS_ROOT or "games"
end

-- ---------------------------------------------------------------------------
-- Evidence receipts: what Forge can honestly record for a generated pack
-- ---------------------------------------------------------------------------

local function ensureDir(path: string)
	local segments: { string } = {}
	for segment in string.gmatch(path, "[^/]+") do
		table.insert(segments, segment)
	end
	local current = ""
	for _, segment in segments do
		current = if current == "" then segment else current .. "/" .. segment
		if not fs.isDir(current) then
			fs.writeDir(current)
		end
	end
end

--- Reads a pack's declared profile. Returns (profile, nil) or (nil, errors).
function M.readProfile(packDir: string): (qualityprofile.Profile?, { string })
	local path = packDir .. "/quality.yml"
	if not fs.isFile(path) then
		return nil, { path .. ": missing quality profile" }
	end
	local ok, document = pcall(function()
		return serde.decode("yaml", fs.readFile(path))
	end)
	if not ok then
		return nil, { path .. ": failed to decode: " .. tostring(document) }
	end
	local profile, errors = qualityprofile.parse(document)
	if profile == nil then
		return nil, errors
	end
	return profile, {}
end

--- Turns a sweep variant's own report into the evidence receipt for the pack's
--- declared tier. Every column verdict comes from the sweep's own steps, so the
--- receipt restates evidence the same run produced and never invents one.
--- `optional` carries the mechanical capture/AV evidence a caller supplied; an
--- absent one is recorded as absent with a reason, never inferred.
function M.evidenceFor(report: any, profile: qualityprofile.Profile, optional: any?): any
	local steps = if type(report.steps) == "table" then report.steps else {}
	local columns: { [string]: any } = {}
	for _, name in qualityevidence.REQUIRED_COLUMNS do
		local step = steps[name]
		columns[name] = {
			ok = step ~= nil and step.ok == true,
			error = if step ~= nil then step.error else "step not recorded",
		}
	end
	local nativeStep = steps.nativeQa
	local loadStep = steps.load
	local captures = if optional ~= nil and optional.captures ~= nil
		then optional.captures
		else {
			present = false,
			reason = "the sweep runs headless; a Studio capture run records its manifest separately",
		}
	local av = if optional ~= nil and optional.av ~= nil
		then optional.av
		else { present = false, reason = "no captured session in a headless sweep" }
	return qualityevidence.build({
		pack = report.slug,
		tier = profile.tier,
		profileDigest = qualityevidence.profileDigest(profile),
		columns = columns,
		captures = captures,
		av = av,
		nativeQa = {
			ran = if nativeStep ~= nil then nativeStep.ran else 0,
			passed = if nativeStep ~= nil then nativeStep.passed else 0,
			skipped = nativeStep ~= nil and nativeStep.skipped == true,
		},
		load = {
			ok = loadStep ~= nil and loadStep.ok == true,
			actors = if loadStep ~= nil then loadStep.actors else 0,
			actions = if loadStep ~= nil then loadStep.actions else 0,
			runtime = if loadStep ~= nil then loadStep.runtime else nil,
		},
	})
end

--- The mechanical summary of a Studio capture run for `pack`, read from a visual
--- run directory that holds `runs/<pack>/receipt.json`. The visual-content gate
--- result is recorded as the mechanical fact it is (a frame was not uniform);
--- nothing here is a judgment about whether the game looks good.
function M.captureEvidence(dir: string, pack: string): (any?, string?)
	local path = dir .. "/runs/" .. pack .. "/receipt.json"
	if not fs.isFile(path) then
		return nil, path .. ": no capture receipt for this pack"
	end
	local ok, receipt = pcall(function()
		return serde.decode("json", fs.readFile(path))
	end)
	if not ok or type(receipt) ~= "table" then
		return nil, path .. ": capture receipt does not decode"
	end
	local outcome = if type(receipt.outcome) == "table" then receipt.outcome else receipt
	local captures = if type(outcome.captures) == "table" then outcome.captures else {}
	local verdicts: { [string]: number } = {}
	local minimum = math.huge
	for _, capture in captures do
		local content = if type(capture) == "table" then capture.visualContent else nil
		if type(content) == "table" then
			local verdict = tostring(content.verdict)
			verdicts[verdict] = (verdicts[verdict] or 0) + 1
			if type(content.meanDetail) == "number" and content.meanDetail < minimum then
				minimum = content.meanDetail
			end
		end
	end
	local inconclusive = if type(outcome.inconclusive) == "table" then #outcome.inconclusive else 0
	return {
		present = true,
		source = path,
		digest = qualityevidence.digest(receipt),
		captures = #captures,
		visualContent = {
			-- The gate's own verdicts, never a quality score: `varied` says the frame
			-- was not uniform, which is all this evidence can support.
			verdicts = verdicts,
			minMeanDetail = if minimum ~= math.huge then minimum else nil,
			inconclusive = inconclusive,
		},
	},
		nil
end

--- The mechanical summary of an AV source receipt: the captured container, its
--- bytes and the session it belongs to. Audio and motion quality stay a human
--- judgment; this records only that the acquisition happened.
function M.avEvidence(path: string): (any?, string?)
	if not fs.isFile(path) then
		return nil, path .. ": no AV source receipt"
	end
	local ok, document = pcall(function()
		return serde.decode("json", fs.readFile(path))
	end)
	if not ok or type(document) ~= "table" then
		return nil, path .. ": AV source receipt does not decode"
	end
	local original = if type(document.original) == "table" then document.original else nil
	return {
		present = true,
		source = path,
		digest = qualityevidence.digest(document),
		sessionId = document.sessionId,
		buildIdentity = document.buildIdentity,
		tracks = document.tracks,
		original = if original ~= nil
			then { path = original.path, sha256 = original.sha256, byteLength = original.byteLength }
			else nil,
	},
		nil
end

--- The sweep variant report for `pack`, read from a sweep output directory.
function M.sweepReport(sweepDir: string, pack: string): (any?, string?)
	local path = sweepDir .. "/sweep.json"
	if not fs.isFile(path) then
		return nil, path .. ": missing sweep report"
	end
	local ok, decoded = pcall(function()
		return serde.decode("json", fs.readFile(path))
	end)
	if not ok or type(decoded) ~= "table" or type(decoded.genres) ~= "table" then
		return nil, path .. ": invalid sweep report"
	end
	for _, report in decoded.genres do
		if type(report) == "table" and report.slug == pack then
			return report, nil
		end
	end
	return nil, "the sweep report carries no variant for pack '" .. pack .. "'"
end

--- The declared tier plus the receipt a sweep report implies, or the errors
--- that stop one being recorded.
--- The declared tier plus the receipt a sweep report implies, or the errors
--- that stop one being recorded. `optional` carries the mechanical capture/AV
--- evidence a caller supplied.
function M.buildEvidence(packDir: string, report: any, optional: any?): (any?, qualityprofile.Profile?, { string })
	local profile, profileErrors = M.readProfile(packDir)
	if profile == nil then
		return nil, nil, profileErrors
	end
	local receipt = M.evidenceFor(report, profile, optional)
	local errors = qualityevidence.validate(receipt, profile)
	if #errors > 0 then
		return nil, profile, errors
	end
	return receipt, profile, {}
end

--- `forge quality evaluate --pack <slug> --sweep <dir> [--out <path>]`: builds
--- the evidence receipt for a sweep pack from the sweep's own columns and load
--- proof, validates it against the declared tier, and writes it.
local function runEvaluateSweep(args: { string }): boolean
	local options: { [string]: string } = {}
	for index = 3, #args, 2 do
		local flag, value = args[index], args[index + 1]
		if
			flag ~= "--pack"
			and flag ~= "--sweep"
			and flag ~= "--out"
			and flag ~= "--packs-root"
			and flag ~= "--captures"
			and flag ~= "--av"
		then
			stdio.ewrite("unknown quality evaluate argument: " .. tostring(flag) .. NL)
			return false
		end
		if value == nil or value == "" or string.sub(value, 1, 2) == "--" or options[flag] ~= nil then
			stdio.ewrite("missing value or repeated argument: " .. tostring(flag) .. NL)
			return false
		end
		options[flag] = value
	end
	local pack = options["--pack"]
	if not cliutil.isValidKey(pack or "") or options["--sweep"] == nil then
		stdio.ewrite("quality evaluate: --pack and --sweep are required" .. NL)
		return false
	end
	local report, reason = M.sweepReport(options["--sweep"], pack :: string)
	if report == nil then
		stdio.ewrite("quality evaluate: " .. tostring(reason) .. NL)
		return false
	end
	local packDir = if type(report.packDir) == "string" and report.packDir ~= ""
		then report.packDir
		else M.checkPacksRoot(options, process.env) .. "/" .. (pack :: string)
	-- Optional mechanical evidence, read only when the caller names it. A named
	-- artifact that cannot be read is an error, not a silent absence.
	local optional: any = nil
	if options["--captures"] ~= nil then
		local captures, captureReason = M.captureEvidence(options["--captures"], pack :: string)
		if captures == nil then
			stdio.ewrite("quality evaluate: " .. tostring(captureReason) .. NL)
			return false
		end
		optional = { captures = captures }
	end
	if options["--av"] ~= nil then
		local av, avReason = M.avEvidence(options["--av"])
		if av == nil then
			stdio.ewrite("quality evaluate: " .. tostring(avReason) .. NL)
			return false
		end
		optional = if optional == nil then { av = av } else optional
		optional.av = av
	end
	local receipt, profile, errors = M.buildEvidence(packDir, report, optional)
	if receipt == nil then
		stdio.ewrite("quality evaluate: EVIDENCE_INVALID" .. NL .. table.concat(errors, NL) .. NL)
		return false
	end
	local out = options["--out"] or (options["--sweep"] .. "/quality/" .. (pack :: string) .. ".json")
	ensureDir(string.match(out, "^(.*)/[^/]+$") or ".")
	fs.writeFile(out, serde.encode("json", receipt, true) .. NL)
	stdio.write(
		string.format(
			"quality evaluate: EVIDENCE_VALID (%s, tier=%s, receipt=%s); fun/visual remain %s%s",
			pack,
			(profile :: qualityprofile.Profile).tier,
			out,
			qualityevidence.PENDING,
			NL
		)
	)
	return true
end

--- `forge quality check --pack <slug> --evidence <path>` (or `--sweep <dir>`):
--- validates an evidence receipt against the pack's declared tier. It never
--- grants release approval and never approves fun or visual quality.
local function runCheckEvidence(options: { [string]: string }): boolean
	local pack = options["--pack"]
	local packDir = M.checkPacksRoot(options, process.env) .. "/" .. pack
	local report: any = nil
	if options["--sweep"] ~= nil then
		local found, reason = M.sweepReport(options["--sweep"], pack)
		if found == nil then
			stdio.ewrite("quality check: " .. tostring(reason) .. NL)
			return false
		end
		report = found
		if type(found.packDir) == "string" and found.packDir ~= "" then
			packDir = found.packDir
		end
	end
	local profile, profileErrors = M.readProfile(packDir)
	if profile == nil then
		stdio.ewrite("quality check: " .. table.concat(profileErrors, NL) .. NL)
		return false
	end
	local document: any = nil
	if report ~= nil then
		document = M.evidenceFor(report, profile)
	else
		local ok, decoded = pcall(function()
			return serde.decode("json", fs.readFile(options["--evidence"]))
		end)
		if not ok then
			stdio.ewrite("quality check: " .. options["--evidence"] .. ": failed to decode" .. NL)
			return false
		end
		document = decoded
	end
	local errors = qualityevidence.validate(document, profile)
	if #errors > 0 then
		stdio.ewrite("quality check: EVIDENCE_INVALID" .. NL .. table.concat(errors, NL) .. NL)
		return false
	end
	if options["--out"] ~= nil and report ~= nil then
		ensureDir(string.match(options["--out"], "^(.*)/[^/]+$") or ".")
		fs.writeFile(options["--out"], serde.encode("json", document, true) .. NL)
	end
	stdio.write(
		string.format(
			"quality check: EVIDENCE_VALID (%s, tier=%s, human judgment=%s, releaseApproved=false)%s",
			pack,
			profile.tier,
			qualityevidence.PENDING,
			NL
		)
	)
	return true
end

local function runCheck(args: { string }): boolean
	local options, reason = M.parseCheckArgs(args)
	if options == nil then
		stdio.ewrite(tostring(reason) .. NL)
		return false
	end
	if options["--evidence"] ~= nil or options["--sweep"] ~= nil then
		return runCheckEvidence(options)
	end
	local target: qualityprofile.Tier? = nil
	if options["--target"] == "starter" then
		target = "starter"
	elseif options["--target"] == "vertical-slice" then
		target = "vertical-slice"
	elseif options["--target"] == "release-candidate" then
		target = "release-candidate"
	end
	local result = qualitygate.check({
		pack = options["--pack"],
		packDir = M.checkPacksRoot(options, process.env) .. "/" .. options["--pack"],
		receiptPath = options["--receipt"],
		target = target,
		authority = {
			identity = process.env.FORGE_QUALITY_EVALUATOR or "",
			attestationPath = process.env.FORGE_QUALITY_ATTESTATION or "",
		},
	})
	local message = "quality check: " .. result.code .. NL
	if result.ok then
		stdio.write(message)
	else
		stdio.ewrite(message .. table.concat(result.errors, NL) .. NL)
	end
	return result.ok
end

function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local sub = args[2]
	if sub == "evaluate" then
		if table.find(args, "--sweep") ~= nil then
			return runEvaluateSweep(args)
		end
		return require("../lib/qualityevaluate").run(args)
	end
	if sub == "check" then
		return runCheck(args)
	end
	if sub == "validate" then
		return runValidate(args, context)
	end
	stdio.ewrite("Error: forge quality requires 'validate', 'evaluate' or 'check'" .. NL)
	return false
end

return M
