--!strict
-- Scoped regression entry point; the native CLI scenario is run separately.
local specs: { [string]: () -> () } = require("../../../../genres/survival-coop/module/Mode.spec")
local count = 0
for name, test in specs do
	test()
	count += 1
	print("PASS " .. name)
end
print(string.format("inventory integration mode specs: %d passed", count))

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Executor = require("../../../../core/domain/genre/Executor")
local Contract = require("../../../../genres/survival-coop/module/Contract")
local config = serde.decode("yaml", fs.readFile("cli/forge/fixtures/inventory-conservation/fixture-survival/econ.yml"))
local executor = Executor.new(config.genre_contract, { Contract }, {
	now = function()
		return 0
	end,
	roll = function()
		return 0
	end,
	emit = function(_) end,
})
assert(executor.join("1").ok, "fixture player joins")
local calls: { { action: string, args: { any } } } = {
	{ action = "inventory-reserve", args = { "race", "job-owned", "last", 1, 1 } },
	{ action = "inventory-release", args = { "race", "job-owned", 2 } },
	{ action = "inventory-consume", args = { "race", "last", 1, 1 } },
}
for _, call in calls do
	local result = executor.dispatchClient("1", "survival-coop:" .. call.action, call.args)
	assert(not result.ok, "internal inventory action accepted client ingress")
	assert(executor.snapshot("1")["survival-coop"].inventory.race.version == 1, "client refusal preserves version")
end
assert(
	executor.dispatchServer("1", "survival-coop:inventory-reserve", { "race", "job-owned", "last", 1, 1 }).ok,
	"trusted server reserves"
)
assert(
	not executor.dispatchClient("1", "survival-coop:inventory-release", { "race", "job-owned", 2 }).ok,
	"client cannot release server reservation"
)
assert(
	executor.snapshot("1")["survival-coop"].inventory.race.reservations["job-owned"].last == 1,
	"server reservation remains intact"
)
print("PASS client cannot reserve, consume, or release a job-owned reservation")
