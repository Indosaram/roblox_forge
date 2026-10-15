--!strict
-- qaharness: the native scenario executor behind `lune run cli/forge qa run`.
--
-- It drives the REAL modules: core/infra/genre/Session over a real
-- ProfileStore and backend, which drives the real Executor and the real genre
-- adapters. The harness owns no survival, economy or crafting rule; it only
-- translates declarative steps into Session calls and compares the results the
-- real modules returned. If a mechanism is missing, the Session refuses and the
-- scenario FAILs -- there is no path here that can synthesise a success.
--
-- Time is explicit: the scenario advances an injected clock, never a sleep.
-- Commit barriers are explicit too: a barrier suspends or fails the backend's
-- own update callback and the step resumes on that exact signal.

local Session = require("../../../core/infra/genre/Session")
local MemoryBackend = require("../../../core/infra/data/MemoryBackend")
local Clock = require("../../../core/infra/genre/Clock")
local Contract = require("../../../core/domain/genre/Contract")
local qascenario = require("./qascenario")
local serde = require("@lune/serde")
local SettlementRuntime = require("../../../genres/survival-coop/module/SettlementRuntime")
local SettlementBridge = require("../../../genres/survival-coop/module/SettlementBridge")
local TransferRuntime = require("../../../genres/survival-coop/module/TransferRuntime")
local TransferBridge = require("../../../genres/survival-coop/module/TransferBridge")
local Settlement = require("../../../core/domain/settlement/Settlement")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Content = require("../../../core/domain/survival/Content")
local FencedStore = require("../../../core/infra/data/FencedStore")
local Rng = require("../../../core/domain/random/Rng")
local Journal = require("../../../core/domain/command/Journal")

local M = {}

--- Normalizes a scenario player reference to the id the Session keys on.
local function playerOf(step: any): string
	return qascenario.playerId(step.player) :: string
end

export type StepResult = { index: number, op: string, ok: boolean, detail: string? }
export type Outcome = {
	ok: boolean,
	scenario: string,
	kind: string,
	steps: { StepResult },
	assertions: number,
	failures: { string },
	elapsedClockSeconds: number,
	seed: number?,
	-- Journal.hash of the durable store plus every joined actor's snapshot at the end of the run.
	stateHash: string?,
	-- Set when a replay could not apply the journal in step with the scenario.
	diverged: string?,
}

--- `journal` records every join/leave/command/advance/save/reload the run executes.
--- `replay` makes those same steps take their inputs (actor, action, args,
--- requestId, clock and seed) from a recorded journal, in order.
export type RunOptions = { journal: Journal.Journal?, replay: Journal.Journal? }

export type Target = {
	clock: Clock.Clock?,
	lifecycle: { bind: (any) -> (), close: () -> Contract.Result }?,
	starterWorld: boolean?,
	services: {
		survivalSpatial: any?,
		survivalDeath: any?,
		survivalSettlement: any?,
		survivalTransfer: any?,
		survivalGathering: any?,
		survivalWildlife: any?,
	}?,
	packConfig: Contract.PackConfig,
	contracts: { Contract.RuntimeContract },
	controls: { any },
	storeName: string,
	hooks: Contract.HookMap?,
	backend: any?,
	durable: any?,
	-- The pack's serialized genre spec, so a server-side presenter can read the declared
	-- presentation bindings. A native target carries no engine presenter, so it is optional.
	spec: any?,
	seed: number?,
}

--- A durable backend whose commits can be suspended or failed on demand. The
--- suspension yields from inside the real update callback, so a scenario
--- observes the exact commit boundary instead of guessing with a delay.
---
--- The yield is only safe because `runNative` executes every suspendable
--- session call inside a coroutine IT owns (`callSession` below). REPRODUCED
--- DEFECT: with no owning coroutine, `coroutine.yield` inside the backend
--- callback does not raise -- it silently abandons the remainder of the run
--- and the process exits 0, which reads as a pass. Ownership plus an explicit
--- `resume_commit` step is what makes the barrier honest.
export type Barrier = {
	backend: MemoryBackend.Backend,
	fail: (count: number) -> (),
	suspend: (string?, number?) -> (),
	pending: () -> boolean,
	resume: () -> (),
	snapshot: () -> { [string]: any },
}

