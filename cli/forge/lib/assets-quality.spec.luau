--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local qualityprofile = require("./qualityprofile")
local receipt = require("./qualityreceipt")
local assets = require("./assets")
local unit = require("../fixtures/quality-unit")(".omo/fixtures/task-3-native")
receipt, assets = unit.receipt, unit.assets
local function document(): any
	local criteria = {}
	for _, id in qualityprofile.CRITERIA do
		table.insert(criteria, { id = id, target = 4, anchors = { [1] = "blocked", [3] = "uneven", [5] = "clear" } })
	end
	local goals = {}
	for _, goal in qualityprofile.DEFAULT_FIRST_PLAY_GOALS do
		table.insert(goals, {
			id = goal.id,
			description = goal.description,
			within_minutes = goal.withinMinutes,
			players = goal.players,
		})
	end
	return {
		schema_version = 1,
		pack = "fixture-quality",
		tier = "vertical-slice",
		provisional_targets = true,
		evaluation_receipt = "evidence/receipt.json",
		reference = {
			name = "test reference",
			source = "first-party regression fixture",
			rights_holder = "Forge",
			capture_permission = "test owned",
			capture_date = "2026-10-02",
			rubric_version = "1",
			exemplars = {
				{ surface = "desktop", path = "reference/desktop" },
				{ surface = "mobile", path = "reference/mobile" },
			},
			disqualifiers = { "blocked" },
		},
		rubric = { version = "1", criteria = criteria },
		first_play = { goals = goals },
		asset_quality = {
			rights_source = "first-party",
			commercial_use = true,
			moderation = "not-applicable",
			platform_approved = false,
		},
		fun_verdict = { required = true, rationale_required = true, confidence_required = true },
	}
end

