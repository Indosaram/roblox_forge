--!strict
local Session = require("../../../core/infra/genre/Session")
local Harness = require("./qaharness")
local Survival = require("../../../genres/survival-coop/module/Contract")
local Fixture = require("../../../genres/survival-coop/module/Adapter.fixture")
local serde = require("@lune/serde")
local Executor = require("../../../core/domain/genre/Executor")
local Ledger = require("../../../core/domain/command/Ledger")
local function setup(policy: any?, notifyFailure: boolean?, serverOrigin: boolean?)
	local gate = Harness.barrier()
	local now, events = 0, 0
	local config = table.clone(Fixture.config)
	config.startingBalance = 100
	local descriptor = table.clone(Survival)
	if serverOrigin then
		descriptor.actions = table.clone(Survival.actions)
		for index, action in descriptor.actions do
			if action.id == "buy-defense" then
				descriptor.actions[index] = table.clone(action)
				descriptor.actions[index].origin = "server"
			end
		end
	end
	local create = descriptor.create
	descriptor.create = function(c, services)
		local instance = create(c, services)
		if policy and policy.tickAction then
			instance.pendingServerEvent = function(id, millis)
				return if millis >= 1000 and instance.snapshot(id).upgradeLevel == 0 then "scheduled:1" else nil
			end
		end
		local stage = instance.stageCommand :: (string, string, { any }) -> any
		instance.stageCommand = function(id, action, args, context)
			assert(
				context ~= nil and context.actorId == id and type(context.requestId) == "string",
				"trusted command context"
			)
			assert(context.nowMillis == math.floor(now * 1000), "authoritative millisecond clock forwarded")
			assert(type(context.expiredBeforeEpoch) == "number", "authoritative retention floor forwarded")
			assert(type(context.serverId) == "string" and #context.serverId > 0, "locked host identity forwarded")
			local candidate = stage(id, action, args)
			if candidate then
				candidate.result.data = {
					jobId = "job-original",
					outputs = { "item-original" },
					floor = context.expiredBeforeEpoch,
					host = context.serverId,
				}
			end
			return candidate
		end
		return instance
	end
	local function fresh(backend, name)
		return Session.new(
			{
				packConfig = { api = 1, order = { Survival.id }, configs = { [Survival.id] = config } },
				contracts = { descriptor },
				controls = {},
				storeName = "ReplaySpec",
				hooks = if notifyFailure
					then {
						["survival-coop:DefenseBought"] = function(_event: any)
							error("hook failed")
						end,
					}
					else nil,
			},
			backend,
			{
				sessionId = name,
				lockTimeout = 120,
				retries = 0,
				now = function()
					return now
				end,
			},
			{
				now = function()
					return now
				end,
				roll = function()
					return 0
				end,
				emit = function()
					events += 1
					if notifyFailure then
						error("emit failed")
					end
				end,
			},
			policy
				or {
					actions = { "survival-coop:buy-defense", "survival-coop:defend-active" },
					windowSeconds = 1000,
					maxOutcomes = 5,
				}
		)
	end
	return fresh(gate.backend, "first"),
		gate,
		fresh,
		function(value)
			now = value
		end,
		function()
			return events
		end
end
local function request(id: string?): any
	return { requestId = id or "one", sessionEpoch = 0, action = "survival-coop:buy-defense", args = {} }
end
return {
	["scheduled server event failure freezes advance and close without heartbeat receipts"] = function()
		local session, gate, _, clock, events = setup(
			{ actions = {}, serverActions = { "survival-coop:buy-defense" }, tickAction = "survival-coop:buy-defense" },
			nil,
			true
		)
		assert(session.join("1").ok, "join")
		for _ = 1, 100 do
			session.advance(0)
		end
		local empty = session.envelope("1").commands
		assert(empty ~= nil and empty.stateVersion == 0, "ordinary heartbeat writes no outcomes")
		clock(1)
		gate.fail(2)
		session.advance(1)
		assert(
			session.snapshot("1")[Survival.id].upgradeLevel == 0 and events() == 0,
			"failed scheduled stage unpublished"
		)
		assert(not session.close("1").ok and #session.members() == 1, "failed close remains joined")
		assert(session.close("1").ok and #session.members() == 0, "same scheduled request commits before detach")
		local record = gate.snapshot()["player-1"].data
		assert(
			record.commands.stateVersion == 1 and record.genres[Survival.id].data.balance == 90,
			"one durable scheduled event"
		)
		assert(
			record.commands.epochs["0"].outcomes["scheduled:1"] ~= nil,
			"event token retained through failed retries"
		)
	end,
	["host identity is trusted and old committed response replays under new host"] = function()
		local session, gate, fresh = setup()
		assert(session.join("1").ok, "join")
		local forged = request()
		forged.serverId = "attacker"
		assert(session.command("1", forged).reason == "invalid command transport", "caller host refused")
		forged.serverId = nil
		forged.nowMillis = 999
		assert(session.command("1", forged).reason == "invalid command transport", "caller clock refused")
		forged.nowMillis = nil
		forged.equipment = {}
		assert(session.command("1", forged).reason == "invalid command transport", "caller equipment refused")
		local committed = session.command("1", request())
		assert(committed.data and committed.data.host == "first", "initial store owner supplied")
		assert(session.close("1").ok, "release")
		local restored =
			fresh(Harness.barrier(serde.decode("json", serde.encode("json", gate.snapshot()))).backend, "new-host")
		assert(restored.join("1").ok, "new locked host")
		local replay = restored.command("1", request())
		assert(replay.data and replay.data.host == "first", "replay precedes restaging on new host")
		local nextResult = restored.command("1", request("next"))
		assert(nextResult.data and nextResult.data.host == "new-host", "new stage uses new owner identity")
		assert(restored.close("1").ok, "release new owner")
	end,
	["durable server lane refuses client origin and survives failed commit replay"] = function()
		local policy = { actions = {}, serverActions = { "survival-coop:buy-defense" } }
		local session, gate, fresh, _, events = setup(policy, true, true)
		assert(session.join("1").ok, "join")
		assert(not session.command("1", request()).ok, "client cannot call server action")
		assert(
			session.dispatchServer("1", "survival-coop:buy-defense", {}).reason == "DURABLE_COMMAND_REQUIRED",
			"legacy trusted route cannot bypass journal"
		)
		local forged = request()
		forged.origin = "server"
		assert(session.commandServer("1", forged).reason == "invalid command transport", "origin never client field")
		forged.origin = nil
		forged.actorId = "2"
		assert(not session.commandServer("1", forged).ok, "actor mismatch rejected")
		gate.fail(1)
		assert(session.commandServer("1", request()).reason == "COMMIT_FAILED", "failed commit no ACK")
		assert(session.snapshot("1")[Survival.id].balance == 100 and events() == 0, "candidate invisible")
		local result, diagnostic = session.commandServer("1", request())
		assert(result.ok and diagnostic ~= nil, "committed success reports notification errors")
		for _ = 1, 100 do
			assert(session.commandServer("1", request()).stateVersion == 1, "server replay before rate debit")
		end
		assert(events() == 1 and session.snapshot("1")[Survival.id].balance == 90, "one transition")
		assert(session.close("1").ok, "release")
		local restored =
			fresh(Harness.barrier(serde.decode("json", serde.encode("json", gate.snapshot()))).backend, "server-next")
		assert(
			restored.join("1").ok and restored.commandServer("1", request()).stateVersion == 1,
			"server durable reconstruction"
		)
		assert(restored.close("1").ok, "release restored")
	end,
	["server lost acknowledgment reconstructs committed outcome without second debit"] = function()
		local _, gate, fresh, clock =
			setup({ actions = {}, serverActions = { "survival-coop:buy-defense" } }, nil, true)
		local lose = false
		local backend = {
			update = function(key: string, transform: (any) -> any): (boolean, any)
				local ok, value = gate.backend.update(key, transform)
				if lose then
					lose = false
					return false, "lost ACK"
				end
				return ok, value
			end,
		}
		local session = fresh(backend, "server-old")
		assert(session.join("1").ok, "join")
		lose = true
		assert(session.commandServer("1", request()).reason == "COMMIT_FAILED", "lost ACK not success")
		clock(121)
		local restored = fresh(
			Harness.barrier(serde.decode("json", serde.encode("json", gate.snapshot()))).backend,
			"server-takeover"
		)
		assert(restored.join("1").ok, "takeover")
		assert(restored.commandServer("1", request()).stateVersion == 1, "replay committed server outcome")
		assert(restored.snapshot("1")[Survival.id].balance == 90, "one durable debit")
		assert(restored.close("1").ok, "release")
	end,
	["trusted retention floor protects live prior receipts and rejects client cutoff"] = function()
		local session, _, _, clock = setup({ actions = { "survival-coop:buy-defense" } })
		assert(session.join("1").ok, "join")
		clock(86399)
		assert(session.command("1", request()).ok, "late original epoch receipt")
		clock(86401)
		assert(session.commandEpoch("1") == 1, "next epoch")
		local nextRequest = request("next")
		nextRequest.sessionEpoch = 1
		nextRequest.expiredBeforeEpoch = 999
		assert(session.command("1", nextRequest).reason == "invalid command transport", "client cutoff rejected")
		nextRequest.expiredBeforeEpoch = nil
		local retained = session.command("1", nextRequest)
		assert(retained.data ~= nil and retained.data.floor == 0, "prior live receipt protects epoch zero")
		clock(172799)
		local later = request("later")
		later.sessionEpoch = 1
		local advanced = session.command("1", later)
		assert(advanced.data ~= nil and advanced.data.floor == 1, "floor advances only after all prior horizons expire")
		assert(session.close("1").ok, "release")
	end,
	["unversioned experimental ledger is refused without inventing receipt deadlines"] = function()
		local raw = { version = 1, genres = {}, commands = { epoch = 0, stateVersion = 1, outcomes = {} } }
		assert(#Executor.validateSave(raw, { Survival }) > 0, "old experimental ledger lacks durable issuance time")
		assert(#Executor.validateSave({ version = 1, genres = {} }, { Survival }) == 0, "legacy opt-out save unchanged")
	end,
	["production policy preserves late receipts across issued epochs and reconstruction"] = function()
		local session, gate, fresh, clock = setup({ actions = { "survival-coop:buy-defense" } })
		assert(session.join("1").ok, "join issues durable epoch")
		local commands = session.envelope("1").commands
		assert(commands ~= nil and commands.epochs["0"].expiresAt == 86400, "production TTL is 24h")
		clock(86399)
		local original = session.command("1", request())
		assert(original.ok, "late epoch commit")
		clock(86401)
		assert(session.commandEpoch("1") == 1, "new epoch persisted")
		assert(session.command("1", request()).stateVersion == original.stateVersion, "old valid receipt retained")
		assert(session.command("1", request("unknown")).reason == "REQUEST_EXPIRED", "expired epoch rejects unknown")
		assert(session.close("1").ok, "release")
		local restored =
			fresh(Harness.barrier(serde.decode("json", serde.encode("json", gate.snapshot()))).backend, "next")
		assert(restored.join("1").ok, "reconstruct")
		assert(restored.command("1", request()).stateVersion == original.stateVersion, "TTL survives restart")
		clock(172799)
		assert(restored.command("1", request()).reason == "REQUEST_EXPIRED", "receipt expires at own deadline")
		assert(restored.snapshot("1")[Survival.id].balance == 90, "expiry cannot debit")
		assert(restored.close("1").ok, "release restored")
	end,
	["4096 retained outcomes save reconstruct and reject capacity before mutation"] = function()
		local session, gate, fresh = setup({ actions = { "survival-coop:buy-defense" } })
		assert(session.join("1").ok, "join")
		assert(session.close("1").ok, "release seed")
		local disk = gate.snapshot()
		local ledger = disk["player-1"].data.commands
		local binding = Ledger.canonical({ action = "survival-coop:buy-defense", args = {} })
		for index = 1, 4096 do
			ledger.epochs["0"].outcomes[tostring(index)] = {
				binding = binding,
				result = { ok = true, stateVersion = index },
				createdAt = 0,
				expiresAt = 86400,
			}
		end
		ledger.stateVersion = 4096
		assert(
			#Executor.validateSave(disk["player-1"].data, { Survival }) == 0,
			"4096 ledger passes separate save boundary"
		)
		assert(not Executor.data(ledger.epochs["0"].outcomes), "client tuple bound not relaxed")
		local backend = Harness.barrier(serde.decode("json", serde.encode("json", disk)))
		local restored = fresh(backend.backend, "capacity")
		assert(restored.join("1").ok and restored.save("1").ok, "full ledger real ProfileStore save")
		assert(restored.command("1", request("4096")).stateVersion == 4096, "last record retained")
		assert(
			restored.command("1", request("overflow")).reason == "REQUEST_WINDOW_FULL",
			"cap refuses before execution"
		)
		assert(restored.snapshot("1")[Survival.id].balance == 100, "capacity refusal changes nothing")
		assert(restored.close("1").ok, "release")
	end,
	["postcommit emit and hook errors accompany immutable durable success"] = function()
		local session = setup(nil, true)
		assert(session.join("1").ok, "join")
		local result, diagnostic = session.command("1", request())
		assert(result.ok and diagnostic ~= nil, "committed success with diagnostic")
		assert(string.find(diagnostic.notificationError, "emit failed", 1, true), "emit error exposed")
		assert(string.find(diagnostic.notificationError, "hook failed", 1, true), "hook error exposed")
		local replay, replayDiagnostic = session.command("1", request())
		assert(serde.encode("json", result) == serde.encode("json", replay), "first return immutable replay response")
		assert(replayDiagnostic == nil and session.snapshot("1")[Survival.id].balance == 90, "no hook replay or debit")
		assert(session.close("1").ok, "release")
	end,
	["committed request remains replayable across clock bucket boundary"] = function()
		local session, _, _, clock = setup()
		clock(999)
		assert(session.join("1").ok, "join immediately before former bucket boundary")
		local command = request()
		command.sessionEpoch = session.commandEpoch("1")
		local result = session.command("1", command)
		assert(result.ok, "commit before boundary")
		clock(1001)
		assert(
			session.command("1", command).stateVersion == result.stateVersion,
			"receipt must survive clock bucket boundary"
		)
		assert(session.close("1").ok, "release")
	end,
	["backend callback replay and lost ACK reconstruct exactly one native debit"] = function()
		local _, gate, fresh, clock, events = setup()
		local loseAck = false
		local replayBackend = {
			update = function(key: string, transform: (any) -> any): (boolean, any)
				local ok, value = gate.backend.update(key, function(old)
					transform(old)
					return transform(old)
				end)
				if loseAck then
					loseAck = false
					return false, "lost acknowledgment"
				end
				return ok, value
			end,
		}
		local session = fresh(replayBackend, "lost-ack")
		assert(session.join("1").ok, "join")
		loseAck = true
		assert(session.command("1", request()).reason == "COMMIT_FAILED", "no ACK before confirmed success")
		assert(session.snapshot("1")[Survival.id].balance == 100 and events() == 0, "no tentative visibility")
		clock(121)
		local restored =
			fresh(Harness.barrier(serde.decode("json", serde.encode("json", gate.snapshot()))).backend, "takeover")
		assert(restored.join("1").ok, "expired owner reconstructs durable aggregate")
		local result = restored.command("1", request())
		assert(result.ok and result.stateVersion == 1, "lost ACK replays durable result")
		assert(restored.snapshot("1")[Survival.id].balance == 90, "exactly one debit")
		assert(restored.snapshot("1")[Survival.id].upgradeLevel == 1, "exactly one upgrade")
		assert(restored.close("1").ok, "release restored owner")
	end,
	["failed command can complete across epoch boundary without a second transition"] = function()
		local session, gate, _, clock, events = setup()
		clock(999)
		assert(session.join("1").ok, "join")
		gate.fail(1)
		assert(not session.command("1", request()).ok, "failed save")
		clock(1000)
		assert(session.command("1", request()).ok, "accepted pending request completes")
		assert(events() == 1 and session.snapshot("1")[Survival.id].balance == 90, "one transition")
		assert(session.command("1", request()).ok, "settled receipt retains full TTL")
		assert(not session.restore("1", session.envelope("1")).ok, "restore cannot rewind ledger")
		assert(session.close("1").ok, "release")
	end,
	["durable native failure suspension replay and reconstructed response isolation"] = function()
		local session, gate, fresh, clock, events = setup()
		assert(session.join("1").ok, "durable command invariant")
		gate.fail(1)
		assert(session.command("1", request()).reason == "COMMIT_FAILED", "durable command invariant")
		assert(session.snapshot("1")[Survival.id].balance == 100 and events() == 0, "durable command invariant")
		gate.suspend()
		local result: any
		local worker = coroutine.create(function()
			result = session.command("1", request())
		end)
		local ok, signal = coroutine.resume(worker)
		assert(ok and signal == "commit-barrier-entered", "durable command invariant")
		assert(session.command("1", request()).reason == "COMMAND_PENDING", "durable command invariant")
		assert(
			session.dispatchServer("1", "survival-coop:buy-defense", {}).reason == "COMMAND_PENDING",
			"trusted ingress cannot race pending commit"
		)
		assert(session.snapshot("1")[Survival.id].upgradeLevel == 0 and events() == 0, "durable command invariant")
		assert(coroutine.resume(worker))
		assert(
			coroutine.status(worker) == "dead" and result.ok and result.stateVersion == 1,
			"durable command invariant"
		)
		local original = serde.encode("json", result)
		result.data.jobId = "tampered"
		result.data.outputs[1] = "tampered"
		for _ = 1, 100 do
			assert(serde.encode("json", (session.command("1", request()))) == original, "durable command invariant")
		end
		assert(events() == 1 and session.snapshot("1")[Survival.id].balance == 90, "durable command invariant")
		local forged = request()
		forged.actorId = "2"
		assert(
			not session.command("1", forged).ok and not session.command("2", request()).ok,
			"durable command invariant"
		)
		local changed = request()
		changed.action = "survival-coop:defend-active"
		assert(session.command("1", changed).reason == "REQUEST_CONFLICT", "durable command invariant")
		local cyclic = request()
		cyclic.args[1] = cyclic
		assert(not session.command("1", cyclic).ok, "durable command invariant")
		local nonfinite = request()
		nonfinite.sessionEpoch = math.huge
		assert(not session.command("1", nonfinite).ok, "durable command invariant")
		assert(session.close("1").ok, "durable command invariant")
		local disk = serde.decode("json", serde.encode("json", gate.snapshot()))
		local restoredGate = Harness.barrier(disk)
		local restored = fresh(restoredGate.backend, "second")
		assert(restored.join("1").ok, "durable command invariant")
		assert(serde.encode("json", (restored.command("1", request()))) == original, "durable command invariant")
		assert(restored.snapshot("1")[Survival.id].balance == 90 and events() == 1, "durable command invariant")
		clock(1000)
		assert(restored.command("1", request()).reason == "REQUEST_EXPIRED", "durable command invariant")
		assert(restored.close("1").ok, "durable command invariant")
	end,
	["replay precedes rate debit and window retains all accepted IDs"] = function()
		local session = setup()
		assert(session.join("1").ok, "durable command invariant")
		for index = 1, 5 do
			assert(session.command("1", request(tostring(index))).ok, "durable command invariant")
		end
		for _ = 1, 100 do
			assert(session.command("1", request("1")).ok, "durable command invariant")
		end
		assert(session.command("1", request("6")).reason == "REQUEST_WINDOW_FULL", "durable command invariant")
		assert(session.snapshot("1")[Survival.id].balance == 50, "durable command invariant")
		assert(session.close("1").ok, "durable command invariant")
	end,
}
