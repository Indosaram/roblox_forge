--!strict
-- Native authority for the contracts-tutorial scenario: real gathering source,
-- real tribe/settlement services and the real ContractsExtension over the
-- pack's own content. All commands and assertions stay in qaharness; this
-- fixture only wires owners to the actual Session and checks the analytics
-- stream it observed when the run is closed.
local Services = require("../../../../genres/survival-coop/module/SurvivalServices")
local Gathering = require("../../../../genres/survival-coop/module/Gathering")
local Runtime = require("../../../../genres/survival-coop/module/GatheringRuntime")
local Bridge = require("../../../../genres/survival-coop/module/GatheringBridge")
local ContractsExtension = require("../../../../genres/survival-coop/module/ContractsExtension")
local MarketExtension = require("../../../../genres/survival-coop/module/MarketExtension")
local MarketPorts = require("../../../../games/robango-island/src/shared/MarketPorts")
local Content = require("../../../../core/domain/survival/Content")
local Job = require("../../../../core/domain/crafting/Job")
local Settlement = require("../../../../core/domain/settlement/Settlement")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Events = require("../../../../core/infra/analytics/Events")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Session = require("../../../../core/infra/genre/Session")
local Contract = require("../../../../core/domain/genre/Contract")
local ProfileStore = require("../../../../core/infra/data/ProfileStore")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local M = {}
local SELLER_COINS = 20

-- The analytics stream this fixture observed must follow the golden path: steps strictly
-- ascending by one, tutorial_complete at most once and only right after step 6. A restart
-- opens a fresh fixture (empty log) that resumes mid-path, so only ordering is checked here;
-- completeness is asserted on the real snapshot by the scenario itself.
local function validStream(log: { { name: string, fields: any } }): string?
	local last: number? = nil
	local completed = 0
	for _, event in log do
		if event.name == "tutorial_step" then
			if last ~= nil and event.fields.step ~= last + 1 then
				return "tutorial_step out of order or duplicated"
			end
			last = event.fields.step
		elseif event.name == "tutorial_complete" then
			completed += 1
			if last ~= 6 then
				return "tutorial_complete before the last step"
			end
		end
	end
	if completed > 1 then
		return "tutorial_complete emitted more than once"
	end
	return nil
end

