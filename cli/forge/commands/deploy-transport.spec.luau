--!strict
-- Synthetic local admission data, never a real evaluator or Studio receipt.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local deploy = require("./deploy")
local profileLib = require("../lib/qualityprofile")
local receipt = require("../lib/qualityreceipt")
local gate = require("../lib/qualitygate")
local runtime = require("../fixtures/quality-runtime")
local buildtargets = require("../lib/buildtargets")
local roblox = require("@lune/roblox")
local unit = require("../fixtures/quality-unit")(".")
receipt, gate, deploy = unit.receipt, unit.gate, unit.deploy

type Approved = {
	pack: string,
	directory: string,
	build: string,
	env: { [string]: string? },
}

--- Writes an approved release-candidate fixture pack (synthetic receipt and
--- attestation over `build/<pack>.rbxl`), runs `body`, and removes everything.
--- `rebuild` replaces the synthetic artifact before the receipt binds it.
local function withApproved(
	pack: string,
	deployYml: string,
	tree: any?,
	rebuild: ((directory: string, build: string) -> ())?,
	body: (Approved) -> ()
)
	local directory = "games/" .. pack
	local evidence = ".omo/fixtures/" .. pack
	local build = "build/" .. pack .. ".rbxl"
	assert(not fs.isDir(directory) and not fs.isFile(directory), "not fs.isDir(directory) and not fs.isFile(directory)")
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
		fs.writeFile(directory .. "/deploy.yml", deployYml)
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
		local identity = runtime(profile, input, review, nil, tree)
		if rebuild then
			rebuild(directory, build)
		end
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
		assert(admitted.ok and admitted.releaseApproved, admitted.code .. ": " .. table.concat(admitted.errors, "; "))
		body({ pack = pack, directory = directory, build = build, env = env })
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
end

local ROLES = {
	"onboarding",
	"home",
	"harbor",
	"archipelago",
	"explore10",
	"explore20",
	"frontier30",
	"frontier40",
	"frontier50",
	"frontier60",
	"brawl",
	"team-outpost",
	"town",
}

return {
	["approved release caller preserves gates bytes and one attempt through actual adapter"] = function()
		withApproved(
			"fixture-task-fifteen-deploy",
			"environments:\n  production:\n    universeId: 42\n    placeId: 7\n  staging:\n    universeId: 99\n    placeId: 8\n",
			nil,
			nil,
			function(fixture: Approved)
				local pack, build, env = fixture.pack, fixture.build, fixture.env
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
			end
		)
	end,
	["production environment build embeds the role and product maps the non-development deploy accepts"] = function()
		local pack = "fixture-b6-production-build"
		local yml = "environments:\n  production:\n    universeId: 42\n    placeId: 7\n    roles:\n"
		for index, role in ROLES do
			yml ..= string.format(
				"      %s: %s\n",
				role,
				if role == "onboarding"
					then "7"
					elseif role == "town" then "${FORGE_PRODUCTION_ROLE_TOWN}"
					else tostring(100 + index)
			)
		end
		yml ..= "    monetization:\n      patron: ${FORGE_PRODUCTION_PRODUCT_PATRON}\n      unset: ${FORGE_PRODUCTION_PRODUCT_UNSET}\n"
		yml ..= "  staging:\n    universeId: 99\n    placeId: 8\n"
		local variables: { [string]: string? } = {
			FORGE_PRODUCTION_ROLE_TOWN = "555",
			FORGE_PRODUCTION_PRODUCT_PATRON = "123",
		}
		local built: buildtargets.TargetResult? = nil
		withApproved(
			pack,
			yml,
			{ ["$className"] = "DataModel", ReplicatedStorage = { Ping = { ["$className"] = "RemoteEvent" } } },
			function(directory: string, build: string)
				-- The one owned build, exactly as runbook step 1 calls it, plus the environment.
				built = buildtargets.runTarget({
					kind = "pack",
					slug = pack,
					packDir = directory,
					projectPath = directory .. "/default.project.json",
					outputPath = build,
				}, nil, "production", variables)
			end,
			function(fixture: Approved)
				local result = assert(built, "environment build ran")
				assert(result.ok, table.concat(result.errors, "; "))
				local artifact = fs.readFile(fixture.build)
				local sidecar = serde.decode("json", fs.readFile(fixture.build .. ".identity.json"))
				assert(
					sidecar.build == "sha256:" .. serde.hash("sha256", artifact),
					"identity digest binds the bytes that carry the maps"
				)
				local storage = roblox.deserializePlace(artifact):FindFirstChild("ServerStorage") :: any
				local roles = serde.decode("json", storage:FindFirstChild("ForgePlaceRoles").Value)
				local ids = serde.decode("json", storage:FindFirstChild("ForgeMonetizationIds").Value)
				assert(
					roles.onboarding == 7 and roles.town == 555 and roles.home == 102,
					"production role map embedded"
				)
				assert(ids.patron == 123 and ids.unset == 0, "production product ids embedded")

				local env = table.clone(fixture.env)
				for name, value in variables do
					env[name] = value
				end
				local args = { "deploy", "--env", "production", "--pack", pack, "--all-roles" }
				local calls = 0
				local others: { [string]: string } =
					{ FORGE_PRODUCTION_PRODUCT_PATRON = "999", FORGE_PRODUCTION_ROLE_TOWN = "556" }
				for name, value in others do
					local other = table.clone(env)
					other[name] = value
					assert(not deploy.run(args, {
						env = other,
						request = function(_request: any): any
							calls += 1
							error("mismatched artifact reached transport")
						end,
					}), "an artifact built for other ids is refused: " .. name)
				end
				assert(calls == 0, "configuration mismatch refuses before transport")
				assert(
					deploy.run(args, {
						env = env,
						request = function(request: any): any
							calls += 1
							assert(request.body == artifact, "publishes the evaluated bytes unchanged")
							return { statusCode = 200, ok = true, body = '{"versionNumber":1}' }
						end,
					}),
					"production --all-roles accepts the environment-built artifact"
				)
				assert(calls == #ROLES, "every role place published once")
				assert(fs.readFile(fixture.build) == artifact, "deploy never rebuilds or patches")
			end
		)
	end,
}
