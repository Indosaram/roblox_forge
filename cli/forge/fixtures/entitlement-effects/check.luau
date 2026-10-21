--!strict
local suites: { { [string]: () -> () } } = {
	require("../../../../core/domain/monetization/Entitlements.spec"),
	require("../../../../genres/survival-coop/module/EntitlementEffects.spec"),
	require("../../../../genres/survival-coop/module/SkinSelection.spec"),
}
local count = 0
for _, suite in suites do
	for name, test in suite do
		test()
		count += 1
		print("PASS " .. name)
	end
end
print(string.format("entitlement-effects: %d passed", count))