function M.new(config: Contract.PackConfig, backend: ProfileStore.Backend, now: () -> number)
	-- The contracts catalog lives in the pack's content.yml (the econ.yml QA target carries none).
	local content = assert(Content.canonicalize(serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))))
	assert(content.contracts ~= nil, "pack content declares no contracts")
	assert(config.configs["survival-coop"] ~= nil, "pack config binds survival-coop")
	local options = {
		sessionId = "contracts-tutorial-owner",
		leaseSeconds = 120,
		now = now,
		budget = {
			encode = function(value: any): string
				return serde.encode("json", value)
			end,
		},
	}
	local definitions: { [string]: Settlement.Definition } = {}
	for _, definition in content.structures do
		definitions[definition.id] = {
			id = definition.id,
			footprintX = definition.footprintX,
			footprintZ = definition.footprintZ,
			cost = definition.cost,
		}
	end
	local log: { { name: string, fields: any } } = {}
	local analytics = Events.new(function(name, fields)
		table.insert(log, { name = name, fields = fields })
	end)
	local factory = assert(Services.new({
		tribes = {
			{
				key = "qa-tribe",
				now = now,
				catalog = Job.catalog(content),
				definitions = definitions,
				analytics = analytics,
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
					return actor == proof
				end,
			},
		},
		maxServerPlayers = 8,
		maxPlots = 4,
		maxReceipts = 4096,
		tribeFor = function()
			return "tribe"
		end,
		authorize = function()
			return { ok = true }
		end,
		consent = function()
			return false
		end,
		proof = function(actor)
			return actor
		end,
	}, backend, options))
	local session: Session.Session? = nil
	local nodeStore = Fenced.new(backend, options)
	local nodes: { Gathering.Node } = {}
	for index = 1, 3 do
		table.insert(nodes, {
			id = "tree-" .. index,
			catalogId = "fallen-tree",
			position = { x = 0, y = 0, z = 0 },
			charges = 1,
			qualityMilli = 1000,
		})
	end
	table.insert(nodes, {
		id = "flint-1",
		catalogId = "flint-outcrop",
		position = { x = 0, y = 0, z = 0 },
		charges = 1,
		qualityMilli = 1000,
	})
	local runtime = assert(Runtime.new({
		key = "qa-nodes",
		initial = Gathering.new("fixture-world", content, nodes),
		content = content,
		now = now,
		nowMillis = function()
			return now() * 1000
		end,
		maxReceipts = 4096,
		resolvePersonal = function(actor)
			return if session then session.personalTransfer(actor) else nil
		end,
		access = function(request, bag)
			local active = assert(session, "fixture must bind actual Session")
			if request.sessionEpoch ~= (active.envelope(request.actorId).commands :: any).epoch then
				return nil
			end
			return {
				actorId = request.actorId,
				carriedContainer = bag.id,
				worldRevision = "fixture-world",
				equipment = function()
					return {}
				end,
				reachable = function()
					return true
				end,
			}
		end,
	}, nodeStore))
	local extension = assert(ContractsExtension.factory({
		content = content,
		store = function()
			return Fenced.new(backend, {
				sessionId = "contracts-tutorial-ext",
				leaseSeconds = 120,
				now = now,
				budget = options.budget,
			})
		end,
		nowMillis = function()
			return math.floor(now() * 1000)
		end,
		analytics = analytics,
		members = function()
			return if session then session.members() else {}
		end,
		personalTransfer = function(actor)
			return if session then session.personalTransfer(actor) else nil
		end,
	}))
	local port: any = table.clone(extension)
	port.close = nil
	-- Earn-then-spend: the real Market with the pack's goods. Player "1" earns Coins only from
	-- contracts; eligibility reads the real Contracts tutorial. Player "2" is a fixture veteran
	-- seller (tutorial done, SELLER_COINS seeded once) so the buyer has someone to buy from.
	MarketExtension.configure(MarketPorts.config({
		accountAgeDays = function()
			return 30
		end,
		sessionSeconds = function()
			return 10 * 3600
		end,
		tutorialComplete = function(actor)
			if actor == "2" then
				return true
			end
			local data = extension.snapshot(actor)
			return type(data) == "table" and data.tutorial.complete == true
		end,
	}))
	local market = assert(MarketExtension.factory({
		store = function()
			return Fenced.new(backend, {
				sessionId = "contracts-tutorial-market",
				leaseSeconds = 120,
				now = function()
					return math.floor(now())
				end,
				budget = options.budget,
			})
		end,
		now = function()
			return math.floor(now())
		end,
		content = content,
		personalTransfer = function(actor)
			return if session then session.personalTransfer(actor) else nil
		end,
		members = function()
			return if session then session.members() else {}
		end,
	}))
	local marketPort: any = table.clone(market)
	marketPort.close = nil
	local services = table.clone(factory.services)
	services.survivalGathering = Bridge.new({
		resolve = function()
			return runtime
		end,
	})
	services.survivalExtensions = { port, marketPort }
	return {
		services = services,
		bind = function(value: Session.Session)
			session = value
			factory.bind(value)
			local join = value.join
			value.join = function(actor)
				local result = join(actor)
				local access = if result.ok and actor == "2" then value.personalTransfer(actor) else nil
				if access then
					local token = assert(access.personal:update(access.profile(), function(view)
						if view.itemTransfers.receipts["qa-seller-coins"] == nil then
							view.envelope.genres["survival-coop"].data.balance = SELLER_COINS
							view.itemTransfers.receipts["qa-seller-coins"] = { phase = "QA" }
						end
						return view
					end))
					access.install(token)
				end
				return result
			end
		end,
		close = function(): Contract.Result
			local streamError = validStream(log)
			if streamError then
				return { ok = false, reason = "analytics: " .. streamError }
			end
			local released = (extension :: any).close()
			if not released.ok then
				return released
			end
			local marketReleased = (market :: any).close()
			MarketExtension.configure(nil)
			if not marketReleased.ok then
				return marketReleased
			end
			local closed = factory.close()
			if not closed.ok then
				return closed
			end
			local profile = assert(nodeStore:acquire("qa-nodes", function(data)
				return data
			end))
			assert(nodeStore:release(profile))
			return { ok = true }
		end,
	}
end
return M
