--!strict
-- End-to-end specs for `forge provenance check` against the on-disk fixture
-- packs: the clean pack passes and the contaminated pack fails (QA-PROV-01,
-- QA-NAME-01), and the shipped packs without a policy are left alone.

local fs = require("@lune/fs")

local command = require("./provenance")

local PACKS = "cli/forge/fixtures/provenance/packs"

local function rulesOf(report: any): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, finding in report.findings do
		set[finding.rule] = true
	end
	return set
end

return {
	["the clean fixture pack passes and reports a PASS line"] = function()
		local report = command.checkPackDir("clean", PACKS .. "/clean")
		local out, err = command.formatReport(report)
		assert(report.ok, err)
		assert(string.find(out, "provenance: PASS clean (", 1, true), out)
	end,

	["the contaminated fixture pack fails on names, n-grams and sidecars"] = function()
		local report = command.checkPackDir("contaminated", PACKS .. "/contaminated")
		assert(not report.ok, "contaminated pack must fail")
		local rules = rulesOf(report)
		for _, rule in
			{ "NAME-TERM", "NAME-STEM", "NAME-LETTER", "NAME-HASHED", "PROV-NGRAM", "PROV-MISSING", "PROV-FIELD" }
		do
			assert(rules[rule], "expected " .. rule)
		end
		local _, err = command.formatReport(report)
		assert(string.find(err, "provenance: FAIL contaminated (", 1, true), err)
		assert(not string.find(err, "Durango", 1, true), "banned term leaked into output")
	end,

	["shipped packs have no policy, so the gate never touches them"] = function()
		for _, name in fs.readDir("games") do
			if fs.isDir("games/" .. name) then
				assert(not command.hasPolicy("games/" .. name), name .. " unexpectedly opted in")
			end
		end
	end,

	["check refuses a pack without a policy and a missing --pack"] = function()
		assert(not command.run({ "provenance", "check", "--pack", "kaiju-egg-raiders" }), "no policy must fail")
		assert(not command.run({ "provenance", "check" }), "missing --pack must fail")
		assert(not command.run({ "provenance", "nope" }), "unknown subcommand must fail")
	end,

	["a fingerprint set can be loaded from a .path pointer outside the pack"] = function()
		local root = "build/provenance-spec-pointer"
		if fs.isDir(root) then
			fs.removeDir(root)
		end
		fs.writeDir(root)
		local ok, reason = pcall(function()
			local pack = root .. "/clean"
			fs.writeDir(pack)
			for _, rel in { "provenance", "locale", "assets" } do
				fs.writeDir(pack .. "/" .. rel)
			end
			for _, rel in
				{
					"provenance/policy.yml",
					"provenance/banned-names.yml",
					"game.yml",
					"econ.yml",
					"econ.provenance.yml",
					"content.yml",
					"content.provenance.yml",
					"deploy.yml",
					"locale/strings.csv",
					"locale/provenance.csv",
					"assets/manifest.yml",
				}
			do
				fs.writeFile(pack .. "/" .. rel, fs.readFile(PACKS .. "/clean/" .. rel))
			end
			fs.writeDir(pack .. "/provenance/fingerprints")
			-- No set files next to the pack: without the pointer it must fail.
			assert(not command.checkPackDir("clean", pack).ok, "missing set must fail")
			fs.writeFile(
				pack .. "/provenance/fingerprints/synthetic-ref.path",
				PACKS .. "/clean/provenance/fingerprints\n"
			)
			local report = command.checkPackDir("clean", pack)
			local _, err = command.formatReport(report)
			assert(report.ok, err)
		end)
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
}
