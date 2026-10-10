--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Bootstrap = require("../../../../genres/survival-coop/module/SurvivalBootstrap")
local Session = require("../../../../core/infra/genre/Session")
local Contract = require("../../../../genres/survival-coop/module/Contract")
local Gathering = require("../../../../genres/survival-coop/module/Gathering")
local Settlement = require("../../../../core/domain/settlement/Settlement")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Content = require("../../../../core/domain/survival/Content")
local Job = require("../../../../core/domain/crafting/Job")
local Memory = require("../../../../core/infra/data/MemoryBackend")
local config =
	serde.decode("yaml", fs.readFile("cli/forge/fixtures/inventory-conservation/fixture-survival/econ.yml")).genre_contract
local inventory = config.configs["survival-coop"].inventory
inventory.carriedContainer = "bag"
inventory.content.nodes = { { id = "tree", respawnMillis = 1000, harvest = { { item = "wood", quantity = 3 } } } }
inventory.content.structures =
	{ { id = "bench", station = true, footprintX = 1, footprintZ = 1, cost = { { item = "wood", quantity = 1 } } } }
inventory.content.recipes = {
	{
		id = "light",
		craftMillis = 1000,
		station = "bench",
		inputs = { { item = "wood", quantity = 2 } },
		outputs = { { item = "light", quantity = 1 } },
	},
}
local content = assert(Content.canonicalize(inventory.content))
local now = 0
local function clock(): number
	return now
end
local function encode(value: any): string
	return serde.encode("json", value)
