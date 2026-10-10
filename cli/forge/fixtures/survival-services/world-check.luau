--!strict
local cases: { [string]: () -> () } = require("../../../../genres/survival-coop/module/SurvivalWorld.spec")
local passed = 0
for name, run in cases do
	run()
	passed += 1
	print("PASS " .. name)
end
assert(passed > 0, "no world regression cases")
print("world regression: " .. tostring(passed) .. " passed")
