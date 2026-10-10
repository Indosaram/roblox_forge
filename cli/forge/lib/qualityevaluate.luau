--!strict
-- Serializes supplied, attested judgments; never invents a score or an attestation.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local qualityprofile = require("./qualityprofile")
local qualityreceipt = require("./qualityreceipt")
local qastudio = require("./qastudio")
local Validation = require("../../../core/domain/genre/Validation")
local M = {}

export type Result = { ok: boolean, code: string, errors: { string }, receipt: any? }
export type Options = { [string]: string }

local function text(value: any): boolean
	return type(value) == "string" and string.find(value, "%S") ~= nil
end

local function list(value: any): boolean
	return Validation.dense(value, 4096) and #value > 0
end

local function member(paths: { string }, path: any): boolean
	return type(path) == "string" and table.find(paths, path) ~= nil
end

-- Observations use the existing receipt shape, extended only inside review.
-- Every goal cites a captured scenario step, and carries the exact profile
-- description/deadline/player bound. This is an audit boundary, not proof that
-- a human's interpretation was true; the configured evaluator attests to it.
function M.validateObservations(
	profile: qualityprofile.Profile,
	input: qualityreceipt.Inputs,
	candidate: any
): { string }
	local errors: { string } = {}
	local function demand(condition: boolean, message: string)
		if not condition then
			table.insert(errors, message)
		end
	end
	if type(candidate) ~= "table" or type(candidate.review) ~= "table" then
		return { "MISSING_OBSERVATIONS" }
	end
	local review = candidate.review
	for _, defect in profile.reference.disqualifiers do
		local observation = if type(review.disqualifiers) == "table" then review.disqualifiers[defect] else nil
		demand(
			type(observation) == "table" and observation.present == false and text(observation.rationale),
			"UNASSESSED_DISQUALIFIER: " .. defect
		)
	end
	demand(qualityreceipt.digest(candidate.inputs) == qualityreceipt.digest({
		buildPath = input.buildPath,
		evidenceDir = input.evidenceDir,
		evidence = input.evidence,
	}), "INPUT_BINDING_MISMATCH")
	local scenarios: { [string]: any } = {}
	for _, path in input.evidence.scenarios do
		local ok, document = pcall(function()
			return serde.decode("json", fs.readFile(input.root .. "/" .. path))
		end)
		if not ok or type(document) ~= "table" or document.mode ~= "studio" or type(document.outcome) ~= "table" then
			table.insert(errors, "INVALID_SCENARIO: " .. path)
			continue
		end
		local outcome = document.outcome
		if
			outcome.ok ~= true
			or outcome.kind ~= "studio"
			or type(outcome.blockers) ~= "table"
			or next(outcome.blockers) ~= nil
		then
			table.insert(errors, "FAILED_SCENARIO: " .. path)
			continue
		end
		if
			not list(outcome.steps)
			or not list(outcome.inputs)
			or not list(outcome.calls)
			or not list(outcome.captures)
		then
			table.insert(errors, "MISSING_CAPTURED_ACTIONS: " .. path)
			continue
		end
		scenarios[path] = outcome
	end
	-- Surface dimensions and actor identities are explicit evaluator observations,
	-- linked to the runner's actual captures, not inferred from a filename.
	local surfaces: { [string]: boolean } = {}
	local actors: { [string]: boolean } = {}
	if not list(review.surfaces) then
		table.insert(errors, "MISSING_SURFACE_OBSERVATIONS")
	else
		for _, observed in review.surfaces do
			if type(observed) ~= "table" then
				table.insert(errors, "INVALID_SURFACE_OBSERVATION")
				continue
			end
			local outcome = scenarios[observed.scenario]
			local found = false
			if outcome then
				for _, capture in outcome.captures do
					if
						type(capture) == "table"
						and capture.path == observed.capture
						and capture.actor == observed.actor
						and text(capture.studio_id)
						and capture.studio_id == observed.studio_id
						and observed.captureSchemaVersion == qastudio.CAPTURE_SCHEMA_VERSION
						and observed.geometryDigest == qualityreceipt.digest({
							device = capture.device,
							logical = capture.logical,
							raster = capture.raster,
							logicalToRaster = capture.logicalToRaster,
							criticalUI = capture.criticalUI,
						})
						and member(input.evidence.captures, capture.path)
					then
						local bytes = fs.readFile(input.root .. "/" .. capture.path)
						found = capture.sha256 == serde.hash("sha256", bytes)
							and qastudio.validateCapture(capture, bytes, observed.surface)
					end
				end
			end
			local valid = text(observed.actor) and member(input.evidence.captures, observed.capture) and found
			demand(valid, "SURFACE_CAPTURE_MISMATCH")
			if valid then
				surfaces[observed.surface] = true
				actors[observed.actor] = true
			end
		end
	end
	demand(surfaces.desktop == true and surfaces.mobile == true, "MISSING_DESKTOP_MOBILE")
	local actorCount = 0
	for _ in actors do
		actorCount += 1
	end
	demand(actorCount >= 2, "MISSING_TWO_ACTORS")
	for _, criterion in profile.criteria do
		local observed = if type(review.criteria) == "table" then review.criteria[criterion.id] else nil
		if type(observed) ~= "table" then
			table.insert(errors, "MISSING_CRITERION: " .. criterion.id)
			continue
		end
		demand(observed.anchorsDigest == qualityreceipt.digest(criterion), "ANCHOR_MISMATCH: " .. criterion.id)
		local compared: { [string]: boolean } = {}
		if list(observed.comparisons) then
			for _, pair in observed.comparisons do
				if type(pair) ~= "table" then
					table.insert(errors, "INVALID_REFERENCE_PAIR: " .. criterion.id)
					continue
				end
				local found = false
				for _, exemplar in profile.reference.exemplars do
					if exemplar.path == pair.reference and exemplar.surface == pair.surface then
						found = true
					end
				end
				local captured = false
				for _, surface in review.surfaces or {} do
					if
						type(surface) == "table"
						and surface.surface == pair.surface
						and surface.capture == pair.capture
					then
						captured = true
					end
				end
				local valid = found
					and captured
					and member(input.evidence.captures, pair.capture)
					and text(pair.rationale)
				if valid then
					local referenceDigest = serde.hash("sha256", fs.readFile(input.root .. "/" .. pair.reference))
					local captureDigest = serde.hash("sha256", fs.readFile(input.root .. "/" .. pair.capture))
					local independent = referenceDigest ~= captureDigest
					demand(independent, "SELF_REFERENCE: " .. criterion.id)
					valid = independent
				end
				demand(valid, "INVALID_REFERENCE_PAIR: " .. criterion.id)
				if valid then
					compared[pair.surface] = true
				end
			end
		end
		demand(compared.desktop == true and compared.mobile == true, "MISSING_REFERENCE_PAIRS: " .. criterion.id)
	end
	for _, goal in profile.firstPlayGoals do
		local observed = if type(review.goals) == "table" then review.goals[goal.id] else nil
		if type(observed) ~= "table" then
			table.insert(errors, "MISSING_GOAL: " .. goal.id)
			continue
		end
		demand(observed.goalDigest == qualityreceipt.digest(goal), "GOAL_BINDING_MISMATCH: " .. goal.id)
		local outcome = scenarios[observed.evidence]
		local recorded = if outcome
				and type(outcome.firstPlay) == "table"
				and type(outcome.firstPlay.goals) == "table"
			then outcome.firstPlay.goals[goal.id]
			else nil
		demand(type(recorded) == "table" and qualityreceipt.digest(recorded) == qualityreceipt.digest({
			goalDigest = observed.goalDigest,
			actors = observed.actors,
			step = observed.step,
			elapsedSeconds = observed.elapsedSeconds,
			observation = observed.observation,
			unprompted = observed.unprompted,
			shortcut = observed.shortcut,
		}), "GOAL_CAPTURE_MISMATCH: " .. goal.id)
		local seen: { [string]: boolean } = {}
		local count = 0
		if list(observed.actors) then
			for _, actor in observed.actors do
				local inScenario = false
				for _, capture in if outcome then outcome.captures else {} do
					if type(capture) == "table" and capture.actor == actor then
						inScenario = true
					end
				end
				if type(actor) == "string" and actors[actor] and inScenario and not seen[actor] then
					seen[actor] = true
					count += 1
				else
					table.insert(errors, "INVALID_GOAL_ACTOR: " .. goal.id)
				end
			end
		end
		demand(count == observed.players and count >= (goal.players or 1), "GOAL_ACTOR_COUNT: " .. goal.id)
		local steps = outcome and outcome.steps
		local step = if type(steps) == "table" and Validation.finite(observed.step) then steps[observed.step] else nil
		demand(type(step) == "table" and step.index == observed.step, "MISSING_GOAL_STEP: " .. goal.id)
		demand(
			text(observed.observation) and observed.unprompted == true and observed.shortcut == false,
			"MISSING_FIRSTPLAY_OBSERVATION: " .. goal.id
		)
		demand(
			Validation.finite(observed.elapsedSeconds)
				and observed.elapsedSeconds >= 0
				and observed.minutes == observed.elapsedSeconds / 60,
			"GOAL_TIME_MISMATCH: " .. goal.id
		)
	end
	local fun = review.fun
	demand(
		type(fun) == "table"
			and text(fun.limits)
			and member(input.evidence.actions, fun.actions)
			and member(input.evidence.audio, fun.audio),
		"MISSING_FUN_ACTION_AUDIO"
	)
	local heard = false
	for _, outcome in scenarios do
		for _, audio in outcome.audio or {} do
			if
				type(audio) == "table"
				and type(fun) == "table"
				and audio.path == fun.audio
				and member(input.evidence.audio, audio.path)
			then
				heard = audio.sha256 == serde.hash("sha256", fs.readFile(input.root .. "/" .. audio.path))
			end
		end
	end
	demand(heard, "MISSING_CAPTURED_AUDIO")
	return errors
