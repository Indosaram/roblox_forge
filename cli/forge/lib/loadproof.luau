--!strict
-- loadproof: the headless 8-actor load proof for a generated pack.
--
-- It drives the REAL modules - core/infra/genre/Session over a real
-- ProfileStore, which drives the real Executor and the real genre adapters -
-- with no Studio, no engine and no clock sleep. Eight actors join one session,
-- run the pack's own golden path concurrently at the same logical instant,
-- save, leave and rejoin, and the run is compared against a single-actor
-- reference over the same roster.
--
-- What it asserts, and why each assertion is honest:
--   * join        - the whole roster joins, and every loop actor rejoins.
--   * no-errors   - no call raised, every action returned a verdict, every
--                   save/leave/rejoin succeeded, and a refusal always named a
--                   reason.
--   * rate-limits - the primary actor's accepted/refused vector equals the
--                   reference's. Rate buckets are per actor, so eight actors
--                   acting at one instant must not turn a refusal into an
--                   acceptance or the reverse. The primary acts first at every
--                   step in both runs, so a shared cooperative wave resolves
--                   the same way for it.
--   * no-duplicate-grants - the primary accepted no more actions than the
--                   reference, and for a durable command genre a replayed
--                   requestId returns the identical outcome without changing
--                   state.
--   * conservation- every numeric leaf of every actor is a finite non-negative
--                   safe integer, and the genre's own `validateSave` accepts
--                   every actor's envelope - the domain's conservation rule,
--                   applied to all eight actors.
--   * persistence - every numeric leaf the reference preserved across save,
--                   leave and rejoin is preserved for every actor too, so a
--                   rejoin grants nothing twice.
--
-- It does NOT assert that peers leave each other's state untouched: an arena
-- duel legitimately moves two actors' ratings and a cooperative wave is shared.
-- Asserting per-actor equality against a solo run would fail every adversarial
-- genre for a reason that is not a defect, so the proof asserts only what holds
-- by construction and reports the rest.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Session = require("../../../core/infra/genre/Session")
local MemoryBackend = require("../../../core/infra/data/MemoryBackend")
local Clock = require("../../../core/infra/genre/Clock")
local qascenario = require("./qascenario")
local qagen = require("./qagen")

local M = {}

M.ACTIONS = { "dispatch", "server_dispatch", "command", "command_server" } :: { string }
M.DEFAULT_ACTORS = 8

export type Step = {
	kind: string, -- "action" | "advance"
	op: string?,
	action: string?,
	args: { any }?,
	requestId: string?,
	seconds: number?,
}
export type Script = { primary: string, roster: { string }, steps: { Step } }
export type Invariant = { ok: boolean, detail: string? }
export type Result = {
	ok: boolean,
	actors: number,
	actions: number,
	invariants: { [string]: Invariant },
	failures: { string },
	reference: { accepted: number, refused: number },
	replay: { accepted: number, refused: number },
}

local function text(value: any): boolean
	return type(value) == "string" and string.find(value, "%S") ~= nil
end

