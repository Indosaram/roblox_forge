--!strict
local specs: { [string]: () -> () } = require("../../../core/infra/camera/QuarterView.spec")
local count = 0
for name, run in specs do
	run()
	count += 1
	print("PASS " .. name)
end
print("camera: " .. tostring(count) .. " passed")
