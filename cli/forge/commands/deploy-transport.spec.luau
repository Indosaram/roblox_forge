--!strict
-- Synthetic local admission data, never a real evaluator or Studio receipt.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local deploy = require("./deploy")
local profileLib = require("../lib/qualityprofile")
local receipt = require("../lib/qualityreceipt")
local gate = require("../lib/qualitygate")
local runtime = require("../fixtures/quality-runtime")
local unit = require("../fixtures/quality-unit")(".")
receipt, gate, deploy = unit.receipt, unit.gate, unit.deploy

return {
	["approved release caller preserves gates bytes and one attempt through actual adapter"] = function()
		local pack = "fixture-task-fifteen-deploy"
		local directory = "games/" .. pack
		local evidence = ".omo/fixtures/task-fifteen-deploy"
		local build = "build/" .. pack .. ".rbxl"
		assert(
			not fs.isDir(directory) and not fs.isFile(directory),
			"not fs.isDir(directory) and not fs.isFile(directory)"
		)
		assert(not fs.isDir(evidence) and not fs.isFile(evidence), "not fs.isDir(evidence) and not fs.isFile(evidence)")
		assert(
			not fs.isFile(build) and not fs.isFile(build .. ".identity.json"),
			'not fs.isFile(build) and not fs.isFile(build .. ".identity.json")'
		)
		local ok, reason = xpcall(function()
			fs.writeDir(directory .. "/assets")
			fs.writeDir(evidence .. "/reference")
			fs.writeDir("build")
			local document = serde.decode("yaml", fs.readFile("cli/forge/fixtures/quality-profile.yml"))
			for _, criterion in document.rubric.criteria do
				local anchors = criterion.anchors
				criterion.anchors = {
					["1"] = anchors["1"] or anchors[1],
					["3"] = anchors["3"] or anchors[3],
					["5"] = anchors["5"] or anchors[5],
				}
			end
			document.reference.rubric_version, document.rubric.version = "primal-independent-1", "primal-independent-1"
			document.pack, document.tier = pack, "release-candidate"
			document.evaluation_receipt = evidence .. "/receipt.json"
			for _, exemplar in document.reference.exemplars do
				exemplar.path = evidence .. "/synthetic-reference-" .. exemplar.surface .. "-forward.png"
				fs.writeFile(exemplar.path, "independent synthetic reference " .. exemplar.surface)
			end
			fs.writeFile(directory .. "/quality.yml", serde.encode("yaml", document))
			fs.writeFile(directory .. "/game.yml", "name: Synthetic operational fixture\nmonetization: {}\n")
			fs.writeFile(directory .. "/forge-lock.yml", "version: 1\n")
			fs.writeFile(directory .. "/assets/manifest.yml", "assets: []\n")
			fs.writeFile(
				directory .. "/deploy.yml",
				"environments:\n  production:\n    universeId: 42\n    placeId: 7\n  staging:\n    universeId: 99\n    placeId: 8\n"
			)
			local profile = assert(profileLib.parse(document))
			local input: receipt.Inputs = {
				root = ".",
				packDir = directory,
				buildPath = build,
				receiptPath = evidence .. "/receipt.json",
				evidenceDir = evidence,
				evidence = {
					captures = { evidence .. "/desktop", evidence .. "/mobile" },
					actions = { evidence .. "/actions" },
					audio = { evidence .. "/audio" },
					scenarios = { evidence .. "/scenario" },
				},
			}
			fs.writeFile(evidence .. "/audio", "synthetic audio admission bytes")
			local review: any = {
				criteria = {},
				goals = {},
				disqualifiers = {},
				blockers = {},
				fun = {
					verdict = "approved",
					rationale = "unit fixture",
					confidence = "unit fixture",
					actions = evidence .. "/actions",
					audio = evidence .. "/audio",
					limits = "synthetic admission only",
				},
			}
			local identity = runtime(profile, input, review)
			local scenario = serde.decode("json", fs.readFile(evidence .. "/scenario"))
			local outcome = scenario.outcome
			outcome.inputs, outcome.calls = { { fixture = true } }, { { fixture = true } }
			outcome.audio =
				{ { path = evidence .. "/audio", sha256 = serde.hash("sha256", fs.readFile(evidence .. "/audio")) } }
			local mobile = outcome.captures[2]
			mobile.path = evidence .. "/mobile"
			fs.writeFile(mobile.path, fs.readFile(evidence .. "/desktop"))
			mobile.device = {
				id = "mobile",
				surface = "mobile",
				width = 390,
				height = 844,
				form = "Phone",
				orientation = "Portrait",
				scaling = "ActualResolution",
			}
			review.surfaces[2].surface, review.surfaces[2].capture = "mobile", mobile.path
			review.surfaces[2].geometryDigest = receipt.digest({
				device = mobile.device,
				logical = mobile.logical,
				raster = mobile.raster,
				logicalToRaster = mobile.logicalToRaster,
				criticalUI = mobile.criticalUI,
			})
			for _, defect in profile.reference.disqualifiers do
				review.disqualifiers[defect] = { present = false, rationale = "synthetic admission" }
			end
			for _, criterion in profile.criteria do
				local comparisons = {}
				for _, exemplar in profile.reference.exemplars do
					table.insert(comparisons, {
						reference = exemplar.path,
						surface = exemplar.surface,
						capture = evidence .. "/" .. exemplar.surface,
						rationale = "synthetic comparison",
					})
				end
				review.criteria[criterion.id] = {
					score = 5,
					rationale = "synthetic admission",
					anchorsDigest = receipt.digest(criterion),
					comparisons = comparisons,
				}
			end
			fs.writeFile(evidence .. "/scenario", serde.encode("json", scenario))
			local approved: any = {
				schemaVersion = receipt.SCHEMA_VERSION,
				captureSchemaVersion = 2,
				pack = pack,
				scope = "release-candidate",
				evaluator = "fixture-operator",
				verdict = "approved",
				buildIdentity = identity,
				review = review,
				inputs = { buildPath = build, evidenceDir = evidence, evidence = input.evidence },
			}
			require("../fixtures/quality-approval")(profile, input, approved)
			approved.snapshot = assert(receipt.snapshot(profile, input))
			fs.writeFile(input.receiptPath, serde.encode("json", approved))
			local attestation = evidence .. "/attestation.json"
			fs.writeFile(
				attestation,
				serde.encode("json", {
					schemaVersion = receipt.SCHEMA_VERSION,
					evaluator = "fixture-operator",
					receiptDigest = receipt.digest(approved),
				})
			)
			local env: { [string]: string? } = {
				FORGE_ALLOW_PRODUCTION = "1",
				FORGE_QUALITY_EVALUATOR = "fixture-operator",
				FORGE_QUALITY_ATTESTATION = attestation,
				ROBLOX_PRODUCTION_API_KEY = "synthetic-key",
				ROBLOX_PRODUCTION_UNIVERSE_ID = "42",
				ROBLOX_PRODUCTION_PLACE_ID = "7",
			}
			local admitted = gate.check({
				pack = pack,
				packDir = directory,
				environment = "production",
				buildPath = build,
				authority = { identity = "fixture-operator", attestationPath = attestation },
			})
			assert(
				admitted.ok and admitted.releaseApproved,
				admitted.code .. ": " .. table.concat(admitted.errors, "; ")
			)
			local artifact = fs.readFile(build)
			local args = { "deploy", "--env", "production", "--pack", pack }
			local calls = 0
			for _, mode in { "accepted", "malformed", "timeout", "429", "403" } do
				local before = calls
				local accepted = deploy.run(args, {
					env = env,
					request = function(request: any): any
						calls += 1
						assert(
							request.body == artifact and fs.readFile(build) == artifact,
							"request.body == artifact and fs.readFile(build) == artifact"
						)
						assert(
							request.method == "POST" and request.headers["x-api-key"] == "synthetic-key",
							'request.method == "POST" and request.headers["x-api-key"] == "synthetic-key"'
						)
						assert(
							request.url
								== "https://apis.roblox.com/universes/v1/42/places/7/versions?versionType=Published",
							'request.url == "https://apis.roblox.com/universes/v1/42/places/7/versions?versionType=Published"'
						)
						if mode == "timeout" then
							error("timeout private provider text")
						end
						return {
							statusCode = tonumber(mode) or 200,
							ok = tonumber(mode) == nil,
							body = if mode == "accepted" then '{"versionNumber":1}' else "private provider text",
						}
					end,
				})
				assert(
					accepted == (mode == "accepted") and calls == before + 1,
					'accepted == (mode == "accepted") and calls == before + 1'
				)
			end
			assert(not deploy.run(args, {
				env = env,
				request = function(_request: any): any
					error("PUBLISH_TRANSPORT_UNSUPPORTED", 0)
				end,
			}), "unavailable transport must refuse")
			for _, field in
				{
					"FORGE_ALLOW_PRODUCTION",
					"ROBLOX_PRODUCTION_API_KEY",
					"ROBLOX_PRODUCTION_UNIVERSE_ID",
					"FORGE_QUALITY_EVALUATOR",
				}
			do
				local changed = table.clone(env)
				changed[field] = ""
				assert(not deploy.run(args, {
					env = changed,
					request = function(_request: any): any
						calls += 1
						error("refused invocation reached transport")
					end,
				}), "changed environment values must refuse before transport")
			end
			assert(calls == 5, "changed environment refusals never reach transport")
			fs.writeFile(build, artifact .. "changed")
			assert(not deploy.run(args, {
				env = env,
				request = function(_request: any): any
					calls += 1
					error("stale artifact reached transport")
				end,
			}), "stale artifact must refuse before transport")
			assert(calls == 5, "stale artifact refusal never reaches transport")
		end, debug.traceback)
		local cleaned, cleanupError = pcall(function()
			for _, path in { build, build .. ".identity.json" } do
				if fs.isFile(path) then
					fs.removeFile(path)
				end
			end
			if fs.isDir(directory) then
				fs.removeDir(directory)
			end
			if fs.isDir(evidence) then
				fs.removeDir(evidence)
			end
		end)
		assert(cleaned, tostring(cleanupError))
		assert(ok, tostring(reason))
	end,
}
