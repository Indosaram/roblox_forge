--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local profileLib = require("./qualityprofile")
local receipt = require("./qualityreceipt")
local evaluate = require("./qualityevaluate")
local Png = require("./png")
local Pixels = require("../../../core/domain/procgen/Pixels")

return {
	["rejoin documents cannot be reused as first play scenarios"] = function()
		local input: receipt.Inputs = {
			root = ".",
			packDir = "pack",
			buildPath = "build",
			receiptPath = "e/receipt",
			evidenceDir = "e",
			evidence = {
				captures = {},
				actions = {},
				audio = {},
				scenarios = { "e/rejoin" },
				rejoin = { "e/rejoin" },
				rejoinArtifacts = {},
			},
		}
		local admitted, detail = receipt.validateRejoin(input, { review = {} })
		assert(
			not admitted and string.find(tostring(detail), "REJOIN_FIRSTPLAY_SEPARATION", 1, true),
			'not admitted and string.find(tostring(detail), "REJOIN_FIRSTPLAY_SEPARATION", 1, true)'
		)
	end,
	["standalone audio and image observations cannot replace audiovisual admission"] = function()
		local input: receipt.Inputs = {
			root = ".",
			packDir = "pack",
			buildPath = "build.rbxl",
			receiptPath = "e/receipt.json",
			evidenceDir = "e",
			evidence = { captures = {}, actions = {}, audio = { "separate.wav" }, scenarios = {} },
		}
		local ok, reason = receipt.validateAudiovisual(
			input,
			{ review = { audiovisual = { verdict = "approved", observations = {} } } }
		)
		assert(
			not ok and string.find(tostring(reason), "AV_EVIDENCE_REQUIRED", 1, true),
			'not ok and string.find(tostring(reason), "AV_EVIDENCE_REQUIRED", 1, true)'
		)
	end,
	["captured observations bind distinct actors dimensions goal time and criterion anchors"] = function()
		local root = ".omo/fixtures/quality-evaluate-observations"
		assert(not fs.isDir(root), "fixture already exists")
		fs.writeDir(root)
		local ok, reason = xpcall(function()
			fs.writeDir(root .. "/evidence")
			local profile =
				assert(profileLib.parse(serde.decode("yaml", fs.readFile("cli/forge/fixtures/quality-profile.yml"))))
			local bytes = buffer.tostring(Png.encode(Pixels.new(8, 6)))
			fs.writeDir(root .. "/reference")
			for _, exemplar in profile.reference.exemplars do
				exemplar.path = "reference/" .. exemplar.surface
				fs.writeFile(root .. "/" .. exemplar.path, "distinct benchmark fixture " .. exemplar.surface)
			end
			for _, name in { "desktop", "mobile", "audio", "actions" } do
				fs.writeFile(root .. "/evidence/" .. name, bytes)
			end
			local input: receipt.Inputs = {
				root = root,
				packDir = "pack",
				buildPath = "build.rbxl",
				receiptPath = "evidence/receipt.json",
				evidenceDir = "evidence",
				evidence = {
					captures = { "evidence/desktop", "evidence/mobile" },
					actions = { "evidence/actions" },
					audio = { "evidence/audio" },
					scenarios = { "evidence/scenario.json" },
				},
			}
			local outcome: any = {
				ok = true,
				kind = "studio",
				blockers = {},
				steps = { { index = 1, op = "expect_snapshot" } },
				inputs = { { fixture = true } },
				calls = { { fixture = true } },
				captures = {
					{
						path = "evidence/desktop",
						studio_id = "studio",
						actor = "actor-a",
						width = 1280,
						height = 720,
						sha256 = serde.hash("sha256", bytes),
					},
					{
						path = "evidence/mobile",
						studio_id = "studio",
						actor = "actor-b",
						width = 390,
						height = 844,
						sha256 = serde.hash("sha256", bytes),
					},
				},
				audio = { { path = "evidence/audio", sha256 = serde.hash("sha256", bytes) } },
				firstPlay = { goals = {} },
			}
			local review: any = {
				criteria = {},
				goals = {},
				disqualifiers = {},
				surfaces = {
					{
						surface = "desktop",
						width = 1280,
						height = 720,
						actor = "actor-a",
						studio_id = "studio",
						scenario = "evidence/scenario.json",
						capture = "evidence/desktop",
					},
					{
						surface = "mobile",
						width = 390,
						height = 844,
						actor = "actor-b",
						studio_id = "studio",
						scenario = "evidence/scenario.json",
						capture = "evidence/mobile",
					},
				},
				fun = { actions = "evidence/actions", audio = "evidence/audio", limits = "unit fixture only" },
			}
			for index, capture in outcome.captures do
				local observed = review.surfaces[index]
				capture.schemaVersion = 2
				capture.device = {
					id = "fixture",
					surface = observed.surface,
					width = capture.width,
					height = capture.height,
					scaling = "ActualResolution",
					form = if observed.surface == "mobile" then "Phone" else "Desktop",
					orientation = if observed.surface == "mobile" then "Portrait" else "LandscapeLeft",
				}
				capture.logical = {
					full = { x = 0, y = 0, width = 400.5, height = 800.5 },
					viewport = { x = 0, y = 20, width = 400.5, height = 760.5 },
					safeArea = { x = 0, y = 20, width = 400.5, height = 760.5 },
					insets = { left = 0, top = 20, right = 0, bottom = 20 },
				}
				capture.raster = { format = "png", width = 8, height = 6 }
				capture.logicalToRaster =
					{ origin = "full-screen", scaleX = 8 / 400.5, scaleY = 6 / 800.5, offsetX = 0, offsetY = 0 }
				capture.criticalUI = { { id = "action", x = 10, y = 30, width = 100, height = 50 } }
				capture.width, capture.height = nil, nil
				observed.width, observed.height = nil, nil
				observed.captureSchemaVersion = 2
				observed.geometryDigest = receipt.digest({
					device = capture.device,
					logical = capture.logical,
					raster = capture.raster,
					logicalToRaster = capture.logicalToRaster,
					criticalUI = capture.criticalUI,
				})
			end
			for _, defect in profile.reference.disqualifiers do
				review.disqualifiers[defect] = { present = false, rationale = "fixture" }
			end
			for _, criterion in profile.criteria do
				local comparisons = {}
				for _, exemplar in profile.reference.exemplars do
					table.insert(comparisons, {
						reference = exemplar.path,
						surface = exemplar.surface,
						capture = "evidence/" .. exemplar.surface,
						rationale = "fixture",
					})
				end
				review.criteria[criterion.id] = { anchorsDigest = receipt.digest(criterion), comparisons = comparisons }
			end
			for _, goal in profile.firstPlayGoals do
				local recorded = {
					goalDigest = receipt.digest(goal),
					actors = { "actor-a", "actor-b" },
					step = 1,
					elapsedSeconds = 60,
					observation = "fixture only",
					unprompted = true,
					shortcut = false,
				}
				outcome.firstPlay.goals[goal.id] = recorded
				local observed: any = table.clone(recorded)
				observed.evidence = "evidence/scenario.json"
				observed.players = 2
				observed.minutes = 1
				review.goals[goal.id] = observed
			end
			fs.writeFile(
				root .. "/evidence/scenario.json",
				serde.encode("json", { mode = "studio", outcome = outcome })
			)
			local candidate = {
				inputs = { buildPath = input.buildPath, evidenceDir = input.evidenceDir, evidence = input.evidence },
				review = review,
			}
			local function errors(): { string }
				return evaluate.validateObservations(profile, input, candidate)
			end
			assert(#errors() == 0, table.concat(errors(), "; "))
			outcome.captures[2].actor = "actor-a"
			review.surfaces[2].actor = "actor-a"
			fs.writeFile(
				root .. "/evidence/scenario.json",
				serde.encode("json", { mode = "studio", outcome = outcome })
			)
			assert(table.find(errors(), "MISSING_TWO_ACTORS"), "two viewports of one actor cannot prove cooperation")
			outcome.captures[2].actor = "actor-b"
			review.surfaces[2].actor = "actor-b"
			fs.writeFile(
				root .. "/evidence/scenario.json",
				serde.encode("json", { mode = "studio", outcome = outcome })
			)
			fs.writeFile(root .. "/reference/desktop", bytes)
			assert(
				table.find(errors(), "SELF_REFERENCE: legibility"),
				"renaming identical capture bytes cannot create a benchmark"
			)
			fs.writeFile(root .. "/reference/desktop", "distinct benchmark fixture desktop")
			review.surfaces[2].captureSchemaVersion = 1
			assert(table.find(errors(), "SURFACE_CAPTURE_MISMATCH"))
			review.surfaces[2].captureSchemaVersion = 2
			local geometryDigest = review.surfaces[2].geometryDigest
			review.surfaces[2].geometryDigest = "stale"
			assert(table.find(errors(), "SURFACE_CAPTURE_MISMATCH"))
			review.surfaces[2].geometryDigest = geometryDigest
			review.goals["shared-facility"].actors = { "actor-a", "actor-a" }
			assert(table.find(errors(), "INVALID_GOAL_ACTOR: shared-facility"))
			review.goals["shared-facility"].actors = { "actor-a", "actor-b" }
			review.goals["objective-identified"].elapsedSeconds = 59
			assert(table.find(errors(), "GOAL_CAPTURE_MISMATCH: objective-identified"))
			assert(table.find(errors(), "GOAL_TIME_MISMATCH: objective-identified"))
			review.goals["objective-identified"].elapsedSeconds = 60
			review.criteria.legibility.anchorsDigest = "stale"
			assert(table.find(errors(), "ANCHOR_MISMATCH: legibility"))
			review.criteria.legibility.anchorsDigest = receipt.digest(profile.criteria[1])
			fs.writeFile(root .. "/evidence/audio", "changed")
			assert(table.find(errors(), "MISSING_CAPTURED_AUDIO"))
		end, debug.traceback)
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
	["evaluate arguments require actual capture reference and output paths"] = function()
		assert(
			evaluate.parseArgs({ "quality", "evaluate", "--pack", "primal-isles" }) == nil,
			"missing capture, reference, and output must fail"
		)
		assert(evaluate.parseArgs({
			"quality",
			"evaluate",
			"--pack",
			"../other",
			"--capture",
			"e",
			"--reference",
			"r",
			"--out",
			"o",
		}) == nil, "unsafe pack slug must fail")
		assert(evaluate.parseArgs({
			"quality",
			"evaluate",
			"--pack",
			"primal-isles",
			"--capture",
			"e",
			"--reference",
			"r",
			"--out",
			"o",
			"--out",
			"x",
		}) == nil, "duplicate output argument must fail")
		local options = assert(evaluate.parseArgs({
			"quality",
			"evaluate",
			"--pack",
			"primal-isles",
			"--capture",
			"e",
			"--reference",
			"r",
			"--out",
			"o",
		}))
		assert(options["--reference"] == "r", "reference argument must be preserved")
	end,
	["missing structured captures never become a quality verdict"] = function()
		local profile =
			assert(profileLib.parse(serde.decode("yaml", fs.readFile("cli/forge/fixtures/quality-profile.yml"))))
		local input: receipt.Inputs = {
			root = ".",
			packDir = "cli/forge/fixtures",
			buildPath = "missing.rbxl",
			receiptPath = ".omo/evidence/quality-negative.json",
			evidenceDir = ".omo/evidence/missing-firstplay",
			evidence = { captures = {}, actions = {}, audio = {}, scenarios = {} },
		}
		local errors = evaluate.validateObservations(profile, input, { inputs = {}, review = {} })
		assert(table.find(errors, "INPUT_BINDING_MISMATCH"))
		assert(table.find(errors, "MISSING_DESKTOP_MOBILE"))
		assert(table.find(errors, "MISSING_TWO_ACTORS"))
		assert(table.find(errors, "MISSING_CAPTURED_AUDIO"))
		assert(table.find(errors, "MISSING_GOAL: objective-identified"))
		local failed = evaluate.evaluate(profile, input, { schemaVersion = 1 }, { identity = "", attestationPath = "" })
		assert(not failed.ok and failed.receipt == nil, "missing evidence must not produce an approved receipt")
	end,
	["bare passing scores cannot replace anchors or exact goals"] = function()
		local profile =
			assert(profileLib.parse(serde.decode("yaml", fs.readFile("cli/forge/fixtures/quality-profile.yml"))))
		local input: receipt.Inputs = {
			root = ".",
			packDir = "cli/forge/fixtures",
			buildPath = "missing.rbxl",
			receiptPath = ".omo/evidence/quality-negative.json",
			evidenceDir = ".omo/evidence/missing-firstplay",
			evidence = { captures = {}, actions = {}, audio = {}, scenarios = {} },
		}
		local review: any =
			{ criteria = {}, goals = {}, fun = { verdict = "approved", rationale = "fixture", confidence = "fixture" } }
		for _, criterion in profile.criteria do
			review.criteria[criterion.id] = { score = 5, rationale = "fixture" }
		end
		for _, goal in profile.firstPlayGoals do
			review.goals[goal.id] = { completed = true, minutes = 1, players = 2, elapsedSeconds = math.huge }
		end
		local errors = evaluate.validateObservations(profile, input, { inputs = {}, review = review })
		assert(table.find(errors, "ANCHOR_MISMATCH: legibility"))
		assert(table.find(errors, "MISSING_REFERENCE_PAIRS: legibility"))
		assert(table.find(errors, "GOAL_BINDING_MISMATCH: shared-facility"))
		assert(table.find(errors, "GOAL_CAPTURE_MISMATCH: shared-facility"))
		assert(table.find(errors, "GOAL_ACTOR_COUNT: shared-facility"))
		assert(table.find(errors, "GOAL_TIME_MISMATCH: shared-facility"))
	end,
	["inconclusive supplied evaluation remains failed without minting authority"] = function()
		local profile =
			assert(profileLib.parse(serde.decode("yaml", fs.readFile("cli/forge/fixtures/quality-profile.yml"))))
		local input: receipt.Inputs = {
			root = ".",
			packDir = "cli/forge/fixtures",
			buildPath = "missing.rbxl",
			receiptPath = ".omo/evidence/quality-negative.json",
			evidenceDir = ".omo/evidence/missing-firstplay",
			evidence = { captures = {}, actions = {}, audio = {}, scenarios = {} },
		}
		local result = evaluate.evaluate(profile, input, {
			schemaVersion = receipt.SCHEMA_VERSION,
			evaluator = "fixture",
			pack = profile.pack,
			scope = profile.tier,
			verdict = "inconclusive",
		}, { identity = "fixture", attestationPath = ".omo/evidence/nonexistent-attestation.json" })
		assert(
			not result.ok and result.code == "INCONCLUSIVE" and result.receipt == nil,
			"inconclusive observations must remain unapproved"
		)
	end,
}
