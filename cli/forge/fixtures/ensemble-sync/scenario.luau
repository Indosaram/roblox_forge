--!strict
-- Real Session commands over the production extension; only repository storage/range/clock are ports.
local Extension = require("../../../../genres/survival-coop/module/EnsembleExtension")
local Library = require("../../../../core/domain/music/Library")
local Score = require("../../../../core/domain/music/Score")
local Rules = require("../../../../core/domain/music/TestCatalog")
local Session = require("../../../../core/infra/genre/Session")
local Schema = require("../../../../core/infra/net/Schema")
local serde = require("@lune/serde")
local M = {}
M.operations = {
	ensemble_run = function(ctx: any, step: any): string?
		local failure = ctx.fixture.run()
		ctx.results[ctx.playerOf(step)] = { ok = failure == nil }
		return failure
	end,
}
function M.new(ctx: any): any
	local states: any = {}
	local repository = Library.new({
		read = function(actor)
			return Score.copy(states[actor])
		end,
		write = function(actor, version, nextState)
			if version ~= (if states[actor] then states[actor].version else 0) then
				return false
			end
			states[actor] = Score.copy(nextState)
			return true
		end,
	})
	local extension = Extension.new({
		repository = repository,
		rules = Rules,
		inRange = function()
			return true
		end,
		decode = function(text)
			return serde.decode("json", text)
		end,
		now = function()
			return ctx.now()
		end,
	})
	local actions: { any } = {}
	local ids = {}
	local text = Schema.string()
	local part = Schema.number({ min = 1, max = 6, integer = true })
	local definitions: any = {
		["score-import"] = { text, Schema.optional(text) },
		["score-share"] = { text, part, text },
		["ensemble-join"] = { text, part, part },
		["ensemble-ready"] = { Schema.boolean() },
		["ensemble-start"] = {},
		["ensemble-leave"] = {},
	}
	for id, args in definitions do
		table.insert(ids, "survival-coop:" .. id)
		table.insert(
			actions,
			{ id = id, args = args, origin = "client", rate = { capacity = 100, refillPerSecond = 100 } }
		)
	end
	local contract: any = {
		api = 1,
		id = "survival-coop",
		configVersion = 1,
		saveVersion = 1,
		actions = actions,
		events = {},
		hooks = {},
		validateConfig = function()
			return {}
		end,
		validateSave = function()
			return {}
		end,
		create = function()
			return {
				join = function()
					return { ok = true }
				end,
				leave = function() end,
				dispatch = function()
					return { ok = false }
				end,
				advance = function() end,
				snapshot = function()
					return {}
				end,
				save = function()
					return {}
				end,
			}
		end,
	}
	local policy = { actions = ids }
	local session = Session.new(
		{
			packConfig = { api = 1, order = { "survival-coop" }, configs = { ["survival-coop"] = {} } },
			contracts = { contract },
			controls = {},
			storeName = "EnsembleQA",
			durable = policy,
		} :: any,
		ctx.backend,
		{ sessionId = "ensemble-native", lockTimeout = 120, retries = 0, now = ctx.now },
		{
			now = ctx.now,
			roll = function()
				return 0
			end,
			emit = function() end,
			encode = function(value)
				return serde.encode("json", value)
			end,
			survivalExtensions = { extension },
		},
		policy
	)
	local request = 0
	local function command(actor: string, id: string, args: { any }): any
		request += 1
		return session.command(actor, {
			action = "survival-coop:" .. id,
			args = args,
			requestId = tostring(request),
			sessionEpoch = session.commandEpoch(actor),
		})
	end
	local fixture: any = {}
	function fixture.run(): string?
		for i = 1, 7 do
			assert(session.join(tostring(i)).ok, "scenario.luau: invariant failed")
		end
		local score: any = { version = 1, tempo = 120, parts = {} }
		for _, instrument in { "piano", "guitar", "bass", "violin", "flute", "drums" } do
			table.insert(score.parts, {
				instrumentId = instrument,
				notes = { { startTick = 0, durationTicks = 480, pitch = 60, velocity = 100 } },
			})
		end
		-- Catalog fixture setup uses the production repository. Session's shared transport
		-- currently caps every string at 256 bytes; the integration report calls this out.
		local small = { version = 1, tempo = 120, parts = { { instrumentId = "clarinet", notes = {} } } }
		local imported = command("1", "score-import", { serde.encode("json", small), "" })
		assert(imported.ok, tostring(imported.reason))
		local result =
			repository.save("1", nil, assert(Score.validate(score, Rules), "scenario.luau: invariant failed"))
		assert(result.ok, tostring(result.reason))
		local id = result.data.scoreId
		for i = 1, 7 do
			if i > 1 then
				assert(command("1", "score-share", { id, 1, tostring(i) }).ok, "scenario.luau: invariant failed")
			end
			local joined = command(tostring(i), "ensemble-join", { id, 1, if i <= 6 then i else 1 })
			assert(joined.ok == (i <= 6), "scenario.luau: invariant failed")
			if i <= 6 then
				assert(command(tostring(i), "ensemble-ready", { true }).ok, "scenario.luau: invariant failed")
			end
		end
		local before = serde.encode("json", states)
		assert(not command("1", "score-import", { "{", "" }).ok, "scenario.luau: invariant failed")
		assert(
			not command("1", "score-import", { string.rep("x", Rules.maxBytes + 1), "" }).ok,
			"scenario.luau: invariant failed"
		)
		assert(serde.encode("json", states) == before, "scenario.luau: invariant failed")
		assert(command("1", "ensemble-start", {}).ok, "scenario.luau: invariant failed")
		local room = extension.snapshot("1").room
		assert(room.startAt == ctx.now() + Rules.countdownSeconds, "scenario.luau: invariant failed")
		assert(#room.events == 6 and room.members["7"] == nil, "scenario.luau: invariant failed")
		for _, event in room.events do
			assert(math.abs(event.at - room.startAt) <= 0.1, "scenario.luau: invariant failed")
		end
		return nil
	end
	function fixture.snapshot(): any
		return extension.snapshot("1")
	end
	return fixture
end
return M
