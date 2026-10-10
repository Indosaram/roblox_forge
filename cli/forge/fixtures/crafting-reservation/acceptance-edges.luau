--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local run = require("../../lib/run")
local Session = require("../../../../core/infra/genre/Session")
local MemoryBackend = require("../../../../core/infra/data/MemoryBackend")
local Ledger = require("../../../../core/domain/command/Ledger")
local Contract = require("../../../../genres/survival-coop/module/Contract")

local config = serde.decode("yaml", fs.readFile("cli/forge/fixtures/crafting-reservation/fixture-survival/econ.yml"))
local content = config.genre_contract.configs["survival-coop"].inventory.content
content.limits.slots = 3
content.recipes[1].craftMillis = 1001
content.vitals = {
	hungerMillisPerUnit = 18000,
	fatigueMilliPerAction = 500,
	restMilliPerSecond = 2000,
	starvationMillisPerUnit = 5000,
}
local policy = {
	actions = {
		"survival-coop:craft-reserve",
		"survival-coop:craft-start",
		"survival-coop:craft-complete",
		"survival-coop:craft-cancel",
	},
	windowSeconds = 10000,
	maxOutcomes = 64,
	personal = { namespace = "edges", inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" } },
}
local wall = 0
local function open(memory: MemoryBackend.Memory, host: string)
	return Session.new(
		{
			packConfig = config.genre_contract,
			contracts = { Contract },
			controls = {},
			storeName = "craft-edges",
			durable = policy,
		},
		memory,
		{
			sessionId = host,
			lockTimeout = 10000,
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
			encode = function(value)
				return serde.encode("json", value)
			end,
		},
		policy
	)
end
local function request(id: string, action: string, args: { any }): any
	return { requestId = id, sessionEpoch = 0, action = "survival-coop:" .. action, args = args }
end
local function equal(a: any, b: any, message: string)
	assert(Ledger.canonical(a) == Ledger.canonical(b), message)
end
local function view(session: Session.Session): any
	return session.snapshot("1")["survival-coop"]
end
local function start(session: Session.Session): string
	assert(session.join("1").ok, "join fenced Session")
	local reserved = session.command("1", request("reserve", "craft-reserve", { "cord", "hand" }))
	assert(reserved.ok, tostring(reserved.reason))
	assert(reserved.data and type(reserved.data.jobId) == "string", "reservation returns job ID")
	assert(session.command("1", request("start", "craft-start", { reserved.data.jobId })).ok, "start")
	return reserved.data.jobId
end
local function restore(raw: any): MemoryBackend.Memory
	local memory = MemoryBackend.new()
	assert(memory.update("edges:1", function(_)
		return raw
	end))
	return memory
end

if process.args[1] == "restore" then
	local payload = serde.decode("json", process.args[2])
	wall = payload.wall
	local session = open(restore(payload.record), "fresh-process")
	assert(session.join("1").ok, "fresh process acquires serialized PersonalAggregate")
	local before = view(session)
	for _ = 1, 100 do
		equal(session.command("1", payload.request), payload.result, "fresh process exact cancel replay")
	end
	equal(view(session), before, "fresh process cancellation immutable")
	local conflict = session.command("1", request("cancel", "craft-cancel", { "changed-job" }))
	assert(not conflict.ok and conflict.reason == "REQUEST_CONFLICT", "changed cancel payload conflicts")
	equal(view(session), before, "conflict leaves gameplay unchanged")
	assert(before.inventory.bag.items["fiber-stack"].quantity == 300, "no cancellation debit")
	assert(next(before.inventory.bag.reservations) == nil, "reservation released once")
	assert(session.close("1").ok and #session.members() == 0, "fresh process cleanup")
	print("PASS fresh-process cancel100 and changed-payload conflict")
	return
end

local function deadlines()
	local baseline: any = nil
	for _, fractional in { false, true } do
		for _, advanceFirst in { false, true } do
			wall = 0
			local session = open(MemoryBackend.new(), "deadline")
			local id = start(session)
			assert(view(session).workshop.entries[id].job.finishAt == 1001, "pinned 1001ms deadline")
			if fractional then
				for _, time in { 0.125, 0.375, 0.75 } do
					wall = time
					session.advance(wall)
				end
			end
			wall = 1.001 - 0.000001
			if advanceFirst then
				session.advance(wall)
			end
			local early = session.command("1", request("early", "craft-complete", { id }))
			assert(not early.ok and early.reason == "NOT_READY", "cannot complete one millisecond early")
			-- Fenced commands hydrate the durable aggregate, so observe elapsed
			-- vitals after the same final heartbeat in both ordering variants.
			session.advance(wall)
			assert(view(session).vitals.activeMillis == 1000, "sub-ms time does not invent elapsed vitals")
			wall = 1.001
			if advanceFirst then
				session.advance(wall)
			end
			local done = session.command("1", request("finish", "craft-complete", { id }))
			assert(done.ok, "exact fractional deadline completion: " .. tostring(done.reason))
			session.advance(wall)
			local state = view(session)
			assert(state.vitals.activeMillis == 1001, "exact boundary advances vitals by one millisecond")
			assert(state.inventory.bag.items["fiber-stack"].quantity == 297, "one input consumption")
			assert(state.inventory.bag.items[id .. ":output:1"].quantity == 1, "one stable output")
			for _ = 1, 100 do
				equal(session.command("1", request("finish", "craft-complete", { id })), done, "finish replay")
			end
			if baseline then
				equal(state, baseline, "whole snapshot independent of fractional partition and command ordering")
			else
				baseline = state
			end
			assert(session.close("1").ok and #session.members() == 0, "deadline cleanup")
		end
	end
	print("PASS exact/fractional deadline partitions in both command/advance orders")
end
if process.args[1] ~= "recovery" then
	deadlines()
end

wall = 0
local memory = MemoryBackend.new()
local session = open(memory, "cancel")
local id = start(session)
local cancel = request("cancel", "craft-cancel", { id })
local cancelled = session.command("1", cancel)
assert(cancelled.ok, "cancel commits")
local before = view(session)
for _ = 1, 100 do
	equal(session.command("1", cancel), cancelled, "cancel exact replay100")
end
equal(view(session), before, "replay leaves whole snapshot unchanged")
local conflict = session.command("1", request("cancel", "craft-cancel", { "changed-job" }))
assert(not conflict.ok and conflict.reason == "REQUEST_CONFLICT", "changed payload conflict before restart")
equal(view(session), before, "conflict immutable")
assert(session.close("1").ok, "cancel session closes")
local ok, record = memory.update("edges:1", function(old)
	return old
end)
assert(ok and record.data.envelope, "actual PersonalAggregate persisted")
local child = run.exec("lune", {
	"run",
	"cli/forge/fixtures/crafting-reservation/acceptance-edges",
	"restore",
	serde.encode("json", { record = record, wall = wall, request = cancel, result = cancelled }),
})
assert(child.ok, child.stdout .. child.stderr)
print(child.stdout)

wall = 0
memory = MemoryBackend.new()
session = open(memory, "offline")
id = start(session)
wall = 0.5
session.advance(wall)
local savedVitals = view(session).vitals
assert(session.close("1").ok, "disconnect pending job")
ok, record = memory.update("edges:1", function(old)
	return old
end)
assert(ok, "read durable record")
wall = 900
session = open(restore(serde.decode("json", serde.encode("json", record))), "offline-restored")
assert(session.join("1").ok, "offline rejoin")
local restored = view(session)
for _, field in
	{ "healthMilli", "hungerMilli", "fatigueMilli", "activeMillis", "hungerRemainder", "starvationRemainder" }
do
	assert(restored.vitals[field] == savedVitals[field], "offline freezes " .. field)
end
assert(restored.workshop.entries[id].job.finishAt == 1001, "offline deadline not rebased")
local finished = session.command("1", request("offline-finish", "craft-complete", { id }))
assert(finished.ok, "offline job finishes past deadline")
local completed = view(session)
assert(completed.inventory.bag.items["fiber-stack"].quantity == 297, "offline consumes once")
assert(completed.inventory.bag.items[id .. ":output:1"].quantity == 1, "offline output once")
for _ = 1, 100 do
	equal(session.command("1", request("offline-finish", "craft-complete", { id })), finished, "offline finish replay")
end
equal(view(session), completed, "offline replay immutable")
assert(session.close("1").ok and #session.members() == 0, "offline cleanup")
print("PASS offline pending job completes once while restored vitals freeze")
