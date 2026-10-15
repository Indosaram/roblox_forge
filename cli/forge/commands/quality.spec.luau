--!strict
-- Specs for the quality command's argument parsing and path resolution, plus
-- one real on-disk run of `M.run` against a temporary fixture so the decode
-- and reporting path is exercised, not only the pure schema module.

local fs = require("@lune/fs")
local tempdir = require("../lib/tempdir")
local serde = require("@lune/serde")

local quality = require("./quality")
local qualitygate = require("../lib/qualitygate")
local qualityevidence = require("../lib/qualityevidence")

local VALID_PROFILE = [[
schema_version: 1
pack: fixture-quality
tier: starter
provisional_targets: true
reference:
  name: coop-survival-bench
  source: first-party capture of games/fixture-quality
  rights_holder: forge
  capture_permission: first-party build, captured by the framework owner
  capture_date: "2026-10-01"
  rubric_version: quality-rubric-v1
  exemplars:
    - surface: desktop
      path: reference/desktop-first-camp.png
    - surface: mobile
      path: reference/mobile-first-camp.png
  disqualifiers:
    - the player cannot tell which object is interactive
rubric:
  version: quality-rubric-v1
  criteria:
    - id: legibility
      target: 4
      anchors:
        1: targets are indistinguishable from scenery
        3: targets read once the player is already adjacent
        5: targets read instantly at normal camera distance
    - id: coherence
      target: 4
      anchors:
        1: assets come from unrelated styles
        3: most assets share a palette, some do not
        5: every asset shares silhouette, palette and scale rules
    - id: feedback
      target: 4
      anchors:
        1: actions resolve with no response at all
        3: actions respond visually but not audibly
        5: every action resolves with paired visual and audio response
    - id: pacing
      target: 4
      anchors:
        1: the first minute has nothing to do
        3: the loop starts but stalls between goals
        5: each goal hands off to the next without a dead stretch
    - id: meaningful-choice
      target: 4
      anchors:
        1: only one action is ever worth taking
        3: choices exist but one dominates
        5: competing options trade off against each other
first_play:
  goals:
    - id: objective-identified
      description: the player names the current objective without being prompted
      within_minutes: 10
      players: 1
    - id: first-gather-craft-meal-rest
      description: one gather, one craft, one meal and one rest are completed
      within_minutes: 10
      players: 1
    - id: shared-facility
      description: two players finish one shared facility together
      within_minutes: 20
      players: 2
asset_quality:
  rights_source: forge-procgen first-party output
  commercial_use: true
  moderation: not-applicable
  platform_approved: false
fun_verdict:
  required: true
  rationale_required: true
  confidence_required: true
]]

local function withFixture(test: (string) -> ())
	local root = tempdir.root() .. "/forge-quality-validate-" .. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
	local ok, reason = xpcall(function()
		fs.writeDir(root)
		test(root)
	end, debug.traceback)
	local cleaned, cleanupError = pcall(function()
		if fs.isDir(root) then
			fs.removeDir(root)
		end
	end)
	assert(cleaned, tostring(cleanupError))
	assert(ok, tostring(reason))
end

