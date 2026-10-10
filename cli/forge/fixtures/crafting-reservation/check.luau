--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Session = require("../../../../core/infra/genre/Session")
local Executor = require("../../../../core/domain/genre/Executor")
local Ledger = require("../../../../core/domain/command/Ledger")
local Contract = require("../../../../genres/survival-coop/module/Contract")
local Harness = require("../../lib/qaharness")
local config = serde.decode("yaml", fs.readFile("cli/forge/fixtures/crafting-reservation/fixture-survival/econ.yml"))
local base = 1790899200
local wall = base
local gate = Harness.barrier()
local loseAck = false
local stationPresent = true
local backend = {
	update = function(key: string, transform: (any) -> any): (boolean, any)
		local ok, value = gate.backend.update(key, transform)
		if ok and loseAck then
			loseAck = false
			return false, "lost acknowledgement after durable commit"
		end
		return ok, value
	end,
}
local actions = {
	"survival-coop:craft-reserve",
	"survival-coop:craft-start",
	"survival-coop:craft-complete",
	"survival-coop:craft-cancel",
	"survival-coop:inventory-move",
}
local function open(sessionId: string)
	return Session.new(
		{ packConfig = config.genre_contract, contracts = { Contract }, controls = {}, storeName = "craft-proof" },
		backend,
		{
			sessionId = sessionId,
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
			survivalSpatial = {
				campfire = function(_, _)
					return nil
				end,
				station = function(player, id)
					return if stationPresent
							and player == "1"
							and id == "bench"
						then { kind = "bench", reachable = true }
						else nil
				end,
			},
		},
		{ actions = actions, windowSeconds = 10000, maxOutcomes = 512 }
	)
end
local session = open("first")
assert(session.join("1").ok, "join actual Session")
local function command(request: string, action: string, args: { any }): any
	return session.command(
		"1",
		{ requestId = request, sessionEpoch = 0, action = "survival-coop:" .. action, args = args }
	)
end
local function view(): any
	return session.snapshot("1")["survival-coop"]
end
local restartCount = 0
local function restart()
	assert(session.close("1").ok, "close persists")
	gate = Harness.barrier(serde.decode("json", serde.encode("json", gate.snapshot())))
	restartCount += 1
	session = open("restart-" .. tostring(restartCount))
	assert(session.join("1").ok, "JSON restart")
end
gate.fail(1)
local failed = command("reserve", "craft-reserve", { "cord", "hand" })
assert(not failed.ok and failed.reason == "COMMIT_FAILED", "failed commit")
assert(
	view().inventory.bag.version == 2 and next(view().workshop.entries) == nil,
	"failed commit keeps source unchanged"
)
local reserved = command("reserve", "craft-reserve", { "cord", "hand" })
assert(reserved.ok, tostring(reserved.reason))
local id = reserved.data.jobId
for _ = 1, 100 do
	assert(
		Ledger.canonical(command("reserve", "craft-reserve", { "cord", "hand" })) == Ledger.canonical(reserved),
		"exact reserve replay"
	)
end
assert(
	view().inventory.bag.reservations[id]["fiber-stack"] == 3 and view().inventory.bag.version == 3,
	"one three-fiber reservation"
)
restart()
assert(view().workshop.entries[id].job.state == "Reserved", "Reserved restart")
assert(command("start", "craft-start", { id }).ok, "start")
restart()
assert(view().workshop.entries[id].job.state == "Running", "Running restart")
assert(view().workshop.entries[id].job.finishAt == base * 1000 + 1000, "2026 Unix millisecond deadline")
wall += 1
local full = command("full", "craft-complete", { id })
assert(not full.ok and full.reason == "FULL_SLOTS", "full output refuses")
restart()
assert(
	view().workshop.entries[id].job.state == "Ready" and view().inventory.bag.items["fiber-stack"].quantity == 300,
	"Ready persists without consumption"
)
config.genre_contract.configs["survival-coop"].inventory.content.recipes[1].outputs[1].quantity = 5
restart()
local free = command("free", "inventory-move", { "bag", "chest", "blocker", 1, "blocker", 3, 0 })
assert(free.ok, "free capacity: " .. tostring(free.reason))
loseAck = true
local lost = command("finish", "craft-complete", { id })
assert(not lost.ok and lost.reason == "COMMIT_FAILED", "lost ACK is not final success")
assert(view().inventory.bag.items["fiber-stack"].quantity == 300, "lost ACK keeps local candidate unapplied")
local finished = command("finish", "craft-complete", { id })
assert(finished.ok, "retry durable finish")
restart()
assert(view().workshop.entries[id].job.state == "Committed", "Committed restart")
assert(view().inventory.bag.items[id .. ":output:1"].quantity == 1, "pinned recipe output")
assert(view().inventory.bag.items["fiber-stack"].quantity == 297, "one input consumption")
for _ = 1, 100 do
	assert(
		Ledger.canonical(command("finish", "craft-complete", { id })) == Ledger.canonical(finished),
		"exact finish replay"
	)
