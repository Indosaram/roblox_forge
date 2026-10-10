--!strict
local Session = require("../../../core/infra/genre/Session")
local Survival = require("../../../genres/survival-coop/module/Contract")
local Fixture = require("../../../genres/survival-coop/module/Adapter.fixture")
local Bridge = require("../../../genres/survival-coop/module/SettlementBridge")
local Runtime = require("../../../genres/survival-coop/module/SettlementRuntime")
local Settlement = require("../../../core/domain/settlement/Settlement")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local FencedStore = require("../../../core/infra/data/FencedStore")
local Memory = require("../../../core/infra/data/MemoryBackend")
local serde = require("@lune/serde")
local backend = Memory.new()
local now = function()
	return 0
end
local runtime = assert(Runtime.new(
	{
		key = "tribe",
		now = now,
		catalog = Catalog.new({}),
		definitions = {},
		initial = {
			settlement = Settlement.new(
				{ tribeId = "tribe", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 },
				"owner"
			),
			warehouse = Inventory.new("warehouse", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 }),
		},
	},
	FencedStore.new(backend, {
		sessionId = "tribe-host",
		leaseSeconds = 120,
		now = now,
		budget = {
			encode = function(v)
				return serde.encode("json", v)
			end,
		},
	})
))
local bridge = Bridge.new({
	resolve = function(id)
		return if id == "owner" or id == "member" then runtime else nil
	end,
	authorize = function()
		return { ok = true }
	end,
})
local policy = { actions = {}, serverActions = { "survival-coop:settlement-invite" } }
local session = Session.new(
	{
		packConfig = { api = 1, order = { Survival.id }, configs = { [Survival.id] = Fixture.config } },
		contracts = { Survival },
		controls = {},
		storeName = "BridgeSpec",
		durable = policy,
	},
	backend,
	{ sessionId = "player-host", lockTimeout = 120, retries = 0, now = now },
	{
		now = now,
		roll = function()
			return 0
		end,
		emit = function() end,
		survivalSettlement = bridge,
	},
	policy
)
assert(session.join("owner").ok, "actual Session join")
assert(session.commandEpoch("owner", "survival-coop:settlement-invite") == 0, "route epoch")
local args: { any } = { "member", 0, 0 }
local request = { requestId = "invite", sessionEpoch = 0, action = "survival-coop:settlement-invite", args = args }
assert(
	session.command("owner", request).reason == "unknown/disallowed action",
	"client invite denied by production origin"
)
assert(
	session.dispatchServer("owner", request.action, args).reason == "DURABLE_COMMAND_REQUIRED",
	"trusted invite cannot bypass durable route"
)
assert(session.commandServer("owner", request).ok, "accepted-consent server bridge route")
assert(session.join("member").ok, "nonowner member joins real Session")
local deniedArgs: { any } = { "outsider", 1, 0 }
local denied = session.commandServer("member", {
	requestId = "nonowner-invite",
	sessionEpoch = 0,
	action = request.action,
	args = deniedArgs,
})
assert(not denied.ok, "Runtime refuses nonowner invite despite trusted bridge authorization")
assert(session.snapshot("owner").survivalSettlement.settlement.version == 1, "nonowner refusal preserves settlement")
local malformedArgs: { any } = { "outsider", "not-a-version", 0 }
local malformed = session.commandServer("owner", {
	requestId = "malformed-invite",
	sessionEpoch = 0,
	action = request.action,
	args = malformedArgs,
})
assert(
	not malformed.ok and malformed.reason == "arg 2: expected number",
	"production action schema refuses malformed tuple"
)
assert(session.snapshot("owner").survivalSettlement.settlement.version == 1, "schema refusal preserves settlement")
for _ = 1, 100 do
	assert(session.commandServer("owner", request).ok, "server replay before rate admission")
end
local envelope = session.envelope("owner")
assert(envelope.commands and envelope.commands.stateVersion == 0, "tribe command never enters personal journal")
assert(session.snapshot("owner").survivalSettlement.settlement.version == 1, "actual authoritative settlement snapshot")
assert(session.close("owner").ok, "release personal")
assert(session.close("member").ok, "release nonowner")
print("PASS actual Session settlement Bridge epoch, origin, 100 replay admission, sole-owner journal and snapshot")