local function deepClone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = deepClone(item)
	end
	return copy
end

--- Builds a barrier backend over durable storage. `storage` may be a table
--- restored from a serialized snapshot, which is how a scenario proves restart
--- durability across processes rather than trusting fresh memory.
function M.barrier(storage: { [string]: any }?): Barrier
	local data: { [string]: any } = storage or {}
	local failures = 0
	local armed = false
	local waiting = false
	local selectedKey: string? = nil
	local skip = 0
	local backend = {
		update = function(key: string, transform: (any) -> any): (boolean, any)
			if failures > 0 then
				failures -= 1
				return false, "commit barrier: backend refused"
			end
			if armed and (selectedKey == nil or selectedKey == key) and skip > 0 then
				skip -= 1
			elseif armed and (selectedKey == nil or selectedKey == key) then
				armed = false
				waiting = true
				coroutine.yield("commit-barrier-entered")
				waiting = false
			end
			local updated = transform(deepClone(data[key]))
			data[key] = deepClone(updated)
			return true, updated
		end,
	}
	return {
		backend = backend,
		fail = function(count: number)
			failures = count
		end,
		suspend = function(key, skipCount)
			selectedKey, skip = key, skipCount or 0
			armed = true
		end,
		pending = function()
			return waiting
		end,
		resume = function()
			armed = false
		end,
		snapshot = function()
			return deepClone(data)
		end,
	}
end

local function fieldValue(source: any, path: string): any
	local current = source
	for segment in string.gmatch(path, "[^%.]+") do
		if type(current) ~= "table" then
			return nil
		end
		local index = tonumber(segment)
		current = if index ~= nil then current[index] else current[segment]
	end
	return current
end

local function compare(step: any, actual: any): (boolean, string)
	if step.is_nil ~= nil then
		local want = step.is_nil == true
		return (actual == nil) == want, string.format("is_nil=%s actual=%s", tostring(want), tostring(actual))
	end
	if step.equals ~= nil then
		return actual == step.equals, string.format("expected %s, got %s", tostring(step.equals), tostring(actual))
	end
	if step.not_equals ~= nil then
		return actual ~= step.not_equals, string.format("expected not %s", tostring(step.not_equals))
	end
	if step.at_least ~= nil then
		return type(actual) == "number" and actual >= step.at_least,
			string.format("expected >= %s, got %s", tostring(step.at_least), tostring(actual))
	end
	if step.at_most ~= nil then
		return type(actual) == "number" and actual <= step.at_most,
			string.format("expected <= %s, got %s", tostring(step.at_most), tostring(actual))
	end
	return false, "no comparator"
end

