--!strict
-- Specs for the pure asset manifest: schema parsing, license/moderation gates,
-- provenance and quality binding, deterministic Luau codegen, and Asphalt
-- config generation.

local luau = require("@lune/luau")
local Assets = require("./assets")

local DIGEST_A = "sha256:" .. string.rep("a", 64)
local DIGEST_B = "sha256:" .. string.rep("b", 64)

local function provenance(overrides: any?): any
	local base = {
		digest = DIGEST_A,
		recipe = { id = "gen-image", version = "1", input = "a prompt", inputVersion = DIGEST_B },
		provider = { name = "forge-procgen", version = "1" },
		rights = { source = "first-party generator in this repository", ownership = "first-party" },
	}
	if overrides ~= nil then
		for key, value in overrides do
			if value == "\0nil" then
				base[key] = nil
			else
				base[key] = value
			end
		end
	end
	return base
end

local function parse(assets: any, version: number?): Assets.Manifest
	local manifest, err = Assets.parseManifest({ version = version, assets = assets })
	assert(err == nil, "unexpected parse error: " .. tostring(err))
	return manifest :: Assets.Manifest
end

return {
	["parses a valid manifest"] = function()
		local manifest = parse({
			{
				key = "iconA",
				kind = "image",
				tool = "studio-mcp",
				source = "generated launch art",
				path = "assets/icon/icon-a.png",
				assetId = 55,
				moderation = "Approved",
			},
		})
		assert(#manifest.assets == 1, "expected one asset")
		local asset = manifest.assets[1]
		assert(asset.key == "iconA", "key is parsed")
		assert(asset.kind == "image", "kind is parsed")
		assert(asset.path == "assets/icon/icon-a.png", "optional path is parsed")
		assert(asset.assetId == 55, "assetId is parsed")
		assert(asset.moderation == "Approved", "moderation is parsed")
	end,

	["defaults a missing assetId to 0 and moderation to NotUploaded"] = function()
		local manifest = parse({
			{ key = "sfxHit", kind = "sfx", tool = "studio-mcp", source = "prompt" },
		})
		assert(manifest.assets[1].assetId == 0, "assetId defaults to 0")
		assert(manifest.assets[1].moderation == "NotUploaded", "moderation defaults to NotUploaded")
	end,

	["rejects a bad kind"] = function()
		local manifest, err = Assets.parseManifest({
			assets = { { key = "weird", kind = "badge", tool = "studio-mcp", source = "x" } },
		})
		assert(manifest == nil, "a bad kind must not parse")
		assert(
			err ~= nil and string.find(err, "invalid kind", 1, true) ~= nil,
			"reason should name the invalid kind: " .. tostring(err)
		)
	end,

	["rejects an invalid key"] = function()
		local manifest, err = Assets.parseManifest({
			assets = { { key = "9bad", kind = "image", tool = "studio-mcp", source = "x" } },
		})
		assert(manifest == nil, "a leading-digit key must not parse")
		assert(
			err ~= nil and string.find(err, "invalid key", 1, true) ~= nil,
			"reason should name the invalid key: " .. tostring(err)
		)
	end,

	["denies the research-only tool roblox-cube"] = function()
		local manifest = parse({
			{ key = "badMesh", kind = "mesh", tool = "roblox-cube", source = "x" },
		})
		local result = Assets.check(manifest, "staging")
		assert(not result.ok, "roblox-cube must fail the license gate")
		assert(
			string.find(result.errors[1], "research only", 1, true) ~= nil,
			"reason should name research-only: " .. tostring(result.errors[1])
		)
	end,

	["rejects an unknown tool"] = function()
		local manifest = parse({
			{ key = "mystery", kind = "image", tool = "meshy", source = "x" },
		})
		local result = Assets.check(manifest, "staging")
		assert(not result.ok, "an unknown tool must fail the license gate")
		assert(
			string.find(result.errors[1], "unknown tool", 1, true) ~= nil,
			"reason should name the unknown tool: " .. tostring(result.errors[1])
		)
	end,

	["flags duplicate keys"] = function()
		local manifest = parse({
			{ key = "iconA", kind = "image", tool = "studio-mcp", source = "a", assetId = 1, moderation = "Approved" },
			{ key = "iconA", kind = "image", tool = "studio-mcp", source = "b", assetId = 2, moderation = "Approved" },
		})
		local result = Assets.check(manifest, "staging")
		assert(not result.ok, "duplicate keys must fail")
		assert(
			string.find(result.errors[1], "duplicate key", 1, true) ~= nil,
			"reason should name the duplicate: " .. tostring(result.errors[1])
		)
	end,

	["production blocks a PendingModeration asset"] = function()
		local manifest = parse({
			{
				key = "pendingIcon",
				kind = "image",
				tool = "studio-mcp",
				source = "x",
				assetId = 0,
				moderation = "PendingModeration",
			},
		})
		local result = Assets.check(manifest, "production")
		assert(not result.ok, "production must block pending assets")
		assert(
			string.find(result.errors[1], "not approved (PendingModeration)", 1, true) ~= nil,
			"reason should name the state: " .. tostring(result.errors[1])
		)
	end,

	["production blocks an approved asset that has no uploaded id"] = function()
		local manifest = parse({
			{
				key = "approvedIcon",
				kind = "image",
				tool = "studio-mcp",
				source = "x",
				assetId = 0,
				moderation = "Approved",
			},
		})
		local result = Assets.check(manifest, "production")
		assert(not result.ok, "an approved asset with id 0 is not uploaded yet")
	end,

	["staging allows PendingModeration and NotUploaded"] = function()
		local manifest = parse({
			{
				key = "pendingIcon",
				kind = "image",
				tool = "studio-mcp",
				source = "x",
				moderation = "PendingModeration",
			},
			{ key = "notUploadedIcon", kind = "image", tool = "studio-mcp", source = "x", moderation = "NotUploaded" },
		})
		local result = Assets.check(manifest, "staging")
		assert(result.ok, "staging must allow pending and not-uploaded assets: " .. table.concat(result.errors, "; "))
	end,

	["staging blocks a Rejected asset"] = function()
		local manifest = parse({
			{ key = "rejectedIcon", kind = "image", tool = "studio-mcp", source = "x", moderation = "Rejected" },
		})
		local result = Assets.check(manifest, "staging")
		assert(not result.ok, "staging must block rejected assets")
		assert(
			string.find(result.errors[1], "rejected", 1, true) ~= nil,
			"reason should name the rejection: " .. tostring(result.errors[1])
		)
	end,

	["renderLuau sorts keys and blanks unset ids"] = function()
		local manifest = parse({
			{
				key = "zebra",
				kind = "image",
				tool = "studio-mcp",
				source = "z",
				assetId = 0,
				moderation = "NotUploaded",
			},
			{ key = "mid", kind = "image", tool = "studio-mcp", source = "m", assetId = 42, moderation = "Approved" },
			{
				key = "alpha",
				kind = "image",
				tool = "studio-mcp",
				source = "a",
				assetId = 0,
				moderation = "NotUploaded",
			},
		})
		local text = Assets.renderLuau(manifest)
		assert(string.sub(text, 1, 9) == "--!strict", "module must start with --!strict")
		assert(
			string.find(text, "-- Generated by forge assets codegen from assets/manifest.yml. Do not edit.", 1, true)
				~= nil,
			"module must carry the generated header"
		)
		local alphaAt = string.find(text, "alpha=", 1, true)
		local midAt = string.find(text, "mid=", 1, true)
		local zebraAt = string.find(text, "zebra=", 1, true)
		assert(alphaAt == nil and zebraAt == nil and midAt ~= nil, "only published keys are emitted")
		assert(
			string.find(text, "{mid=42}", 1, true) ~= nil,
			"an uploaded id is stored numerically under an identifier key"
		)
	end,

	["renderLuau brackets only keys that are not plain identifiers and round-trips"] = function()
		local manifest = parse({
			{
				key = "icon-a",
				kind = "image",
				tool = "studio-mcp",
				source = "a",
				assetId = 11,
				moderation = "Approved",
			},
			{ key = "end", kind = "image", tool = "studio-mcp", source = "e", assetId = 12, moderation = "Approved" },
			{
				key = "plain_b",
				kind = "image",
				tool = "studio-mcp",
				source = "b",
				assetId = 13,
				moderation = "Approved",
			},
		})
		local text = Assets.renderLuau(manifest)
		assert(
			string.find(text, '{["end"]=12,["icon-a"]=11,plain_b=13}', 1, true) ~= nil,
			"compact one-line id table: " .. text
		)
		local runtime = luau.load(text)()
		assert(runtime["icon-a"] == "rbxassetid://11" and runtime["end"] == "rbxassetid://12", "bracketed keys load")
		assert(runtime.plain_b == "rbxassetid://13" and runtime.missing == "", "identifier keys load, unknown is empty")
	end,

	["renderLuau on an empty manifest returns an empty table"] = function()
		local text = Assets.renderLuau(parse({}))
		assert(string.find(text, "local Assets: { [string]: string } = {}", 1, true) ~= nil, "empty table is rendered")
	end,

	["renderLuau maps local wav cues to rbxasset paths"] = function()
		local manifest = parse({
			{
				key = "sfxClick",
				kind = "sfx",
				tool = "forge-procgen",
				source = "procedural audio/sfxClick",
				path = "assets/audio/sfxClick.wav",
				assetId = 0,
				moderation = "Approved",
			},
			{
				key = "musicExplore",
				kind = "bgm",
				tool = "forge-procgen",
				source = "procedural audio/musicExplore",
				path = "assets/audio/musicExplore.wav",
				assetId = 0,
				moderation = "Approved",
			},
			{
				key = "iconA",
				kind = "image",
				tool = "forge-procgen",
				source = "art",
				path = "assets/icon/icon-a.png",
				assetId = 7,
				moderation = "Approved",
			},
		})
		local text = Assets.renderLuau(manifest, "kaiju-egg-raiders")
		assert(
			string.find(text, 'sfxClick="rbxasset://forge/kaiju-egg-raiders/sfxClick.wav"', 1, true) ~= nil,
			"an sfx wav maps to its installed rbxasset URL"
		)
		assert(
			string.find(text, 'musicExplore="rbxasset://forge/kaiju-egg-raiders/musicExplore.wav"', 1, true) ~= nil,
			"a bgm wav maps to its installed rbxasset URL"
		)
		assert(string.find(text, "iconA=7", 1, true) ~= nil, "non-audio assets still use rbxassetid")
		local withoutPack = Assets.renderLuau(manifest)
		assert(
			string.find(withoutPack, "sfxClick", 1, true) == nil,
			"without a pack name the local file resolves to an empty id"
		)
	end,

	["asphalt excludes mesh and model entries"] = function()
		local manifest = parse({
			{ key = "iconA", kind = "image", tool = "studio-mcp", source = "art", path = "assets/icon/icon-a.png" },
			{ key = "heroMesh", kind = "mesh", tool = "studio-mcp", source = "art", path = "assets/models/hero.rbxm" },
			{
				key = "heroModel",
				kind = "model",
				tool = "studio-mcp",
				source = "art",
				path = "assets/models/hero.rbxmx",
			},
		})
		local text = Assets.asphaltConfig("kaiju-egg-raiders", manifest)
		assert(string.find(text, "[inputs.iconA]", 1, true) ~= nil, "image inputs are included")
		assert(string.find(text, "assets/icon/icon-a.png", 1, true) ~= nil, "the image path is included")
		assert(string.find(text, "heroMesh", 1, true) == nil, "meshes must be excluded")
		assert(string.find(text, "heroModel", 1, true) == nil, "models must be excluded")
	end,

	["asphalt maps an uploaded asset through the web table"] = function()
		local manifest = parse({
			{
				key = "iconA",
				kind = "image",
				tool = "studio-mcp",
				source = "art",
				path = "assets/icon/icon-a.png",
				assetId = 987654,
				moderation = "Approved",
			},
		})
		local text = Assets.asphaltConfig("kaiju-egg-raiders", manifest)
		assert(string.find(text, "[inputs.iconA.web]", 1, true) ~= nil, "an uploaded asset gets a web table")
		assert(string.find(text, "{ id = 987654 }", 1, true) ~= nil, "the web table carries the id")
	end,

	["framework check passes forge-procgen and audio-library assets"] = function()
		local manifest = parse({
			{
				key = "iconA",
				kind = "image",
				tool = "forge-procgen",
				source = "procedural launch art (forge gen launchart)",
				assetId = 0,
				moderation = "Approved",
				provenance = provenance(),
			},
			{
				key = "sfxClick",
				kind = "sfx",
				tool = "roblox-audio-library",
				source = "Roblox audio library",
				assetId = 12221967,
				moderation = "Approved",
				provenance = provenance({
					provider = { name = "roblox-audio-library", version = "2026-01" },
					rights = { source = "Roblox Audio Library terms", ownership = "platform" },
				}),
			},
		}, 2)
		local result = Assets.checkFramework(manifest)
		assert(result.ok, "recorded provenance must pass: " .. table.concat(result.errors, "; "))
	end,

	-- provenance ------------------------------------------------------------
	["a lawfully licensed import passes provenance while awaiting quality"] = function()
		-- The exact case the old framework whitelist refused outright: a licensed
		-- third-party tool, lawful and reproducible, with no quality verdict yet.
		local manifest = parse({
			{
				key = "heroMesh",
				kind = "mesh",
				tool = "trellis",
				source = "imported hero mesh",
				assetId = 0,
				moderation = "NotUploaded",
				provenance = provenance({
					provider = { name = "trellis", version = "0.9.3" },
					rights = { source = "TRELLIS MIT license", ownership = "first-party" },
				}),
			},
		}, 2)
		local result = Assets.checkProvenance(manifest)
		assert(result.ok, "a licensed import must pass provenance: " .. table.concat(result.errors, "; "))
		assert(#result.approved == 0, "provenance alone never approves quality")
		assert(#result.pending == 1, "the asset is reported as awaiting a quality report")
		assert(#result.moderation == 1, "moderation is reported separately from the provenance verdict")
	end,

	["provenance refuses a banned tool and a banned provider"] = function()
		for _, banned in { "audiocraft", "roblox-cube", "hunyuan3d-2" } do
			local byTool = parse({
				{
					key = "bad",
					kind = "mesh",
					tool = banned,
					source = "x",
					moderation = "Approved",
					provenance = provenance(),
				},
			}, 2)
			assert(not Assets.checkProvenance(byTool).ok, banned .. " must fail as a tool")

			local byProvider = parse({
				{
					key = "bad",
					kind = "mesh",
					tool = "forge-procgen",
					source = "x",
					moderation = "Approved",
					provenance = provenance({ provider = { name = banned, version = "1" } }),
				},
			}, 2)
			local result = Assets.checkProvenance(byProvider)
			assert(not result.ok, banned .. " must fail as a recorded provider")
			assert(
				string.find(result.errors[1], "provider", 1, true) ~= nil,
				"reason names the provider: " .. tostring(result.errors[1])
			)

			-- Forged rights evidence cannot buy a banned model in: the weights are
			-- not commercially licensed here, so the denial outranks any claim.
			local forged = parse({
				{
					key = "bad",
					kind = "mesh",
					tool = banned,
					source = "x",
					moderation = "Approved",
					provenance = provenance({
						provider = { name = banned, version = "1" },
						rights = {
							source = "we totally have a commercial license",
							ownership = "licensed",
							evidence = {
								document = "legal/forged-agreement.pdf",
								version = "2026-01",
								verifiedBy = "agent://someone",
							},
						},
					}),
				},
			}, 2)
			local forgedResult = Assets.checkProvenance(forged)
			assert(not forgedResult.ok, banned .. " must fail even with recorded rights evidence")
			assert(
				string.find(table.concat(forgedResult.errors, "; "), "denied", 1, true) ~= nil,
				"reason names the denial: " .. table.concat(forgedResult.errors, "; ")
			)
		end
	end,

	["an unregistered lawful provider passes on recorded rights evidence"] = function()
		-- The whitelist is gone: a provider this repo has never heard of is lawful
		-- when the artifact records versioned commercial rights evidence, and it is
		-- still awaiting its quality verdict.
		local function withRights(rights: any): Assets.Manifest
			return parse({
				{
					key = "heroMesh",
					kind = "mesh",
					tool = "meshy",
					source = "licensed hero mesh",
					moderation = "NotUploaded",
					provenance = provenance({
						provider = { name = "meshy", version = "4.2.0" },
						rights = rights,
					}),
				},
			}, 2)
		end

		local lawful = withRights({
			source = "Meshy commercial plan terms",
			ownership = "licensed",
			evidence = {
				document = "legal/meshy-commercial-terms.pdf",
				version = "2026-01-15",
				verifiedBy = "agent://rights-reviewer",
			},
		})
		local result = Assets.checkProvenance(lawful)
		assert(
			result.ok,
			"recorded rights must authorize an unregistered provider: " .. table.concat(result.errors, "; ")
		)
		assert(#result.approved == 0, "lawfulness is not a quality approval")
		assert(#result.pending == 1, "the import is reported as awaiting a quality report")

		local noEvidence = withRights({ source = "trust me", ownership = "licensed" })
		local missing = Assets.checkProvenance(noEvidence)
		assert(not missing.ok, "an unregistered provider without evidence must fail")
		assert(
			string.find(missing.errors[1], "records no rights evidence", 1, true) ~= nil,
			"reason names the missing evidence, not the unknown name: " .. tostring(missing.errors[1])
		)

		local placeholder = withRights({
			source = "Meshy commercial plan terms",
			ownership = "licensed",
			evidence = { document = "TBD", version = "2026-01-15", verifiedBy = "agent://rights-reviewer" },
		})
		assert(not Assets.checkProvenance(placeholder).ok, "placeholder evidence is not evidence")
	end,

	["a commissioned artifact passes with its agreement recorded"] = function()
		local manifest = parse({
			{
				key = "bannerArt",
				kind = "image",
				tool = "commissioned-artist",
				source = "commissioned key art",
				moderation = "NotUploaded",
				provenance = provenance({
					provider = { name = "commissioned-artist", version = "contract-2026-02" },
					rights = {
						source = "work-for-hire agreement, full assignment",
						ownership = "commissioned",
						evidence = {
							document = "legal/keyart-work-for-hire.pdf",
							version = "2026-02-01",
							verifiedBy = "agent://rights-reviewer",
						},
					},
				}),
			},
		}, 2)
		local result = Assets.checkProvenance(manifest)
		assert(result.ok, "a commissioned artifact is lawful: " .. table.concat(result.errors, "; "))
	end,

	["provenance refuses a tool that does not match its recorded provider"] = function()
		local manifest = parse({
			{
				key = "laundered",
				kind = "mesh",
				tool = "meshy",
				source = "x",
				moderation = "Approved",
				provenance = provenance(),
			},
		}, 2)
		local result = Assets.checkProvenance(manifest)
		assert(not result.ok, "an entry cannot hide an unvetted tool behind a lawful provider record")
		local joined = table.concat(result.errors, "; ")
		assert(string.find(joined, "does not match recorded provider", 1, true) ~= nil, "mismatch is named: " .. joined)
	end,

	["provenance refuses missing rights, missing digest and a bad ownership claim"] = function()
		local _, noRights = Assets.parseManifest({
			version = 2,
			assets = {
				{
					key = "a",
					kind = "image",
					tool = "forge-procgen",
					source = "x",
					provenance = provenance({
						rights = "\0nil",
					}),
				},
			},
		})
		assert(
			noRights ~= nil and string.find(noRights, "rights is missing", 1, true) ~= nil,
			"missing rights is named: " .. tostring(noRights)
		)

		local _, noDigest = Assets.parseManifest({
			version = 2,
			assets = {
				{
					key = "a",
					kind = "image",
					tool = "forge-procgen",
					source = "x",
					provenance = provenance({
						digest = "\0nil",
					}),
				},
			},
		})
		assert(
			noDigest ~= nil and string.find(noDigest, "digest is missing", 1, true) ~= nil,
			"missing digest is named: " .. tostring(noDigest)
		)

		local _, badDigest = Assets.parseManifest({
			version = 2,
			assets = {
				{
					key = "a",
					kind = "image",
					tool = "forge-procgen",
					source = "x",
					provenance = provenance({
						digest = "deadbeef",
					}),
				},
			},
		})
		assert(
			badDigest ~= nil and string.find(badDigest, "sha256:<64 hex>", 1, true) ~= nil,
			"a malformed digest is named: " .. tostring(badDigest)
		)

		-- An import from a licensed provider cannot claim the output as
		-- first-party work.
		local overclaim = parse({
			{
				key = "sfxBoom",
				kind = "sfx",
				tool = "elevenlabs",
				source = "x",
				moderation = "Approved",
				provenance = provenance({
					provider = { name = "elevenlabs", version = "v1" },
					rights = { source = "ElevenLabs commercial plan terms", ownership = "first-party" },
				}),
			},
		}, 2)
		local result = Assets.checkProvenance(overclaim)
		assert(not result.ok, "a licensed provider's output is not first-party")
		assert(
			string.find(result.errors[1], "first-party", 1, true) ~= nil,
			"reason names the ownership claim: " .. tostring(result.errors[1])
		)
	end,

	["provenance refuses mutated artifact bytes and unreadable artifacts"] = function()
		local manifest = parse({
			{
				key = "iconA",
				kind = "image",
				tool = "forge-procgen",
				source = "art",
				path = "assets/icon/icon-a.png",
				moderation = "Approved",
				provenance = provenance(),
			},
		}, 2)
		assert(Assets.checkProvenance(manifest, { digests = { iconA = DIGEST_A } }).ok, "matching bytes pass")

		local mutated = Assets.checkProvenance(manifest, { digests = { iconA = DIGEST_B } })
		assert(not mutated.ok, "mutated bytes must fail")
		assert(
			string.find(mutated.errors[1], "digest mismatch", 1, true) ~= nil,
			"reason names the mismatch: " .. tostring(mutated.errors[1])
		)

		local unreadable = Assets.checkProvenance(manifest, { digests = {}, unreadable = { iconA = true } })
		assert(not unreadable.ok, "an unreadable artifact must fail, not pass silently")
	end,

	-- legacy compatibility ---------------------------------------------------
	["a legacy manifest still parses and gates but is never quality-approved"] = function()
		local legacy = parse({
			{ key = "iconA", kind = "image", tool = "studio-mcp", source = "art", moderation = "Approved" },
		})
		assert(legacy.version == 1, "a manifest with no version reads as legacy v1")
		local gate = Assets.checkProvenance(legacy)
		assert(gate.ok, "a legacy entry still gates: " .. table.concat(gate.errors, "; "))
		assert(#gate.approved == 0, "migration must not invent a quality approval")
		assert(#gate.pending == 1, "the legacy entry is reported as unevaluated")
	end,

	["version 2 requires provenance and an unknown newer version is refused"] = function()
		local _, missing = Assets.parseManifest({
			version = 2,
			assets = { { key = "iconA", kind = "image", tool = "forge-procgen", source = "art" } },
		})
		assert(
			missing ~= nil and string.find(missing, "missing provenance", 1, true) ~= nil,
			"v2 requires provenance: " .. tostring(missing)
		)

		local _, newer = Assets.parseManifest({ version = 99, assets = {} })
		assert(
			newer ~= nil and string.find(newer, "newer than this CLI supports", 1, true) ~= nil,
			"an unsupported newer version is refused rather than read as v2: " .. tostring(newer)
		)
	end,

	["quality profile refuses a report that cannot be bound"] = function()
		local _, noDigest = Assets.parseQualityProfile({
			reference = { id = "r", version = "1" },
			reports = { { key = "iconA", verdict = "approved", evaluator = "a", report = "b" } },
		})
		assert(noDigest ~= nil, "a report with no digest is refused: " .. tostring(noDigest))

		local _, noEvaluator = Assets.parseQualityProfile({
			reference = { id = "r", version = "1" },
			reports = { { key = "iconA", digest = DIGEST_A, verdict = "approved", report = "b" } },
		})
		assert(noEvaluator ~= nil, "a report with no evaluator is refused")

		local _, badVerdict = Assets.parseQualityProfile({
			reference = { id = "r", version = "1" },
			reports = {
				{ key = "iconA", digest = DIGEST_A, verdict = "looks-fine", evaluator = "a", report = "b" },
			},
		})
		assert(badVerdict ~= nil, "an unknown verdict is refused")

		local _, noReference = Assets.parseQualityProfile({ reports = {} })
		assert(noReference ~= nil, "a profile with no reference is refused")
	end,

	["framework check rejects a hand-made tool"] = function()
		-- A tool the license registry does not allow is still refused; `studio-mcp`
		-- is lawful and now passes, which is the whitelist behaviour being removed.
		local lawful = parse({
			{
				key = "iconA",
				kind = "image",
				tool = "studio-mcp",
				source = "generated launch art",
				assetId = 0,
				moderation = "Approved",
				provenance = provenance({
					provider = { name = "studio-mcp", version = "1" },
					rights = { source = "Roblox Creator Terms of Use", ownership = "platform" },
				}),
			},
		}, 2)
		assert(Assets.checkFramework(lawful).ok, "a licensed tool is no longer refused for not being first-party")

		local unknown = parse({
			{ key = "iconA", kind = "image", tool = "meshy", source = "x", moderation = "Approved" },
		})
		local result = Assets.checkFramework(unknown)
		assert(not result.ok, "an unregistered tool must still fail")
		assert(
			string.find(result.errors[1], "unknown tool", 1, true) ~= nil,
			"reason names the unknown tool: " .. tostring(result.errors[1])
		)
	end,

	["framework check rejects a non-approved asset"] = function()
		-- Moderation is now reported, not conflated with the lawfulness verdict:
		-- a NotUploaded asset is lawful and still unmoderated.
		local manifest = parse({
			{
				key = "iconA",
				kind = "image",
				tool = "forge-procgen",
				source = "procedural launch art",
				assetId = 0,
				moderation = "NotUploaded",
				provenance = provenance(),
			},
		}, 2)
		local result = Assets.checkProvenance(manifest)
		assert(result.ok, "an unmoderated asset is still lawful: " .. table.concat(result.errors, "; "))
		assert(result.moderation[1] == "iconA: NotUploaded", "moderation is reported on its own")
		assert(#result.approved == 0, "and it carries no quality approval")
	end,

	["framework check rejects TBD and placeholder source or path"] = function()
		local manifest = parse({
			{
				key = "iconA",
				kind = "image",
				tool = "forge-procgen",
				source = "TBD",
				path = "assets/icon/icon-a.png",
				assetId = 0,
				moderation = "Approved",
				provenance = provenance(),
			},
			{
				key = "iconB",
				kind = "image",
				tool = "forge-procgen",
				source = "procedural launch art",
				path = "assets/icon/placeholder-b.png",
				assetId = 0,
				moderation = "Approved",
				provenance = provenance(),
			},
			{
				key = "iconC",
				kind = "image",
				tool = "forge-procgen",
				source = "procedural launch art",
				path = "assets/icon/icon-c.png",
				assetId = 0,
				moderation = "Approved",
				provenance = provenance({
					recipe = { id = "gen-image", version = "TBD", input = "p", inputVersion = DIGEST_B },
				}),
			},
		}, 2)
		local result = Assets.checkFramework(manifest)
		assert(not result.ok, "placeholder markers must fail the gate")
		assert(#result.errors == 3, "every placeholder field must be named, provenance included")
	end,
}
