--!strict
-- UNIT DATA ONLY. These invented acquisition/listening/rights records exercise
-- structural admission; they are never real media, permission or release proof.
-- Only writes below the caller's owned .omo/fixtures directory.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local receipt = require("../lib/qualityreceipt")
local Png = require("../lib/png")
local Pixels = require("../../../core/domain/procgen/Pixels")

return function(profile: any, input: any, candidate: any)
	local directory = input.root .. "/" .. input.evidenceDir
	assert(
		string.find(directory, ".omo/fixtures/", 1, true),
		"synthetic approval requires owned unit fixture directory"
	)
	local function write(path: string, value: any): string
		local bytes = if type(value) == "string" then value else serde.encode("json", value)
		fs.writeFile(input.root .. "/" .. path, bytes)
		return bytes
	end
	local function clone(value: any): any
		return serde.decode("json", serde.encode("json", value))
	end
	local function path(name: string): string
		return input.evidenceDir .. "/synthetic-" .. name
	end
	local review = candidate.review
	local scenarioPath = input.evidence.scenarios[1]
	local scenario = serde.decode("json", fs.readFile(input.root .. "/" .. scenarioPath))
	local outcome = scenario.outcome
	outcome.inputs, outcome.calls = { { unitFixture = true } }, { { unitFixture = true } }
	local mobile = outcome.captures[2]
	if #input.evidence.captures < 2 then
		table.insert(input.evidence.captures, path("mobile.png"))
	end
	mobile.path = input.evidence.captures[2]
	write(mobile.path, fs.readFile(input.root .. "/" .. outcome.captures[1].path))
	mobile.device = {
		id = "synthetic-phone",
		surface = "mobile",
		width = 390,
		height = 844,
		form = "Phone",
		orientation = "Portrait",
		scaling = "ActualResolution",
	}
	review.surfaces = {}
	for _, capture in outcome.captures do
		table.insert(review.surfaces, {
			scenario = scenarioPath,
			capture = capture.path,
			actor = capture.actor,
			studio_id = capture.studio_id,
			surface = capture.device.surface,
			captureSchemaVersion = 2,
			geometryDigest = receipt.digest({
				device = capture.device,
				logical = capture.logical,
				raster = capture.raster,
				logicalToRaster = capture.logicalToRaster,
				criticalUI = capture.criticalUI,
			}),
		})
	end
	review.disqualifiers = {}
	for _, defect in profile.reference.disqualifiers do
		review.disqualifiers[defect] = { present = false, rationale = "synthetic unit observation" }
	end
	review.fun.actions, review.fun.audio, review.fun.limits =
		input.evidence.actions[1], input.evidence.audio[1], "synthetic unit data, no listening performed"
	outcome.audio = {
		{
			path = input.evidence.audio[1],
			sha256 = serde.hash("sha256", fs.readFile(input.root .. "/" .. input.evidence.audio[1])),
		},
	}

	-- AV records bind the existing runtime and action interval, without invoking
	-- a decoder/model or presenting these bytes as an actual recording.
	input.evidence.audiovisual, input.evidence.avArtifacts = { path("av.json") }, {}
	local function avWrite(name: string, value: any): string
		local target = path(name)
		write(target, value)
		table.insert(input.evidence.avArtifacts, target)
		return target
	end
	local originalBytes = "synthetic AV unit container; not playable media"
	local originalPath = avWrite("container.unit", originalBytes)
	local av: any = {
		schemaVersion = 1,
		scenario = scenarioPath,
		sessionId = outcome.runtime.server.sessionId,
		actorId = outcome.runtime.clients[1].actorId,
		studioId = outcome.runtime.clients[1].studio_id,
		buildIdentity = candidate.buildIdentity.id,
		processIdentity = "synthetic-process",
		recorderId = "synthetic-recorder",
		audioEndpoint = "synthetic-endpoint",
		videoSource = "synthetic-window",
		acquisitionDigest = "synthetic-acquisition",
		runSha256 = "synthetic-run",
		original = { path = originalPath, sha256 = serde.hash("sha256", originalBytes), byteLength = #originalBytes },
		tracks = { audio = 1, video = 0 },
		clock = {
			offsetSeconds = 0,
			rate = 1,
			uncertaintySeconds = 0,
			driftSeconds = 0,
			anchors = { { ptsSeconds = 0, actionSeconds = 0 }, { ptsSeconds = 60, actionSeconds = 60 } },
		},
		policy = { maxGapSeconds = 0, maxClockErrorSeconds = 0, intervals = {} },
		sourceReceipt = path("source.json"),
		decodeReport = path("decode.json"),
		listeningCapability = path("capability.json"),
		listeningReport = path("listening.json"),
	}
	local listening: any = {
		evaluator = candidate.evaluator,
		originalSha256 = av.original.sha256,
		tracks = av.tracks,
		verdict = "approved",
		deliveryEvidence = path("delivery.json"),
		intervals = {},
	}
	for _, cue in { "gather", "craft", "hit", "ambient" } do
		table.insert(
			av.policy.intervals,
			{ id = cue, cue = cue, step = 1, start = 0, ["end"] = 60, audioRequired = true, motion = true }
		)
		listening.intervals[cue] = {
			start = 0,
			finish = 60,
			heard = true,
			audioObservation = "synthetic unit field",
			motionObservation = "synthetic unit field",
			frames = 2,
			samples = 8,
		}
	end
	-- Rendered-nonce registration is a separate native proof: raw BGRA frames
	-- carrying the round nonce, re-decoded by the gate, never a boolean.
	local registered = require("../fixtures/quality-registration")(input, outcome, {
		actorId = av.actorId,
		studioId = av.studioId,
		buildIdentity = av.buildIdentity,
	})
	av.processIdentity, av.videoSource = registered.processIdentity, registered.videoSource
	local source = clone(av)
	source.finalized, source.startAcknowledgement, source.finalizeAcknowledgement =
		true, "synthetic-start", "synthetic-finish"
	source.acquisition, source.policyDigest = "owned-process-loopback", receipt.digest(av.policy)
	source.registrationEvidence = { path = registered.path, sha256 = registered.sha256 }
	source.registrationCompletedQpc, source.captureStartQpc = registered.completedQpc, registered.captureStartQpc
	local decoded: any = {
		schemaVersion = 1,
		provenance = av,
		original = av.original,
		versions = { ffmpeg = "synthetic", ffprobe = "synthetic" },
		runs = {},
		audio = { parentSha256 = av.original.sha256, streamIndex = 1, nonzero = 1, samples = 8 },
		frameHashes = { "synthetic-frame-a", "synthetic-frame-b" },
		coverage = {
			audio = { { start = 0, ["end"] = 60 } },
			video = { { start = 0, ["end"] = 30 }, { start = 30, ["end"] = 60 } },
		},
	}
	for _ = 1, 5 do
		table.insert(decoded.runs, { exitCode = 0, cleanup = { ok = true }, stdoutSha256 = "synthetic" })
	end
	avWrite("source.json", source)
	avWrite("decode.json", decoded)
	avWrite("capability.json", {
		schemaVersion = 1,
		evaluator = candidate.evaluator,
		audioInput = true,
		temporalVideoInput = true,
		commercialUse = true,
		api = "synthetic-unit-api",
		licenseBasis = "invented unit data",
		probeEvidence = path("probe.json"),
	})
	avWrite("probe.json", { ok = true, audioDelivered = true, videoDelivered = true, api = "synthetic-unit-api" })
	avWrite("delivery.json", {
		audioDelivered = true,
		videoDelivered = true,
		originalSha256 = av.original.sha256,
		tracks = av.tracks,
		api = "synthetic-unit-api",
	})
	avWrite("listening.json", listening)
	write(input.evidence.audiovisual[1], av)
	outcome.audiovisualSources = { [input.evidence.audiovisual[1]] = receipt.digest(source) }
	review.audiovisual = { verdict = "approved", observations = {} }
	for _, interval in av.policy.intervals do
		table.insert(review.audiovisual.observations, {
			manifest = input.evidence.audiovisual[1],
			interval = interval.id,
			listeningReportDigest = receipt.digest(listening),
			originalSha256 = av.original.sha256,
		})
	end

	-- Independent-reference structure uses different encoded pixels and explicit
	-- invented rights/source records, not a claim about any external game.
	assert(
		profile.reference.rubricVersion == "primal-independent-1",
		"fixture rubric must be selected before identity generation"
	)
	input.evidence.reference, input.evidence.referenceArtifacts = { path("reference.json") }, {}
	local function referenceWrite(name: string, value: any): any
		local target = path(name)
		local bytes = write(target, value)
		table.insert(input.evidence.referenceArtifacts, target)
		return { path = target, sha256 = serde.hash("sha256", bytes) }
	end
	local archive = referenceWrite("reference-source.unit", "synthetic independent source archive")
	local independence = referenceWrite("independence.json", {
		verified = true,
		forgeGenerated = false,
		sourceSha256 = archive.sha256,
		independentOfPack = profile.pack,
		reviewedBy = "synthetic-unit-reviewer",
		archive = archive,
	})
	local permission = referenceWrite("permission.unit", "Invented unit permission record, grants no real rights")
	permission.url, permission.version = "https://example.invalid/unit-permission", "synthetic-1"
	local inventory = referenceWrite("rights.json", {
		complete = true,
		sourceSha256 = archive.sha256,
		components = {
			{
				name = "synthetic",
				holder = "unit fixture",
				license = "synthetic permission",
				localCapture = true,
				localEvaluation = true,
				documentPath = permission.path,
			},
		},
	})
	local rubric = referenceWrite("rubric.json", { criteria = profile.criteria })
	rubric.version, rubric.frozenAt = profile.reference.rubricVersion, "2026-01-01T00:00:00Z"
	local invocations = referenceWrite("reference-invocations.json", {
		loadedSourceSha256 = archive.sha256,
		sessionId = "synthetic-reference-session",
		loadVerified = true,
		calls = { { unitFixture = true } },
	})
	local reference: any = {
		schemaVersion = 1,
		kind = "independent-reference",
		source = {
			independentOfPack = profile.pack,
			owner = "synthetic",
			name = "synthetic",
			url = "https://example.invalid/unit",
			revision = "synthetic",
			sourceSha256 = archive.sha256,
			independenceEvidence = independence,
		},
		rights = {
			basis = "explicit-owner-permission",
			holder = "synthetic",
			reviewedBy = "synthetic",
			reviewedAt = "2026-01-01T00:00:00Z",
			scope = { localCapture = true, localEvaluation = true, redistribution = false },
			documents = { permission },
			inventory = inventory,
		},
		rubric = rubric,
		session = {
			id = "synthetic-reference-session",
			startedAt = "2026-01-02T00:00:00Z",
			endedAt = "2026-01-02T00:02:00Z",
			loadedSourceSha256 = archive.sha256,
			invocations = invocations,
			actors = {
				{ actor = "reference-a", studio_id = "reference-desktop", inputMode = "keyboard-mouse" },
				{ actor = "reference-b", studio_id = "reference-mobile", inputMode = "touch" },
			},
		},
		captures = {},
		intervals = {},
	}
	local referenceBytes = buffer.tostring(Png.encode(Pixels.new(9, 6)))
	for index, surface in { "desktop", "mobile" } do
		for _, view in { "forward", "oblique", "elevated-back" } do
			local capture = clone(outcome.captures[index])
			local entry = referenceWrite("reference-" .. surface .. "-" .. view .. ".png", referenceBytes)
			capture.path, capture.sha256 = entry.path, entry.sha256
			capture.sessionId, capture.buildIdentity = reference.session.id, archive.sha256
			capture.actor, capture.studio_id =
				reference.session.actors[index].actor, reference.session.actors[index].studio_id
			capture.raster.width, capture.logicalToRaster.scaleX = 9, 9 / capture.logical.full.width
			table.insert(reference.captures, {
				capture = capture,
				surface = surface,
				capturedAt = "2026-01-02T00:01:00Z",
				mimeType = "image/png",
				checkpoint = "synthetic",
				view = view,
				geometryDigest = receipt.digest({
					device = capture.device,
					logical = capture.logical,
					raster = capture.raster,
					logicalToRaster = capture.logicalToRaster,
					criticalUI = capture.criticalUI,
				}),
			})
			if view == "forward" then
				for _, exemplar in profile.reference.exemplars do
					if exemplar.surface == surface then
						assert(
							exemplar.path == capture.path,
							"select synthetic reference paths before building identity"
						)
					end
				end
			end
		end
	end
	local coverage = { "gather", "craft", "eat", "rest", "build", "combat", "shared-facility", "objective-identified" }
	local trace = referenceWrite("reference-trace.json", {
		sessionId = reference.session.id,
		shortcut = false,
		coached = false,
		startedAt = "2026-01-02T00:00:00Z",
		endedAt = "2026-01-02T00:01:00Z",
		coverage = coverage,
	})
	local interval = referenceWrite("reference-interval.unit", "synthetic temporal unit data")
	interval.sessionId, interval.actor, interval.startedAt, interval.endedAt =
		reference.session.id, "reference-a", "2026-01-02T00:00:00Z", "2026-01-02T00:01:00Z"
	interval.mimeType, interval.coverage, interval.actionTrace = "application/x-synthetic-unit", coverage, trace
	table.insert(reference.intervals, interval)
	local cleanup = referenceWrite(
		"reference-cleanup.json",
		{ ok = true, residuals = {}, resources = { { cleanup = "released", evidence = { unitFixture = true } } } }
	)
	reference.cleanup = { receiptPath = cleanup.path, sha256 = cleanup.sha256 }
	write(input.evidence.reference[1], reference)
	review.referenceDigest, review.assessedAt = receipt.digest(reference), "2026-01-03T00:00:00Z"
	for _, criterion in profile.criteria do
		local score = review.criteria[criterion.id]
		score.anchorsDigest, score.comparisons = receipt.digest(criterion), {}
		for index, exemplar in profile.reference.exemplars do
			table.insert(score.comparisons, {
				reference = exemplar.path,
				surface = exemplar.surface,
				capture = outcome.captures[index].path,
				rationale = "synthetic unit comparison",
				referenceDigest = review.referenceDigest,
				referenceInterval = interval.path,
				observedDifference = "synthetic",
				anchorRationale = "synthetic",
				referenceAt = "2026-01-02T00:00:30Z",
				candidateInterval = outcome.actionEvidence,
				candidateSeconds = 30,
			})
		end
	end
	write(scenarioPath, scenario)
end