--- The primary actor's executable script, read from the pack's own derived
--- native scenario. Expectations, captures and the other roster members' steps
--- are not part of it: a load proof replays the loop, it does not re-assert the
--- scenario's declared outcomes (the native QA column already did that).
---
--- `advance_elapsed` is relative to `begin_clock` and `advance_to` is absolute;
--- both normalize to one absolute clock target so the concurrent run and the
--- reference sample the same instant.
function M.script(scenario: any): Script
	assert(type(scenario) == "table" and scenario.kind == "native", "load proof requires a native scenario")
	local roster: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, raw in (if type(scenario.players) == "table" then scenario.players else {}) do
		local id = qascenario.playerId(raw)
		if id ~= nil and not seen[id] then
			seen[id] = true
			table.insert(roster, id)
		end
	end
	local primary = if #roster > 0 then roster[1] else "1"
	if not seen[primary] then
		table.insert(roster, primary)
		seen[primary] = true
	end
	local steps: { Step } = {}
	local target = 0
	for _, step in (if type(scenario.steps) == "table" then scenario.steps else {}) do
		if type(step) ~= "table" then
			continue
		end
		local op = step.op
		if op == "begin_clock" then
			target = 0
			continue
		end
		if op == "advance_elapsed" or op == "advance_to" then
			local seconds = step.seconds
			if type(seconds) == "number" then
				target = if op == "advance_elapsed" then target + seconds else math.max(target, seconds)
				table.insert(steps, { kind = "advance", seconds = target })
			end
			continue
		end
		if op == "join" or op == "leave" or op == "close" or op == "save" or op == "restore" then
			continue
		end
		if op == nil or not table.find(M.ACTIONS, op) then
			continue
		end
		-- Only the primary's own actions form the loop; a peer's steps belong to
		-- the peer, and every loop actor runs the primary's loop.
		local owner = qascenario.playerId(step.player)
		if owner ~= nil and owner ~= primary then
			continue
		end
		if not text(step.action) then
			continue
		end
		table.insert(steps, {
			kind = "action",
			op = op,
			action = step.action,
			args = if type(step.args) == "table" then step.args else {},
			requestId = if type(step.requestId) == "string" then step.requestId else nil,
		})
	end
	return { primary = primary, roster = roster, steps = steps }
end

--- The synthetic peers a run adds: `count - 1` ids that never collide with a
--- declared player. The declared peers beyond the primary stay in the roster
--- (they are the other half of a two-actor genre) but do not run the loop.
function M.synthetics(declared: { string }, count: number): { string }
	local out: { string } = {}
	local index = 1
	while #out < count - 1 do
		local candidate = "load-" .. tostring(index)
		index += 1
		if not table.find(declared, candidate) then
			table.insert(out, candidate)
		end
	end
	return out
end

--- The actors that run the loop: the primary first, then the synthetic peers.
--- The primary acts first at every step, which is what makes the reference
--- comparison meaningful for a genre with shared state.
function M.runners(declared: { string }, count: number): { string }
	local out: { string } = { declared[1] }
	for _, id in M.synthetics(declared, count) do
		table.insert(out, id)
	end
	return out
end

--- Every actor the session holds: the declared roster plus the synthetic peers.
function M.roster(declared: { string }, count: number): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, id in declared do
		if not seen[id] then
			seen[id] = true
			table.insert(out, id)
		end
	end
	for _, id in M.synthetics(declared, count) do
		seen[id] = true
		table.insert(out, id)
	end
	return out
end

--- Every scalar leaf of a state table, keyed by dotted path. Arrays use [i] so
--- a reordered list is a different path rather than a silent match.
local function leaves(value: any, prefix: string, out: { [string]: any }, depth: number)
	if depth > 32 then
		return
	end
	if type(value) ~= "table" then
		out[prefix] = value
		return
	end
	for key, item in value do
		local path = if type(key) == "number"
			then string.format("%s[%d]", prefix, key)
			else prefix .. "." .. tostring(key)
		leaves(item, path, out, depth + 1)
	end
end

local function snapshotLeaves(state: any): { [string]: any }
	local out: { [string]: any } = {}
	leaves(state, "", out, 0)
	return out
end

local function newSession(target: any, backend: any, clock: any, storeName: string, durable: any)
	return Session.new(
		{
			packConfig = target.packConfig,
			contracts = target.contracts,
			controls = target.controls or {},
			storeName = storeName,
			hooks = target.hooks,
		},
		backend,
		{
			sessionId = storeName,
			lockTimeout = 120,
			retries = 0,
			now = clock.now,
		},
		{
			now = clock.now,
			encode = function(value)
				return serde.encode("json", value)
			end,
			roll = function()
				return 0
			end,
			emit = function() end,
		},
		durable
	)
end

