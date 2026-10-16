--!strict
-- Specs for the provenance gate (QA-PROV-01 / QA-NAME-01). Every case starts
-- from the clean fixture pack and changes one thing, so each negative case
-- proves its rule can fail and the clean pack proves it can pass. Fixture
-- reference text is synthetic (cli/forge/fixtures/provenance/corpus).

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local provenance = require("./provenance")

local CLEAN = "cli/forge/fixtures/provenance/packs/clean"
local CORPUS = "cli/forge/fixtures/provenance/corpus/synthetic-reference.txt"
local SET = "synthetic-ref"
-- Eight-plus consecutive code points of the synthetic reference sentence.
local REFERENCE_SLICE = "물결을 따라 모래톱 끝까지 걸어간 조사단"

local function cleanFiles(): { [string]: string }
	local files: { [string]: string } = {}
	for _, rel in provenance.FILES do
		local path = CLEAN .. "/" .. rel
		if fs.isFile(path) then
			files[rel] = fs.readFile(path)
		end
	end
	return files
end

local function cleanSets(): { [string]: provenance.SetFiles }
	local base = CLEAN .. "/provenance/fingerprints/" .. SET
	return { [SET] = { fp = fs.readFile(base .. ".fp"), meta = fs.readFile(base .. ".meta.yml") } }
end

local function run(
	mutate: ((files: { [string]: string }, sets: { [string]: provenance.SetFiles }) -> ())?
): provenance.Report
	local files = cleanFiles()
	local sets = cleanSets()
	if mutate then
		mutate(files, sets)
	end
	return provenance.checkPack("fixture", files, sets)
end

local function rules(report: provenance.Report): { [string]: number }
	local counts: { [string]: number } = {}
	for _, finding in report.findings do
		counts[finding.rule] = (counts[finding.rule] or 0) + 1
	end
	return counts
end

local function describe(report: provenance.Report): string
	local lines: { string } = {}
	for _, finding in report.findings do
		table.insert(lines, provenance.formatFinding(report.pack, finding))
	end
	return table.concat(lines, "\n")
end

local function addLocale(files: { [string]: string }, key: string, cell: string)
	files[provenance.FILES.locale] ..= string.format('%s,Hi,ctx,Hi,"%s"\n', key, cell)
	files[provenance.FILES.localeProv] ..= key .. ",original,human:indo,2026-10-16\n"
end

local function expectRule(report: provenance.Report, rule: string, count: number?)
	local got = rules(report)[rule] or 0
	assert(not report.ok, "expected FAIL with " .. rule)
	if count then
		assert(got == count, string.format("expected %d %s, got %d:\n%s", count, rule, got, describe(report)))
	else
		assert(got > 0, "expected " .. rule .. ":\n" .. describe(report))
	end
end

local function expectOk(report: provenance.Report)
	assert(report.ok, "expected PASS:\n" .. describe(report))
end

