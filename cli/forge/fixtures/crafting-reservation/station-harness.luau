--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Harness = require("../../lib/qaharness")
local Contract = require("../../../../genres/survival-coop/module/Contract")
local config = serde.decode("yaml", fs.readFile("cli/forge/fixtures/crafting-reservation/fixture-survival/econ.yml"))
local content = config.genre_contract.configs["survival-coop"].inventory.content
content.structures = {
	{ id = "bench", footprintX = 1, footprintZ = 1, station = true, cost = { { item = "fiber", quantity = 1 } } },
}
content.recipes[1].station = "bench"
local target =
	{ packConfig = config.genre_contract, contracts = { Contract }, controls = {}, storeName = "station-proof" }
local function check(distance: number, expected: string)
	local steps: { any } = {
		{ op = "join", player = "1" },
		{
			op = "command",
			player = "1",
			requestId = "station-reserve",
			sessionEpoch = 0,
			action = "survival-coop:craft-reserve",
			args = { "cord", "bench" },
			expect = expected,
		},
		{ op = "expect_result", player = "1", field = "ok", equals = expected == "ok" },
		{ op = "close", player = "1" },
		{ op = "reload" },
		{ op = "join", player = "1" },
	}
	if expected == "ok" then
		table.insert(steps, {
			op = "expect_snapshot",
			player = "1",
			genre = "survival-coop",
			field = "workshop.entries.w1:1:0:15:station-reserve.job.state",
			equals = "Reserved",
		})
	end
	local outcome = Harness.runNative({
		name = "station-harness",
		genre = "survival-coop",
		pack = "fixture-survival",
		kind = "native",
		contract_api = 1,
		timeout_seconds = 60,
		players = { "1" },
		fixtures = {},
		data = {
			durable = { actions = { "survival-coop:craft-reserve" }, windowSeconds = 10000, maxOutcomes = 256 },
			survivalSpatial = {
				radiusStuds = 12,
				players = { ["1"] = { x = 0, y = 0, z = 0 } },
				campfires = { fire = { x = 0, y = 0, z = 0 } },
				stations = { bench = { x = distance, y = 0, z = 0, kind = "bench" } },
			},
		},
		steps = steps,
	}, target)
	assert(outcome.ok, table.concat(outcome.failures, "; "))
end
check(12, "ok")
check(13, "refused")
print("PASS actual Session station reservation at reach boundary and refusal outside; persisted job survives reload")