return {
	["asset approval uses the canonical attestation and binds each report"] = function()
		local root = ".omo/fixtures/task-3-native"
		assert(not fs.isDir(root), "fixture already exists")
		fs.writeDir(root)
		local ok, reason = xpcall(function()
			for _, dir in { "core", "genres", "cli", "skills", "pack/assets", "reference", "evidence" } do
				fs.writeDir(root .. "/" .. dir)
			end
			local doc = document()
			doc.reference.rubric_version, doc.rubric.version = "primal-independent-1", "primal-independent-1"
			for _, exemplar in doc.reference.exemplars do
				exemplar.path = "evidence/synthetic-reference-" .. exemplar.surface .. "-forward.png"
			end
			for path, bytes in
				{
					["pack/game.yml"] = "fixture",
					["pack/default.project.json"] = "{}",
					["pack/forge-lock.yml"] = "version: 1",
					["pack/quality.yml"] = serde.encode("yaml", doc),
					["pack/assets/model"] = "artifact",
					["reference/desktop"] = "desktop",
					["reference/mobile"] = "mobile",
					["evidence/capture"] = "capture",
					["evidence/actions"] = "actions",
					["evidence/audio"] = "audio",
					["evidence/scenario"] = "scenario",
					["build.rbxl"] = "native fixture",
				} :: { [string]: string }
			do
				fs.writeFile(root .. "/" .. path, bytes)
			end
			local digest = "sha256:" .. serde.hash("sha256", "artifact")
			local manifestDoc = {
				version = 2,
				assets = {
					{
						key = "model",
						kind = "model",
						tool = "forge-procgen",
						source = "fixture",
						path = "assets/model",
						provenance = {
							digest = digest,
							recipe = { id = "fixture", version = "1", input = "fixture", inputVersion = "1" },
							provider = { name = "forge-procgen", version = "1" },
							rights = { source = "first-party fixture", ownership = "first-party" },
						},
					},
				},
			}
			fs.writeFile(root .. "/pack/assets/manifest.yml", serde.encode("yaml", manifestDoc))
			local manifest = assert(assets.parseManifest(manifestDoc))
			local profile = assert(qualityprofile.parse(doc))
			local input: receipt.Inputs = {
				root = root,
				packDir = "pack",
				buildPath = "build.rbxl",
				receiptPath = "evidence/receipt.json",
				evidenceDir = "evidence",
				evidence = {
					captures = { "evidence/capture" },
					actions = { "evidence/actions" },
					audio = { "evidence/audio" },
					scenarios = { "evidence/scenario" },
				},
			}
			local report: any = {
				key = "model",
				digest = digest,
				verdict = "approved",
				evaluator = "fixture",
				report = "evidence/capture",
			}
			local review: any = {
				criteria = {},
				blockers = {},
				goals = {},
				fun = { verdict = "approved", rationale = "fixture", confidence = "fixture" },
				assets = { report },
			}
			for _, criterion in profile.criteria do
				review.criteria[criterion.id] = { score = 4, rationale = "fixture" }
			end
			for _, goal in profile.firstPlayGoals do
				review.goals[goal.id] = { completed = true, minutes = 1, players = 2, evidence = "evidence/scenario" }
			end
			local approved: any = {
				schemaVersion = receipt.SCHEMA_VERSION,
				captureSchemaVersion = 2,
				pack = profile.pack,
				scope = profile.tier,
				evaluator = "fixture",
				verdict = "approved",
				review = review,
			}
			approved.inputs =
				{ buildPath = input.buildPath, evidenceDir = input.evidenceDir, evidence = input.evidence }
			approved.buildIdentity = require("../fixtures/quality-runtime")(profile, input, review)
			require("../fixtures/quality-approval")(profile, input, approved)
			for _, validate in { receipt.validateRuntime, receipt.validateReference } do
				local valid, validationReason = validate(profile, input, approved)
				assert(valid, tostring(validationReason))
			end
			local references = assert(input.evidence.reference, "approval fixture must publish reference evidence")
			local referencePath = root .. "/" .. references[1]
			local originalReference = fs.readFile(referencePath)
			local reference = serde.decode("json", originalReference)
			local rubricPath = root .. "/" .. reference.rubric.path
			local originalRubric = fs.readFile(rubricPath)
			local originalReferenceDigest = review.referenceDigest
			local rubric = serde.decode("json", originalRubric)
			-- Lune's JSON decoder normalizes numeric-looking object keys to integers, so
			-- alter the anchor key that is actually present instead of a string twin that
			-- the encoder would drop and leave the shipped bytes unchanged.
			local anchorKey = next(rubric.criteria[1].anchors)
			assert(anchorKey ~= nil, "fixture rubric must carry anchors")
			rubric.criteria[1].anchors[anchorKey] = "altered anchor"
			local alteredRubric = serde.encode("json", rubric)
			assert(alteredRubric ~= originalRubric, "fixture tamper must change shipped bytes")
			fs.writeFile(rubricPath, alteredRubric)
			reference.rubric.sha256 = serde.hash("sha256", alteredRubric)
			fs.writeFile(referencePath, serde.encode("json", reference))
			review.referenceDigest = receipt.digest(reference)
			local acceptedTamper, tamperReason = receipt.validateReference(profile, input, approved)
			assert(
				not acceptedTamper and string.find(tostring(tamperReason), "REFERENCE_RUBRIC_MISMATCH", 1, true),
				"rehashed altered anchor refuses independently of stale evidence"
			)
			fs.writeFile(rubricPath, originalRubric)
			fs.writeFile(referencePath, originalReference)
			review.referenceDigest = originalReferenceDigest
			local restoredReference, restoredReason = receipt.validateReference(profile, input, approved)
			assert(restoredReference, tostring(restoredReason))
			local audiovisual, audiovisualReason = receipt.validateAudiovisual(input, approved)
			assert(audiovisual, tostring(audiovisualReason))
			approved.snapshot = assert(receipt.snapshot(profile, input))
			local originalCapture = fs.readFile(root .. "/evidence/capture")
			local authority = { identity = "fixture", attestationPath = root .. "/evidence/attestation.json" }
			local function attest()
				fs.writeFile(
					authority.attestationPath,
					serde.encode("json", {
						schemaVersion = receipt.SCHEMA_VERSION,
						evaluator = authority.identity,
						receiptDigest = receipt.digest(approved),
					})
				)
			end
			local function check(): assets.GateResult
				return assets.checkQuality(manifest, profile, input, approved, authority)
			end
			assert(not check().ok, "missing attestation fails")
			attest()
			local canonical = check()
			assert(canonical.ok, "canonical asset receipt passes: " .. table.concat(canonical.errors, "; "))
			for _, role in { "audiovisual", "reference" } do
				local evidenceLists: any = input.evidence
				local evidence = evidenceLists[role]
				evidenceLists[role] = nil
				approved.snapshot = assert(receipt.snapshot(profile, input))
				attest()
				local rejected = check()
				assert(
					not rejected.ok and table.find(rejected.errors, "INCONCLUSIVE"),
					"missing canonical evidence refuses: " .. role
				)
				evidenceLists[role] = evidence
			end
			approved.snapshot = assert(receipt.snapshot(profile, input))
			attest()
			assert(check().ok, "restoring canonical evidence restores asset admission")
			for _, name in { "synthetic-container.unit", "synthetic-reference-source.unit" } do
				local path = root .. "/evidence/" .. name
				local original = fs.readFile(path)
				fs.writeFile(path, original .. "changed")
				local rejected = check()
				assert(
					not rejected.ok and table.find(rejected.errors, "STALE_EVIDENCE"),
					"original byte mutation refuses"
				)
				fs.writeFile(path, original)
			end
			report.report = "missing.json"
			assert(not check().ok, "forged report cannot retain attestation")
			attest()
			assert(not check().ok, "attested report must reference bound evidence")
			report.report = "evidence/capture"
			for _, verdict in { "failed", "inconclusive" } do
				report.verdict = verdict
				attest()
				assert(not check().ok, "nonapproval rejected")
			end
			report.verdict = "approved"
			report.digest = "sha256:" .. string.rep("a", 64)
			attest()
			assert(not check().ok, "stale per-asset digest rejected")
			report.digest = digest
			report.reference = "wrong reference"
			attest()
			assert(not check().ok, "noncanonical reference rejected")
			report.reference = nil
			report.evaluator = "forged"
			attest()
			assert(not check().ok, "per-report evaluator must match attested identity")
			report.evaluator = "fixture"
			review.assets = {}
			attest()
			assert(not check().ok, "missing report rejected")
			review.assets = { report }
			attest()
			authority.identity = ""
			assert(not check().ok, "missing configured identity rejected")
			authority.identity = "fixture"
			fs.writeFile(root .. "/evidence/capture", "changed")
			assert(not check().ok, "stale report evidence rejected")
			fs.writeFile(root .. "/evidence/capture", originalCapture)
			fs.writeFile(root .. "/pack/assets/model", "changed")
			assert(not check().ok, "stale artifact rejected")
			fs.writeFile(root .. "/pack/assets/model", "artifact")
			manifest.assets[1].provenance = nil
			assert(not check().ok, "legacy artifact cannot inherit approval")
		end, debug.traceback)
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
}