--- Applies one script step for one actor at the current clock instant. Returns
--- (ok, reason): `ok` is the Session's own verdict, never a re-derivation.
local function act(session: any, actor: string, step: Step): (boolean, string?)
	local op = step.op
	if op == "dispatch" or op == "server_dispatch" then
		local result = if op == "dispatch"
			then session.dispatch(actor, step.action, step.args or {})
			else session.dispatchServer(actor, step.action, step.args or {})
		return result.ok == true, result.reason
	end
	local epoch = session.commandEpoch(actor, step.action)
	local result = session.command(actor, {
		requestId = step.requestId or step.action,
		sessionEpoch = epoch,
		action = step.action,
		args = step.args or {},
	})
	return result.ok == true, result.reason
end

--- Runs the script for `runners` over the full roster. `runners` of one is the
--- reference; eight is the load run. Returns the per-actor accepted vector, the
--- final state of every actor, its saved envelope, and the member counts at the
--- two points where they matter.
local function play(options: any, runners: { string }, roster: { string }, script: Script)
	local target = options.target
	local backend = MemoryBackend.new()
	local wall = 0
	local clock = Clock.new(function()
		return wall
	end)
	local session = newSession(target, backend, clock, options.storeName, options.durable)
	local failures: { string } = {}
	for _, actor in roster do
		local joined = session.join(actor)
		if not joined.ok then
			table.insert(failures, "join refused for " .. actor .. ": " .. tostring(joined.reason))
		end
	end
	local membersAfterJoin = #session.members()
	local vectors: { [string]: { boolean } } = {}
	for _, actor in runners do
		vectors[actor] = {}
	end
	local accepted = 0
	for _, step in script.steps do
		if step.kind == "advance" then
			wall = math.max(wall, step.seconds :: number)
			session.advance(wall)
			continue
		end
		for _, actor in runners do
			local ok, reason = act(session, actor, step)
			table.insert(vectors[actor], ok)
			if ok then
				accepted += 1
			elseif reason == nil then
				table.insert(
					failures,
					"action " .. tostring(step.action) .. " for " .. actor .. " refused without a reason"
				)
			end
		end
	end
	local before: { [string]: { [string]: any } } = {}
	local envelopes: { [string]: any } = {}
	for _, actor in runners do
		before[actor] = snapshotLeaves(session.snapshot(actor))
		envelopes[actor] = session.envelope(actor)
	end
	local persisted: { [string]: { [string]: any } } = {}
	-- Every roster member leaves, so the session is empty before the rejoin. The
	-- standing peers save and release through the same path the loop actors do.
	for _, actor in roster do
		local saved = session.save(actor)
		if not saved.ok then
			table.insert(failures, "save refused for " .. actor .. ": " .. tostring(saved.reason))
		end
		local closed = session.close(actor)
		if not closed.ok then
			table.insert(failures, "leave refused for " .. actor .. ": " .. tostring(closed.reason))
		end
	end
	for _, actor in runners do
		local joined = session.join(actor)
		if not joined.ok then
			table.insert(failures, "rejoin refused for " .. actor .. ": " .. tostring(joined.reason))
		end
		persisted[actor] = snapshotLeaves(session.snapshot(actor))
	end
	local membersAfterRejoin = #session.members()
	-- A durable command genre must answer a replayed requestId with the same
	-- outcome and no second grant; the probe is the last command the script issued.
	local lastCommand: Step? = nil
	for _, step in script.steps do
		if step.kind == "action" and (step.op == "command" or step.op == "command_server") then
			lastCommand = step
		end
	end
	local replay: { [string]: any } = {}
	if lastCommand ~= nil then
		for _, actor in runners do
			local epoch = session.commandEpoch(actor, lastCommand.action)
			local result = session.command(actor, {
				requestId = lastCommand.requestId or lastCommand.action,
				sessionEpoch = epoch,
				action = lastCommand.action,
				args = lastCommand.args or {},
			})
			replay[actor] = {
				-- A refusal is a legitimate answer to a replayed command (the job is
				-- already complete); what matters is that the replay changes nothing.
				ok = result.ok == true,
				after = snapshotLeaves(session.snapshot(actor)),
			}
		end
	end
	for _, actor in runners do
		local closed = session.close(actor)
		if not closed.ok then
			table.insert(failures, "final leave refused for " .. actor .. ": " .. tostring(closed.reason))
		end
	end
	return {
		accepted = accepted,
		vectors = vectors,
		before = before,
		persisted = persisted,
		envelopes = envelopes,
		replay = replay,
		membersAfterJoin = membersAfterJoin,
		membersAfterRejoin = membersAfterRejoin,
		failures = failures,
	}
