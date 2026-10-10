--!strict
-- Native production factory composition with the actual Session personal owner.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Session = require("../../../../core/infra/genre/Session")
local Contract = require("../../../../genres/survival-coop/module/Contract")
local Services = require("../../../../genres/survival-coop/module/SurvivalServices")
local Settlement = require("../../../../core/domain/settlement/Settlement")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Catalog = require("../../../../core/domain/inventory/ItemCatalog")
local Memory = require("../../../../core/infra/data/MemoryBackend")
local config =
	serde.decode("yaml", fs.readFile("cli/forge/fixtures/inventory-conservation/fixture-survival/econ.yml")).genre_contract
local function encode(value: any): string
	return serde.encode("json", value)
end
local now = 0
local function clock(): number
	return now
end
local backend = Memory.new()
local catalog = Catalog.new({ { id = "wood", stackMax = 100, weightMilli = 1000 } })
local factory = assert(Services.new(
	{
		tribes = {
			{
				key = "tribe",
				catalog = catalog,
				definitions = { hut = { id = "hut", footprintX = 1, footprintZ = 1, cost = {} } },
				now = clock,
				verifyTransfer = function(actor, proof)
					return actor == "1" and proof == "trusted-proof"
				end,
				initial = {
					settlement = Settlement.new(
						{ tribeId = "tribe", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 },
						"1"
					),
					warehouse = Inventory.new(
						"warehouse",
						{ slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 }
					),
				},
			},
		},
		maxServerPlayers = 8,
		maxPlots = 4,
		maxReceipts = 4096,
		tribeFor = function(actor)
			return if actor == "1" or actor == "2" then "tribe" else nil
		end,
		authorize = function()
			return { ok = true }
		end,
		consent = function(actor, target)
			return actor == "1" and target == "2"
		end,
		proof = function()
			return "trusted-proof"
		end,
	},
	backend,
	{
		sessionId = "tribe-owner",
		leaseSeconds = 120,
		now = clock,
		budget = { encode = encode },
	}
))
local action = "survival-coop:transfer-deposit"
local policy = {
	actions = {
		action,
		"survival-coop:settlement-kick",
		"survival-coop:settlement-reserve",
		"survival-coop:settlement-place",
	},
	serverActions = { "survival-coop:settlement-invite" },
	personal = { namespace = "personal", inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" } },
}
local session = Session.new(
	{
		packConfig = config,
		contracts = { Contract },
		controls = {},
		storeName = "SurvivalServicesSeam",
		durable = policy,
	},
	backend,
	{ sessionId = "personal-owner", lockTimeout = 120, retries = 0, now = clock },
	{
		now = clock,
		roll = function()
			return 0
		end,
		emit = function() end,
		encode = encode,
		survivalTransfer = factory.services.survivalTransfer,
		survivalSettlement = factory.services.survivalSettlement,
	},
	policy
)
factory.bind(session)
assert(session.join("1").ok, "join personal owner")
assert(factory.close().reason == "PLAYERS_ACTIVE", "owners stay open while players active")
assert(session.commandEpoch("1", action) == 0, "initial epoch")
local args: { any } = { "wood", 3 }
local request = { requestId = "deposit", sessionEpoch = 0, action = action, args = args }
local first = session.command("1", request)
for _ = 1, 8 do
	if first.ok then
		break
	end
	assert(session.recoverTransfers("1", 1).ok, "bounded recovery")
	first = session.command("1", request)
end
assert(first.ok, "initial actual Session transfer: " .. tostring(first.reason))
local savedResponse = encode(first)
assert(session.command("1", request).ok, "same-epoch replay")
local function command(id: string, verb: string, values: { any })
	local name = "survival-coop:settlement-" .. verb
	local envelope = {
		requestId = id,
		sessionEpoch = assert(session.commandEpoch("1", name), "settlement epoch"),
		action = name,
		args = values,
	}
	if verb == "invite" then
		return session.commandServer("1", envelope)
	end
	return session.command("1", envelope)
end
assert(command("no-consent", "invite", { "outsider", 0, 0 }).reason == "CONSENT_REQUIRED", "consent required")
assert(command("invite", "invite", { "2", 0, 0 }).ok, "accepted consent joins tribe")
assert(session.join("2").ok, "member joins actual Session")
assert(session.snapshot("2").survivalSettlement.settlement.roles["2"] == "member", "server link resolves member")
assert(command("kick", "kick", { "2", 1, 1 }).ok, "owner revokes member")
assert(factory.services.survivalSettlement.link("2") == nil, "revoked link cannot expose warehouse")
assert(session.commandEpoch("2", action) == nil, "revocation denies new transfer epoch")
assert(session.close("2").ok, "close revoked personal owner")
local state = assert(factory.services.survivalSettlement.snapshot("1"))
local built = command(
	"reserve",
	"reserve",
	{ "hut", 4, 4, 0, state.settlement.version, state.warehouse.version, state.settlement.membershipRevision }
)
assert(built.ok and built.data, "reserve shared structure")
state = assert(factory.services.survivalSettlement.snapshot("1"))
assert(
	command("place", "place", { built.data.reservationId, state.settlement.version, state.warehouse.version }).ok,
	"place shared structure"
)
local structureCount = 0
for _ in factory.services.survivalSettlement.snapshot("1").settlement.structures do
	structureCount += 1
end
assert(structureCount == 1, "one durable structure")
-- Keep both actual owners leased while advancing deterministically past expiry.
for tick = 1, 864 do
	now = tick * 100
	assert(session.save("1").ok, "renew personal lease")
	assert(factory.services.survivalSettlement.snapshot("1"))
end
assert(session.commandEpoch("1", action) == 1, "rotate tribe epoch")
local replay = session.command("1", request)
assert(replay.ok and encode(replay) == savedResponse, "exact accepted response survives epoch rollover")
local changed: { any } = { "wood", 4 }
assert(
	session.command("1", { requestId = "deposit", sessionEpoch = 0, action = action, args = changed }).reason
		== "TRANSFER_CONFLICT",
	"changed payload conflicts after rollover"
)
assert(session.recoverTransfers("1", 1).ok, "native recovery still uses retained internal request")
assert(session.snapshot("1")["survival-coop"].inventory.bag.items.wood.quantity == 7, "no duplicate debit")
assert(
	assert(factory.services.survivalSettlement.snapshot("1")).warehouse.items["transfer:1:0:deposit:output"].quantity
		== 3,
	"no duplicate credit"
)
assert(session.close("1").ok, "close personal owner")
assert(session.join("1").ok, "rejoin actual personal owner")
assert(next(session.snapshot("1").survivalSettlement.settlement.structures) ~= nil, "structure survives rejoin")
assert(
	session.snapshot("1")["survival-coop"].inventory.bag.items.wood.quantity == 7,
	"sole personal inventory survives rejoin"
)
assert(session.command("1", request).reason == "REQUEST_EXPIRED", "join recovery retires expired terminal request")
assert(session.close("1").ok, "close rejoined personal owner")
assert(factory.close().ok, "close tribe owner")
print("PASS actual SurvivalServices factory Session ownership rejoin and rollover replay")
local specs: { [string]: () -> () } = require("../../../../genres/survival-coop/module/SurvivalServices.spec")
for name, test in specs do
	test()
	print("PASS " .. name)
end
