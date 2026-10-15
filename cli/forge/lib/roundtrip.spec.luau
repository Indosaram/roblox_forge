--!strict
-- Save/load round-trip identity for every registered genre.
--
-- For each genre the registry discovers (the shipped catalog and the fixture
-- catalog), the spec builds the genre's real pack config from its own
-- generator, drives the real Session over a shared MemoryBackend the way
-- loadproof's newSession does, joins the declared roster, replays the primary
-- actor's golden path (qagen.derive + loadproof.script), saves, releases, then
-- loads every actor into a FRESH session over the same backend and saves again.
-- The persisted envelope of every actor must be canonically identical across
-- the two saves: loading a save and saving it again must change nothing.
--
-- The clock is fixed: it does not advance between the first save, the release,
-- the reload and the second save, so a time-derived field cannot drift for a
-- reason that is not a defect.
--
-- Session-volatile fields excluded from the comparison: NONE inside the saved
-- envelope. The comparison reads the backend record's `data` (the envelope the
-- genre saved); the record's sibling `lock` ({ session, at }) is ProfileStore
-- lease metadata, not save data, and necessarily names the session that wrote
-- it, so it is outside the compared value by construction.

local serde = require("@lune/serde")
local Session = require("../../../core/infra/genre/Session")
local MemoryBackend = require("../../../core/infra/data/MemoryBackend")
local Clock = require("../../../core/infra/genre/Clock")
local Ledger = require("../../../core/domain/command/Ledger")
local registryLib = require("./genreregistry")
local loadproof = require("./loadproof")
local qagen = require("./qagen")

local ROOTS = { "genres", "cli/forge/fixtures/genres" }

local INPUT = {
	mode = "new",
	slug = "roundtrip",
	pascal = "Roundtrip",
	title = "Roundtrip",
	concept = "",
	seed = 7,
	teams = { "Red", "Blue" },
	debugName = "RoundtripDebug",
	guiName = "RoundtripGui",
}

