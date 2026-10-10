--!strict
-- Native authority only; all commands and assertions remain in qaharness.
local Services = require("../../../../genres/survival-coop/module/SurvivalServices")
local Gathering = require("../../../../genres/survival-coop/module/Gathering")
local Runtime = require("../../../../genres/survival-coop/module/GatheringRuntime")
local Bridge = require("../../../../genres/survival-coop/module/GatheringBridge")
local Content = require("../../../../core/domain/survival/Content")
local Job = require("../../../../core/domain/crafting/Job")
local Settlement = require("../../../../core/domain/settlement/Settlement")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Session = require("../../../../core/infra/genre/Session")
local Contract = require("../../../../core/domain/genre/Contract")
local ProfileStore = require("../../../../core/infra/data/ProfileStore")
local serde = require("@lune/serde")
local M = {}
function M.new(config: Contract.PackConfig, backend: ProfileStore.Backend, now: () -> number)
	local content = assert(Content.canonicalize(config.configs["survival-coop"].inventory.content))
	local options = {
		sessionId = "gather-craft-settle-owner",
		leaseSeconds = 120,
		now = now,
		budget = {
			encode = function(value: any): string
				return serde.encode("json", value)
			end,
		},
	}
	local factory = assert(Services.new({
		tribes = {
			{
				key = "qa-tribe",
				now = now,
				catalog = Job.catalog(content),
				definitions = {
					bench = { id = "bench", footprintX = 1, footprintZ = 1, cost = { { item = "wood", quantity = 1 } } },
				},
				initial = {
					settlement = Settlement.new(
						{ tribeId = "tribe", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 },
						"owner"
					),
					warehouse = Inventory.new(
						"warehouse",
						{ slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 }
					),
				},
				verifyTransfer = function(actor, proof)
					return actor == proof
				end,
				workshop = {
					content = content,
					revision = "fixture-v1",
					verifyStation = function(_, station, state)
						local structure = state.settlement.structures[station]
						if not structure or structure.definition.id ~= "bench" then
							return nil
						end
						return {
							carriedContainer = state.warehouse.id,
							stationId = station,
							stationKind = "bench",
							inReach = true,
						}
					end,
				},
			},
		},
		maxServerPlayers = 8,
		maxPlots = 4,
		maxReceipts = 4096,
		tribeFor = function()
			-- Even a foreign actor routed to this owner must fail membership authority.
			return "tribe"
		end,
		authorize = function()
			return { ok = true }
		end,
		consent = function(actor, target)
			return actor == "owner" and target ~= "owner"
		end,
		proof = function(actor)
			return actor
		end,
	}, backend, options))
	local session: Session.Session? = nil
	local nodeStore = Fenced.new(backend, options)
	local runtime = assert(Runtime.new({
		key = "qa-nodes",
		initial = Gathering.new("fixture-world", content, {
			{
				id = "final-tree",
				catalogId = "tree",
				position = { x = 0, y = 0, z = 0 },
				charges = 1,
				qualityMilli = 1000,
			},
		}),
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
	local services = table.clone(factory.services)
	services.survivalGathering = Bridge.new({
		resolve = function()
			return runtime
		end,
	})
	return {
		services = services,
		bind = function(value: Session.Session)
			session = value
			factory.bind(value)
		end,
		close = function(): Contract.Result
			local closed = factory.close()
			if not closed.ok then
				return closed
			end
			-- Gathering has no public close; acquire the same owner token only
			-- after all players close, then release its current durable profile.
			local profile = assert(nodeStore:acquire("qa-nodes", function(data)
				return data
			end))
			assert(nodeStore:release(profile))
			return { ok = true }
		end,
	}
end
return M
