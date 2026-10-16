--!strict
-- The shipped Durango provenance kit (cli/forge/provenance/durango) parses,
-- its fingerprint set is intact, the clean fixture pack passes under it, and
-- the user-named banned terms and stems are rejected under it.

local fs = require("@lune/fs")

local provenance = require("./provenance")

local KIT = "cli/forge/provenance/durango"
local CLEAN = "cli/forge/fixtures/provenance/packs/clean"
local SET = "namu-20261016"

local function kitFiles(): ({ [string]: string }, { [string]: provenance.SetFiles })
	local files: { [string]: string } = {}
	for _, rel in provenance.FILES do
		if fs.isFile(CLEAN .. "/" .. rel) then
			files[rel] = fs.readFile(CLEAN .. "/" .. rel)
		end
	end
	files[provenance.FILES.policy] = fs.readFile(KIT .. "/policy.example.yml")
	files[provenance.FILES.banned] = fs.readFile(KIT .. "/banned-names.yml")
	local sets = {
		[SET] = {
			fp = fs.readFile(KIT .. "/fingerprints/" .. SET .. ".fp"),
			meta = fs.readFile(KIT .. "/fingerprints/" .. SET .. ".meta.yml"),
		},
	}
	return files, sets
end

local function addLocale(files: { [string]: string }, key: string, cell: string)
	files[provenance.FILES.locale] ..= string.format('%s,Hi,ctx,Hi,"%s"\n', key, cell)
	files[provenance.FILES.localeProv] ..= key .. ",original,human:indo,2026-10-16\n"
end

return {
	["clean fixture strings pass under the real Durango kit"] = function()
		local files, sets = kitFiles()
		local report = provenance.checkPack("kit", files, sets)
		local lines = {}
		for _, finding in report.findings do
			table.insert(lines, provenance.formatFinding("kit", finding))
		end
		assert(report.ok, table.concat(lines, "\n"))
		assert(report.sets[1] == SET, "real set loaded")
	end,

	["every user-named term and stem is rejected under the real kit"] = function()
		local files, sets = kitFiles()
		for index, text in { "Durango", "듀랑고", "Wild Lands", "야생의 땅", "개척자", "Pioneer", "워프" } do
			addLocale(files, "hud.banned" .. index, text)
		end
		local report = provenance.checkPack("kit", files, sets)
		local counts: { [string]: number } = {}
		for _, finding in report.findings do
			counts[finding.rule] = (counts[finding.rule] or 0) + 1
		end
		assert((counts["NAME-TERM"] or 0) >= 4, "terms: " .. tostring(counts["NAME-TERM"]))
		assert((counts["NAME-STEM"] or 0) >= 3, "stems: " .. tostring(counts["NAME-STEM"]))
	end,
}