return {
	-- QA-PROV-01 -------------------------------------------------------------

	["P-H1 the clean fixture pack passes"] = function()
		local report = run()
		expectOk(report)
		assert(report.strings > 0 and report.entries > 0 and report.assets == 2, "surfaces were scanned")
	end,

	["P-H2 seven shared code points stay under n=8"] = function()
		expectOk(run(function(files)
			addLocale(files, "hud.near", "물결을 따라 모래") -- skeleton: 7 code points of the reference
		end))
	end,

	["P-H3 short strings skip n-gram matching"] = function()
		expectOk(run(function(files)
			addLocale(files, "hud.ok", "확인")
		end))
	end,

	["P-F1 an injected reference slice is rejected with its locator"] = function()
		local report = run(function(files)
			addLocale(files, "dialogue.guide.lore", REFERENCE_SLICE)
		end)
		expectRule(report, "PROV-NGRAM", 1)
		assert(report.findings[1].locator == "Key=dialogue.guide.lore[ko-kr]", report.findings[1].locator)
	end,

	["P-F2 spacing, zero-width and punctuation cannot dodge the n-gram gate"] = function()
		expectRule(
			run(function(files)
				addLocale(files, "hud.lore", "물 결 을\u{200B}따라, 모래톱... 끝까지 걸어간")
			end),
			"PROV-NGRAM",
			1
		)
	end,

	["P-F3 contaminated content strings are rejected"] = function()
		expectRule(
			run(function(files)
				files[provenance.FILES.content] =
					string.gsub(files[provenance.FILES.content], "name: Tide Kelp", "name: " .. REFERENCE_SLICE)
			end),
			"PROV-NGRAM",
			1
		)
	end,

	["P-F4 missing sidecar entries are rejected for content, locale and econ"] = function()
		local report = run(function(files)
			files[provenance.FILES.contentProv] =
				string.gsub(files[provenance.FILES.contentProv], "  items/tide%-kelp: { created: 2026%-10%-16 }\n", "")
			files[provenance.FILES.locale] ..= "hud.extra,Extra,ctx,Extra,추가\n"
			files[provenance.FILES.econProv] = string.gsub(
				files[provenance.FILES.econProv],
				'  "genre_contract.configs.survival%-coop.currency": { created: 2026%-10%-16 }\n',
				""
			)
		end)
		expectRule(report, "PROV-MISSING", 3)
	end,

	["P-F4b a missing sidecar file is rejected"] = function()
		expectRule(
			run(function(files)
				files[provenance.FILES.localeProv] = nil
			end),
			"PROV-MISSING",
			1
		)
	end,

	["P-F5 entries pointing at nothing are stale"] = function()
		expectRule(
			run(function(files)
				files[provenance.FILES.contentProv] ..= "  items/ghost-item: { created: 2026-10-16 }\n"
			end),
			"PROV-STALE",
			1
		)
	end,

	["P-F6 bad source, date, author and defaulted created are field errors"] = function()
		local report = run(function(files)
			files[provenance.FILES.contentProv] = [[
version: 1
defaults: { source: original, author: "agent:opus-5.5/fixture", created: 2026-10-16 }
entries:
  items/tide-kelp: { created: 2026-10-16, source: namu }
  items/stone-adze: { created: 2026-13-01 }
  recipes/adze-basic: { created: 2026-10-16, author: bob }
  sections/rules: { created: 2026-02-30 }
  sections/tags: { created: 2026-10-16 }
]]
		end)
		expectRule(report, "PROV-FIELD", 5)
	end,

	["P-F7 tampered or malformed fingerprint sets are refused"] = function()
		local function tampered(change: (provenance.SetFiles) -> ())
			return run(function(_, sets)
				change(sets[SET])
			end)
		end
		expectRule(
			tampered(function(set)
				set.fp = "000000000000\n" .. string.sub(set.fp :: string, 14)
			end),
			"PROV-FP",
			1
		)
		expectRule(
			tampered(function(set)
				set.meta = string.gsub(set.meta :: string, "\nn: 8\n", "\nn: 6\n")
			end),
			"PROV-FP",
			1
		)
		expectRule(
			tampered(function(set)
				local fp = "plain text line\n"
				set.fp = fp
				set.meta = string.gsub(
					string.gsub(set.meta :: string, "count: %d+", "count: 1"),
					'fpSha256: "%x+"',
					'fpSha256: "' .. serde.hash("sha256", fp) .. '"'
				)
			end),
			"PROV-FP",
			1
		)
		expectRule(
			tampered(function(set)
				set.fp = nil
			end),
			"PROV-FP",
			1
		)
	end,

	["P-H4 and P-F8 allow.yml waives one gram only for a human reviewer"] = function()
		local chars = provenance.skeleton("물결을 따라 모래톱") :: { string }
		local grams = provenance.grams(chars, 8)
		assert(#grams == 1, "the slice has exactly one 8-gram")
		local gramHash = provenance.hash12(SET, grams[1])
		local function allow(reviewer: string): provenance.Report
			return run(function(files)
				addLocale(files, "hud.tide", "물결을 따라 모래톱")
				files[provenance.FILES.allow] = string.format(
					[[
version: 1
entries:
  - { file: locale/strings.csv, locator: "Key=hud.tide[ko-kr]", gramHash: "%s", reason: "reviewed", reviewer: "%s" }
]],
					gramHash,
					reviewer
				)
			end)
		end
		expectOk(allow("human:indo"))
		local agent = allow("agent:opus-5.5/run")
		expectRule(agent, "PROV-NGRAM", 1)
		expectRule(agent, "PROV-POLICY", 1)
	end,

	["P-F9 denied tools are rejected"] = function()
		for _, tool in { "audiocraft", "roblox-cube", "hunyuan3d-2" } do
			expectRule(
				run(function(files)
					files[provenance.FILES.manifest] = string.gsub(
						files[provenance.FILES.manifest],
						'tool: forge%-procgen\n    source: "procedural prop/kelp"',
						"tool: " .. tool .. '\n    source: "procedural prop/kelp"'
					)
				end),
				"ASSET-TOOL"
			)
		end
	end,

	["P-F10 registry-legal tools outside the policy and unknown recipes are rejected"] = function()
		local report = run(function(files)
			local manifest = files[provenance.FILES.manifest]
			manifest = string.gsub(manifest, "id: gen%-audio", "id: gen-icons")
			manifest ..= [[
  - key: store-rock
    kind: model
    tool: creator-store
    source: "creator store rock"
    assetId: 0
    moderation: Approved
    provenance:
      digest: sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
      recipe: { id: import, version: "1" }
      provider: { name: creator-store, version: "1" }
      rights: { source: "Creator Store", ownership: licensed }
      author: "human:indo"
      created: 2026-10-16
  - key: door-creak
    kind: sfx
    tool: acme-sfx-library
    source: "acme pack 12"
    assetId: 0
    moderation: NotUploaded
    provenance:
      digest: sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
      recipe: { id: import, version: "1" }
      provider: { name: acme-sfx-library, version: "1" }
      rights: { source: "ACME commercial license", ownership: licensed }
      author: "human:indo"
      created: 2026-10-16
]]
			files[provenance.FILES.manifest] = manifest
		end)
		expectRule(report, "ASSET-TOOL", 3)
	end,

	["licensed sfx from an unregistered provider passes with rights evidence"] = function()
		expectOk(run(function(files)
			files[provenance.FILES.manifest] ..= [[
  - key: door-creak
    kind: sfx
    tool: acme-sfx-library
    source: "acme pack 12"
    assetId: 0
    moderation: NotUploaded
    provenance:
      digest: sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
      recipe: { id: import, version: "1" }
      provider: { name: acme-sfx-library, version: "1" }
      rights:
        source: "ACME commercial license"
        ownership: licensed
        evidence: { document: "docs/licenses/acme.pdf", version: "2026-09", verifiedBy: "human:indo" }
      author: "human:indo"
      created: 2026-10-16
]]
		end))
	end,

	["P-F11 assets without author/created or provenance are rejected"] = function()
		local report = run(function(files)
			local manifest = files[provenance.FILES.manifest]
			manifest = string.gsub(manifest, '      author: "agent:opus%-5%.5/fixture"\n', "", 1)
			manifest ..= [[
  - key: legacy-rock
    kind: model
    tool: forge-procgen
    source: "legacy"
    assetId: 0
    moderation: Approved
]]
			files[provenance.FILES.manifest] = manifest
		end)
		expectRule(report, "ASSET-PROV", 2)
	end,

	["P-H6 fingerprinting is byte-identical and holds only hashes"] = function()
		local docs = { { name = "a.txt", text = fs.readFile(CORPUS) } }
		local fp1, meta1 = provenance.fingerprint(docs, { set = SET })
		local fp2, meta2 = provenance.fingerprint(docs, { set = SET })
		assert(fp1 ~= nil and fp1 == fp2 and meta1 == meta2, "fingerprint must be deterministic")
		for line in string.gmatch(fp1 :: string, "([^\n]*)\n") do
			assert(string.match(line, "^[0-9a-f]+$") and #line == 12, "non-hash line in .fp")
		end
		assert(not string.find(meta1 :: string, "물결", 1, true), "meta must not carry source text")
		-- The committed fixture set is exactly what the generator writes.
		local committed = cleanSets()[SET]
		local fixtureFp, fixtureMeta = provenance.fingerprint(
			{ { name = "synthetic-reference.txt", text = fs.readFile(CORPUS) } },
			{ set = SET }
		)
		assert(committed.fp == fixtureFp and committed.meta == fixtureMeta, "committed fixture set is stale")
	end,

	["boilerplate grams shared by most documents are excluded"] = function()
		local chrome = "최근변경최근토론특수기능"
		local docs = {}
		for index = 1, 4 do
			table.insert(docs, {
				name = index .. ".txt",
				text = chrome .. string.rep(tostring(index), 3) .. "고유한문장이에요" .. index,
			})
		end
		local fp = provenance.fingerprint(docs, { set = "b" }) :: string
		local chromeGram = provenance.grams(provenance.skeleton(chrome) :: { string }, 8)[1]
		assert(not string.find(fp, provenance.hash12("b", chromeGram), 1, true), "chrome gram must be excluded")
	end,

	["policy refuses unknown keys, a different n and a denied allowTool"] = function()
		for _, edit in
			{
				{ "version: 1\n", "version: 1\nextra: true\n" },
				{ "  n: 8\n", "  n: 6\n" },
				{ "allowTools: %[forge%-procgen, trellis%]", "allowTools: [forge-procgen, audiocraft]" },
				{ "allowedSources: %[original%]", "allowedSources: [original, namu]" },
			}
		do
			expectRule(
				run(function(files)
					files[provenance.FILES.policy] = string.gsub(files[provenance.FILES.policy], edit[1], edit[2])
				end),
				"PROV-POLICY"
			)
		end
	end,

	-- QA-NAME-01 -------------------------------------------------------------

	["N-H1..N-H4 ordinary words, UI letters, token boundaries and compat jamo pass"] = function()
		expectOk(run(function(files)
			addLocale(files, "hud.words", "개울 개미굴 Pin Pilot")
			addLocale(files, "hud.letter", "X선 K")
			addLocale(files, "dialogue.guide.ok", "OK KM Xeno k")
			addLocale(files, "dialogue.guide.lol", "ㅋㅋ")
		end))
	end,

	["N-F1 banned terms in game.yml survive width, case and punctuation tricks"] = function()
		for _, title in { "Mooncairn Lite", "ＭＯＯＮＣＡＩＲＮ", "M.o.o.n.c.a.i.r.n" } do
			expectRule(
				run(function(files)
					files[provenance.FILES.game] =
						string.gsub(files[provenance.FILES.game], "name: Tidewatch Fixture", 'name: "' .. title .. '"')
				end),
				"NAME-TERM",
				1
			)
		end
	end,

	["N-F2 banned terms in locale cells are matched after normalization"] = function()
		expectRule(
			run(function(files)
				addLocale(files, "hud.a", "문 케 언")
				addLocale(files, "hud.b", "야생의땅")
				addLocale(files, "hud.c", "wild-lands")
			end),
			"NAME-TERM",
			3
		)
	end,

	["N-F3 banned stems match anywhere in the skeleton"] = function()
		expectRule(
			run(function(files)
				for index, text in
					{ "개척자", "신개척지", "개 척", "Pioneers", "pioneering", "워프게이트" }
				do
					addLocale(files, "hud.stem" .. index, text)
				end
			end),
			"NAME-STEM",
			6
		)
	end,

	["N-F4 standalone single letters in dialogue and speaker fields are rejected"] = function()
		expectRule(
			run(function(files)
				addLocale(files, "dialogue.guide.back", "K가 돌아왔다")
				files[provenance.FILES.content] ..= "wildlife:\n  - id: shore-strider\n    speaker: X\n"
				files[provenance.FILES.contentProv] ..= "  wildlife/shore-strider: { created: 2026-10-16 }\n"
			end),
			"NAME-LETTER",
			2
		)
	end,

	["N-F5 hashed proper names are rejected without echoing them"] = function()
		local report = run(function(files)
			files[provenance.FILES.game] =
				string.gsub(files[provenance.FILES.game], "name: Wide Satchel", "name: 모래등대단 Satchel")
		end)
		expectRule(report, "NAME-HASHED", 1)
	end,

	["N-F6 decomposed jamo spelling is an encoding error"] = function()
		expectRule(
			run(function(files)
				addLocale(files, "hud.jamo", "\u{1103}\u{1172}\u{1105}\u{1161}\u{11BC}\u{1100}\u{1169}")
			end),
			"NAME-ENCODING",
			1
		)
	end,

	["N-F7 invalid UTF-8 in a csv cell is an encoding error"] = function()
		expectRule(
			run(function(files)
				addLocale(files, "hud.bytes", "ok\255\254")
			end),
			"NAME-ENCODING",
			1
		)
	end,

	["N-F8 findings never print banned words or hashed names in plain text"] = function()
		local report = run(function(files)
			files[provenance.FILES.game] =
				string.gsub(files[provenance.FILES.game], "name: Tidewatch Fixture", "name: Mooncairn")
			files[provenance.FILES.game] =
				string.gsub(files[provenance.FILES.game], "name: Wide Satchel", "name: 모래등대단")
			addLocale(files, "hud.d", "문케언 " .. REFERENCE_SLICE)
		end)
		assert(not report.ok, "expected FAIL")
		local text = describe(report)
		for _, plain in { "Mooncairn", "mooncairn", "문케언", "모래등대단", "물결" } do
			assert(not string.find(text, plain, 1, true), "plain text leaked: " .. plain)
		end
	end,

	["skeleton folds width and case and drops punctuation and zero-width marks"] = function()
		local a = table.concat(provenance.skeleton("Ｍ.o-o\u{200B}N c a i r n!") :: { string })
		assert(a == "mooncairn", a)
		assert(provenance.standaloneLetter("— X:", "X"), "dash-colon bounded letter matches")
		assert(not provenance.standaloneLetter("XK1", "K"), "letters inside tokens do not match")
	end,
}