end
local memory = Memory.new()
local failSource = false
local sourceUntilFailure: number? = nil
local backend = {
	update = function(key: string, transform: (any) -> any): (boolean, any)
		if key == "nodes:world" and sourceUntilFailure then
			if sourceUntilFailure == 0 then
				return false, "snapshot unavailable"
			end
			sourceUntilFailure -= 1
		end
		if failSource and key == "nodes:world" then
			return false, "source unavailable"
		end
		return memory.update(key, transform)
	end,
}
local publications: { Gathering.State } = {}
local bound: Session.Session? = nil
local destroyed = false
local reachable = true
local admissions = 0
local world: Bootstrap.World = {
	publishNodes = function(state)
		table.insert(publications, Gathering.snapshot(state))
	end,
	services = {
		survivalSpatial = {
			campfire = function()
				return nil
			end,
			station = function(_, id)
				return if id == "bench-1" then { kind = "bench", reachable = reachable } else nil
			end,
		},
	},
	bind = function(session)
		bound = session
	end,
	destroy = function()
		destroyed = true
	end,
	gatheringAccess = function(authorize)
		return function(request, bag)
			local session = assert(bound, "world bound before ingress")
			assert(session.commandEpoch(request.actorId, "survival-coop:gather") == nil, "busy epoch is not authority")
			assert(authorize(session, request, bag), "actual admitted callback authority")
			local forged = table.clone(request)
			forged.requestId = "forged"
			assert(not authorize(session, forged, bag), "request identity checked")
			admissions += 1
			return {
				actorId = request.actorId,
				carriedContainer = bag.id,
				worldRevision = "world",
				equipment = function()
					return {}
				end,
				reachable = function()
					return reachable
				end,
			}
		end
	end,
}
local factory = assert(Bootstrap.new({
	settlements = {
		tribes = {
			{
				key = "tribe",
				now = clock,
				catalog = Job.catalog(content),
				definitions = {
					bench = { id = "bench", footprintX = 1, footprintZ = 1, cost = { { item = "wood", quantity = 1 } } },
				},
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
				verifyTransfer = function(actor, proof)
					return (actor == "1" or actor == "2") and proof == "trusted"
				end,
				workshop = {
					content = content,
					revision = "v1",
					verifyStation = function()
						error("bootstrap must install canonical world station verification")
					end,
				},
			},
		},
		maxServerPlayers = 2,
		maxPlots = 4,
		maxReceipts = 4096,
		tribeFor = function(actor)
			return if actor == "1" or actor == "2" then "tribe" else nil
		end,
		authorize = function()
			return { ok = true }
		end,
		consent = function(owner, target)
			return owner == "1" and target == "2"
		end,
		proof = function()
			return "trusted"
		end,
	},
	sourceKey = "nodes:world",
	initial = Gathering.new(
		"world",
		content,
		{ { id = "tree-1", catalogId = "tree", position = { x = 0, y = 0, z = 0 }, charges = 2, qualityMilli = 1000 } }
	),
	content = content,
	now = clock,
	nowMillis = function()
		return now * 1000
	end,
}, world, backend, { sessionId = "owners", leaseSeconds = 120, now = clock, budget = { encode = encode } }))
local policy = {
	actions = {
		"survival-coop:gather",
		"survival-coop:transfer-deposit",
		"survival-coop:settlement-reserve",
		"survival-coop:settlement-place",
		"survival-coop:settlement-workshop-reserve",
		"survival-coop:settlement-workshop-start",
		"survival-coop:settlement-workshop-complete",
	},
	serverActions = { "survival-coop:settlement-invite" },
	personal = { namespace = "personal", inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" } },
}
local services: any = table.clone(factory.services)
services.now, services.encode = clock, encode
services.roll = function()
	return 0
end
services.emit = function() end
local session = Session.new(
	{ packConfig = config, contracts = { Contract }, controls = {}, storeName = "Bootstrap", durable = policy },
	backend,
	{ sessionId = "personal", lockTimeout = 120, retries = 0, now = clock },
	services,
	policy
)
factory.bind(session)
assert(
	#publications == 1 and publications[1].version == 0 and publications[1].nodes["tree-1"].charges == 2,
	"bind publishes confirmed initial source"
)
assert(session.join("1").ok and session.join("2").ok, "two personal owners join")
assert(session.join("3").reason == "SERVER_PLAYER_LIMIT", "cap refuses third owner")
assert(factory.close().reason == "PLAYERS_ACTIVE", "active owners prevent close")
local function request(actor: string, id: string, action: string, args: { any })
	return { requestId = id, sessionEpoch = assert(session.commandEpoch(actor, action)), action = action, args = args }
end
local function command(actor: string, id: string, action: string, args: { any })
	return session.command(actor, request(actor, id, "survival-coop:" .. action, args))
end
assert(
	session.commandServer("1", request("1", "invite", "survival-coop:settlement-invite", { "2", 0, 0 })).ok,
	"session.commandServer('1', request('1', 'invite', 'survival-coop:settlement-invite', { '2', 0, 0 })).ok"
)
local gather = request("1", "gather", "survival-coop:gather", { "tree-1", 0 })
local publicationCount = #publications
failSource = true
assert(not session.command("1", gather).ok, "failed source command refused")
session.recoverTransfers("1", 16)
assert(#publications == publicationCount, "failed command and recovery never publish")
failSource = false
local gatheredResult = session.command("1", gather)
if not gatheredResult.ok then
	assert(session.recoverTransfers("1", 16).ok, "session.recoverTransfers('1', 16).ok")
	gatheredResult = session.command("1", gather)
end
assert(gatheredResult.ok, tostring(gatheredResult.reason))
assert(
	publications[#publications].version == 1 and publications[#publications].nodes["tree-1"].charges == 1,
	"command publishes confirmed depleted count"
)
local secondGather = request("2", "gather", "survival-coop:gather", { "tree-1", 1 })
session.command("2", secondGather)
assert(session.recoverTransfers("2", 16).ok, "session.recoverTransfers('2', 16).ok")
assert(session.command("2", secondGather).ok, "session.command('2', secondGather).ok")
assert(admissions == 2, "both gather requests admitted")
local source = session.snapshot("1").survivalGathering
assert(source.nodes["tree-1"].charges == 0, "shared source depleted")
publicationCount = #publications
sourceUntilFailure = 1
assert(
	factory.services.survivalGathering.recover("1", 16).status == "confirmed",
	"successful recovery remains successful when publication snapshot fails"
)
assert(#publications == publicationCount, "failed fresh snapshot cannot publish cached source")
sourceUntilFailure = nil
local function gathered(actor: string): string
	for id, item in session.snapshot(actor)["survival-coop"].inventory.bag.items do
		if item.catalogId == "wood" and id ~= "wood" and id ~= "odd" then
			return id
		end
	end
	error("missing gathered output")
end
local deposit = request("1", "deposit", "survival-coop:transfer-deposit", { gathered("1"), 3 })
session.command("1", deposit)
assert(session.recoverTransfers("1", 16).ok, "session.recoverTransfers('1', 16).ok")
assert(session.command("1", deposit).ok, "session.command('1', deposit).ok")
local secondDeposit = request("2", "deposit", "survival-coop:transfer-deposit", { gathered("2"), 3 })
session.command("2", secondDeposit)
assert(session.recoverTransfers("2", 16).ok, "session.recoverTransfers('2', 16).ok")
assert(session.command("2", secondDeposit).ok, "session.command('2', secondDeposit).ok")
local function state(): any
	return session.snapshot("1").survivalSettlement
end
local function craftArgs(first: string, second: string): { any }
	local s = state()
	return { first, second, s.settlement.version, s.warehouse.version, s.settlement.membershipRevision }
end
reachable = false
assert(
	not command("2", "far", "settlement-workshop-reserve", craftArgs("light", "bench-1")).ok,
	"not command('2', 'far', 'settlement-workshop-reserve', craftArgs('light', 'bench-1')).ok"
)
reachable = true
assert(
	not command("2", "fake", "settlement-workshop-reserve", craftArgs("light", "fake")).ok,
	"not command('2', 'fake', 'settlement-workshop-reserve', craftArgs('light', 'fake')).ok"
)
local reserved = command("2", "craft", "settlement-workshop-reserve", craftArgs("light", "bench-1"))
assert(reserved.ok and reserved.data, tostring(reserved.reason))
local job = reserved.data.jobId
assert(
	command("2", "start", "settlement-workshop-start", craftArgs(job, "2")).ok,
	"command('2', 'start', 'settlement-workshop-start', craftArgs(job, '2')).ok"
)
now = 1
session.advance(now)
assert(
	publications[#publications].version == 3 and publications[#publications].nodes["tree-1"].charges == 2,
	"Session recovery publishes confirmed respawn without new scheduler"
)
assert(
	command("2", "complete", "settlement-workshop-complete", craftArgs(job, "2")).ok,
	"command('2', 'complete', 'settlement-workshop-complete', craftArgs(job, '2')).ok"
)
local s = state()
local built = command(
	"1",
	"build",
	"settlement-reserve",
	{ "bench", 4, 4, 0, s.settlement.version, s.warehouse.version, s.settlement.membershipRevision }
)
assert(built.ok and built.data, tostring(built.reason))
s = state()
assert(
	command("1", "place", "settlement-place", { built.data.reservationId, s.settlement.version, s.warehouse.version }).ok,
	"place reserved structure"
)
assert(session.command("1", deposit).ok and session.command("1", gather).ok, "retained requests")
assert(session.close("1").ok and session.join("1").ok, "session.close('1').ok and session.join('1').ok")
assert(session.command("1", deposit).ok and session.command("1", gather).ok, "retained requests after rejoin")
local wood, light = 0, 0
for _, item in state().warehouse.items do
	if item.catalogId == "wood" then
		wood += item.quantity
	else
		light += item.quantity
	end
end
assert(wood == 3 and light == 1, "shared gathering deposit workshop build conservation: " .. wood .. "/" .. light)
assert(next(state().settlement.structures) ~= nil, "build persists")
assert(session.close("1").ok and session.close("2").ok, "session.close('1').ok and session.close('2').ok")
assert(factory.close().ok and destroyed, "owners released before world destroy")
assert(session.join("1").reason == "BOOTSTRAP_CLOSED", "closed bootstrap refuses join")
print(
	"PASS bootstrap actual Session: two actors shared source, consent, deposit, workshop, build, retained requests/rejoin, caps, shutdown"
)
local specs: { [string]: () -> () } = require("../../../../genres/survival-coop/module/SurvivalBootstrap.spec")
for name, check in specs do
	check()
	print("PASS " .. name)
end