end

local function sameVector(a: { boolean }, b: { boolean }): boolean
	if #a ~= #b then
		return false
	end
	for index, value in a do
		if value ~= b[index] then
			return false
		end
	end
	return true
end

local function isSafeNonNegative(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value <= 2 ^ 53 - 1
end

--- Runs the proof. `options.scenario` is the pack's own derived native scenario
--- document; `options.target` is the pack target `qa.loadTarget` builds.
function M.run(options: any): Result
	local script = M.script(options.scenario)
	local count = options.actors or M.DEFAULT_ACTORS
	local runners = M.runners(script.roster, count)
	local roster = M.roster(script.roster, count)
	local durable = if type(options.scenario.data) == "table" then options.scenario.data.durable else nil
	local reference = play({
		target = options.target,
		storeName = (options.storeName or "load") .. "-ref",
		durable = durable,
	}, { script.primary }, roster, script)
	local load = play({
		target = options.target,
		storeName = (options.storeName or "load") .. "-load",
		durable = durable,
	}, runners, roster, script)

	local failures: { string } = {}
	for _, failure in reference.failures do
		table.insert(failures, "reference: " .. failure)
	end
	for _, failure in load.failures do
		table.insert(failures, "load: " .. failure)
	end

	local referenceVector = reference.vectors[script.primary]
	local referenceLeaves = reference.before[script.primary]
	local referencePersisted = reference.persisted[script.primary]
	-- The leaves the reference itself preserved across save, leave and rejoin are
	-- the durable ones; a volatile round field the reference never carried is not
	-- asserted for anyone.
	local durableLeaves: { [string]: boolean } = {}
	for path, value in referenceLeaves do
		if referencePersisted[path] == value then
			durableLeaves[path] = true
		end
	end

	local membersOk = load.membersAfterJoin == #roster and load.membersAfterRejoin == #runners
	if not membersOk then
		table.insert(
			failures,
			string.format(
				"member count mismatch: joined %d/%d, rejoined %d/%d",
				load.membersAfterJoin,
				#roster,
				load.membersAfterRejoin,
				#runners
			)
		)
	end
	local primaryRateOk = sameVector(load.vectors[script.primary], referenceVector)
	if not primaryRateOk then
		table.insert(failures, "the primary actor's accepted/refused pattern changed under load")
	end
	local primaryAccepted = 0
	for _, value in load.vectors[script.primary] do
		if value then
			primaryAccepted += 1
		end
	end
	local duplicateOk = primaryAccepted == reference.accepted
	if not duplicateOk then
		table.insert(failures, "the primary actor accepted more actions under load than in the reference")
	end
	local conservationOk = true
	local persistenceOk = true
	local contracts = if type(options.target) == "table" then options.target.contracts else nil
	for _, actor in runners do
		local own = load.before[actor]
		for path, value in own do
			if type(value) == "number" and not isSafeNonNegative(value) then
				conservationOk = false
				table.insert(failures, "load: " .. path .. " is not a finite non-negative safe number for " .. actor)
			end
		end
		-- The domain's own rule, applied to every actor's envelope.
		if type(contracts) == "table" then
			local envelope = load.envelopes[actor]
			for _, contract in contracts do
				local entry = if type(envelope) == "table" and type(envelope.genres) == "table"
					then envelope.genres[contract.id]
					else nil
				if type(entry) == "table" and type(contract.validateSave) == "function" then
					local errors = contract.validateSave(entry.data)
					if type(errors) == "table" and #errors > 0 then
						conservationOk = false
						table.insert(
							failures,
							"load: "
								.. actor
								.. " saved an invalid "
								.. contract.id
								.. " state: "
								.. tostring(errors[1])
						)
					end
				end
			end
		end
		local persisted = load.persisted[actor]
		for path in durableLeaves do
			-- Only where the actor reached the reference's own value: an arena actor
			-- whose round is live is in a state the reference never demonstrated, and
			-- the genre's persistence rule for that state is its own business.
			if own[path] ~= nil and own[path] == referenceLeaves[path] and persisted[path] ~= own[path] then
				persistenceOk = false
				table.insert(failures, "load: " .. actor .. " changed durable " .. path .. " across rejoin")
			end
		end
		local replayed = load.replay[actor]
		if replayed ~= nil then
			for path, value in replayed.after do
				if persisted[path] ~= value then
					duplicateOk = false
					table.insert(failures, "load: replaying a durable command changed " .. path .. " for " .. actor)
				end
			end
		end
	end
	local noErrors = #failures == 0
	local invariants: { [string]: Invariant } = {
		join = {
			ok = membersOk,
			detail = if membersOk then nil else "member count mismatch",
		},
		["no-errors"] = {
			ok = noErrors,
			detail = if noErrors then nil else failures[1],
		},
		["no-duplicate-grants"] = {
			ok = duplicateOk,
			detail = if duplicateOk
				then nil
				else "a concurrent run accepted more than the reference or a replayed command granted twice",
		},
		["rate-limits"] = {
			ok = primaryRateOk,
			detail = if primaryRateOk then nil else "the primary's verdict vector changed under load",
		},
		conservation = {
			ok = conservationOk,
			detail = if conservationOk then nil else "a numeric leaf or a saved envelope violated the domain rule",
		},
		persistence = {
			ok = persistenceOk,
			detail = if persistenceOk then nil else "a durable leaf changed across save, leave and rejoin",
		},
	}
	local ok = true
	for _, invariant in invariants do
		if not invariant.ok then
			ok = false
		end
	end
	local replayAccepted = 0
	for _, actor in runners do
		local replayed = load.replay[actor]
		if replayed ~= nil and replayed.ok then
			replayAccepted += 1
		end
	end
	return {
		ok = ok,
		actors = #runners,
		actions = #script.steps,
		invariants = invariants,
		failures = failures,
		reference = { accepted = reference.accepted, refused = #referenceVector - reference.accepted },
		replay = { accepted = replayAccepted, refused = #runners - replayAccepted },
	}
end

--- The scenario a load proof replays for a pack: the pack's own derived native
--- scenario when it ships one (every non-legacy generated pack does), else the
--- scenario the genre's declared golden path implies. A genre with no golden
--- path yields no scenario, and the caller records an honest absence rather
--- than inventing a loop.
function M.scenarioFor(packDir: string, pack: string, spec: any, genre: string, mode: string?): (any?, string?)
	local dir = packDir .. "/qa-scenarios"
	if fs.isDir(dir) then
		local names = fs.readDir(dir)
		table.sort(names)
		for _, name in names do
			if string.match(name, "%.yml$") then
				local decodedOk, decoded = pcall(function()
					return serde.decode("yaml", fs.readFile(dir .. "/" .. name))
				end)
				if decodedOk and type(decoded) == "table" and decoded.kind == "native" and decoded.pack == pack then
					return decoded, nil
				end
			end
		end
	end
	local derived = qagen.derive(spec, { name = qagen.name(spec), genre = genre, pack = pack }, mode)
	if type(derived) == "table" and type(derived.steps) == "table" and #derived.steps > 0 then
		return derived, nil
	end
	return nil, "the genre declares no golden path to replay"
end

return M