end
local duplicate = command("new-finish", "craft-complete", { id })
assert(not duplicate.ok and duplicate.reason == "ALREADY_COMMITTED", "new identity terminal refusal")
local cancelled = command("cancel-reserve", "craft-reserve", { "cord", "hand" })
assert(cancelled.ok, "reserve cancellation")
assert(command("cancel", "craft-cancel", { cancelled.data.jobId }).ok, "cancel")
restart()
assert(view().workshop.entries[cancelled.data.jobId].job.state == "Cancelled", "Cancelled restart")
-- Fill retained queue through the actual durable Session, not a synthetic save.
for n = 3, 64 do
	wall += 1
	local result = command("r" .. tostring(n), "craft-reserve", { "cord", "hand" })
	assert(result.ok, tostring(result.reason))
	assert(command("c" .. tostring(n), "craft-cancel", { result.data.jobId }).ok, "cancel for retained budget")
end
local envelope = session.envelope("1")
assert(Executor.data(envelope), "actual 64-job envelope structural depth and entry budgets")
local bytes = #serde.encode("json", envelope)
assert(bytes < 4 * 1024 * 1024, "actual JSON payload below DataStore four MiB limit")
local before = Ledger.canonical(view())
local overflow = command("overflow", "craft-reserve", { "cord", "hand" })
assert(not overflow.ok and overflow.reason == "JOB_QUEUE_FULL", "65th job refuses before commit")
assert(Ledger.canonical(view()) == before, "queue refusal leaves jobs and inventory unchanged")
assert(session.close("1").ok, "final close")
gate = Harness.barrier()
local content = config.genre_contract.configs["survival-coop"].inventory.content
content.structures =
	{ { id = "bench", footprintX = 1, footprintZ = 1, station = true, cost = { { item = "fiber", quantity = 1 } } } }
content.recipes[1].station = "bench"
content.recipes[1].outputs[1].quantity = 1
content.vitals = {
	hungerMillisPerUnit = 18000,
	fatigueMilliPerAction = 500,
	restMilliPerSecond = 2000,
	starvationMillisPerUnit = 5000,
}
session = open("spatial")
assert(session.join("1").ok, "station fixture joins")
local missing = command("missing", "craft-reserve", { "cord", "absent" })
assert(not missing.ok and missing.reason == "STATION_UNAVAILABLE", "server station existence required")
local near = command("near", "craft-reserve", { "cord", "bench" })
assert(near.ok and view().vitals.fatigueMilli == 500, "server station and one action fatigue")
for _ = 1, 100 do
	assert(command("near", "craft-reserve", { "cord", "bench" }).ok, "station reserve replay")
end
assert(view().vitals.fatigueMilli == 500, "replay adds no fatigue")
stationPresent = false
assert(command("station-start", "craft-start", { near.data.jobId }).ok, "existing starts after removal")
wall += 1
local ready = command("station-finish", "craft-complete", { near.data.jobId })
assert(not ready.ok and ready.reason == "FULL_SLOTS", "existing completion reaches capacity after removal")
assert(view().vitals.fatigueMilli == 1000, "capacity refusal adds no fatigue")
assert(session.close("1").ok, "station fixture closes")
print(string.format("PASS real Session crafting restart/replay/failed commit/lost ACK; 64-job JSON bytes=%d", bytes))
