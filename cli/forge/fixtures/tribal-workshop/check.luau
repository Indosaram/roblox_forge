--!strict
local Bridge = require("../../../../genres/survival-coop/module/SettlementBridge")
local bridge = Bridge.new({
	resolve = function()
		return nil
	end,
	authorize = function()
		return { ok = true }
	end,
})
assert(bridge.handles("survival-coop:settlement-workshop-reserve"), "MISSING_SHARED_WORKSHOP_ROUTE")
local suites: { { [string]: () -> () } } = {
	require("../../../../genres/survival-coop/module/SettlementRuntime.spec"),
	require("../../../../genres/survival-coop/module/SettlementBridge.spec"),
	require("../../../../genres/survival-coop/module/Workshop.spec"),
	require("../../../../core/domain/settlement/Transaction.spec"),
}
local count = 0
for _, suite in suites do
	for name, run in suite do
		run()
		count += 1
		print("PASS " .. name)
	end
end
print("TRIBAL_WORKSHOP_PASS " .. count)
