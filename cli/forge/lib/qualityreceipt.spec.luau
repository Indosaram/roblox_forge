--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local qualityprofile = require("./qualityprofile")
local receipt = require("./qualityreceipt")
local qualitygate = require("./qualitygate")
local unit = require("../fixtures/quality-unit")(".omo/fixtures/task-4-native")
receipt, qualitygate = unit.receipt, unit.gate

local function document(): any
	local criteria = {}
	for _, id in qualityprofile.CRITERIA do
		table.insert(criteria, {
			id = id,
			target = 4,
			anchors = { ["1"] = "blocked", ["3"] = "uneven", ["5"] = "clear" },
		})
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
			rubric_version = "rubric-v1",
			exemplars = {
				{ surface = "desktop", path = "reference/desktop" },
				{ surface = "mobile", path = "reference/mobile" },
			},
			disqualifiers = { "blocked" },
		},
		rubric = { version = "rubric-v1", criteria = criteria },
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
	["whole test rejoin requires one transition per actor on every epoch edge"] = function()
		local root = ".omo/fixtures/rejoin-actors"
		assert(not fs.isDir(root), "fixture root must start absent")
		fs.writeDir(root .. "/e")
		local ok, reason = xpcall(function()
			local input: receipt.Inputs = {
				root = root,
				packDir = "pack",
				buildPath = "build",
				receiptPath = "e/receipt",
				evidenceDir = "e",
				evidence = {
					captures = {},
					actions = {},
					audio = {},
					scenarios = {},
					rejoin = { "e/rejoin" },
					rejoinArtifacts = {},
				},
			}
			local function proof(name, value)
				local path, bytes = "e/" .. name, serde.encode("json", value)
				fs.writeFile(root .. "/" .. path, bytes)
				local rejoinArtifacts = input.evidence.rejoinArtifacts
				assert(rejoinArtifacts, "fixture rejoin artifacts must exist")
				table.insert(rejoinArtifacts, path)
				return { path = path, sha256 = serde.hash("sha256", bytes) }
			end
			local identity = { id = "sha256:" .. string.rep("a", 64) }
			local rejoinDocument: any = {
				schemaVersion = 1,
				kind = "physical-rejoin",
				buildIdentity = identity.id,
				epochs = {},
				transitions = {},
				actions = {},
				captures = {},
			}
			local backendIdentities = {}
			rejoinDocument.capability = proof("capability", {
				verified = true,
				physicalClose = true,
				physicalReconnect = true,
				durableBackend = true,
				backendIdentity = "backend",
				api = "fixture",
				hostOwnership = "host",
				mode = "studio-local",
				namespace = "fixture",
			})
			for epoch = 1, 2 do
				local runtime = {
					server = {
						schemaVersion = 1,
						role = "server",
						buildIdentity = identity.id,
						sessionId = "session" .. epoch,
					},
					clients = {},
				}
				local mappings = {}
				for _, actor in { "a", "b" } do
					local studio = actor .. epoch
					table.insert(runtime.clients, {
						schemaVersion = 1,
						role = "client",
						buildIdentity = identity.id,
						serverBuildIdentity = identity.id,
						sessionId = runtime.server.sessionId,
						actorId = actor,
						studio_id = studio,
					})
					table.insert(
						mappings,
						{ actor = actor, studio_id = studio, clientSessionId = studio, processIdentity = studio }
					)
				end
				local context: any = {
					observed = true,
					backendIdentity = "backend",
					hostOwnership = "host",
					mode = "studio-local",
					namespace = "fixture",
					sessionId = runtime.server.sessionId,
					sessionOwnership = "owned" .. epoch,
					configConsumed = true,
					backendEpoch = "backend-epoch" .. epoch,
					backendServerSessionId = "job" .. epoch,
				}
				backendIdentities[epoch] = {
					mode = "studio-local",
					namespace = "fixture",
					storeName = "store",
					epoch = context.backendEpoch,
					serverSessionId = context.backendServerSessionId,
				}
				context.hostReady = proof(
					"ready" .. epoch,
					{ ready = true, hostOwnership = "host", databaseIdentity = "db", backendIdentity = "backend" }
				)
				context.resourceOwnership = proof("resource" .. epoch, {
					owned = true,
					exclusiveDatabase = true,
					databaseIdentity = "db",
					hostOwnership = "host",
					sessionOwnership = context.sessionOwnership,
					processIdentity = "process" .. epoch,
				})
				context.snapshot = proof("snapshot" .. epoch, { identity = backendIdentities[epoch] })
				context.loadedHandshake = proof("handshake" .. epoch, runtime)
				context.installation = proof("install" .. epoch, {
					succeeded = true,
					beforePlay = true,
					mode = context.mode,
					namespace = context.namespace,
					sessionOwnership = context.sessionOwnership,
					hostOwnership = "host",
					invocation = "fixture",
				})
				context.consumedObservation = proof("consumed" .. epoch, {
					folderAbsent = true,
					snapshotObserved = true,
					sessionOwnership = context.sessionOwnership,
					sessionId = runtime.server.sessionId,
					buildIdentity = identity.id,
					snapshotSha256 = context.snapshot.sha256,
					invocation = "fixture",
				})
				table.insert(rejoinDocument.epochs, {
					epoch = epoch,
					runtime = runtime,
					actorMappings = mappings,
					startedSeconds = (epoch - 1) * 2,
					endedSeconds = (epoch - 1) * 2 + 1,
					backendEvidence = proof("backend" .. epoch, context),
				})
			end
			for _, actor in { "a", "b" } do
				local wrapper = serde.encode("json", {
					revision = 1,
					data = {
						genres = {
							["survival-coop"] = {
								data = { inventory = { bag = { items = { wood = { quantity = 3 } } } } },
							},
						},
					},
				})
				local committedRaw = proof(actor .. "rawcommit", {
					key = actor,
					identity = backendIdentities[1],
					hostOwnership = "host",
					sessionOwnership = "owned1",
					buildIdentity = identity.id,
					handshakeSessionId = "session1",
					serialized = wrapper,
					updateAsyncReturned = true,
				})
				local loadedRaw = proof(actor .. "rawload", {
					key = actor,
					identity = backendIdentities[2],
					hostOwnership = "host",
					sessionOwnership = "owned2",
					buildIdentity = identity.id,
					handshakeSessionId = "session2",
					previousSerialized = wrapper,
				})
				table.insert(rejoinDocument.transitions, {
					fromEpoch = 1,
					toEpoch = 2,
					actor = actor,
					oldClientSessionId = actor .. "1",
					newClientSessionId = actor .. "2",
					profileKey = actor,
					backendIdentity = "backend",
					committedRevision = 1,
					loadedRevision = 1,
					retainedItems = { wood = 3 },
					closeEvidence = proof(actor .. "close", {
						exited = true,
						processIdentity = actor .. "1",
						clientSessionId = actor .. "1",
						elapsedSeconds = 1,
					}),
					loadEvidence = proof(actor .. "load", {
						physicalReconnect = true,
						shortcut = false,
						restore = false,
						actor = actor,
						profileKey = actor,
						backendIdentity = "backend",
						clientSessionId = actor .. "2",
						processIdentity = actor .. "2",
						revision = 1,
						items = { wood = 3 },
						hostOwnership = "host",
						sessionOwnership = "owned2",
						mode = "studio-local",
						namespace = "fixture",
						observedPersistedWrapper = true,
						elapsedSeconds = 2.5,
						wrapperEvidence = loadedRaw,
					}),
					commitEvidence = proof(actor .. "commit", {
						durable = true,
						actor = actor,
						profileKey = actor,
						backendIdentity = "backend",
						revision = 1,
						elapsedSeconds = 0.5,
						items = { wood = 3 },
						hostOwnership = "host",
						sessionOwnership = "owned1",
						mode = "studio-local",
						namespace = "fixture",
						observedPersistedWrapper = true,
						updateAsyncReturned = true,
						wrapperEvidence = committedRaw,
					}),
				})
			end
			local candidate = { buildIdentity = identity, review = { rejoinDigests = {} } }
			local function refusal(expected)
				fs.writeFile(root .. "/e/rejoin", serde.encode("json", rejoinDocument))
				candidate.review.rejoinDigests["e/rejoin"] = receipt.digest(rejoinDocument)
				local admitted, detail = receipt.validateRejoin(input, candidate)
				assert(not admitted and string.find(tostring(detail), expected, 1, true), tostring(detail))
			end
			refusal("REJOIN_ACTIONS_REQUIRED") -- Both actor transitions admitted; later missing actions still reject.
			local second = table.remove(rejoinDocument.transitions)
			refusal("REJOIN_ACTOR_TRANSITION_REQUIRED")
			table.insert(rejoinDocument.transitions, second)
			table.insert(rejoinDocument.transitions, second)
			refusal("REJOIN_DUPLICATE_ACTOR_TRANSITION")
		end, debug.traceback)
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
	["rejoin refuses absent capability independently from first play"] = function()
		local input: receipt.Inputs = {
			root = ".",
			packDir = "pack",
			buildPath = "build",
			receiptPath = "e/receipt",
			evidenceDir = "e",
			evidence = { captures = {}, actions = {}, audio = {}, scenarios = {} },
		}
		local admitted, detail = receipt.validateRejoin(input, { review = {} })
		assert(
			not admitted and string.find(tostring(detail), "REJOIN_EVIDENCE_REQUIRED", 1, true),
			'not admitted and string.find(tostring(detail), "REJOIN_EVIDENCE_REQUIRED", 1, true)'
		)
	end,
	["reference provenance and rights failures reject before capture assessment"] = function()
		local root = ".omo/fixtures/reference-admission"
		assert(not fs.isDir(root), "fixture exists")
		fs.writeDir(root .. "/e")
		local ok, reason = xpcall(function()
			local input: receipt.Inputs = {
				root = root,
				packDir = "pack",
				buildPath = "build",
				receiptPath = "e/receipt",
				evidenceDir = "e",
				evidence = {
					captures = {},
					actions = {},
					audio = {},
					scenarios = {},
					reference = { "e/reference" },
					referenceArtifacts = { "e/independence", "e/archive" },
				},
			}
			local profile = assert(qualityprofile.parse(document()))
			local archive = "independently authored source fixture, not acquired evidence"
			fs.writeFile(root .. "/e/archive", archive)
			local hash = serde.hash("sha256", archive)
			local independence = {
				verified = true,
				forgeGenerated = true,
				sourceSha256 = hash,
				independentOfPack = profile.pack,
				reviewedBy = "fixture",
				archive = { path = "e/archive", sha256 = hash },
			}
			local reference: any = {
				schemaVersion = 1,
				kind = "independent-reference",
				source = {
					name = "fixture",
					owner = "fixture",
					url = "fixture",
					revision = "fixture",
					sourceSha256 = hash,
					independentOfPack = profile.pack,
				},
				rights = {
					basis = "code-license-only",
					scope = { localCapture = true, localEvaluation = true, redistribution = false },
				},
			}
			local candidate = { review = {} }
			local function save()
				local encoded = serde.encode("json", independence)
				fs.writeFile(root .. "/e/independence", encoded)
				reference.source.independenceEvidence =
					{ path = "e/independence", sha256 = serde.hash("sha256", encoded) }
				candidate.review.referenceDigest = receipt.digest(reference)
				fs.writeFile(root .. "/e/reference", serde.encode("json", reference))
			end
			save()
			local admitted, detail = receipt.validateReference(profile, input, candidate)
			assert(
				not admitted and string.find(tostring(detail), "REFERENCE_NOT_INDEPENDENT", 1, true),
				'not admitted and string.find(tostring(detail), "REFERENCE_NOT_INDEPENDENT", 1, true)'
			)
			independence.forgeGenerated = false
			save()
			admitted, detail = receipt.validateReference(profile, input, candidate)
			assert(
				not admitted and string.find(tostring(detail), "REFERENCE_RIGHTS_BASIS", 1, true),
				'not admitted and string.find(tostring(detail), "REFERENCE_RIGHTS_BASIS", 1, true)'
			)
			fs.writeFile(root .. "/e/archive", "swapped")
			admitted, detail = receipt.validateReference(profile, input, candidate)
			assert(
				not admitted and string.find(tostring(detail), "REFERENCE_STALE_ARTIFACT", 1, true),
				'not admitted and string.find(tostring(detail), "REFERENCE_STALE_ARTIFACT", 1, true)'
			)
		end, debug.traceback)
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
	["legacy first party reference cannot enter global independent admission"] = function()
		local input: receipt.Inputs = {
			root = ".",
			packDir = "pack",
			buildPath = "build",
			receiptPath = "e/receipt",
			evidenceDir = "e",
			evidence = { captures = {}, actions = {}, audio = {}, scenarios = {} },
		}
		local profile = assert(qualityprofile.parse(document()))
		local ok, reason = receipt.validateReference(profile, input, { review = { referenceDigest = "claimed" } })
		assert(
			not ok and string.find(tostring(reason), "REFERENCE_EVIDENCE_REQUIRED", 1, true),
			'not ok and string.find(tostring(reason), "REFERENCE_EVIDENCE_REQUIRED", 1, true)'
		)
	end,
	["audiovisual admission binds originals source delivery and interval coverage"] = function()
		local root = ".omo/fixtures/quality-av-admission"
		assert(not fs.isDir(root), "fixture exists")
		fs.writeDir(root .. "/e")
		local ok, reason = xpcall(function()
			local input: receipt.Inputs = {
				root = root,
				packDir = "pack",
				buildPath = "build",
				receiptPath = "e/receipt",
				evidenceDir = "e",
				evidence = {
					captures = {},
					actions = {},
					audio = {},
					scenarios = { "e/scenario" },
					audiovisual = { "e/manifest" },
					avArtifacts = {
						"e/original",
						"e/source",
						"e/decode",
						"e/capability",
						"e/listening",
						"e/probe",
						"e/delivery",
					},
				},
			}
			local original = "fixture container; structural test only, not live capture"
			fs.writeFile(root .. "/e/original", original)
			local av: any = {
				schemaVersion = 1,
				scenario = "e/scenario",
				sourceReceipt = "e/source",
				decodeReport = "e/decode",
				listeningCapability = "e/capability",
				listeningReport = "e/listening",
				original = { path = "e/original", sha256 = serde.hash("sha256", original), byteLength = #original },
				tracks = { audio = 1, video = 0 },
				clock = {
					offsetSeconds = 0,
					rate = 1,
					uncertaintySeconds = 0,
					driftSeconds = 0,
					anchors = { { ptsSeconds = 0, actionSeconds = 0 }, { ptsSeconds = 1, actionSeconds = 1 } },
				},
				policy = { maxGapSeconds = 0, maxClockErrorSeconds = 0, intervals = {} },
			}
			for _, cue in { "gather", "craft", "hit", "ambient" } do
				table.insert(
					av.policy.intervals,
					{ id = cue, cue = cue, audioRequired = true, step = 1, start = 0, ["end"] = 1 }
				)
			end
			for _, key in
				{
					"sessionId",
					"actorId",
					"studioId",
					"buildIdentity",
					"processIdentity",
					"recorderId",
					"audioEndpoint",
					"videoSource",
					"acquisitionDigest",
					"runSha256",
				}
			do
				av[key] = key
			end
			local scenario = {
				outcome = {
					runtime = {
						server = { sessionId = av.sessionId },
						clients = { { actorId = av.actorId, studio_id = av.studioId } },
					},
					steps = { { sessionId = av.sessionId, actor = av.actorId, startedSeconds = 0, elapsedSeconds = 1 } },
					registrations = {},
					audiovisualSources = {},
				},
			}
			-- Rendered-nonce registration is a separate native proof re-decoded from
			-- raw BGRA frames; the shared fixture publishes unit bytes only.
			local registered = require("../fixtures/quality-registration")(input, scenario.outcome, {
				actorId = av.actorId,
				studioId = av.studioId,
				buildIdentity = av.buildIdentity,
			})
			av.processIdentity, av.videoSource = registered.processIdentity, registered.videoSource
			local source: any = table.clone(av)
			source.finalized, source.startAcknowledgement, source.finalizeAcknowledgement = true, "start", "finish"
			source.acquisition, source.policyDigest = "owned-process-loopback", receipt.digest(av.policy)
			source.registrationEvidence = { path = registered.path, sha256 = registered.sha256 }
			source.registrationCompletedQpc, source.captureStartQpc =
				registered.completedQpc, registered.captureStartQpc
			scenario.outcome.audiovisualSources = { ["e/manifest"] = receipt.digest(source) }
			local decoded = {
				schemaVersion = 1,
				provenance = av,
				original = av.original,
				versions = { ffmpeg = "fixture", ffprobe = "fixture" },
				runs = {},
				audio = { parentSha256 = av.original.sha256, streamIndex = 1, nonzero = 1, samples = 8 },
				frameHashes = { "fixture" },
				coverage = { audio = { { start = 0, ["end"] = 1 } }, video = { { start = 0, ["end"] = 1 } } },
			}
			for _ = 1, 5 do
				table.insert(decoded.runs, { exitCode = 0, cleanup = { ok = true }, stdoutSha256 = "fixture" })
			end
			local capability = {
				schemaVersion = 1,
				evaluator = "fixture",
				audioInput = true,
				temporalVideoInput = true,
				commercialUse = true,
				api = "fixture-media-api",
				probeEvidence = "e/probe",
				licenseBasis = "fixture",
			}
			local probe = { ok = true, audioDelivered = true, videoDelivered = true, api = capability.api }
			local delivery = {
				audioDelivered = true,
				videoDelivered = true,
				originalSha256 = av.original.sha256,
				api = capability.api,
				tracks = av.tracks,
			}
			local listening = {
				evaluator = "fixture",
				originalSha256 = av.original.sha256,
				tracks = av.tracks,
				verdict = "approved",
				deliveryEvidence = "e/delivery",
				intervals = {
					gather = {
						start = 0,
						finish = 1,
						heard = true,
						audioObservation = "fixture",
						motionObservation = "fixture",
						frames = 2,
						samples = 8,
					},
				},
			}
			local candidate = {
				evaluator = "fixture",
				buildIdentity = { id = av.buildIdentity },
				review = {
					audiovisual = {
						verdict = "approved",
						observations = {
							{
								manifest = "e/manifest",
								interval = "gather",
								listeningReportDigest = receipt.digest(listening),
								originalSha256 = av.original.sha256,
							},
						},
					},
				},
			}
			for _, cue in { "craft", "hit", "ambient" } do
				listening.intervals[cue] = table.clone(listening.intervals.gather)
			end
			candidate.review.audiovisual.observations = {}
			for _, cue in { "gather", "craft", "hit", "ambient" } do
				table.insert(candidate.review.audiovisual.observations, {
					manifest = "e/manifest",
					interval = cue,
					listeningReportDigest = receipt.digest(listening),
					originalSha256 = av.original.sha256,
				})
			end
			local function write(path, value)
				fs.writeFile(root .. "/e/" .. path, serde.encode("json", value))
			end
			write("manifest", av)
			write("source", source)
			write("scenario", scenario)
			write("decode", decoded)
			write("capability", capability)
			write("probe", probe)
			write("delivery", delivery)
			write("listening", listening)
			local admitted, detail = receipt.validateAudiovisual(input, candidate)
			assert(admitted, tostring(detail))

			local boundRegistration = source.registrationEvidence
			for _, replacement in { false, true } do
				source.registrationEvidence = if replacement then true else nil
				scenario.outcome.audiovisualSources["e/manifest"] = receipt.digest(source)
				write("source", source)
				write("scenario", scenario)
				assert(not receipt.validateAudiovisual(input, candidate), "rehashed source cannot omit registration")
			end
			source.registrationEvidence = boundRegistration
			scenario.outcome.audiovisualSources["e/manifest"] = receipt.digest(source)
			write("source", source)
			write("scenario", scenario)
			capability.audioInput = false
			write("capability", capability)
			assert(not receipt.validateAudiovisual(input, candidate), "image-only cannot approve")
			capability.audioInput = true
			write("capability", capability)
			delivery.originalSha256 = "swapped"
			write("delivery", delivery)
			assert(not receipt.validateAudiovisual(input, candidate), "delivery must bind original")
			delivery.originalSha256 = av.original.sha256
			write("delivery", delivery)
			decoded.coverage.audio[1]["end"] = 0.5
			write("decode", decoded)
			assert(not receipt.validateAudiovisual(input, candidate), "truncated coverage rejected")
			decoded.coverage.audio[1]["end"] = 1
			write("decode", decoded)
			fs.writeFile(root .. "/e/original", "replacement WAV")
			assert(not receipt.validateAudiovisual(input, candidate), "standalone replacement rejected")
		end, debug.traceback)
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
	["canonical digests ignore insertion order but bind keys and bytes"] = function()
		assert(
			receipt.digest({ a = 1, b = { x = "yes", y = false } })
				== receipt.digest({ b = { y = false, x = "yes" }, a = 1 }),
			"insertion order must not affect digest"
		)
		assert(receipt.digest({ a = "1" }) ~= receipt.digest({ a = 1 }), "scalar types are bound")
		assert(receipt.digest({ [1] = "a" }) ~= receipt.digest({ ["1"] = "a" }), "key types are bound")
	end,
	["receipt binds dirty shipped inputs and independent evaluator attestation"] = function()
		local root = ".omo/fixtures/task-4-native"
		assert(not fs.isDir(root), "task fixture already exists")
		fs.writeDir(root)
		local ok, reason = xpcall(function()
			for _, dir in { "core", "genres", "cli", "skills", "pack/assets", "reference", "evidence" } do
				fs.writeDir(root .. "/" .. dir)
			end
			local files: { [string]: string } = {
				["core/entry.luau"] = "return 1",
				["skills/qa.md"] = "original QA contract",
				["pack/game.yml"] = "name: fixture-quality",
				["pack/default.project.json"] = "{}",
				["pack/forge-lock.yml"] = "version: 1",
				["pack/assets/manifest.yml"] = "assets: []",
				["pack/assets/model"] = "original asset",
				["build.rbxl"] = "native digest fixture, not a playable build",
				["reference/desktop"] = "desktop fixture",
				["reference/mobile"] = "mobile fixture",
				["evidence/capture"] = "capture fixture",
				["evidence/action"] = "action fixture",
				["evidence/audio"] = "audio fixture",
				["evidence/scenario"] = "scenario fixture",
				["pack/quality.yml"] = serde.encode("yaml", document()),
			}
			for path, bytes in files do
				fs.writeFile(root .. "/" .. path, bytes)
			end
			local profile, profileErrors =
				qualityprofile.parse(serde.decode("yaml", fs.readFile(root .. "/pack/quality.yml")))
			assert(profile, "disk fixture profile must validate: " .. table.concat(profileErrors, "; "))
			local input: receipt.Inputs = {
				root = root,
				packDir = "pack",
				buildPath = "build.rbxl",
				receiptPath = "evidence/receipt.json",
				evidenceDir = "evidence",
				evidence = {
					captures = { "evidence/capture" },
					actions = { "evidence/action" },
					audio = { "evidence/audio" },
					scenarios = { "evidence/scenario" },
				},
			}
			local snapshot, snapshotError = receipt.snapshot(profile, input)
			assert(snapshot, snapshotError)
			local review: any = {
				criteria = {},
				blockers = {},
				fun = { verdict = "approved", rationale = "fixture assertion only", confidence = "test" },
				goals = {},
			}
			for _, criterion in profile.criteria do
				review.criteria[criterion.id] = { score = 4, rationale = "fixture assertion only" }
			end
			for _, goal in profile.firstPlayGoals do
				review.goals[goal.id] = { completed = true, evidence = "evidence/scenario", minutes = 1, players = 2 }
			end
			local approved: any = {
				schemaVersion = receipt.SCHEMA_VERSION,
				captureSchemaVersion = 2,
				pack = profile.pack,
				scope = profile.tier,
				evaluator = "test-evaluator",
				verdict = "approved",
				snapshot = snapshot,
				review = review,
			}
			approved.inputs =
				{ buildPath = input.buildPath, evidenceDir = input.evidenceDir, evidence = input.evidence }
			local runtimeFixture = require("../fixtures/quality-runtime")
			local token = "synthetic-owned-marker-123"
			approved.buildIdentity = runtimeFixture(profile, input, review, token)
			local admitted, admissionReason = receipt.validateRuntime(profile, input, approved)
			assert(admitted, tostring(admissionReason))
			local sidecarPath = root .. "/build.rbxl.identity.json"
			local scenarioFile, actionFile = root .. "/evidence/scenario", root .. "/evidence/action"
			local originalSidecar = fs.readFile(sidecarPath)
			local markedScenario, markedAction = fs.readFile(scenarioFile), fs.readFile(actionFile)
			local replacements: { boolean | string | number } = { false, "wrong-owned-marker-123", "bad", 123 }
			for _, replacement in replacements do
				local sidecar = serde.decode("json", originalSidecar)
				sidecar.ownedQaToken = if replacement == false then nil else replacement
				fs.writeFile(sidecarPath, serde.encode("json", sidecar))
				assert(
					not receipt.validateRuntime(profile, input, approved),
					"missing malformed or mismatched sidecar marker refuses"
				)
			end
			fs.writeFile(sidecarPath, originalSidecar)
			for _, actor in { "server", "1", "2" } do
				for _, field in { "ownedQaToken", "placeId" } do
					local changed = serde.decode("json", markedScenario)
					local handshake = if actor == "server"
						then changed.outcome.runtime.server
						else changed.outcome.runtime.clients[tonumber(actor)]
					handshake[field] = if field == "placeId" then 7 else "wrong-owned-marker-123"
					fs.writeFile(scenarioFile, serde.encode("json", changed))
					-- Rebind action bytes too: ownership must fail independently of trace mismatch.
					fs.writeFile(
						actionFile,
						serde.encode("json", {
							runtime = changed.outcome.runtime,
							clients = changed.outcome.clients,
							steps = changed.outcome.steps,
						})
					)
					assert(
						not receipt.validateRuntime(profile, input, approved),
						"every loaded process must match artifact ownership and local place"
					)
					handshake[field] = nil
					fs.writeFile(scenarioFile, serde.encode("json", changed))
					fs.writeFile(
						actionFile,
						serde.encode("json", {
							runtime = changed.outcome.runtime,
							clients = changed.outcome.clients,
							steps = changed.outcome.steps,
						})
					)
					assert(
						not receipt.validateRuntime(profile, input, approved),
						"marked artifact requires measured ownership fields on every process"
					)
				end
			end
			fs.writeFile(scenarioFile, markedScenario)
			fs.writeFile(actionFile, markedAction)
			local changedAction = serde.decode("json", markedAction)
			changedAction.runtime.clients[2].ownedQaToken = "wrong-owned-marker-123"
			fs.writeFile(actionFile, serde.encode("json", changedAction))
			local actionAdmitted, actionReason = receipt.validateRuntime(profile, input, approved)
			assert(
				not actionAdmitted and string.find(tostring(actionReason), "ACTION_TRACE_MISMATCH", 1, true),
				"action trace binds measured ownership"
			)
			fs.writeFile(actionFile, markedAction)
			-- Recreate the ordinary unmarked fixture for the existing receipt cases.
			approved.buildIdentity = require("../fixtures/quality-runtime")(profile, input, review)
			local unmarked, unmarkedReason = receipt.validateRuntime(profile, input, approved)
			assert(unmarked, tostring(unmarkedReason))
			local plainSidecar = fs.readFile(sidecarPath)
			local forgedSidecar = serde.decode("json", plainSidecar)
			forgedSidecar.ownedQaToken = token
			fs.writeFile(sidecarPath, serde.encode("json", forgedSidecar))
			assert(
				not receipt.validateRuntime(profile, input, approved),
				"sidecar cannot invent absent artifact marker"
			)
			fs.writeFile(sidecarPath, plainSidecar)
			snapshot = assert(receipt.snapshot(profile, input))
			approved.snapshot = snapshot
			for path in files do
				files[path] = fs.readFile(root .. "/" .. path)
			end
			local authority = { identity = "test-evaluator", attestationPath = root .. "/evidence/attestation.json" }
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
			local function expect(code: string)
				local result = receipt.check(profile, input, approved, authority)
				assert(
					result.code == code,
					result.code .. " expected " .. code .. ": " .. table.concat(result.errors, "; ")
				)
			end
			attest()
			expect("INCONCLUSIVE") -- Legacy hash-only audio cannot establish listening.
			approved.schemaVersion = 1
			expect("INVALID_RECEIPT")
			approved.schemaVersion = receipt.SCHEMA_VERSION
			local scenarioPath = root .. "/evidence/scenario"
			local originalScenario = fs.readFile(scenarioPath)
			for _, mutate in
				{
					function(o: any)
						o.runtime.clients[2].buildIdentity = "stale"
					end,
					function(o: any)
						o.runtime.clients[2].actorId = "1"
					end,
					function(o: any)
						o.steps[1].sessionId = "other"
					end,
					function(o: any)
						o.steps[1].index = 2
					end,
					function(o: any)
						o.steps[1].startedSeconds = -1
					end,
					function(o: any)
						o.steps[1].revisionAfter = -1
					end,
					function(o: any)
						o.steps[1].op = "restore"
					end,
				}
			do
				local changed = serde.decode("json", originalScenario)
				mutate(changed.outcome)
				fs.writeFile(scenarioPath, serde.encode("json", changed))
				approved.snapshot = assert(receipt.snapshot(profile, input))
				attest()
				expect("INVALID_RUNTIME_EVIDENCE")
			end
			fs.writeFile(scenarioPath, originalScenario)
			approved.snapshot = snapshot
			attest()
			local gateOptions: qualitygate.Options = {
				root = root,
				pack = profile.pack,
				packDir = "pack",
				authority = authority,
			}
			approved.inputs = {
				buildPath = input.buildPath,
				evidenceDir = input.evidenceDir,
				evidence = input.evidence,
			}
			local function publishReceipt()
				attest()
				fs.writeFile(root .. "/evidence/receipt.json", serde.encode("json", approved))
			end
			publishReceipt()
			expect("INCONCLUSIVE")
			local gate = qualitygate.check(gateOptions)
			assert(
				not gate.ok and gate.code == "INCONCLUSIVE" and not gate.releaseApproved,
				"a valid authorized base receipt without supplemental observations cannot pass the CLI gate"
					.. ": "
					.. gate.code
					.. ": "
					.. table.concat(gate.errors, "; ")
			)
			assert(
				gate.declaredTier == "vertical-slice" and #gate.errors > 0,
				"observation refusal preserves the declared tier and explains missing evidence"
			)
			gateOptions.target = "starter"
			assert(not qualitygate.check(gateOptions).ok, "cannot bypass declared tier with starter target")
			gateOptions.target = "release-candidate"
			assert(qualitygate.check(gateOptions).code == "INVALID_SCOPE", "slice receipt cannot authorize release")
			gateOptions.environment = "staging"
			local deployment = qualitygate.check(gateOptions)
			assert(
				not deployment.ok and deployment.code == "QUALITY_GATE_FAILED" and not deployment.releaseApproved,
				"a vertical-slice declaration cannot authorize deployment even with a release target"
			)
			gateOptions.environment = nil
			approved.scope = "release-candidate"
			publishReceipt()
			gateOptions.buildPath = "build.rbxl"
			local releaseResult = qualitygate.check(gateOptions)
			assert(
				not releaseResult.ok and releaseResult.code == "INCONCLUSIVE" and not releaseResult.releaseApproved,
				"matching build and release scope cannot bypass missing observational evidence in deployment"
					.. ": "
					.. releaseResult.code
					.. ": "
					.. table.concat(releaseResult.errors, "; ")
			)
			gateOptions.buildPath = "other.rbxl"
			assert(not qualitygate.check(gateOptions).ok, "deployment cannot publish another build path")
			gateOptions.buildPath = "build.rbxl"
			authority.identity = ""
			assert(qualitygate.check(gateOptions).code == "MISSING_EVALUATOR", "missing evaluator fails closed")
			authority.identity = "test-evaluator"
			approved.verdict = "inconclusive"
			publishReceipt()
			assert(qualitygate.check(gateOptions).code == "INCONCLUSIVE", "inconclusive verdict cannot approve release")
			approved.verdict = "approved"
			publishReceipt()
			fs.writeFile(root .. "/pack/assets/model", "changed deployment artifact")
			assert(qualitygate.check(gateOptions).code == "STALE_ASSET", "changed asset invalidates the approval")
			fs.writeFile(root .. "/pack/assets/model", files["pack/assets/model"])
			gateOptions.environment = "staging"
			gateOptions.development = true
			assert(not qualitygate.check(gateOptions).ok, "release target cannot use development bypass")
			local releaseDocument = document()
			releaseDocument.tier = "release-candidate"
			fs.writeFile(root .. "/pack/quality.yml", serde.encode("yaml", releaseDocument))
			gateOptions.target = nil
			assert(not qualitygate.check(gateOptions).ok, "declared release cannot use development bypass")
			gateOptions.target = "starter"
			assert(not qualitygate.check(gateOptions).ok, "explicit starter cannot downgrade declared release")
			fs.writeFile(root .. "/pack/quality.yml", files["pack/quality.yml"])
			gateOptions.target = nil
			local developmentResult = qualitygate.check(gateOptions)
			assert(
				developmentResult.ok
					and developmentResult.code == "STAGING_DEVELOPMENT"
					and not developmentResult.releaseApproved,
				"explicit staging development never grants release approval"
			)
			gateOptions.environment = "production"
			assert(not qualitygate.check(gateOptions).ok, "development is never a production exception")
			approved.scope = profile.tier
			publishReceipt()
			for _, path in
				{
					"core/entry.luau",
					"genres/receipt.json",
					"cli/receipt.json",
					"skills/qa.md",
					"pack/receipt.json",
					"build.rbxl",
					"evidence",
				}
			do
				input.receiptPath = path
				local invalid, invalidReason = receipt.snapshot(profile, input)
				assert(invalid == nil and invalidReason ~= nil, "receipt path must not exempt shipped bytes: " .. path)
			end
			input.receiptPath = "evidence/receipt.json"
			input.buildPath = "evidence/capture"
			assert(receipt.snapshot(profile, input) == nil, "build cannot overlap evidence")
			input.buildPath = "build.rbxl"
			local repeated = assert(receipt.snapshot(profile, input))
			assert(receipt.digest(snapshot) == receipt.digest(repeated), "snapshot is deterministic")
			unit.setTree(string.rep("2", 40))
			expect("STALE_TREE")
			unit.setTree(nil)
			local missingTree, missingTreeReason = receipt.snapshot(profile, input)
			assert(
				missingTree == nil and string.find(tostring(missingTreeReason), "MISSING_GIT_TREE", 1, true),
				"production snapshot still refuses a failed Git tree query"
			)
			unit.setTree(string.rep("1", 40))
			fs.writeFile(root .. "/evidence/receipt.json", "receipt bytes excluded")
			fs.writeFile(root .. "/evidence/unrelated", "separately scoped evidence")
			expect("INCONCLUSIVE")
			for path, code in
				{
					["core/entry.luau"] = "STALE_SOURCE",
					["skills/qa.md"] = "STALE_SOURCE",
					["pack/game.yml"] = "STALE_CONFIG",
					["pack/forge-lock.yml"] = "STALE_CONFIG",
					["pack/assets/model"] = "STALE_ASSET",
					["pack/assets/manifest.yml"] = "STALE_ASSET",
					["reference/desktop"] = "STALE_RUBRIC",
					["evidence/capture"] = "STALE_EVIDENCE",
					["evidence/action"] = "STALE_EVIDENCE",
					["evidence/audio"] = "STALE_EVIDENCE",
					["evidence/scenario"] = "STALE_EVIDENCE",
					["build.rbxl"] = "STALE_BUILD",
				} :: { [string]: string }
			do
				fs.writeFile(root .. "/" .. path, files[path] .. "\n# changed")
				expect(code)
				fs.writeFile(root .. "/" .. path, files[path])
			end
			fs.writeFile(root .. "/core/untracked.luau", "return 2")
			expect("STALE_SOURCE")
			fs.removeFile(root .. "/core/untracked.luau")
			profile.reference.rubricVersion = "rubric-v2"
			expect("STALE_RUBRIC")
			profile.reference.rubricVersion = "rubric-v1"
			authority.identity = "other"
			expect("UNAUTHORIZED_EVALUATOR")
			authority.identity = ""
			expect("MISSING_EVALUATOR")
			authority.identity = "test-evaluator"
			approved.review.fun.rationale = "forged modification"
			expect("INVALID_ATTESTATION")
			attest()
			approved.verdict = "failed"
			expect("FAILED")
			approved.verdict = "inconclusive"
			expect("INCONCLUSIVE")
			approved.verdict = "approved"
			approved.review.criteria.legibility.score = 3
			attest()
			expect("CRITERION_FAILED")
			approved.review.criteria.legibility.score = 4
			attest()
			assert(
				receipt.check(profile, input, approved, authority, "release-candidate").code == "INVALID_SCOPE",
				"no tier upgrade"
			)
			fs.removeFile(root .. "/evidence/audio")
			expect("MISSING_INPUT")
			fs.writeFile(root .. "/evidence/audio", files["evidence/audio"])
			fs.removeFile(authority.attestationPath)
			expect("INVALID_ATTESTATION")
		end, debug.traceback)
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
}
