--!strict
-- Scoped native entry point; the repository spec runner also discovers these cases.
local tests: { [string]: () -> () } = require("../../../genres/survival-coop/module/SurvivalHUDModel.spec")
local count = 0
for name, test in tests do
	test()
	count += 1
	print("PASS " .. name)
end
assert(count > 0, "HUD fixture must execute cases")
print(string.format("SurvivalHUD: %d passed, 0 failed", count))
