--!strict
-- Expected red until the actual caller journals lethal advances with drops.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Session = require("../../../../core/infra/genre/Session")
local Contract = require("../../../../genres/survival-coop/module/Contract")
local Harness = require("../../lib/qaharness")
local config = serde.decode("yaml", fs.readFile("cli/forge/fixtures/vitals-food-rest/fixture-survival/econ.yml"))
local wall = 1790899200
local gate = Harness.barrier()
local session = Session.new(
	{
		packConfig = config.genre_contract,
		contracts = { Contract },
		controls = {},
		storeName = "death-advance-repro",
	},
	gate.backend,
	{
		sessionId = "native-20261015",
		lockTimeout = 120,
		retries = 0,
		now = function()
			return wall
		end,
	},
	{
		now = function()
			return wall
		end,
		roll = function()
			return 0
		end,
		emit = function(_) end,
	}
)
assert(session.join("1").ok, "real Session joins at Unix time")
wall += 2400
local route = process.args[1] or "advance"
local view: any
if route == "close" then
	assert(session.close("1").ok, "actual close captures elapsed vitals")
	local records = gate.snapshot()
	local record = records["player-1"]
	assert(record ~= nil, "closed profile persisted")
	view = record.data.genres["survival-coop"].data
elseif route == "food" then
	local refused = session.dispatch("1", "survival-coop:food", { "ration-stack" })
	assert(not refused.ok, "dead actor cannot consume food")
	view = session.snapshot("1")["survival-coop"]
else
	assert(route == "advance", "expected advance, close, or food route")
	session.advance(wall)
	view = session.snapshot("1")["survival-coop"]
end
assert(view.vitals.healthMilli == 0, "actual advance reaches death")
assert(
	view.deathBundles ~= nil and view.deathBundles.lastSequence == 1,
	"PENDING_INTEGRATION: actual Session " .. route .. " published dead vitals without a journaled death bundle"
)