--- Runs one validated native scenario against a real Session built from
--- `target`. Returns the outcome; it never raises for a scenario failure, and
--- it never reports ok for a step the real modules refused.
function M.runNative(scenario: qascenario.Scenario, target: Target, barrier: Barrier?, options: RunOptions?): Outcome
	local runOptions: RunOptions = options or {}
	local recording = runOptions.journal
	local replaying = runOptions.replay
	-- A replay rolls the recorded seed. Journal meta.seed is mandatory, so 0 with an
	-- unseeded scenario means "no stream", matching the recorded run.
	local seed = scenario.seed
	if replaying and (scenario.seed ~= nil or replaying.meta.seed ~= 0) then
		seed = replaying.meta.seed
	end
	local outcome: Outcome = {
		ok = true,
		scenario = scenario.name,
		kind = scenario.kind,
		steps = {},
		assertions = 0,
		failures = {},
		elapsedClockSeconds = 0,
		seed = seed,
	}
	local function record(index: number, op: string, ok: boolean, detail: string?)
		table.insert(outcome.steps, { index = index, op = op, ok = ok, detail = detail })
		if not ok then
			outcome.ok = false
			table.insert(outcome.failures, string.format("steps[%d] %s: %s", index, op, detail or "failed"))
		end
	end
	local gate = barrier or M.barrier()
	if scenario.kind ~= "native" then
		outcome.ok = false
		table.insert(outcome.failures, "native harness requires native scenario authority")
		return outcome
	end
	local schemaErrors = qascenario.validate(scenario)
	if #schemaErrors > 0 then
		outcome.ok = false
		outcome.failures = schemaErrors
		return outcome
	end
	-- One stream per run, created before the first session, so a reload resumes the
	-- stream where it stopped instead of replaying it. No seed keeps the roll fixed at 0.
	local rng = if seed ~= nil then Rng.new(seed) else nil
	local function roll(): number
		if rng ~= nil then
			return rng:nextNumber()
		end
		return 0
	end
	local wall = 0
	local clock = Clock.new(function()
		return wall
	end)
	local function nowMillis(): number
		return Clock.millis(math.max(0, clock.now()))
	end
	-- Journal cursor: records the entry, or, in a replay, returns the next recorded
	-- entry whose fields then drive the step. A kind mismatch is a divergence.
	local cursor = 0
	local function journalStep(entry: Journal.Entry): Journal.Entry
		if replaying then
			cursor += 1
			local recorded = replaying.entries[cursor]
			if recorded == nil or recorded.kind ~= entry.kind then
				local reason = string.format(
					"journal entry %d: scenario expects %s, journal has %s",
					cursor,
					entry.kind,
					if recorded then recorded.kind else "nothing"
				)
				outcome.diverged = outcome.diverged or reason
				error(reason, 0)
			end
			return recorded
		end
		if recording then
			recording:record(entry)
		end
		return entry
	end
	local spatial: {
		campfire: (string, string) -> { reachable: boolean }?,
		station: ((string, string) -> { kind: string, reachable: boolean }?)?,
	}? =
		nil
	if scenario.data and scenario.data.survivalSpatial ~= nil then
		local errors = qascenario.validate(scenario)
		assert(#errors == 0, table.concat(errors, "; "))
		local fixture = deepClone(scenario.data.survivalSpatial)
		local positions: { [string]: any } = {}
		for id, position in fixture.players do
			positions[qascenario.playerId(id) :: string] = position
		end
		spatial = {
			station = function(playerId, stationId)
				local player = positions[playerId]
				local station = if fixture.stations then fixture.stations[stationId] else nil
				if not player or not station then
					return nil
				end
				local dx, dy, dz = player.x - station.x, player.y - station.y, player.z - station.z
				return {
					kind = station.kind,
					reachable = dx * dx + dy * dy + dz * dz <= fixture.radiusStuds * fixture.radiusStuds,
				}
			end,
			campfire = function(playerId, campfireId)
				local player, fire = positions[playerId], fixture.campfires[campfireId]
				if not player or not fire then
					return nil
				end
				local dx, dy, dz = player.x - fire.x, player.y - fire.y, player.z - fire.z
				return { reachable = dx * dx + dy * dy + dz * dz <= fixture.radiusStuds * fixture.radiusStuds }
			end,
		}
	end
	local runtime: SettlementRuntime.Runtime? = nil
	local transferCatalog: Catalog.Catalog? = nil
	local transfers: { [string]: TransferRuntime.Runtime } = {}
	local transferAccess: { [string]: Session.PersonalTransfer } = {}
	local actualTarget = table.clone(target)
	local trustedServices: {
		survivalSpatial: any?,
		survivalDeath: any?,
		survivalSettlement: any?,
		survivalTransfer: any?,
		survivalGathering: any?,
		survivalWildlife: any?,
	} =
		table.clone(target.services or {})
	actualTarget.services = trustedServices
	-- Explicit native coordinates supply only spatial facts. CraftingAdapter
	-- still owns all real Vitals/DeathBundle transitions; there are no Instances.
	if scenario.data and scenario.data.nativeDeath ~= nil then
		local revision = scenario.data.nativeDeath
		if type(revision) ~= "string" or #revision == 0 or #revision > 128 or not scenario.data.survivalSpatial then
			outcome.ok = false
			table.insert(
				outcome.failures,
				"nativeDeath requires a bounded world revision and validated survivalSpatial"
			)
			return outcome
		end
		local fixture = deepClone(scenario.data.survivalSpatial)
		local positions: { [string]: any } = {}
		for id, position in fixture.players do
			positions[qascenario.playerId(id) :: string] = position
		end
		trustedServices.survivalDeath = {
			worldRevision = revision,
			position = function(id: string)
				return positions[id]
			end,
			equipment = function(id: string)
				return if positions[id] then {} else nil
			end,
			reachable = function(id: string, position: any): boolean
				local origin = positions[id]
				if not origin then
					return false
				end
				local dx, dy, dz = origin.x - position.x, origin.y - position.y, origin.z - position.z
				return dx * dx + dy * dy + dz * dz <= fixture.radiusStuds * fixture.radiusStuds
			end,
		}
	end
	local function settlementOwner()
		local fixture = if scenario.data then scenario.data.settlement else nil
		if not fixture then
			return
		end
		local fixtureErrors = qascenario.validate(scenario)
		assert(#fixtureErrors == 0, table.concat(fixtureErrors, "; "))
		local config = target.packConfig.configs["survival-coop"]
		local content, errors = Content.canonicalize(config.inventory.content)
		assert(content, table.concat(errors, "; "))
		local items: { Catalog.Definition } = {}
		for _, item in content.items do
			table.insert(items, {
				id = item.id,
				stackMax = item.stackMax,
				weightMilli = item.weightMilli,
				maxDurabilityMilli = item.maxDurabilityMilli,
			})
		end
		local catalog = Catalog.new(items)
		transferCatalog = catalog
		local definitions: { [string]: Settlement.Definition } = {}
		for _, definition in content.structures do
			definitions[definition.id] = {
				id = definition.id,
				footprintX = definition.footprintX,
				footprintZ = definition.footprintZ,
				cost = definition.cost,
			}
		end
		local warehouse =
			Inventory.new("qa-warehouse", { slots = fixture.slots, softWeightMilli = 60000, hardWeightMilli = 90000 })
		for _, item in fixture.items do
			warehouse = assert(Inventory.add(warehouse, catalog, item, warehouse.version))
		end
		runtime = assert(SettlementRuntime.new(
			{
				key = fixture.key,
				now = function()
					return math.floor(wall)
				end,
				catalog = catalog,
				definitions = definitions,
				verifyTransfer = function(actor, proof)
					return proof == actor and fixture.positions[actor] ~= nil
				end,
				initial = {
					settlement = Settlement.new(
						{ tribeId = fixture.tribeId, width = 32, depth = 32, cellStuds = 4, maxMembers = 4 },
						fixture.owner
					),
					warehouse = warehouse,
				},
			},
			FencedStore.new(gate.backend, {
				sessionId = "qa-settlement",
				leaseSeconds = 120,
				now = function()
					return math.floor(wall)
				end,
				budget = {
					encode = function(value)
						return serde.encode("json", value)
					end,
				},
			})
		))
		local owner = assert(runtime, "settlement owner")
		trustedServices.survivalTransfer = TransferBridge.new({
			resolve = function(actor)
				return transfers[actor]
			end,
			epoch = function(actor)
				return owner.epoch(actor)
			end,
			request = function(actor, action, args, context)
				local policy = if scenario.data then scenario.data.durable else nil
				if not policy or not policy.personal then
					return nil, nil, nil, "PERSONAL_PERSISTENCE_REQUIRED"
				end
				local tribeProfile = owner.transferStore().profile()
				local authority = tribeProfile.data.authority
				local identity = "transfer:" .. actor .. ":" .. context.sessionEpoch .. ":" .. context.requestId
				local personalKey = policy.personal.namespace .. ":" .. actor
				local deposit = action == "survival-coop:transfer-deposit"
				local grant = tribeProfile.data.transferGrants.entries[identity]
				if grant then
					local accepted = grant.request
					if
						accepted.itemId ~= args[1]
						or accepted.quantity ~= args[2]
						or accepted.source ~= (if deposit then personalKey else fixture.key)
					then
						return nil, nil, nil, "TRANSFER_CONFLICT"
					end
					return table.clone(accepted), authority.membershipRevision, actor, nil
				end
				local issued = authority.epochs[actor]
				if not issued or issued.epoch ~= context.sessionEpoch then
					return nil, nil, nil, "REQUEST_EXPIRED"
				end
				local outputId = identity .. ":output"
				local access = transferAccess[actor]
				local bag = if deposit and access
					then access.profile().data.envelope.genres["survival-coop"].data.inventory.bag
					else tribeProfile.data.inventory
				if bag and bag.items[args[1]] and bag.items[args[1]].quantity == args[2] then
					outputId = args[1]
				end
				return {
					id = identity,
					actor = actor,
					epoch = tostring(context.sessionEpoch),
					expiresAt = issued.expiresAt,
					source = if deposit then personalKey else fixture.key,
					destination = if deposit then fixture.key else personalKey,
					itemId = args[1],
					outputId = outputId,
					quantity = args[2],
				},
					authority.membershipRevision,
					actor,
					nil
			end,
		})
		trustedServices.survivalSettlement = SettlementBridge.new({
			resolve = function(actor)
				return if table.find(scenario.players, actor) then owner else nil
			end,
			authorize = function(actor, action, args)
				local position = fixture.positions[actor]
				if not position then
					return { ok = false, reason = "NO_POSITION" }
				end
				local x, z = nil :: number?, nil :: number?
				if action == "survival-coop:settlement-reserve" then
					x, z = args[2], args[3]
				elseif action == "survival-coop:settlement-place" or action == "survival-coop:settlement-demolish" then
					-- Geometry comes from the owner snapshot, not a client placement.
					local state = owner.snapshot(actor)
					if state then
						local placement = if action == "survival-coop:settlement-place"
							then state.settlement.reservations[args[1]]
							else state.settlement.structures[args[1]]
						if placement then
							x, z = placement.x, placement.z
						end
					end
				end
				if x and z then
					local dx, dz = position.x - x * 4, position.z - z * 4
					if dx * dx + dz * dz > fixture.radiusStuds * fixture.radiusStuds then
						return { ok = false, reason = "UNREACHABLE" }
					end
				end
				return { ok = true }
			end,
		})
	end
	settlementOwner()
	local fixture: any = nil
	local function openFixture()
		if scenario.name == "gather-craft-settle" then
			assert(scenario.genre == "survival-coop" and scenario.pack == "fixture-survival", "fixture pack binding")
			assert(table.find(scenario.fixtures, "cli/forge/fixtures/survival-services"))
			fixture = require("../fixtures/survival-services/scenario").new(target.packConfig, gate.backend, function()
				return wall
			end)
			for key, service in fixture.services do
				(trustedServices :: any)[key] = service
			end
		end
	end
	openFixture()
	local session = Session.new(actualTarget, gate.backend, {
		sessionId = "qa-" .. scenario.name,
		lockTimeout = 120,
		retries = 0,
		now = function()
			return wall
		end,
	}, {
		now = clock.now,
		encode = function(value)
			return serde.encode("json", value)
		end,
		survivalSettlement = trustedServices.survivalSettlement,
		survivalTransfer = trustedServices.survivalTransfer,
		survivalGathering = trustedServices.survivalGathering,
		survivalSpatial = spatial,
		survivalDeath = trustedServices.survivalDeath,
		roll = roll,
		emit = function(_event) end,
	}, if scenario.data then scenario.data.durable else nil)
	if fixture then
		fixture.bind(session)
	end
	local function transferOwner(actor: string)
		if not runtime or not transferCatalog then
			return
		end
		local access = session.personalTransfer(actor)
		if not access then
			return
		end
		transferAccess[actor] = access
		transfers[actor] = TransferRuntime.new({
			personal = access.personal,
			profile = access.profile,
			install = access.install,
			tribe = runtime.transferStore(),
			catalog = transferCatalog,
			now = function()
				return math.floor(wall)
			end,
			maxReceipts = 4096,
		})
	end
	local saves: { [string]: any } = {}
	local results: { [string]: any } = {}
	-- A session call parked at a commit barrier. The scenario resumes it with
	-- an explicit `resume_commit` step; nothing here ever sleeps or polls.
	local suspendedCall: thread? = nil
	local suspendedOp: string? = nil

	--- Runs a session call that may suspend inside the backend commit. The call
	--- owns a coroutine, so a barrier yield returns control HERE instead of
	--- unwinding the run. Returns (finished, detail); `finished == false` means
	--- the call is parked at the commit boundary.
	local function callSession(op: string, body: () -> string?): (boolean, string?)
		if suspendedCall ~= nil then
			return true, "a commit is already suspended; resume_commit it first"
		end
		local worker = coroutine.create(body)
		local ok, value = coroutine.resume(worker)
		if not ok then
			return true, tostring(value)
		end
		if coroutine.status(worker) == "suspended" then
			suspendedCall = worker
			suspendedOp = op
			return false, nil
		end
		return true, value
	end

	for index, step in scenario.steps do
		local op = step.op
		local ok, detail = pcall(function(): string?
			if op == "join" then
				local actor =
					journalStep({ kind = "join", actor = playerOf(step), atMillis = nowMillis() }).actor :: string
				local result = session.join(actor)
				if not result.ok then
					return "join refused: " .. tostring(result.reason)
				end
				transferOwner(actor)
				return nil
			elseif op == "leave" or op == "close" then
				local actor =
					journalStep({ kind = "leave", actor = playerOf(step), atMillis = nowMillis() }).actor :: string
				local finished, closeDetail = callSession(op, function(): string?
					local result = session.close(actor)
					if not result.ok then
						return "close refused: " .. tostring(result.reason)
					end
					return nil
				end)
				if not finished then
					return if step.expect_suspended == true
						then nil
						else "close suspended at a commit barrier without expect_suspended"
				end
				if step.expect_suspended == true then
					return "close was expected to suspend at a commit barrier but completed"
				end
				return closeDetail
			elseif op == "command" or op == "command_server" then
				if op == "command_server" and scenario.kind ~= "native" then
					return "command_server is native-only"
				end
				local command: (string, any) -> (Contract.Result, { notificationError: string }?) = if op
						== "command_server"
					then session.commandServer
					else session.command
				local function invoke(): string?
					for _ = 1, step.times or 1 do
						local entry = journalStep({
							kind = "command",
							actor = playerOf(step),
							action = step.action,
							args = step.args or {},
							requestId = step.requestId,
							atMillis = nowMillis(),
						})
						local actor = entry.actor :: string
						local result = command(actor, {
							requestId = entry.requestId,
							sessionEpoch = if step.sessionEpoch == "current"
								then session.commandEpoch(actor, entry.action)
								else step.sessionEpoch,
							action = entry.action,
							args = entry.args or {},
							actorId = step.actorId,
						})
						results[actor] = result
						if (step.expect or "ok") == "ok" and not result.ok then
							return "command refused: " .. tostring(result.reason)
						end
						if step.expect == "refused" and result.ok then
							return "command unexpectedly succeeded"
						end
					end
					return nil
				end
				-- A duplicate may run while the original command owns the parked commit.
				if suspendedCall then
					return invoke()
				end
				local finished, commandDetail = callSession(op, invoke)
				if not finished then
					return if step.expect_suspended then nil else "command unexpectedly suspended"
				end
				if step.expect_suspended then
					return "command did not suspend"
				end
				return commandDetail
			elseif op == "expect_result" then
				outcome.assertions += 1
				local matched, reason = compare(step, fieldValue(results[playerOf(step)], step.field :: string))
				return if matched then nil else reason
			elseif op == "dispatch" or op == "server_dispatch" then
				local expect = step.expect or "ok"
				if op == "server_dispatch" and scenario.kind ~= "native" then
					return "server_dispatch is native-only"
				end
				-- A dispatch is journaled as a command without a requestId.
				local entry = journalStep({
					kind = "command",
					actor = playerOf(step),
					action = step.action,
					args = step.args or {},
					atMillis = nowMillis(),
				})
				local actor = entry.actor :: string
				local result = if op == "server_dispatch"
					then session.dispatchServer(actor, entry.action :: string, entry.args or {})
					else session.dispatch(actor, entry.action :: string, entry.args or {})
				results[actor] = result
				if expect == "ok" and not result.ok then
					return "dispatch refused: " .. tostring(result.reason)
				end
				if expect == "refused" and result.ok then
					return "dispatch unexpectedly succeeded"
				end
				return nil
			elseif op == "begin_clock" then
				clock.begin()
				return nil
			elseif op == "advance_to" then
				local seconds = step.seconds :: number
				local entry = journalStep({ kind = "advance", atMillis = Clock.millis(seconds) })
				if replaying then
					seconds = entry.atMillis / 1000
				end
				wall = math.max(wall, seconds)
				session.advance(clock.advanceTo(seconds))
				outcome.elapsedClockSeconds = clock.now()
				return nil
			elseif op == "advance_elapsed" then
				local value: number
				if replaying then
					value = clock.advanceTo(journalStep({ kind = "advance", atMillis = 0 }).atMillis / 1000)
				else
					value = clock.advanceElapsed(step.seconds :: number)
					journalStep({ kind = "advance", atMillis = Clock.millis(value) })
				end
				wall = math.max(wall, value)
				session.advance(value)
				outcome.elapsedClockSeconds = clock.now()
				return nil
			elseif op == "save" then
				local actor =
					journalStep({ kind = "save", actor = playerOf(step), atMillis = nowMillis() }).actor :: string
				local finished, saveDetail = callSession(op, function(): string?
					local result = session.save(actor)
					if not result.ok then
						return "save refused: " .. tostring(result.reason)
					end
					if step.label ~= nil then
						saves[step.label] = session.envelope(actor)
					end
					return nil
				end)
				if not finished then
					return if step.expect_suspended == true
						then nil
						else "save suspended at a commit barrier without expect_suspended"
				end
				if step.expect_suspended == true then
					return "save was expected to suspend at a commit barrier but completed"
				end
				return saveDetail
			elseif op == "restore" then
				local saved = saves[step.from]
				if saved == nil then
					return "restore: no save labelled " .. tostring(step.from)
				end
				local result = session.restore(playerOf(step), saved)
				if not result.ok then
					return "restore refused: " .. tostring(result.reason)
				end
				return nil
			elseif op == "commit_barrier" then
				if suspendedCall ~= nil then
					return "a commit is already suspended; resume_commit it first"
				end
				if step.mode == "fail" then
					gate.fail(step.count or 1)
				else
					gate.suspend(step.key, step.skip)
				end
				return nil
			elseif op == "resume_commit" then
				local worker = suspendedCall
				if worker == nil then
					return "resume_commit: no commit is suspended"
				end
				-- Resume the exact parked commit. This is the event boundary:
				-- the scenario decides when the backend proceeds, never a timer.
				suspendedCall, suspendedOp = nil, nil
				gate.resume()
				local resumed, value = coroutine.resume(worker)
				if not resumed then
					return tostring(value)
				end
				if coroutine.status(worker) == "suspended" then
					suspendedCall = worker
					return "resume_commit: the commit suspended again"
				end
				return value
			elseif op == "expect_snapshot" then
				outcome.assertions += 1
				local genre = step.genre :: string
				local field = step.field :: string
				local snapshot = session.snapshot(playerOf(step))
				local actual = fieldValue(if step.scope == "session" then snapshot else snapshot[genre], field)
				local matched, reason = compare(step, actual)
				return if matched
					then nil
					else string.format(
						"%s.%s: %s",
						if step.scope == "session" then "session" else genre,
						field,
						reason
					)
			elseif op == "expect_members" then
				outcome.assertions += 1
				-- Session.members() is `() -> { string }` (core/infra/genre/Session.luau:18),
				-- already the exact roster contract this asserts against. The
				-- previous diagnostic came from the scenario-supplied list:
				-- `step.members or {}` infers `{string} | {}`, which is not
				-- callable/iterable as one type. Bind it to a typed local
				-- first instead of casting the Session API away.
				local members = session.members()
				local declared: { any } = step.members or {}
				local want: { string } = {}
				for _, id in declared do
					table.insert(want, qascenario.playerId(id) :: string)
				end
				if #members ~= #want then
					return string.format("members: expected %d, got %d", #want, #members)
				end
				for i, id in want do
					if members[i] ~= id then
						return string.format("members[%d]: expected %s, got %s", i, id, tostring(members[i]))
					end
				end
				return nil
			elseif op == "recover_transfers" then
				local id = playerOf(step)
				local result = session.recoverTransfers(id, step.maximum)
				results[id] = result
				return if result.ok then nil else "recovery refused: " .. tostring(result.reason)
			elseif op == "reload" then
				-- Rebuild the session from the durable snapshot only: this is the
				-- restart proof, so nothing in-memory may carry over.
				journalStep({ kind = "reload", atMillis = nowMillis() })
				if runtime then
					assert(runtime.close().ok, "settlement release before reload")
				end
				if fixture then
					assert(fixture.close().ok, "fixture release before reload")
				end
				local durable = serde.decode("json", serde.encode("json", gate.snapshot()))
				local restarted = M.barrier(durable)
				gate = restarted
				table.clear(transfers)
				table.clear(transferAccess)
				settlementOwner()
				openFixture()
				session = Session.new(actualTarget, gate.backend, {
					sessionId = "qa-" .. scenario.name .. "-restart",
					lockTimeout = 120,
					retries = 0,
					now = function()
						return wall
					end,
				}, {
					now = clock.now,
					encode = function(value)
						return serde.encode("json", value)
					end,
					survivalSettlement = trustedServices.survivalSettlement,
					survivalTransfer = trustedServices.survivalTransfer,
					survivalGathering = trustedServices.survivalGathering,
					survivalSpatial = spatial,
					survivalDeath = trustedServices.survivalDeath,
					roll = roll,
					emit = function(_event) end,
				}, if scenario.data then scenario.data.durable else nil)
				if fixture then
					fixture.bind(session)
				end
				return nil
			end
			return string.format("operation '%s' has no native driver", tostring(op))
		end)
		if not ok then
			record(index, op, false, tostring(detail))
		else
			record(index, op, detail == nil, detail)
		end
	end

	-- A commit still parked at a barrier is a scenario defect, not a pass: the
	-- run would otherwise end with real work abandoned mid-commit.
	if suspendedCall ~= nil then
		outcome.ok = false
		table.insert(
			outcome.failures,
			string.format("scenario ended with '%s' suspended at a commit barrier", tostring(suspendedOp))
		)
	end
	if replaying and outcome.diverged == nil and cursor ~= #replaying.entries then
		outcome.diverged = string.format("journal has %d entries, the scenario applied %d", #replaying.entries, cursor)
	end
	-- The state hash covers every durable save plus every joined actor's snapshot.
	local snapshots: { [string]: any } = {}
	for _, id in session.members() do
		snapshots[id] = session.snapshot(id)
	end
	outcome.stateHash = Journal.hash({ store = gate.snapshot(), snapshots = snapshots })
	if recording then
		recording:finish(outcome.stateHash :: string)
	end
	if outcome.assertions == 0 then
		outcome.ok = false
		table.insert(outcome.failures, "scenario asserted nothing: a no-op run is never coverage")
	end
	if runtime and suspendedCall == nil then
		local released = runtime.close()
		if not released.ok then
			outcome.ok = false
			table.insert(outcome.failures, "settlement cleanup: " .. tostring(released.reason))
		end
	end
	if fixture and suspendedCall == nil then
		local released = fixture.close()
		if not released.ok then
			outcome.ok = false
			table.insert(outcome.failures, "fixture cleanup: " .. tostring(released.reason))
		end
	end
	return outcome
end

return M