end

-- The adapter gets the actual bytes, not merely filenames or a success claim.
-- Its stdout is an existing-schema receipt; it must independently provide the
-- configured attestation file. This module never writes that authority file.
function M.invokeEvaluator(
	profile: qualityprofile.Profile,
	input: qualityreceipt.Inputs,
	executable: string,
	reference: any
): any
	assert(text(executable), "MISSING_EVALUATOR_EXECUTABLE")
	local snapshot, reason = qualityreceipt.snapshot(profile, input)
	assert(snapshot, reason)
	local artifacts: { [string]: { number } } = {}
	local function collect(path: string)
		local bytes = fs.readFile(input.root .. "/" .. path)
		local encoded: { number } = table.create(#bytes)
		for index = 1, #bytes do
			encoded[index] = string.byte(bytes, index)
		end
		artifacts[path] = encoded
	end
	for _, exemplar in profile.reference.exemplars do
		collect(exemplar.path)
	end
	local evidenceLists: { { string } } = {
		input.evidence.captures,
		input.evidence.actions,
		input.evidence.audio,
		input.evidence.scenarios,
		input.evidence.audiovisual or {},
		input.evidence.avArtifacts or {},
		input.evidence.reference or {},
		input.evidence.referenceArtifacts or {},
		input.evidence.rejoin or {},
		input.evidence.rejoinArtifacts or {},
	}
	for _, paths in evidenceLists do
		for _, path in paths do
			collect(path)
		end
	end
	local arguments = if process.env.FORGE_QUALITY_EVALUATOR_ARGS
		then serde.decode("json", process.env.FORGE_QUALITY_EVALUATOR_ARGS)
		else {}
	assert(Validation.dense(arguments, 16), "INVALID_EVALUATOR_ARGS")
	for _, argument in arguments do
		assert(type(argument) == "string", "INVALID_EVALUATOR_ARG")
	end
	local response = process.exec(executable, arguments, {
		stdio = {
			stdin = serde.encode("json", {
				schemaVersion = qualityreceipt.SCHEMA_VERSION,
				buildIdentity = serde.decode(
					"json",
					fs.readFile(input.root .. "/" .. input.buildPath .. ".identity.json")
				).identity,
				captureSchemaVersion = qastudio.CAPTURE_SCHEMA_VERSION,
				profile = profile,
				reference = reference,
				snapshot = snapshot,
				inputs = { buildPath = input.buildPath, evidenceDir = input.evidenceDir, evidence = input.evidence },
				artifactBytes = artifacts,
			}),
		},
	})
	assert(response.ok, "EVALUATOR_FAILED: " .. response.stderr)
	return serde.decode("json", response.stdout)
end

-- Candidate is the exact receipt the evaluator has attested to. Returning it
-- unchanged preserves compatibility with qualitygate and its digest contract.
function M.evaluate(
	profile: qualityprofile.Profile,
	input: qualityreceipt.Inputs,
	candidate: any,
	authority: qualityreceipt.Authority,
	target: qualityprofile.Tier?
): Result
	local ok, result = pcall(function(): Result
		local checked = qualityreceipt.check(profile, input, candidate, authority, target)
		if not checked.ok then
			return { ok = checked.ok, code = checked.code, errors = checked.errors }
		end
		local errors = M.validateObservations(profile, input, candidate)
		if #errors > 0 then
			return { ok = false, code = "INVALID_OBSERVATIONS", errors = errors }
		end
		return { ok = true, code = "APPROVED", errors = {}, receipt = candidate }
	end)
	if not ok then
		return { ok = false, code = "EVALUATION_FAILED", errors = { tostring(result) } }
	end
	return result
end

function M.parseArgs(args: { string }): (Options?, string?)
	local options: Options = {}
	for index = 3, #args, 2 do
		local flag, value = args[index], args[index + 1]
		if not table.find({ "--pack", "--capture", "--reference", "--out", "--observations" }, flag) then
			return nil, "unknown quality evaluate argument: " .. flag
		end
		if not text(value) or string.sub(value, 1, 2) == "--" or options[flag] ~= nil then
			return nil, "missing value or repeated argument: " .. flag
		end
		options[flag] = value
	end
	for _, flag in { "--pack", "--capture", "--reference", "--out" } do
		if options[flag] == nil then
			return nil, "missing " .. flag
		end
	end
	if not string.match(options["--pack"], "^[a-z][a-z0-9%-]*$") then
		return nil, "invalid pack slug"
	end
	return options, nil
end

function M.run(args: { string }): boolean
	local options, reason = M.parseArgs(args)
	if options == nil then
		stdio.ewrite(tostring(reason) .. "\n")
		return false
	end
	local ok, result = pcall(function(): Result
		local packDir = "games/" .. options["--pack"]
		local document = serde.decode("yaml", fs.readFile(packDir .. "/quality.yml"))
		local profile, errors = qualityprofile.parse(document)
		assert(profile, table.concat(errors, "; "))
		assert(profile.pack == options["--pack"], "pack mismatch")
		local reference = serde.decode("yaml", fs.readFile(options["--reference"]))
		assert(
			qualityreceipt.digest(reference) == qualityreceipt.digest(document.reference),
			"reference declaration mismatch"
		)
		local manifest = serde.decode("json", fs.readFile(options["--capture"] .. "/manifest.json"))
		local input: qualityreceipt.Inputs = {
			root = ".",
			packDir = packDir,
			buildPath = manifest.buildPath,
			receiptPath = options["--out"],
			evidenceDir = options["--capture"],
			evidence = manifest.evidence,
		}
		assert(not fs.isFile(input.receiptPath), "output exists; select a new receipt path")
		local candidate = if options["--observations"]
			then serde.decode("json", fs.readFile(options["--observations"]))
			else M.invokeEvaluator(profile, input, process.env.FORGE_QUALITY_EVALUATOR_EXECUTABLE or "", reference)
		local evaluated = M.evaluate(profile, input, candidate, {
			identity = process.env.FORGE_QUALITY_EVALUATOR or "",
			attestationPath = process.env.FORGE_QUALITY_ATTESTATION or "",
		})
		if evaluated.ok then
			assert(not fs.isFile(input.receiptPath), "output exists; select a new receipt path")
			fs.writeFile(input.receiptPath, serde.encode("json", evaluated.receipt, true) .. "\n")
		end
		return evaluated
	end)
	if not ok then
		stdio.ewrite("quality evaluate: FAIL " .. tostring(result) .. "\n")
		return false
	end
	if not result.ok then
		stdio.ewrite("quality evaluate: " .. result.code .. "\n" .. table.concat(result.errors, "\n") .. "\n")
	else
		stdio.write("quality evaluate: APPROVED (supplied attested observations; no population-retention claim)\n")
	end
	return result.ok
end

return M
