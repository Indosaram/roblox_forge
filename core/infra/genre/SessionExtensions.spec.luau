--!strict
local Session = require("./Session")
local Options = require("./Options")
local Memory = require("../data/MemoryBackend")
local Survival = require("../../../genres/survival-coop/module/Contract")
local Fixture = require("../../../genres/survival-coop/module/Adapter.fixture")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Ledger = require("../../domain/command/Ledger")

local ACTION = "survival-coop:defend-active"

local function fixture(extensions: { any }?, backend: any?, owner: string?, personal: boolean?)
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
	local policy: any = { actions = { ACTION, "survival-coop:buy-defense" } }
	if personal then
		policy.personal =
			{ namespace = "personal", inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" } }
	end
	local options = {
		packConfig = { api = 1, order = { Survival.id }, configs = { [Survival.id] = Fixture.config } },
		contracts = { Survival },
		controls = {},
		storeName = "ExtensionSpec",
		durable = policy,
		services = { survivalExtensions = extensions or { extension } },
	}
	if personal then
		options.packConfig = luau.load(fs.readFile("games/robango-island/src/shared/GenreConfig.luau"))()
	end
	local ports: { any } = extensions or {}
	for _, port in ports do
		if port.drain or port.releaseActor or port.resumeActor then
			Session.registerLifecycle(port)
		end
	end
	local session = Session.new(options :: any, backend or Memory.new(), {
		sessionId = owner or "host",
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
		encode = function(value)
			return serde.encode("json", value)
		end,
		survivalExtensions = (extensions or { extension }) :: { any },
	}, policy)
	return session, calls, options
end

return {
	["receipt resolver only returns committed outcomes with exact actor command binding"] = function()
		local session = fixture({}, nil, "receipts", true)
		assert(session.join("1").ok, "join")
		local action = ACTION
		local epoch = assert(session.commandEpoch("1"), "personal epoch")
		assert(session.committedReceipt("1", epoch, "r1", action, {}, "client") == nil, "unissued receipt refused")
		local port = assert(session.personalTransfer("1"), "personal owner")
		local token = assert(
			port.personal:update(port.profile(), function(view)
				local ledger = view.envelope.commands
				ledger.stateVersion += 1
				ledger.epochs[tostring(epoch)].outcomes.r1 = {
					binding = Ledger.canonical({ action = action, args = {} }),
					result = { ok = true, stateVersion = ledger.stateVersion },
					createdAt = 0,
					expiresAt = 86400,
				}
				return view
			end),
			"receipt durably committed"
		)
		port.install(token)
		local receipt = session.committedReceipt("1", epoch, "r1", action, {}, "client")
		assert(receipt and receipt.ok, "committed successful outcome resolves")
		receipt.ok = false
		local reread = session.committedReceipt("1", epoch, "r1", action, {}, "client")
		assert(reread and reread.ok, "returned receipt is detached")
		assert(session.committedReceipt("2", epoch, "r1", action, {}, "client") == nil, "foreign actor refused")
		assert(session.committedReceipt("1", epoch, "r1", action, { 1 }, "client") == nil, "changed arguments refused")
		assert(session.committedReceipt("1", epoch, "r1", action, {}, "server") == nil, "changed origin refused")
		assert(session.close("1").ok, "close")
	end,
	["handoff drains saves and releases every actor before travel and blocks old callbacks"] = function()
		local order = {}
		local backend = Memory.new()
		local blocked = false
		local failSave = false
		local durableBackend = {
			update = function(key, transform)
				if failSave then
					return false, "FLUSH_FAILED"
				end
				table.insert(order, "commit:" .. key)
				return backend.update(key, transform)
			end,
		}
		local extensions = {}
		local session: any
		for _, id in { "taming", "market", "contracts", "monetization", "camp" } do
			table.insert(extensions, {
				id = id,
				handles = function()
					return false
				end,
				command = function()
					return { ok = true, data = { extension = id } }
				end,
				drain = function()
					blocked = session.dispatch("1", ACTION, {}).reason == "ACTOR_LEAVING"
					table.insert(order, "drain:" .. id)
					return { ok = true }
				end,
				releaseActor = function()
					table.insert(order, "release:" .. id)
					return { ok = true }
				end,
				resumeActor = function()
					table.insert(order, "resume:" .. id)
					return { ok = true }
				end,
				recover = function()
					table.insert(order, "recover:" .. id)
					return { ok = true }
				end,
			})
		end
		session = fixture(extensions, durableBackend, "origin", true)
		assert(session.join("1").ok, "join origin")
		table.clear(order)
		failSave = true
		assert(not session.prepareHandoff("1").ok, "flush failure prohibits travel")
		assert(blocked and #order == 5, "commands blocked before all drains; no lease release on failed flush")
		failSave = false
		assert(session.resumeHandoff("1").ok, "failed departure resumes origin")
		table.clear(order)
		assert(session.prepareHandoff("1").ok, "durable handoff")
		assert(order[1] == "drain:taming" and order[5] == "drain:camp", "all extensions drained first")
		assert(
			string.sub(order[6], 1, 7) == "commit:" and order[7] == "release:taming",
			"save committed before leases release"
		)
		assert(order[11] == "release:camp", "every actor lease released")
		local before = #order
		assert(session.prepareHandoff("1").ok and #order == before, "duplicate departure performs no writes")
		session.advance(0)
		assert(session.recoverTransfers("1", 8).ok and #order == before, "old server sweep cannot reacquire")
		assert(session.completeHandoff("1").ok, "completion")
		assert(session.completeHandoff("1").ok, "duplicate completion is idempotent")
		assert(
			session.resumeHandoff("1").reason == "ACTOR_LEFT",
			"late failed callback cannot reacquire completed departure"
		)
	end,
	["handoff destination failure reacquires origin but destination claim forbids rollback"] = function()
		local backend = Memory.new()
		local origin = fixture({}, backend, "origin", true)
		assert(origin.join("1").ok, "origin joins")
		assert(origin.prepareHandoff("1").ok, "departure")
		assert(origin.resumeHandoff("1").ok, "unclaimed destination failure resumes")
		assert(origin.commandEpoch("1") ~= nil, "commands reenabled only after reacquisition")
		assert(origin.prepareHandoff("1").ok, "second departure")
		local destination = fixture({}, backend, "destination", true)
		assert(destination.join("1").ok, "destination claims released actor")
		assert(not origin.resumeHandoff("1").ok, "origin cannot reacquire claimed actor")
		assert(origin.commandEpoch("1") == nil, "origin remains fenced")
		assert(origin.completeHandoff("1").ok, "origin discards only local state")
		assert(destination.save("1").ok and destination.close("1").ok, "destination remains authoritative")
	end,
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