local function newSession(package: any, backend: any, clock: any, sessionId: string, durable: any)
	local config = package.generator.generate(INPUT).config
	return Session.new(
		{
			packConfig = { api = 1, order = { package.id }, configs = { [package.id] = config } },
			contracts = { package.runtime },
			controls = {},
			storeName = "roundtrip-" .. package.id,
		},
		backend,
		{ sessionId = sessionId, lockTimeout = 120, retries = 0, now = clock.now },
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

-- The envelope the backend holds for an actor, read without changing it.
local function stored(backend: any, actor: string): any
	local _, record = backend.update("player-" .. actor, function(old)
		return old
	end)
	return if type(record) == "table" then record.data else nil
end

local function act(session: any, actor: string, step: any)
	if step.op == "dispatch" then
		session.dispatch(actor, step.action, step.args or {})
	elseif step.op == "server_dispatch" then
		session.dispatchServer(actor, step.action, step.args or {})
	else
		session.command(actor, {
			requestId = step.requestId or step.action,
			sessionEpoch = session.commandEpoch(actor, step.action),
			action = step.action,
			args = step.args or {},
		})
	end
end

-- Runs one genre and returns (first, second, roster, accepted) where first and
-- second map every actor to the canonical string of its persisted envelope.
local function roundtrip(package: any)
	local scenario = qagen.derive(package.spec, { name = "roundtrip", genre = package.id, pack = "roundtrip" })
	local script = loadproof.script(scenario)
	local durable = if type(scenario.data) == "table" then scenario.data.durable else nil
	local backend = MemoryBackend.new()
	local wall = 0
	local clock = Clock.new(function()
		return wall
	end)

	local first = newSession(package, backend, clock, "roundtrip-first", durable)
	for _, actor in script.roster do
		local joined = first.join(actor)
		assert(joined.ok, package.id .. ": join " .. actor .. ": " .. tostring(joined.reason))
	end
	local actions = 0
	for _, step in script.steps do
		if step.kind == "advance" then
			wall = math.max(wall, step.seconds :: number)
			first.advance(wall)
		else
			act(first, script.primary, step)
			actions += 1
		end
	end
	local firstSave: { [string]: string } = {}
	for _, actor in script.roster do
		local saved = first.save(actor)
		assert(saved.ok, package.id .. ": first save " .. actor .. ": " .. tostring(saved.reason))
		firstSave[actor] = Ledger.canonical(stored(backend, actor))
	end
	for _, actor in script.roster do
		local closed = first.close(actor)
		assert(closed.ok, package.id .. ": release " .. actor .. ": " .. tostring(closed.reason))
	end

	-- The fixed clock does not move: the reload and second save happen at the
	-- same instant the first save did.
	local second = newSession(package, backend, clock, "roundtrip-second", durable)
	local secondSave: { [string]: string } = {}
	for _, actor in script.roster do
		local joined = second.join(actor)
		assert(joined.ok, package.id .. ": reload " .. actor .. ": " .. tostring(joined.reason))
	end
	for _, actor in script.roster do
		local saved = second.save(actor)
		assert(saved.ok, package.id .. ": second save " .. actor .. ": " .. tostring(saved.reason))
		secondSave[actor] = Ledger.canonical(stored(backend, actor))
	end
	for _, actor in script.roster do
		second.close(actor)
	end
	return firstSave, secondSave, script.roster, actions
end

local function packages(): { any }
	local out: { any } = {}
	for _, root in ROOTS do
		local registry, errors = registryLib.discover(root)
		assert(registry ~= nil, root .. ": " .. table.concat(errors, "; "))
		for _, id in registry.order do
			table.insert(out, registry.packages[id])
		end
	end
	return out
end

local function firstDifference(a: string, b: string): string
	local index = 1
	while index <= #a and string.sub(a, index, index) == string.sub(b, index, index) do
		index += 1
	end
	local from = math.max(1, index - 60)
	return string.format("at %d: %q vs %q", index, string.sub(a, from, index + 60), string.sub(b, from, index + 60))
end

return {
	["save then load then save is an identity for every genre"] = function()
		local all = packages()
		assert(#all >= 7, "every shipped genre and the fixture genre are discovered: " .. #all)
		local failures: { string } = {}
		for _, package in all do
			local ok, first, second, roster, actions = pcall(roundtrip, package)
			if not ok then
				table.insert(failures, package.id .. ": " .. tostring(first))
				continue
			end
			-- A draft spec (the fixture catalog's counter) declares no golden path;
			-- its joined state is still round-tripped. A shipped genre must act.
			assert(
				actions > 0 or (type(package.spec) == "table" and package.spec.draft == true),
				package.id .. ": the golden path carried no action"
			)
			for _, actor in roster do
				if first[actor] ~= second[actor] then
					table.insert(
						failures,
						package.id .. " actor " .. actor .. " changed " .. firstDifference(first[actor], second[actor])
					)
				end
			end
		end
		assert(#failures == 0, table.concat(failures, "\n"))
	end,

	["the identity comparison detects a mutated leaf after reload"] = function()
		local registry = assert(registryLib.discover())
		local package = registry.packages["grow-harvest"]
		local backend = MemoryBackend.new()
		local clock = Clock.new(function()
			return 0
		end)
		local session = newSession(package, backend, clock, "roundtrip-mutation", nil)
		assert(session.join("1").ok, "join")
		assert(session.save("1").ok, "save")
		local saved = stored(backend, "1")
		local mutated = stored(backend, "1")
		local data = mutated.genres[package.id].data
		local leaf: string? = nil
		for key, value in data do
			if type(value) == "number" then
				leaf = key
				break
			end
		end
		assert(leaf ~= nil, "the envelope carries a numeric leaf to mutate")
		data[leaf :: string] += 1
		assert(Ledger.canonical(saved) == Ledger.canonical(stored(backend, "1")), "an unmutated read is identical")
		assert(Ledger.canonical(saved) ~= Ledger.canonical(mutated), "a mutated leaf is detected")
	end,
}
