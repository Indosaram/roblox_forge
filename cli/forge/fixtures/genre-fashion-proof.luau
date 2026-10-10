--!strict
local suites: { { [string]: () -> () } } = {
	require("../../../genres/social-rp-fashion/module/Outfit.spec"),
	require("../../../genres/social-rp-fashion/module/ThemeRound.spec"),
	require("../../../genres/social-rp-fashion/module/Voting.spec"),
	require("../../../genres/social-rp-fashion/module/Adapter.spec"),
}
local count = 0
for _, suite in suites do
	local names: { string } = {}
	for name in suite do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		suite[name]()
		count += 1
		print("PASS " .. name)
	end
end
assert(count == 19, "all native and adapter regressions executed")
print("Fashion scoped specs: " .. tostring(count) .. " passed, 0 failed")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local QA = require("../lib/qa")
local Manifest = require("../lib/genrecontract")
local manifest = serde.decode("yaml", fs.readFile("genres/social-rp-fashion/forge-package.yml"))
assert(#Manifest.validateManifest(manifest, "social-rp-fashion", "1.0.0") == 0, "manifest schema")
for _, name in { "contract-loop", "contract-rejoin" } do
	local scenario = serde.decode("yaml", fs.readFile("genres/social-rp-fashion/qa-scenarios/" .. name .. ".yml"))
	local errors = QA.validate(scenario, { expectedGenre = "social-rp-fashion", expectedName = name })
	assert(#errors == 0, table.concat(errors, "; "))
end
print("PASS manifest and contract scenario schemas (not Studio execution)")
