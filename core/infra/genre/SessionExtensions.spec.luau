--!strict
local Session = require("./Session")
local Options = require("./Options")
local Memory = require("../data/MemoryBackend")
local Survival = require("../../../genres/survival-coop/module/Contract")
local Fixture = require("../../../genres/survival-coop/module/Adapter.fixture")

local ACTION = "survival-coop:defend-active"

local function fixture(extensions: { any }?)
	local calls: { any } = {}
	local extension = {
		id = "fixture",
		handles = function(action: string): boolean
			return action == ACTION
		end,
		command = function(actor, action, _args, context, origin, admit)
			local admitted = admit()
			table.insert(calls, { actor = actor, action = action, context = context, origin = origin })
			if not admitted.ok then
				return admitted
			end
			return { ok = true, stateVersion = #calls, data = { routed = action } }
		end,
		snapshot = function(actor: string)
			return { actor = actor, calls = #calls }
		end,
		epoch = function(_actor: string, _action: string)
			return 7
		end,
	}
	local policy = { actions = { ACTION, "survival-coop:buy-defense" } }
	local options = {
		packConfig = { api = 1, order = { Survival.id }, configs = { [Survival.id] = Fixture.config } },
		contracts = { Survival },
		controls = {},
		storeName = "ExtensionSpec",
		durable = policy,
		services = { survivalExtensions = extensions or { extension } },
	}
	local session = Session.new(options :: any, Memory.new(), {
		sessionId = "host",
		lockTimeout = 120,
		retries = 0,
		now = function()
			return 0
		end,
	}, {
		now = function()
			return 0
		end,
		roll = function()
			return 0
		end,
		emit = function() end,
		survivalExtensions = (extensions or { extension }) :: { any },
	}, policy)
	return session, calls, options
end

return {
	["session routes a durable action to the registered extension"] = function()
		local session, calls = fixture()
		assert(session.join("1").ok, "join")
		assert(session.commandEpoch("1", ACTION) == 7, "extension epoch consulted")
		local result = session.command("1", { requestId = "r1", sessionEpoch = 7, action = ACTION, args = {} })
		assert(result.ok and result.data and result.data.routed == ACTION, tostring(result.reason))
		assert(#calls == 1 and calls[1].origin == "client" and calls[1].context.requestId == "r1", "routed once")
		assert(session.close("1").ok, "close")
	end,
	["unknown or undeclared actions are still rejected"] = function()
		local session, calls = fixture()
		assert(session.join("1").ok, "join")
		local unknown =
			session.command("1", { requestId = "u", sessionEpoch = 0, action = "survival-coop:nope", args = {} })
		assert(not unknown.ok, "unknown action rejected")
		local undeclared =
			session.command("1", { requestId = "d", sessionEpoch = 0, action = "survival-coop:attack", args = { "x" } })
		assert(undeclared.reason == "durable action disallowed", tostring(undeclared.reason))
		assert(#calls == 0, "extension never invoked for foreign actions")
		assert(session.commandEpoch("1", "survival-coop:buy-defense") == 0, "ledger epoch fallback")
		assert(session.close("1").ok, "close")
	end,
	["extension snapshot merges under survivalExtensions by id"] = function()
		local session = fixture()
		assert(session.join("1").ok, "join")
		local snapshot = session.snapshot("1")
		assert(snapshot.survivalExtensions and snapshot.survivalExtensions.fixture.actor == "1", "merged by id")
		assert(snapshot[Survival.id] ~= nil, "genre snapshot retained")
		assert(session.close("1").ok, "close")
	end,
	["options reject malformed extensions"] = function()
		local _, _, options = fixture()
		Options.validate(options :: any)
		local function rejects(list: any, label: string)
			local copy = table.clone(options)
			copy.services = { survivalExtensions = list }
			assert(not pcall(Options.validate, copy :: any), label)
		end
		local handles = function()
			return false
		end
		rejects({ { id = "x", handles = handles } }, "missing command")
		rejects({ { id = "Bad Id", handles = handles, command = handles } }, "invalid id")
		rejects({ { id = "x", handles = handles, command = handles, extra = handles } }, "unknown field")
		rejects({ { id = "x", handles = handles, command = handles, snapshot = 1 } }, "non-callback")
		rejects({
			{ id = "x", handles = handles, command = handles },
			{ id = "x", handles = handles, command = handles },
		}, "duplicate id")
		rejects({ [2] = { id = "x", handles = handles, command = handles } }, "sparse list")
	end,
}