return {
	["starter needs no receipt and deployment exceptions never approve release"] = function()
		withFixture(function(root)
			fs.writeDir(root .. "/fixture-quality")
			fs.writeFile(root .. "/fixture-quality/quality.yml", VALID_PROFILE)
			local options: qualitygate.Options = {
				root = root,
				pack = "fixture-quality",
				packDir = "fixture-quality",
				authority = { identity = "", attestationPath = "" },
			}
			local result = qualitygate.check(options)
			assert(
				result.ok and result.code == "STARTER_NOT_RELEASE" and not result.releaseApproved,
				"starter succeeds without granting release approval"
			)
			assert(
				quality.run({ "quality", "check", "--pack", options.pack, "--packs-root", root }),
				"the command accepts the starter fixture without a receipt"
			)
			options.target = "release-candidate"
			assert(not qualitygate.check(options).ok, "missing receipt refuses upgrade")
			options.target = nil
			options.environment = "staging"
			assert(not qualitygate.check(options).ok, "starter deployment needs explicit development")
			options.development = true
			local developmentResult = qualitygate.check(options)
			assert(
				developmentResult.ok
					and developmentResult.code == "STAGING_DEVELOPMENT"
					and not developmentResult.releaseApproved,
				"explicit staging development never grants release approval"
			)
			options.environment = "production"
			assert(not qualitygate.check(options).ok, "development cannot bypass production approval")
			options.development = false
			fs.writeFile(
				root .. "/fixture-quality/quality.yml",
				(string.gsub(VALID_PROFILE, "tier: starter", "tier: release-candidate", 1))
			)
			options.environment = "staging"
			options.target = "starter"
			assert(not qualitygate.check(options).ok, "declared release cannot downgrade target")
			options.target = nil
			options.development = true
			assert(not qualitygate.check(options).ok, "release claim cannot use development override")
			options.development = false
			fs.writeFile(root .. "/fixture-quality/quality.yml", "bad: [")
			assert(not qualitygate.check(options).ok, "invalid profile is never a legacy exemption")
			fs.removeFile(root .. "/fixture-quality/quality.yml")
			options.environment = "production"
			local legacyResult = qualitygate.check(options)
			assert(
				not legacyResult.ok and legacyResult.code == "LEGACY_UNASSESSED" and not legacyResult.releaseApproved,
				"legacy production must refuse without retrofitting the pack"
			)
			options.environment = "staging"
			assert(not qualitygate.check(options).ok, "legacy staging requires an explicit exception")
			options.development = true
			local legacyDevelopment = qualitygate.check(options)
			assert(
				legacyDevelopment.ok and not legacyDevelopment.releaseApproved,
				"legacy development stays unassessed"
			)
			options.development = false
			options.environment = nil
			assert(not qualitygate.check(options).ok, "explicit quality check requires a profile")
		end)
	end,
	["check selectors reject ambiguity and resolve flag before environment"] = function()
		local options = assert(
			quality.parseCheckArgs({ "quality", "check", "--pack", "fixture-quality", "--packs-root", "flag" }),
			"check parses"
		)
		assert(quality.checkPacksRoot(options, { FORGE_QUALITY_PACKS_ROOT = "env" }) == "flag", "flag wins")
		assert(quality.checkPacksRoot({}, { FORGE_QUALITY_PACKS_ROOT = "env" }) == "env", "environment wins default")
		assert(quality.checkPacksRoot({}, {}) == "games", "default games")
		assert(quality.parseCheckArgs({ "quality", "check", "--pack", "../bad" }) == nil, "unsafe slug")
		assert(quality.parseCheckArgs({ "quality", "check", "--pack", "good", "--pack", "other" }) == nil, "duplicate")
		assert(quality.parseCheckArgs({ "quality", "check", "--pack", "good", "--receipt" }) == nil, "missing value")
		-- The evidence selectors are additive and mutually exclusive.
		assert(
			quality.parseCheckArgs({ "quality", "check", "--pack", "good", "--evidence", "e.json" }) ~= nil,
			"--evidence parses"
		)
		assert(
			quality.parseCheckArgs({ "quality", "check", "--pack", "good", "--sweep", "build/sweep/x" }) ~= nil,
			"--sweep parses"
		)
		assert(quality.parseCheckArgs({
			"quality",
			"check",
			"--pack",
			"good",
			"--evidence",
			"e.json",
			"--sweep",
			"x",
		}) == nil, "--evidence and --sweep are mutually exclusive")
	end,

	["an evidence receipt is validated against the pack's declared tier"] = function()
		withFixture(function(root)
			local packDir = root .. "/fixture-quality"
			fs.writeDir(packDir)
			fs.writeFile(packDir .. "/quality.yml", VALID_PROFILE)
			local function steps(overrides: { [string]: boolean }?): any
				local out: any = {}
				for _, name in qualityevidence.REQUIRED_COLUMNS do
					local ok = if overrides ~= nil and overrides[name] ~= nil then overrides[name] else true
					out[name] = { ok = ok, error = if ok then nil else name .. " failed" }
				end
				out.nativeQa.ran, out.nativeQa.passed = 1, 1
				out.load.actors, out.load.actions = 8, 12
				return out
			end
			local function writeSweep(stepOverrides: { [string]: boolean }?)
				fs.writeDir(root .. "/sweep")
				fs.writeFile(
					root .. "/sweep/sweep.json",
					serde.encode("json", {
						stamp = "test",
						genres = { { slug = "fixture-quality", packDir = packDir, steps = steps(stepOverrides) } },
					})
				)
			end
			writeSweep(nil)
			local receiptPath = root .. "/receipt.json"
			assert(
				quality.run({
					"quality",
					"evaluate",
					"--pack",
					"fixture-quality",
					"--sweep",
					root .. "/sweep",
					"--out",
					receiptPath,
				}),
				"evaluate writes a receipt for a green sweep"
			)
			local receipt = serde.decode("json", fs.readFile(receiptPath))
			assert(receipt.tier == "starter" and receipt.releaseApproved == false, "the receipt claims no release")
			assert(receipt.fun.verdict == "human-judgment-pending", "fun stays a human judgment")
			assert(
				quality.run({
					"quality",
					"check",
					"--pack",
					"fixture-quality",
					"--evidence",
					receiptPath,
					"--packs-root",
					root,
				}),
				"check validates the receipt"
			)
			-- A receipt that claims approval is refused, and a failing column is refused.
			receipt.releaseApproved = true
			fs.writeFile(receiptPath, serde.encode("json", receipt))
			assert(not quality.run({
				"quality",
				"check",
				"--pack",
				"fixture-quality",
				"--evidence",
				receiptPath,
				"--packs-root",
				root,
			}), "a receipt that approves a release must be refused")
			writeSweep({ build = false })
			assert(
				not quality.run({ "quality", "check", "--pack", "fixture-quality", "--sweep", root .. "/sweep" }),
				"a failing column must fail the check"
			)
		end)
	end,

	["a capture manifest and an AV source receipt are recorded when present"] = function()
		withFixture(function(root)
			local packDir = root .. "/fixture-quality"
			fs.writeDir(packDir)
			fs.writeFile(packDir .. "/quality.yml", VALID_PROFILE)
			local captures, captureReason = quality.captureEvidence(root .. "/visual", "fixture-quality")
			assert(captures == nil and captureReason ~= nil, "a missing capture run is refused, not silent")
			fs.writeDir(root .. "/visual/runs/fixture-quality")
			fs.writeFile(
				root .. "/visual/runs/fixture-quality/receipt.json",
				serde.encode("json", {
					outcome = {
						captures = {
							{ visualContent = { verdict = "varied", meanDetail = 17.6 } },
							{ visualContent = { verdict = "varied", meanDetail = 12.1 } },
						},
						inconclusive = {},
					},
				})
			)
			captures = assert(quality.captureEvidence(root .. "/visual", "fixture-quality"))
			assert(captures.present == true and captures.captures == 2, "the capture count is recorded")
			assert(captures.visualContent.verdicts.varied == 2, "the gate verdicts are counted")
			assert(captures.visualContent.minMeanDetail == 12.1, "the weakest frame detail is recorded")
			assert(captures.verdict == nil, "capture evidence never carries a quality verdict")
			local absent, absentReason = quality.avEvidence(root .. "/av-source.json")
			assert(absent == nil and absentReason ~= nil, "a missing AV receipt is refused, not silent")
			fs.writeFile(
				root .. "/av-source.json",
				serde.encode("json", {
					schemaVersion = 1,
					sessionId = "session-1",
					buildIdentity = "sha256:abc",
					tracks = { video = 1, audio = 2 },
					original = { path = "original.mp4", sha256 = "deadbeef", byteLength = 1024 },
				})
			)
			local av = assert(quality.avEvidence(root .. "/av-source.json"))
			assert(av.present == true and av.digest ~= nil, "the AV source receipt is bound by digest")
			assert(av.original.byteLength == 1024, "the captured container is recorded")
			assert(av.verdict == nil, "AV evidence never carries a quality verdict")
		end)
	end,
	["validate defaults to the default pack's quality.yml"] = function()
		local options = assert(quality.parseValidateArgs({ "quality", "validate" }), "bare validate parses")
		assert(quality.resolvePath(options) == "games/kaiju-egg-raiders/quality.yml", "default path")
	end,

	["--pack resolves under the packs directory"] = function()
		local options =
			assert(quality.parseValidateArgs({ "quality", "validate", "--pack", "primal-isles" }), "pack parses")
		assert(
			quality.resolvePath(options, { packsDir = "fixtures" }) == "fixtures/primal-isles/quality.yml",
			"pack path honours the context root"
		)
	end,

	["--file wins over the pack default"] = function()
		local options = assert(quality.parseValidateArgs({ "quality", "validate", "--file", "a/b.yml" }), "file parses")
		assert(quality.resolvePath(options) == "a/b.yml", "explicit file path is used verbatim")
	end,

	["--file and --pack are mutually exclusive"] = function()
		local options, reason = quality.parseValidateArgs({ "quality", "validate", "--file", "a.yml", "--pack", "b" })
		assert(options == nil, "both selectors at once must be rejected")
		assert(reason ~= nil and string.find(reason, "mutually exclusive", 1, true) ~= nil, tostring(reason))
	end,

	["a flag without a value is rejected"] = function()
		local options, reason = quality.parseValidateArgs({ "quality", "validate", "--file" })
		assert(options == nil, "a dangling --file must be rejected")
		assert(reason ~= nil and string.find(reason, "--file requires a value", 1, true) ~= nil, tostring(reason))
	end,

	["a repeated selector is rejected"] = function()
		local options, reason =
			quality.parseValidateArgs({ "quality", "validate", "--file", "a.yml", "--file", "b.yml" })
		assert(options == nil, "a duplicate --file must be rejected")
		assert(reason ~= nil and string.find(reason, "given twice", 1, true) ~= nil, tostring(reason))
	end,

	["an unknown flag is rejected"] = function()
		local options, reason = quality.parseValidateArgs({ "quality", "validate", "--approve" })
		assert(options == nil, "unknown flags must not be ignored")
		assert(reason ~= nil and string.find(reason, "--approve", 1, true) ~= nil, tostring(reason))
	end,

	["an unsafe pack slug is rejected"] = function()
		local options, reason = quality.parseValidateArgs({ "quality", "validate", "--pack", "../etc" })
		assert(options == nil, "a traversal slug must be rejected")
		assert(reason ~= nil and string.find(reason, "invalid pack slug", 1, true) ~= nil, tostring(reason))
	end,

	["an unknown subcommand fails"] = function()
		assert(not quality.run({ "quality" }), "quality with no subcommand fails")
		assert(not quality.run({ "quality", "approve" }), "an unimplemented subcommand is not silently accepted")
	end,

	["a valid profile file passes and a missing file fails"] = function()
		withFixture(function(root)
			local path = root .. "/quality-valid.yml"
			fs.writeFile(path, VALID_PROFILE)
			assert(quality.run({ "quality", "validate", "--file", path }), "a valid profile must pass")
			assert(
				not quality.run({ "quality", "validate", "--file", root .. "/absent.yml" }),
				"a missing profile must fail"
			)
		end)
	end,

	["a profile missing its reference fails the real command"] = function()
		withFixture(function(root)
			-- Strip exactly the `reference:` block out of the valid text so the
			-- missing reference is the ONLY defect. Decoding and re-encoding the
			-- document instead would also drop the numeric anchor keys, and this
			-- case would then fail for reasons it is not testing.
			local text = string.gsub(VALID_PROFILE, "reference:\n.-\nrubric:\n", "rubric:\n", 1)
			assert(string.find(text, "reference:", 1, true) == nil, "the reference block is gone")
			assert(string.find(text, "rubric:", 1, true) ~= nil, "the rest of the document survives")
			local path = root .. "/quality-no-reference.yml"
			fs.writeFile(path, text)
			assert(
				not quality.run({ "quality", "validate", "--file", path }),
				"a profile without a reference package must fail"
			)
		end)
	end,

	["an undecodable profile fails instead of being skipped"] = function()
		withFixture(function(root)
			local path = root .. "/broken.yml"
			fs.writeFile(path, "schema_version: 1\n\tbad: [unclosed\n")
			assert(not quality.run({ "quality", "validate", "--file", path }), "a broken document must fail")
		end)
	end,
}
